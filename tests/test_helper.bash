#!/usr/bin/env bash

PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
TEST_REAL_TEE="$(command -v tee)"
TEST_REAL_GIT="$(command -v git)"
TEST_REAL_DATE="$(command -v date)"
TEST_REAL_SLEEP="$(command -v sleep)"
TEST_REAL_MKTEMP="$(command -v mktemp)"
TEST_REAL_UNAME="$(command -v uname)"

# Los tests corren también dentro de una corrida real de ralph (el agente
# ejecuta bats desde un `codex exec` hijo de once.sh) y heredarían su
# configuración: RALPH_REQUIRED_CHECKS_JSON, RALPH_ISSUE_ORDER, etc. Con esos
# valores los fixtures no cuadran y, p. ej., el poll de CI espera 30 minutos
# reales. Cada test parte de un entorno sin RALPH_* ni FAKE_*; sólo se
# conservan las rutas reales que los fakes necesitan.
clear_ralph_env() {
  local name
  for name in $(compgen -v RALPH_) $(compgen -v FAKE_); do
    case "$name" in
      RALPH_TEST_REAL_*) ;;
      *) unset "$name" ;;
    esac
  done
}

setup() {
  clear_ralph_env
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ralph-tests.XXXXXX")"
  TEST_ORIGIN="$TEST_ROOT/origin.git"
  TEST_REPO="$TEST_ROOT/repo"
  git clone -q --bare "$PROJECT_ROOT" "$TEST_ORIGIN"
  git clone -q "$TEST_ORIGIN" "$TEST_REPO"
  if ! git -C "$TEST_REPO" show-ref --verify --quiet refs/heads/main; then
    git -C "$TEST_REPO" branch main HEAD
  fi
  git -C "$TEST_REPO" push -q origin main
  git -C "$TEST_REPO" config user.email "ralph-tests@example.invalid"
  git -C "$TEST_REPO" config user.name "ralph tests"

  export RALPH_TEST_REAL_TEE="$TEST_REAL_TEE"
  export RALPH_TEST_REAL_GIT="$TEST_REAL_GIT"
  export RALPH_TEST_REAL_DATE="$TEST_REAL_DATE"
  export RALPH_TEST_REAL_SLEEP="$TEST_REAL_SLEEP"
  export RALPH_TEST_REAL_MKTEMP="$TEST_REAL_MKTEMP"
  export RALPH_TEST_REAL_UNAME="$TEST_REAL_UNAME"
  export FAKE_CI_CALL_COUNT_FILE="$TEST_ROOT/ci-calls"
  export FAKE_CI_CURRENT_RESULT_FILE="$TEST_ROOT/current-ci-result"
  export PATH="$PROJECT_ROOT/tests/fakes:$PATH"
  export GH_MUTATION_LOG="$TEST_ROOT/mutations.log"
  export FAKE_AGENT_LOG="$TEST_ROOT/agents.log"
  export FAKE_CODEX_PR_STATE="$TEST_ROOT/codex-created-pr"
  export FAKE_CODEX_CALL_COUNT_FILE="$TEST_ROOT/codex-calls"
  export FAKE_CLAUDE_CALL_COUNT_FILE="$TEST_ROOT/claude-calls"
  export FAKE_DATE_CALL_COUNT_FILE="$TEST_ROOT/date-calls"
  export FAKE_DATE_LOG="$TEST_ROOT/date.log"
  export FAKE_MKTEMP_LOG="$TEST_ROOT/mktemp.log"
  export FAKE_API_LOG="$TEST_ROOT/api.log"
  : > "$GH_MUTATION_LOG"
  : > "$FAKE_API_LOG"
  : > "$FAKE_AGENT_LOG"
  : > "$FAKE_MKTEMP_LOG"
  : > "$FAKE_DATE_LOG"
  printf '0\n' > "$FAKE_CODEX_CALL_COUNT_FILE"
  printf '0\n' > "$FAKE_CLAUDE_CALL_COUNT_FILE"
  printf '0\n' > "$FAKE_DATE_CALL_COUNT_FILE"
  printf '0\n' > "$FAKE_CI_CALL_COUNT_FILE"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_once() {
  run bash -c 'cd "$1" && bash "$2/once.sh"' _ "$TEST_REPO" "$PROJECT_ROOT"
}
