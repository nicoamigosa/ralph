#!/usr/bin/env bash
# Only presentation and process launch live here. once.sh owns all policy.
set +x
set +v
set -euo pipefail
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RALPH_DIR="$(cd "$HELPER_DIR/../../.." && pwd -P)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
fail() { printf '%s\n' "$*" >&2; exit 1; }

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
  gh auth status >/dev/null 2>&1 || fail 'gh auth status: ausente o inválido'
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

plan() {
  local rc=0
  bash "$RALPH_DIR/update.sh" --check || rc=$?
  case "$rc" in 0|10) ;; *) return "$rc" ;; esac
  check_config
  RALPH_DRY_RUN=1 bash "$RALPH_DIR/once.sh"
}

report() {
  local run_id="${1:-}" summary path
  if [ -z "$run_id" ]; then
    for path in "$RALPH_DIR"/runs/*/summary.json; do
      [ -f "$path" ] || continue
      run_id="${path%/summary.json}"
      run_id="${run_id##*/}"
    done
  fi
  case "$run_id" in ''|*[!A-Za-z0-9_-]*) fail 'run-id ausente o inválido' ;; esac
  summary="$RALPH_DIR/runs/$run_id/summary.json"
  [ -f "$summary" ] || fail 'No existe summary.json para esa corrida'
  jq -er '
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
  ' "$summary" || fail 'No se pudo interpretar summary.json; resultado desconocido'
}

case "${1:-plan}" in
  plan)
    [ "$#" -le 1 ] || fail 'Uso: ralph.sh plan'
    plan
    ;;
  run)
    if [ "$#" -ne 2 ] || [ "$2" != --confirmed ]; then
      fail 'Ejecuta plan y pide confirmación explícita antes de run --confirmed.'
    fi
    check_config run
    launch
    ;;
  report)
    [ "$#" -le 2 ] || fail 'Uso: ralph.sh report [run-id]'
    report "${2:-}"
    ;;
  *) fail 'Uso: ralph.sh [plan|run --confirmed|report [run-id]]' ;;
esac
