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

@test "update check reports a newer stable release" {
  make_release_fixture
  export FAKE_LATEST_VERSION=1.2.0
  export RALPH_RELEASE_API_URL='https://api.invalid/repos/nicoamigosa/ralph/releases/latest'

  run bash -c 'cd "$1" && bash ./update.sh --check' _ "$TEST_REPO"

  [ "$status" -eq 0 ]
  [[ "$output" == *'actualización disponible'* ]]
  [[ "$output" == *'v1.2.0'* ]]
}
