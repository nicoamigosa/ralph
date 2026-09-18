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

  [ "$status" -eq 0 ]
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
