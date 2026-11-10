#!/usr/bin/env bats

@test "MANIFEST includes every tracked test and distributable file" {
  local project_root path missing=0
  project_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  run git -C "$project_root" ls-files -- tests/ once.sh update.sh lib/ skills/ 'prompt_*.md'
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  while IFS= read -r path; do
    if ! grep -Fxq -- "$path" "$project_root/MANIFEST"; then
      printf 'Missing from MANIFEST: %s\n' "$path"
      missing=1
    fi
  done <<< "$output"
  [ "$missing" -eq 0 ]
}

@test "every MANIFEST path exists as a regular file" {
  local project_root path missing=0
  project_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  while IFS= read -r path || [ -n "$path" ]; do
    case "$path" in ''|'#'*) continue ;; esac
    if [ ! -f "$project_root/$path" ]; then
      printf 'Missing MANIFEST file: %s\n' "$path"
      missing=1
    fi
  done < "$project_root/MANIFEST"
  [ "$missing" -eq 0 ]
}
