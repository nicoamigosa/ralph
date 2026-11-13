#!/usr/bin/env bats

load test_helper

test_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

make_release_fixture() {
  local release_root="$TEST_ROOT/releases"
  local version stage_root manifest_path

  while IFS= read -r manifest_path; do
    case "$manifest_path" in
      ''|'#'*) continue ;;
    esac
    mkdir -p "$TEST_REPO/$(dirname "$manifest_path")"
    cp "$PROJECT_ROOT/$manifest_path" "$TEST_REPO/$manifest_path"
  done < "$PROJECT_ROOT/MANIFEST"
  # La instalación de prueba se fija en 1.1.0: heredar la VERSION real del repo
  # ataría estos tests al número de release del día, y en cuanto el repo llega a
  # 1.2.0 actualizar a 1.2.0 pasa a ser un no-op y --check dice 'actual'.
  printf '%s\n' '1.1.0' > "$TEST_REPO/VERSION"
  mkdir -p "$release_root"

  for version in 1.1.0 1.2.0; do
    stage_root="$TEST_ROOT/stage-$version/ralph-v$version"
    mkdir -p "$stage_root"
    while IFS= read -r manifest_path; do
      case "$manifest_path" in
        ''|'#'*) continue ;;
      esac
      mkdir -p "$stage_root/$(dirname "$manifest_path")"
      cp "$TEST_REPO/$manifest_path" "$stage_root/$manifest_path"
    done < "$TEST_REPO/MANIFEST"
    printf '%s\n' "$version" > "$stage_root/VERSION"
    if [ "$version" = 1.2.0 ]; then
      printf '%s\n' 'release once' > "$stage_root/once.sh"
      printf '%s\n' 'not in manifest' > "$stage_root/unlisted-release-file.txt"
    fi
    tar -czf "$release_root/ralph-v$version.tar.gz" \
      -C "$(dirname "$stage_root")" "$(basename "$stage_root")"
  done
  (cd "$release_root" && if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 ralph-v1.1.0.tar.gz ralph-v1.2.0.tar.gz > SHA256SUMS
  else
    sha256sum ralph-v1.1.0.tar.gz ralph-v1.2.0.tar.gz > SHA256SUMS
  fi)
}

repack_target_release() {
  local stage_root="$TEST_ROOT/stage-1.2.0/ralph-v1.2.0"
  tar -czf "$TEST_ROOT/releases/ralph-v1.2.0.tar.gz" \
    -C "$(dirname "$stage_root")" "$(basename "$stage_root")"
  printf '%s  %s\n' "$(test_sha256 "$TEST_ROOT/releases/ralph-v1.2.0.tar.gz")" \
    ralph-v1.2.0.tar.gz >> "$TEST_ROOT/releases/SHA256SUMS.new"
  while read -r hash asset; do
    [ "$asset" = ralph-v1.2.0.tar.gz ] || printf '%s  %s\n' "$hash" "$asset"
  done < "$TEST_ROOT/releases/SHA256SUMS" >> "$TEST_ROOT/releases/SHA256SUMS.new"
  mv "$TEST_ROOT/releases/SHA256SUMS.new" "$TEST_ROOT/releases/SHA256SUMS"
}

@test "update survives replacing its running script with a different size" {
  make_release_fixture
  target_script="$TEST_ROOT/stage-1.2.0/ralph-v1.2.0/update.sh"
  {
    for ((i = 0; i < 2000; i++)); do
      printf '# Destination release padding to change script offsets\n'
    done
    cat "$target_script"
  } > "$target_script.new"
  mv "$target_script.new" "$target_script"
  repack_target_release
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash "$TEST_REPO/update.sh" 1.2.0

  [ "$status" -eq 0 ]
  [[ "$output" == *'✅ Ralph actualizado'* ]]
  [[ "$output" != *'command not found'* ]]
  cmp "$target_script" "$TEST_REPO/update.sh"
  [ "$(cat "$TEST_REPO/VERSION")" = 1.2.0 ]
}

@test "update runs destination release post-install steps" {
  make_release_fixture
  target_script="$TEST_ROOT/stage-1.2.0/ralph-v1.2.0/update.sh"
  # Only the destination knows this new post-install step.
  sed '/^check_skill_link() {/a\
  printf "destination post-install\\n"' "$target_script" > "$target_script.new"
  mv "$target_script.new" "$target_script"
  repack_target_release
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash "$TEST_REPO/update.sh" 1.2.0

  [ "$status" -eq 0 ]
  [[ "$output" == *'destination post-install'* ]]
  [ -f "$TEST_REPO/.claude/skills/ralph/SKILL.md" ]
}

@test "update reports an explicit failure when an atomic replacement fails" {
  make_release_fixture
  mkdir -p "$TEST_ROOT/bin"
  export TEST_REAL_MV="$(command -v mv)"
  cat > "$TEST_ROOT/bin/mv" <<'FAKE'
#!/usr/bin/env bash
if [[ "${!#}" == */once.sh ]]; then
  printf 'simulated replacement failure\n' >&2
  exit 1
fi
exec "$TEST_REAL_MV" "$@"
FAKE
  chmod +x "$TEST_ROOT/bin/mv"
  export PATH="$TEST_ROOT/bin:$PATH"
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash "$TEST_REPO/update.sh" 1.2.0

  [ "$status" -ne 0 ]
  [[ "$output" == *'No pude reemplazar el archivo distribuido: once.sh.'* ]]
  [[ "$output" != *'✅ Ralph actualizado'* ]]
  [ "$(cat "$TEST_REPO/VERSION")" = 1.2.0 ]
  cmp "$TEST_REPO/once.sh" "$PROJECT_ROOT/once.sh"
  run find "$TEST_REPO" -name '.ralph-update.*' -print
  [ -z "$output" ]
}

@test "update replaces only manifest files and preserves project state" {
  make_release_fixture
  mkdir -p "$TEST_REPO/runs" "$TEST_REPO/.ralph"
  printf '%s\n' 'keep this run' > "$TEST_REPO/runs/keep.txt"
  printf '%s\n' 'keep this config' > "$TEST_REPO/.ralph/config.env"
  printf '%s\n' 'keep this checkpoint' > "$TEST_REPO/last_run.md"
  printf '%s\n' 'do not distribute' > "$TEST_REPO/local-only.txt"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash -c 'cd "$1" && bash ./update.sh 1.2.0' _ "$TEST_REPO"

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_REPO/VERSION")" = '1.2.0' ]
  [ "$(cat "$TEST_REPO/once.sh")" = 'release once' ]
  [ "$(cat "$TEST_REPO/runs/keep.txt")" = 'keep this run' ]
  [ "$(cat "$TEST_REPO/.ralph/config.env")" = 'keep this config' ]
  [ "$(cat "$TEST_REPO/last_run.md")" = 'keep this checkpoint' ]
  [ "$(cat "$TEST_REPO/local-only.txt")" = 'do not distribute' ]
  [ ! -e "$TEST_REPO/unlisted-release-file.txt" ]
}

@test "update aborts on an incorrect release checksum without touching the tree" {
  make_release_fixture
  printf '%s\n' 'tampered release' >> "$TEST_ROOT/releases/ralph-v1.2.0.tar.gz"
  before_version="$(cat "$TEST_REPO/VERSION")"
  before_once="$(test_sha256 "$TEST_REPO/once.sh")"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash -c 'cd "$1" && bash ./update.sh 1.2.0' _ "$TEST_REPO"

  [ "$status" -ne 0 ]
  [[ "$output" == *'Checksum SHA-256 incorrecto'* ]]
  [ "$(cat "$TEST_REPO/VERSION")" = "$before_version" ]
  [ "$(test_sha256 "$TEST_REPO/once.sh")" = "$before_once" ]
}

@test "update accepts uppercase hexadecimal release checksums" {
  make_release_fixture
  while read -r hash asset; do
    printf '%s  %s\n' "${hash^^}" "$asset"
  done < "$TEST_ROOT/releases/SHA256SUMS" > "$TEST_ROOT/releases/SHA256SUMS.upper"
  mv "$TEST_ROOT/releases/SHA256SUMS.upper" "$TEST_ROOT/releases/SHA256SUMS"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash -c 'cd "$1" && bash ./update.sh 1.2.0' _ "$TEST_REPO"

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_REPO/VERSION")" = '1.2.0' ]
}

@test "update lists local changes in common files and leaves them untouched" {
  make_release_fixture
  printf '%s\n' '# local edit' >> "$TEST_REPO/once.sh"
  before_version="$(cat "$TEST_REPO/VERSION")"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash -c 'cd "$1" && bash ./update.sh 1.2.0' _ "$TEST_REPO"

  [ "$status" -ne 0 ]
  [[ "$output" == *'modificaciones locales'* ]]
  [[ "$output" == *'once.sh'* ]]
  [ "$(cat "$TEST_REPO/VERSION")" = "$before_version" ]
  grep -Fq '# local edit' "$TEST_REPO/once.sh"
}

@test "update aborts while the remote ralph run lock is present" {
  make_release_fixture
  lock_tree="$("$RALPH_TEST_REAL_GIT" -C "$TEST_REPO" mktree </dev/null)"
  lock_oid="$(printf '%s\n' 'ralph-lock: v1' 'host: fake' 'pid: 123' \
    'started_at: 1' 'heartbeat_at: 1' | \
    GIT_AUTHOR_DATE='2001-09-09T01:46:40Z' \
    GIT_COMMITTER_DATE='2001-09-09T01:46:40Z' \
    "$RALPH_TEST_REAL_GIT" -C "$TEST_REPO" \
      -c user.name=ralph -c user.email=ralph@localhost commit-tree "$lock_tree")"
  "$RALPH_TEST_REAL_GIT" -C "$TEST_REPO" push -q origin "$lock_oid:refs/ralph/lock"
  before_version="$(cat "$TEST_REPO/VERSION")"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash -c 'cd "$1" && bash ./update.sh 1.2.0' _ "$TEST_REPO"

  [ "$status" -ne 0 ]
  [[ "$output" == *'lock remoto'* ]]
  [ "$(cat "$TEST_REPO/VERSION")" = "$before_version" ]
}

@test "update rejects option-style arguments instead of treating them as versions" {
  make_release_fixture
  before_version="$(cat "$TEST_REPO/VERSION")"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'

  run bash -c 'cd "$1" && bash ./update.sh --unsupported' _ "$TEST_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Opción no soportada: --unsupported"* ]]
  [ "$(cat "$TEST_REPO/VERSION")" = "$before_version" ]
}

@test "check reports installed release as current" {
  make_release_fixture
  printf '%s\n' '[{"tag_name":"v1.1.0","draft":false,"prerelease":false}]' \
    > "$TEST_ROOT/releases/releases.json"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"

  run bash -c 'cd "$1" && bash ./update.sh --check' _ "$TEST_REPO"

  [ "$status" -eq 0 ]
  [ "$output" = 'actual' ]
}

@test "check reports a newer stable release as available" {
  make_release_fixture
  printf '%s\n' '[{"tag_name":"v1.2.0","draft":false,"prerelease":false}]' \
    > "$TEST_ROOT/releases/releases.json"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"

  run bash -c 'cd "$1" && bash ./update.sh --check' _ "$TEST_REPO"

  [ "$status" -eq 10 ]
  [ "$output" = 'actualización disponible: v1.2.0' ]
}

@test "check ignores pre-releases when selecting the latest stable release" {
  make_release_fixture
  printf '%s\n' '[{"tag_name":"v1.2.0-rc.1","draft":false,"prerelease":true},{"tag_name":"v1.1.0","draft":false,"prerelease":false}]' \
    > "$TEST_ROOT/releases/releases.json"

  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"

  run bash -c 'cd "$1" && bash ./update.sh --check' _ "$TEST_REPO"

  [ "$status" -eq 0 ]
  [ "$output" = 'actual' ]
}

@test "check reports a failed release query without claiming current" {
  make_release_fixture
  export FAKE_RELEASE_ROOT="$TEST_ROOT/missing-releases"

  run bash -c 'cd "$1" && bash ./update.sh --check' _ "$TEST_REPO"

  [ "$status" -eq 20 ]
  [ "$output" = 'consulta fallida' ]
}

@test "update links the project skill relatively and leaves an idempotent uncommitted diff" {
  make_release_fixture
  mkdir -p "$TEST_REPO/ralph"
  while IFS= read -r path; do
    case "$path" in ''|'#'*) continue ;; esac
    mkdir -p "$TEST_REPO/ralph/$(dirname "$path")"
    cp "$TEST_REPO/$path" "$TEST_REPO/ralph/$path"
  done < "$TEST_REPO/MANIFEST"
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'
  before_head="$(git -C "$TEST_REPO" rev-parse HEAD)"

  run bash "$TEST_REPO/ralph/update.sh" 1.2.0

  [ "$status" -eq 0 ]
  [ "$(readlink "$TEST_REPO/.claude/skills/ralph")" = '../../ralph/skills/ralph' ]
  [ -f "$TEST_REPO/.claude/skills/ralph/SKILL.md" ]
  [ "$(git -C "$TEST_REPO" rev-parse HEAD)" = "$before_head" ]
  run bash "$TEST_REPO/ralph/update.sh" 1.2.0
  [ "$status" -eq 0 ]
  [ "$(readlink "$TEST_REPO/.claude/skills/ralph")" = '../../ralph/skills/ralph' ]
}

@test "update refuses foreign skill destinations before applying the release" {
  make_release_fixture
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'
  mkdir -p "$TEST_REPO/.claude/skills/ralph"
  printf 'keep\n' > "$TEST_REPO/.claude/skills/ralph/own.txt"

  run bash "$TEST_REPO/update.sh" 1.2.0

  [ "$status" -ne 0 ]
  [[ "$output" == *'no es un enlace nuestro'* ]]
  [ "$(cat "$TEST_REPO/VERSION")" = 1.1.0 ]
  [ "$(cat "$TEST_REPO/.claude/skills/ralph/own.txt")" = keep ]
  rm -r "$TEST_REPO/.claude/skills/ralph"
  ln -s missing-foreign-target "$TEST_REPO/.claude/skills/ralph"
  run bash "$TEST_REPO/update.sh" 1.2.0
  [ "$status" -ne 0 ]
  [ "$(readlink "$TEST_REPO/.claude/skills/ralph")" = missing-foreign-target ]
  [ "$(cat "$TEST_REPO/VERSION")" = 1.1.0 ]
}

@test "update rejects a non-directory skill parent before replacing files" {
  make_release_fixture
  export FAKE_RELEASE_ROOT="$TEST_ROOT/releases"
  export RALPH_RELEASE_BASE_URL='https://releases.invalid/ralph'
  mkdir -p "$TEST_REPO/.claude"
  printf 'keep parent\n' > "$TEST_REPO/.claude/skills"

  run bash "$TEST_REPO/update.sh" 1.2.0

  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_REPO/VERSION")" = 1.1.0 ]
  [ "$(cat "$TEST_REPO/.claude/skills")" = 'keep parent' ]
}
