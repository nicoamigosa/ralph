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
  export FAKE_CLAUDE_RESULTS='usage limit|<verdict>PASS</verdict>'
  export FAKE_UNAME_SYSTEM=Darwin
  export FAKE_DATE_FAST_FORWARD=1
  export FAKE_DATE_INCREMENTAL_FAST_FORWARD=1
  export FAKE_SLEEP_NOOP=1
  export RALPH_CI_POLICY=none

  run_once

  [ "$status" -eq 0 ]
  grep -Fq -- '-r ' "$FAKE_DATE_LOG"
  ! grep -Fq -- '-d ' "$FAKE_DATE_LOG"
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
  grep -Fq "pr merge 101 --squash --match-head-commit $reviewed_sha --delete-branch" "$GH_MUTATION_LOG"
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

@test "usage limit during conflict keeps the PR unlabeled for retry" {
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

  [ "$status" -eq 0 ]
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

  run_once

  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ PASS en la ronda 1"* ]]
  [[ "$output" == *"🎉 #1 mergeado a main y cerrado."* ]]
  grep -Fq 'codex ' "$FAKE_AGENT_LOG"
  grep -Fq 'claude ' "$FAKE_AGENT_LOG"
  grep -Fq 'pr merge 101 --squash --match-head-commit ' "$GH_MUTATION_LOG"
  grep -Fq 'issue close 1' "$GH_MUTATION_LOG"
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
