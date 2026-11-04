#!/usr/bin/env bats

load test_helper

@test "skill plan delegates selection without agents mutations or token output" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/dry-run.json"
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  mkdir -p "$FAKE_RELEASE_ROOT"
  printf '%s\n' '[{"tag_name":"v99.0.0","draft":false,"prerelease":false}]' > "$FAKE_RELEASE_ROOT/releases.json"

  run bash -c 'cd "$1" && bash "$2/skills/ralph/scripts/ralph.sh" plan' _ "$TEST_REPO" "$PROJECT_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *'actualización disponible: v99.0.0'* ]]
  [[ "$output" == *'RALPH_TDD_SKILL: presente'* ]]
  [[ "$output" == *'RALPH_REVIEWER_GH_TOKEN: presente'* ]]
  [[ "$output" == *'#1'* ]]
  [[ "$output" != *'fake-reviewer-token'* ]]
  [[ "$output" != *'fake-orchestrator-token'* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill run requires confirmation and detaches a surviving process" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts" "$TEST_ROOT/install/lib"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"
  cp "$PROJECT_ROOT/lib/config.sh" "$TEST_ROOT/install/lib/"
  cat > "$TEST_ROOT/install/once.sh" <<'SH'
#!/usr/bin/env bash
trap -p HUP > "$FAKE_LAUNCH_MARKER"
launch_pgid="$("$RALPH_TEST_REAL_PS" -o pgid= -p "$$" | tr -d " ")"
if [ "$launch_pgid" != "$FAKE_LAUNCH_PARENT_PGID" ]; then
  printf 'isolated process group\n' >> "$FAKE_LAUNCH_MARKER"
fi
printf '%s\n' "$$" >> "$FAKE_LAUNCH_MARKER"
for ((i=0; i<100; i++)); do
  if [ -f "$FAKE_LAUNCH_RELEASE" ]; then
    printf 'completed\n' >> "$FAKE_LAUNCH_MARKER"
    exit 0
  fi
  "$RALPH_TEST_REAL_SLEEP" 0.1
done
exit 1
SH
  export FAKE_LAUNCH_MARKER="$TEST_ROOT/launched" FAKE_LAUNCH_RELEASE="$TEST_ROOT/release"
  export RALPH_REQUIRE_PROTECTION=1
  helper="$TEST_ROOT/install/skills/ralph/scripts/ralph.sh"

  run bash -c 'cd "$1" && bash "$2" run' _ "$TEST_REPO" "$helper"
  [ "$status" -ne 0 ]
  [ ! -f "$FAKE_LAUNCH_MARKER" ]
  run bash -c 'cd "$1" && export FAKE_LAUNCH_PARENT_PGID="$("$RALPH_TEST_REAL_PS" -o pgid= -p "$$" | tr -d " ")" && bash "$2" run --confirmed' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 0 ]
  [[ "$output" == *'PID:'* ]]
  for ((i=0; i<100; i++)); do
    [ ! -f "$FAKE_LAUNCH_MARKER" ] || break
    "$TEST_REAL_SLEEP" 0.1
  done
  touch "$FAKE_LAUNCH_RELEASE"
  for ((i=0; i<100; i++)); do
    if grep -Fq completed "$FAKE_LAUNCH_MARKER"; then break; fi
    "$TEST_REAL_SLEEP" 0.1
  done
  grep -Fq completed "$FAKE_LAUNCH_MARKER"
  grep -Fq "trap -- '' SIGHUP" "$FAKE_LAUNCH_MARKER"
  grep -Fq 'isolated process group' "$FAKE_LAUNCH_MARKER"
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill report interprets stop reasons from fixtures without mutations" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts" "$TEST_ROOT/install/runs/fixture"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"
  helper="$TEST_ROOT/install/skills/ralph/scripts/ralph.sh"
  while IFS=$'\t' read -r reason meaning next; do
    jq -n --arg reason "$reason" '{schema:1,run_id:"fixture",stop_reason:$reason,
      exit_code:0,issues_started:1,issues:[{number:42,status:"merged"}],
      merged:[{issue:42,pr:101}],open_prs:[],needs_human:[],blocked:[],errors:[],
      usage:{codex_tokens:null,claude_estimated_usd:0.25},
      protection:{required:true,status:"passed"}}' > "$TEST_ROOT/install/runs/fixture/summary.json"
    run bash -c 'cd "$1" && bash "$2" report fixture' _ "$TEST_REPO" "$helper"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$reason"* ]]
    [[ "$output" == *"$meaning"* ]]
    [[ "$output" == *"Siguiente paso: $next"* ]]
    [[ "$output" == *'101'* ]]
    [[ "$output" == *'0.25'* ]]
    [[ "$output" == *'desconocido'* ]]
  done < <(jq -r '.[] | [.reason,.meaning,.next] | @tsv' "$PROJECT_ROOT/tests/fixtures/skill-stop-reasons.json")
  run bash -c 'cd "$1" && bash "$2" report' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 0 ]
  [[ "$output" == *fixture* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill plan fails closed on update lookup auth or missing configuration" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/dry-run.json"
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  mkdir -p "$FAKE_RELEASE_ROOT"
  printf '%s\n' 'invalid-json' > "$FAKE_RELEASE_ROOT/releases.json"
  helper="$PROJECT_ROOT/skills/ralph/scripts/ralph.sh"
  run bash -c 'cd "$1" && bash "$2" plan' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 20 ]
  [[ "$output" == *'consulta fallida'* ]]
  printf '%s\n' '[{"tag_name":"v99.0.0","draft":false,"prerelease":false}]' > "$FAKE_RELEASE_ROOT/releases.json"
  export FAKE_GH_AUTH_STATUS_EXIT=1 FAKE_GH_AUTH_STATUS_OUTPUT=fake-reviewer-token
  run bash -c 'cd "$1" && bash "$2" plan' _ "$TEST_REPO" "$helper"
  [ "$status" -ne 0 ]
  [[ "$output" == *'gh auth status: ausente'* ]]
  [[ "$output" != *'fake-reviewer-token'* ]]
  unset FAKE_GH_AUTH_STATUS_EXIT RALPH_REVIEWER_GH_TOKEN
  run bash -c 'cd "$1" && bash "$2" plan' _ "$TEST_REPO" "$helper"
  [ "$status" -ne 0 ]
  [[ "$output" == *'RALPH_REVIEWER_GH_TOKEN: ausente'* ]]
  unset RALPH_TDD_SKILL
  run bash -c 'cd "$1" && bash "$2" plan' _ "$TEST_REPO" "$helper"
  [ "$status" -ne 0 ]
  [[ "$output" == *'RALPH_TDD_SKILL: ausente'* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill run refuses sandbox gate overrides even after confirmation" {
  run bash -c 'cd "$1" && bash "$2/skills/ralph/scripts/ralph.sh" run --confirmed' _ "$TEST_REPO" "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *'requiere protección'* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill report rejects missing malformed and traversal summaries" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts" "$TEST_ROOT/install/runs/bad"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"
  helper="$TEST_ROOT/install/skills/ralph/scripts/ralph.sh"
  for id in missing ../outside; do
    run bash -c 'cd "$1" && bash "$2" report "$3"' _ "$TEST_REPO" "$helper" "$id"
    [ "$status" -ne 0 ]
  done
  printf '%s\n' '{"stop_reason":"no_ready_issues"}' > "$TEST_ROOT/install/runs/bad/summary.json"
  run bash -c 'cd "$1" && bash "$2" report bad' _ "$TEST_REPO" "$helper"
  [ "$status" -ne 0 ]
  [[ "$output" == *'resultado desconocido'* ]]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill report does not treat a structurally incomplete summary as a result" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts" "$TEST_ROOT/install/runs/incomplete"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"
  printf '%s\n' '{"schema":1,"stop_reason":"no_ready_issues","issues":[],"usage":{}}' > "$TEST_ROOT/install/runs/incomplete/summary.json"

  run bash -c 'cd "$1" && bash "$2/install/skills/ralph/scripts/ralph.sh" report incomplete' _ "$TEST_REPO" "$TEST_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" != *'Siguiente paso: Reanudar'* ]]
}

@test "skill helper resolves its installation through the project symlink" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts" "$TEST_ROOT/install/runs/linked" "$TEST_REPO/.claude/skills"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"
  ln -s "$TEST_ROOT/install/skills/ralph" "$TEST_REPO/.claude/skills/ralph"
  printf '%s\n' '{"schema":1,"run_id":"linked","stop_reason":"running","issues_started":0,"issues":[],"merged":[],"open_prs":[],"needs_human":[],"blocked":[],"errors":[],"usage":{}}' > "$TEST_ROOT/install/runs/linked/summary.json"

  run bash -c 'cd "$1" && bash .claude/skills/ralph/scripts/ralph.sh report linked' _ "$TEST_REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *'Corrida: linked'* ]]
}
