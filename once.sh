#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 5 )); then
  printf '%s\n' "Ralph requiere Bash >= 5. Instalá con 'brew install bash' y anteponé \"\$(brew --prefix bash)/bin\" al PATH." >&2
  exit 2
fi

fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

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
# Límites de uso (de Claude o de Codex): los adaptadores sólo aceptan señales
# estructuradas del proveedor, reintentan el mismo issue como máximo
# RALPH_MAX_LIMIT_RETRIES veces y nunca fabrican una hora de reset.
#
# Config por entorno (todo opcional):
#   RALPH_LABEL          label que marca issues AFK      (default: ready-for-agent)
#   RALPH_BASE_BRANCH    branch base                     (default: trunk del repo)
#   RALPH_BRANCH_PREFIX  prefijo de branches por issue   (default: ralph/issue-)
#   RALPH_MAX_ROUNDS     revisiones de Claude por PR     (default: 3)
#   RALPH_CODEX_MODEL    modelo del implementador        (default: gpt-5.6-luna)
#   RALPH_CODEX_EFFORT   reasoning effort de Codex       (default: xhigh)
#   RALPH_CODEX_SANDBOX  sandbox de Codex                (default: workspace-write; .git
#                           es sólo lectura allí, ralph lo habilita como writable_root,
#                           ejecuta una sonda de preflight y reemplaza writable_roots
#                           configurado; danger-full-access no se recomienda)
#   RALPH_CLAUDE_MODEL   modelo del revisor              (default: opus)
#   RALPH_MERGE_METHOD   método de merge del PR          (default: --squash)
#   RALPH_MERGE_TIMEOUT_SECONDS espera confirmación       (default: 600)
#   RALPH_MERGE_PENDING_POLICY ante merge encolado         (default: stop)
#   RALPH_MAX_INFRA_RETRIES  reintentos ante caída del revisor (default: 3)
#   RALPH_MAX_LIMIT_RETRIES  reintentos ante un tope del proveedor (default: 3)
#   RALPH_DEADLINE_EPOCH     deadline global opcional, como epoch UTC
#   RALPH_CI_POLICY          required o none explícito       (default: required)
#   RALPH_CI_TIMEOUT_SECONDS espera de CI requerido         (default: 1800)
#   RALPH_REQUIRED_CHECKS_JSON lista JSON de checks obligatorios (default: vacío)
#   RALPH_REQUIRE_PROTECTION exige un ruleset activo en la base, sin bypass
#                            para la identidad que mergea (default: 1)
#   RALPH_MERGE_IDENTITY   login de la identidad que mergea (default: usuario de gh)
#   RALPH_REVIEW_IDENTITY  login de una identidad revisora distinta (opcional)
#   RALPH_POST_MERGE_CHECK   script que certifica producción tras cada merge;
#                            recibe el SHA mergeado, ≠0 para toda la corrida
#                            (default: vacío = desactivado)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="${RALPH_LABEL:-ready-for-agent}"
# La base es el trunk del repo (main/master según el remoto), nunca la rama en
# la que estés parado: ralph mergea acá y los issues dependientes heredan ese
# código. Detectarla mantiene el script agnóstico al proyecto.
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
BASE_BRANCH="${RALPH_BASE_BRANCH:-$DEFAULT_BRANCH}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH_PREFIX="${RALPH_BRANCH_PREFIX:-ralph/issue-}"
MAX_ROUNDS="${RALPH_MAX_ROUNDS:-3}"
CODEX_MODEL="${RALPH_CODEX_MODEL:-gpt-5.6-luna}"
CODEX_EFFORT="${RALPH_CODEX_EFFORT:-xhigh}"
CODEX_SANDBOX="${RALPH_CODEX_SANDBOX:-workspace-write}"
CLAUDE_MODEL="${RALPH_CLAUDE_MODEL:-opus}"
MERGE_METHOD="${RALPH_MERGE_METHOD:---squash}"
MERGE_TIMEOUT_SECONDS="${RALPH_MERGE_TIMEOUT_SECONDS:-600}"
MERGE_PENDING_POLICY="${RALPH_MERGE_PENDING_POLICY:-stop}"
NEEDS_HUMAN_LABEL="${RALPH_NEEDS_HUMAN_LABEL:-ralph-needs-human}"
MAX_INFRA_RETRIES="${RALPH_MAX_INFRA_RETRIES:-3}"
MAX_LIMIT_RETRIES="${RALPH_MAX_LIMIT_RETRIES:-3}"
DEADLINE_EPOCH="${RALPH_DEADLINE_EPOCH:-}"
ISSUE_ORDER="${RALPH_ISSUE_ORDER:-}"
POST_MERGE_CHECK="${RALPH_POST_MERGE_CHECK:-}"
CI_POLICY="${RALPH_CI_POLICY:-required}"
CI_TIMEOUT_SECONDS="${RALPH_CI_TIMEOUT_SECONDS:-1800}"
REQUIRED_CHECKS_JSON="${RALPH_REQUIRED_CHECKS_JSON:-}"
REQUIRE_PROTECTION="${RALPH_REQUIRE_PROTECTION:-1}"
MERGE_IDENTITY="${RALPH_MERGE_IDENTITY:-}"
REVIEW_IDENTITY="${RALPH_REVIEW_IDENTITY:-}"
DRY_RUN="${RALPH_DRY_RUN:-0}"

CHECKPOINT_FILE="${RALPH_CHECKPOINT_FILE:-$SCRIPT_DIR/last_run.md}"
AGENT_LOG="$(mktemp "${TMPDIR:-/tmp}/ralph-agent.XXXXXX")" \
  || fail "No pude crear el temporal para el log del agente."
LAST_MSG="$(mktemp "${TMPDIR:-/tmp}/ralph-lastmsg.XXXXXX")" \
  || fail "No pude crear el temporal para el último mensaje."
RUN_DIR="${RUN_DIR:-${TMPDIR:-/tmp}/ralph-run-$$}"
mkdir -p "$RUN_DIR" || fail "No pude crear el directorio de corrida '$RUN_DIR'."
RUN_SEQUENCE=0
AGENT_STDOUT=""
AGENT_STDERR=""
ADAPTER_RESULT_FILE=""
ADAPTER_FINAL_MESSAGE=""
ADAPTER_EXIT_CODE=0
ADAPTER_ERROR=""
PROTECTION_STATUS="not_checked"
PROTECTION_FAILURES=""
PROTECTION_RULESET_IDS=""
MERGED_SHA=""
ADAPTER_STATUS=""

CURRENT_ISSUE=""
CURRENT_PHASE="preflight"
CURRENT_AGENT_PID=""
CURRENT_AGENT_PGID=""
CURRENT_AGENT_FIFO=""
CURRENT_AGENT_ERR_FIFO=""
CURRENT_TEE_PID=""
CURRENT_TEE_ERR_PID=""
SIGNAL_EXITING=0

process_group_for_pid() {
  ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]'
}

process_is_running() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')"
  case "$state" in
    ''|Z*) return 1 ;;
    *) return 0 ;;
  esac
}

terminate_agent_group() {
  local own_pgid agent_pgid
  own_pgid="$(process_group_for_pid "$$")"
  agent_pgid="$CURRENT_AGENT_PGID"
  if [ -z "$agent_pgid" ] && [ -n "$CURRENT_AGENT_PID" ]; then
    agent_pgid="$(process_group_for_pid "$CURRENT_AGENT_PID")"
  fi
  if [ -n "$agent_pgid" ] && [ "$agent_pgid" != "$own_pgid" ] && [ "$agent_pgid" != 0 ]; then
    kill -TERM -- "-$agent_pgid" 2>/dev/null || true
    kill -KILL -- "-$agent_pgid" 2>/dev/null || true
    return 0
  fi
  if [ -n "$CURRENT_AGENT_PID" ] && [ "$CURRENT_AGENT_PID" != "$$" ] \
      && process_is_running "$CURRENT_AGENT_PID"; then
    kill -TERM "$CURRENT_AGENT_PID" 2>/dev/null || true
    kill -KILL "$CURRENT_AGENT_PID" 2>/dev/null || true
    return 0
  fi
  return 1
}

terminate_agent_processes() {
  local agent_terminated=0
  if terminate_agent_group; then
    agent_terminated=1
  fi
  if [ -n "$CURRENT_TEE_PID" ]; then
    kill -TERM "$CURRENT_TEE_PID" 2>/dev/null || true
    kill -KILL "$CURRENT_TEE_PID" 2>/dev/null || true
  fi
  if [ -n "$CURRENT_TEE_ERR_PID" ]; then
    kill -TERM "$CURRENT_TEE_ERR_PID" 2>/dev/null || true
    kill -KILL "$CURRENT_TEE_ERR_PID" 2>/dev/null || true
  fi
  if [ -n "$CURRENT_AGENT_PID" ] && { [ "$agent_terminated" -eq 1 ] || ! process_is_running "$CURRENT_AGENT_PID"; }; then
    wait "$CURRENT_AGENT_PID" 2>/dev/null || true
  fi
  if [ -n "$CURRENT_TEE_PID" ]; then
    wait "$CURRENT_TEE_PID" 2>/dev/null || true
  fi
  if [ -n "$CURRENT_TEE_ERR_PID" ]; then
    wait "$CURRENT_TEE_ERR_PID" 2>/dev/null || true
  fi
}

record_signal_in_summary() {
  local signal="$1" exit_code="$2" summary_file
  local summary_tmp message issue_json
  [ -n "${RUN_DIR:-}" ] || return 0
  summary_file="$RUN_DIR/summary.json"
  [ -f "$summary_file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  summary_tmp="${summary_file}.tmp.$$"
  message="corrida terminada por señal $signal durante $CURRENT_PHASE del issue #${CURRENT_ISSUE:-?}"
  if [ -n "$CURRENT_ISSUE" ] && printf '%s' "$CURRENT_ISSUE" | grep -Eq '^[0-9]+$'; then
    issue_json="$CURRENT_ISSUE"
  else
    issue_json=null
  fi
  if jq --arg signal "$signal" \
      --arg phase "$CURRENT_PHASE" \
      --arg message "$message" \
      --argjson issue "$issue_json" \
      --argjson exit_code "$exit_code" \
      '.stop_reason = ("signal:" + $signal) |
       .signal = {name: $signal, phase: $phase, issue: $issue, exit_code: $exit_code} |
       .errors = ((.errors // []) + [$message])' \
      "$summary_file" > "$summary_tmp" 2>/dev/null; then
    mv -f "$summary_tmp" "$summary_file"
  else
    rm -f "$summary_tmp"
  fi
}

signal_number() {
  case "$1" in
    HUP) printf '%s\n' 1 ;;
    INT) printf '%s\n' 2 ;;
    TERM) printf '%s\n' 15 ;;
    *) printf '%s\n' 1 ;;
  esac
}

handle_signal() {
  local signal="$1" exit_code message
  [ "$SIGNAL_EXITING" -eq 0 ] || return 0
  SIGNAL_EXITING=1
  exit_code=$((128 + $(signal_number "$signal")))
  message="corrida terminada por señal $signal durante $CURRENT_PHASE del issue #${CURRENT_ISSUE:-?}"
  printf '⚠️  %s\n' "$message"
  printf '%s\n' "$message" >> "$AGENT_LOG"
  record_signal_in_summary "$signal" "$exit_code"
  terminate_agent_processes
  exit "$exit_code"
}

cleanup_on_exit() {
  [ "$SIGNAL_EXITING" -eq 1 ] || terminate_agent_processes
  rm -f "$AGENT_LOG" "$LAST_MSG"
  [ -n "$CURRENT_AGENT_FIFO" ] && rm -f "$CURRENT_AGENT_FIFO"
  [ -n "$CURRENT_AGENT_ERR_FIFO" ] && rm -f "$CURRENT_AGENT_ERR_FIFO"
}

trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP
trap cleanup_on_exit EXIT

# Seteados por los runners cuando un agente reporta un tope de uso.
LIMIT_KIND=""
RESET_EPOCH=""
LIMIT_ERROR=""

# Códigos privados del adaptador para que el bucle principal pueda distinguir
# un tope reintentable de errores que deben detener la corrida.
LIMIT_RETRY_RC=8
AUTH_ERROR_RC=65
CONFIG_ERROR_RC=66

# ---------------------------------------------------------------- preflight --

case "$MERGE_METHOD" in
  --squash|--merge|--rebase) ;;
  *) fail "RALPH_MERGE_METHOD debe ser exactamente --squash, --merge o --rebase." ;;
esac

case "$MERGE_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) fail "RALPH_MERGE_TIMEOUT_SECONDS debe ser un entero no negativo." ;;
esac

case "$MERGE_PENDING_POLICY" in
  stop|continue) ;;
  *) fail "RALPH_MERGE_PENDING_POLICY debe ser exactamente stop o continue." ;;
esac

case "$CI_POLICY" in
  required|none) ;;
  *) fail "RALPH_CI_POLICY debe ser exactamente required o none." ;;
esac
case "$REQUIRE_PROTECTION" in
  0|1) ;;
  *) fail "RALPH_REQUIRE_PROTECTION debe ser exactamente 0 o 1." ;;
esac
case "$CI_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) fail "RALPH_CI_TIMEOUT_SECONDS debe ser un entero no negativo." ;;
esac
case "$MAX_LIMIT_RETRIES" in
  ''|*[!0-9]*) fail "RALPH_MAX_LIMIT_RETRIES debe ser un entero no negativo." ;;
esac
case "$DEADLINE_EPOCH" in
  '') ;;
  *[!0-9]*) fail "RALPH_DEADLINE_EPOCH debe ser un epoch entero no negativo." ;;
  *) ;;
esac

repo_host() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  case "$remote" in
    http://*|https://*)
      remote="${remote#*://}"
      printf '%s\n' "${remote%%/*}"
      ;;
    git@*:*)
      remote="${remote#git@}"
      printf '%s\n' "${remote%%:*}"
      ;;
    ssh://*)
      remote="${remote#ssh://}"
      remote="${remote#*@}"
      printf '%s\n' "${remote%%/*}"
      ;;
    *)
      printf '%s\n' "github.com"
      ;;
  esac
}

for cmd in git gh; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Falta '$cmd' en el PATH."
done
if [ "$DRY_RUN" != "1" ]; then
  command -v jq >/dev/null 2>&1 || fail "Falta 'jq' en el PATH para leer los resultados de CI."
fi
if [ -n "$REQUIRED_CHECKS_JSON" ]; then
  if ! jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' \
      >/dev/null 2>&1 <<<"$REQUIRED_CHECKS_JSON"; then
    fail "RALPH_REQUIRED_CHECKS_JSON debe ser una lista JSON de nombres no vacíos."
  fi
fi
if [ "$DRY_RUN" != "1" ]; then
  for cmd in codex claude; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Falta '$cmd' en el PATH."
  done
fi
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
REPO_HOST="$(repo_host)"

write_protection_summary() {
  local status="$1" failure required_checks protection_required_json=true summary_tmp
  failure=""
  [ "$#" -gt 1 ] && failure="$2"
  required_checks="$REQUIRED_CHECKS_JSON"
  [ -n "$required_checks" ] || required_checks='[]'
  [ "$REQUIRE_PROTECTION" = "0" ] && protection_required_json=false
  [ "$DRY_RUN" = "1" ] && return 0
  summary_tmp="$RUN_DIR/summary.json.tmp.$$"
  if jq -cn \
      --arg status "$status" \
      --arg base_branch "$BASE_BRANCH" \
      --arg merge_identity "$MERGE_IDENTITY" \
      --arg review_identity "$REVIEW_IDENTITY" \
      --arg failure "$failure" \
      --argjson required "$protection_required_json" \
      --argjson required_checks "$required_checks" \
      '{
        protection: {
          required: $required,
          status: $status,
          base_branch: $base_branch,
          merge_identity: $merge_identity,
          review_identity: $review_identity,
          required_checks: $required_checks,
          warning: (if $status == "disabled" then "RALPH_REQUIRE_PROTECTION=0" else null end)
        },
        errors: (if $failure == "" then [] else [$failure] end)
      }' >"$summary_tmp" 2>/dev/null; then
    mv -f "$summary_tmp" "$RUN_DIR/summary.json"
  else
    rm -f "$summary_tmp"
  fi
}

ref_name_matches_pattern() {
  local ref_name="$1" pattern="$2"
  case "$pattern" in
    "~ALL") return 0 ;;
    "~DEFAULT_BRANCH")
      [ -n "$DEFAULT_BRANCH" ] && [ "$BASE_BRANCH" = "$DEFAULT_BRANCH" ]
      return
      ;;
    *)
      # shellcheck disable=SC2254
      case "$ref_name" in
        $pattern) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

ruleset_covers_branch() {
  local ruleset="$1" ref_name="refs/heads/$BASE_BRANCH" pattern
  local include_count include_match=0

  include_count="$(jq -r '(.conditions.ref_name.include // []) | length' <<<"$ruleset")" || return 1
  if [ "$include_count" -eq 0 ]; then
    include_match=1
  else
    while IFS= read -r pattern; do
      if ref_name_matches_pattern "$ref_name" "$pattern"; then
        include_match=1
        break
      fi
    done < <(jq -r '.conditions.ref_name.include[]? // empty' <<<"$ruleset")
  fi
  [ "$include_match" -eq 1 ] || return 1

  while IFS= read -r pattern; do
    if ref_name_matches_pattern "$ref_name" "$pattern"; then
      return 1
    fi
  done < <(jq -r '.conditions.ref_name.exclude[]? // empty' <<<"$ruleset")
  return 0
}

check_base_protection() {
  local identity_json="" rulesets active_rulesets required_checks missing_checks
  local ruleset_detail ruleset_details identity_id
  local review_rule=0 review_check=0
  local branch="$BASE_BRANCH"
  PROTECTION_FAILURES=""
  PROTECTION_RULESET_IDS=""

  if [ "$REQUIRE_PROTECTION" = "0" ]; then
    PROTECTION_STATUS="disabled"
    write_protection_summary "$PROTECTION_STATUS" ""
    echo "⚠️  Protección de la base desactivada explícitamente (RALPH_REQUIRE_PROTECTION=0); sólo permitido para el sandbox de pruebas." >&2
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    PROTECTION_STATUS="dry_run"
    return 0
  fi

  identity_json="$(gh api user 2>/dev/null | jq -c . 2>/dev/null)" || identity_json=""
  if [ -z "$MERGE_IDENTITY" ]; then
    MERGE_IDENTITY="$(jq -r '.login // empty' <<<"$identity_json" 2>/dev/null)"
  fi
  if [ -z "$MERGE_IDENTITY" ]; then
    PROTECTION_FAILURES="no pude resolver la identidad que mergea (gh api user o RALPH_MERGE_IDENTITY)"
  fi
  identity_id="$(jq -r '.id // empty' <<<"$identity_json" 2>/dev/null)"

  rulesets="$(gh api --paginate \
    "repos/$REPO_SLUG/rulesets?includes_parents=true" 2>/dev/null | \
    jq -s -c 'if length == 1 and (.[0] | type) == "array" then .[0] else add end' 2>/dev/null)" || rulesets=""
  if [ -z "$rulesets" ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$rulesets"; then
    PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }no pude consultar los rulesets de la base '$branch'"
    write_protection_summary failed "$PROTECTION_FAILURES"
    echo "❌ Preflight de protección falló para '$branch': $PROTECTION_FAILURES. Faltan un ruleset activo y required status checks; no se mergea." >&2
    return 1
  fi

  if ! jq -e '[.[] | select(.id == null)] | length == 0' >/dev/null 2>&1 <<<"$rulesets"; then
    PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }el listado de rulesets no incluye identificadores completos"
  fi
  ruleset_details='[]'
  while IFS= read -r ruleset_id; do
    [ -n "$ruleset_id" ] || continue
    ruleset_detail="$(gh api --paginate \
      "repos/$REPO_SLUG/rulesets/$ruleset_id" 2>/dev/null | jq -c . 2>/dev/null)" || ruleset_detail=""
    if [ -z "$ruleset_detail" ] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$ruleset_detail"; then
      PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }no pude consultar el detalle del ruleset '$ruleset_id'"
      continue
    fi
    ruleset_details="$(jq -c --argjson detail "$ruleset_detail" '. + [$detail]' <<<"$ruleset_details")" || {
      PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }no pude procesar el detalle del ruleset '$ruleset_id'"
    }
  done < <(jq -r '.[].id // empty' <<<"$rulesets")

  active_rulesets='[]'
  while IFS= read -r ruleset_detail; do
    [ -n "$ruleset_detail" ] || continue
    if [ "$(jq -r '.enforcement // "active"' <<<"$ruleset_detail")" = "active" ] \
      && [ "$(jq -r '.target // "branch"' <<<"$ruleset_detail")" = "branch" ] \
      && ruleset_covers_branch "$ruleset_detail"; then
      active_rulesets="$(jq -c --argjson detail "$ruleset_detail" '. + [$detail]' <<<"$active_rulesets")" || {
        PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }no pude procesar los rulesets activos"
      }
    fi
  done < <(jq -c '.[]' <<<"$ruleset_details")

  if [ "$(jq 'length' <<<"$active_rulesets")" -eq 0 ]; then
    PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }ruleset activo que cubra '$branch'"
  else
    PROTECTION_RULESET_IDS="$(jq -r 'map(.id // .name // empty) | join(",")' <<<"$active_rulesets")"
    if jq -e 'any(.[]; ((.bypass_actors? // null) | type != "array"))' \
        <<<"$active_rulesets" >/dev/null; then
      PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }el ruleset activo no expone bypass_actors como array; dato insuficiente para verificar ausencia de bypass"
    fi
  fi

  required_checks="$(jq -c '[.[] |
    .rules[]? | select(.type == "required_status_checks") |
    (.parameters.required_status_checks // [])[]? |
    (.context // .name // empty)] | unique' <<<"$active_rulesets")"
  if [ -z "$REQUIRED_CHECKS_JSON" ]; then
    [ "$(jq 'length' <<<"$required_checks")" -gt 0 ] ||
      PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }al menos un required status check"
  else
    missing_checks="$(jq -nr --argjson configured "$REQUIRED_CHECKS_JSON" --argjson covered "$required_checks" \
      '$configured - $covered | join(", ")')"
    [ -z "$missing_checks" ] ||
      PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }required status checks faltantes: $missing_checks"
  fi

  if [ -n "$REVIEW_IDENTITY" ] && [ "$REVIEW_IDENTITY" != "$MERGE_IDENTITY" ]; then
    if jq -e 'any(.[]; any(.rules[]?;
        .type == "pull_request" and
        ((.parameters.required_approving_review_count // 0) > 0)))' \
        <<<"$active_rulesets" >/dev/null; then
      review_rule=1
    fi
    if jq -e 'index("ralph-review") != null' <<<"$required_checks" >/dev/null; then
      review_check=1
    fi
    if [ "$review_rule" -eq 0 ] && [ "$review_check" -eq 0 ]; then
      PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }identidad revisora distinta requiere una aprobación obligatoria o el required status check ralph-review"
    fi
  fi

  if [ -n "$MERGE_IDENTITY" ] && [ "$(jq 'length' <<<"$active_rulesets")" -gt 0 ]; then
    if jq -e --arg id "$identity_id" '
        any(.[]; any(.bypass_actors[]?;
          ((.bypass_mode // "always") != "never") and
          ((.actor_type // "") == "User") and
          ($id != "" and ((.actor_id // "") | tostring) == $id)))' \
        <<<"$active_rulesets" >/dev/null; then
      PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }la identidad de merge '$MERGE_IDENTITY' tiene bypass"
    fi
    if jq -e --arg id "$identity_id" '
        any(.[]; any(.bypass_actors[]?;
          ((.bypass_mode // "always") != "never") and
          (((.actor_type // "") != "User") or
            ($id == "" or .actor_id == null))))' \
        <<<"$active_rulesets" >/dev/null; then
      PROTECTION_FAILURES="${PROTECTION_FAILURES}${PROTECTION_FAILURES:+; }hay un bypass_actor que no se puede demostrar como un usuario distinto de la identidad de merge"
    fi
  fi

  if [ -n "$PROTECTION_FAILURES" ]; then
    PROTECTION_STATUS="failed"
    write_protection_summary "$PROTECTION_STATUS" "$PROTECTION_FAILURES"
    echo "❌ Preflight de protección falló para '$branch': $PROTECTION_FAILURES. Faltan un ruleset activo, required status checks cubiertos y ausencia de bypass; no se mergea." >&2
    return 1
  fi
  PROTECTION_STATUS="verified"
  write_protection_summary "$PROTECTION_STATUS" ""
  echo "🛡️  Protección verificada para '$branch' (rulesets: $PROTECTION_RULESET_IDS; identidad de merge: $MERGE_IDENTITY)."
  return 0
}

check_base_protection || exit $?

# El working tree debe estar limpio: vamos a saltar entre branches y mergear.
if [ "$DRY_RUN" != "1" ] && [ -n "$(git status --porcelain)" ]; then
  fail "Working tree sucio. Commiteá o stasheá antes de correr ralph."
fi

PROMPT_IMPLEMENT="$(cat "$SCRIPT_DIR/prompt_implement.md")"
PROMPT_REVIEW="$(cat "$SCRIPT_DIR/prompt_review.md")"
PROMPT_REVISE="$(cat "$SCRIPT_DIR/prompt_revise.md")"
PROMPT_CONFLICTS="$(cat "$SCRIPT_DIR/prompt_conflicts.md")"

# Un PR necesita que su base exista en el remoto.
if ! git ls-remote --exit-code --heads origin "$BASE_BRANCH" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "⚠️  La base '$BASE_BRANCH' no existe en origin; dry-run continúa sin publicar."
  else
    echo "📤 La base '$BASE_BRANCH' no existe en origin; la publico."
    git push -u origin "$BASE_BRANCH" >/dev/null 2>&1 || fail "No pude publicar '$BASE_BRANCH'."
  fi
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
  local all rest n candidate is_first
  local -a first=()
  all="$(cat)"
  [ -z "$ISSUE_ORDER" ] && { printf '%s\n' "$all"; return 0; }
  for n in $ISSUE_ORDER; do
    while IFS= read -r candidate; do
      if [ "$candidate" = "$n" ]; then
        first+=("$n")
        break
      fi
    done <<EOF
$all
EOF
  done
  rest=""
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    is_first=0
    for candidate in "${first[@]}"; do
      if [ "$candidate" = "$n" ]; then
        is_first=1
        break
      fi
    done
    [ "$is_first" -eq 1 ] || rest="${rest}${n}"$'\n'
  done <<EOF
$all
EOF
  [ "${#first[@]}" -gt 0 ] && printf '%s\n' "${first[@]}"
  [ -n "$rest" ] && printf '%s' "$rest"
  return 0
}

# Extrae referencias documentadas bajo una sección markdown.
# Lee el body por stdin, imprime los números (sin '#'), uno por línea.
section_refs() {
  awk -v wanted="$1" '
    function trim_right(value) {
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^##[[:space:]]/) {
        heading = line
        sub(/^##[[:space:]]*/, "", heading)
        active = (tolower(trim_right(heading)) == tolower(wanted))
        next
      }
      if (active && line ~ /^[[:space:]]*-?[[:space:]]*#[0-9]+[[:space:]]*$/) {
        reference = line
        sub(/^[[:space:]]*-?[[:space:]]*#/, "", reference)
        sub(/[[:space:]]+$/, "", reference)
        print reference
      }
    }
  '
}

# Valida que cada línea no vacía de ## Blocked by sea una referencia completa.
# Imprime las líneas inválidas y devuelve un estado distinto de cero.
validate_blocked_by() {
  awk '
    function is_reference(value) {
      return value ~ /^[[:space:]]*-?[[:space:]]*#[0-9]+[[:space:]]*$/
    }
    function trim_right(value) {
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^##[[:space:]]/) {
        heading = line
        sub(/^##[[:space:]]*/, "", heading)
        active = (tolower(trim_right(heading)) == "blocked by")
        next
      }
      if (active && line !~ /^[[:space:]]*$/ && !is_reference(line)) {
        print line
        invalid = 1
      }
    }
    END { exit invalid ? 1 : 0 }
  '
}

format_epoch() {
  local epoch="$1" format="${2:-+%Y-%m-%d %H:%M %Z}"
  if [ "$(uname -s)" = "Darwin" ]; then
    date -r "$epoch" "$format"
  else
    date -d "@$epoch" "$format"
  fi
}

# Convierte únicamente epochs enteros o timestamps RFC3339 con zona. No se
# aceptan horas humanas, nombres de zona implícitos ni valores derivados de
# stdout/stderr.
parse_zoned_timestamp_epoch() {
  local timestamp="$1" mac_timestamp length
  case "$timestamp" in
    ????-??-??T??:??:??Z|????-??-??T??:??:??+??:??|????-??-??T??:??:??-??:??) ;;
    *) return 1 ;;
  esac
  if [ "$(uname -s)" = "Darwin" ]; then
    mac_timestamp="$timestamp"
    if [[ "$mac_timestamp" == *Z ]]; then
      mac_timestamp="${mac_timestamp%Z}+0000"
    else
      length="${#mac_timestamp}"
      mac_timestamp="${mac_timestamp:0:length-3}${mac_timestamp:length-2:2}"
    fi
    date -j -f '%Y-%m-%dT%H:%M:%S%z' "$mac_timestamp" +%s 2>/dev/null
  else
    date -u -d "$timestamp" +%s 2>/dev/null
  fi
}

normalize_retry_at() {
  local signal="$1" retry_type retry_value epoch
  retry_type="$(jq -r '.retry_at | type' <<<"$signal")"
  case "$retry_type" in
    number)
      jq -e '.retry_at >= 0 and (.retry_at | floor) == .retry_at' \
        >/dev/null 2>&1 <<<"$signal" || return 0
      jq -r '.retry_at' <<<"$signal"
      ;;
    string)
      retry_value="$(jq -r '.retry_at' <<<"$signal")"
      case "$retry_value" in
        ''|*[!0-9]*)
          epoch="$(parse_zoned_timestamp_epoch "$retry_value")" || return 0
          ;;
        *)
          epoch="$retry_value"
          ;;
      esac
      printf '%s\n' "$epoch"
      ;;
  esac
}

provider_signal_from_event() {
  jq -c '
    if (.type == "error" or .type == "turn.failed") then
      if (.error | type) == "object" then .error
      elif (.provider_error | type) == "object" then .provider_error
      elif (.metadata.error | type) == "object" then .metadata.error
      elif (.provider_metadata.error | type) == "object" then .provider_metadata.error
      elif (.metadata.rate_limit | type) == "object" then .metadata.rate_limit
      elif (.provider_metadata.rate_limit | type) == "object" then .provider_metadata.rate_limit
      elif (.metadata | type) == "object" then .metadata
      elif (.provider_metadata | type) == "object" then .provider_metadata
      elif ((.code // .kind // .status // .retry_at) != null) then .
      else empty end
    elif (.type == "result" and .is_error == true) then
      if (.error | type) == "object" then .error
      elif (.provider_error | type) == "object" then .provider_error
      elif (.metadata.error | type) == "object" then .metadata.error
      elif (.provider_metadata.error | type) == "object" then .provider_metadata.error
      elif (.metadata.rate_limit | type) == "object" then .metadata.rate_limit
      elif (.provider_metadata.rate_limit | type) == "object" then .provider_metadata.rate_limit
      elif (.metadata | type) == "object" then .metadata
      elif (.provider_metadata | type) == "object" then .provider_metadata
      elif ((.code // .kind // .status // .retry_at) != null) then .
      else empty end
    else empty end
  ' <<<"$1"
}

classify_provider_signal() {
  local signal="$1" code scope retry_at error_message
  code="$(jq -r 'if (.rate_limit == true or (.rate_limit | type) == "object" or .rate_limited == true) then "rate_limit" else (.code // .error_code // .kind // .type // .status // "") end | tostring | ascii_downcase' <<<"$signal")"
  scope="$(jq -r '(.limit_scope // .scope // "") | tostring | ascii_downcase' <<<"$signal")"
  retry_at="$(normalize_retry_at "$signal")"
  error_message="$(jq -r '(.message // .detail // .code // "provider error") | tostring' <<<"$signal")"

  ADAPTER_ERROR="$error_message"
  ADAPTER_RETRY_AT="null"
  ADAPTER_LIMIT_SCOPE="unknown"
  ADAPTER_RETRYABLE=false
  case "$code" in
    rate_limit|rate_limited|rate_limit_exceeded|usage_limit|quota_exceeded|too_many_requests|429)
      ADAPTER_STATUS="rate_limited"
      ADAPTER_RETRYABLE=true
      [ -n "$retry_at" ] && ADAPTER_RETRY_AT="$retry_at"
      case "$scope" in
        weekly|week) ADAPTER_LIMIT_SCOPE="weekly" ;;
        session|day|daily) ADAPTER_LIMIT_SCOPE="session" ;;
      esac
      ;;
    auth_error|authentication_error|unauthorized|invalid_api_key|not_authenticated|401)
      ADAPTER_STATUS="auth_error"
      ;;
    config_error|configuration_error|invalid_configuration|invalid_model|unsupported_model|invalid_option|unsupported_option)
      ADAPTER_STATUS="config_error"
      ;;
    *)
      ADAPTER_STATUS="unknown"
      ;;
  esac
}

# Espera hasta el instante fiable entregado por el proveedor, en bloques de
# <=10min. Devuelve 2 si el deadline global vence antes del reset.
wait_for_reset() {
  local issue="$1" target now remaining
  [ -n "$RESET_EPOCH" ] || {
    echo "⏭️  Tope sin retry_at fiable; reintento de #$issue sin espera."
    return 0
  }
  now="$(date +%s)"
  target="$RESET_EPOCH"
  if [ -n "$DEADLINE_EPOCH" ] && [ "$target" -gt "$DEADLINE_EPOCH" ]; then
    echo "🛑 El reset del proveedor excede el deadline global; no reintento #$issue."
    return 2
  fi
  [ "$target" -gt "$now" ] || return 0
  echo "⏳ Tope $LIMIT_KIND. Reintento de #$issue ~$(format_epoch "$target" '+%H:%M') (en $(((target - now) / 60)) min)..."
  while :; do
    now="$(date +%s)"
    remaining=$((target - now))
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
    [ -n "$RESET_EPOCH" ] && echo "**Reset estimado:** $(format_epoch "$RESET_EPOCH" '+%Y-%m-%d %H:%M %Z')"
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

# Corre un agente en su propia sesión/grupo y conserva stdout y stderr en
# archivos distintos. Devuelve el exit code del agente o 70 si falla una
# captura.
run_agent_group() {
  local stdout_file="$1" stderr_file="$2"
  local stdout_fifo="$stdout_file.fifo" stderr_fifo="$stderr_file.fifo"
  local agent_rc=0 tee_rc=0 tee_err_rc=0 agent_done=0 tee_done=0 tee_err_done=0
  local had_job_control=0 own_pgid agent_pgid attempt=0

  rm -f "$stdout_fifo" "$stderr_fifo"
  mkfifo "$stdout_fifo" "$stderr_fifo" || return 70
  CURRENT_AGENT_FIFO="$stdout_fifo"
  CURRENT_AGENT_ERR_FIFO="$stderr_fifo"

  case "$-" in *m*) had_job_control=1;; esac
  tee "$stdout_file" < "$stdout_fifo" &
  CURRENT_TEE_PID=$!
  tee "$stderr_file" < "$stderr_fifo" >&2 &
  CURRENT_TEE_ERR_PID=$!

  if command -v setsid >/dev/null 2>&1; then
    setsid "${AGENT_COMMAND[@]}" > "$stdout_fifo" 2> "$stderr_fifo" &
  else
    set -m
    "${AGENT_COMMAND[@]}" > "$stdout_fifo" 2> "$stderr_fifo" &
    [ "$had_job_control" -eq 1 ] || set +m
  fi
  CURRENT_AGENT_PID=$!
  own_pgid="$(process_group_for_pid "$$")"
  CURRENT_AGENT_PGID=""
  while [ "$attempt" -lt 100 ]; do
    agent_pgid="$(process_group_for_pid "$CURRENT_AGENT_PID")"
    if [ -n "$agent_pgid" ] && [ "$agent_pgid" != "$own_pgid" ]; then
      CURRENT_AGENT_PGID="$agent_pgid"
      break
    fi
    if [ -z "$agent_pgid" ] && ! process_is_running "$CURRENT_AGENT_PID"; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if [ -z "$CURRENT_AGENT_PGID" ] && ! process_is_running "$CURRENT_AGENT_PID"; then
    CURRENT_AGENT_PGID="$CURRENT_AGENT_PID"
  fi
  if [ -z "$CURRENT_AGENT_PGID" ]; then
    echo "❌ No pude aislar el grupo de procesos del agente; detengo la corrida."
    kill -TERM "$CURRENT_AGENT_PID" 2>/dev/null || true
    return 70
  fi

  while [ "$agent_done" -eq 0 ] || [ "$tee_done" -eq 0 ] || [ "$tee_err_done" -eq 0 ]; do
    if [ "$agent_done" -eq 0 ] && ! process_is_running "$CURRENT_AGENT_PID"; then
      wait "$CURRENT_AGENT_PID" 2>/dev/null
      agent_rc=$?
      agent_done=1
      terminate_agent_group
    fi
    if [ "$tee_done" -eq 0 ] && ! process_is_running "$CURRENT_TEE_PID"; then
      wait "$CURRENT_TEE_PID" 2>/dev/null
      tee_rc=$?
      tee_done=1
      [ "$agent_done" -eq 1 ] || terminate_agent_group
    fi
    if [ "$tee_err_done" -eq 0 ] && ! process_is_running "$CURRENT_TEE_ERR_PID"; then
      wait "$CURRENT_TEE_ERR_PID" 2>/dev/null
      tee_err_rc=$?
      tee_err_done=1
      [ "$agent_done" -eq 1 ] || terminate_agent_group
    fi
    if [ "$agent_done" -eq 0 ] || [ "$tee_done" -eq 0 ] || [ "$tee_err_done" -eq 0 ]; then
      sleep 0.1
    fi
  done

  rm -f "$stdout_fifo" "$stderr_fifo"
  CURRENT_AGENT_PID=""
  CURRENT_AGENT_PGID=""
  CURRENT_AGENT_FIFO=""
  CURRENT_AGENT_ERR_FIFO=""
  CURRENT_TEE_PID=""
  CURRENT_TEE_ERR_PID=""
  [ "$tee_rc" -eq 0 ] || return 70
  [ "$tee_err_rc" -eq 0 ] || return 70
  return "$agent_rc"
}

build_codex_sandbox_config() {
  local REPO_ROOT git_root toml_git_root
  CODEX_SANDBOX_CONFIG_ARGS=(
    -c "model_reasoning_effort=\"$CODEX_EFFORT\""
    -c 'sandbox_workspace_write.network_access=true'
  )
  [ "$CODEX_SANDBOX" = "workspace-write" ] || return 0

  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "❌ No pude resolver la raíz del repo para habilitar .git en Codex." >&2
    return 70
  }
  git_root="$REPO_ROOT/.git"
  toml_git_root="$(jq -Rn --arg path "$git_root" '$path')" || {
    echo "❌ No pude escapar la ruta de .git para la configuración de Codex." >&2
    return 70
  }
  CODEX_SANDBOX_CONFIG_ARGS=(
    "${CODEX_SANDBOX_CONFIG_ARGS[@]}"
    -c "sandbox_workspace_write.writable_roots=[$toml_git_root]"
  )
}

prepare_agent_capture() {
  local kind="$1" stdout_suffix="$2"
  RUN_SEQUENCE=$((RUN_SEQUENCE + 1))
  AGENT_STDOUT="$RUN_DIR/${kind}-${RUN_SEQUENCE}.${stdout_suffix}"
  AGENT_STDERR="$RUN_DIR/${kind}-${RUN_SEQUENCE}.stderr.log"
  ADAPTER_RESULT_FILE="$RUN_DIR/${kind}-${RUN_SEQUENCE}.result.json"
  : > "$AGENT_STDOUT"
  : > "$AGENT_STDERR"
  : > "$ADAPTER_RESULT_FILE"
}

record_agent_log() {
  : > "$AGENT_LOG"
  cat "$AGENT_STDOUT" "$AGENT_STDERR" > "$AGENT_LOG" 2>/dev/null || true
}

write_adapter_result() {
  local retry_at_json="${ADAPTER_RETRY_AT:-null}"
  if [ "${ADAPTER_FINAL_MESSAGE_SET:-0}" -eq 1 ]; then
    jq -cn \
      --arg status "$ADAPTER_STATUS" \
      --arg limit_scope "$ADAPTER_LIMIT_SCOPE" \
      --arg final_message "$ADAPTER_FINAL_MESSAGE" \
      --argjson retry_at "$retry_at_json" \
      --argjson retryable "$ADAPTER_RETRYABLE" \
      --argjson exit_code "$ADAPTER_EXIT_CODE" \
      --arg error "${ADAPTER_ERROR:-}" \
      '{status: $status, retry_at: $retry_at, limit_scope: $limit_scope,
        retryable: $retryable, exit_code: $exit_code, final_message: $final_message,
        error: (if $error == "" then null else $error end)}' \
      > "$ADAPTER_RESULT_FILE"
  else
    jq -cn \
      --arg status "$ADAPTER_STATUS" \
      --arg limit_scope "$ADAPTER_LIMIT_SCOPE" \
      --argjson retry_at "$retry_at_json" \
      --argjson retryable "$ADAPTER_RETRYABLE" \
      --argjson exit_code "$ADAPTER_EXIT_CODE" \
      --arg error "${ADAPTER_ERROR:-}" \
      '{status: $status, retry_at: $retry_at, limit_scope: $limit_scope,
        retryable: $retryable, exit_code: $exit_code, final_message: null,
        error: (if $error == "" then null else $error end)}' \
      > "$ADAPTER_RESULT_FILE"
  fi
}

classify_adapter_failure() {
  local signal="${1:-}"
  ADAPTER_STATUS="unknown"
  ADAPTER_RETRY_AT="null"
  ADAPTER_LIMIT_SCOPE="unknown"
  ADAPTER_RETRYABLE=false
  ADAPTER_ERROR="agent failed without a recognized provider error signal"
  if [ -n "$signal" ]; then
    classify_provider_signal "$signal"
  fi
}

parse_codex_result() {
  local stdout_file="$1" stderr_file="$2" last_message_file="$3" process_rc="$4"
  local line event_type provider_signal="" invalid=0 completed=0 item_message=""
  local last_message=""
  ADAPTER_STATUS="failed"
  ADAPTER_RETRY_AT="null"
  ADAPTER_LIMIT_SCOPE="unknown"
  ADAPTER_RETRYABLE=false
  ADAPTER_ERROR=""
  ADAPTER_FINAL_MESSAGE=""
  ADAPTER_FINAL_MESSAGE_SET=0
  ADAPTER_EXIT_CODE="$process_rc"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line"; then
      invalid=1
      continue
    fi
    event_type="$(jq -r '.type // empty' <<<"$line")"
    case "$event_type" in
      turn.completed)
        if jq -e '.usage | type == "object"' >/dev/null 2>&1 <<<"$line"; then
          completed=1
        else
          invalid=1
        fi
        ;;
      turn.failed|error)
        provider_signal="$(provider_signal_from_event "$line" || true)"
        ;;
      item.completed)
        if jq -e '.item.type == "agent_message" and (.item.text | type == "string")' \
            >/dev/null 2>&1 <<<"$line"; then
          item_message="$(jq -r '.item.text' <<<"$line")"
        fi
        ;;
    esac
  done < "$stdout_file"

  if [ -s "$last_message_file" ]; then
    last_message="$(cat "$last_message_file")"
  elif [ -n "$item_message" ]; then
    last_message="$item_message"
  fi
  if [ -n "$last_message" ]; then
    ADAPTER_FINAL_MESSAGE="$last_message"
    ADAPTER_FINAL_MESSAGE_SET=1
  fi

  if [ -n "$provider_signal" ]; then
    classify_adapter_failure "$provider_signal"
  elif [ "$process_rc" -ne 0 ] || [ "$invalid" -ne 0 ] || [ "$completed" -ne 1 ] \
      || [ "$ADAPTER_FINAL_MESSAGE_SET" -ne 1 ]; then
    if [ "$process_rc" -ne 0 ]; then
      classify_adapter_failure
    else
      ADAPTER_STATUS="failed"
      ADAPTER_ERROR="Codex output did not contain a valid terminal event"
    fi
  else
    ADAPTER_STATUS="ok"
    ADAPTER_RETRYABLE=false
    ADAPTER_LIMIT_SCOPE="unknown"
    ADAPTER_RETRY_AT="null"
    ADAPTER_ERROR=""
  fi
  write_adapter_result
}

parse_claude_result() {
  local stdout_file="$1" stderr_file="$2" process_rc="$3"
  local result_json="" subtype="" is_error="false" provider_signal="" result_present=0
  ADAPTER_STATUS="failed"
  ADAPTER_RETRY_AT="null"
  ADAPTER_LIMIT_SCOPE="unknown"
  ADAPTER_RETRYABLE=false
  ADAPTER_ERROR=""
  ADAPTER_FINAL_MESSAGE=""
  ADAPTER_FINAL_MESSAGE_SET=0
  ADAPTER_EXIT_CODE="$process_rc"

  if result_json="$(jq -s -c -e \
      'if length == 1 and (.[0] | type == "object") then .[0] else error("one JSON object required") end' \
      "$stdout_file" 2>/dev/null)"; then
    if jq -e '.type == "result" and (.result | type == "string" and length > 0)' \
        >/dev/null 2>&1 <<<"$result_json"; then
      result_present=1
      ADAPTER_FINAL_MESSAGE="$(jq -r '.result' <<<"$result_json")"
      ADAPTER_FINAL_MESSAGE_SET=1
    fi
    subtype="$(jq -r '.subtype // ""' <<<"$result_json")"
    is_error="$(jq -r '(.is_error // false)' <<<"$result_json")"
    provider_signal="$(provider_signal_from_event "$result_json" || true)"
  fi

  if [ "$process_rc" -ne 0 ] || [ "$result_present" -ne 1 ] \
      || [ "$subtype" != "success" ] || [ "$is_error" != "false" ]; then
    if [ -n "$provider_signal" ]; then
      classify_adapter_failure "$provider_signal"
    elif [ "$process_rc" -ne 0 ]; then
      classify_adapter_failure
    else
      ADAPTER_STATUS="failed"
      ADAPTER_ERROR="Claude output did not contain a valid successful result"
    fi
  else
    ADAPTER_STATUS="ok"
    ADAPTER_RETRYABLE=false
    ADAPTER_LIMIT_SCOPE="unknown"
    ADAPTER_RETRY_AT="null"
    ADAPTER_ERROR=""
  fi
  write_adapter_result
}

finish_adapter() {
  case "$ADAPTER_STATUS" in
    ok) return 0 ;;
    rate_limited)
      RESET_EPOCH=""
      [ "$ADAPTER_RETRY_AT" != "null" ] && RESET_EPOCH="$ADAPTER_RETRY_AT"
      LIMIT_ERROR="${ADAPTER_ERROR:-provider rate limit}"
      LIMIT_KIND="${ADAPTER_LIMIT_SCOPE:-unknown}"
      return "$LIMIT_RETRY_RC"
      ;;
    auth_error)
      return "$AUTH_ERROR_RC"
      ;;
    config_error)
      return "$CONFIG_ERROR_RC"
      ;;
    *)
      [ "$ADAPTER_EXIT_CODE" -ne 0 ] && return "$ADAPTER_EXIT_CODE"
      return 70
      ;;
  esac
}

run_codex() {
  local prompt="$1" process_rc
  : > "$AGENT_LOG"; : > "$LAST_MSG"
  prepare_agent_capture codex stdout.jsonl
  build_codex_sandbox_config || return $?
  AGENT_COMMAND=(
    codex exec
    --json
    --model "$CODEX_MODEL"
    "${CODEX_SANDBOX_CONFIG_ARGS[@]}"
    --sandbox "$CODEX_SANDBOX"
    --skip-git-repo-check
    -o "$LAST_MSG"
    "$prompt"
  )
  run_agent_group "$AGENT_STDOUT" "$AGENT_STDERR"
  process_rc=$?
  record_agent_log
  if [ "$process_rc" -eq 70 ]; then
    ADAPTER_STATUS="failed"
    ADAPTER_RETRY_AT="null"
    ADAPTER_LIMIT_SCOPE="unknown"
    ADAPTER_RETRYABLE=false
    ADAPTER_FINAL_MESSAGE=""
    ADAPTER_FINAL_MESSAGE_SET=0
    ADAPTER_EXIT_CODE="$process_rc"
    ADAPTER_ERROR="agent capture failed"
    write_adapter_result
    return "$process_rc"
  fi
  parse_codex_result "$AGENT_STDOUT" "$AGENT_STDERR" "$LAST_MSG" "$process_rc"
  finish_adapter
}

run_claude() {
  local prompt="$1" process_rc
  : > "$AGENT_LOG"; : > "$LAST_MSG"
  prepare_agent_capture claude stdout.json
  AGENT_COMMAND=(
    claude
    --model "$CLAUDE_MODEL"
    --dangerously-skip-permissions
    --print
    --output-format json
    "$prompt"
  )
  run_agent_group "$AGENT_STDOUT" "$AGENT_STDERR"
  process_rc=$?
  record_agent_log
  if [ "$process_rc" -eq 70 ]; then
    ADAPTER_STATUS="failed"
    ADAPTER_RETRY_AT="null"
    ADAPTER_LIMIT_SCOPE="unknown"
    ADAPTER_RETRYABLE=false
    ADAPTER_FINAL_MESSAGE=""
    ADAPTER_FINAL_MESSAGE_SET=0
    ADAPTER_EXIT_CODE="$process_rc"
    ADAPTER_ERROR="agent capture failed"
    write_adapter_result
    return "$process_rc"
  fi
  parse_claude_result "$AGENT_STDOUT" "$AGENT_STDERR" "$process_rc"
  finish_adapter
}

run_sandbox_preflight() {
  local probe_error
  [ "$DRY_RUN" = "1" ] && return 0
  [ "$CODEX_SANDBOX" = "danger-full-access" ] && return 0

  build_codex_sandbox_config || return $?
  if ! codex sandbox "${CODEX_SANDBOX_CONFIG_ARGS[@]}" \
      -c "sandbox_mode=\"$CODEX_SANDBOX\"" --help >/dev/null 2>&1; then
    echo "⚠️  codex sandbox no está disponible en esta plataforma; omito la sonda de escritura de .git."
    return 0
  fi

  if probe_error="$(codex sandbox "${CODEX_SANDBOX_CONFIG_ARGS[@]}" \
      -c "sandbox_mode=\"$CODEX_SANDBOX\"" -- \
      sh -c 'touch .git/.ralph-probe && rm .git/.ralph-probe' 2>&1)"; then
    return 0
  fi
  if printf '%s\n' "$probe_error" | grep -Eqi \
      'only available on (linux|macos|darwin|windows)|(linux|macos|darwin|windows) (sandbox )?(is )?(not supported|unsupported)|not supported on (this|your) (platform|operating system)|unsupported (platform|operating system)|unknown (command|subcommand)|unrecognized (command|subcommand)|no such command'; then
    echo "⚠️  codex sandbox no está disponible en esta plataforma; omito la sonda de escritura de .git."
    return 0
  fi

  printf '❌ El sandbox configurado (%s) no permite escribir .git; la sonda de preflight falló.\n' \
    "$CODEX_SANDBOX" >&2
  printf '   Corregí la versión de codex y verificá que sandbox_mode="%s" (RALPH_CODEX_SANDBOX) esté soportado; ralph configura writable_roots automáticamente.\n' \
    "$CODEX_SANDBOX" >&2
  [ -n "$probe_error" ] && printf '   Detalle: %s\n' "$probe_error" >&2
  return 1
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

checkout_or_fail() {
  local branch="$1"
  if git checkout "$branch" >/dev/null 2>&1; then
    return 0
  fi
  echo "❌ No pude hacer checkout de '$branch'; detengo la corrida."
  return 70
}

verify_reviewed_head() {
  local pr="$1" expected_sha="$2" local_sha remote_sha
  local_sha="$(git rev-parse HEAD 2>/dev/null)" || {
    echo "❌ No pude leer HEAD local; detengo la corrida."
    return 70
  }
  remote_sha="$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null)" || {
    echo "❌ No pude leer headRefOid del PR #$pr; detengo la corrida."
    return 70
  }
  if [ "$local_sha" != "$expected_sha" ] || [ "$remote_sha" != "$expected_sha" ]; then
    echo "❌ head_changed: el SHA revisado ya no coincide con HEAD local o headRefOid."
    return 70
  fi
  return 0
}

# Pone la rama al día con la base antes de cada revisión, para que el revisor
# vea lo que de verdad se va a mergear. Siempre con merge, nunca rebase: Codex
# trabaja sobre esta rama y el merge final es --squash. Si hay conflictos los
# resuelve Codex (sin consumir ronda de revisión); si no lo logra, el PR queda
# para un humano. Devuelve: 0 al día · 70 fallo fatal · 8 señal estructurada
# de tope del proveedor.
update_branch_with_base() {
  local branch="$1" pr="$2" rc conflicted
  if ! git fetch -q origin "$BASE_BRANCH" >/dev/null 2>&1; then
    echo "❌ No pude traer '$BASE_BRANCH'; conservo el estado y detengo la corrida."
    return 70
  fi
  if git merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD; then
    return 0
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      echo "❌ No pude comprobar la relación entre '$branch' y '$BASE_BRANCH'; detengo la corrida."
      return 70
    fi
  fi
  echo "🔄 Pongo $branch al día con $BASE_BRANCH..."
  if git merge --no-edit "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    if ! git push -q origin "$branch" >/dev/null 2>&1; then
      echo "❌ No pude publicar $branch; conservo el estado y detengo la corrida."
      return 70
    fi
    return 0
  fi
  conflicted="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  if [ -z "$conflicted" ]; then
    echo "❌ El merge de '$BASE_BRANCH' falló sin dejar conflictos identificables; conservo el estado y detengo la corrida."
    return 70
  fi
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
    if ! git merge --abort >/dev/null 2>&1; then
      echo "⚠️  No pude abortar el merge; conservo el árbol en conflicto para recuperación manual."
    fi
    if [ "$rc" -ne 8 ] && [ "$rc" -ne 9 ]; then
      add_label "$pr" "$NEEDS_HUMAN_LABEL"
      gh pr comment "$pr" --body "🤖 Ralph no pudo resolver los conflictos con \`$BASE_BRANCH\`: el PR queda para un humano." >/dev/null 2>&1 || true
    fi
    return "$rc"
  fi
  if [ -n "$(git status --porcelain)" ] || ! git merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD; then
    if ! git merge --abort >/dev/null 2>&1; then
      echo "⚠️  No pude abortar el merge; conservo el árbol en conflicto para recuperación manual."
    fi
    echo "🙋 Codex no resolvió los conflictos con $BASE_BRANCH. PR #$pr queda para un humano."
    add_label "$pr" "$NEEDS_HUMAN_LABEL"
    gh pr comment "$pr" --body "🤖 Ralph no pudo poner la rama al día con \`$BASE_BRANCH\`: conflictos sin resolver en $conflicted. Necesita un humano." >/dev/null 2>&1 || true
    return 70
  fi
  if ! git push -q origin "$branch" >/dev/null 2>&1; then
    echo "❌ No pude publicar $branch; conservo el estado y detengo la corrida."
    return 70
  fi
  return 0
}

# Revisa todos los checks obligatorios del SHA exacto que Claude vio. Devuelve
# 0 si cada uno terminó en success, 1 si alguno terminó en un estado distinto,
# y 2 si alguno está ausente, pendiente o la API no responde. Los estados
# auxiliares quedan en variables globales para distinguir rechazo de espera.
check_required_checks() {
  local reviewed_sha="$1"
  local check_runs_pages statuses_pages check_runs statuses results_json
  local required state failed pending missing

  REQUIRED_CHECKS_STATE="infrastructure"
  REQUIRED_CHECKS_FAILURES=""
  check_runs_pages="$(gh api --paginate \
    "repos/$REPO_SLUG/commits/$reviewed_sha/check-runs" 2>/dev/null | \
    jq -s -c '[.[] | .check_runs[]?]' 2>/dev/null)" || return 2
  statuses_pages="$(gh api --paginate \
    "repos/$REPO_SLUG/commits/$reviewed_sha/statuses" 2>/dev/null | \
    jq -s -c '
      [.[][]?] |
      reduce .[] as $status
        ([];
         if any(.[]; .context == $status.context) then .
         else . + [$status]
         end)
    ' 2>/dev/null)" || return 2
  check_runs="$check_runs_pages"
  statuses="$statuses_pages"
  results_json="$(jq -cn --argjson check_runs "$check_runs" --argjson statuses "$statuses" \
    '{check_runs: $check_runs, statuses: $statuses}' 2>/dev/null)" || return 2

  if [ -z "$REQUIRED_CHECKS_JSON" ]; then
    state="$(jq -r --arg sha "$reviewed_sha" '
      ([.check_runs[]? | select(.head_sha == $sha) |
        {state: ((.conclusion // "") | ascii_downcase)}] +
       [.statuses[]? | select(.sha == $sha) |
        {state: ((.state // "") | ascii_downcase)}]) as $results |
      if ($results | length) == 0 then
        "missing"
      elif any($results[]; .state == "" or .state == "queued" or
               .state == "in_progress" or .state == "pending") then
        "pending"
      elif all($results[]; .state == "success") then
        "success"
      else
        "failure"
      end
    ' <<<"$results_json" 2>/dev/null)" || return 2
    case "$state" in
      success)
        REQUIRED_CHECKS_STATE="success"
        return 0
        ;;
      failure)
        REQUIRED_CHECKS_STATE="failure"
        REQUIRED_CHECKS_FAILURES="check reportado sin éxito"
        return 1
        ;;
      pending)
        REQUIRED_CHECKS_STATE="pending"
        return 2
        ;;
      missing)
        REQUIRED_CHECKS_STATE="missing"
        return 2
        ;;
      *) return 2 ;;
    esac
  fi

  failed=0
  pending=0
  missing=0
  while IFS= read -r required; do
    [ -n "$required" ] || continue
    state="$(jq -r --arg name "$required" --arg sha "$reviewed_sha" '
      ([.check_runs[]? | select(.name == $name and .head_sha == $sha)]) as $runs |
      ([.statuses[]? | select(.context == $name and .sha == $sha)]) as $statuses |
      if any($runs[]?; ((.conclusion // "") | ascii_downcase) == "success") or
         any($statuses[]?; ((.state // "") | ascii_downcase) == "success") then
        "success"
      elif any($runs[]?; ((.conclusion // "") | ascii_downcase) != "") or
           any($statuses[]?; ((.state // "") | ascii_downcase) != "") then
        "failure"
      elif ($runs | length) > 0 or ($statuses | length) > 0 then
        "pending"
      else
        "missing"
      end
    ' <<<"$results_json" 2>/dev/null)" || return 2
    case "$state" in
      success) ;;
      failure)
        failed=1
        REQUIRED_CHECKS_FAILURES="${REQUIRED_CHECKS_FAILURES}${REQUIRED_CHECKS_FAILURES:+, }$required"
        ;;
      pending) pending=1 ;;
      missing) missing=1 ;;
      *) return 2 ;;
    esac
  done < <(jq -r '.[]' <<<"$REQUIRED_CHECKS_JSON")

  if [ "$failed" -eq 1 ]; then
    REQUIRED_CHECKS_STATE="failure"
    return 1
  fi
  if [ "$missing" -eq 1 ]; then
    REQUIRED_CHECKS_STATE="missing"
    return 2
  fi
  if [ "$pending" -eq 1 ]; then
    REQUIRED_CHECKS_STATE="pending"
    return 2
  fi
  REQUIRED_CHECKS_STATE="success"
  return 0
}

verify_distinct_review() {
  local pr="$1" reviewed_sha="$2" reviews check_runs statuses
  if [ -z "$REVIEW_IDENTITY" ] || [ "$REVIEW_IDENTITY" = "$MERGE_IDENTITY" ]; then
    return 0
  fi

  reviews="$(gh api --paginate "repos/$REPO_SLUG/pulls/$pr/reviews" 2>/dev/null | \
    jq -s -c 'add' 2>/dev/null)" || return 2
  if jq -e --arg identity "$REVIEW_IDENTITY" --arg sha "$reviewed_sha" '
      ([.[] | select((.user.login // "") == $identity and
        (.commit_id // "") == $sha)] | last) as $review |
        (($review.state // "") | ascii_upcase) == "APPROVED"' <<<"$reviews" >/dev/null; then
    return 0
  fi

  check_runs="$(gh api --paginate \
    "repos/$REPO_SLUG/commits/$reviewed_sha/check-runs" 2>/dev/null | \
    jq -s -c '[.[] | .check_runs[]?]' 2>/dev/null)" || return 2
  statuses="$(gh api --paginate \
    "repos/$REPO_SLUG/commits/$reviewed_sha/statuses" 2>/dev/null | \
    jq -s -c 'add' 2>/dev/null)" || return 2
  if jq -e --arg identity "$REVIEW_IDENTITY" --arg sha "$reviewed_sha" '
      any(.[]; .name == "ralph-review" and .head_sha == $sha and
        (.status // "") == "completed" and (.conclusion // "") == "success" and
        ((.creator.login // .app.slug // .app.name // .author.login // "") == $identity))' \
      <<<"$check_runs" >/dev/null ||
      jq -e --arg identity "$REVIEW_IDENTITY" --arg sha "$reviewed_sha" '
      any(.[]; .context == "ralph-review" and .sha == $sha and
        ((.state // "") | ascii_downcase) == "success" and
        ((.creator.login // "") == $identity))' <<<"$statuses" >/dev/null; then
    return 0
  fi

  echo "❌ La identidad revisora '$REVIEW_IDENTITY' no aprobó el SHA $reviewed_sha ni emitió un check ralph-review válido; no se mergea." >&2
  return 1
}

# CI verde es condición de merge además del PASS. Devuelve 0 si los checks
# pasan, 1 si hay un fallo real (tras dejar en el PR el ítem que Codex debe
# corregir), y 2 si la ausencia o el estado de CI sigue pendiente.
wait_for_ci() {
  local pr="$1" branch="$2" reviewed_sha="${3:-}" run_url started now deadline checks_rc pending_reason remaining

  if [ "$CI_POLICY" = "none" ]; then
    echo "⚠️  CI sin checks: política RALPH_CI_POLICY=none explícita; continúo sin esa garantía."
    return 0
  fi

  started="$(date +%s 2>/dev/null)" || return 2
  deadline=$((started + CI_TIMEOUT_SECONDS))
  while :; do
    check_required_checks "$reviewed_sha"
    checks_rc=$?
    if [ "$checks_rc" -eq 0 ]; then
      return 0
    elif [ "$checks_rc" -eq 1 ]; then
      run_url="$(gh run list --branch "$branch" --limit 1 --json url --jq '.[0].url' 2>/dev/null)"
      if [ -n "$REQUIRED_CHECKS_JSON" ]; then
        echo "🔴 CI obligatorio en rojo en PR #$pr: ${REQUIRED_CHECKS_FAILURES:-check sin éxito} (${run_url:-sin URL del run})"
        gh pr comment "$pr" --body "1. CI obligatorio en rojo: ${REQUIRED_CHECKS_FAILURES:-check sin éxito}; reproducir con la suite en base virgen y corregir." >/dev/null 2>&1 || true
      else
        echo "🔴 CI en rojo en PR #$pr: ${run_url:-sin URL del run}"
        gh pr comment "$pr" --body "1. CI en rojo: ${run_url:-ver la pestaña Checks del PR}; reproducir con la suite en base virgen y corregir." >/dev/null 2>&1 || true
      fi
      return 1
    else
      case "$REQUIRED_CHECKS_STATE" in
        missing)
          if [ -n "$REQUIRED_CHECKS_JSON" ]; then
            pending_reason="CI obligatorio ausente"
          else
            pending_reason="CI ausente"
          fi
          ;;
        pending)
          if [ -n "$REQUIRED_CHECKS_JSON" ]; then
            pending_reason="CI obligatorio pendiente"
          else
            pending_reason="CI pendiente"
          fi
          ;;
        *)
          if [ -n "$REQUIRED_CHECKS_JSON" ]; then
            pending_reason="CI obligatorio pendiente por infraestructura"
          else
            pending_reason="CI pendiente por infraestructura"
          fi
          ;;
      esac
    fi

    now="$(date +%s 2>/dev/null)" || return 2
    if [ "$now" -ge "$deadline" ]; then
      echo "⚠️  $pending_reason en PR #$pr; estado ci_pending, sin merge."
      return 2
    fi
    remaining=$((deadline - now))
    sleep $(( remaining > 30 ? 30 : remaining ))
  done
}

# gh pr merge puede aceptar un merge encolado sin que el PR esté mergeado aún.
# Sólo un estado MERGED con un OID SHA válido habilita borrar la rama y avanzar.
# Devuelve 0 confirmado · 2 merge_pending · 70 fallo de infraestructura.
wait_for_merge() {
  local pr="$1" started now deadline remaining merge_result merge_state merge_oid

  MERGED_SHA=""
  started="$(date +%s 2>/dev/null)" || return 70
  deadline=$((started + MERGE_TIMEOUT_SECONDS))
  while :; do
    merge_result="$(gh pr view "$pr" --json state,mergeCommit \
      --jq '.state + "\t" + (.mergeCommit.oid // "")' 2>/dev/null)" || {
      echo "❌ No pude consultar el estado de merge del PR #$pr; detengo la corrida."
      return 70
    }
    merge_state="${merge_result%%$'\t'*}"
    merge_oid="${merge_result#*$'\t'}"
    if [ "$merge_state" = "MERGED" ] &&
       printf '%s\n' "$merge_oid" | grep -Eq '^[0-9a-fA-F]{40}$'; then
      MERGED_SHA="$merge_oid"
      return 0
    fi

    now="$(date +%s 2>/dev/null)" || return 70
    if [ "$now" -ge "$deadline" ]; then
      echo "⚠️  PR #$pr sigue sin merge confirmado; estado merge_pending, sin borrar rama ni cerrar issue."
      return 2
    fi
    remaining=$((deadline - now))
    sleep $(( remaining > 30 ? 30 : remaining ))
  done
}

# ------------------------------------------------------------ ciclo por issue --

# Procesa UN issue: implementación por Codex, revisión por Claude, hasta
# MAX_ROUNDS. Devuelve: 0 normal · 8 tope estructurado · códigos privados para
# auth/config · código del agente ante unknown o fallo de infraestructura.
process_issue() {
  local num="$1"
  local branch="${BRANCH_PREFIX}${num}"
  local rc issue_ctx commits pr round verdict comments prior_work reviewed_sha
  local infra_retries comments_before comments_after backoff merged_sha ci_ok ci_rc review_rc
  local remote_delete_error

  CURRENT_ISSUE="$num"
  CURRENT_PHASE="preparación"
  echo ""
  echo "════ Issue #$num ($branch) ════"

  # Idempotencia: si la rama ya existe (corrida anterior interrumpida) la
  # reutilizamos. Recrearla con 'checkout -B' descartaría ese trabajo.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    checkout_or_fail "$branch" || return 70
    prior_work="$(git log --oneline "$BASE_BRANCH..$branch" 2>/dev/null)"
  else
    if ! git checkout -b "$branch" "$BASE_BRANCH" >/dev/null 2>&1; then
      echo "❌ No pude crear y hacer checkout de '$branch'; detengo la corrida."
      return 70
    fi
    prior_work=""
  fi

  pr="$(pr_for_branch "$branch")"

  # Un PR ya marcado para humano no se vuelve a tocar: agotó sus rondas.
  if [ -n "$pr" ] && gh pr view "$pr" --json labels --jq '.labels[].name' 2>/dev/null \
       | grep -qx "$NEEDS_HUMAN_LABEL"; then
    echo "🙋 PR #$pr espera revisión humana; no lo toco."
    checkout_or_fail "$BASE_BRANCH" || return 70
    return 0
  fi

  # Contexto mínimo: SOLO este issue (cuerpo + comentarios) y los últimos commits.
  issue_ctx="$(gh issue view "$num" --json number,title,body,comments)"
  commits="$(git log -n 5 --format='%H%n%ad%n%B---' --date=short "$BASE_BRANCH" 2>/dev/null || echo 'No commits found')"

  # ---- Fase 1: implementación (se salta si ya hay PR abierto) ----
  if [ -z "$pr" ]; then
    CURRENT_PHASE="implementación"
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
    if [ "$rc" -ge 128 ]; then
      echo "❌ Codex terminó por señal (rc=$rc): fallo de infraestructura del issue #$num."
    fi
    [ "$rc" -ne 0 ] && return "$rc"

    # El agente debe dejar el trabajo commiteado. Preservamos el árbol para
    # recuperación manual, pero nunca fabricamos un commit por él.
    if [ -n "$(git status --porcelain)" ]; then
      echo "❌ Codex dejó cambios sin commitear; conservo el estado y detengo la corrida."
      return 70
    fi

    pr="$(pr_for_branch "$branch")"
    if [ -z "$pr" ]; then
      echo "⚠️  Codex no dejó PR abierto para #$num. Branch preservado, sin merge."
      checkout_or_fail "$BASE_BRANCH" || return 70
      return 0
    fi
    echo "📬 PR #$pr abierto."
  else
    echo "♻️  PR #$pr ya existe; voy directo a revisión."
  fi

  # ---- Fase 2: revisión, hasta MAX_ROUNDS ----
  CURRENT_PHASE="revisión"
  round=1
  infra_retries=0
  while [ "$round" -le "$MAX_ROUNDS" ]; do
    update_branch_with_base "$branch" "$pr"
    rc=$?
    if [ "$rc" -ge 128 ]; then
      echo "❌ Codex terminó por señal (rc=$rc): fallo de infraestructura del issue #$num."
    fi
    [ "$rc" -ne 0 ] && return "$rc"

    reviewed_sha="$(git rev-parse HEAD 2>/dev/null)" || {
      echo "❌ No pude capturar el SHA a revisar; detengo la corrida."
      return 70
    }
    verify_reviewed_head "$pr" "$reviewed_sha"
    rc=$?
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
    verdict="$(printf '%s\n' "$ADAPTER_FINAL_MESSAGE" | tail -n 1 | \
      grep -xE '<verdict>(PASS|CHANGES_REQUESTED)</verdict>' || true)"

    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -ne 8 ] && [ "$rc" -ne 9 ]; then
        echo "❌ Claude terminó con rc=$rc; #$num queda abierto sin merge."
      fi
      return "$rc"
    fi
    # PASS con CI en rojo no mergea: wait_for_ci deja el ítem en el PR y se
    # cae a la Fase 3 como con cualquier CHANGES_REQUESTED.
    ci_ok=0
    if [ "$verdict" = "<verdict>PASS</verdict>" ]; then
      verify_reviewed_head "$pr" "$reviewed_sha"
      rc=$?
      [ "$rc" -ne 0 ] && return "$rc"
      verify_distinct_review "$pr" "$reviewed_sha"
      review_rc=$?
      if [ "$review_rc" -eq 2 ]; then
        echo "❌ No pude verificar la identidad revisora para el SHA $reviewed_sha; detengo la corrida."
        return 70
      elif [ "$review_rc" -ne 0 ]; then
        checkout_or_fail "$BASE_BRANCH" || return 70
        return 0
      fi
      echo "✅ PASS en la ronda $round. Espero CI de PR #$pr..."
      wait_for_ci "$pr" "$branch" "$reviewed_sha"
      ci_rc=$?
      if [ "$ci_rc" -eq 0 ]; then
        ci_ok=1
      elif [ "$ci_rc" -eq 2 ]; then
        checkout_or_fail "$BASE_BRANCH" || return 70
        return 0
      fi
    fi
    if [ "$ci_ok" -eq 1 ]; then
      if [ -n "$(git status --porcelain)" ]; then
        echo "❌ El árbol cambió después de la revisión; detengo la corrida."
        return 70
      fi
      verify_reviewed_head "$pr" "$reviewed_sha"
      rc=$?
      [ "$rc" -ne 0 ] && return "$rc"
      echo "🟢 CI verde. Mergeo PR #$pr."
      checkout_or_fail "$BASE_BRANCH" || return 70
      if gh pr merge "$pr" "$MERGE_METHOD" \
          --match-head-commit "$reviewed_sha" >/dev/null 2>&1; then
        wait_for_merge "$pr"
        rc=$?
        if [ "$rc" -eq 2 ]; then
          if [ "$MERGE_PENDING_POLICY" = "stop" ]; then
            checkout_or_fail "$BASE_BRANCH" || return 70
            write_checkpoint "merge_pending para el PR #$pr; la corrida se detiene sin borrar la rama ni cerrar el issue."
            exit 0
          fi
          checkout_or_fail "$BASE_BRANCH" || return 70
          return 0
        elif [ "$rc" -ne 0 ]; then
          return "$rc"
        fi
        merged_sha="$MERGED_SHA"
        remote_delete_error=""
        if ! remote_delete_error="$(gh api --method DELETE \
            "repos/$REPO_SLUG/git/refs/heads/$branch" 2>&1)"; then
          case "$remote_delete_error" in
            *"Reference does not exist"*"HTTP 422"*) : ;;
            *)
              echo "❌ No pude borrar la rama remota '$branch' después de confirmar el merge; detengo la corrida."
              return 70
              ;;
          esac
        fi
        if ! git branch -D "$branch" >/dev/null 2>&1; then
          echo "❌ No pude borrar la rama local '$branch' después de confirmar el merge; detengo la corrida."
          return 70
        fi
        # La base local debe traer el merge: los issues dependientes heredan ese código.
        if ! git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1; then
          echo "❌ No pude actualizar '$BASE_BRANCH' local con --ff-only; conservo el estado y detengo la corrida."
          return 70
        fi
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
          checkout_or_fail "$BASE_BRANCH" || return 70
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
      checkout_or_fail "$BASE_BRANCH" || return 70
      return 0
    fi

    # ---- Fase 3: Codex atiende los comentarios ----
    CURRENT_PHASE="corrección"
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
    if [ "$rc" -ge 128 ]; then
      echo "❌ Codex terminó por señal (rc=$rc): fallo de infraestructura del issue #$num."
    fi
    [ "$rc" -ne 0 ] && return "$rc"

    # Las correcciones también deben llegar commiteadas por Codex; preservar
    # cambios sin commit es preferible a inventar historia o perderlos.
    if [ -n "$(git status --porcelain)" ]; then
      echo "❌ Codex dejó cambios sin commitear; conservo el estado y detengo la corrida."
      return 70
    fi
    if ! git push -q origin "$branch" >/dev/null 2>&1; then
      echo "❌ No pude publicar $branch; conservo el estado y detengo la corrida."
      return 70
    fi

    round=$((round + 1))
  done

  checkout_or_fail "$BASE_BRANCH" || return 70
  return 0
}

# --------------------------------------------------------------- selector --

refs_csv() {
  local refs="${1:-}" ref result=""
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    [ -n "$result" ] && result="$result,"
    result="$result$ref"
  done <<EOF
$refs
EOF
  [ -n "$result" ] && printf '%s' "$result" || printf '%s' "none"
}

pr_needs_human() {
  local pr="$1" labels
  [ -z "$pr" ] && return 1
  labels="$(gh pr view "$pr" --json labels --jq '.labels[].name' 2>/dev/null || true)"
  printf '%s\n' "$labels" | grep -Fqx "$NEEDS_HUMAN_LABEL"
}

print_plan_issue() {
  local num="$1" priority="$2" parents="$3" blockers="$4" needs_human="$5" pr="$6" exclusion="$7"
  local pr_text="${pr:-none}"
  printf '#%s priority=%s host=%s parents=%s blockers=%s needs-human=%s pr=%s' \
    "$num" "$priority" "$REPO_HOST" "$(refs_csv "$parents")" \
    "$(refs_csv "$blockers")" "$needs_human" "$pr_text"
  [ -n "$exclusion" ] && printf ' excluded=%s' "$exclusion"
  printf '\n'
}

# Selecciona issues y, en modo plan, describe exactamente las mismas decisiones
# sin checkout, agentes, labels, push ni merge. El modo normal conserva el ciclo
# de pasadas para que un blocker cerrado durante la corrida desbloquee a otro.
select_issues() {
  local mode="$1"
  local attempted=" " progress=1 numbers n num priority parents blockers open_blockers
  local epics p b state pr needs_human exclusion rc blocked_by_error

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

    priority=0
    for num in $numbers; do
      priority=$((priority + 1))
      parents="$(printf '%s' "${BODY[$num]}" | section_refs 'Parent')"
      blockers="$(printf '%s' "${BODY[$num]}" | section_refs 'Blocked by')"
      blocked_by_error="$(printf '%s' "${BODY[$num]}" | validate_blocked_by)"
      open_blockers=""
      for b in $blockers; do
        [ -n "${CLOSED_BLOCKER[$b]:-}" ] && continue
        state="$(gh issue view "$b" --json state --jq '.state' 2>/dev/null || echo OPEN)"
        if [ "$state" = "CLOSED" ]; then
          CLOSED_BLOCKER[$b]=1
        else
          [ -n "$open_blockers" ] && open_blockers="$open_blockers"$'\n'
          open_blockers="${open_blockers}${b}"
        fi
      done

      pr="$(pr_for_branch "${BRANCH_PREFIX}${num}")"
      needs_human=no
      pr_needs_human "$pr" && needs_human=yes

      if [ -n "$blocked_by_error" ]; then
        echo "🚫 #$num bloqueado: formato inválido en ## Blocked by: $blocked_by_error"
        if [ "$mode" = "plan" ]; then
          print_plan_issue "$num" "$priority" "$parents" "$blockers" \
            "$needs_human" "$pr" "invalid-blocked-by"
        fi
        continue
      fi

      if [ "$mode" = "plan" ]; then
        exclusion=""
        case "$epics" in *" $num "*) exclusion="parent";; esac
        [ -n "$exclusion" ] || if [ -n "$open_blockers" ]; then
          exclusion="blocked-by:$(refs_csv "$open_blockers")"
        fi
        [ -n "$exclusion" ] || if [ "$needs_human" = yes ]; then
          exclusion="needs-human"
        fi
        print_plan_issue "$num" "$priority" "$parents" "$blockers" \
          "$needs_human" "$pr" "$exclusion"
        continue
      fi

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
      if [ -n "$open_blockers" ]; then
        echo "⏭️  #$num bloqueado por dependencias abiertas, lo salto por ahora."
        continue
      fi
      if [ "$needs_human" = yes ]; then
        echo "🙋 PR #$pr espera revisión humana; no lo toco."
        continue
      fi

      # Los topes sólo reintentan este issue y tienen un techo global por issue.
      # Un reset fiable puede demorar el reintento, pero nunca se inventa una
      # espera cuando el proveedor no entregó retry_at.
      limit_retries=0
      while :; do
        process_issue "$num"
        rc=$?
        if [ "$rc" -eq "$LIMIT_RETRY_RC" ] && [ "$ADAPTER_STATUS" = "rate_limited" ]; then
          if [ "$limit_retries" -ge "$MAX_LIMIT_RETRIES" ]; then
            echo "🛑 Tope del proveedor: máximo $MAX_LIMIT_RETRIES reintentos para #$num; guardo contexto."
            write_checkpoint "tope del proveedor agotó el máximo de $MAX_LIMIT_RETRIES reintentos para #$num (${LIMIT_ERROR:-sin detalle})."
            exit 0
          fi
          limit_retries=$((limit_retries + 1))
          if [ -n "$DEADLINE_EPOCH" ]; then
            now="$(date +%s)" || exit 1
            if [ "$now" -ge "$DEADLINE_EPOCH" ]; then
              echo "🛑 Deadline global alcanzado; no reintento #$num."
              write_checkpoint "deadline global alcanzado antes del reintento de #$num."
              exit 0
            fi
          fi
          wait_for_reset "$num"
          wait_rc=$?
          if [ "$wait_rc" -eq 2 ]; then
            write_checkpoint "deadline global alcanzado antes del reset del proveedor para #$num."
            exit 0
          elif [ "$wait_rc" -ne 0 ]; then
            echo "❌ No pude esperar el reset del proveedor; detengo la corrida."
            exit 1
          fi
          continue   # reintenta el MISMO issue
        elif [ "$rc" -eq "$AUTH_ERROR_RC" ] && [ "$ADAPTER_STATUS" = "auth_error" ]; then
          echo "❌ auth_error del proveedor: ${ADAPTER_ERROR:-sin detalle}. Detengo la corrida."
          write_checkpoint "auth_error del proveedor para #$num: ${ADAPTER_ERROR:-sin detalle}."
          exit 1
        elif [ "$rc" -eq "$CONFIG_ERROR_RC" ] && [ "$ADAPTER_STATUS" = "config_error" ]; then
          echo "❌ config_error del proveedor: ${ADAPTER_ERROR:-sin detalle}. Detengo la corrida."
          write_checkpoint "config_error del proveedor para #$num: ${ADAPTER_ERROR:-sin detalle}."
          exit 1
        elif [ "$ADAPTER_STATUS" = "unknown" ]; then
          echo "❌ unknown del proveedor: ${ADAPTER_ERROR:-sin detalle}. No espero ni reintento."
          exit "$rc"
        elif [ "$rc" -ne 0 ]; then
          echo "🛑 Fallo fatal (rc=$rc). Detengo la corrida."
          exit "$rc"
        fi
        break
      done

      attempted="$attempted$num "
      progress=1
    done
  done
}

print_plan() {
  echo "Ralph dry-run plan (read-only)"
  select_issues plan
}

# ------------------------------------------------------------------- bucle --

if [ "$DRY_RUN" = "1" ]; then
  print_plan
else
  run_sandbox_preflight || exit $?
  select_issues run
  echo "🏁 No quedan issues '$LABEL' listos para procesar."
fi
