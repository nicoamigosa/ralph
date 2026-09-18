#!/bin/bash
#
# Ralph loop — resuelve issues de GitHub sin supervisión, con dos agentes:
#
#   Codex (gpt-5.6-luna, xhigh) implementa    →  abre PR
#   Claude (opus) revisa                      →  PASS ? merge : comentarios
#   Codex corrige sobre la misma rama         →  Claude vuelve a revisar
#
# Nada se mergea sin un <verdict>PASS</verdict> explícito de Claude. Si tras
# RALPH_MAX_ROUNDS revisiones sigue sin pasar, el PR queda abierto y etiquetado
# para que lo mires vos: el loop nunca mergea "por cansancio".
#
# AGNÓSTICO AL PROYECTO: no asume lenguaje, framework ni test runner. Copiá esta
# carpeta en cualquier repo con remoto de GitHub y funciona. Los agentes deducen
# los comandos de test/lint/tipos leyendo AGENTS.md, CLAUDE.md, README y el
# manifest del proyecto (ver ralph/prompt_*.md).
#
# Qué hace cada vuelta:
#   1. Filtra issues abiertos por label de agente (default: ready-for-agent).
#   2. Excluye los "épicos" (issues referenciados como "## Parent" por otros).
#   3. Atiende dependencias: salta los que tienen blockers (## Blocked by)
#      todavía abiertos; los reintenta cuando esos blockers se cierran.
#   4. Rama por issue desde la base, Codex implementa con la skill tdd y abre PR.
#   5. Claude revisa. PASS → merge + cierre del issue, para que los issues
#      dependientes hereden ese código. CHANGES_REQUESTED → Codex corrige.
#
# Idempotente: si una corrida se corta, la siguiente REUTILIZA la rama y el PR
# existentes en vez de recrearlos, y salta lo ya mergeado.
#
# Límites de uso (de Claude o de Codex):
#   - Tope de sesión: NO es un fallo del issue. El script espera a que reabra la
#     ventana y reintenta el MISMO issue.
#   - Tope semanal: para y deja un checkpoint (ralph/last_run.md).
#
# Config por entorno (todo opcional):
#   RALPH_LABEL          label que marca issues AFK      (default: ready-for-agent)
#   RALPH_BASE_BRANCH    branch base                     (default: trunk del repo)
#   RALPH_BRANCH_PREFIX  prefijo de branches por issue   (default: ralph/issue-)
#   RALPH_MAX_ROUNDS     revisiones de Claude por PR     (default: 3)
#   RALPH_CODEX_MODEL    modelo del implementador        (default: gpt-5.6-luna)
#   RALPH_CODEX_EFFORT   reasoning effort de Codex       (default: xhigh)
#   RALPH_CODEX_SANDBOX  sandbox de Codex                (default: workspace-write)
#   RALPH_CLAUDE_MODEL   modelo del revisor              (default: opus)
#   RALPH_MERGE_METHOD   método de merge del PR          (default: --squash)
#   RALPH_MAX_INFRA_RETRIES  reintentos ante caída del revisor (default: 3)
#   RALPH_POST_MERGE_CHECK   script que certifica producción tras cada merge;
#                            recibe el SHA mergeado, ≠0 para toda la corrida
#                            (default: vacío = desactivado)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="${RALPH_LABEL:-ready-for-agent}"
# La base es el trunk del repo (main/master según el remoto), nunca la rama en
# la que estés parado: ralph mergea acá y los issues dependientes heredan ese
# código. Detectarla mantiene el script agnóstico al proyecto.
BASE_BRANCH="${RALPH_BASE_BRANCH:-$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH_PREFIX="${RALPH_BRANCH_PREFIX:-ralph/issue-}"
MAX_ROUNDS="${RALPH_MAX_ROUNDS:-3}"
CODEX_MODEL="${RALPH_CODEX_MODEL:-gpt-5.6-luna}"
CODEX_EFFORT="${RALPH_CODEX_EFFORT:-xhigh}"
CODEX_SANDBOX="${RALPH_CODEX_SANDBOX:-workspace-write}"
CLAUDE_MODEL="${RALPH_CLAUDE_MODEL:-opus}"
MERGE_METHOD="${RALPH_MERGE_METHOD:---squash}"
NEEDS_HUMAN_LABEL="${RALPH_NEEDS_HUMAN_LABEL:-ralph-needs-human}"
MAX_INFRA_RETRIES="${RALPH_MAX_INFRA_RETRIES:-3}"
ISSUE_ORDER="${RALPH_ISSUE_ORDER:-}"
POST_MERGE_CHECK="${RALPH_POST_MERGE_CHECK:-}"
DRY_RUN="${RALPH_DRY_RUN:-0}"
GITHUB_HOST="${GH_HOST:-github.com}"

CHECKPOINT_FILE="$SCRIPT_DIR/last_run.md"
AGENT_LOG="$(mktemp -t ralph-agent.XXXXXX)"
LAST_MSG="$(mktemp -t ralph-lastmsg.XXXXXX)"
trap 'rm -f "$AGENT_LOG" "$LAST_MSG"' EXIT

# Seteados por los runners cuando un agente reporta un tope de uso.
LIMIT_KIND=""
RESET_EPOCH=""

# ---------------------------------------------------------------- preflight --

fail() { echo "❌ $*" >&2; exit 1; }

for cmd in git gh codex claude; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Falta '$cmd' en el PATH."
done
for f in prompt_implement.md prompt_review.md prompt_revise.md prompt_conflicts.md; do
  [ -f "$SCRIPT_DIR/$f" ] || fail "Falta $SCRIPT_DIR/$f."
done
if [ -n "$POST_MERGE_CHECK" ] && [ ! -x "$POST_MERGE_CHECK" ]; then
  fail "RALPH_POST_MERGE_CHECK='$POST_MERGE_CHECK' no existe o no es ejecutable."
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Esto no es un repo git."
git show-ref --verify --quiet "refs/heads/$BASE_BRANCH" \
  || fail "La base '$BASE_BRANCH' no existe localmente (probá: git fetch origin $BASE_BRANCH)."
git remote get-url origin >/dev/null 2>&1 || fail "No hay remoto 'origin'."
gh auth status >/dev/null 2>&1 || fail "gh no está autenticado (corré 'gh auth login')."
REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
[ -n "$REPO_SLUG" ] || fail "No pude resolver el repo de GitHub."

# El working tree debe estar limpio: vamos a saltar entre branches y mergear.
if [ -n "$(git status --porcelain)" ]; then
  fail "Working tree sucio. Commiteá o stasheá antes de correr ralph."
fi

PROMPT_IMPLEMENT="$(cat "$SCRIPT_DIR/prompt_implement.md")"
PROMPT_REVIEW="$(cat "$SCRIPT_DIR/prompt_review.md")"
PROMPT_REVISE="$(cat "$SCRIPT_DIR/prompt_revise.md")"
PROMPT_CONFLICTS="$(cat "$SCRIPT_DIR/prompt_conflicts.md")"

# Un PR necesita que su base exista en el remoto.
if ! git ls-remote --exit-code --heads origin "$BASE_BRANCH" >/dev/null 2>&1; then
  echo "📤 La base '$BASE_BRANCH' no existe en origin; la publico."
  git push -u origin "$BASE_BRANCH" >/dev/null 2>&1 || fail "No pude publicar '$BASE_BRANCH'."
fi

# Label con el que marcamos los PRs que agotaron las rondas.
if [ "$DRY_RUN" != "1" ]; then
  gh label create "$NEEDS_HUMAN_LABEL" --color B60205 \
    --description "Ralph agotó las rondas de revisión; necesita un humano" >/dev/null 2>&1 || true
fi

echo "🔧 base=$BASE_BRANCH · label=$LABEL · rondas=$MAX_ROUNDS · $CODEX_MODEL($CODEX_EFFORT) → $CLAUDE_MODEL"

# ----------------------------------------------------------------- helpers --

# Ordena los issues de la pasada. Por defecto, por número. Si RALPH_ISSUE_ORDER
# trae una lista ('127 124 126'), esos van primero y en ese orden; el resto
# detrás, por número. Los que no estén abiertos y etiquetados se ignoran: la
# lista es una preferencia de orden, nunca una fuente de trabajo.
# Lee los números por stdin, uno por línea; los imprime igual.
apply_issue_order() {
  local all first_lines rest n
  local -a first_numbers=()
  all="$(cat)"
  [ -z "$ISSUE_ORDER" ] && { printf '%s\n' "$all"; return 0; }
  for n in $ISSUE_ORDER; do
    printf '%s\n' "$all" | grep -qx "$n" && first_numbers+=("$n")
  done
  first_lines="$(printf '%s\n' "${first_numbers[@]}")"
  rest="$(printf '%s\n' "$all" | grep -vxF "$first_lines" || true)"
  [ "${#first_numbers[@]}" -gt 0 ] && printf '%s\n' "${first_numbers[@]}"
  [ -n "$rest" ] && printf '%s\n' "$rest"
  return 0
}

# Extrae los #N que aparecen bajo una sección markdown (ej. 'Parent', 'Blocked by').
# Lee el body por stdin, imprime los números (sin '#'), uno por línea.
section_refs() {
  sed -n "/^## *$1/I,/^## /p" | grep -oE '#[0-9]+' | tr -d '#' || true
}

# Si el log del agente termina con "... limit · resets 4:10am", devuelve ese
# instante como epoch (el mensaje lo da en America/New_York).
reset_epoch_from_log() {
  local clock e now
  clock="$(tail -n 40 "$AGENT_LOG" | grep -oiE '[0-9]{1,2}:[0-9]{2}[[:space:]]*(am|pm)' | head -1)"
  [ -z "$clock" ] && return 0
  e="$(TZ='America/New_York' date -d "$clock" +%s 2>/dev/null)" || return 0
  now="$(date +%s)"
  [ "$e" -le "$now" ] && e=$((e + 86400))   # si esa hora ya pasó hoy, es mañana
  echo "$e"
}

# ¿La corrida murió por tope de uso del proveedor? Miramos SOLO el final del log:
# el aviso llega al cierre, mientras que el prompt (que Codex ecoa al principio)
# puede contener cualquier frase y daría falsos positivos.
# Devuelve: 0 si no hubo tope · 8 tope de sesión · 9 tope semanal.
classify_limit() {
  local tail_log now
  tail_log="$(tail -n 40 "$AGENT_LOG")"
  printf '%s' "$tail_log" | grep -qiE \
    "you('ve| have) (hit|reached) your .*limit|usage limit|rate limit|limit[^a-z0-9]*resets" \
    || return 0

  RESET_EPOCH="$(reset_epoch_from_log)"
  now="$(date +%s)"
  # Primero por la palabra del mensaje (señal fiable); si no aparece, por la
  # distancia al reset (un tope de sesión reabre en pocas horas).
  if printf '%s' "$tail_log" | grep -qi "week"; then
    LIMIT_KIND="semanal"; return 9
  elif printf '%s' "$tail_log" | grep -qi "session"; then
    LIMIT_KIND="de sesión"; return 8
  elif [ -n "$RESET_EPOCH" ] && [ "$((RESET_EPOCH - now))" -gt 28800 ]; then
    LIMIT_KIND="semanal"; return 9
  fi
  LIMIT_KIND="de sesión"; return 8
}

# Espera hasta que reabra la ventana de uso, en bloques de <=10min (robusto
# ante suspensión de la máquina). Usa RESET_EPOCH si se conoce; si no, 1h.
wait_for_reset() {
  local issue="$1" target now remaining
  now="$(date +%s)"
  if [ -n "$RESET_EPOCH" ] && [ "$RESET_EPOCH" -gt "$now" ]; then
    target=$((RESET_EPOCH + 120))           # +2 min de colchón
  else
    target=$((now + 3600))
  fi
  echo "⏳ Tope $LIMIT_KIND. Reintento de #$issue ~$(date -d "@$target" '+%H:%M') (en $(((target - now) / 60)) min)..."
  while :; do
    remaining=$((target - $(date +%s)))
    [ "$remaining" -le 0 ] && break
    sleep $(( remaining > 600 ? 600 : remaining ))
  done
}

# Al parar (tope semanal, o producción sin verificar), deja contexto para
# reanudar a mano más tarde. $1: motivo de la parada (default: tope de uso).
write_checkpoint() {
  local reason="${1:-tope ${LIMIT_KIND:-de uso} alcanzado.}"
  {
    echo "# Ralph — checkpoint $(date '+%Y-%m-%d %H:%M %Z')"
    echo
    echo "**Parada:** $reason"
    [ -n "$RESET_EPOCH" ] && echo "**Reset estimado:** $(date -d "@$RESET_EPOCH" '+%Y-%m-%d %H:%M %Z')"
    echo "**Branch base:** \`$BASE_BRANCH\`"
    echo
    echo "## Issues \`$LABEL\` aún abiertos"
    gh issue list --state open --label "$LABEL" --json number,title --jq '.[] | "- #\(.number) \(.title)"'
    echo
    echo "## PRs de ralph abiertos"
    gh pr list --state open --json number,title,headRefName,labels \
      --jq '.[] | select(.headRefName | startswith("'"$BRANCH_PREFIX"'")) | "- #\(.number) \(.title) [\(.labels|map(.name)|join(","))]"'
    echo
    echo "## Reanudar"
    echo "Cuando se renueve el cupo, corré de nuevo (idempotente: reutiliza ramas"
    echo "y PRs existentes, y salta lo ya mergeado):"
    echo
    echo '```bash'
    echo "RALPH_BASE_BRANCH=$BASE_BRANCH ./ralph/once.sh"
    echo '```'
  } > "$CHECKPOINT_FILE"
  echo "💾 Contexto guardado en $CHECKPOINT_FILE"
}

# Corre Codex sobre el repo. Devuelve 0 · 8 · 9 (ver classify_limit).
run_codex() {
  local prompt="$1"
  : > "$AGENT_LOG"; : > "$LAST_MSG"
  codex exec \
    --model "$CODEX_MODEL" \
    -c "model_reasoning_effort=\"$CODEX_EFFORT\"" \
    -c 'sandbox_workspace_write.network_access=true' \
    --sandbox "$CODEX_SANDBOX" \
    --skip-git-repo-check \
    -o "$LAST_MSG" \
    "$prompt" 2>&1 | tee "$AGENT_LOG"
  classify_limit
}

# Corre Claude en modo headless. Devuelve 0 · 8 · 9 (ver classify_limit).
run_claude() {
  local prompt="$1"
  : > "$AGENT_LOG"
  claude \
    --model "$CLAUDE_MODEL" \
    --dangerously-skip-permissions \
    --print \
    "$prompt" 2>&1 | tee "$AGENT_LOG"
  classify_limit
}

# 'gh pr edit --add-label' revienta en versiones de gh que aún consultan
# projectCards (Projects classic, deprecado). La API REST de issues no.
add_label() {
  gh api "repos/$REPO_SLUG/issues/$1/labels" -f "labels[]=$2" >/dev/null 2>&1 \
    || echo "⚠️  No pude aplicar el label '$2' a #$1."
}

pr_for_branch() {
  gh pr list --head "$1" --state open --json number --jq '.[0].number // empty' 2>/dev/null
}

format_refs() {
  local refs
  refs="$(tr '\n' ',' | sed 's/,$//')"
  [ -n "$refs" ] && printf '%s' "$refs" || printf 'none'
}

dry_run_plan() {
  local numbers n priority body parents blockers pr needs_human excluded blocker blocker_state
  local -A bodies=()
  local -A epics=()

  numbers="$(gh issue list --state open --label "$LABEL" --json number \
    --jq 'sort_by(.number) | .[].number' | apply_issue_order)"

  for n in $numbers; do
    bodies[$n]="$(gh issue view "$n" --json body --jq '.body')"
    while read -r n; do
      [ -n "$n" ] && epics[$n]=1
    done < <(printf '%s' "${bodies[$n]}" | section_refs 'Parent')
  done

  echo "Ralph dry-run plan (no mutations or agents)"
  priority=0
  for n in $numbers; do
    priority=$((priority + 1))
    body="${bodies[$n]}"
    parents="$(printf '%s' "$body" | section_refs 'Parent' | format_refs)"
    blockers="$(printf '%s' "$body" | section_refs 'Blocked by' | format_refs)"
    pr="$(pr_for_branch "${BRANCH_PREFIX}${n}")"
    needs_human=no
    if [ -n "$pr" ] && gh pr view "$pr" --json labels --jq '.labels[].name' 2>/dev/null \
      | grep -qx "$NEEDS_HUMAN_LABEL"; then
      needs_human=yes
    fi

    excluded=""
    if [ -n "${epics[$n]:-}" ]; then
      excluded=parent
    elif [ "$needs_human" = yes ]; then
      excluded=needs-human
    else
      while read -r blocker; do
        [ -n "$blocker" ] || continue
        blocker_state="$(gh issue view "$blocker" --json state --jq '.state' 2>/dev/null || printf 'OPEN')"
        if [ "$blocker_state" != CLOSED ]; then
          excluded="blocked-by:$blocker"
          break
        fi
      done < <(printf '%s' "$body" | section_refs 'Blocked by')
    fi

    printf '#%s priority=%s host=%s parents=%s blockers=%s needs-human=%s pr=%s' \
      "$n" "$priority" "$GITHUB_HOST" "$parents" "$blockers" "$needs_human" "${pr:-none}"
    [ -n "$excluded" ] && printf ' excluded=%s' "$excluded"
    printf '\n'
  done
}

# Pone la rama al día con la base antes de cada revisión, para que el revisor
# vea lo que de verdad se va a mergear. Siempre con merge, nunca rebase: Codex
# trabaja sobre esta rama y el merge final es --squash. Si hay conflictos los
# resuelve Codex (sin consumir ronda de revisión); si no lo logra, el PR queda
# para un humano. Devuelve: 0 al día · 1 conflicto sin resolver · 8/9 tope de uso.
update_branch_with_base() {
  local branch="$1" pr="$2" rc conflicted
  git fetch -q origin "$BASE_BRANCH" >/dev/null 2>&1
  git merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD && return 0
  echo "🔄 Pongo $branch al día con $BASE_BRANCH..."
  if git merge --no-edit "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    git push -q origin "$branch" >/dev/null 2>&1 || true
    return 0
  fi
  conflicted="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  echo "⚔️  Conflictos con $BASE_BRANCH en: $conflicted. Codex los resuelve..."
  run_codex "Your branch has a merge in progress from the base branch, with conflicts.

Pull request: #$pr
Branch (already checked out, stay on it): $branch
Base branch being merged in:              $BASE_BRANCH

## Files in conflict
$conflicted

## Working instructions
$PROMPT_CONFLICTS"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    git merge --abort >/dev/null 2>&1 || git reset -q --hard
    return "$rc"
  fi
  if [ -n "$(git status --porcelain)" ] || ! git merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD; then
    git merge --abort >/dev/null 2>&1 || git reset -q --hard
    echo "🙋 Codex no resolvió los conflictos con $BASE_BRANCH. PR #$pr queda para un humano."
    add_label "$pr" "$NEEDS_HUMAN_LABEL"
    gh pr comment "$pr" --body "🤖 Ralph no pudo poner la rama al día con \`$BASE_BRANCH\`: conflictos sin resolver en $conflicted. Necesita un humano." >/dev/null 2>&1 || true
    return 1
  fi
  git push -q origin "$branch" >/dev/null 2>&1 || true
  return 0
}

# CI verde es condición de merge además del PASS. Devuelve 0 si los checks
# pasan (o si el repo no tiene ninguno: avisa y no bloquea); 1 si están en
# rojo, tras dejar en el PR el ítem que Codex debe corregir.
wait_for_ci() {
  local pr="$1" branch="$2" out run_url
  out="$(gh pr checks "$pr" --watch --fail-fast 2>&1)" && return 0
  if printf '%s' "$out" | grep -q "no checks reported"; then
    # Puede ser que el run aún no se registró tras el último push.
    sleep 30
    out="$(gh pr checks "$pr" --watch --fail-fast 2>&1)" && return 0
    if printf '%s' "$out" | grep -q "no checks reported"; then
      echo "⚠️  PR #$pr no tiene checks de CI; mergeo sin esa garantía."
      return 0
    fi
  fi
  run_url="$(gh run list --branch "$branch" --limit 1 --json url --jq '.[0].url' 2>/dev/null)"
  echo "🔴 CI en rojo en PR #$pr: ${run_url:-sin URL del run}"
  gh pr comment "$pr" --body "1. CI en rojo: ${run_url:-ver la pestaña Checks del PR}; reproducir con la suite en base virgen y corregir." >/dev/null 2>&1 || true
  return 1
}

# ------------------------------------------------------------ ciclo por issue --

# Procesa UN issue: implementación por Codex, revisión por Claude, hasta
# MAX_ROUNDS. Devuelve: 0 normal · 8 tope de sesión · 9 tope semanal.
process_issue() {
  local num="$1"
  local branch="${BRANCH_PREFIX}${num}"
  local rc issue_ctx commits pr round verdict comments prior_work
  local infra_retries comments_before comments_after backoff merged_sha ci_ok

  echo ""
  echo "════ Issue #$num ($branch) ════"

  # Idempotencia: si la rama ya existe (corrida anterior interrumpida) la
  # reutilizamos. Recrearla con 'checkout -B' descartaría ese trabajo.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git checkout "$branch" >/dev/null 2>&1 || return 0
    prior_work="$(git log --oneline "$BASE_BRANCH..$branch" 2>/dev/null)"
  else
    git checkout -b "$branch" "$BASE_BRANCH" >/dev/null 2>&1 || return 0
    prior_work=""
  fi

  pr="$(pr_for_branch "$branch")"

  # Un PR ya marcado para humano no se vuelve a tocar: agotó sus rondas.
  if [ -n "$pr" ] && gh pr view "$pr" --json labels --jq '.labels[].name' 2>/dev/null \
       | grep -qx "$NEEDS_HUMAN_LABEL"; then
    echo "🙋 PR #$pr espera revisión humana; no lo toco."
    git checkout "$BASE_BRANCH" >/dev/null 2>&1
    return 0
  fi

  # Contexto mínimo: SOLO este issue (cuerpo + comentarios) y los últimos commits.
  issue_ctx="$(gh issue view "$num" --json number,title,body,comments)"
  commits="$(git log -n 5 --format='%H%n%ad%n%B---' --date=short "$BASE_BRANCH" 2>/dev/null || echo 'No commits found')"

  # ---- Fase 1: implementación (se salta si ya hay PR abierto) ----
  if [ -z "$pr" ]; then
    echo "🛠️  Codex implementa #$num..."
    local resume_note=""
    [ -n "$prior_work" ] && resume_note="
## Heads-up: this branch already has work

A previous run was interrupted before opening a PR. These commits are already on
your branch — review them, keep what is good, and continue from there:

$prior_work
"
    run_codex "You are resolving ONE GitHub issue in an isolated branch.

Branch (already checked out, stay on it): $branch
Base branch for the pull request:         $BASE_BRANCH

## GitHub issue to resolve
$issue_ctx

## Recent commits on the base branch (last 5)
$commits
$resume_note
## Working instructions
$PROMPT_IMPLEMENT"
    rc=$?
    [ "$rc" -ne 0 ] && return "$rc"

    # Red de seguridad: si el agente dejó cambios sin commitear, los persistimos.
    if [ -n "$(git status --porcelain)" ]; then
      git add -A
      git commit -q -m "ralph: progreso sin commitear en issue #$num"
    fi

    pr="$(pr_for_branch "$branch")"
    if [ -z "$pr" ]; then
      echo "⚠️  Codex no dejó PR abierto para #$num. Branch preservado, sin merge."
      git checkout "$BASE_BRANCH" >/dev/null 2>&1
      return 0
    fi
    echo "📬 PR #$pr abierto."
  else
    echo "♻️  PR #$pr ya existe; voy directo a revisión."
  fi

  # ---- Fase 2: revisión, hasta MAX_ROUNDS ----
  round=1
  infra_retries=0
  while [ "$round" -le "$MAX_ROUNDS" ]; do
    update_branch_with_base "$branch" "$pr"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      git checkout "$BASE_BRANCH" >/dev/null 2>&1
      return 0
    fi
    [ "$rc" -ne 0 ] && return "$rc"

    echo "🔍 Claude revisa PR #$pr (ronda $round/$MAX_ROUNDS)..."
    comments_before="$(gh pr view "$pr" --json comments --jq '.comments|length' 2>/dev/null || echo 0)"
    run_claude "You are reviewing ONE pull request.

Pull request: #$pr   (inspect it with: gh pr view $pr, gh pr diff $pr)
Branch under review (already checked out): $branch
Base branch:                               $BASE_BRANCH

## The GitHub issue this PR must satisfy
$issue_ctx

## Review instructions
$PROMPT_REVIEW"
    rc=$?

    # Fail-closed: sin PASS explícito y bien formado, no se mergea.
    verdict="$(grep -oE '<verdict>(PASS|CHANGES_REQUESTED)</verdict>' "$AGENT_LOG" | tail -1)"

    # Un veredicto bien formado prueba que la revisión terminó: descarta un
    # falso positivo de classify_limit (el código revisado puede hablar de
    # "rate limit" y contaminar el log).
    [ -n "$verdict" ] && rc=0
    [ "$rc" -ne 0 ] && return "$rc"
    # PASS con CI en rojo no mergea: wait_for_ci deja el ítem en el PR y se
    # cae a la Fase 3 como con cualquier CHANGES_REQUESTED.
    ci_ok=0
    if [ "$verdict" = "<verdict>PASS</verdict>" ]; then
      echo "✅ PASS en la ronda $round. Espero CI de PR #$pr..."
      wait_for_ci "$pr" "$branch" && ci_ok=1
    fi
    if [ "$ci_ok" -eq 1 ]; then
      echo "🟢 CI verde. Mergeo PR #$pr."
      git checkout "$BASE_BRANCH" >/dev/null 2>&1
      if gh pr merge "$pr" "$MERGE_METHOD" --delete-branch >/dev/null 2>&1; then
        git branch -D "$branch" >/dev/null 2>&1 || true
        merged_sha="$(gh pr view "$pr" --json mergeCommit --jq .mergeCommit.oid 2>/dev/null)"
        # La base local debe traer el merge: los issues dependientes heredan ese código.
        git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1 \
          || echo "⚠️  No pude actualizar '$BASE_BRANCH' local con --ff-only; revisá a mano."
        # Producción rota no admite otro despliegue encima: si el hook falla, para toda la corrida.
        if [ -n "$POST_MERGE_CHECK" ]; then
          echo "🩺 Verifico producción con $POST_MERGE_CHECK $merged_sha..."
          if ! "$POST_MERGE_CHECK" "$merged_sha"; then
            add_label "$num" "$NEEDS_HUMAN_LABEL"
            gh issue comment "$num" --body "🤖 PR #$pr mergeado como $merged_sha pero la verificación de producción falló. Ralph se detiene." >/dev/null 2>&1 || true
            write_checkpoint "producción no verificada tras mergear PR #$pr como \`$merged_sha\`."
            exit 1
          fi
        fi
        # 'Closes #N' sólo autocierra si la base es la rama por defecto: cerramos nosotros.
        gh issue close "$num" --comment "Resuelto por PR #$pr (revisado y aprobado por el revisor de ralph)." >/dev/null 2>&1 || true
        echo "🎉 #$num mergeado a $BASE_BRANCH y cerrado."
      else
        echo "⚠️  El merge de PR #$pr falló (¿conflictos, o checks pendientes?). Queda abierto."
        add_label "$pr" "$NEEDS_HUMAN_LABEL"
      fi
      return 0
    fi

    # Un revisor que no llegó a correr (529, red caída, crash) NO es un rechazo:
    # gastar una ronda mandaría a Codex a "corregir" contra una revisión que no
    # existe. La señal de que hubo revisión real es que dejó comentario.
    if [ -z "$verdict" ]; then
      comments_after="$(gh pr view "$pr" --json comments --jq '.comments|length' 2>/dev/null || echo 0)"
      if [ "$comments_after" -le "$comments_before" ]; then
        infra_retries=$((infra_retries + 1))
        if [ "$infra_retries" -gt "$MAX_INFRA_RETRIES" ]; then
          echo "⚠️  El revisor no arrancó en $MAX_INFRA_RETRIES intentos (fallo de infraestructura, no del código)."
          echo "🔸 #$num queda sin revisar; PR #$pr abierto y SIN label: un rerun lo retoma."
          git checkout "$BASE_BRANCH" >/dev/null 2>&1
          return 0
        fi
        backoff=$((60 * 3 ** (infra_retries - 1)))
        echo "🔁 El revisor no dejó veredicto ni comentario: lo trato como fallo de infraestructura."
        echo "   Reintento $infra_retries/$MAX_INFRA_RETRIES en $((backoff / 60)) min, sin consumir ronda."
        sleep "$backoff"
        continue
      fi
      echo "⚠️  Claude comentó pero no emitió veredicto válido; lo trato como CHANGES_REQUESTED."
    fi

    if [ "$round" -eq "$MAX_ROUNDS" ]; then
      echo "🙋 #$num agotó las $MAX_ROUNDS rondas sin PASS. PR #$pr queda abierto para revisión humana."
      add_label "$pr" "$NEEDS_HUMAN_LABEL"
      gh pr comment "$pr" --body "🤖 Ralph agotó las $MAX_ROUNDS rondas de revisión sin alcanzar PASS. Sin merge: necesita un humano." >/dev/null 2>&1 || true
      git checkout "$BASE_BRANCH" >/dev/null 2>&1
      return 0
    fi

    # ---- Fase 3: Codex atiende los comentarios ----
    echo "✏️  Codex corrige PR #$pr..."
    comments="$(gh pr view "$pr" --json comments --jq '.comments[-1] | "### \(.author.login) escribió:\n\n\(.body)"' 2>/dev/null)"
    run_codex "Your pull request was reviewed and did not pass.

Pull request: #$pr
Branch (already checked out, stay on it): $branch
Base branch:                              $BASE_BRANCH

## The GitHub issue this PR must satisfy
$issue_ctx

## The review you must address
$comments

## Working instructions
$PROMPT_REVISE"
    rc=$?
    [ "$rc" -ne 0 ] && return "$rc"

    if [ -n "$(git status --porcelain)" ]; then
      git add -A
      git commit -q -m "ralph: correcciones sin commitear en issue #$num"
    fi
    git push -q origin "$branch" >/dev/null 2>&1 || true

    round=$((round + 1))
  done

  git checkout "$BASE_BRANCH" >/dev/null 2>&1
  return 0
}

# ------------------------------------------------------------------- bucle --

if [ "$DRY_RUN" = "1" ]; then
  dry_run_plan
  exit 0
fi

# Repetimos pasadas mientras haya progreso, para que los issues que se
# desbloquean al cerrarse sus blockers se procesen en la misma corrida.
attempted=" "
progress=1
while [ "$progress" -eq 1 ]; do
  progress=0

  numbers="$(gh issue list --state open --label "$LABEL" --json number \
    --jq 'sort_by(.number) | .[].number' | apply_issue_order)"
  [ -z "$numbers" ] && break
  # Cachear bodies de la pasada (una llamada por issue) para detectar épicos y blockers.
  unset BODY; declare -A BODY
  # Blockers ya confirmados cerrados. Sólo cacheamos CLOSED: es un estado final,
  # mientras que OPEN puede dejar de serlo dentro de esta misma pasada.
  unset CLOSED_BLOCKER; declare -A CLOSED_BLOCKER
  epics=" "
  for n in $numbers; do
    BODY[$n]="$(gh issue view "$n" --json body --jq '.body')"
    for p in $(printf '%s' "${BODY[$n]}" | section_refs 'Parent'); do
      epics="$epics$p "
    done
  done

  for num in $numbers; do
    # Ya intentado en esta corrida: no reprocesar.
    case "$attempted" in *" $num "*) continue;; esac
    # Es un épico/padre (lo referencia otro issue): no se implementa.
    case "$epics" in *" $num "*) echo "↪️  #$num es épico/padre, lo omito."; continue;; esac

    # ¿Tiene blockers todavía abiertos? Si sí, lo dejamos para la próxima pasada.
    # El listado de la pasada no sirve para decidir esto: la API de GitHub es
    # eventualmente consistente, así que justo después de cerrar un issue todavía
    # lo devuelve abierto y sus dependientes quedan bloqueados de mentira. Peor,
    # si esa pasada no llega a intentar nada el bucle termina por falta de
    # progreso. Consultamos el estado real de cada blocker al evaluarlo, lo que
    # además desbloquea en la misma pasada a los que dependían de un issue que
    # acabamos de cerrar.
    blocked=0
    for b in $(printf '%s' "${BODY[$num]}" | section_refs 'Blocked by'); do
      [ -n "${CLOSED_BLOCKER[$b]:-}" ] && continue
      if [ "$(gh issue view "$b" --json state --jq '.state' 2>/dev/null || echo OPEN)" = "CLOSED" ]; then
        CLOSED_BLOCKER[$b]=1
      else
        blocked=1; break
      fi
    done
    if [ "$blocked" -eq 1 ]; then
      echo "⏭️  #$num bloqueado por dependencias abiertas, lo salto por ahora."
      continue
    fi

    # Reintenta automáticamente ante el tope de sesión; ante el tope semanal,
    # para y deja contexto para reanudar a mano.
    while :; do
      process_issue "$num"
      rc=$?
      if [ "$rc" -eq 9 ]; then
        echo "🛑 Tope semanal alcanzado. Paro y guardo contexto."
        write_checkpoint
        exit 0
      elif [ "$rc" -eq 8 ]; then
        wait_for_reset "$num"
        continue   # reintenta el MISMO issue en la ventana nueva
      fi
      break
    done

    attempted="$attempted$num "
    progress=1
  done
done

echo "🏁 No quedan issues '$LABEL' listos para procesar."
