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
#   5. Claude revisa. PASS → merge + cierre según RALPH_CLOSE_POLICY, para que
#      los issues dependientes hereden ese código. CHANGES_REQUESTED → Codex
#      corrige.
#
# Idempotente: si una corrida se corta, la siguiente REUTILIZA la rama y el PR
# existentes en vez de recrearlos, y salta lo ya mergeado.
#
# Límites de uso (de Claude o de Codex): los adaptadores sólo aceptan señales
# estructuradas del proveedor, reintentan el mismo issue como máximo
# RALPH_MAX_LIMIT_RETRIES veces y nunca fabrican una hora de reset.
#
# Config por entorno, proyecto y host (todo opcional; precedencia:
# entorno explícito > host > proyecto > defaults):
#   RALPH_LABEL          label que marca issues AFK      (default: ready-for-agent)
#   RALPH_BASE_BRANCH    branch base                     (default: trunk del repo)
#   RALPH_BRANCH_PREFIX  prefijo de branches por issue   (default: ralph/issue-)
#   RALPH_MAX_ROUNDS     revisiones de Claude por PR     (default: 3)
#   RALPH_MAX_ISSUES     issues únicos iniciados por corrida (default: 5)
#   RALPH_MAX_RUN_SECONDS duración máxima de la corrida (default: 14400)
#   RALPH_CODEX_MODEL    modelo del implementador        (default: gpt-5.6-luna)
#   RALPH_CODEX_EFFORT   reasoning effort de Codex       (default: xhigh)
#   RALPH_CODEX_SANDBOX  sandbox de Codex                (default: workspace-write; .git
#                           es sólo lectura allí, ralph lo habilita como writable_root,
#                           ejecuta una sonda de preflight y reemplaza writable_roots
#                           configurado; danger-full-access no se recomienda)
#   RALPH_CLAUDE_MODEL   modelo del revisor              (default: opus)
#   RALPH_CLAUDE_MAX_BUDGET_USD límite por invocación de Claude (optional)
#   RALPH_TDD_SKILL      ruta obligatoria a SKILL.md para Codex
#   RALPH_SMOKE_TEST     smoke test de ambos modelos      (default: 0)
#   RALPH_REVIEWER_GH_TOKEN token fine-grained read-only para Claude (required)
#   RALPH_REQUIRE_REVIEWER_TOKEN exige el token; sólo puede ser 0 en sandbox
#   RALPH_MERGE_METHOD   método de merge del PR          (default: --squash)
#   RALPH_MERGE_TIMEOUT_SECONDS espera confirmación       (default: 600)
#   RALPH_MERGE_PENDING_POLICY ante merge encolado         (default: stop)
#   RALPH_MAX_INFRA_RETRIES  reintentos ante infraestructura de CI/revisor (default: 3)
#   RALPH_MAX_LIMIT_RETRIES  reintentos ante un tope del proveedor (default: 3)
#   RALPH_RUN_BUDGET_USD   presupuesto estimado de Claude por corrida (optional)
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
#   RALPH_CLOSE_POLICY       verified o never (default: verified)
#   RALPH_HOST_CONFIG        archivo del host (default:
#                            ${XDG_CONFIG_HOME:-$HOME/.config}/ralph/host.env)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" \
  || fail "No pude resolver el directorio de once.sh."
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || fail "No pude resolver la raíz del repositorio git."
cd "$REPO_ROOT" || fail "No pude cambiar a la raíz del repositorio '$REPO_ROOT'."

declare -A EXPLICIT_RALPH_ENV=()
declare -a EXPLICIT_RALPH_NAMES=()
EXPLICIT_HOST_CONFIG=0
while IFS= read -r env_name; do
  case "$env_name" in
    RALPH_*)
      EXPLICIT_RALPH_NAMES+=("$env_name")
      EXPLICIT_RALPH_ENV["$env_name"]="${!env_name}"
      [ "$env_name" = RALPH_HOST_CONFIG ] && EXPLICIT_HOST_CONFIG=1
      ;;
  esac
done < <(compgen -e)

restore_explicit_ralph_env() {
  local env_name
  for env_name in "${EXPLICIT_RALPH_NAMES[@]}"; do
    printf -v "$env_name" '%s' "${EXPLICIT_RALPH_ENV[$env_name]}"
    declare -gx "$env_name"
  done
}

load_env_file() {
  local env_file="$1" required="${2:-0}"
  if [ -e "$env_file" ] && [ ! -f "$env_file" ]; then
    fail "La configuración '$env_file' debe ser un archivo regular."
  fi
  if [ -f "$env_file" ]; then
    # Los archivos .env son código shell de confianza, no datos parseados.
    # shellcheck disable=SC1090
    if ! source "$env_file"; then
      fail "No pude cargar la configuración '$env_file'."
    fi
  elif [ "$required" -eq 1 ]; then
    fail "No existe la configuración requerida '$env_file'."
  fi
}

load_env_file "$REPO_ROOT/.ralph/config.env"
restore_explicit_ralph_env
HOST_CONFIG_PATH="${RALPH_HOST_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph/host.env}"
load_env_file "$HOST_CONFIG_PATH" "$EXPLICIT_HOST_CONFIG"
restore_explicit_ralph_env

LABEL="${RALPH_LABEL:-ready-for-agent}"
# Este es el tamaño de página de la consulta, no un límite de ejecución: cada
# candidato devuelto sigue siendo considerado por el selector. Se explicita
# porque gh limita por defecto la lista de issues a 30 resultados.
ISSUE_QUERY_LIMIT=1000
# La base es el trunk del repo (main/master según el remoto), nunca la rama en
# la que estés parado: ralph mergea acá y los issues dependientes heredan ese
# código. Detectarla mantiene el script agnóstico al proyecto.
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
BASE_BRANCH="${RALPH_BASE_BRANCH:-$DEFAULT_BRANCH}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH_PREFIX="${RALPH_BRANCH_PREFIX:-ralph/issue-}"
MAX_ROUNDS="${RALPH_MAX_ROUNDS:-3}"
MAX_ISSUES="${RALPH_MAX_ISSUES:-5}"
MAX_RUN_SECONDS="${RALPH_MAX_RUN_SECONDS:-14400}"
CODEX_MODEL="${RALPH_CODEX_MODEL:-gpt-5.6-luna}"
CODEX_EFFORT="${RALPH_CODEX_EFFORT:-xhigh}"
CODEX_SANDBOX="${RALPH_CODEX_SANDBOX:-workspace-write}"
CLAUDE_MODEL="${RALPH_CLAUDE_MODEL:-opus}"
CLAUDE_MAX_BUDGET_USD="${RALPH_CLAUDE_MAX_BUDGET_USD:-}"
RUN_BUDGET_USD="${RALPH_RUN_BUDGET_USD:-}"
REVIEWER_GH_TOKEN="${RALPH_REVIEWER_GH_TOKEN:-}"
REQUIRE_REVIEWER_TOKEN="${RALPH_REQUIRE_REVIEWER_TOKEN:-1}"
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
AGENT_TIMEOUT_SECONDS="${RALPH_AGENT_TIMEOUT_SECONDS:-1800}"
LOCK_REF="${RALPH_LOCK_REF:-refs/ralph/lock}"
LOCK_TTL_SECONDS="${RALPH_LOCK_TTL_SECONDS:-}"
LOCK_HEARTBEAT_SECONDS="${RALPH_LOCK_HEARTBEAT_SECONDS:-}"
LOCK_HOST="${RALPH_LOCK_HOST:-$(uname -n 2>/dev/null || printf '%s' unknown)}"
CLOSE_POLICY="${RALPH_CLOSE_POLICY:-verified}"
TDD_SKILL="${RALPH_TDD_SKILL:-}"
SMOKE_TEST="${RALPH_SMOKE_TEST:-0}"
TIMEOUT_COMMAND=""
declare -a CLEAN_RALPH_ENV_ARGS=()

# These are the versions represented by the checked-in provider contract
# fixtures. Newer patch/minor releases are accepted; older releases are not.
SUPPORTED_CODEX_VERSION="0.154.0"
SUPPORTED_CLAUDE_VERSION="2.1.277"
SUPPORTED_GH_VERSION="2.45.0"

HOST_SYSTEM="$(uname -s 2>/dev/null)" || fail "No pude detectar el sistema operativo con uname -s."
case "$HOST_SYSTEM" in
  Darwin) HOST_KIND=macos ;;
  Linux) HOST_KIND=linux ;;
  *) fail "Sistema operativo no soportado por Ralph: '$HOST_SYSTEM'." ;;
esac

CHECKPOINT_FILE="${RALPH_CHECKPOINT_FILE:-$SCRIPT_DIR/last_run.md}"

validate_non_negative_integer() {
  local variable_name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) fail "$variable_name debe ser un entero no negativo." ;;
  esac
}

validate_non_negative_decimal() {
  local variable_name="$1" value="$2"
  case "$value" in
    ''|*[!0-9.]*|.*|*.) fail "$variable_name debe ser un número decimal no negativo." ;;
  esac
  case "$value" in
    *.*.*) fail "$variable_name debe ser un número decimal no negativo." ;;
  esac
}

validate_file_path() {
  local variable_name="$1" path="$2" parent
  [ -n "$path" ] || fail "$variable_name no puede estar vacío."
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    fail "$variable_name='$path' debe apuntar a un archivo regular."
  fi
  parent="$(dirname "$path")"
  [ -d "$parent" ] || fail "$variable_name='$path' apunta a un directorio inexistente."
}

validate_tdd_skill() {
  if [ -z "$TDD_SKILL" ] || [ "${TDD_SKILL##*/}" != "SKILL.md" ] \
      || [ ! -f "$TDD_SKILL" ] || [ ! -r "$TDD_SKILL" ]; then
    fail "Configura RALPH_TDD_SKILL con la ruta a un SKILL.md legible."
  fi
}

validate_non_negative_integer RALPH_MAX_ROUNDS "$MAX_ROUNDS"
validate_non_negative_integer RALPH_MAX_ISSUES "$MAX_ISSUES"
validate_non_negative_integer RALPH_MAX_RUN_SECONDS "$MAX_RUN_SECONDS"
validate_non_negative_integer RALPH_MAX_INFRA_RETRIES "$MAX_INFRA_RETRIES"
validate_non_negative_integer RALPH_MAX_LIMIT_RETRIES "$MAX_LIMIT_RETRIES"
validate_non_negative_integer RALPH_CI_TIMEOUT_SECONDS "$CI_TIMEOUT_SECONDS"
case "$CLAUDE_MAX_BUDGET_USD" in
  '') ;;
  *) validate_non_negative_decimal RALPH_CLAUDE_MAX_BUDGET_USD "$CLAUDE_MAX_BUDGET_USD" ;;
esac
case "$RUN_BUDGET_USD" in
  '') ;;
  *) validate_non_negative_decimal RALPH_RUN_BUDGET_USD "$RUN_BUDGET_USD" ;;
esac
case "$DEADLINE_EPOCH" in
  '') ;;
  *) validate_non_negative_integer RALPH_DEADLINE_EPOCH "$DEADLINE_EPOCH" ;;
esac
validate_file_path RALPH_CHECKPOINT_FILE "$CHECKPOINT_FILE"
validate_tdd_skill

AGENT_LOG=""
LAST_MSG=""
RUN_ID=""
RUN_DIR="${RUN_DIR:-}"
RUN_INITIALIZED=0
RUN_STARTED_EPOCH=""
RUN_DEADLINE=""
RUN_ISSUES_STARTED=0
RUN_STOP_REASON="running"
RUN_FAILED_ISSUES=0
RUN_SEQUENCE=0
RUN_CODEX_TOKENS=""
RUN_CLAUDE_ESTIMATED_USD=""
CODEX_VERSION=""
CLAUDE_VERSION=""
GH_VERSION=""
AGENT_STDOUT=""
AGENT_STDERR=""
ADAPTER_RESULT_FILE=""
ADAPTER_FINAL_MESSAGE=""
ADAPTER_EXIT_CODE=0
ADAPTER_ERROR=""
ADAPTER_STATUS="ok"
CI_FAILURE_BODY=""
CI_INFRASTRUCTURE_REASON=""
PROTECTION_STATUS="not_checked"
PROTECTION_FAILURES=""
PROTECTION_RULESET_IDS=""
MERGED_SHA=""

CURRENT_ISSUE=""
CURRENT_PR=""
CURRENT_PHASE="preflight"
CURRENT_AGENT_PID=""
CURRENT_AGENT_PGID=""
CURRENT_AGENT_FIFO=""
CURRENT_AGENT_ERR_FIFO=""
CURRENT_TEE_PID=""
CURRENT_TEE_ERR_PID=""
AGENT_ROLE=""
CODEX_SKILL_CONTEXT=""
SIGNAL_EXITING=0
LOCK_HELD=0
LOCK_COMMIT=""
LOCK_STARTED_AT=""
LOCK_NEXT_HEARTBEAT_MONOTONIC=""
LOCK_STATE="missing"
LOCK_REMOTE_OID=""
LOCK_REMOTE_HOST=""
LOCK_REMOTE_PID=""
LOCK_REMOTE_STARTED_AT=""
LOCK_REMOTE_HEARTBEAT_AT=""
LOCK_TREE=""

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

record_run_event() {
  local event="$1" issue="${2:-}" pr="${3:-}" status="${4:-}" detail="${5:-}" blockers="${6:-}"
  local issue_json=null pr_json=null blockers_json event_json timestamp
  [ "$RUN_INITIALIZED" -eq 1 ] || return 0
  timestamp="$(lock_epoch_now 2>/dev/null)" || timestamp=""
  [ -n "$issue" ] && printf '%s' "$issue" | grep -Eq '^[0-9]+$' && issue_json="$issue"
  [ -n "$pr" ] && printf '%s' "$pr" | grep -Eq '^[0-9]+$' && pr_json="$pr"
  blockers_json="$(printf '%s\n' "$blockers" | jq -Rsc '
    split("\n") | map(select(length > 0) | tonumber)
  ')" || return 70
  event_json="$(jq -cn \
    --arg event "$event" \
    --arg timestamp "$timestamp" \
    --arg phase "$CURRENT_PHASE" \
    --arg status "$status" \
    --arg detail "$detail" \
    --argjson issue "$issue_json" \
    --argjson pr "$pr_json" \
    --argjson blockers "$blockers_json" \
    '{event: $event, timestamp: (if $timestamp == "" then null else $timestamp end),
      issue: $issue, pr: $pr, phase: $phase,
      status: (if $status == "" then null else $status end),
      detail: (if $detail == "" then null else $detail end),
      blockers: $blockers}')" || return 70
  printf '%s\n' "$event_json" >> "$RUN_DIR/events.jsonl" || return 70
}

record_codex_usage() {
  local stdout_file="$1" tokens
  tokens="$(jq -s -r '
    [ .[] | select(.type == "turn.completed" and (.usage | type == "object")) |
      if (.usage.total_tokens | type) == "number" then .usage.total_tokens
      elif ([.usage.input_tokens, .usage.output_tokens]
            | any(type == "number")) then
        [.usage.input_tokens, .usage.output_tokens]
        | map(select(type == "number")) | add
      else empty
      end
    ] | if length == 0 then empty else add end
  ' "$stdout_file" 2>/dev/null)" || tokens=""
  case "$tokens" in
    ''|*[!0-9]*) ;;
    *)
      if [ -n "$RUN_CODEX_TOKENS" ]; then
        RUN_CODEX_TOKENS=$((RUN_CODEX_TOKENS + tokens))
      else
        RUN_CODEX_TOKENS="$tokens"
      fi
      ;;
  esac
}

record_claude_usage() {
  local stdout_file="$1" cost
  cost="$(jq -s -r '
    if length == 1 and (.[0] | type == "object") and
       (.[0].total_cost_usd | type == "number") then .[0].total_cost_usd
    else empty end
  ' "$stdout_file" 2>/dev/null)" || cost=""
  case "$cost" in
    ''|*[!0-9.-]*) ;;
    *)
      if [ -n "$RUN_CLAUDE_ESTIMATED_USD" ]; then
        RUN_CLAUDE_ESTIMATED_USD="$(awk -v left="$RUN_CLAUDE_ESTIMATED_USD" -v right="$cost" 'BEGIN { printf "%.10f", left + right }')"
      else
        RUN_CLAUDE_ESTIMATED_USD="$cost"
      fi
      ;;
  esac
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

initialize_run_storage() {
  local summary_tmp
  [ "$DRY_RUN" = "1" ] && return 0

  umask 077
  RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$" || {
    printf '❌ No pude generar el identificador de la corrida.\n' >&2
    return 70
  }
  RUN_STARTED_EPOCH="$(lock_epoch_now 2>/dev/null)" || RUN_STARTED_EPOCH=""
  case "$RUN_STARTED_EPOCH" in *[!0-9]*|'') RUN_STARTED_EPOCH="" ;; esac
  if [ -z "$RUN_STARTED_EPOCH" ]; then
    printf '❌ No pude fijar el inicio de la corrida para calcular el deadline.\n' >&2
    return 70
  fi
  RUN_DEADLINE=$((RUN_STARTED_EPOCH + MAX_RUN_SECONDS))
  if [ -n "$DEADLINE_EPOCH" ] && [ "$DEADLINE_EPOCH" -lt "$RUN_DEADLINE" ]; then
    RUN_DEADLINE="$DEADLINE_EPOCH"
  fi
  [ -n "$RUN_DIR" ] || RUN_DIR="$SCRIPT_DIR/runs/$RUN_ID"
  mkdir -p "$RUN_DIR" || {
    printf "❌ No pude crear el directorio de corrida '%s'.\n" "$RUN_DIR" >&2
    return 70
  }
  : > "$RUN_DIR/run.log" || {
    printf "❌ No pude crear el log de corrida '%s/run.log'.\n" "$RUN_DIR" >&2
    return 70
  }
  AGENT_LOG="$RUN_DIR/events.log"
  LAST_MSG="$RUN_DIR/last-message.txt"
  : > "$AGENT_LOG" || return 70
  : > "$RUN_DIR/events.jsonl" || return 70
  : > "$LAST_MSG" || return 70
  summary_tmp="$RUN_DIR/summary.json.tmp.$$"
  if ! jq -cn \
      --arg run_id "$RUN_ID" \
      --arg started_at "$RUN_ID" \
      --arg base_branch "$BASE_BRANCH" \
      --arg stop_reason "$RUN_STOP_REASON" \
      '{schema: 1, run_id: $run_id, started_at: $started_at,
        base_branch: $base_branch, stop_reason: $stop_reason,
        exit_code: null, issues_started: 0, issues: [], merged: [], open_prs: [],
        needs_human: [], blocked: [], errors: [], elapsed_seconds: null,
        versions: {codex: null, claude: null, gh: null},
        usage: {codex_tokens: null, claude_estimated_usd: null}}' > "$summary_tmp"; then
    rm -f "$summary_tmp"
    return 70
  fi
  mv -f "$summary_tmp" "$RUN_DIR/summary.json" || return 70
  RUN_INITIALIZED=1
  record_run_event "run_started" "" "" "running" "$RUN_ID" || return 70
  exec > >(tee -a "$RUN_DIR/run.log") 2>&1
  echo "📁 Corrida $RUN_ID: artefactos en $RUN_DIR"
}

write_summary_markdown() {
  local markdown_tmp="$RUN_DIR/summary.md.tmp.$$"
  jq -r --arg repo "https://github.com/$REPO_SLUG" '
    def item_link($url; $label):
      if $url == null then $label else "[" + $label + "](" + $url + ")" end;
    def issue_link:
      if .issue == null then "Issue desconocido"
      else item_link(.issue_url; "Issue #" + (.issue | tostring)) end;
    def pr_link:
      if .pr == null then "PR desconocido"
      else item_link(.pr_url; "PR #" + (.pr | tostring)) end;
    def section($title; $items):
      "## " + $title + "\n\n" +
      (if ($items | length) == 0 then "- Ninguno\n"
       else ($items | map("- " + issue_link + " — " +
         (if .pr == null then "" else pr_link end)) | join("\n") + "\n") end);
    "# Ralph — corrida " + .run_id + "\n\n" +
    "- Stop reason: `" + (.stop_reason | tostring) + "`\n" +
    "- Exit code: `" + (.exit_code | tostring) + "`\n" +
    "- Elapsed seconds: `" + (.elapsed_seconds | tostring) + "`\n\n" +
    "## Tool versions\n\n" +
    "- Codex version: `" + (if .versions.codex == null then "unknown" else (.versions.codex | tostring) end) + "`\n" +
    "- Claude version: `" + (if .versions.claude == null then "unknown" else (.versions.claude | tostring) end) + "`\n" +
    "- gh version: `" + (if .versions.gh == null then "unknown" else (.versions.gh | tostring) end) + "`\n\n" +
    section("Merged"; .merged) + "\n" +
    section("Open PRs"; .open_prs) + "\n" +
    "## Needs human\n\n" +
    (if (.needs_human | length) == 0 then "- Ninguno\n"
     else (.needs_human | map("- " + issue_link + " — " + (if .reason == null then "sin motivo" else .reason end) +
       (if .pr == null then "" else " (" + pr_link + ")" end)) | join("\n") + "\n") end) + "\n" +
    "## Blocked\n\n" +
    (if (.blocked | length) == 0 then "- Ninguno\n"
     else (.blocked | map("- " + issue_link + " — blockers: " + ((.blockers // []) | map("#" + tostring) | join(", "))) | join("\n") + "\n") end) + "\n" +
    "## Errors\n\n" +
    (if (.errors | length) == 0 then "- Ninguno\n"
     else (.errors | map("- " + tostring) | join("\n") + "\n") end) + "\n" +
    "## Usage\n\n" +
    "- Codex tokens: `" + (if .usage.codex_tokens == null then "unknown" else (.usage.codex_tokens | tostring) end) + "`\n" +
    "- Claude estimated USD: `" + (if .usage.claude_estimated_usd == null then "unknown" else (.usage.claude_estimated_usd | tostring) end) + "`\n\n" +
    "Claude cost is an estimate reported by the provider. Actual billing is not inferred, and a subscription does not imply marginal cost. The run budget covers only this estimated Claude cost; it is not a joint Codex/Claude budget. Configure Codex hard ceiling at its provider.\n"
  ' "$RUN_DIR/summary.json" > "$markdown_tmp" 2>/dev/null || {
    rm -f "$markdown_tmp"
    return 70
  }
  mv -f "$markdown_tmp" "$RUN_DIR/summary.md"
}

finalize_run_summary() {
  local exit_code="$1" reason="$RUN_STOP_REASON" summary_tmp issue_json elapsed_json now
  [ "$RUN_INITIALIZED" -eq 1 ] || return 0
  [ -f "$RUN_DIR/summary.json" ] || return 0
  if [ "$reason" = "running" ]; then
    if [ "$exit_code" -eq 0 ]; then
      reason="completed"
    elif [ -n "$CURRENT_ISSUE" ]; then
      reason="issue_failed"
    else
      reason="run_failed"
    fi
  fi
  if [ -n "$CURRENT_ISSUE" ] && printf '%s' "$CURRENT_ISSUE" | grep -Eq '^[0-9]+$'; then
    issue_json="$CURRENT_ISSUE"
  else
    issue_json=null
  fi
  elapsed_json=null
  if [ -n "$RUN_STARTED_EPOCH" ]; then
    now="$(lock_epoch_now 2>/dev/null)" || now=""
    if printf '%s' "$now" | grep -Eq '^[0-9]+$' && [ "$now" -ge "$RUN_STARTED_EPOCH" ]; then
      elapsed_json=$((now - RUN_STARTED_EPOCH))
    fi
  fi
  summary_tmp="$RUN_DIR/summary.json.tmp.$$"
  if jq --arg stop_reason "$reason" \
      --argjson exit_code "$exit_code" \
      --argjson issue "$issue_json" \
      --argjson elapsed "$elapsed_json" \
      --argjson issues_started "$RUN_ISSUES_STARTED" \
      --arg repo "https://github.com/$REPO_SLUG" \
      --arg codex_tokens "$RUN_CODEX_TOKENS" \
      --arg claude_estimated_usd "$RUN_CLAUDE_ESTIMATED_USD" \
      --slurpfile events "$RUN_DIR/events.jsonl" \
      '.stop_reason = $stop_reason | .exit_code = $exit_code |
       .current_issue = $issue | .elapsed_seconds = $elapsed |
       .issues_started = $issues_started |
       .errors = ((.errors // []) +
         [$events[] | select(.event == "error" and .detail != null) | .detail] | unique) |
       (.usage = {
         codex_tokens: (if $codex_tokens == "" then null else ($codex_tokens | tonumber) end),
         claude_estimated_usd: (if $claude_estimated_usd == "" then null else ($claude_estimated_usd | tonumber) end)
       }) |
       (reduce ($events[] | select((.event == "pr_associated" or .event == "pr_state") and .pr != null)) as $event
         ({}; .[($event.pr | tostring)] = $event) | [.[]]) as $latest_prs |
       (reduce ($events[] | select(.event == "issue_failure" and .status == "needs_human" and .issue != null)) as $event
         ({}; .[($event.issue | tostring)] = $event) | [.[]]) as $human_events |
       (reduce ($events[] | select(.event == "issue_blocked" and .issue != null)) as $event
         ({}; .[($event.issue | tostring)] = $event) | [.[]]) as $blocked_events |
       .merged = [$latest_prs[] | select(.status == "merged") |
         {issue: .issue, pr: .pr,
          issue_url: (if .issue == null then null else ($repo + "/issues/" + (.issue | tostring)) end),
          pr_url: ($repo + "/pull/" + (.pr | tostring))}] |
       .open_prs = [$latest_prs[] | select(.status != "merged") |
         {issue: .issue, pr: .pr,
          issue_url: (if .issue == null then null else ($repo + "/issues/" + (.issue | tostring)) end),
          pr_url: ($repo + "/pull/" + (.pr | tostring))}] |
       .needs_human = [$human_events[] |
         {issue: .issue, pr: .pr, reason: .detail,
          issue_url: (if .issue == null then null else ($repo + "/issues/" + (.issue | tostring)) end),
          pr_url: (if .pr == null then null else ($repo + "/pull/" + (.pr | tostring)) end)}] |
       .blocked = [$blocked_events[] |
         {issue: .issue, blockers: .blockers,
          issue_url: (if .issue == null then null else ($repo + "/issues/" + (.issue | tostring)) end)}]' \
      "$RUN_DIR/summary.json" > "$summary_tmp" 2>/dev/null; then
    mv -f "$summary_tmp" "$RUN_DIR/summary.json"
  else
    rm -f "$summary_tmp"
  fi
  write_summary_markdown || true
}

print_summary_path() {
  [ "$RUN_INITIALIZED" -eq 1 ] || return 0
  [ -f "$RUN_DIR/summary.md" ] || return 0
  printf '📄 Resumen: %s/summary.md\n' "$RUN_DIR"
}

publish_summary_report() {
  local report_issue="${RALPH_REPORT_ISSUE:-}"
  [ "$RUN_INITIALIZED" -eq 1 ] || return 0
  [ -n "$report_issue" ] || return 0
  [ -f "$RUN_DIR/summary.md" ] || return 0
  if gh issue comment "$report_issue" --body "$(cat "$RUN_DIR/summary.md")" >/dev/null 2>&1; then
    echo "📣 Resumen publicado en issue #$report_issue."
  else
    printf '⚠️  No pude publicar el resumen en issue #%s; conservo %s/summary.md.\n' \
      "$report_issue" "$RUN_DIR" >&2
  fi
}

record_issue_failure() {
  local issue="$1" reason="$2" summary_tmp event_status issue_status=failed pr="${3-$CURRENT_PR}"
  [ "$RUN_INITIALIZED" -eq 1 ] || return 0
  RUN_FAILED_ISSUES=1
  [ "$reason" = "timeout" ] && issue_status=timeout
  summary_tmp="$RUN_DIR/summary.json.tmp.$$"
  if ! jq --argjson issue "$issue" --arg reason "$reason" --arg status "$issue_status" \
      '.issues = ((.issues // []) |
        map(select(.number != $issue)) +
        [{number: $issue, status: $status, reason: $reason}])' \
      "$RUN_DIR/summary.json" > "$summary_tmp" 2>/dev/null; then
    rm -f "$summary_tmp"
    return 70
  fi
  mv -f "$summary_tmp" "$RUN_DIR/summary.json" || return 70
  event_status=failed
  case "$reason" in
    needs_human) event_status=needs_human ;;
    timeout) event_status=timeout ;;
  esac
  record_run_event "issue_failure" "$issue" "$pr" "$event_status" "$reason" || return $?
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
  RUN_STOP_REASON="signal:$signal"
  exit_code=$((128 + $(signal_number "$signal")))
  message="corrida terminada por señal $signal durante $CURRENT_PHASE del issue #${CURRENT_ISSUE:-?}"
  printf '⚠️  %s\n' "$message"
  [ -n "$AGENT_LOG" ] && printf '%s\n' "$message" >> "$AGENT_LOG"
  record_run_event "signal" "$CURRENT_ISSUE" "$CURRENT_PR" "signal:$signal" "$message" || true
  record_signal_in_summary "$signal" "$exit_code"
  terminate_agent_processes
  exit "$exit_code"
}

cleanup_on_exit() {
  local exit_code=$?
  [ "$SIGNAL_EXITING" -eq 1 ] || terminate_agent_processes
  release_remote_lock
  finalize_run_summary "$exit_code"
  print_summary_path
  publish_summary_report
  [ -n "$CURRENT_AGENT_FIFO" ] && rm -f "$CURRENT_AGENT_FIFO"
  [ -n "$CURRENT_AGENT_ERR_FIFO" ] && rm -f "$CURRENT_AGENT_ERR_FIFO"
  return "$exit_code"
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
TIMEOUT_RC=67

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
case "$CLOSE_POLICY" in
  verified|never) ;;
  *) fail "RALPH_CLOSE_POLICY debe ser exactamente verified o never." ;;
esac
case "$REQUIRE_REVIEWER_TOKEN" in
  0|1) ;;
  *) fail "RALPH_REQUIRE_REVIEWER_TOKEN debe ser exactamente 0 o 1." ;;
esac
case "$SMOKE_TEST" in
  0|1) ;;
  *) fail "RALPH_SMOKE_TEST debe ser exactamente 0 o 1." ;;
esac
if [ "$DRY_RUN" != "1" ]; then
  if [ "$REQUIRE_REVIEWER_TOKEN" = "0" ] && [ "$REQUIRE_PROTECTION" != "0" ]; then
    fail "RALPH_REQUIRE_REVIEWER_TOKEN=0 sólo está permitido junto con RALPH_REQUIRE_PROTECTION=0 en el sandbox."
  fi
  if [ "$REQUIRE_REVIEWER_TOKEN" = "1" ] && [ -z "$REVIEWER_GH_TOKEN" ]; then
    fail "Falta RALPH_REVIEWER_GH_TOKEN. Creá un token fine-grained de GitHub con permisos read-only sobre este repositorio y configurá esa variable; RALPH_REQUIRE_REVIEWER_TOKEN=0 sólo está permitido en el sandbox."
  fi
  if [ -n "$REVIEWER_GH_TOKEN" ] && [ -n "${GH_TOKEN:-}" ] \
      && [ "$REVIEWER_GH_TOKEN" = "$GH_TOKEN" ]; then
    fail "RALPH_REVIEWER_GH_TOKEN debe ser distinto del token del orquestador GH_TOKEN."
  fi
fi

CLOSE_POLICY_INSTRUCTIONS="RALPH_CLOSE_POLICY=$CLOSE_POLICY
"
case "$CLOSE_POLICY" in
  verified)
    CLOSE_POLICY_INSTRUCTIONS+="The PR body MUST declare \`Closes #<issue number>\` so Ralph can close the issue after a verified merge."
    ;;
  never)
    CLOSE_POLICY_INSTRUCTIONS+="The PR body and every commit message MUST declare \`Part of #<issue number>\` and MUST NOT contain the autoclose keywords \`Closes\`, \`Fixes\`, or \`Resolves\`."
    ;;
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
case "$AGENT_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) fail "RALPH_AGENT_TIMEOUT_SECONDS debe ser un entero positivo." ;;
esac
[ "$AGENT_TIMEOUT_SECONDS" -gt 0 ] || fail "RALPH_AGENT_TIMEOUT_SECONDS debe ser un entero positivo."
if [ -z "$LOCK_TTL_SECONDS" ]; then
  LOCK_TTL_SECONDS=$((AGENT_TIMEOUT_SECONDS * 2))
fi
case "$LOCK_TTL_SECONDS" in
  ''|*[!0-9]*) fail "RALPH_LOCK_TTL_SECONDS debe ser un entero positivo." ;;
esac
[ "$LOCK_TTL_SECONDS" -gt 0 ] || fail "RALPH_LOCK_TTL_SECONDS debe ser un entero positivo."
if [ -z "$LOCK_HEARTBEAT_SECONDS" ]; then
  LOCK_HEARTBEAT_SECONDS=$((LOCK_TTL_SECONDS / 2))
  [ "$LOCK_HEARTBEAT_SECONDS" -gt 0 ] || LOCK_HEARTBEAT_SECONDS=1
fi
case "$LOCK_HEARTBEAT_SECONDS" in
  ''|*[!0-9]*) fail "RALPH_LOCK_HEARTBEAT_SECONDS debe ser un entero positivo." ;;
esac
[ "$LOCK_HEARTBEAT_SECONDS" -gt 0 ] || fail "RALPH_LOCK_HEARTBEAT_SECONDS debe ser un entero positivo."

select_timeout_command() {
  local candidate
  for candidate in gtimeout timeout; do
    if command -v "$candidate" >/dev/null 2>&1 &&
        "$candidate" --help >/dev/null 2>&1; then
      TIMEOUT_COMMAND="$(command -v "$candidate")"
      return 0
    fi
  done
  fail "Falta un timeout GNU usable. En macOS instalá 'brew install coreutils' (gtimeout); en Linux instalá el paquete 'coreutils'."
}

load_prompt() {
  local name="$1" common_prompt local_prompt
  case "$name" in
    prompt_implement|prompt_review|prompt_revise|prompt_conflicts) ;;
    *) fail "Prompt desconocido '$name'." ;;
  esac
  common_prompt="$SCRIPT_DIR/$name.md"
  local_prompt="$REPO_ROOT/.ralph/$name.local.md"
  [ -f "$common_prompt" ] || fail "Falta $common_prompt."
  if [ -e "$local_prompt" ] && [ ! -f "$local_prompt" ]; then
    fail "El prompt local '$local_prompt' debe ser un archivo regular."
  fi
  cat "$common_prompt"
  if [ -f "$local_prompt" ]; then
    printf '\n\n# Project-specific requirements\n\n'
    cat "$local_prompt"
  fi
}

lock_field() {
  local field="$1"
  awk -F': ' -v wanted="$field" '$1 == wanted {print substr($0, length(wanted) + 3); exit}'
}

lock_remote_oid() {
  git ls-remote origin "$LOCK_REF" 2>/dev/null | awk 'NR == 1 {print $1; exit}'
}

lock_epoch_now() {
  printf '%(%s)T\n' -1
}

lock_read_metadata() {
  local oid="$1" body
  if ! git cat-file -e "$oid^{commit}" 2>/dev/null; then
    git fetch --no-write-fetch-head -q origin "$LOCK_REF" >/dev/null 2>&1 || return 70
  fi
  body="$(git show -s --format=%B "$oid" 2>/dev/null)" || return 70
  case "$body" in
    "ralph-lock: v1"$'\n'*) ;;
    *) return 70 ;;
  esac
  LOCK_REMOTE_HOST="$(printf '%s\n' "$body" | lock_field host)"
  LOCK_REMOTE_PID="$(printf '%s\n' "$body" | lock_field pid)"
  LOCK_REMOTE_STARTED_AT="$(printf '%s\n' "$body" | lock_field started_at)"
  LOCK_REMOTE_HEARTBEAT_AT="$(printf '%s\n' "$body" | lock_field heartbeat_at)"
  case "$LOCK_REMOTE_HOST" in
    '') return 70 ;;
  esac
  case "$LOCK_REMOTE_PID:$LOCK_REMOTE_STARTED_AT:$LOCK_REMOTE_HEARTBEAT_AT" in
    *[!0-9:]*|:*|*::*) return 70 ;;
  esac
  return 0
}

inspect_remote_lock() {
  local now age
  LOCK_STATE="missing"
  LOCK_REMOTE_OID="$(lock_remote_oid)" || return 70
  [ -n "$LOCK_REMOTE_OID" ] || return 0
  case "$LOCK_REMOTE_OID" in
    *[!0-9a-f]*)
      echo "❌ La ref remota '$LOCK_REF' no contiene un objeto Git válido." >&2
      LOCK_STATE="invalid"
      return 70
      ;;
  esac
  if ! lock_read_metadata "$LOCK_REMOTE_OID"; then
    echo "❌ El lock remoto '$LOCK_REF' tiene metadatos inválidos o ilegibles." >&2
    LOCK_STATE="invalid"
    return 70
  fi
  now="$(date +%s)" || return 70
  age=$((now - LOCK_REMOTE_HEARTBEAT_AT))
  if [ "$age" -ge "$LOCK_TTL_SECONDS" ]; then
    LOCK_STATE="stale"
  else
    LOCK_STATE="active"
  fi
  return 0
}

lock_make_commit() {
  local heartbeat="$1" parent="${2:-}" message
  message="ralph-lock: v1
host: $LOCK_HOST
pid: $$
started_at: $LOCK_STARTED_AT
heartbeat_at: $heartbeat"
  if [ -n "$parent" ]; then
    printf '%s\n' "$message" | GIT_AUTHOR_DATE="@$heartbeat" \
      GIT_COMMITTER_DATE="@$heartbeat" \
      git -c user.name=ralph -c user.email=ralph@localhost commit-tree "$LOCK_TREE" -p "$parent"
  else
    printf '%s\n' "$message" | GIT_AUTHOR_DATE="@$heartbeat" \
      GIT_COMMITTER_DATE="@$heartbeat" \
      git -c user.name=ralph -c user.email=ralph@localhost commit-tree "$LOCK_TREE"
  fi
}

lock_mark_acquired() {
  local oid="$1"
  LOCK_HELD=1
  LOCK_COMMIT="$oid"
  LOCK_NEXT_HEARTBEAT_MONOTONIC=$((SECONDS + LOCK_HEARTBEAT_SECONDS))
}

release_remote_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  if git push -q --force-with-lease="$LOCK_REF:$LOCK_COMMIT" \
      origin ":$LOCK_REF" >/dev/null 2>&1; then
    LOCK_HELD=0
  else
    echo "⚠️  No pude liberar el lock remoto; no borro un lock que pudo reclamar otro proceso." >&2
  fi
}

renew_remote_lock() {
  local now new_oid
  [ "$LOCK_HELD" -eq 1 ] || return 0
  now="$(lock_epoch_now)" || return 70
  new_oid="$(lock_make_commit "$now" "$LOCK_COMMIT")" || return 70
  if ! git push -q --force-with-lease="$LOCK_REF:$LOCK_COMMIT" origin \
      "$new_oid:$LOCK_REF" >/dev/null 2>&1; then
    echo "❌ Perdí la propiedad del lock remoto '$LOCK_REF'; detengo la corrida." >&2
    return 70
  fi
  LOCK_COMMIT="$new_oid"
  LOCK_NEXT_HEARTBEAT_MONOTONIC=$((SECONDS + LOCK_HEARTBEAT_SECONDS))
  return 0
}

heartbeat_remote_lock_if_due() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  [ "$SECONDS" -lt "$LOCK_NEXT_HEARTBEAT_MONOTONIC" ] || renew_remote_lock
}

acquire_remote_lock() {
  local now new_oid previous_oid previous_host previous_pid push_rc
  LOCK_TREE="$(git mktree </dev/null 2>/dev/null)" || return 70
  [ -n "$LOCK_TREE" ] || return 70
  LOCK_STARTED_AT="$(lock_epoch_now)" || return 70
  inspect_remote_lock || return $?
  case "$LOCK_STATE" in
    active)
      echo "🔒 Ya hay una corrida activa en este repositorio (host=$LOCK_REMOTE_HOST pid=$LOCK_REMOTE_PID heartbeat=$LOCK_REMOTE_HEARTBEAT_AT); salgo sin mutaciones."
      return 1
      ;;
    invalid)
      return 70
      ;;
  esac

  previous_oid="$LOCK_REMOTE_OID"
  previous_host="$LOCK_REMOTE_HOST"
  previous_pid="$LOCK_REMOTE_PID"
  now="$LOCK_STARTED_AT"
  if [ "$LOCK_STATE" = "stale" ]; then
    new_oid="$(lock_make_commit "$now" "$previous_oid")" || return 70
    git push -q --force-with-lease="$LOCK_REF:$previous_oid" origin \
      "$new_oid:$LOCK_REF" >/dev/null 2>&1
    push_rc=$?
  else
    new_oid="$(lock_make_commit "$now")" || return 70
    git push -q origin "$new_oid:$LOCK_REF" >/dev/null 2>&1
    push_rc=$?
  fi
  if [ "$push_rc" -eq 0 ]; then
    lock_mark_acquired "$new_oid"
    if [ "$LOCK_STATE" = "stale" ]; then
      echo "🔓 Lock remoto vencido; reclamo el lock (host anterior: $previous_host, pid=$previous_pid)."
    fi
    return 0
  fi

  if inspect_remote_lock && [ "$LOCK_STATE" = "active" ]; then
    echo "🔒 Otra corrida adquirió el lock remoto antes que esta (host=$LOCK_REMOTE_HOST pid=$LOCK_REMOTE_PID); salgo sin mutaciones."
    return 1
  fi
  echo "❌ No pude adquirir el lock remoto '$LOCK_REF'; detengo la corrida." >&2
  return 70
}

for cmd in git gh jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Falta '$cmd' en el PATH."
done
if [ -n "$REQUIRED_CHECKS_JSON" ]; then
  if ! jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' \
      >/dev/null 2>&1 <<<"$REQUIRED_CHECKS_JSON"; then
    fail "RALPH_REQUIRED_CHECKS_JSON debe ser una lista JSON de nombres no vacíos."
  fi
fi
if [ "$DRY_RUN" != "1" ]; then
  select_timeout_command
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

write_protection_summary() {
  local status="$1" failure required_checks protection_required_json=true summary_tmp summary_rc
  failure=""
  [ "$#" -gt 1 ] && failure="$2"
  required_checks="$REQUIRED_CHECKS_JSON"
  [ -n "$required_checks" ] || required_checks='[]'
  [ "$REQUIRE_PROTECTION" = "0" ] && protection_required_json=false
  [ "$RUN_INITIALIZED" -eq 1 ] || return 0
  summary_tmp="$RUN_DIR/summary.json.tmp.$$"
  if [ -f "$RUN_DIR/summary.json" ]; then
    jq \
      --arg status "$status" \
      --arg base_branch "$BASE_BRANCH" \
      --arg merge_identity "$MERGE_IDENTITY" \
      --arg review_identity "$REVIEW_IDENTITY" \
      --arg failure "$failure" \
      --argjson required "$protection_required_json" \
      --argjson required_checks "$required_checks" \
      '.protection = {
          required: $required,
          status: $status,
          base_branch: $base_branch,
          merge_identity: $merge_identity,
          review_identity: $review_identity,
          required_checks: $required_checks,
          warning: (if $status == "disabled" then "RALPH_REQUIRE_PROTECTION=0" else null end)
        } |
        .errors = (if $failure == "" then (.errors // []) else ((.errors // []) + [$failure]) end)' \
      "$RUN_DIR/summary.json" >"$summary_tmp" 2>/dev/null
  else
    jq -cn \
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
      }' >"$summary_tmp" 2>/dev/null
  fi
  summary_rc=$?
  if [ "$summary_rc" -eq 0 ]; then
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
  [ "$include_count" -gt 0 ] || return 1
  while IFS= read -r pattern; do
    if ref_name_matches_pattern "$ref_name" "$pattern"; then
      include_match=1
      break
    fi
  done < <(jq -r '.conditions.ref_name.include[]? // empty' <<<"$ruleset")
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

initialize_run_storage || exit $?
write_protection_summary "$PROTECTION_STATUS" "$PROTECTION_FAILURES"

if [ "$DRY_RUN" != "1" ]; then
  CURRENT_PHASE="adquisición del lock remoto"
  acquire_remote_lock
  lock_rc=$?
  case "$lock_rc" in
    0) ;;
    1) exit 0 ;;
    *) exit 70 ;;
  esac
fi

PROMPT_IMPLEMENT="$(load_prompt prompt_implement)"
PROMPT_IMPLEMENT+=$'\n\n## Close policy passed by Ralph\n\n'
PROMPT_IMPLEMENT+="$CLOSE_POLICY_INSTRUCTIONS"
PROMPT_REVIEW="$(load_prompt prompt_review)"
PROMPT_REVISE="$(load_prompt prompt_revise)"
PROMPT_CONFLICTS="$(load_prompt prompt_conflicts)"
CODEX_SKILL_CONTEXT=$'\n\n## Required implementation skill\n\n'
CODEX_SKILL_CONTEXT+="$(cat "$TDD_SKILL")"

# Un PR necesita que su base exista en el remoto.
if ! git ls-remote --exit-code --heads origin "$BASE_BRANCH" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "⚠️  La base '$BASE_BRANCH' no existe en origin; dry-run continúa sin publicar."
  else
    echo "📤 La base '$BASE_BRANCH' no existe en origin; la publico."
    git push -u origin "$BASE_BRANCH" >/dev/null 2>&1 || fail "No pude publicar '$BASE_BRANCH'."
  fi
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
  local issue="$1" target now remaining heartbeat_remaining sleep_for global_remaining
  check_run_deadline "la espera del reset del proveedor" || return $?
  [ -n "$RESET_EPOCH" ] || {
    echo "⏭️  Tope sin retry_at fiable; reintento de #$issue sin espera."
    return 0
  }
  now="$(date +%s)"
  target="$RESET_EPOCH"
  if [ -n "$RUN_DEADLINE" ] && [ "$target" -gt "$RUN_DEADLINE" ]; then
    echo "🛑 El reset del proveedor excede el deadline global; no reintento #$issue."
    return 2
  fi
  [ "$target" -gt "$now" ] || return 0
  echo "⏳ Tope $LIMIT_KIND. Reintento de #$issue ~$(format_epoch "$target" '+%H:%M') (en $(((target - now) / 60)) min)..."
  while :; do
    check_run_deadline "la espera del reset del proveedor" || return $?
    heartbeat_remote_lock_if_due || return 70
    now="$(date +%s)"
    remaining=$((target - now))
    [ "$remaining" -le 0 ] && break
    sleep_for=$(( remaining > 600 ? 600 : remaining ))
    if [ -n "$RUN_DEADLINE" ]; then
      global_remaining=$((RUN_DEADLINE - now))
      [ "$global_remaining" -gt 0 ] || stop_for_deadline "la espera del reset del proveedor"
      [ "$global_remaining" -lt "$sleep_for" ] && sleep_for="$global_remaining"
    fi
    if [ "$LOCK_HELD" -eq 1 ]; then
      heartbeat_remaining=$((LOCK_NEXT_HEARTBEAT_MONOTONIC - SECONDS))
      [ "$heartbeat_remaining" -gt 0 ] && [ "$heartbeat_remaining" -lt "$sleep_for" ] && sleep_for="$heartbeat_remaining"
    fi
    [ "$sleep_for" -gt 0 ] || sleep_for=1
    sleep "$sleep_for"
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

run_deadline_expired() {
  local now
  [ -n "$RUN_DEADLINE" ] || return 1
  now="$(lock_epoch_now 2>/dev/null)" || return 70
  [ "$now" -ge "$RUN_DEADLINE" ]
}

is_bounded_timeout_rc() {
  case "$1" in
    124|137) return 0 ;;
    *) return 1 ;;
  esac
}

# Ejecuta una orden con el límite solicitado, recortándolo al tiempo que queda
# de la corrida. La variante GNU de timeout garantiza que un proceso que no
# responde a TERM reciba KILL después de la gracia fija.
run_bounded() {
  local requested_seconds="$1" now remaining effective_seconds rc
  shift
  BOUNDED_TIMED_OUT=0
  [ -n "$TIMEOUT_COMMAND" ] || return 70
  case "$requested_seconds" in
    ''|*[!0-9]*) return 70 ;;
  esac
  effective_seconds="$requested_seconds"
  if [ -n "$RUN_DEADLINE" ]; then
    now="$(lock_epoch_now 2>/dev/null)" || return 70
    remaining=$((RUN_DEADLINE - now))
    if [ "$remaining" -le 0 ]; then
      BOUNDED_TIMED_OUT=1
      return 124
    fi
    [ "$remaining" -lt "$effective_seconds" ] && effective_seconds="$remaining"
  fi
  if [ "${RUN_BOUNDED_ISOLATE:-0}" = "1" ] &&
      command -v setsid >/dev/null 2>&1; then
    exec setsid "$TIMEOUT_COMMAND" --kill-after=30s "$effective_seconds" "$@"
  fi
  "$TIMEOUT_COMMAND" --kill-after=30s "$effective_seconds" "$@"
  rc=$?
  is_bounded_timeout_rc "$rc" && BOUNDED_TIMED_OUT=1
  return "$rc"
}

stop_for_deadline() {
  local context="${1:-la siguiente operación}"
  echo "🛑 Deadline global alcanzado durante $context; detengo la corrida sin continuar."
  RUN_STOP_REASON="deadline"
  write_checkpoint "deadline global alcanzado durante $context."
  exit 0
}

stop_for_budget() {
  local context="${1:-la siguiente invocación de un agente}"
  echo "🛑 Presupuesto estimado de Claude alcanzado durante $context; detengo la corrida sin continuar."
  RUN_STOP_REASON="budget"
  write_checkpoint "presupuesto estimado de Claude alcanzado durante $context."
  exit 0
}

run_budget_reached() {
  [ -n "$RUN_BUDGET_USD" ] || return 1
  [ -n "$RUN_CLAUDE_ESTIMATED_USD" ] || return 1
  awk -v spent="$RUN_CLAUDE_ESTIMATED_USD" -v budget="$RUN_BUDGET_USD" \
    'BEGIN { exit !(spent >= budget) }'
}

check_run_budget() {
  run_budget_reached
  case "$?" in
    0) stop_for_budget "$1" ;;
    1) return 0 ;;
    *) return 70 ;;
  esac
}

stop_for_timeout() {
  local context="${1:-la orden acotada}"
  echo "⏱️  timeout durante $context; conservo la rama y detengo la corrida."
  record_issue_failure "$CURRENT_ISSUE" "timeout" "$CURRENT_PR" || exit 70
  RUN_STOP_REASON="timeout"
  write_checkpoint "timeout durante $context para #$CURRENT_ISSUE."
  exit 1
}

stop_for_ci_infrastructure() {
  local detail="${1:-CI no pudo iniciar el job.}"
  RUN_STOP_REASON="ci_infrastructure"
  echo "🛑 CI detenido por infraestructura (estado ci_infrastructure): $detail"
  record_run_event "error" "" "${CURRENT_PR:-}" "ci_infrastructure" "$detail" || return 70
  return 70
}

check_run_deadline() {
  run_deadline_expired
  case "$?" in
    0) stop_for_deadline "$1" ;;
    1) return 0 ;;
    *) return 70 ;;
  esac
}

start_next_issue() {
  local max_issues_message
  check_run_deadline "el inicio de un issue" || return $?
  if [ "$RUN_ISSUES_STARTED" -ge "$MAX_ISSUES" ]; then
    max_issues_message="máximo de $MAX_ISSUES issues únicos iniciados alcanzado."
    echo "🛑 $max_issues_message"
    RUN_STOP_REASON="max_issues"
    write_checkpoint "$max_issues_message"
    exit 0
  fi
  RUN_ISSUES_STARTED=$((RUN_ISSUES_STARTED + 1))
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

  launch_agent_process() {
    if [ "$AGENT_ROLE" = "reviewer" ]; then
      if [ -n "$REVIEWER_GH_TOKEN" ]; then
        export GH_TOKEN="$REVIEWER_GH_TOKEN"
      else
        unset GH_TOKEN
      fi
    fi
    RUN_BOUNDED_ISOLATE=1 run_bounded "$AGENT_TIMEOUT_SECONDS" env \
      "${CLEAN_RALPH_ENV_ARGS[@]}" "${AGENT_COMMAND[@]}"
  }
  if command -v setsid >/dev/null 2>&1; then
    launch_agent_process > "$stdout_fifo" 2> "$stderr_fifo" &
  else
    set -m
    launch_agent_process > "$stdout_fifo" 2> "$stderr_fifo" &
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
    if ! heartbeat_remote_lock_if_due; then
      terminate_agent_processes
      return 70
    fi
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

build_clean_ralph_env_args() {
  local env_name
  CLEAN_RALPH_ENV_ARGS=()
  while IFS= read -r env_name; do
    case "$env_name" in
      RALPH_TEST_REAL_*) ;;
      RALPH_*) CLEAN_RALPH_ENV_ARGS+=(-u "$env_name") ;;
    esac
  done < <(compgen -e)
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
  {
    printf '%s\n' "agent=$AGENT_ROLE stream=stdout"
    cat "$AGENT_STDOUT"
    printf '%s\n' "agent=$AGENT_ROLE stream=stderr"
    cat "$AGENT_STDERR"
  } >> "$AGENT_LOG" 2>/dev/null || true
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
    timeout) return "$TIMEOUT_RC" ;;
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

record_agent_timeout() {
  local provider="$1" process_rc="$2"
  ADAPTER_STATUS="timeout"
  ADAPTER_RETRY_AT="null"
  ADAPTER_LIMIT_SCOPE="unknown"
  ADAPTER_RETRYABLE=false
  ADAPTER_FINAL_MESSAGE=""
  ADAPTER_FINAL_MESSAGE_SET=0
  ADAPTER_EXIT_CODE="$process_rc"
  ADAPTER_ERROR="$provider excedió RALPH_AGENT_TIMEOUT_SECONDS"
  write_adapter_result || return 70
  record_run_event "agent_finished" "$CURRENT_ISSUE" "$CURRENT_PR" "timeout" "$provider" || return $?
  record_run_event "error" "$CURRENT_ISSUE" "$CURRENT_PR" "timeout" "$ADAPTER_ERROR" || return $?
  return "$TIMEOUT_RC"
}

run_codex() {
  local prompt="$1" process_rc
  check_run_budget "la invocación de Codex" || return $?
  check_run_deadline "la invocación de Codex" || return $?
  prompt+="$CODEX_SKILL_CONTEXT"
  AGENT_ROLE="codex"
  : > "$LAST_MSG"
  record_run_event "agent_started" "$CURRENT_ISSUE" "$CURRENT_PR" "codex" "$CURRENT_PHASE" || return $?
  prepare_agent_capture codex stdout.jsonl
  build_codex_sandbox_config || return $?
  build_clean_ralph_env_args
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
  if is_bounded_timeout_rc "$process_rc"; then
    record_agent_timeout "Codex" "$process_rc"
    return $?
  fi
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
    record_run_event "agent_finished" "$CURRENT_ISSUE" "$CURRENT_PR" "failed" "codex" || return $?
    record_run_event "error" "$CURRENT_ISSUE" "$CURRENT_PR" "failed" "$ADAPTER_ERROR" || return $?
    return "$process_rc"
  fi
  parse_codex_result "$AGENT_STDOUT" "$AGENT_STDERR" "$LAST_MSG" "$process_rc"
  record_codex_usage "$AGENT_STDOUT"
  record_run_event "agent_finished" "$CURRENT_ISSUE" "$CURRENT_PR" "$ADAPTER_STATUS" "codex" || return $?
  [ -z "$ADAPTER_ERROR" ] || record_run_event "error" "$CURRENT_ISSUE" "$CURRENT_PR" "$ADAPTER_STATUS" "$ADAPTER_ERROR" || return $?
  finish_adapter
}

run_claude() {
  local prompt="$1" process_rc
  check_run_budget "la invocación de Claude" || return $?
  check_run_deadline "la invocación de Claude" || return $?
  AGENT_ROLE="reviewer"
  record_run_event "agent_started" "$CURRENT_ISSUE" "$CURRENT_PR" "reviewer" "$CURRENT_PHASE" || return $?
  prepare_agent_capture claude stdout.json
  build_clean_ralph_env_args
  AGENT_COMMAND=(
    claude
    --model "$CLAUDE_MODEL"
  )
  if [ -n "$CLAUDE_MAX_BUDGET_USD" ]; then
    AGENT_COMMAND+=(--max-budget-usd "$CLAUDE_MAX_BUDGET_USD")
  fi
  AGENT_COMMAND+=(
    --dangerously-skip-permissions
    --print
    --output-format json
    "$prompt"
  )
  run_agent_group "$AGENT_STDOUT" "$AGENT_STDERR"
  process_rc=$?
  record_agent_log
  if is_bounded_timeout_rc "$process_rc"; then
    record_agent_timeout "Claude" "$process_rc"
    return $?
  fi
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
    record_run_event "agent_finished" "$CURRENT_ISSUE" "$CURRENT_PR" "failed" "reviewer" || return $?
    record_run_event "error" "$CURRENT_ISSUE" "$CURRENT_PR" "failed" "$ADAPTER_ERROR" || return $?
    return "$process_rc"
  fi
  parse_claude_result "$AGENT_STDOUT" "$AGENT_STDERR" "$process_rc"
  record_claude_usage "$AGENT_STDOUT"
  record_run_event "agent_finished" "$CURRENT_ISSUE" "$CURRENT_PR" "$ADAPTER_STATUS" "reviewer" || return $?
  [ -z "$ADAPTER_ERROR" ] || record_run_event "error" "$CURRENT_ISSUE" "$CURRENT_PR" "$ADAPTER_STATUS" "$ADAPTER_ERROR" || return $?
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

extract_tool_version() {
  local output="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ([0-9]+([.][0-9]+){1,2}) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$output"
  return 1
}

version_at_least() {
  local actual="$1" required="$2" i a r
  local -a actual_parts=() required_parts=()
  IFS=. read -r -a actual_parts <<< "$actual"
  IFS=. read -r -a required_parts <<< "$required"
  for i in 0 1 2; do
    a="${actual_parts[$i]:-0}"
    r="${required_parts[$i]:-0}"
    case "$a:$r" in
      *[!0-9:]*|:*) return 1 ;;
    esac
    if (( 10#$a > 10#$r )); then
      return 0
    elif (( 10#$a < 10#$r )); then
      return 1
    fi
  done
  return 0
}

record_tool_versions() {
  local summary_tmp="$RUN_DIR/summary.json.tmp.$$"
  jq --arg codex "$CODEX_VERSION" --arg claude "$CLAUDE_VERSION" \
    --arg gh "$GH_VERSION" \
    '.versions = {codex: $codex, claude: $claude, gh: $gh}' \
    "$RUN_DIR/summary.json" > "$summary_tmp" 2>/dev/null || {
    rm -f "$summary_tmp"
    return 70
  }
  mv -f "$summary_tmp" "$RUN_DIR/summary.json"
}

run_provider_preflight() {
  local codex_login_output claude_auth_output version
  [ "$DRY_RUN" = "1" ] && return 0

  if ! codex_login_output="$(codex login status 2>&1)"; then
    printf '❌ Preflight de autenticación falló: codex login status no confirma una sesión válida.\n' >&2
    [ -n "$codex_login_output" ] && printf '   Detalle: %s\n' "$codex_login_output" >&2
    return "$CONFIG_ERROR_RC"
  fi
  if printf '%s\n' "$codex_login_output" | grep -Eqi \
      'not[[:space:]]+logged[[:space:]]+in|not[[:space:]]+authenticated|logged[[:space:]]+out'; then
    printf '❌ Preflight de autenticación falló: codex login status indica que no hay sesión válida.\n' >&2
    return "$CONFIG_ERROR_RC"
  fi
  if jq -e 'type == "object" and (.loggedIn == false or .authenticated == false)' \
      >/dev/null 2>&1 <<< "$codex_login_output"; then
    printf '❌ Preflight de autenticación falló: codex login status indica que no hay sesión válida.\n' >&2
    return "$CONFIG_ERROR_RC"
  fi
  if ! claude_auth_output="$(claude auth status --json 2>&1)"; then
    printf '❌ Preflight de autenticación falló: claude auth status no confirma una sesión válida.\n' >&2
    [ -n "$claude_auth_output" ] && printf '   Detalle: %s\n' "$claude_auth_output" >&2
    return "$CONFIG_ERROR_RC"
  fi
  if ! jq -e '.loggedIn == true' >/dev/null 2>&1 <<< "$claude_auth_output"; then
    printf '❌ Preflight de autenticación falló: claude auth status indica que no hay sesión válida.\n' >&2
    return "$CONFIG_ERROR_RC"
  fi
  if ! gh auth status >/dev/null 2>&1; then
    printf '❌ Preflight de autenticación falló: gh auth status no confirma una sesión válida.\n' >&2
    return "$CONFIG_ERROR_RC"
  fi
  command -v jq >/dev/null 2>&1 || {
    printf '❌ Preflight de herramientas falló: falta jq en el PATH.\n' >&2
    return "$CONFIG_ERROR_RC"
  }

  version="$(codex --version 2>&1)" || {
    printf '❌ Preflight de herramientas falló: no pude obtener la versión de codex.\n' >&2
    return "$CONFIG_ERROR_RC"
  }
  CODEX_VERSION="$(extract_tool_version "$version")" || {
    printf '❌ Preflight de herramientas falló: versión de codex ilegible.\n' >&2
    return "$CONFIG_ERROR_RC"
  }
  version="$(claude --version 2>&1)" || {
    printf '❌ Preflight de herramientas falló: no pude obtener la versión de claude.\n' >&2
    return "$CONFIG_ERROR_RC"
  }
  CLAUDE_VERSION="$(extract_tool_version "$version")" || {
    printf '❌ Preflight de herramientas falló: versión de claude ilegible.\n' >&2
    return "$CONFIG_ERROR_RC"
  }
  version="$(gh --version 2>&1)" || {
    printf '❌ Preflight de herramientas falló: no pude obtener la versión de gh.\n' >&2
    return "$CONFIG_ERROR_RC"
  }
  GH_VERSION="$(extract_tool_version "$version")" || {
    printf '❌ Preflight de herramientas falló: versión de gh ilegible.\n' >&2
    return "$CONFIG_ERROR_RC"
  }

  if ! version_at_least "$CODEX_VERSION" "$SUPPORTED_CODEX_VERSION"; then
    printf '❌ Versión de codex no soportada: %s (mínima %s).\n' \
      "$CODEX_VERSION" "$SUPPORTED_CODEX_VERSION" >&2
    return "$CONFIG_ERROR_RC"
  fi
  if ! version_at_least "$CLAUDE_VERSION" "$SUPPORTED_CLAUDE_VERSION"; then
    printf '❌ Versión de claude no soportada: %s (mínima %s).\n' \
      "$CLAUDE_VERSION" "$SUPPORTED_CLAUDE_VERSION" >&2
    return "$CONFIG_ERROR_RC"
  fi
  if ! version_at_least "$GH_VERSION" "$SUPPORTED_GH_VERSION"; then
    printf '❌ Versión de gh no soportada: %s (mínima %s).\n' \
      "$GH_VERSION" "$SUPPORTED_GH_VERSION" >&2
    return "$CONFIG_ERROR_RC"
  fi

  record_tool_versions || return $?
  printf 'Preflight versions: codex=%s claude=%s gh=%s jq=present\n' \
    "$CODEX_VERSION" "$CLAUDE_VERSION" "$GH_VERSION"
  record_run_event "preflight" "" "" "ok" \
    "versions codex=$CODEX_VERSION claude=$CLAUDE_VERSION gh=$GH_VERSION jq=present" || return $?
}

ci_annotation_text() {
  local check_run_id="$1" annotations
  annotations="$(gh api --paginate \
    "repos/$REPO_SLUG/check-runs/$check_run_id/annotations" 2>/dev/null | \
    jq -s -r '[.[][]? | (.message // ""), (.title // ""), (.raw_details // "")] | join(" ")' \
    2>/dev/null)" || return 70
  printf '%s\n' "$annotations"
}

ci_job_steps_length() {
  local job_id="$1" job_json steps_length
  job_json="$(gh api "repos/$REPO_SLUG/actions/jobs/$job_id" 2>/dev/null)" || return 70
  steps_length="$(jq -r 'if (.steps | type) == "array" then (.steps | length) else -1 end' \
    <<<"$job_json" 2>/dev/null)" || return 70
  printf '%s\n' "$steps_length"
}

run_base_ci_preflight() {
  local runs run_id run_status run_conclusion jobs jobs_count executed_steps check_id annotation reason
  [ "$DRY_RUN" = "1" ] && return 0
  if [ "$CI_POLICY" = "none" ]; then
    echo "⚠️  Preflight CI de la base omitido: política RALPH_CI_POLICY=none explícita."
    return 0
  fi

  runs="$(gh run list --branch "$BASE_BRANCH" --limit 1 \
    --json databaseId,headSha,status,conclusion,url 2>/dev/null)" || {
    reason="no pude consultar el último run de CI en '$BASE_BRANCH'"
    stop_for_ci_infrastructure "$reason"
    return $?
  }
  run_id="$(jq -r '.[0].databaseId // empty' <<<"$runs" 2>/dev/null)" || run_id=""
  if [ -z "$run_id" ]; then
    reason="no existe un run de CI verificable en la base '$BASE_BRANCH'"
    stop_for_ci_infrastructure "$reason"
    return $?
  fi
  run_status="$(jq -r '.[0].status // empty | ascii_downcase' <<<"$runs" 2>/dev/null)" || run_status=""
  run_conclusion="$(jq -r '.[0].conclusion // empty | ascii_downcase' <<<"$runs" 2>/dev/null)" || run_conclusion=""
  if [ "$run_status" != "completed" ] ||
     { [ "$run_conclusion" != "failure" ] && [ "$run_conclusion" != "cancelled" ]; }; then
    echo "✅ Preflight CI de la base no detecta infraestructura: run #$run_id status=${run_status:-desconocido} conclusion=${run_conclusion:-desconocida}."
    return 0
  fi
  jobs="$(gh api --paginate \
    "repos/$REPO_SLUG/actions/runs/$run_id/jobs?per_page=100" 2>/dev/null | \
    jq -s -c '[.[] | .jobs[]?]' 2>/dev/null)" || {
    reason="no pude consultar los jobs del último run de CI #$run_id en '$BASE_BRANCH'"
    stop_for_ci_infrastructure "$reason"
    return $?
  }
  jobs_count="$(jq 'length' <<<"$jobs" 2>/dev/null)" || jobs_count=0
  executed_steps="$(jq '[.[] | .steps[]?] | length' <<<"$jobs" 2>/dev/null)" || executed_steps=0
  if [ "$jobs_count" -gt 0 ] && [ "$executed_steps" -gt 0 ]; then
    echo "✅ Preflight CI de la base verificado: el último run #$run_id ejecutó steps."
    record_run_event "preflight" "" "" "ok" \
      "base CI run=$run_id executed_steps=$executed_steps" || return $?
    return 0
  fi

  check_id="$(jq -r '[.[] | select((.conclusion // "" | ascii_downcase) == "failure" or (.conclusion // "" | ascii_downcase) == "cancelled") | .id // empty] | first // empty' <<<"$jobs" 2>/dev/null)" || check_id=""
  annotation=""
  if [ -n "$check_id" ]; then
    annotation="$(ci_annotation_text "$check_id")" || {
      reason="el último run de CI #$run_id no ejecutó steps y no pude leer sus anotaciones; verificá con gh api repos/$REPO_SLUG/check-runs/$check_id/annotations"
      stop_for_ci_infrastructure "$reason"
      return $?
    }
  fi
  reason="el último run de CI #$run_id en '$BASE_BRANCH' no ejecutó ningún step"
  [ -n "$annotation" ] && reason="$reason: $annotation"
  if [ -n "$check_id" ]; then
    reason="$reason. Verificá con gh api repos/$REPO_SLUG/check-runs/$check_id/annotations"
  fi
  stop_for_ci_infrastructure "$reason"
  return $?
}

run_smoke_test() {
  local codex_stdout="$RUN_DIR/preflight-codex.stdout.jsonl"
  local codex_stderr="$RUN_DIR/preflight-codex.stderr.log"
  local codex_message="$RUN_DIR/preflight-codex.message.txt"
  local claude_stdout="$RUN_DIR/preflight-claude.stdout.json"
  local claude_stderr="$RUN_DIR/preflight-claude.stderr.log"
  local smoke_rc
  local -a claude_command=(claude --model "$CLAUDE_MODEL")

  if [ "$DRY_RUN" = "1" ] || [ "$SMOKE_TEST" = "0" ]; then
    return 0
  fi
  build_codex_sandbox_config || return $?
  build_clean_ralph_env_args
  check_run_deadline "la invocación de Codex del smoke test" || return $?

  if run_bounded "$AGENT_TIMEOUT_SECONDS" env "${CLEAN_RALPH_ENV_ARGS[@]}" \
      codex exec --json --model "$CODEX_MODEL" \
      "${CODEX_SANDBOX_CONFIG_ARGS[@]}" --sandbox "$CODEX_SANDBOX" \
      --skip-git-repo-check -o "$codex_message" \
      'RALPH preflight smoke test: reply with OK.' \
      >"$codex_stdout" 2>"$codex_stderr"; then
    smoke_rc=0
  else
    smoke_rc=$?
  fi
  if [ "$smoke_rc" -ne 0 ] || [ ! -s "$codex_message" ] || \
      ! jq -s -e 'any(.[]; .type == "turn.completed" and
        (.usage | type == "object"))' "$codex_stdout" >/dev/null 2>&1; then
    printf '❌ Smoke test: el modelo de codex no es accesible; error de configuración.\n' >&2
    record_run_event "error" "" "" "config_error" \
      "Smoke test de codex falló (modelo no accesible)" || return $?
    return "$CONFIG_ERROR_RC"
  fi

  check_run_deadline "la invocación de Claude del smoke test" || return $?
  if [ -n "$CLAUDE_MAX_BUDGET_USD" ]; then
    claude_command+=(--max-budget-usd "$CLAUDE_MAX_BUDGET_USD")
  fi
  claude_command+=(--print --output-format json 'RALPH preflight smoke test: reply with OK.')
  if run_bounded "$AGENT_TIMEOUT_SECONDS" env "${CLEAN_RALPH_ENV_ARGS[@]}" \
      "${claude_command[@]}" \
      >"$claude_stdout" 2>"$claude_stderr"; then
    smoke_rc=0
  else
    smoke_rc=$?
  fi
  if [ "$smoke_rc" -ne 0 ] || ! jq -s -e \
      'length == 1 and .[0].type == "result" and
       .[0].subtype == "success" and .[0].is_error == false and
       (.[0].result | type == "string" and length > 0)' \
      "$claude_stdout" >/dev/null 2>&1; then
    printf '❌ Smoke test: el modelo de claude no es accesible; error de configuración.\n' >&2
    record_run_event "error" "" "" "config_error" \
      "Smoke test de claude falló (modelo no accesible)" || return $?
    return "$CONFIG_ERROR_RC"
  fi
  echo "Smoke test: codex y claude accesibles."
}

# 'gh pr edit --add-label' revienta en versiones de gh que aún consultan
# projectCards (Projects classic, deprecado). La API REST de issues no.
add_label() {
  gh api "repos/$REPO_SLUG/issues/$1/labels" -f "labels[]=$2" >/dev/null 2>&1 \
    || echo "⚠️  No pude aplicar el label '$2' a #$1."
}

extract_comment_id() {
  local reference="$1"
  printf '%s\n' "$reference" | sed -n 's/.*issuecomment-\([0-9][0-9]*\).*/\1/p'
}

publish_pr_state() {
  local pr="$1" issue="$2" phase="$3" round="$4" reviewed_sha="$5"
  local status="$6" merge_status="$7" review_body="${8:-}"
  local payload state_body comment_ref comment_id checkpoint_body publish_review=0

  payload="$(jq -cn \
    --arg pr "$pr" \
    --arg issue "$issue" \
    --arg phase "$phase" \
    --arg round "$round" \
    --arg reviewed_sha "$reviewed_sha" \
    --arg status "$status" \
    --arg merge_status "$merge_status" \
    --arg review_body "$review_body" \
    '{schema: 1, pr: ($pr | tonumber), issue: ($issue | tonumber), phase: $phase,
      round: ($round | tonumber), reviewed_sha: $reviewed_sha, status: $status,
      merge_status: $merge_status, review_body: $review_body, comment_id: null}')" || {
    echo "❌ No pude serializar el estado del PR #$pr." >&2
    return 70
  }
  comment_id="${PR_STATE_COMMENT_ID:-}"
  case "$status" in
    pass|changes_requested) publish_review=1 ;;
  esac
  if [ "$publish_review" -eq 1 ]; then
    [ -n "$review_body" ] || {
      echo "❌ El resultado publicable del revisor del PR #$pr está vacío." >&2
      return 70
    }
    comment_ref="$(gh pr comment "$pr" --body "$review_body" 2>/dev/null)" || {
      echo "❌ No pude publicar el estado del PR #$pr." >&2
      return 70
    }
    comment_id="$(extract_comment_id "$comment_ref")"
  elif [ -z "$comment_id" ]; then
    state_body="<!-- ralph-state -->"$'\n'"$payload"
    comment_ref="$(gh pr comment "$pr" --body "$state_body" 2>/dev/null)" || {
      echo "❌ No pude publicar el estado del PR #$pr." >&2
      return 70
    }
    comment_id="$(extract_comment_id "$comment_ref")"
  fi
  [ -n "$comment_id" ] || {
    echo "❌ gh pr comment no devolvió un ID reconocible para el PR #$pr." >&2
    return 70
  }

  payload="$(jq -cn \
    --argjson state "$payload" \
    --arg comment_id "$comment_id" \
    '$state | .comment_id = ($comment_id | tonumber)')" || return 70
  checkpoint_body="<!-- ralph-state -->"$'\n'"$payload"
  if ! gh pr comment "$pr" --body "$checkpoint_body" >/dev/null 2>&1; then
    echo "❌ No pude confirmar el estado remoto del PR #$pr." >&2
    return 70
  fi
  PR_STATE_COMMENT_ID="$comment_id"
  record_run_event "pr_state" "$issue" "$pr" "$status" "$merge_status" || return $?
}

resolve_merge_identity() {
  local identity_json=""
  [ -n "$MERGE_IDENTITY" ] && return 0

  identity_json="$(gh api user 2>/dev/null | jq -c . 2>/dev/null)" || identity_json=""
  MERGE_IDENTITY="$(jq -r '.login // empty' <<<"$identity_json" 2>/dev/null)"
  [ -n "$MERGE_IDENTITY" ] || {
    echo "❌ No pude resolver la identidad que mergea (gh api user o RALPH_MERGE_IDENTITY)." >&2
    return 70
  }
}

load_pr_state() {
  local pr="$1" comments_json state_json
  resolve_merge_identity || return $?
  PR_STATE_FOUND=0
  PR_STATE_PHASE=""
  PR_STATE_ROUND=0
  PR_STATE_REVIEWED_SHA=""
  PR_STATE_STATUS=""
  PR_STATE_MERGE_STATUS=""
  PR_STATE_REVIEW_BODY=""
  PR_STATE_COMMENT_ID=""

  comments_json="$(gh pr view "$pr" --json comments --jq '.comments' 2>/dev/null)" || {
    echo "❌ No pude reconstruir el estado remoto del PR #$pr." >&2
    return 70
  }
  state_json="$(jq -c --arg identity "$MERGE_IDENTITY" '
    [.[] | select((.author.login // "") == $identity)
     | select((.body // "") | contains("<!-- ralph-state -->"))
     | try ((.body | split("<!-- ralph-state -->")[1]) | fromjson) catch empty]
    | last // empty
  ' <<<"$comments_json")" || {
    echo "❌ El registro remoto del PR #$pr no es JSON válido." >&2
    return 70
  }
  [ -n "$state_json" ] || return 0
  jq -e --argjson expected_pr "$pr" '
    type == "object" and .schema == 1 and .pr == $expected_pr and
    (.pr | type) == "number" and (.issue | type) == "number" and
    (.phase | type) == "string" and (.round | type) == "number" and
    (.round >= 1) and ((.round | floor) == .round) and
    (.reviewed_sha | type) == "string" and (.status | type) == "string" and
    (.merge_status | type) == "string" and (.review_body | type) == "string" and
    (.comment_id | type) == "number"
  ' <<<"$state_json" >/dev/null 2>&1 || {
    echo "❌ El registro remoto del PR #$pr tiene un formato no reconocido." >&2
    return 70
  }
  PR_STATE_FOUND=1
  PR_STATE_PHASE="$(jq -r '.phase' <<<"$state_json")"
  PR_STATE_ROUND="$(jq -r '.round' <<<"$state_json")"
  PR_STATE_REVIEWED_SHA="$(jq -r '.reviewed_sha' <<<"$state_json")"
  PR_STATE_STATUS="$(jq -r '.status' <<<"$state_json")"
  PR_STATE_MERGE_STATUS="$(jq -r '.merge_status' <<<"$state_json")"
  PR_STATE_REVIEW_BODY="$(jq -r '.review_body' <<<"$state_json")"
  PR_STATE_COMMENT_ID="$(jq -r '.comment_id // empty' <<<"$state_json")"
  [ -n "$PR_STATE_COMMENT_ID" ] || {
    echo "❌ El registro remoto del PR #$pr no conserva el ID del comentario." >&2
    return 70
  }
}

run_codex_correction() {
  local pr="$1" branch="$2" issue_ctx="$3" review_body="$4" num="$5" rc
  CURRENT_PHASE="corrección"
  echo "✏️  Codex corrige PR #$pr..."
  run_codex "Your pull request was reviewed and did not pass.

Pull request: #$pr
Branch (already checked out, stay on it): $branch
Base branch:                              $BASE_BRANCH

## The GitHub issue this PR must satisfy
$issue_ctx

## The review you must address
$review_body

## Working instructions
$PROMPT_REVISE"
  rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "❌ Codex terminó por señal (rc=$rc): fallo de infraestructura del issue #$num."
  fi
  [ "$rc" -ne 0 ] && return "$rc"
  if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Codex dejó cambios sin commitear; conservo el estado y detengo la corrida."
    return 70
  fi
  if ! git push -q origin "$branch" >/dev/null 2>&1; then
    echo "❌ No pude publicar $branch; conservo el estado y detengo la corrida."
    return 70
  fi
}

pull_requests_for_branch_or_issue() {
  local branch="$1" issue="$2" prs
  if ! prs="$(gh pr list --state all --limit 1000 \
      --json number,state,headRefName,body,mergedAt,mergeCommit 2>/dev/null)"; then
    printf '❌ No pude leer los PRs asociados a la rama %s o al issue #%s; detengo la corrida.\n' \
      "$branch" "$issue" >&2
    return 70
  fi
  jq -c --arg branch "$branch" --arg issue "$issue" '
    [ .[] |
      select((.headRefName // "") == $branch or
        ((.body // "") | test(
          "(^|[^[:alnum:]_])(closes|fixes|resolves|part[[:space:]]+of)[[:space:]]+#[[:space:]]*" +
          $issue + "([^[:alnum:]_]|$)"; "i")))
    ]
  ' <<<"$prs" 2>/dev/null || {
    printf '❌ La lista de PRs asociados a la rama %s o al issue #%s no es válida; detengo la corrida.\n' \
      "$branch" "$issue" >&2
    return 70
  }
}

pr_for_branch() {
  local branch="$1" issue="$2" prs
  prs="$(pull_requests_for_branch_or_issue "$branch" "$issue")" || return $?
  jq -r --arg branch "$branch" '
    map(select((.state // "") | ascii_upcase == "OPEN")) |
    sort_by(if (.headRefName // "") == $branch then 0 else 1 end) |
    .[0].number // empty
  ' <<<"$prs"
}

reconcile_merged_pr() {
  local pr="$1" issue="$2" body="$3"
  if [ "$CLOSE_POLICY" = "verified" ] &&
      printf '%s\n' "$body" | grep -Eiq "(^|[^[:alnum:]])closes[[:space:]]+#[[:space:]]*$issue([^[:alnum:]]|$)"; then
    gh issue close "$issue" --comment "Reconciliado por PR mergeado #$pr (política de cierre verificada)." >/dev/null 2>&1 || true
    echo "✅ PR #$pr ya estaba mergeado; reconcilio el issue #$issue y lo cierro según la política '$CLOSE_POLICY'."
  else
    add_label "$issue" "$NEEDS_HUMAN_LABEL"
    gh issue comment "$issue" --body "🤖 PR #$pr ya estaba mergeado; el issue queda abierto (política de cierre: $CLOSE_POLICY)." >/dev/null 2>&1 || true
    echo "✅ PR #$pr ya estaba mergeado; reconcilio el issue #$issue y lo dejo abierto según la política '$CLOSE_POLICY'."
  fi
  record_run_event "pr_state" "$issue" "$pr" "merged" "merged" || return $?
}

checkout_or_fail() {
  local branch="$1"
  if git checkout "$branch" >/dev/null 2>&1; then
    return 0
  fi
  echo "❌ No pude hacer checkout de '$branch'; detengo la corrida."
  return 70
}

remote_branch_exists() {
  local branch="$1" rc
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    return 1
  fi
  echo "❌ No pude comprobar si existe 'origin/$branch'; detengo la corrida." >&2
  return 70
}

synchronize_branch_with_origin() {
  local branch="$1" local_sha remote_sha rc
  local_sha="$(git rev-parse "$branch" 2>/dev/null)" || {
    echo "❌ No pude leer la rama local '$branch'; detengo la corrida."
    return 70
  }
  remote_sha="$(git rev-parse "origin/$branch" 2>/dev/null)" || {
    echo "❌ No pude leer la rama remota 'origin/$branch'; detengo la corrida."
    return 70
  }
  if [ "$local_sha" = "$remote_sha" ]; then
    git branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 || {
      echo "❌ No pude configurar el tracking de '$branch'; detengo la corrida."
      return 70
    }
    return 0
  fi

  if git merge-base --is-ancestor "$branch" "origin/$branch"; then
    if ! git merge --ff-only "origin/$branch" >/dev/null 2>&1; then
      echo "❌ No pude hacer fast-forward local de '$branch' desde origin; detengo la corrida."
      return 70
    fi
    echo "🔄 rama local '$branch' actualizada por fast-forward desde origin."
  else
    rc=$?
    [ "$rc" -eq 1 ] || {
      echo "❌ No pude comprobar la relación entre '$branch' y 'origin/$branch'; detengo la corrida."
      return 70
    }
    if git merge-base --is-ancestor "origin/$branch" "$branch"; then
      if ! git push -q -u origin "$branch" >/dev/null 2>&1; then
        echo "❌ No pude publicar el fast-forward de '$branch' en origin; detengo la corrida."
        return 70
      fi
      if ! git fetch -q origin "$branch" >/dev/null 2>&1; then
        echo "❌ No pude confirmar el fast-forward de '$branch' en origin; detengo la corrida."
        return 70
      fi
      echo "🔄 rama remota 'origin/$branch' actualizada por fast-forward desde local."
    else
      rc=$?
      [ "$rc" -eq 1 ] || {
        echo "❌ No pude comprobar la relación entre '$branch' y 'origin/$branch'; detengo la corrida."
        return 70
      }
      return 1
    fi
  fi

  local_sha="$(git rev-parse "$branch" 2>/dev/null)" || return 70
  remote_sha="$(git rev-parse "origin/$branch" 2>/dev/null)" || return 70
  [ "$local_sha" = "$remote_sha" ] || {
    echo "❌ '$branch' y 'origin/$branch' siguen sin coincidir después del fast-forward; detengo la corrida."
    return 70
  }
  git branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 || {
    echo "❌ No pude configurar el tracking de '$branch'; detengo la corrida."
    return 70
  }
  return 0
}

mark_divergent_branch_for_human() {
  local branch="$1" pr="$2"
  echo "🙋 '$branch' y 'origin/$branch' están divergentes; ${pr:+PR #$pr }queda para un humano."
  if [ -n "$pr" ]; then
    add_label "$pr" "$NEEDS_HUMAN_LABEL"
    gh pr comment "$pr" --body "🤖 Ralph detectó que '$branch' y 'origin/$branch' tienen historias divergentes. El PR queda para un humano." >/dev/null 2>&1 || true
  else
    add_label "$CURRENT_ISSUE" "$NEEDS_HUMAN_LABEL"
    gh issue comment "$CURRENT_ISSUE" --body "🤖 Ralph detectó que '$branch' y 'origin/$branch' tienen historias divergentes. El issue queda para un humano." >/dev/null 2>&1 || true
  fi
}

verify_reviewed_head() {
  local pr="$1" expected_sha="$2" rc
  reviewed_head_matches "$pr" "$expected_sha"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -ne 1 ] && return "$rc"
  echo "❌ head_changed: el SHA revisado ya no coincide con HEAD local o headRefOid."
  return 70
}

reviewed_head_matches() {
  local pr="$1" expected_sha="$2" local_sha remote_sha attempt=1
  while [ "$attempt" -le 5 ]; do
    local_sha="$(git rev-parse HEAD 2>/dev/null)" || {
      echo "❌ No pude leer HEAD local; detengo la corrida."
      return 70
    }
    [ "$local_sha" = "$expected_sha" ] || return 1

    remote_sha="$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null)" || {
      echo "❌ No pude leer headRefOid del PR #$pr; detengo la corrida."
      return 70
    }
    [ "$remote_sha" = "$expected_sha" ] && return 0

    if [ "$attempt" -lt 5 ]; then
      sleep 2 || {
        echo "❌ No pude esperar para volver a leer headRefOid del PR #$pr; detengo la corrida."
        return 70
      }
    fi
    attempt=$((attempt + 1))
  done
  return 1
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

check_run_infrastructure_reason() {
  local check_runs="$1" reviewed_sha="$2" check_id steps_length check_name annotation job_steps_length
  CI_INFRASTRUCTURE_REASON=""
  while IFS=$'\t' read -r check_id steps_length check_name; do
    [ -n "$check_id$check_name" ] || continue
    annotation=""
    if [ -n "$check_id" ]; then
      annotation="$(ci_annotation_text "$check_id")" || annotation=""
    fi
    if printf '%s\n' "$annotation" | grep -Eqi 'was[[:space:]]+not[[:space:]]+started'; then
      CI_INFRASTRUCTURE_REASON="CI check '$check_name' terminó sin ejecutar steps"
      [ -n "$annotation" ] && CI_INFRASTRUCTURE_REASON="$CI_INFRASTRUCTURE_REASON: $annotation"
      if [ -n "$check_id" ]; then
        CI_INFRASTRUCTURE_REASON="$CI_INFRASTRUCTURE_REASON. Verificá con gh api repos/$REPO_SLUG/check-runs/$check_id/annotations"
      fi
      return 0
    fi
    if [ "$steps_length" -lt 0 ] && [ -n "$check_id" ]; then
      if job_steps_length="$(ci_job_steps_length "$check_id")"; then
        steps_length="$job_steps_length"
      fi
    fi
    if [ "$steps_length" -eq 0 ]; then
      CI_INFRASTRUCTURE_REASON="CI check '$check_name' terminó sin ejecutar steps"
      [ -n "$annotation" ] && CI_INFRASTRUCTURE_REASON="$CI_INFRASTRUCTURE_REASON: $annotation"
      if [ -n "$check_id" ]; then
        CI_INFRASTRUCTURE_REASON="$CI_INFRASTRUCTURE_REASON. Verificá con gh api repos/$REPO_SLUG/check-runs/$check_id/annotations"
      fi
      return 0
    fi
  done < <(jq -r --arg sha "$reviewed_sha" '
    .[] |
    select(.head_sha == $sha and
      (.status // "" | ascii_downcase) == "completed" and
      ((.conclusion // "" | ascii_downcase) == "failure" or
       (.conclusion // "" | ascii_downcase) == "cancelled")) |
    [(.id // "" | tostring),
     (if (.steps | type) == "array" then (.steps | length) else -1 end),
     (.name // "check sin nombre")] | @tsv
  ' <<<"$check_runs" 2>/dev/null)
  return 1
}

# Revisa todos los checks obligatorios del SHA exacto que Claude vio. Devuelve
# 0 si cada uno terminó en success, 1 si alguno terminó en un estado distinto,
# 2 si alguno está ausente, pendiente o la API no responde, y 3 si un check
# falló por infraestructura (sin steps o con la anotación de job no iniciado).
# Los estados auxiliares quedan en variables globales para distinguir rechazo,
# espera e infraestructura.
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

  check_run_infrastructure_reason "$check_runs" "$reviewed_sha"
  case "$?" in
    0)
      REQUIRED_CHECKS_STATE="ci_infrastructure"
      return 3
      ;;
    1) ;;
    *)
      REQUIRED_CHECKS_STATE="infrastructure"
      return 2
      ;;
  esac

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
  local pr="$1" branch="$2" reviewed_sha="${3:-}" run_url started now deadline checks_rc pending_reason remaining heartbeat_remaining global_remaining sleep_rc infra_retries=0

  CI_FAILURE_BODY=""

  if [ "$CI_POLICY" = "none" ]; then
    echo "⚠️  CI sin checks: política RALPH_CI_POLICY=none explícita; continúo sin esa garantía."
    return 0
  fi

  started="$(date +%s 2>/dev/null)" || return 2
  deadline=$((started + CI_TIMEOUT_SECONDS))
  while :; do
    check_run_deadline "la espera de CI" || return $?
    heartbeat_remote_lock_if_due || return 70
    check_required_checks "$reviewed_sha"
    checks_rc=$?
    if [ "$checks_rc" -eq 0 ]; then
      return 0
    elif [ "$checks_rc" -eq 3 ]; then
      if [ "$infra_retries" -lt "$MAX_INFRA_RETRIES" ]; then
        infra_retries=$((infra_retries + 1))
        echo "🔁 CI de infraestructura para PR #$pr; reintento $infra_retries/$MAX_INFRA_RETRIES sin consumir ronda."
        now="$(date +%s 2>/dev/null)" || return 70
        if [ "$now" -lt "$deadline" ]; then
          remaining=$((deadline - now))
          [ "$remaining" -gt 30 ] && remaining=30
          [ "$remaining" -gt 0 ] || remaining=1
          run_bounded "$remaining" sleep "$remaining"
          sleep_rc=$?
          if [ "$BOUNDED_TIMED_OUT" -eq 1 ]; then
            stop_for_deadline "la espera de recuperación de CI"
          fi
          [ "$sleep_rc" -eq 0 ] || return 70
        fi
        continue
      fi
      stop_for_ci_infrastructure "$CI_INFRASTRUCTURE_REASON"
      return $?
    elif [ "$checks_rc" -eq 1 ]; then
      run_url="$(gh run list --branch "$branch" --limit 1 --json url --jq '.[0].url' 2>/dev/null)"
      if [ -n "$REQUIRED_CHECKS_JSON" ]; then
        CI_FAILURE_BODY="1. CI obligatorio en rojo: ${REQUIRED_CHECKS_FAILURES:-check sin éxito}; reproducir con la suite en base virgen y corregir (${run_url:-sin URL del run})."
        echo "🔴 CI obligatorio en rojo en PR #$pr: ${REQUIRED_CHECKS_FAILURES:-check sin éxito} (${run_url:-sin URL del run})"
      else
        CI_FAILURE_BODY="1. CI en rojo: ${run_url:-ver la pestaña Checks del PR}; reproducir con la suite en base virgen y corregir."
        echo "🔴 CI en rojo en PR #$pr: ${run_url:-sin URL del run}"
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
    if [ -n "$RUN_DEADLINE" ]; then
      global_remaining=$((RUN_DEADLINE - now))
      [ "$global_remaining" -gt 0 ] || stop_for_deadline "la espera de CI"
    fi
    if [ "$now" -ge "$deadline" ]; then
      echo "⚠️  $pending_reason en PR #$pr; estado ci_pending, sin merge."
      return 2
    fi
    remaining=$((deadline - now))
    if [ "$remaining" -gt 30 ]; then
      remaining=30
    fi
    [ -n "$RUN_DEADLINE" ] && [ "$global_remaining" -lt "$remaining" ] && remaining="$global_remaining"
    if [ "$LOCK_HELD" -eq 1 ]; then
      heartbeat_remaining=$((LOCK_NEXT_HEARTBEAT_MONOTONIC - SECONDS))
      [ "$heartbeat_remaining" -gt 0 ] && [ "$heartbeat_remaining" -lt "$remaining" ] && remaining="$heartbeat_remaining"
    fi
    [ "$remaining" -gt 0 ] || remaining=1
    run_bounded "$remaining" sleep "$remaining"
    sleep_rc=$?
    if [ "$BOUNDED_TIMED_OUT" -eq 1 ]; then
      stop_for_deadline "la espera de CI"
    fi
    [ "$sleep_rc" -eq 0 ] || return 70
  done
}

# gh pr merge puede aceptar un merge encolado sin que el PR esté mergeado aún.
# Sólo un estado MERGED con un OID SHA válido habilita borrar la rama y avanzar.
# Devuelve 0 confirmado · 2 merge_pending · 70 fallo de infraestructura.
wait_for_merge() {
  local pr="$1" started now deadline remaining global_remaining merge_result merge_state merge_oid sleep_rc

  MERGED_SHA=""
  started="$(date +%s 2>/dev/null)" || return 70
  deadline=$((started + MERGE_TIMEOUT_SECONDS))
  while :; do
    check_run_deadline "la espera de confirmación del merge" || return $?
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
    if [ -n "$RUN_DEADLINE" ]; then
      global_remaining=$((RUN_DEADLINE - now))
      [ "$global_remaining" -gt 0 ] || stop_for_deadline "la espera de confirmación del merge"
    fi
    if [ "$now" -ge "$deadline" ]; then
      echo "⚠️  PR #$pr sigue sin merge confirmado; estado merge_pending, sin borrar rama ni cerrar issue."
      return 2
    fi
    remaining=$((deadline - now))
    [ "$remaining" -gt 30 ] && remaining=30
    [ -n "$RUN_DEADLINE" ] && [ "$global_remaining" -lt "$remaining" ] && remaining="$global_remaining"
    run_bounded "$remaining" sleep "$remaining"
    sleep_rc=$?
    if [ "$BOUNDED_TIMED_OUT" -eq 1 ]; then
      stop_for_deadline "la espera de confirmación del merge"
    fi
    [ "$sleep_rc" -eq 0 ] || return 70
  done
}

# ------------------------------------------------------------ ciclo por issue --

# Procesa UN issue: implementación por Codex, revisión por Claude, hasta
# MAX_ROUNDS. Devuelve: 0 normal · 8 tope estructurado · códigos privados para
# auth/config · código del agente ante unknown o fallo de infraestructura.
process_issue() {
  local num="$1"
  local branch="${BRANCH_PREFIX}${num}"
  local rc issue_ctx commits pr round verdict review_body prior_work reviewed_sha
  local state_status state_phase infra_retries merged_sha ci_ok ci_rc backoff deadline_remaining deadline_now
  local pr_body prs open_pr_record merged_pr merged_pr_body
  local review_rc
  local remote_delete_error

  CURRENT_ISSUE="$num"
  CURRENT_PR=""
  CURRENT_PHASE="preparación"
  pr=""
  record_run_event "issue_started" "$num" "" "started" "" || return $?
  echo ""
  echo "════ Issue #$num ($branch) ════"

  if ! git fetch -q origin >/dev/null 2>&1; then
    echo "❌ No pude actualizar las referencias de origin para el issue #$num; detengo la corrida."
    return 70
  fi

  prs="$(pull_requests_for_branch_or_issue "$branch" "$num")" || return $?
  open_pr_record="$(jq -c --arg branch "$branch" '
    map(select((.state // "") | ascii_upcase == "OPEN")) |
    sort_by(if (.headRefName // "") == $branch then 0 else 1 end) |
    .[0] // empty
  ' <<<"$prs")"
  if [ -n "$open_pr_record" ]; then
    pr="$(jq -r '.number' <<<"$open_pr_record")"
    branch="$(jq -r --arg fallback "$branch" '.headRefName // $fallback' <<<"$open_pr_record")"
    CURRENT_PR="$pr"
  else
    merged_pr="$(jq -r '
      map(select(((.state // "") | ascii_upcase) == "MERGED" or (.mergedAt // null) != null)) |
      .[0].number // empty
    ' <<<"$prs")"
    if [ -n "$merged_pr" ]; then
      merged_pr_body="$(jq -r --argjson pr "$merged_pr" '.[] | select(.number == $pr) | .body // ""' <<<"$prs")"
      reconcile_merged_pr "$merged_pr" "$num" "$merged_pr_body"
      checkout_or_fail "$BASE_BRANCH" || return 70
      return 0
    fi
  fi

  # Idempotencia: si la rama ya existe (corrida anterior interrumpida) la
  # reutilizamos. Recrearla con 'checkout -B' descartaría ese trabajo.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    checkout_or_fail "$branch" || return 70
    remote_branch_exists "$branch"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      if ! git show-ref --verify --quiet "refs/remotes/origin/$branch" &&
          ! git fetch -q origin "$branch" >/dev/null 2>&1; then
        echo "❌ No pude traer '$branch' desde origin; detengo la corrida."
        return 70
      fi
      synchronize_branch_with_origin "$branch"
      rc=$?
      if [ "$rc" -eq 1 ]; then
        mark_divergent_branch_for_human "$branch" "$pr"
        checkout_or_fail "$BASE_BRANCH" || return 70
        return 0
      fi
      [ "$rc" -eq 0 ] || return "$rc"
    elif [ "$rc" -ne 1 ]; then
      return "$rc"
    fi
    prior_work="$(git log --oneline "$BASE_BRANCH..$branch" 2>/dev/null)"
  else
    remote_branch_exists "$branch"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      if ! git fetch -q origin "$branch" >/dev/null 2>&1; then
        echo "❌ No pude traer '$branch' desde origin; detengo la corrida."
        return 70
      fi
      if ! git checkout --track -b "$branch" "origin/$branch" >/dev/null 2>&1; then
        echo "❌ No pude crear '$branch' desde origin; detengo la corrida."
        return 70
      fi
      echo "📥 rama remota '$branch' recuperada con tracking; continúo con el trabajo existente."
      prior_work="$(git log --oneline "$BASE_BRANCH..$branch" 2>/dev/null)"
    elif [ "$rc" -ne 1 ]; then
      return "$rc"
    else
      if ! git checkout -b "$branch" "$BASE_BRANCH" >/dev/null 2>&1; then
        echo "❌ No pude crear y hacer checkout de '$branch'; detengo la corrida."
        return 70
      fi
      prior_work=""
    fi
  fi

  if [ -z "$pr" ]; then
    pr="$(pr_for_branch "$branch" "$num")"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  fi
  CURRENT_PR="$pr"
  if [ -n "$pr" ]; then
    record_run_event "pr_associated" "$num" "$pr" "open" "$branch" || return $?
  fi

  # Un PR ya marcado para humano no se vuelve a tocar: agotó sus rondas.
  if [ -n "$pr" ]; then
    pr_needs_human "$pr"
    rc=$?
    [ "$rc" -eq 70 ] && return "$rc"
    if [ "$rc" -eq 0 ]; then
      echo "🙋 PR #$pr espera revisión humana; no lo toco."
      record_issue_failure "$num" "needs_human" "$pr" || return $?
      checkout_or_fail "$BASE_BRANCH" || return 70
      return 0
    fi
  fi

  # Contexto mínimo: SOLO este issue (cuerpo + comentarios) y los últimos commits.
  issue_ctx="$(gh issue view "$num" --json number,title,body,comments)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "❌ No pude leer el contexto del issue #$num; detengo la corrida."
    return 70
  fi
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
    validate_issue_for_agent "$num" "$pr"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      checkout_or_fail "$BASE_BRANCH" || return 70
      return 0
    fi
    [ "$rc" -eq 0 ] || return "$rc"
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
    if [ "$rc" -eq "$TIMEOUT_RC" ] && [ "$ADAPTER_STATUS" = "timeout" ]; then
      stop_for_timeout "la implementación de Codex"
    fi
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

    pr="$(pr_for_branch "$branch" "$num")"
    if [ -z "$pr" ]; then
      echo "⚠️  Codex no dejó PR abierto para #$num. Branch preservado, sin merge."
      record_issue_failure "$num" "no_pull_request" || return $?
      checkout_or_fail "$BASE_BRANCH" || return 70
      return 0
    fi
    echo "📬 PR #$pr abierto."
  else
    echo "♻️  PR #$pr ya existe; voy directo a revisión."
  fi

  load_pr_state "$pr" || return $?

  # ---- Fase 2: revisión, hasta MAX_ROUNDS ----
  CURRENT_PHASE="revisión"
  round=1
  state_status=""
  state_phase=""
  review_body=""
  reviewed_sha=""
  if [ "$PR_STATE_FOUND" -eq 1 ]; then
    round="$PR_STATE_ROUND"
    state_phase="$PR_STATE_PHASE"
    state_status="$PR_STATE_STATUS"
    reviewed_sha="$PR_STATE_REVIEWED_SHA"
    review_body="$PR_STATE_REVIEW_BODY"
    case "$state_phase" in
      revisión) CURRENT_PHASE="revisión" ;;
      corrección) CURRENT_PHASE="corrección" ;;
      merge) CURRENT_PHASE="merge" ;;
    esac
    if [ "$PR_STATE_MERGE_STATUS" = "merged" ]; then
      echo "✅ PR #$pr ya figura como mergeado en el estado remoto."
      record_run_event "pr_state" "$num" "$pr" "merged" "merged" || return $?
      checkout_or_fail "$BASE_BRANCH" || return 70
      return 0
    fi
  fi
  infra_retries=0
  while [ "$round" -le "$MAX_ROUNDS" ]; do
    update_branch_with_base "$branch" "$pr"
    rc=$?
    if [ "$rc" -ge 128 ]; then
      echo "❌ Codex terminó por señal (rc=$rc): fallo de infraestructura del issue #$num."
    fi
    [ "$rc" -ne 0 ] && return "$rc"

    if [ "$state_status" = "pass" ] || [ "$state_status" = "merge_pending" ]; then
      reviewed_head_matches "$pr" "$reviewed_sha"
      rc=$?
      if [ "$rc" -eq 1 ]; then
        reviewed_sha="$(git rev-parse HEAD 2>/dev/null)" || {
          echo "❌ No pude capturar el SHA después de actualizar la base; detengo la corrida."
          return 70
        }
        publish_pr_state "$pr" "$num" "revisión" "$round" "$reviewed_sha" \
          "reviewing" "open" "" || return $?
        state_phase="revisión"
        state_status="reviewing"
        review_body=""
      elif [ "$rc" -ne 0 ]; then
        return "$rc"
      fi
    fi

    if [ "$state_status" = "changes_requested" ] || [ "$state_status" = "correction_pending" ]; then
      if [ "$round" -eq "$MAX_ROUNDS" ]; then
        echo "🙋 #$num agotó las $MAX_ROUNDS rondas sin PASS. PR #$pr queda abierto para revisión humana."
        record_issue_failure "$num" "max_rounds" || return $?
        add_label "$pr" "$NEEDS_HUMAN_LABEL"
        gh pr comment "$pr" --body "🤖 Ralph agotó las $MAX_ROUNDS rondas de revisión sin alcanzar PASS. Sin merge: necesita un humano." >/dev/null 2>&1 || true
        checkout_or_fail "$BASE_BRANCH" || return 70
        return 0
      fi
      if [ "$state_status" != "correction_pending" ]; then
        publish_pr_state "$pr" "$num" "corrección" "$round" "$reviewed_sha" \
          "correction_pending" "open" "$review_body" || return $?
        state_phase="corrección"
        state_status="correction_pending"
      fi
      validate_issue_for_agent "$num" "$pr"
      rc=$?
      if [ "$rc" -eq 1 ]; then
        checkout_or_fail "$BASE_BRANCH" || return 70
        return 0
      fi
      [ "$rc" -eq 0 ] || return "$rc"
      run_codex_correction "$pr" "$branch" "$issue_ctx" "$review_body" "$num"
      rc=$?
      if [ "$rc" -eq "$TIMEOUT_RC" ] && [ "$ADAPTER_STATUS" = "timeout" ]; then
        stop_for_timeout "la corrección de Codex"
      fi
      [ "$rc" -ne 0 ] && return "$rc"
      round=$((round + 1))
      reviewed_sha="$(git rev-parse HEAD 2>/dev/null)" || {
        echo "❌ No pude capturar el SHA después de la corrección; detengo la corrida."
        return 70
      }
      publish_pr_state "$pr" "$num" "revisión" "$round" "$reviewed_sha" \
        "reviewing" "open" "" || return $?
      state_phase="revisión"
      state_status="reviewing"
      review_body=""
      continue
    fi

    if [ "$state_status" = "pass" ] || [ "$state_status" = "merge_pending" ]; then
      verdict="<verdict>PASS</verdict>"
    else
      if [ "$state_status" = "reviewing" ] || [ -z "$reviewed_sha" ]; then
        reviewed_sha="$(git rev-parse HEAD 2>/dev/null)" || {
          echo "❌ No pude capturar el SHA a revisar; detengo la corrida."
          return 70
        }
      fi
      verify_reviewed_head "$pr" "$reviewed_sha"
      rc=$?
      [ "$rc" -ne 0 ] && return "$rc"
      publish_pr_state "$pr" "$num" "revisión" "$round" "$reviewed_sha" \
        "reviewing" "open" "" || return $?
      state_phase="revisión"
      state_status="reviewing"
      validate_issue_for_agent "$num" "$pr"
      rc=$?
      if [ "$rc" -eq 1 ]; then
        checkout_or_fail "$BASE_BRANCH" || return 70
        return 0
      fi
      [ "$rc" -eq 0 ] || return "$rc"
      echo "🔍 Claude revisa PR #$pr (ronda $round/$MAX_ROUNDS)..."
      run_claude "You are reviewing ONE pull request.

Pull request: #$pr   (inspect it with: gh pr view $pr, gh pr diff $pr)
Branch under review (already checked out): $branch
Base branch:                               $BASE_BRANCH

## The GitHub issue this PR must satisfy
$issue_ctx

## Review instructions
$PROMPT_REVIEW"
      rc=$?
      if [ "$rc" -eq "$TIMEOUT_RC" ] && [ "$ADAPTER_STATUS" = "timeout" ]; then
        stop_for_timeout "la revisión de Claude"
      fi
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 8 ] && [ "$rc" -ne 9 ]; then
        echo "❌ Claude terminó con rc=$rc; #$num queda abierto sin merge."
      fi
      [ "$rc" -ne 0 ] && return "$rc"
      review_body="$ADAPTER_FINAL_MESSAGE"
      # Fail-closed: sin PASS explícito y bien formado, no se mergea.
      verdict="$(printf '%s\n' "$review_body" | tail -n 1 | \
        grep -xE '<verdict>(PASS|CHANGES_REQUESTED)</verdict>' || true)"
      if [ -z "$verdict" ] && [ "$infra_retries" -lt "$MAX_INFRA_RETRIES" ]; then
        infra_retries=$((infra_retries + 1))
        backoff=$((60 * 3 ** (infra_retries - 1)))
        echo "🔁 El revisor no dejó un veredicto válido; reintento $infra_retries/$MAX_INFRA_RETRIES sin consumir ronda."
        check_run_deadline "la espera del reintento del revisor" || return $?
        if [ -n "$RUN_DEADLINE" ]; then
          deadline_now="$(date +%s 2>/dev/null)" || return 70
          deadline_remaining=$((RUN_DEADLINE - deadline_now))
          [ "$deadline_remaining" -gt 0 ] || stop_for_deadline "la espera del reintento del revisor"
          [ "$deadline_remaining" -lt "$backoff" ] && backoff="$deadline_remaining"
        fi
        sleep "$backoff"
        continue
      fi
      if [ "$verdict" = "<verdict>PASS</verdict>" ]; then
        state_status="pass"
      else
        verdict="<verdict>CHANGES_REQUESTED</verdict>"
        state_status="changes_requested"
      fi
      publish_pr_state "$pr" "$num" "revisión" "$round" "$reviewed_sha" \
        "$state_status" "open" "$review_body" || return $?
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
      elif [ "$ci_rc" -eq 70 ]; then
        return 70
      elif [ "$ci_rc" -eq 1 ]; then
        state_status="changes_requested"
        review_body="$CI_FAILURE_BODY"
        publish_pr_state "$pr" "$num" "revisión" "$round" "$reviewed_sha" \
          "$state_status" "open" "$review_body" || return $?
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
      publish_pr_state "$pr" "$num" "merge" "$round" "$reviewed_sha" \
        "merge_pending" "open" "$review_body" || return $?
      checkout_or_fail "$BASE_BRANCH" || return 70
      check_run_deadline "la solicitud de merge" || return $?
      if gh pr merge "$pr" "$MERGE_METHOD" \
          --match-head-commit "$reviewed_sha" >/dev/null 2>&1; then
        wait_for_merge "$pr"
        rc=$?
        if [ "$rc" -eq 2 ]; then
          if [ "$MERGE_PENDING_POLICY" = "stop" ]; then
            checkout_or_fail "$BASE_BRANCH" || return 70
            write_checkpoint "merge_pending para el PR #$pr; la corrida se detiene sin borrar la rama ni cerrar el issue."
            RUN_STOP_REASON="merge_pending"
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
        publish_pr_state "$pr" "$num" "merge" "$round" "$reviewed_sha" \
          "merged" "merged" "$review_body" || return $?
        # La base local debe traer el merge: los issues dependientes heredan ese código.
        if ! git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1; then
          echo "❌ No pude actualizar '$BASE_BRANCH' local con --ff-only; conservo el estado y detengo la corrida."
          return 70
        fi
        # Producción rota no admite otro despliegue encima: si el hook falla, para toda la corrida.
        if [ -n "$POST_MERGE_CHECK" ]; then
          echo "🩺 Verifico producción con $POST_MERGE_CHECK $merged_sha..."
          build_clean_ralph_env_args
          run_bounded "$AGENT_TIMEOUT_SECONDS" env \
            "${CLEAN_RALPH_ENV_ARGS[@]}" "$POST_MERGE_CHECK" "$merged_sha"
          rc=$?
          if [ "$BOUNDED_TIMED_OUT" -eq 1 ]; then
            add_label "$num" "$NEEDS_HUMAN_LABEL"
            gh issue comment "$num" --body "🤖 PR #$pr mergeado como $merged_sha pero el hook post-merge excedió el timeout. Ralph se detiene." >/dev/null 2>&1 || true
            stop_for_timeout "el hook post-merge"
          elif [ "$rc" -ne 0 ]; then
            add_label "$num" "$NEEDS_HUMAN_LABEL"
            gh issue comment "$num" --body "🤖 PR #$pr mergeado como $merged_sha pero la verificación de producción falló. Ralph se detiene." >/dev/null 2>&1 || true
            write_checkpoint "producción no verificada tras mergear PR #$pr como \`$merged_sha\`."
            RUN_STOP_REASON="production_unverified"
            exit 1
          fi
        fi
        if [ "$CLOSE_POLICY" = "verified" ] &&
            pr_body="$(gh pr view "$pr" --json body --jq .body 2>/dev/null)" &&
            printf '%s\n' "$pr_body" | grep -Eiq "(^|[^[:alnum:]])closes[[:space:]]+#[[:space:]]*$num([^[:alnum:]]|$)"; then
          gh issue close "$num" --comment "Resuelto por PR #$pr (revisado y aprobado por el revisor de ralph)." >/dev/null 2>&1 || true
          echo "🎉 #$num mergeado a $BASE_BRANCH y cerrado."
        else
          gh issue comment "$num" --body "🤖 PR #$pr mergeado como $merged_sha; el issue queda abierto (política de cierre: $CLOSE_POLICY)." >/dev/null 2>&1 || true
          echo "🎉 #$num mergeado a $BASE_BRANCH y abierto."
        fi
      else
        echo "⚠️  El merge de PR #$pr falló (¿conflictos, o checks pendientes?). Queda abierto."
        publish_pr_state "$pr" "$num" "merge" "$round" "$reviewed_sha" \
          "merge_failed" "failed" "$review_body" || return $?
        add_label "$pr" "$NEEDS_HUMAN_LABEL"
      fi
      return 0
    fi

    if [ "$state_status" = "changes_requested" ]; then
      if [ "$round" -eq "$MAX_ROUNDS" ]; then
        echo "🙋 #$num agotó las $MAX_ROUNDS rondas sin PASS. PR #$pr queda abierto para revisión humana."
        record_issue_failure "$num" "max_rounds" || return $?
        add_label "$pr" "$NEEDS_HUMAN_LABEL"
        gh pr comment "$pr" --body "🤖 Ralph agotó las $MAX_ROUNDS rondas de revisión sin alcanzar PASS. Sin merge: necesita un humano." >/dev/null 2>&1 || true
        checkout_or_fail "$BASE_BRANCH" || return 70
        return 0
      fi
      publish_pr_state "$pr" "$num" "corrección" "$round" "$reviewed_sha" \
        "correction_pending" "open" "$review_body" || return $?
      state_phase="corrección"
      state_status="correction_pending"
      continue
    fi
  done

  checkout_or_fail "$BASE_BRANCH" || return 70
  return 0
}

# --------------------------------------------------------------- selector --

populate_issue_bodies() {
  local issue_json issue_number
  while IFS= read -r issue_json; do
    [ -n "$issue_json" ] || continue
    issue_number="$(jq -r '.number' <<<"$issue_json")"
    BODY[$issue_number]="$(jq -r '.body // ""' <<<"$issue_json")"
  done <<<"${1:-}"
}

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

read_issue_body() {
  local num="$1" body
  if ! body="$(gh issue view "$num" --json body --jq '.body // ""' 2>/dev/null)"; then
    printf '❌ No pude leer el body del issue #%s; detengo la corrida.\n' "$num" >&2
    return 70
  fi
  printf '%s' "$body"
}

read_issue_state() {
  local num="$1" state
  if ! state="$(gh issue view "$num" --json state --jq '.state // empty' 2>/dev/null)"; then
    printf '❌ No pude leer el estado del issue #%s; detengo la corrida.\n' "$num" >&2
    return 70
  fi
  printf '%s' "$state"
}

read_issue_labels() {
  local num="$1" labels
  if ! labels="$(gh issue view "$num" --json labels --jq '.labels[]? | if type == "object" then .name else . end' 2>/dev/null)"; then
    printf '❌ No pude leer los labels del issue #%s; detengo la corrida.\n' "$num" >&2
    return 70
  fi
  printf '%s' "$labels"
}

read_issue_data() {
  local num="$1" rc
  ISSUE_BODY="$(read_issue_body "$num")"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ISSUE_STATE="$(read_issue_state "$num")"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ISSUE_LABELS="$(read_issue_labels "$num")"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case "$ISSUE_STATE" in
    OPEN|CLOSED) return 0 ;;
    *)
      printf '❌ El issue #%s devolvió un estado inválido; detengo la corrida.\n' "$num" >&2
      return 70
      ;;
  esac
}

issue_has_label() {
  local labels="$1" wanted="$2" label
  while IFS= read -r label; do
    [ "$label" = "$wanted" ] && return 0
  done <<<"$labels"
  return 1
}

host_requirement_for_labels() {
  local labels="$1" has_macos=0 has_linux=0
  issue_has_label "$labels" "ralph-host:macos" && has_macos=1
  issue_has_label "$labels" "ralph-host:linux" && has_linux=1
  if [ "$has_macos" -eq 1 ] && [ "$has_linux" -eq 1 ]; then
    return 2
  elif [ "$has_macos" -eq 1 ]; then
    printf '%s\n' macos
  elif [ "$has_linux" -eq 1 ]; then
    printf '%s\n' linux
  else
    printf '%s\n' any
  fi
  return 0
}

host_requirement_matches() {
  local required="$1"
  [ "$required" = any ] || [ "$required" = "$HOST_KIND" ]
}

pr_needs_human() {
  local pr="$1" labels
  [ -z "$pr" ] && return 1
  if ! labels="$(gh pr view "$pr" --json labels --jq '.labels[].name' 2>/dev/null)"; then
    printf '❌ No pude leer los labels del PR #%s; detengo la corrida.\n' "$pr" >&2
    return 70
  fi
  printf '%s\n' "$labels" | grep -Fqx "$NEEDS_HUMAN_LABEL"
}

validate_issue_for_agent() {
  local num="$1" pr="${2:-}" blockers blocked_by_error b state rc host_required

  read_issue_data "$num"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if [ "$ISSUE_STATE" != "OPEN" ]; then
    echo "⏭️  #$num ya no está abierto; no invoco agentes."
    return 1
  fi
  if ! issue_has_label "$ISSUE_LABELS" "$LABEL"; then
    echo "⏭️  #$num ya no tiene el label '$LABEL'; no invoco agentes."
    return 1
  fi
  if issue_has_label "$ISSUE_LABELS" "$NEEDS_HUMAN_LABEL"; then
    echo "🙋 #$num marcado con $NEEDS_HUMAN_LABEL; no invoco agentes."
    record_issue_failure "$num" "needs_human" "$pr" || return $?
    return 1
  fi

  host_required="$(host_requirement_for_labels "$ISSUE_LABELS")"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "🚫 #$num bloqueado: labels de host contradictorios (ralph-host:macos y ralph-host:linux)."
    return 1
  elif [ "$rc" -ne 0 ]; then
    return 70
  fi
  if ! host_requirement_matches "$host_required"; then
    echo "⏭️  #$num requiere host $host_required, actual $HOST_KIND; lo omito."
    return 1
  fi

  blockers="$(printf '%s' "$ISSUE_BODY" | section_refs 'Blocked by')"
  blocked_by_error="$(printf '%s' "$ISSUE_BODY" | validate_blocked_by)"
  if [ -n "$blocked_by_error" ]; then
    echo "🚫 #$num bloqueado: formato inválido en ## Blocked by: $blocked_by_error"
    return 1
  fi
  for b in $blockers; do
    state="$(read_issue_state "$b")"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ "$state" != "CLOSED" ]; then
      echo "⏭️  #$num bloqueado por dependencias abiertas, no invoco agentes."
      return 1
    fi
  done

  if [ -n "$pr" ]; then
    pr_needs_human "$pr"
    rc=$?
    [ "$rc" -eq 70 ] && return "$rc"
    if [ "$rc" -eq 0 ]; then
      echo "🙋 PR #$pr espera revisión humana; no invoco agentes."
      record_issue_failure "$num" "needs_human" "$pr" || return $?
      return 1
    fi
  fi
  return 0
}

print_plan_issue() {
  local num="$1" priority="$2" host_required="$3" parents="$4" blockers="$5" needs_human="$6" pr="$7" exclusion="$8"
  local pr_text="${pr:-none}"
  printf '#%s priority=%s host=%s current=%s parents=%s blockers=%s needs-human=%s pr=%s' \
    "$num" "$priority" "$host_required" "$HOST_KIND" "$(refs_csv "$parents")" \
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
  local epics p b state pr needs_human exclusion rc blocked_by_error host_required host_rc
  local candidate_issues all_issues

  while [ "$progress" -eq 1 ]; do
    progress=0
    if ! candidate_issues="$(gh issue list --state open --label "$LABEL" \
      --limit "$ISSUE_QUERY_LIMIT" --json number,body,state,labels \
      --jq 'sort_by(.number) | .[] | @json')"; then
      echo "❌ No pude listar los issues candidatos; detengo la corrida."
      return 70
    fi
    numbers="$(printf '%s\n' "$candidate_issues" | jq -r '.number' | apply_issue_order)"
    [ -z "$numbers" ] && break

    # Cachear cuerpos de todos los issues, no sólo de los candidatos: un hijo
    # cerrado o sin label sigue haciendo épico a su padre.
    unset BODY ISSUE_STATE_BY_ISSUE ISSUE_LABELS_BY_ISSUE
    declare -A BODY ISSUE_STATE_BY_ISSUE ISSUE_LABELS_BY_ISSUE
    populate_issue_bodies "$candidate_issues"
    if ! all_issues="$(gh issue list --state all --limit "$ISSUE_QUERY_LIMIT" \
      --json number,body --jq 'sort_by(.number) | .[] | @json')"; then
      echo "❌ No pude listar todos los issues para detectar padres; detengo la corrida."
      return 70
    fi
    populate_issue_bodies "$all_issues"

    # En modo normal se releen body, estado y labels antes de crear la rama.
    # El plan usa los mismos datos del listado para seguir siendo una operación
    # de sólo lectura y evitar consultas por issue innecesarias.
    while IFS= read -r issue_json; do
      [ -n "$issue_json" ] || continue
      n="$(jq -r '.number' <<<"$issue_json")"
      if [ "$mode" = "run" ]; then
        read_issue_data "$n"
        rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        BODY[$n]="$ISSUE_BODY"
        ISSUE_STATE_BY_ISSUE[$n]="$ISSUE_STATE"
        ISSUE_LABELS_BY_ISSUE[$n]="$ISSUE_LABELS"
      else
        ISSUE_STATE_BY_ISSUE[$n]="$(jq -r '.state // empty' <<<"$issue_json")"
        ISSUE_LABELS_BY_ISSUE[$n]="$(jq -r '.labels[]? | if type == "object" then .name else . end' <<<"$issue_json")"
      fi
    done <<<"$candidate_issues"

    epics=" "
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      for p in $(printf '%s' "${BODY[$n]}" | section_refs 'Parent'); do
        epics="$epics$p "
      done
    done < <(printf '%s\n' "$all_issues" | jq -r '.number')

    priority=0
    for num in $numbers; do
      priority=$((priority + 1))
      parents="$(printf '%s' "${BODY[$num]}" | section_refs 'Parent')"
      blockers="$(printf '%s' "${BODY[$num]}" | section_refs 'Blocked by')"
      blocked_by_error="$(printf '%s' "${BODY[$num]}" | validate_blocked_by)"
      host_required="$(host_requirement_for_labels "${ISSUE_LABELS_BY_ISSUE[$num]}")"
      host_rc=$?
      if [ "$host_rc" -eq 2 ]; then
        echo "🚫 #$num bloqueado: labels de host contradictorios (ralph-host:macos y ralph-host:linux)."
        if [ "$mode" = "plan" ]; then
          print_plan_issue "$num" "$priority" conflict "$parents" "$blockers" \
            no "" host-conflict
        fi
        continue
      elif [ "$host_rc" -ne 0 ]; then
        echo "❌ No pude determinar el host requerido para #$num; detengo la corrida."
        return 70
      fi
      if ! host_requirement_matches "$host_required"; then
        echo "⏭️  #$num requiere host $host_required, actual $HOST_KIND; lo omito."
        if [ "$mode" = "plan" ]; then
          print_plan_issue "$num" "$priority" "$host_required" "$parents" "$blockers" \
            no "" "host:$host_required"
        fi
        continue
      fi
      open_blockers=""
      for b in $blockers; do
        state="$(read_issue_state "$b")"
        rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        if [ "$state" != "CLOSED" ]; then
          [ -n "$open_blockers" ] && open_blockers="$open_blockers"$'\n'
          open_blockers="${open_blockers}${b}"
        fi
      done

      pr="$(pr_for_branch "${BRANCH_PREFIX}${num}" "$num")"
      rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      needs_human=no
      issue_has_label "${ISSUE_LABELS_BY_ISSUE[$num]}" "$NEEDS_HUMAN_LABEL" && needs_human=yes
      if [ -n "$pr" ]; then
        pr_needs_human "$pr"
        rc=$?
        [ "$rc" -eq 70 ] && return "$rc"
        [ "$rc" -eq 0 ] && needs_human=yes
      fi

      if [ -n "$blocked_by_error" ]; then
        echo "🚫 #$num bloqueado: formato inválido en ## Blocked by: $blocked_by_error"
        if [ "$mode" = "plan" ]; then
          print_plan_issue "$num" "$priority" "$host_required" "$parents" "$blockers" \
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
        print_plan_issue "$num" "$priority" "$host_required" "$parents" "$blockers" \
          "$needs_human" "$pr" "$exclusion"
        continue
      fi

      # Ya intentado en esta corrida: no reprocesar.
      case "$attempted" in *" $num "*) continue;; esac
      # Es un épico/padre (lo referencia otro issue): no se implementa.
      case "$epics" in *" $num "*) echo "↪️  #$num es épico/padre, lo omito."; continue;; esac

      if [ "${ISSUE_STATE_BY_ISSUE[$num]}" != "OPEN" ]; then
        echo "⏭️  #$num ya no está abierto; lo omito."
        continue
      fi
      if ! issue_has_label "${ISSUE_LABELS_BY_ISSUE[$num]}" "$LABEL"; then
        echo "⏭️  #$num ya no tiene el label '$LABEL'; lo omito."
        continue
      fi
      if issue_has_label "${ISSUE_LABELS_BY_ISSUE[$num]}" "$NEEDS_HUMAN_LABEL"; then
        echo "🙋 #$num marcado con $NEEDS_HUMAN_LABEL; no lo toco."
        record_issue_failure "$num" "needs_human" "$pr" || return $?
        continue
      fi

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
        record_run_event "issue_blocked" "$num" "$pr" "blocked" "open blockers" "$open_blockers" || return $?
        continue
      fi
      if [ "$needs_human" = yes ]; then
        echo "🙋 PR #$pr espera revisión humana; no lo toco."
        record_issue_failure "$num" "needs_human" "$pr" || return $?
        continue
      fi

      start_next_issue || return $?

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
            RUN_STOP_REASON="usage_limit"
            exit 0
          fi
          limit_retries=$((limit_retries + 1))
          check_run_deadline "el reintento por tope del issue #$num" || exit $?
          wait_for_reset "$num"
          wait_rc=$?
          if [ "$wait_rc" -eq 2 ]; then
            write_checkpoint "deadline global alcanzado antes del reset del proveedor para #$num."
            RUN_STOP_REASON="deadline"
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
  CURRENT_PHASE="lectura del lock remoto"
  inspect_remote_lock
  lock_rc=$?
  [ "$lock_rc" -eq 0 ] || exit 70
  case "$LOCK_STATE" in
    active)
      echo "🔒 Lock remoto activo: host=$LOCK_REMOTE_HOST pid=$LOCK_REMOTE_PID heartbeat=$LOCK_REMOTE_HEARTBEAT_AT; dry-run sólo lo lee."
      ;;
    stale)
      echo "⚠️  Lock remoto vencido: host=$LOCK_REMOTE_HOST pid=$LOCK_REMOTE_PID; dry-run no lo reclama."
      ;;
  esac
  print_plan
else
  run_provider_preflight || exit $?
  run_sandbox_preflight || exit $?
  run_base_ci_preflight || exit $?
  run_smoke_test || exit $?
  # Label con el que marcamos los PRs que agotaron las rondas.
  gh label create "$NEEDS_HUMAN_LABEL" --color B60205 \
    --description "Ralph agotó las rondas de revisión; necesita un humano" >/dev/null 2>&1 || true
  select_issues run
  rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  if [ "$RUN_FAILED_ISSUES" -gt 0 ]; then
    RUN_STOP_REASON="issues_failed"
  else
    RUN_STOP_REASON="no_ready_issues"
  fi
  echo "🏁 No quedan issues '$LABEL' listos para procesar."
fi
