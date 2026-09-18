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
