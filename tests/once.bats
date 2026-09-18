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
  ! grep -Eq '^(codex|claude) ' "$FAKE_AGENT_LOG"
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
  [ "$(grep -c '^codex ' "$FAKE_AGENT_LOG")" -eq 1 ]
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
  [ "$(grep -c '^codex ' "$FAKE_AGENT_LOG")" -eq 1 ]
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
  [ "$(grep -c '^codex ' "$FAKE_AGENT_LOG")" -eq 1 ]
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
  [ "$(grep -c '^codex ' "$FAKE_AGENT_LOG")" -eq 1 ]
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
  [ "$(grep -c '^codex ' "$FAKE_AGENT_LOG")" -eq 1 ]
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
