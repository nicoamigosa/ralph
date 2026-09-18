#!/usr/bin/env bats

load test_helper

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
  grep -Fq 'pr merge 101 --squash --delete-branch' "$GH_MUTATION_LOG"
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
  grep -Fq 'pr merge 101 --squash --delete-branch' "$GH_MUTATION_LOG"
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
