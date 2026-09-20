#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 5 )); then
  printf '❌ La suite de integración requiere Bash >= 5.\n' >&2
  exit 2
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TARGET_SLUG="${REPO_SLUG:-nicoamigosa/ralph-sandbox}"
ALLOWLIST="${RALPH_SANDBOX_SLUGS:-nicoamigosa/ralph-sandbox}"
SCENARIOS="${RALPH_INTEGRATION_SCENARIOS:-pass-green pass-red rejection agent-error}"

die() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

valid_slug() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

valid_slug "$TARGET_SLUG" || {
  printf '❌ REPO_SLUG debe tener el formato owner/repository.\n' >&2
  exit 2
}

target_is_allowlisted=0
for allowed_slug in $ALLOWLIST; do
  valid_slug "$allowed_slug" || {
    printf '❌ RALPH_SANDBOX_SLUGS contiene un slug inválido: %s.\n' "$allowed_slug" >&2
    exit 2
  }
  if [ "$TARGET_SLUG" = "$allowed_slug" ]; then
    target_is_allowlisted=1
  fi
done

if [ "$target_is_allowlisted" -ne 1 ]; then
  printf '❌ REPO_SLUG=%s no pertenece al allowlist RALPH_SANDBOX_SLUGS=%s; no se escribe en GitHub.\n' \
    "$TARGET_SLUG" "$ALLOWLIST" >&2
  exit 2
fi

case "$SCENARIOS" in
  *[!A-Za-z0-9_\ -]*) die "RALPH_INTEGRATION_SCENARIOS contiene caracteres inválidos." ;;
esac

for command_name in bash date gh git jq mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || die "Falta '$command_name' en el PATH."
done

[ -n "${GH_TOKEN:-}" ] || die "Configurá GH_TOKEN con un token de escritura del sandbox."
[ -n "${RALPH_REVIEWER_GH_TOKEN:-}" ] || \
  die "Configurá RALPH_REVIEWER_GH_TOKEN con un token de lectura distinto."
[ "$GH_TOKEN" != "$RALPH_REVIEWER_GH_TOKEN" ] || \
  die "GH_TOKEN y RALPH_REVIEWER_GH_TOKEN deben ser distintos."

case "$SCENARIOS" in
  *pass-green*|*pass-red*|*rejection*|*agent-error*) ;;
  *) die "No hay escenarios de integración seleccionados." ;;
esac

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-integration.XXXXXX")"
cleanup_temp() {
  rm -rf "$temp_dir"
}
trap cleanup_temp EXIT

# gh auth setup-git queda aislado en un archivo temporal. Los pushes del agente
# falso usan GH_TOKEN sin modificar la configuración del usuario.
export GIT_CONFIG_GLOBAL="$temp_dir/gitconfig"
gh auth setup-git >/dev/null

repo_dir="$temp_dir/sandbox"
resolved_slug="$(gh repo view "$TARGET_SLUG" --json nameWithOwner --jq '.nameWithOwner')" || \
  die "No pude leer el repositorio sandbox '$TARGET_SLUG'."
[ "$resolved_slug" = "$TARGET_SLUG" ] || \
  die "GitHub resolvió '$resolved_slug', distinto de REPO_SLUG='$TARGET_SLUG'."

default_branch="$(gh repo view "$TARGET_SLUG" --json defaultBranchRef --jq '.defaultBranchRef.name')" || \
  die "No pude resolver la rama base de '$TARGET_SLUG'."
[ -n "$default_branch" ] || die "El sandbox no tiene rama base."

gh repo clone "$TARGET_SLUG" "$repo_dir" >/dev/null || \
  die "No pude clonar '$TARGET_SLUG'."
git -C "$repo_dir" config user.name "ralph integration"
git -C "$repo_dir" config user.email "ralph-integration@example.invalid"

run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
scenario_failure=0
CURRENT_PR=""

issue_number_from_url() {
  local url="$1" number
  number="${url##*/}"
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$number" ;;
  esac
}

find_pr_json() {
  local branch="$1"
  gh pr list --repo "$TARGET_SLUG" --state all --head "$branch" --limit 20 \
    --json number,state,headRefName,mergedAt,mergeCommit |
    jq -c --arg branch "$branch" '[.[] | select(.headRefName == $branch)] | sort_by(.number) | last // empty'
}

remote_branch_exists() {
  local branch="$1"
  gh api "repos/$TARGET_SLUG/git/ref/heads/$branch" >/dev/null 2>&1
}

record_failure() {
  printf '❌ %s\n' "$*" >&2
  scenario_failure=1
}

cleanup_scenario() {
  local issue="$1" branch="$2" pr="$3" issue_state pr_state pr_json

  if [ -z "$pr" ]; then
    pr_json="$(find_pr_json "$branch" 2>/dev/null || true)"
    pr="$(jq -r '.number // empty' <<<"$pr_json")"
  fi

  if [ -n "$pr" ]; then
    pr_state="$(gh pr view "$pr" --repo "$TARGET_SLUG" --json state --jq '.state' 2>/dev/null || true)"
    if [ "$pr_state" = "OPEN" ]; then
      gh pr close "$pr" --repo "$TARGET_SLUG" --delete-branch \
        --comment "Cierre automático de la suite de integración $run_id." >/dev/null 2>&1 || \
        record_failure "No pude cerrar el PR de limpieza #$pr."
    fi
  fi

  if remote_branch_exists "$branch"; then
    gh api --method DELETE "repos/$TARGET_SLUG/git/refs/heads/$branch" >/dev/null 2>&1 || \
      record_failure "No pude borrar la rama de limpieza '$branch'."
  fi

  issue_state="$(gh issue view "$issue" --repo "$TARGET_SLUG" --json state --jq '.state' 2>/dev/null || true)"
  if [ "$issue_state" = "OPEN" ]; then
    gh issue close "$issue" --repo "$TARGET_SLUG" \
      --comment "Cierre automático de la suite de integración $run_id." >/dev/null 2>&1 || \
      record_failure "No pude cerrar el issue de limpieza #$issue."
  fi
}

assert_cleanup_state() {
  local scenario="$1" issue="$2" branch="$3" pr="$4" pr_state issue_state

  issue_state="$(gh issue view "$issue" --repo "$TARGET_SLUG" --json state --jq '.state' 2>/dev/null || true)"
  [ "$issue_state" = "CLOSED" ] || \
    record_failure "$scenario dejó el issue #$issue abierto después de cleanup."
  if remote_branch_exists "$branch"; then
    record_failure "$scenario dejó la rama '$branch' después de cleanup."
  fi
  if [ -n "$pr" ]; then
    pr_state="$(gh pr view "$pr" --repo "$TARGET_SLUG" --json state --jq '.state' 2>/dev/null || true)"
    case "$pr_state" in
      CLOSED|MERGED) ;;
      *) record_failure "$scenario dejó el PR #$pr en estado '${pr_state:-desconocido}' después de cleanup." ;;
    esac
  else
    record_failure "$scenario no pudo localizar su PR después de cleanup."
  fi
}

prepare_base() {
  git -C "$repo_dir" checkout "$default_branch" >/dev/null 2>&1 || return 1
  git -C "$repo_dir" fetch -q origin "$default_branch" || return 1
  git -C "$repo_dir" pull -q --ff-only origin "$default_branch" || return 1
}

assert_scenario_state() {
  local scenario="$1" issue="$2" branch="$3" once_rc="$4"
  local pr_json pr pr_state issue_state branch_exists comments

  pr="${CURRENT_PR:-}"
  if [ -z "$pr" ]; then
    pr_json="$(find_pr_json "$branch")" || {
      record_failure "No pude leer el PR de '$branch'."
      return
    }
    pr="$(jq -r '.number // empty' <<<"$pr_json")"
  fi
  if [ -n "$pr" ]; then
    pr_state="$(gh pr view "$pr" --repo "$TARGET_SLUG" --json state --jq '.state')" || {
      record_failure "No pude leer el estado del PR #$pr."
      return
    }
  else
    pr_state=""
  fi
  issue_state="$(gh issue view "$issue" --repo "$TARGET_SLUG" --json state --jq '.state')" || {
    record_failure "No pude leer el estado remoto del issue #$issue."
    return
  }
  if remote_branch_exists "$branch"; then
    branch_exists=1
  else
    branch_exists=0
  fi

  case "$scenario" in
    pass-green)
      [ "$once_rc" -eq 0 ] || record_failure "pass-green terminó con rc=$once_rc."
      [ "$pr_state" = "MERGED" ] || record_failure "pass-green no dejó el PR mergeado."
      [ "$issue_state" = "CLOSED" ] || record_failure "pass-green no cerró el issue #$issue."
      [ "$branch_exists" -eq 0 ] || record_failure "pass-green dejó la rama remota."
      ;;
    pass-red)
      [ "$once_rc" -eq 0 ] || record_failure "pass-red terminó con rc=$once_rc."
      [ "$pr_state" = "OPEN" ] || record_failure "pass-red no dejó el PR abierto."
      [ "$issue_state" = "OPEN" ] || record_failure "pass-red cerró inesperadamente el issue #$issue."
      [ "$branch_exists" -eq 1 ] || record_failure "pass-red no dejó la rama remota."
      ;;
    rejection)
      [ "$once_rc" -eq 0 ] || record_failure "rejection terminó con rc=$once_rc."
      [ "$pr_state" = "OPEN" ] || record_failure "rejection no dejó el PR abierto."
      [ "$issue_state" = "OPEN" ] || record_failure "rejection cerró inesperadamente el issue #$issue."
      [ "$branch_exists" -eq 1 ] || record_failure "rejection no dejó la rama remota."
      comments="$(gh pr view "$pr" --repo "$TARGET_SLUG" --json comments --jq '.comments[].body')" || true
      grep -Fq '<verdict>CHANGES_REQUESTED</verdict>' <<<"$comments" || \
        record_failure "rejection no publicó el veredicto de rechazo en el PR."
      ;;
    agent-error)
      [ "$once_rc" -ne 0 ] || record_failure "agent-error terminó exitosamente."
      [ "$pr_state" = "OPEN" ] || record_failure "agent-error no dejó el PR abierto."
      [ "$issue_state" = "OPEN" ] || record_failure "agent-error cerró inesperadamente el issue #$issue."
      [ "$branch_exists" -eq 1 ] || record_failure "agent-error no dejó la rama remota."
      ;;
  esac

  printf '  estado: scenario=%s issue=#%s pr=#%s pr_state=%s issue_state=%s branch=%s once_rc=%s\n' \
    "$scenario" "$issue" "${pr:-none}" "${pr_state:-none}" "$issue_state" \
    "$branch_exists" "$once_rc"
  CURRENT_PR="$pr"
}

run_scenario() {
  local scenario="$1" title issue_url issue branch scenario_dir once_rc

  prepare_base || {
    record_failure "No pude preparar '$default_branch' antes de '$scenario'."
    return
  }
  title="[ralph integration $run_id] $scenario"
  issue_url="$(gh issue create --repo "$TARGET_SLUG" --title "$title" \
    --body "Escenario de integración: $scenario.\n\nLa suite lo cerrará al terminar la verificación." \
    --label ready-for-agent)" || {
      record_failure "No pude crear el issue para '$scenario'."
      return
    }
  issue="$(issue_number_from_url "$issue_url")" || {
    record_failure "gh issue create devolvió una URL ilegible para '$scenario'."
    return
  }
  branch="ralph/issue-$issue"
  scenario_dir="$temp_dir/$scenario"
  mkdir -p "$scenario_dir"
  : > "$scenario_dir/host.env"

  printf '▶ escenario=%s issue=#%s branch=%s\n' "$scenario" "$issue" "$branch"
  if (
    cd "$repo_dir"
    export PATH="$SCRIPT_DIR/bin:$PATH"
    export RALPH_INTEGRATION_SCENARIO="$scenario"
    export RALPH_INTEGRATION_REPO_SLUG="$TARGET_SLUG"
    export RALPH_INTEGRATION_BASE_BRANCH="$default_branch"
    export RALPH_INTEGRATION_RUN_ID="$run_id"
    export RALPH_BASE_BRANCH="$default_branch"
    export RALPH_BRANCH_PREFIX=ralph/issue-
    export RALPH_LABEL=ready-for-agent
    export RALPH_MAX_ISSUES=1
    export RALPH_MAX_ROUNDS=1
    export RALPH_MAX_RUN_SECONDS="${RALPH_INTEGRATION_MAX_RUN_SECONDS:-1800}"
    export RALPH_AGENT_TIMEOUT_SECONDS="${RALPH_INTEGRATION_AGENT_TIMEOUT_SECONDS:-600}"
    export RALPH_CI_TIMEOUT_SECONDS="${RALPH_INTEGRATION_CI_TIMEOUT_SECONDS:-600}"
    export RALPH_MERGE_TIMEOUT_SECONDS="${RALPH_INTEGRATION_MERGE_TIMEOUT_SECONDS:-600}"
    export RALPH_MAX_INFRA_RETRIES=0
    export RALPH_MAX_LIMIT_RETRIES=0
    export RALPH_REQUIRE_REVIEWER_TOKEN=1
    export RALPH_REQUIRE_PROTECTION=1
    export RALPH_CI_POLICY=required
    export RALPH_REQUIRED_CHECKS_JSON='["test"]'
    export RALPH_MERGE_METHOD=--squash
    export RALPH_MERGE_PENDING_POLICY=stop
    export RALPH_CLOSE_POLICY=verified
    export RALPH_SMOKE_TEST=0
    export RALPH_CODEX_SANDBOX=workspace-write
    export RALPH_TDD_SKILL="$PROJECT_ROOT/tests/fixtures/SKILL.md"
    unset RALPH_CLAUDE_MAX_BUDGET_USD RALPH_RUN_BUDGET_USD RALPH_DEADLINE_EPOCH \
      RALPH_ISSUE_ORDER RALPH_MERGE_IDENTITY RALPH_REVIEW_IDENTITY \
      RALPH_POST_MERGE_CHECK RALPH_DRY_RUN RALPH_LOCK_REF
    export RALPH_HOST_CONFIG="$scenario_dir/host.env"
    export RALPH_CHECKPOINT_FILE="$scenario_dir/last-run.md"
    export RALPH_INTEGRATION_PR_FILE="$scenario_dir/pr-url"
    export RUN_DIR="$scenario_dir/run"
    bash "$PROJECT_ROOT/once.sh" >"$scenario_dir/once.log" 2>&1
  ); then
    once_rc=0
  else
    once_rc=$?
  fi

  CURRENT_PR=""
  if [ -s "$scenario_dir/pr-url" ]; then
    CURRENT_PR="$(sed -n 's#.*/##p' "$scenario_dir/pr-url")"
  fi
  assert_scenario_state "$scenario" "$issue" "$branch" "$once_rc"
  cleanup_scenario "$issue" "$branch" "$CURRENT_PR"
  assert_cleanup_state "$scenario" "$issue" "$branch" "$CURRENT_PR"
  CURRENT_PR=""

  if ! prepare_base; then
    record_failure "No pude volver a '$default_branch' después de '$scenario'."
  fi
}

printf 'Ralph GitHub integration suite: repo=%s base=%s scenarios=%s\n' \
  "$TARGET_SLUG" "$default_branch" "$SCENARIOS"

for scenario in $SCENARIOS; do
  case "$scenario" in
    pass-green|pass-red|rejection|agent-error) run_scenario "$scenario" ;;
    '') ;;
    *) record_failure "Escenario desconocido: $scenario." ;;
  esac
done

if [ "$scenario_failure" -ne 0 ]; then
  die "La suite de integración falló. Los recursos creados fueron limpiados cuando fue posible."
fi

printf '✅ Suite de integración completada; no quedan PRs abiertos ni ramas de los escenarios.\n'
