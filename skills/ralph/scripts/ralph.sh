#!/usr/bin/env bash
# Only presentation and process launch live here. once.sh owns all policy.
set +x
set +v
set -euo pipefail
usage() {
  cat <<'HELP'
Uso: ralph.sh [plan [--json]|run --confirmed|report [run-id] [--json]]
  plan: comprueba actualización, requisitos y selector de sólo lectura.
  run --confirmed: lanza once.sh después de confirmar explícitamente el plan.
  report [run-id]: interpreta summary.json; sin ID usa el último resumen.
  --json: objeto schema=1 en stdout para plan/report; texto por defecto.
Códigos de salida:
  0: éxito (en run sólo lanzamiento, no resultado de la corrida)
  2: uso incorrecto o confirmación ausente
  3: configuración ausente o inválida
  4: autenticación de GitHub ausente o inválida
  5: resumen ausente, ilegible o incompleto
  6: fallo de once.sh durante plan
  20: consulta de actualización fallida
El código 10 de update.sh --check (actualización disponible) no bloquea plan.
HELP
}
if [ "${1:-}" = --help ] && [ "$#" -eq 1 ]; then
  usage
  exit 0
fi
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RALPH_DIR="$(cd "$HELPER_DIR/../../.." && pwd -P)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
fail() { printf '%s\n' "$*" >&2; exit "${ERROR_CODE:-3}"; }

launch() {
  local launch_pid
  local -a launcher=(nohup)
  umask 077
  mkdir -p "$RALPH_DIR/runs"
  launch_log="$(mktemp "$RALPH_DIR/runs/launch.XXXXXX")"
  # Separate the process group as well as ignoring terminal hangups. macOS
  # need not provide setsid: Bash job control creates an independent group.
  set +m
  if command -v setsid >/dev/null 2>&1; then
    launcher+=(setsid)
  else
    set -m
  fi
  "${launcher[@]}" bash "$RALPH_DIR/once.sh" </dev/null >"$launch_log" 2>&1 &
  launch_pid=$!
  set +m
  printf 'PID: %s\nLog de lanzamiento: %s\n' "$launch_pid" "$launch_log"
}

check_config() (
  # Never display config files, values, or authentication diagnostics.
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=../../../lib/config.sh
  source "$RALPH_DIR/lib/config.sh" >/dev/null 2>&1
  if [ "${1:-plan}" = json ]; then
    local rc=0
    if gh auth status >/dev/null 2>&1; then printf '%s\n' 'gh auth status: presente'; else rc=4; fi
    if [ -n "${RALPH_TDD_SKILL:-}" ]; then printf '%s\n' 'RALPH_TDD_SKILL: presente'; else [ "$rc" -ne 0 ] || rc=3; fi
    if [ -n "${RALPH_REVIEWER_GH_TOKEN:-}" ]; then printf '%s\n' 'RALPH_REVIEWER_GH_TOKEN: presente'; else [ "$rc" -ne 0 ] || rc=3; fi
    return "$rc"
  fi
  gh auth status >/dev/null 2>&1 || ERROR_CODE=4 fail 'gh auth status: ausente o inválido'
  printf '%s\n' 'gh auth status: presente'
  [ -n "${RALPH_TDD_SKILL:-}" ] || fail 'RALPH_TDD_SKILL: ausente'
  printf '%s\n' 'RALPH_TDD_SKILL: presente'
  [ -n "${RALPH_REVIEWER_GH_TOKEN:-}" ] || fail 'RALPH_REVIEWER_GH_TOKEN: ausente'
  printf '%s\n' 'RALPH_REVIEWER_GH_TOKEN: presente'
  if [ "${1:-plan}" = run ]; then
    [ "${RALPH_REQUIRE_PROTECTION:-1}" = 1 ] || fail 'run requiere protección de la base'
    [ "${RALPH_REQUIRE_REVIEWER_TOKEN:-1}" = 1 ] || fail 'run requiere token del revisor'
    [ "${RALPH_DRY_RUN:-0}" = 0 ] || fail 'run requiere RALPH_DRY_RUN=0'
  fi
)

# JSON contains only selected fields, never raw configuration or diagnostics.
plan_json() {
  local update_rc=0 config_rc=0 once_rc=0 update_output config_output dry_output=''
  update_output="$(bash "$RALPH_DIR/update.sh" --check 2>/dev/null)" || update_rc=$?
  config_output="$(check_config json 2>/dev/null)" || config_rc=$?
  if [ "$update_rc" -eq 0 ] || [ "$update_rc" -eq 10 ]; then
    if [ "$config_rc" -eq 0 ]; then
      dry_output="$(RALPH_DRY_RUN=1 bash "$RALPH_DIR/once.sh" 2>/dev/null)" || once_rc=$?
    fi
  fi
  jq -n --arg update "$update_output" --argjson update_rc "$update_rc" \
    --arg config "$config_output" --argjson config_rc "$config_rc" \
    --arg dry "$dry_output" --argjson once_rc "$once_rc" '
    ($dry | split("\n") | map(select(test("^#[0-9]+ priority=")) |
      capture("^#(?<number>[0-9]+) priority=(?<priority>[0-9]+) host=(?<host>[^ ]+) current=(?<current>[^ ]+) parents=(?<parents>[^ ]+) blockers=(?<blockers>[^ ]+) needs-human=(?<needs_human>yes|no) pr=(?<pr>[^ ]+)( excluded=(?<reason>[^ ]+))?$") |
      .number |= tonumber | .priority |= tonumber |
      .pr |= (if . == "none" then null else tonumber end))) as $rows |
    {schema:1, mode:"plan", success: (($update_rc == 0 or $update_rc == 10) and $config_rc == 0 and $once_rc == 0),
     update:{status:(if $update_rc == 0 then "current" elif $update_rc == 10 then "available" else "unknown" end),
       version: ((try ($update | capture("^actualización disponible: (?<v>v[0-9]+\\.[0-9]+\\.[0-9]+)$").v) catch null) // null)},
     requirements:{gh_auth:($config | contains("gh auth status: presente")),
       tdd_skill:($config | contains("RALPH_TDD_SKILL: presente")),
       reviewer_token:($config | contains("RALPH_REVIEWER_GH_TOKEN: presente"))},
     candidates:(if ($update_rc == 0 or $update_rc == 10) and $once_rc == 0 and $config_rc == 0 then [$rows[] | select(.reason == null)] else null end),
     excluded:(if ($update_rc == 0 or $update_rc == 10) and $once_rc == 0 and $config_rc == 0 then [$rows[] | select(.reason != null)] else null end)}'
  case "$update_rc" in 0|10) ;; *) return 20 ;; esac
  [ "$config_rc" -eq 0 ] || return "$config_rc"
  [ "$once_rc" -eq 0 ] || return 6
}

plan() {
  local rc=0
  bash "$RALPH_DIR/update.sh" --check || rc=$?
  case "$rc" in 0|10) ;; *) return 20 ;; esac
  check_config
  RALPH_DRY_RUN=1 bash "$RALPH_DIR/once.sh" || return 6
}

report() {
  local run_id="${1:-}" summary path
  local json="${2:-false}"
  if [ -z "$run_id" ]; then
    for path in "$RALPH_DIR"/runs/*/summary.json; do
      [ -f "$path" ] || continue
      run_id="${path%/summary.json}"
      run_id="${run_id##*/}"
    done
  fi
  [ -n "$run_id" ] || ERROR_CODE=5 fail 'run-id ausente o inválido'
  case "$run_id" in *[!A-Za-z0-9_-]*) ERROR_CODE=2 fail 'run-id ausente o inválido' ;; esac
  ERROR_CODE=5
  summary="$RALPH_DIR/runs/$run_id/summary.json"
  [ -f "$summary" ] || fail 'No existe summary.json para esa corrida'
  jq -er --argjson json "$json" '
    if .schema != 1 or (.run_id | type) != "string" or .run_id == "" or
       (.stop_reason | type) != "string" or .stop_reason == "" or
       (.issues_started | type) != "number" or
       (.issues | type) != "array" or (.usage | type) != "object" or
       (.merged | type) != "array" or (.open_prs | type) != "array" or
       (.needs_human | type) != "array" or (.blocked | type) != "array" or
       (.errors | type) != "array"
    then error("summary incompleto") else . end |
    def meaning:
      {running:"en curso", completed:"corrida completada", run_failed:"corrida fallida",
       no_ready_issues:"sin candidatos",
       max_issues:"límite de issues", deadline:"plazo agotado",
       budget:"presupuesto estimado agotado", usage_limit:"límite del proveedor",
       timeout:"tiempo de agente agotado", ci_infrastructure:"infraestructura de CI",
       merge_pending:"merge sin confirmar", production_unverified:"post-merge sin verificar",
       issue_failed:"issue fallido", issues_failed:"issues fallidos"}[.] //
       (if startswith("signal:") then "interrumpida por señal" else "motivo desconocido" end);
    def next_step($reason):
      if .stop_reason == "running" then "Esperar el resultado de esta corrida."
      elif (.needs_human // [] | length) > 0 then
        "Revisar el PR #\(.needs_human[0].pr // "desconocido") en ralph-needs-human."
      elif .stop_reason == "usage_limit" then "Esperar al reset documentado en retry_at del adaptador."
      elif (["completed","no_ready_issues","max_issues","deadline","timeout"] | index($reason)) != null or
           (.stop_reason | startswith("signal:")) then "Reanudar con /ralph run tras consultar last_run.md."
      elif (["merge_pending","production_unverified","issue_failed","issues_failed"] | index($reason)) != null then
        "Revisar el PR #\((.open_prs[0].pr // .merged[-1].pr) // "desconocido") y su checkpoint antes de reanudar."
      else "Corregir la configuración o infraestructura indicada en los artefactos antes de reanudar."
      end;
    .stop_reason as $reason |
    if $json then
      {schema:1, mode:"report", run_id, stop_reason, issues_started, issues,
       merged, open_prs, needs_human, blocked,
       protection:(.protection // null),
       usage:{claude_estimated_usd:(.usage.claude_estimated_usd // null),
         codex_tokens:(.usage.codex_tokens // null)}, next_step:next_step($reason)}
    else
    "Corrida: \(.run_id)\nstop_reason: \(.stop_reason) — \(.stop_reason | meaning)",
    "Issues iniciados: \(.issues_started // "desconocido")",
    "Issues: \(.issues | tojson)",
    "Merges: \((.merged // []) | tojson)",
    "PR abiertos: \((.open_prs // []) | tojson)",
    "Needs-human: \((.needs_human // []) | tojson)",
    "Bloqueados: \((.blocked // []) | tojson)",
    "Protección: \((.protection // "desconocida") | tojson)",
    "Claude USD estimado: \(.usage.claude_estimated_usd // "desconocido"); Codex tokens: \(.usage.codex_tokens // "desconocido")",
    "Siguiente paso: \(next_step($reason))"
    end
  ' "$summary" || fail 'No se pudo interpretar summary.json; resultado desconocido'
}

ERROR_CODE=2
case "${1:-plan}" in
  plan)
    if [ "$#" -eq 2 ] && [ "$2" = --json ]; then
      ERROR_CODE=3
      plan_json
    else
      [ "$#" -le 1 ] || fail 'Uso: ralph.sh plan [--json]'
      ERROR_CODE=3
      plan
    fi
    ;;
  run)
    if [ "$#" -ne 2 ] || [ "$2" != --confirmed ]; then
      fail 'Ejecuta plan y pide confirmación explícita antes de run --confirmed.'
    fi
    ERROR_CODE=3
    check_config run
    launch
    ;;
  report)
    shift
    report_id='' report_json=false
    if [ "${1:-}" != --json ] && [ "$#" -gt 0 ]; then
      report_id="$1"
      shift
    fi
    if [ "${1:-}" = --json ]; then
      report_json=true
      shift
    fi
    [ "$#" -eq 0 ] || fail 'Uso: ralph.sh report [run-id] [--json]'
    report "$report_id" "$report_json"
    ;;
  *) fail 'Uso: ralph.sh [plan|run --confirmed|report [run-id]]' ;;
esac
