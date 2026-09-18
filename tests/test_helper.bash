#!/usr/bin/env bash

PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
TEST_REAL_TEE="$(command -v tee)"

setup() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ralph-tests.XXXXXX")"
  TEST_ORIGIN="$TEST_ROOT/origin.git"
  TEST_REPO="$TEST_ROOT/repo"
  git clone -q --bare "$PROJECT_ROOT" "$TEST_ORIGIN"
  git clone -q "$TEST_ORIGIN" "$TEST_REPO"
  if ! git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/main; then
    git -C "$TEST_REPO" branch main HEAD
  fi
  git -C "$TEST_REPO" config user.email "ralph-tests@example.invalid"
  git -C "$TEST_REPO" config user.name "ralph tests"

  export RALPH_TEST_REAL_TEE="$TEST_REAL_TEE"
  export PATH="$PROJECT_ROOT/tests/fakes:$PATH"
  export GH_MUTATION_LOG="$TEST_ROOT/mutations.log"
  export FAKE_AGENT_LOG="$TEST_ROOT/agents.log"
  export FAKE_CODEX_PR_STATE="$TEST_ROOT/codex-created-pr"
  export FAKE_CLAUDE_CALL_COUNT_FILE="$TEST_ROOT/claude-calls"
  : > "$GH_MUTATION_LOG"
  : > "$FAKE_AGENT_LOG"
  printf '0\n' > "$FAKE_CLAUDE_CALL_COUNT_FILE"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_once() {
  run bash -c 'cd "$1" && bash "$2/once.sh"' _ "$TEST_REPO" "$PROJECT_ROOT"
}
