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
    run bash -c 'cd "$1" && bash "$2" report fixture --json' _ "$TEST_REPO" "$helper"
    [ "$status" -eq 0 ]
    if [ "$reason" = completed ]; then
      jq -e '.next_step == null' <<<"$output"
    else
      jq -e --arg next "$next" '.next_step | startswith($next)' <<<"$output"
    fi
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

@test "skill plan json reports selector candidates exclusions and requirement presence" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/dry-run.json"
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  mkdir -p "$FAKE_RELEASE_ROOT"
  printf '%s\n' '[{"tag_name":"v99.0.0","draft":false,"prerelease":false}]' > "$FAKE_RELEASE_ROOT/releases.json"

  run bash -c 'cd "$1" && bash "$2/skills/ralph/scripts/ralph.sh" plan --json' _ "$TEST_REPO" "$PROJECT_ROOT"

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  jq -e '.schema == 1 and .update.status == "available" and
    .requirements.gh_auth and .requirements.tdd_skill and .requirements.reviewer_token and
    ([.candidates[].number] == [4,6]) and
    ([.excluded[] | {number,reason}] == [{number:2,reason:"parent"},{number:5,reason:"needs-human"},{number:10,reason:"blocked-by:4"}])' <<<"$output"
  [[ "$output" != *'fake-reviewer-token'* ]]
  [[ "$output" != *'fake-orchestrator-token'* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill report json exposes summary evidence and unknown usage without secrets" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts" "$TEST_ROOT/install/runs/fixture"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"
  jq -n '{schema:1,run_id:"fixture",stop_reason:"completed",issues_started:1,
    issues:[{number:42,status:"merged"}],merged:[{issue:42,pr:101}],open_prs:[],
    needs_human:[],blocked:[],errors:[],usage:{claude_estimated_usd:0.25},
    protection:{required:true,status:"passed"},untrusted:"fake-reviewer-token fake-orchestrator-token"}' > "$TEST_ROOT/install/runs/fixture/summary.json"
  helper="$TEST_ROOT/install/skills/ralph/scripts/ralph.sh"

  run bash -c 'cd "$1" && bash "$2" report fixture --json' _ "$TEST_REPO" "$helper"

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  jq -e '.schema == 1 and .run_id == "fixture" and .stop_reason == "completed" and
    .issues[0].number == 42 and .merged[0].pr == 101 and .open_prs == [] and
    .protection.status == "passed" and .usage.claude_estimated_usd == 0.25 and
    .usage.codex_tokens == null and .next_step == null' <<<"$output"
  [[ "$output" != *'fake-reviewer-token'* ]]
  [[ "$output" != *'fake-orchestrator-token'* ]]
  run bash -c 'cd "$1" && bash "$2" report --json' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  jq -e '.run_id == "fixture"' <<<"$output"
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill helper returns usage code 2 for invalid arguments and missing confirmation" {
  for args in 'plan --bad' 'run' 'report ../outside' 'unknown'; do
    read -r -a argv <<<"$args"
    run bash -c 'cd "$1" && shift && bash "$@"' _ "$TEST_REPO" "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "${argv[@]}"
    [ "$status" -eq 2 ]
  done
}

@test "skill plan json returns configuration code 3 and checks each requirement independently" {
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  mkdir -p "$FAKE_RELEASE_ROOT"
  printf '%s\n' '[{"tag_name":"v99.0.0","draft":false,"prerelease":false}]' > "$FAKE_RELEASE_ROOT/releases.json"
  unset RALPH_TDD_SKILL

  run bash -c 'cd "$1" && bash "$2/skills/ralph/scripts/ralph.sh" plan --json' _ "$TEST_REPO" "$PROJECT_ROOT"

  [ "$status" -eq 3 ]
  [ -n "$output" ]
  jq -e '.success == false and .requirements.gh_auth == true and
    .requirements.tdd_skill == false and .requirements.reviewer_token == true and
    .candidates == null and .excluded == null' <<<"$output"
  [ ! -s "$FAKE_AGENT_LOG" ]
}

@test "skill helper returns authentication code 4 without authentication diagnostics" {
  export FAKE_GH_AUTH_STATUS_EXIT=1 FAKE_GH_AUTH_STATUS_OUTPUT=fake-reviewer-token
  export RALPH_REQUIRE_PROTECTION=1

  run bash -c 'cd "$1" && bash "$2/skills/ralph/scripts/ralph.sh" run --confirmed' _ "$TEST_REPO" "$PROJECT_ROOT"

  [ "$status" -eq 4 ]
  [[ "$output" == *'gh auth status: ausente o inválido'* ]]
  [[ "$output" != *'fake-reviewer-token'* ]]
}

@test "skill report returns summary code 5 for absent malformed or incomplete evidence" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts" "$TEST_ROOT/install/runs/bad"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"
  helper="$TEST_ROOT/install/skills/ralph/scripts/ralph.sh"
  run bash -c 'cd "$1" && bash "$2" report missing --json' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 5 ]
  for summary in '' invalid-json '{}'; do
    printf '%s\n' "$summary" > "$TEST_ROOT/install/runs/bad/summary.json"
    run bash -c 'cd "$1" && bash "$2" report bad --json' _ "$TEST_REPO" "$helper"
    [ "$status" -eq 5 ]
    [[ "$output" == *'resultado desconocido'* ]]
  done
}

@test "skill plan returns once failure code 6 and no partial candidates" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/dry-run.json"
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases" FAKE_ISSUE_VIEW_FAIL_NUM=4 FAKE_ISSUE_VIEW_FAIL_FIELD=state
  mkdir -p "$FAKE_RELEASE_ROOT"
  printf '%s\n' '[{"tag_name":"v99.0.0","draft":false,"prerelease":false}]' > "$FAKE_RELEASE_ROOT/releases.json"

  run bash -c 'cd "$1" && bash "$2/skills/ralph/scripts/ralph.sh" plan --json' _ "$TEST_REPO" "$PROJECT_ROOT"

  [ "$status" -eq 6 ]
  [ -n "$output" ]
  jq -e '.success == false and .candidates == null and .excluded == null' <<<"$output"
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill help documents modes json and distinct exit codes" {
  run bash -c 'cd "$1" && bash "$2/skills/ralph/scripts/ralph.sh" --help' _ "$TEST_REPO" "$PROJECT_ROOT"

  [ "$status" -eq 0 ]
  for text in 'plan [--json]' 'run --confirmed' 'report [run-id] [--json]' \
    '0: éxito' '2: uso incorrecto' '3: configuración' '4: autenticación' \
    '5: resumen' '6: fallo de once.sh' '20: consulta de actualización' '10'; do
    [[ "$output" == *"$text"* ]]
  done
}

@test "skill plan json reports current version and failed update queries without inventing a plan" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/dry-run.json"
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  mkdir -p "$FAKE_RELEASE_ROOT"
  jq -n --arg version "v$(cat "$PROJECT_ROOT/VERSION")" '[{tag_name:$version,draft:false,prerelease:false}]' > "$FAKE_RELEASE_ROOT/releases.json"
  helper="$PROJECT_ROOT/skills/ralph/scripts/ralph.sh"

  run bash -c 'cd "$1" && bash "$2" plan --json' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  jq -e '.success == true and .update.status == "current" and .candidates[0].number == 4' <<<"$output"
  printf '%s\n' invalid-json > "$FAKE_RELEASE_ROOT/releases.json"
  run bash -c 'cd "$1" && bash "$2" plan --json' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 20 ]
  [ -n "$output" ]
  jq -e '.success == false and .update.status == "unknown" and .candidates == null and .excluded == null' <<<"$output"
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill report without any summary returns summary code 5" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"

  run bash -c 'cd "$1" && bash "$2/install/skills/ralph/scripts/ralph.sh" report --json' _ "$TEST_REPO" "$TEST_ROOT"

  [ "$status" -eq 5 ]
}

@test "skill plan loads reviewer token from the default XDG reviewer config without exposing it" {
  export GH_FIXTURE="$PROJECT_ROOT/tests/fixtures/dry-run.json"
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  mkdir -p "$FAKE_RELEASE_ROOT" "$XDG_CONFIG_HOME/ralph"
  printf '%s\n' '[{"tag_name":"v99.0.0","draft":false,"prerelease":false}]' > "$FAKE_RELEASE_ROOT/releases.json"
  printf '%s\n' 'RALPH_REVIEWER_GH_TOKEN=fake-file-reviewer-token' > "$XDG_CONFIG_HOME/ralph/reviewer.env"
  unset RALPH_REVIEWER_GH_TOKEN

  run bash -c 'cd "$1" && bash "$2/skills/ralph/scripts/ralph.sh" plan' _ "$TEST_REPO" "$PROJECT_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *'RALPH_REVIEWER_GH_TOKEN: presente'* ]]
  [[ "$output" != *'fake-file-reviewer-token'* ]]
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill helper rejects an explicitly missing reviewer config before plan or run" {
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  mkdir -p "$FAKE_RELEASE_ROOT"
  printf '%s\n' '[{"tag_name":"v99.0.0","draft":false,"prerelease":false}]' > "$FAKE_RELEASE_ROOT/releases.json"
  export RALPH_REVIEWER_CONFIG="$TEST_ROOT/missing-reviewer.env"

  for args in 'plan' 'plan --json' 'run --confirmed'; do
    read -r -a argv <<<"$args"
    run bash -c 'cd "$1" && shift && bash "$@"' _ "$TEST_REPO" "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "${argv[@]}"
    [ "$status" -eq 3 ]
  done
  [ ! -s "$FAKE_AGENT_LOG" ]
  [ ! -s "$GH_MUTATION_LOG" ]
}

@test "skill report without candidates names blocked issues instead of suggesting resume in text and json" {
  mkdir -p "$TEST_ROOT/install/skills/ralph/scripts" "$TEST_ROOT/install/runs/fixture"
  cp "$PROJECT_ROOT/skills/ralph/scripts/ralph.sh" "$TEST_ROOT/install/skills/ralph/scripts/"
  cp "$PROJECT_ROOT/tests/fixtures/skill-no-ready-summary.json" "$TEST_ROOT/install/runs/fixture/summary.json"
  helper="$TEST_ROOT/install/skills/ralph/scripts/ralph.sh"

  run bash -c 'cd "$1" && bash "$2" report fixture --json' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 0 ]
  next="$(jq -r '.next_step' <<<"$output")"
  [[ "$next" == *'#105'* ]]
  [[ "$next" == *'#106'* ]]
  [[ "$next" == *'ready-for-agent'* ]]
  [[ "$next" != *'Reanudar'* ]]
  [[ "$next" != *'/ralph run'* ]]

  run bash -c 'cd "$1" && bash "$2" report fixture' _ "$TEST_REPO" "$helper"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Siguiente paso: $next"* ]]
  [ ! -s "$GH_MUTATION_LOG" ]
}
