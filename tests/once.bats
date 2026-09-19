#!/usr/bin/env bats

load test_helper

@test "once.sh uses env bash so PATH can select Bash 5 on macOS" {
  run head -n 1 "$PROJECT_ROOT/once.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]
}

@test "Bash version guard runs before any preflight and explains the Homebrew fix" {
  version_line="$(grep -n 'BASH_VERSINFO' "$PROJECT_ROOT/once.sh" | head -n 1 | cut -d: -f1)"
  set_line="$(grep -n '^set -' "$PROJECT_ROOT/once.sh" | head -n 1 | cut -d: -f1)"
  script_dir_line="$(grep -n '^SCRIPT_DIR=' "$PROJECT_ROOT/once.sh" | head -n 1 | cut -d: -f1)"
  first_lines="$(sed -n "1,${set_line}p" "$PROJECT_ROOT/once.sh")"

  [ -n "$version_line" ]
  [ "$version_line" -lt "$set_line" ]
  [ "$version_line" -lt "$script_dir_line" ]
  [[ "$first_lines" == *"brew install bash"* ]]
  [[ "$first_lines" == *"PATH"* ]]
  [[ "$first_lines" == *"exit 2"* ]]
}

@test "workspace-write gives codex exec an absolute writable .git root" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  grep -Fq -- "-c sandbox_workspace_write.writable_roots=[\"$TEST_REPO/.git\"]" "$FAKE_AGENT_LOG"
}

@test "danger-full-access does not override writable roots" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_CODEX_SANDBOX=danger-full-access
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  run grep -F -- "sandbox_workspace_write.writable_roots" "$FAKE_AGENT_LOG"
  [ "$status" -eq 1 ]
}

@test "preflight probes .git before the first codex exec" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  grep -Fq -- 'codex sandbox' "$FAKE_AGENT_LOG"
  probe_line="$(grep -n -m 1 -F -- 'ralph-probe' "$FAKE_AGENT_LOG" | cut -d: -f1)"
  exec_line="$(grep -n -m 1 -F -- 'codex exec' "$FAKE_AGENT_LOG" | cut -d: -f1)"
  [ "$probe_line" -lt "$exec_line" ]
  grep -Fq -- '-c sandbox_mode="workspace-write"' "$FAKE_AGENT_LOG"
  grep -Fq -- "sandbox_workspace_write.writable_roots=[\"$TEST_REPO/.git\"]" "$FAKE_AGENT_LOG"
}

@test "preflight fails closed when the sandbox cannot write .git" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_SANDBOX_EXIT=1
  export FAKE_CODEX_SANDBOX_ERROR='touch: .git/.ralph-probe: Read-only file system'

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"sandbox configurado (workspace-write)"* ]]
  [[ "$output" == *"no permite escribir .git"* ]]
  [[ "$output" == *"versión de codex"* ]]
  [[ "$output" == *"sandbox_mode"* ]]
  [[ "$output" == *"RALPH_CODEX_SANDBOX"* ]]
  ! grep -Fq -- 'codex exec' "$FAKE_AGENT_LOG"
}

@test "preflight fails closed for a generic unsupported filesystem operation" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_SANDBOX_EXIT=1
  export FAKE_CODEX_SANDBOX_ERROR='touch: .git/.ralph-probe: Operation not supported'

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"no permite escribir .git"* ]]
  ! grep -Fq -- 'codex exec' "$FAKE_AGENT_LOG"
}

@test "unavailable codex sandbox warns and continues" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_SANDBOX_HELP_EXIT=127
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex sandbox no está disponible"* ]]
  run grep -F -- 'codex sandbox --' "$FAKE_AGENT_LOG"
  [ "$status" -eq 1 ]
  grep -Fq -- 'codex exec' "$FAKE_AGENT_LOG"
}

@test "platform without a usable codex sandbox warns and continues" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_SANDBOX_EXIT=1
  export FAKE_CODEX_SANDBOX_ERROR='Linux sandbox is only available on Linux'
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex sandbox no está disponible"* ]]
  grep -Fq -- 'codex exec' "$FAKE_AGENT_LOG"
}

@test "dry-run skips the sandbox preflight" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/dry-run.json"
  export RALPH_DRY_RUN=1
  export FAKE_CODEX_SANDBOX_EXIT=1

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"Ralph dry-run plan"* ]]
  [[ "$output" != *"codex sandbox"* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
}

@test "preflight fails when the base has no protection ruleset" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-none.json"

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"ruleset"* ]]
  [[ "$output" == *"required status checks"* ]]
}

@test "preflight fails when an active ruleset has no branch targets" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_REQUIRED_CHECKS_JSON='["CI"]'
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-no-targets.json"

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"ruleset activo que cubra 'main'"* ]]
  ! grep -Fq 'codex exec' "$FAKE_AGENT_LOG"
}

@test "preflight passes when the ruleset covers every required status check" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_REQUIRED_CHECKS_JSON='["CI / test","ShellCheck"]'
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-required-checks.json"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"Protección verificada para 'main'"* ]]
  grep -Fq 'rulesets?includes_parents=true' "$FAKE_API_LOG"
  grep -Fq 'rulesets/12' "$FAKE_API_LOG"
  grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "preflight fails when the merge identity can bypass the ruleset" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-bypass.json"

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"identidad de merge 'ralph-bot' tiene bypass"* ]]
  ! grep -Fq 'codex exec' "$FAKE_AGENT_LOG"
}

@test "preflight fails closed when an active ruleset omits bypass actors" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_CI_POLICY=none
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-missing-bypass-actors.json"

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"bypass_actors"* ]]
  [[ "$output" == *"dato insuficiente"* ]]
  ! grep -Fq 'codex exec' "$FAKE_AGENT_LOG"
}

@test "preflight fails closed when the merge user id cannot be resolved" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export FAKE_MERGE_USER_EXIT=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-bypass.json"

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"hay un bypass_actor que no se puede demostrar como un usuario distinto"* ]]
  [[ "$output" != *"identidad de merge 'ralph-bot' tiene bypass"* ]]
  ! grep -Fq 'codex exec' "$FAKE_AGENT_LOG"
}

@test "preflight fails closed for role organization and team bypass actors" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-bypass-non-user.json"

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"bypass_actor"* ]]
  ! grep -Fq 'codex exec' "$FAKE_AGENT_LOG"
}

@test "preflight accepts a ruleset covering all refs with the GitHub ~ALL pattern" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_REQUIRED_CHECKS_JSON='["CI"]'
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-ref-all.json"

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "preflight rejects the default-branch pattern for a different base branch" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_BASE_BRANCH=develop
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_REQUIRED_CHECKS_JSON='["CI"]'
  export RALPH_CI_POLICY=none
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-ref-default-branch.json"
  git -C "$TEST_REPO" branch develop main

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"ruleset activo que cubra 'develop'"* ]]
}

@test "preflight accepts the default-branch pattern for the default base branch" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_BASE_BRANCH=main
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_REQUIRED_CHECKS_JSON='["CI"]'
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-ref-default-branch.json"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"Protección verificada para 'main'"* ]]
  grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "preflight accepts fnmatch refs and rejects an excluded base ref" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_REQUIRED_CHECKS_JSON='["CI"]'
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-ref-glob.json"

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'pr merge' "$GH_MUTATION_LOG"

  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-ref-excluded.json"
  : > "$GH_MUTATION_LOG"
  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"ruleset activo que cubra 'main'"* ]]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "disabling protection warns and records the decision in the run summary" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=0
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export RUN_DIR="$TEST_ROOT/run"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_REQUIRE_PROTECTION=0"* ]]
  [ "$(jq -r '.protection.required' "$RUN_DIR/summary.json")" = false ]
  [ "$(jq -r '.protection.status' "$RUN_DIR/summary.json")" = disabled ]
}

@test "distinct review identity requires an approval rule or ralph-review check" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export RALPH_REVIEW_IDENTITY=claude-reviewer
  export RALPH_REQUIRED_CHECKS_JSON='["CI / test"]'
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-required-checks.json"

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"ralph-review"* ]]
  [[ "$output" == *"aprobación"* ]]
}

@test "distinct review identity must approve the reviewed SHA before merge" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export RALPH_REVIEW_IDENTITY=claude-reviewer
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-review-approval.json"
  export FAKE_REVIEWS_JSON='[]'

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-reviewer"* ]]
  [[ "$output" == *"no aprobó el SHA"* ]]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "approval by the distinct reviewer is accepted only for the reviewed SHA" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export RALPH_REVIEW_IDENTITY=claude-reviewer
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-review-approval.json"
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_REVIEWS_JSON='[{"user":{"login":"claude-reviewer"},"state":"APPROVED","commit_id":"'"$reviewed_sha"'"}]'

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"🎉 #1 mergeado a main y cerrado."* ]]
  grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "approval by the distinct reviewer on another SHA does not merge" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export RALPH_REVIEW_IDENTITY=claude-reviewer
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-review-approval.json"
  export FAKE_REVIEWS_JSON='[{"user":{"login":"claude-reviewer"},"state":"APPROVED","commit_id":"another-sha"}]'

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"no aprobó el SHA"* ]]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "ralph-review check must be successful on the reviewed SHA and reviewer identity" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export RALPH_REVIEW_IDENTITY=claude-reviewer
  export RALPH_CI_POLICY=none
  export RALPH_REQUIRED_CHECKS_JSON='["CI"]'
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-review-check.json"
  export FAKE_REVIEWS_JSON='[]'
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_CHECK_RUNS_JSON='[{"name":"ralph-review","head_sha":"'"$reviewed_sha"'","status":"completed","conclusion":"success","creator":{"login":"claude-reviewer"}}]'

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"🎉 #1 mergeado a main y cerrado."* ]]
  grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "ralph-review from another creator does not merge" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export RALPH_REVIEW_IDENTITY=claude-reviewer
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-review-check.json"
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_CHECK_RUNS_JSON='[{"name":"ralph-review","head_sha":"'"$reviewed_sha"'","status":"completed","conclusion":"success","creator":{"login":"another-reviewer"}}]'

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"no aprobó el SHA"* ]]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "ralph-review for another SHA does not merge" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export RALPH_REVIEW_IDENTITY=claude-reviewer
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-review-check.json"
  export FAKE_CHECK_RUNS_JSON='[{"name":"ralph-review","head_sha":"another-sha","status":"completed","conclusion":"success","creator":{"login":"claude-reviewer"}}]'

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"no aprobó el SHA"* ]]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "ralph-review without a successful conclusion does not merge" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_REQUIRE_PROTECTION=1
  export RALPH_MERGE_IDENTITY=ralph-bot
  export RALPH_REVIEW_IDENTITY=claude-reviewer
  export RALPH_CI_POLICY=none
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_RULESETS_FILE="$PROJECT_ROOT/tests/fixtures/rulesets-review-check.json"
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_CHECK_RUNS_JSON='[{"name":"ralph-review","head_sha":"'"$reviewed_sha"'","status":"completed","conclusion":"failure","creator":{"login":"claude-reviewer"}}]'

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"no aprobó el SHA"* ]]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "mktemp failure stops through fail with a clear message" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_MKTEMP_EXIT=1

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"No pude crear el temporal"* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
}

@test "mktemp uses a TMPDIR path template supported by BSD and GNU implementations" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_CI_POLICY=none
  export TMPDIR="$TEST_ROOT/custom-tmp"
  mkdir -p "$TMPDIR"

  run_once

  [ "$status" -eq 0 ]
  [ "$(grep -Ec "^$TMPDIR/ralph-[^.]+\.XXXXXX$" "$FAKE_MKTEMP_LOG")" -eq 2 ]
}

@test "date -d is confined to the portable epoch formatter" {
  [ "$(grep -Ec 'date -d' "$PROJECT_ROOT/once.sh")" -eq 1 ]
}

@test "epoch formatting uses BSD date -r on Darwin" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CLAUDE_RESULTS='__rate_limit__|<verdict>PASS</verdict>'
  export FAKE_UNAME_SYSTEM=Darwin
  export FAKE_DATE_FAST_FORWARD=1
  export FAKE_DATE_INCREMENTAL_FAST_FORWARD=1
  export FAKE_SLEEP_NOOP=1
  export RUN_DIR="$TEST_ROOT/run"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  grep -Fq -- '-r ' "$FAKE_DATE_LOG"
  ! grep -Fq -- '-d ' "$FAKE_DATE_LOG"
  [ "$(jq -r '.status' "$RUN_DIR"/claude-2.result.json)" = rate_limited ]
  [ "$(jq -r '.retryable' "$RUN_DIR"/claude-2.result.json)" = true ]
}

@test "a signal inside codex's process group is an infrastructure failure, not a host death" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_SIGNAL_GROUP=1
  export FAKE_CODEX_SIGNAL_MARKER="$TEST_ROOT/codex-signal"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 143 ]
  [ -f "$FAKE_CODEX_SIGNAL_MARKER" ]
  [[ "$output" == *"fallo de infraestructura"* ]]
  [[ "$output" == *"rc=143"* ]]
  ! grep -Fq 'claude ' "$FAKE_AGENT_LOG"
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "finishing codex removes its orphaned child process" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_CHILD_PID_FILE="$TEST_ROOT/codex-child.pid"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  child_pid="$(cat "$FAKE_CODEX_CHILD_PID_FILE")"
  child_alive=0
  kill -0 "$child_pid" 2>/dev/null && child_alive=1
  [ "$child_alive" -eq 0 ] || kill -KILL "$child_pid" 2>/dev/null || true
  [ "$child_alive" -eq 0 ]
}

@test "TERM during agent group discovery records the phase and preserves the checked out tree" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_WAIT_FILE="$TEST_ROOT/codex-waiting"
  export FAKE_CODEX_PID_FILE="$TEST_ROOT/codex.pid"
  export FAKE_PS_DELAY_AGENT_PGID=1
  export FAKE_PS_AGENT_PGID_SEEN_FILE="$TEST_ROOT/agent-pgid-seen"
  export FAKE_SLEEP_DISCOVERY_GATE_FILE="$TEST_ROOT/discovery-sleep"
  export FAKE_SLEEP_DISCOVERY_RELEASE_FILE="$TEST_ROOT/discovery-release"
  export RALPH_CI_POLICY=none
  before_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"

  bash -c 'cd "$1" && exec bash "$2/once.sh"' _ "$TEST_REPO" "$PROJECT_ROOT" \
    > "$TEST_ROOT/runner.log" 2>&1 &
  runner_pid=$!
  for _ in {1..50}; do
    [ -f "$FAKE_SLEEP_DISCOVERY_GATE_FILE" ] && break
    "$RALPH_TEST_REAL_SLEEP" 0.1
  done
  [ -f "$FAKE_SLEEP_DISCOVERY_GATE_FILE" ]

  kill -TERM "$runner_pid"
  : > "$FAKE_SLEEP_DISCOVERY_RELEASE_FILE"
  runner_done=0
  for _ in {1..100}; do
    if ! kill -0 "$runner_pid" 2>/dev/null; then
      runner_done=1
      break
    fi
    "$RALPH_TEST_REAL_SLEEP" 0.05
  done
  if [ "$runner_done" -eq 0 ]; then
    agent_pid="$(cat "$FAKE_CODEX_PID_FILE")"
    agent_pgid="$("$RALPH_TEST_REAL_PS" -o pgid= -p "$agent_pid" | tr -d '[:space:]')"
    runner_pgid="$("$RALPH_TEST_REAL_PS" -o pgid= -p "$runner_pid" | tr -d '[:space:]')"
    if [ -n "$agent_pgid" ] && [ "$agent_pgid" != "$runner_pgid" ] && [ "$agent_pgid" != "0" ]; then
      kill -KILL -- "-$agent_pgid" 2>/dev/null || true
    fi
    kill -KILL "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    false
  fi

  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi

  [ "$runner_rc" -eq 143 ]
  grep -Fq 'corrida terminada por señal TERM durante implementación del issue #1' "$TEST_ROOT/runner.log"
  [ "$(git -C "$TEST_REPO" branch --show-current)" = "ralph/issue-1" ]
  [ "$(git -C "$TEST_REPO" rev-parse HEAD)" = "$before_sha" ]
  [ -z "$(git -C "$TEST_REPO" status --porcelain)" ]
}

@test "TERM does not modify a repo summary.json before RUN_DIR exists" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_WAIT_FILE="$TEST_ROOT/codex-waiting"
  export RALPH_CI_POLICY=none
  unset RUN_DIR
  printf '%s\n' '{"errors":[]}' > "$TEST_REPO/summary.json"
  git -C "$TEST_REPO" switch -q main
  git -C "$TEST_REPO" add summary.json
  git -C "$TEST_REPO" commit -q -m 'test summary'

  bash -c 'cd "$1" && exec bash "$2/once.sh"' _ "$TEST_REPO" "$PROJECT_ROOT" \
    > "$TEST_ROOT/runner.log" 2>&1 &
  runner_pid=$!
  for _ in {1..50}; do
    [ -f "$FAKE_CODEX_WAIT_FILE" ] && break
    sleep 0.1
  done
  [ -f "$FAKE_CODEX_WAIT_FILE" ]

  kill -TERM "$runner_pid"
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi

  [ "$runner_rc" -eq 143 ]
  [ "$(cat "$TEST_REPO/summary.json")" = '{"errors":[]}' ]
  [ -z "$(git -C "$TEST_REPO" status --porcelain)" ]
}

@test "dry run prints the selector plan without mutations or agents" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/dry-run.json"
  export RALPH_DRY_RUN=1
  export RALPH_ISSUE_ORDER="6 10 5 2 4"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"Ralph dry-run plan"* ]]
  [[ "$output" == *"#6 priority=1 host=github.com parents=none blockers=none needs-human=no pr=106"* ]]
  [[ "$output" == *"#2 priority=4 host=github.com parents=none blockers=none needs-human=no pr=none excluded=parent"* ]]
  [[ "$output" == *"#5 priority=3 host=github.com parents=none blockers=none needs-human=yes pr=105 excluded=needs-human"* ]]
  [[ "$output" == *"#10 priority=2 host=github.com parents=2 blockers=4 needs-human=no pr=none excluded=blocked-by:4"* ]]
  [ ! -s "$GH_MUTATION_LOG" ]
  [ ! -s "$FAKE_AGENT_LOG" ]
}

@test "more than 30 issues and parents with children outside candidates: full selection" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/complete-selection.json"
  export RALPH_DRY_RUN=1

  run_once

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -Ec '^#[0-9]+ priority=')" -eq 45 ]
  [[ "$output" == *"#1 priority=1 host=github.com parents=none blockers=none needs-human=no pr=none excluded=parent"* ]]
  [[ "$output" == *"#45 priority=45 host=github.com parents=none blockers=none needs-human=no pr=none"* ]]
}

@test "issue bodies come from listings, not per-issue views" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/complete-selection.json"
  export RALPH_DRY_RUN=1
  export FAKE_REJECT_BODY_VIEW=1

  run_once

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -Ec '^#[0-9]+ priority=')" -eq 45 ]
}

@test "a blocker reopened during the pass blocks later candidates again" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/blocker-reopened.json"
  export RALPH_DRY_RUN=1
  export FAKE_STATE_SEQUENCE_ISSUE=2
  export FAKE_STATE_SEQUENCE='CLOSED|OPEN'
  export FAKE_STATE_SEQUENCE_FILE="$TEST_ROOT/blocker-state-calls"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"#1 priority=1 host=github.com parents=none blockers=2 needs-human=no pr=none"* ]]
  [[ "$output" == *"#3 priority=2 host=github.com parents=none blockers=2 needs-human=no pr=none excluded=blocked-by:2"* ]]
  [ "$(cat "$FAKE_STATE_SEQUENCE_FILE")" -eq 2 ]
}

@test "section references stop at the next heading" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/section-refs.json"
  export RALPH_DRY_RUN=1

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"#1 priority=1 host=github.com parents=none blockers=12 needs-human=no pr=none excluded=blocked-by:12"* ]]
  [[ "$output" == *"#2 priority=2 host=github.com parents=none blockers=12 needs-human=no pr=none excluded=blocked-by:12"* ]]
  [[ "$output" != *"blockers=12,999"* ]]
}

@test "section references require one documented reference per line" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/section-format.json"
  export RALPH_DRY_RUN=1

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"#1 priority=1 host=github.com parents=42 blockers=12,13,14,15 needs-human=no pr=none excluded=blocked-by:12,13,14,15"* ]]
  [[ "$output" != *"parents=42,43,44,45"* ]]
}

@test "invalid Blocked by content blocks the issue explicitly" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/invalid-blocked-by.json"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"#1 bloqueado: formato inválido en ## Blocked by: - #12 (parser)"* ]]
  [[ "$output" == *"#12, #13"* ]]
  ! grep -Eq '^(codex exec|claude) ' "$FAKE_AGENT_LOG"
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "fallo al leer el body del issue detiene antes de crear rama o invocar agentes" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_ISSUE_VIEW_FAIL_NUM=1
  export FAKE_ISSUE_VIEW_FAIL_FIELD=body

  run_once
  run_output="$output"

  [ "$status" -eq 70 ]
  run git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-1
  [ "$status" -ne 0 ]
  run grep -Eq '^(codex exec|claude) ' "$FAKE_AGENT_LOG"
  [ "$status" -eq 1 ]
  [[ "$run_output" == *"No pude leer el body del issue #1"* ]]
}

@test "ralph-needs-human en el issue omite el issue sin rama ni agentes" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/needs-human-issue.json"

  run_once
  run_output="$output"

  [ "$status" -eq 0 ]
  run git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-1
  [ "$status" -ne 0 ]
  run grep -Eq '^(codex exec|claude) ' "$FAKE_AGENT_LOG"
  [ "$status" -eq 1 ]
  [[ "$run_output" == *"#1 marcado con ralph-needs-human"* ]]
}

@test "issue que pierde ready-for-agent antes del agente no invoca Codex" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_ISSUE_LABELS_SEQUENCE='ready-for-agent|__empty__'
  export FAKE_ISSUE_LABELS_CALL_COUNT_FILE="$TEST_ROOT/issue-label-calls"
  export RALPH_CI_POLICY=none

  run_once
  run_output="$output"

  [ "$status" -eq 0 ]
  run grep -Eq '^(codex exec|claude) ' "$FAKE_AGENT_LOG"
  [ "$status" -eq 1 ]
  run git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-1
  [ "$status" -eq 0 ]
  [[ "$run_output" == *"#1 ya no tiene el label 'ready-for-agent'; no invoco agentes."* ]]
}

@test "ralph-needs-human en el PR omite el issue sin invocar agentes" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/needs-human-pr.json"

  run_once
  run_output="$output"

  [ "$status" -eq 0 ]
  run grep -Eq '^(codex exec|claude) ' "$FAKE_AGENT_LOG"
  [ "$status" -eq 1 ]
  [[ "$run_output" == *"PR #101 espera revisión humana"* ]]
}

@test "claude PASS with a nonzero exit never merges the issue" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CLAUDE_RESULT='<verdict>PASS</verdict>'
  export FAKE_CLAUDE_EXIT=42

  run_once

  [ "$status" -eq 42 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  [[ "$output" == *"Claude terminó con rc=42"* ]]
  [[ "$output" != *"🎉 #1 mergeado a main y cerrado."* ]]
}

@test "quoted PASS before final CHANGES_REQUESTED never merges the issue" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CLAUDE_RESULT=$'The review body quotes <verdict>PASS</verdict> as an example.\n<verdict>CHANGES_REQUESTED</verdict>'

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  [[ "$output" != *"🎉 #1 mergeado a main y cerrado."* ]]
}

@test "check obligatorio ausente en el SHA revisado no mergea" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_REQUIRED_CHECKS_JSON='["suite obligatoria"]'
  export FAKE_CHECK_RUNS_JSON='[]'
  export FAKE_STATUSES_JSON='[]'
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
}

@test "check obligatorio skipped no cuenta como éxito" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_REQUIRED_CHECKS_JSON='["suite obligatoria"]'
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_CHECK_RUNS_JSON="[{\"name\":\"suite obligatoria\",\"head_sha\":\"$reviewed_sha\",\"status\":\"completed\",\"conclusion\":\"skipped\"}]"
  export FAKE_STATUSES_JSON='[]'

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  [[ "$output" == *"CI obligatorio en rojo"* ]]
}

@test "check obligatorio pendiente no mergea" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_REQUIRED_CHECKS_JSON='["suite obligatoria"]'
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_CHECK_RUNS_JSON="[{\"name\":\"suite obligatoria\",\"head_sha\":\"$reviewed_sha\",\"status\":\"in_progress\",\"conclusion\":null}]"
  export FAKE_STATUSES_JSON='[]'
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  [[ "$output" == *"ci_pending"* ]]
}

@test "check obligatorio failed no mergea" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_REQUIRED_CHECKS_JSON='["suite obligatoria"]'
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_CHECK_RUNS_JSON="[{\"name\":\"suite obligatoria\",\"head_sha\":\"$reviewed_sha\",\"status\":\"completed\",\"conclusion\":\"failure\"}]"
  export FAKE_STATUSES_JSON='[]'

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  [[ "$output" == *"CI obligatorio en rojo"* ]]
}

@test "todos los checks obligatorios exitosos permiten extras" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_REQUIRED_CHECKS_JSON='["suite obligatoria"]'
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_CHECK_RUNS_JSON="[{\"name\":\"suite obligatoria\",\"head_sha\":\"$reviewed_sha\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"name\":\"check extra\",\"head_sha\":\"$reviewed_sha\",\"status\":\"completed\",\"conclusion\":\"success\"}]"
  export FAKE_STATUSES_JSON='[]'

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
  grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
}

@test "éxito de un check obligatorio en un SHA anterior no permite mergear" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_REQUIRED_CHECKS_JSON='["suite obligatoria"]'
  export FAKE_CHECK_RUNS_JSON='[{"name":"suite obligatoria","head_sha":"previous-commit","status":"completed","conclusion":"success"}]'
  export FAKE_STATUSES_JSON='[]'
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  grep -Fq "commits/$reviewed_sha/check-runs" "$FAKE_API_LOG"
  grep -Fq "commits/$reviewed_sha/statuses" "$FAKE_API_LOG"
}

@test "la consulta de checks no depende de --slurp" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_REQUIRED_CHECKS_JSON='["suite obligatoria"]'
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_CHECK_RUNS_JSON="[{\"name\":\"suite obligatoria\",\"head_sha\":\"$reviewed_sha\",\"status\":\"completed\",\"conclusion\":\"success\"}]"
  export FAKE_STATUSES_JSON='[]'

  run_once

  [ "$status" -eq 0 ]
  run grep -Fq -- '--slurp' "$FAKE_API_LOG"
  [ "$status" -eq 1 ]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
}

@test "modo sin lista usa el estado más reciente de cada context" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CHECK_RUNS_JSON='[]'
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_STATUSES_JSON="[{\"context\":\"suite obligatoria\",\"sha\":\"$reviewed_sha\",\"state\":\"success\"},{\"context\":\"suite obligatoria\",\"sha\":\"$reviewed_sha\",\"state\":\"pending\"}]"
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
}

@test "lista obligatoria usa el estado más reciente de cada context" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export RALPH_REQUIRED_CHECKS_JSON='["suite obligatoria"]'
  export FAKE_CHECK_RUNS_JSON='[]'
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  export FAKE_STATUSES_JSON="[{\"context\":\"suite obligatoria\",\"sha\":\"$reviewed_sha\",\"state\":\"failure\"},{\"context\":\"suite obligatoria\",\"sha\":\"$reviewed_sha\",\"state\":\"success\"}]"

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  [[ "$output" == *"CI obligatorio en rojo"* ]]
}

@test "CI ausente con política required queda ci_pending sin mergear" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT="no checks reported"
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1
  unset RALPH_CI_POLICY

  run_once
  runner_output="$output"

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  ! grep -Fq 'pr comment' "$GH_MUTATION_LOG"
  [ "$(grep -c '^codex exec ' "$FAKE_AGENT_LOG")" -eq 1 ]
  [[ "$runner_output" == *"CI ausente"* ]]
  [[ "$runner_output" == *"ci_pending"* ]]
}

@test "timeout de CI ausente no mergea ni manda corrección a Codex" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT="no checks reported"
  export RALPH_CI_TIMEOUT_SECONDS=60
  export FAKE_DATE_FAST_FORWARD=1
  export FAKE_SLEEP_NOOP=1
  unset RALPH_CI_POLICY

  run_once
  runner_output="$output"

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  ! grep -Fq 'pr comment' "$GH_MUTATION_LOG"
  [ "$(grep -c '^codex exec ' "$FAKE_AGENT_LOG")" -eq 1 ]
  [[ "$runner_output" == *"ci_pending"* ]]
}

@test "checks de CI que aparecen dentro del timeout permiten el merge" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULTS="no checks reported|pass"
  export RALPH_CI_TIMEOUT_SECONDS=60
  export FAKE_SLEEP_NOOP=1

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
  grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
  [ "$(cat "$FAKE_CI_CALL_COUNT_FILE")" -eq 2 ]
}

@test "el poll de CI consulta los endpoints del SHA revisado" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT=pass

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  grep -Fq "commits/$reviewed_sha/check-runs" "$FAKE_API_LOG"
  grep -Fq "commits/$reviewed_sha/statuses" "$FAKE_API_LOG"
}

@test "RALPH_CI_POLICY=none permite mergear sin checks con aviso explícito" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT="no checks reported"
  export RALPH_CI_POLICY=none

  run_once
  runner_output="$output"

  [ "$status" -eq 0 ]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
  grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
  [[ "$runner_output" == *"RALPH_CI_POLICY=none"* ]]
}

@test "check fallido deja el run en el PR para Codex y no mergea" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT=fail
  export FAKE_CI_RUN_URL="https://github.com/nicoamigosa/ralph/actions/runs/456"
  export RALPH_MAX_ROUNDS=1

  run_once
  runner_output="$output"

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  grep -Fq 'pr comment' "$GH_MUTATION_LOG"
  grep -Fq "$FAKE_CI_RUN_URL" "$GH_MUTATION_LOG"
  [[ "$runner_output" == *"CI en rojo"* ]]
}

@test "check fallido con texto de infraestructura sigue siendo fallo real" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT="network timeout failure"
  export FAKE_CI_RUN_URL="https://github.com/nicoamigosa/ralph/actions/runs/789"
  export RALPH_CI_TIMEOUT_SECONDS=0
  export RALPH_MAX_ROUNDS=1

  run_once
  runner_output="$output"

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  grep -Fq 'pr comment' "$GH_MUTATION_LOG"
  grep -Fq "$FAKE_CI_RUN_URL" "$GH_MUTATION_LOG"
  [[ "$runner_output" == *"CI en rojo"* ]]
  [[ "$runner_output" != *"ci_pending"* ]]
}

@test "fallo de infraestructura de CI queda ci_pending sin corrección" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT=infra
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1

  run_once
  runner_output="$output"

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  ! grep -Fq 'pr comment' "$GH_MUTATION_LOG"
  [ "$(grep -c '^codex exec ' "$FAKE_AGENT_LOG")" -eq 1 ]
  [[ "$runner_output" == *"ci_pending"* ]]
}

@test "exit 8 de gh pr checks queda ci_pending sin corrección" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT=pending
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1

  run_once
  runner_output="$output"

  [ "$status" -eq 0 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'pr comment' "$GH_MUTATION_LOG"
  [ "$(grep -c '^codex exec ' "$FAKE_AGENT_LOG")" -eq 1 ]
  [[ "$runner_output" == *"ci_pending"* ]]
}

@test "HEAD distinto de headRefOid antes de revisar detiene sin invocar Claude" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_HEAD_REF_OID=remote-head-changed

  run_once

  [ "$status" -eq 70 ]
  ! grep -Eq '^claude ' "$FAKE_AGENT_LOG"
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  [[ "$output" == *"head_changed"* ]]
}

@test "cambio de HEAD después de PASS no mergea y deja estado head_changed" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_HEAD_CHANGED=1

  run_once

  [ "$status" -eq 70 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  [[ "$output" == *"head_changed"* ]]
}

@test "mergea siempre con el SHA que pasó la revisión" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  reviewed_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"

  run_once

  [ "$status" -eq 0 ]
  grep -Fq "pr merge 101 --squash --match-head-commit $reviewed_sha" "$GH_MUTATION_LOG"
}

@test "merge queue confirma MERGED antes de borrar rama, hook y issue" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_MERGE_STATES='OPEN|MERGED'
  export FAKE_MERGE_QUERY_COUNT_FILE="$TEST_ROOT/merge-queries"
  export RALPH_MERGE_TIMEOUT_SECONDS=60
  export FAKE_SLEEP_NOOP=1
  export RALPH_POST_MERGE_CHECK="$PROJECT_ROOT/tests/fakes/post-merge-check"

  run_once

  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_MERGE_QUERY_COUNT_FILE")" -eq 2 ]
  ! git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-1
  merge_line="$(grep -n '^pr merge ' "$GH_MUTATION_LOG" | cut -d: -f1)"
  state_line="$(grep -n '^pr state MERGED ' "$GH_MUTATION_LOG" | cut -d: -f1)"
  remote_delete_line="$(grep -n '^api --method DELETE ' "$GH_MUTATION_LOG" | cut -d: -f1)"
  delete_line="$(grep -n '^git branch -D ' "$GH_MUTATION_LOG" | cut -d: -f1)"
  hook_line="$(grep -n '^post_merge ' "$GH_MUTATION_LOG" | cut -d: -f1)"
  close_line="$(grep -n '^issue close ' "$GH_MUTATION_LOG" | cut -d: -f1)"
  [ "$merge_line" -lt "$delete_line" ]
  [ "$state_line" -lt "$remote_delete_line" ]
  [ "$remote_delete_line" -lt "$delete_line" ]
  [ "$delete_line" -lt "$hook_line" ]
  [ "$hook_line" -lt "$close_line" ]
  grep -Fq 'post_merge 1111111111111111111111111111111111111111' "$GH_MUTATION_LOG"
}

@test "rama remota ya borrada tras MERGED no impide limpieza ni cierre" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_MERGE_STATES=MERGED
  export FAKE_MERGE_QUERY_COUNT_FILE="$TEST_ROOT/merge-queries"
  export FAKE_REMOTE_DELETE_422=1
  export RALPH_POST_MERGE_CHECK="$PROJECT_ROOT/tests/fakes/post-merge-check"

  run_once

  [ "$status" -eq 0 ]
  ! git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-1
  grep -q '^api --method DELETE ' "$FAKE_API_LOG"
  grep -Fq 'git branch -D ralph/issue-1' "$GH_MUTATION_LOG"
  grep -Fq 'post_merge 1111111111111111111111111111111111111111' "$GH_MUTATION_LOG"
  grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
}

@test "merge encolado: no cerrar issue ni borrar rama" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/two-issues.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_MERGE_STATES=OPEN
  export FAKE_MERGE_QUERY_COUNT_FILE="$TEST_ROOT/merge-queries"
  export RALPH_MERGE_TIMEOUT_SECONDS=0
  export RALPH_CHECKPOINT_FILE="$TEST_ROOT/last_run.md"
  export RALPH_POST_MERGE_CHECK="$PROJECT_ROOT/tests/fakes/post-merge-check"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"merge_pending"* ]]
  [ -f "$RALPH_CHECKPOINT_FILE" ]
  git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-1
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  ! grep -Fq 'branch -D' "$GH_MUTATION_LOG"
  ! grep -Fq 'post_merge' "$GH_MUTATION_LOG"
  [ "$(grep -c '^codex exec ' "$FAKE_AGENT_LOG")" -eq 1 ]
  [ "$(grep -c '^claude ' "$FAKE_AGENT_LOG")" -eq 1 ]
}

@test "merge_pending con política continue permite otro issue independiente" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/two-issues.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_MERGE_STATES=OPEN
  export FAKE_MERGE_QUERY_COUNT_FILE="$TEST_ROOT/merge-queries"
  export RALPH_MERGE_TIMEOUT_SECONDS=0
  export RALPH_MERGE_PENDING_POLICY=continue

  run_once

  [ "$status" -eq 0 ]
  [ "$(grep -c '^codex exec ' "$FAKE_AGENT_LOG")" -eq 1 ]
  [ "$(grep -c '^claude ' "$FAKE_AGENT_LOG")" -eq 2 ]
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-1
  git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-2
}

@test "RALPH_MERGE_METHOD con argumentos extra falla en preflight" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_MERGE_METHOD="--squash --admin"

  run_once

  [ "$status" -eq 1 ]
  [ ! -s "$FAKE_AGENT_LOG" ]
  [[ "$output" == *"RALPH_MERGE_METHOD"* ]]
}

@test "árbol sucio después de PASS detiene sin mergear" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CLAUDE_WRITE_FILE="$TEST_REPO/review-dirty.txt"

  run_once

  [ "$status" -eq 70 ]
  [ -f "$TEST_REPO/review-dirty.txt" ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  [[ "$output" == *"árbol cambió después de la revisión"* ]]
}

@test "uncommitted codex work stops without an automatic commit" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_WRITE_FILE="$TEST_REPO/uncommitted.txt"

  run_once
  runner_output="$output"

  [ "$status" -eq 70 ]
  [ -f "$TEST_REPO/uncommitted.txt" ]
  [ "$(git -C "$TEST_REPO" status --porcelain -- uncommitted.txt)" = "?? uncommitted.txt" ]
  run bash -c '! git -C "$1" log --all --format="%s" | grep -Fq "$2"' _ "$TEST_REPO" 'ralph: progreso sin commitear en issue #1'
  [ "$status" -eq 0 ]
  run bash -c '! grep -Eq "$1" "$2"' _ '^claude ' "$FAKE_AGENT_LOG"
  [ "$status" -eq 0 ]
  run bash -c '! grep -Fq "$1" "$2"' _ 'pr merge' "$GH_MUTATION_LOG"
  [ "$status" -eq 0 ]
  [[ "$runner_output" == *"cambios sin commitear"* ]]
}

@test "git push failure stops with the branch and PR still open" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/review-cycle.json"
  export FAKE_CLAUDE_RESULTS='<verdict>CHANGES_REQUESTED</verdict>|<verdict>PASS</verdict>'
  export FAKE_CODEX_COMMIT_FILE="$TEST_REPO/review-fix.txt"
  export FAKE_GIT_FAIL=push

  run_once
  runner_output="$output"

  [ "$status" -eq 70 ]
  git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/ralph/issue-99
  run bash -c '! grep -Fq "$1" "$2"' _ 'pr merge' "$GH_MUTATION_LOG"
  [ "$status" -eq 0 ]
  run bash -c '! grep -Fq "$1" "$2"' _ 'issue close' "$GH_MUTATION_LOG"
  [ "$status" -eq 0 ]
  [[ "$runner_output" == *"Fallo fatal (rc=70)"* ]]
}

@test "git pull failure after merge stops before the next issue" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/two-issues.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_GIT_FAIL=pull

  run_once
  runner_output="$output"

  [ "$status" -eq 70 ]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
  run bash -c '! grep -Fq "$1" "$2"' _ 'issue close' "$GH_MUTATION_LOG"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^codex exec ' "$FAKE_AGENT_LOG")" -eq 1 ]
  [ "$(grep -c '^claude ' "$FAKE_AGENT_LOG")" -eq 1 ]
  [[ "$runner_output" == *"Fallo fatal (rc=70)"* ]]
}

@test "unresolved merge preserves a recoverable tree and labels the PR" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/review-cycle.json"
  export FAKE_CODEX_EXIT=42

  git -C "$TEST_REPO" switch -q -c ralph/issue-99
  printf '%s\n' 'branch version' > "$TEST_REPO/conflict.txt"
  git -C "$TEST_REPO" add conflict.txt
  git -C "$TEST_REPO" commit -q -m 'branch conflict'
  git -C "$TEST_REPO" switch -q main
  printf '%s\n' 'base version' > "$TEST_REPO/conflict.txt"
  git -C "$TEST_REPO" add conflict.txt
  git -C "$TEST_REPO" commit -q -m 'base conflict'
  git -C "$TEST_REPO" push -q origin HEAD:main
  git -C "$TEST_REPO" switch -q ralph/issue-99

  run_once

  [ "$status" -eq 42 ]
  [ -z "$(git -C "$TEST_REPO" status --porcelain)" ]
  grep -Fq 'api repos/nicoamigosa/ralph/issues/199/labels -f labels[]=ralph-needs-human' "$GH_MUTATION_LOG"
  run bash -c '! grep -Eq "$1" "$2"' _ 'git reset( -q)? --hard' "$PROJECT_ROOT/once.sh"
  [ "$status" -eq 0 ]
}

@test "exit codes without a provider signal stay unlabeled and do not retry" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/review-cycle.json"
  export FAKE_CODEX_EXITS='8|9'
  export FAKE_DATE_FAST_FORWARD=1

  git -C "$TEST_REPO" switch -q -c ralph/issue-99
  printf '%s\n' 'branch version' > "$TEST_REPO/conflict.txt"
  git -C "$TEST_REPO" add conflict.txt
  git -C "$TEST_REPO" commit -q -m 'branch conflict'
  git -C "$TEST_REPO" switch -q main
  printf '%s\n' 'base version' > "$TEST_REPO/conflict.txt"
  git -C "$TEST_REPO" add conflict.txt
  git -C "$TEST_REPO" commit -q -m 'base conflict'
  git -C "$TEST_REPO" push -q origin HEAD:main
  git -C "$TEST_REPO" switch -q ralph/issue-99

  run_once

  [ "$status" -eq 8 ]
  run bash -c '! grep -Fq "$1" "$2"' _ 'labels[]=' "$GH_MUTATION_LOG"
  [ "$status" -eq 0 ]
  run bash -c '! grep -Fq "$1" "$2"' _ 'pr comment' "$GH_MUTATION_LOG"
  [ "$status" -eq 0 ]
}

@test "tee failure returns 70 and stops the run" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_TEE_EXIT=1

  run_once

  [ "$status" -eq 70 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue close' "$GH_MUTATION_LOG"
  ! grep -Eq '^claude ' "$FAKE_AGENT_LOG"
}

@test "happy path implements reviews merges and closes the issue" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_PR_BODY='Closes #1'

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ PASS en la ronda 1"* ]]
  [[ "$output" == *"🎉 #1 mergeado a main y cerrado."* ]]
  grep -Fq 'codex ' "$FAKE_AGENT_LOG"
  grep -Fq 'claude ' "$FAKE_AGENT_LOG"
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
  grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
  jq -e '
    [.comments[] | select(.body | contains("<!-- ralph-state -->")) |
      .body | split("<!-- ralph-state -->")[1] | fromjson] | last |
      .pr == 101 and .merge_status == "merged" and .status == "merged"
  ' "$FAKE_GH_STATE_FILE"
}

@test "orchestrator publishes the exact reviewer body once per review round" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CLAUDE_RESULT=$'1. Revisar el estado remoto.\n<verdict>CHANGES_REQUESTED</verdict>'
  export RALPH_CI_POLICY=none
  export RALPH_MAX_INFRA_RETRIES=0

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'pr comment 101 --body 1. Revisar el estado remoto.' "$GH_MUTATION_LOG"
  grep -Fq '<!-- ralph-state -->' "$GH_MUTATION_LOG"
  [ "$(jq '[.comments[] | select(.body == "1. Revisar el estado remoto.\n<verdict>CHANGES_REQUESTED</verdict>")] | length' "$FAKE_GH_STATE_FILE")" -eq 3 ]
  jq -e '
    ([.comments[] |
      select(.body == "1. Revisar el estado remoto.\n<verdict>CHANGES_REQUESTED</verdict>") |
      .id]) as $review_ids |
    ([.comments[] | select(.body | contains("<!-- ralph-state -->")) |
      .body | split("<!-- ralph-state -->")[1] | fromjson |
      select(.status == "changes_requested")]) as $review_states |
    ($review_ids | length) == 3 and ($review_states | length) == 3 and
    ($review_states | map(.round)) == [1, 2, 3] and
    ($review_states | map(.comment_id)) == $review_ids and
    ($review_states | last).pr == 101 and
    ($review_states | last).review_body == "1. Revisar el estado remoto.\n<verdict>CHANGES_REQUESTED</verdict>"
  ' "$FAKE_GH_STATE_FILE"
}

@test "CI failure becomes the next correction body with its run URL" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT=fail
  export FAKE_CI_RUN_URL='https://github.com/nicoamigosa/ralph/actions/runs/456'
  export RALPH_MAX_ROUNDS=2
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1

  run_once

  [ "$status" -eq 0 ]
  correction_prompt="$(awk '/^codex exec/ {codex_calls++; capture=(codex_calls == 2)} /^claude / {if (capture) exit} capture {print}' "$FAKE_AGENT_LOG")"
  [[ "$correction_prompt" == *"https://github.com/nicoamigosa/ralph/actions/runs/456"* ]]
  [[ "$correction_prompt" != *"<verdict>PASS</verdict>"* ]]
}

@test "correction receives the saved review body, not a later foreign comment" {
  state_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"
  sed "s/STATE_SHA/$state_sha/" \
    "$PROJECT_ROOT/tests/fixtures/persistent-review.json" > "$TEST_ROOT/persistent-review.json"
  export GH_FIXTURE="$TEST_ROOT/persistent-review.json"
  export FAKE_CLAUDE_RESULT='<verdict>PASS</verdict>'
  export FAKE_CODEX_COMMIT_FILE="$TEST_REPO/review-fix.txt"
  export RALPH_CI_POLICY=none
  git -C "$TEST_REPO" push -q origin HEAD:refs/heads/ralph/issue-99

  run_once

  [ "$status" -eq 0 ]
  grep -Fq '1. Corregir el checkpoint remoto.' "$FAKE_AGENT_LOG"
  run bash -c '! grep -Fq "$1" "$2"' _ 'Comentario ajeno posterior' "$FAKE_AGENT_LOG"
  [ "$status" -eq 0 ]
}

@test "restart after round two resumes the same PR at round three" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/review-cycle.json"
  export FAKE_CLAUDE_RESULTS='<verdict>CHANGES_REQUESTED</verdict>|<verdict>CHANGES_REQUESTED</verdict>'
  export RALPH_CI_POLICY=none
  export RALPH_MAX_ROUNDS=2

  run_once

  [ "$status" -eq 0 ]
  round_two_sha="$(jq -r '
    [.comments[] | select(.body | contains("<!-- ralph-state -->")) |
      .body | split("<!-- ralph-state -->")[1] | fromjson] | last | .reviewed_sha
  ' "$FAKE_GH_STATE_FILE")"
  [ -n "$round_two_sha" ]
  export FAKE_CLAUDE_RESULT='<verdict>PASS</verdict>'
  unset FAKE_CLAUDE_RESULTS
  export RALPH_MAX_ROUNDS=3

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"🔍 Claude revisa PR #199 (ronda 3/3)"* ]]
  [[ "$output" != *"🔍 Claude revisa PR #199 (ronda 1/3)"* ]]
  jq -e --arg sha "$round_two_sha" '
    [.comments[] | select(.body | contains("<!-- ralph-state -->")) |
      .body | split("<!-- ralph-state -->")[1] | fromjson] | last |
      .round == 3 and .reviewed_sha == $sha
  ' "$FAKE_GH_STATE_FILE"
}

@test "limit during review preserves phase and round in the remote checkpoint" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CLAUDE_RESULT='__rate_limit__'
  export RALPH_CI_POLICY=none
  export RALPH_MAX_LIMIT_RETRIES=0

  run_once

  [ "$status" -eq 0 ]
  jq -e '
    [.comments[] | select(.body | contains("<!-- ralph-state -->")) |
      .body | split("<!-- ralph-state -->")[1] | fromjson] | last |
      .phase == "revisión" and .round == 1 and .status == "reviewing"
  ' "$FAKE_GH_STATE_FILE"
}

@test "reviewing after a base advance recaptures the SHA and can merge" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CLAUDE_RESULT='__rate_limit__'
  export RALPH_CI_POLICY=none
  export RALPH_MAX_LIMIT_RETRIES=0

  run_once

  [ "$status" -eq 0 ]
  reviewed_sha_before_base="$(jq -r '
    [.comments[] | select(.body | contains("<!-- ralph-state -->")) |
      .body | split("<!-- ralph-state -->")[1] | fromjson] | last | .reviewed_sha
  ' "$FAKE_GH_STATE_FILE")"

  git -C "$TEST_REPO" switch -q main
  printf '%s\n' 'base advanced after the review stopped' > "$TEST_REPO/base-advance.txt"
  git -C "$TEST_REPO" add base-advance.txt
  git -C "$TEST_REPO" commit -q -m 'advance base after review stop'
  git -C "$TEST_REPO" push -q origin main
  git -C "$TEST_REPO" switch -q ralph/issue-1

  export FAKE_CLAUDE_RESULT='<verdict>PASS</verdict>'
  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"🔍 Claude revisa PR #101 (ronda 1/3)"* ]]
  [[ "$output" != *"head_changed"* ]]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
  grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
  jq -e --arg old_sha "$reviewed_sha_before_base" '
    ([.comments[] | select(.body | contains("<!-- ralph-state -->")) |
      .body | split("<!-- ralph-state -->")[1] | fromjson] | last) as $state |
    $state.status == "merged" and $state.round == 1 and
    $state.reviewed_sha != $old_sha
  ' "$FAKE_GH_STATE_FILE"
}

@test "CI timeout preserves the passed review for the next run" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CI_RESULT='no checks reported'
  export RALPH_CI_TIMEOUT_SECONDS=0
  export FAKE_SLEEP_NOOP=1

  run_once

  [ "$status" -eq 0 ]
  jq -e '
    [.comments[] | select(.body | contains("<!-- ralph-state -->")) |
      .body | split("<!-- ralph-state -->")[1] | fromjson] | last |
      .phase == "revisión" and .round == 1 and .status == "pass" and
      .merge_status == "open"
  ' "$FAKE_GH_STATE_FILE"

  export RALPH_CI_POLICY=none
  run_once

  [ "$status" -eq 0 ]
  [ "$(grep -c '^claude ' "$FAKE_AGENT_LOG")" -eq 1 ]
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
}

@test "verified closes only when the merged PR declares Closes" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_PR_BODY='Closes #1'

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
  ! grep -Fq 'issue comment 1' "$GH_MUTATION_LOG"
}

@test "verified leaves a Part of issue open and comments after merge" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_PR_BODY='Part of #1'

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
  grep -Fq 'issue comment 1' "$GH_MUTATION_LOG"
}

@test "implementation prompt receives the verified close policy" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_PR_BODY='Closes #1'

  run_once

  [ "$status" -eq 0 ]
  grep -Fq 'RALPH_CLOSE_POLICY=verified' "$FAKE_AGENT_LOG"
  grep -Fq 'PR body MUST declare `Closes #<issue number>`' "$FAKE_AGENT_LOG"
}

@test "never keeps the issue open even when the PR declares Closes" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_PR_BODY='Closes #1'
  export RALPH_CLOSE_POLICY=never

  run_once

  [ "$status" -eq 0 ]
  ! grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
  grep -Fq 'issue comment 1' "$GH_MUTATION_LOG"
  grep -Fq 'RALPH_CLOSE_POLICY=never' "$FAKE_AGENT_LOG"
  grep -Fq 'Part of #<issue number>' "$FAKE_AGENT_LOG"
  grep -Fq 'MUST NOT contain the autoclose keywords `Closes`, `Fixes`, or `Resolves`' "$FAKE_AGENT_LOG"
}

@test "invalid close policy fails before agents or mutations" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export RALPH_CLOSE_POLICY=maybe

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"RALPH_CLOSE_POLICY debe ser exactamente verified o never"* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "review corrections push only to the isolated test remote" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/review-cycle.json"
  export FAKE_CLAUDE_RESULTS='<verdict>CHANGES_REQUESTED</verdict>|<verdict>PASS</verdict>'

  project_branches_before="$(git -C "$PROJECT_ROOT" for-each-ref --format='%(refname)' 'refs/heads/ralph/*')"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"✏️  Codex corrige PR #199"* ]]
  git --git-dir="$TEST_ORIGIN" show-ref --verify --quiet refs/heads/ralph/issue-99
  project_branches_after="$(git -C "$PROJECT_ROOT" for-each-ref --format='%(refname)' 'refs/heads/ralph/*')"
  [ "$project_branches_after" = "$project_branches_before" ]
}

@test "codex JSONL without turn.completed is failed and never merges" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_STDOUT='{"type":"thread.started","thread_id":"thread_fixture"}'
  export FAKE_CODEX_STDERR='codex diagnostic'
  export RUN_DIR="$TEST_ROOT/run"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 70 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  [ "$(find "$RUN_DIR" -name 'codex-*.stdout.jsonl' | wc -l | tr -d '[:space:]')" -eq 1 ]
  [ "$(find "$RUN_DIR" -name 'codex-*.stderr.log' | wc -l | tr -d '[:space:]')" -eq 1 ]
  result_file="$(find "$RUN_DIR" -name 'codex-*.result.json' -print -quit)"
  [ "$(jq -r '.status' "$result_file")" = failed ]
  [ "$(cat "$RUN_DIR"/codex-*.stderr.log)" = 'codex diagnostic' ]
}

@test "codex and claude adapters preserve real JSON output and final messages" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_STDOUT_FILE="$PROJECT_ROOT/tests/fixtures/codex-0.154.0-success.jsonl"
  export FAKE_CODEX_FINAL_MESSAGE='implementation complete'
  export FAKE_CODEX_STDERR='codex diagnostic'
  export FAKE_CLAUDE_STDOUT_FILE="$PROJECT_ROOT/tests/fixtures/claude-2.1.277-success.json"
  export FAKE_CLAUDE_STDERR='claude diagnostic'
  export RUN_DIR="$TEST_ROOT/run"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  grep -Fq -- '--json' "$FAKE_AGENT_LOG"
  grep -Fq -- '--output-format json' "$FAKE_AGENT_LOG"
  codex_stdout="$(find "$RUN_DIR" -name 'codex-*.stdout.jsonl' -print -quit)"
  codex_stderr="$(find "$RUN_DIR" -name 'codex-*.stderr.log' -print -quit)"
  claude_stdout="$(find "$RUN_DIR" -name 'claude-*.stdout.json' -print -quit)"
  claude_stderr="$(find "$RUN_DIR" -name 'claude-*.stderr.log' -print -quit)"
  [ -s "$codex_stdout" ] && [ -s "$codex_stderr" ]
  [ -s "$claude_stdout" ] && [ -s "$claude_stderr" ]
  ! grep -Fq 'codex diagnostic' "$codex_stdout"
  ! grep -Fq 'claude diagnostic' "$claude_stdout"
  [ "$(jq -r '.status' "$RUN_DIR"/codex-*.result.json)" = ok ]
  [ "$(jq -r '.status' "$RUN_DIR"/claude-*.result.json)" = ok ]
  jq -e 'has("status") and has("retry_at") and has("limit_scope") and
    has("retryable") and has("exit_code") and has("final_message") and
    .status == "ok" and .retry_at == null and .limit_scope == "unknown" and
    .retryable == false and .exit_code == 0' "$RUN_DIR"/codex-*.result.json
  jq -e 'has("status") and has("retry_at") and has("limit_scope") and
    has("retryable") and has("exit_code") and has("final_message") and
    .status == "ok" and .retry_at == null and .limit_scope == "unknown" and
    .retryable == false and .exit_code == 0' "$RUN_DIR"/claude-*.result.json
  [ "$(jq -r '.final_message' "$RUN_DIR"/codex-*.result.json)" = 'implementation complete' ]
  [ "$(jq -r '.final_message' "$RUN_DIR"/claude-*.result.json)" = '<verdict>PASS</verdict>' ]
}

@test "claude JSON without a final result is failed and never merges" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CLAUDE_STDOUT='{"type":"assistant","message":{"role":"assistant","content":[]}}'
  export FAKE_CLAUDE_STDERR='claude stopped before result'
  export RUN_DIR="$TEST_ROOT/run"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 70 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  result_file="$(find "$RUN_DIR" -name 'claude-*.result.json' -print -quit)"
  [ "$(jq -r '.status' "$result_file")" = failed ]
  [ "$(jq -r '.final_message' "$result_file")" = null ]
}

@test "truncated codex JSONL is failed and never merges" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_STDOUT_FILE="$PROJECT_ROOT/tests/fixtures/codex-0.154.0-truncated.jsonl"
  export FAKE_CODEX_FINAL_MESSAGE='implementation complete'
  export RUN_DIR="$TEST_ROOT/run"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 70 ]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  result_file="$(find "$RUN_DIR" -name 'codex-*.result.json' -print -quit)"
  [ "$(jq -r '.status' "$result_file")" = failed ]
}

@test "codex failure ignores 429 and quota in aggregated output" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_EXITS='1|0'
  export FAKE_CODEX_FINAL_MESSAGE='implementation complete'
  export FAKE_CODEX_STDOUT='{"type":"thread.started","thread_id":"thread_fixture"}
{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"Tests: 429 passed; quota check complete"}}
{"type":"item.completed","item":{"type":"agent_message","text":"implementation complete"}}
{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}'
  export FAKE_DATE_FAST_FORWARD=1
  export RUN_DIR="$TEST_ROOT/run"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown del proveedor"* ]]
  ! grep -Fq 'pr merge' "$GH_MUTATION_LOG"
  [ "$(cat "$FAKE_CODEX_CALL_COUNT_FILE")" = 1 ]
  result_file="$(find "$RUN_DIR" -name 'codex-*.result.json' -print -quit)"
  [ "$(jq -r '.status' "$result_file")" = unknown ]
  [ "$(jq -r '.retryable' "$result_file")" = false ]
  [ "$(jq -r '.exit_code' "$result_file")" = 1 ]
}

@test "raw auth exit code without a provider signal stays unknown" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_EXIT=65
  export RALPH_CI_POLICY=none
  export RUN_DIR="$TEST_ROOT/run"

  run_once

  [ "$status" -eq 65 ]
  [[ "$output" == *"unknown del proveedor"* ]]
  result_file="$RUN_DIR/codex-1.result.json"
  [ "$(jq -r '.status' "$result_file")" = unknown ]
  [ ! -e "$TEST_REPO/last_run.md" ]
}

@test "successful codex tool output mentioning rate limit is not a usage limit" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_FINAL_MESSAGE='implementation complete'
  export FAKE_CODEX_STDOUT='{"type":"thread.started","thread_id":"thread_fixture"}
{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"diff contains rate limit implementation"}}
{"type":"item.completed","item":{"type":"agent_message","text":"implementation complete"}}
{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}'
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" != *"Tope"* ]]
  [ ! -s "$FAKE_SLEEP_LOG" ]
  grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "provider rate limit event preserves retry_at and retries the same issue" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_CREATE_PR=1
  export FAKE_CODEX_EXITS='1|0'
  export FAKE_CODEX_FINAL_MESSAGE='implementation complete'
  export FAKE_CODEX_STDOUT='{"type":"error","error":{"code":"rate_limit_exceeded","limit_scope":"session","retry_at":"2026-09-18T23:05:00Z","message":"provider rate limit"}}
{"type":"item.completed","item":{"type":"agent_message","text":"implementation complete"}}
{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}'
  export FAKE_DATE_FAST_FORWARD=1
  export FAKE_SLEEP_NOOP=1
  export RUN_DIR="$TEST_ROOT/run"
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  [ "$(grep -c '════ Issue #1' <<<"$output")" -eq 2 ]
  first_result="$RUN_DIR/codex-1.result.json"
  [ "$(jq -r '.status' "$first_result")" = rate_limited ]
  [ "$(jq -r '.retry_at' "$first_result")" != null ]
  grep -Fq 'pr merge' "$GH_MUTATION_LOG"
}

@test "provider rate limit without retry_at retries at most three times" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_EXITS=1
  export FAKE_CODEX_FINAL_MESSAGE='implementation incomplete'
  export FAKE_CODEX_STDOUT='{"type":"error","error":{"code":"rate_limit_exceeded","limit_scope":"session","message":"provider rate limit"}}'
  export FAKE_SLEEP_NOOP=1
  export RUN_DIR="$TEST_ROOT/run"
  export RALPH_CHECKPOINT_FILE="$TEST_ROOT/last_run.md"
  export RALPH_MAX_LIMIT_RETRIES=3

  run_once

  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_CODEX_CALL_COUNT_FILE")" = 4 ]
  [ "$(jq -r '.status' "$RUN_DIR"/codex-4.result.json)" = rate_limited ]
  [ "$(jq -r '.retry_at' "$RUN_DIR"/codex-4.result.json)" = null ]
  [ ! -s "$FAKE_SLEEP_LOG" ]
  [[ "$output" == *"máximo 3"* ]]
  [ -f "$RALPH_CHECKPOINT_FILE" ]
}

@test "provider auth_error stops the run with a checkpoint" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_EXIT=1
  export FAKE_CODEX_FINAL_MESSAGE='authentication failed'
  export FAKE_CODEX_STDOUT='{"type":"error","error":{"code":"unauthorized","message":"provider rejected credentials"}}'
  export RALPH_CHECKPOINT_FILE="$TEST_ROOT/last_run.md"
  export RUN_DIR="$TEST_ROOT/run"

  run_once

  [ "$status" -eq 1 ]
  [ "$(cat "$FAKE_CODEX_CALL_COUNT_FILE" 2>/dev/null || printf 0)" = 0 ]
  [[ "$output" == *"auth_error"* ]]
  [[ "$output" == *"provider rejected credentials"* ]]
  [ -f "$RALPH_CHECKPOINT_FILE" ]
  [ "$(jq -r '.status' "$RUN_DIR"/codex-1.result.json)" = auth_error ]
}

@test "provider reset after the global deadline is not awaited" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_EXIT=1
  export FAKE_CODEX_STDOUT='{"type":"error","error":{"code":"rate_limit_exceeded","retry_at":4102444800,"message":"provider rate limit"}}'
  export FAKE_SLEEP_NOOP=1
  export RALPH_CHECKPOINT_FILE="$TEST_ROOT/last_run.md"
  export RALPH_DEADLINE_EPOCH=4102440000
  export RUN_DIR="$TEST_ROOT/run"

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"excede el deadline global"* ]]
  [ ! -s "$FAKE_SLEEP_LOG" ]
  [ -f "$RALPH_CHECKPOINT_FILE" ]
  [ "$(jq -r '.status' "$RUN_DIR"/codex-1.result.json)" = rate_limited ]
}

@test "provider config_error stops the run with a checkpoint" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/happy-path.json"
  export FAKE_CODEX_EXIT=1
  export FAKE_CODEX_STDOUT='{"type":"error","error":{"code":"invalid_model","message":"provider rejected model"}}'
  export RALPH_CHECKPOINT_FILE="$TEST_ROOT/last_run.md"
  export RUN_DIR="$TEST_ROOT/run"

  run_once

  [ "$status" -eq 1 ]
  [[ "$output" == *"config_error"* ]]
  [[ "$output" == *"provider rejected model"* ]]
  [ -f "$RALPH_CHECKPOINT_FILE" ]
  [ "$(jq -r '.status' "$RUN_DIR"/codex-1.result.json)" = config_error ]
}

@test "fallo fatal antes de correr ningún agente no explota por ADAPTER_STATUS" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/review-cycle.json"
  export FAKE_HEAD_REF_OID="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  run_once

  [ "$status" -eq 70 ]
  [[ "$output" == *"head_changed"* ]]
  [[ "$output" == *"Fallo fatal (rc=70)"* ]]
  [[ "$output" != *"unbound variable"* ]]
}
