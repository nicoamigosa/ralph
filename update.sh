#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="${TMPDIR:-/tmp}"
RELEASE_REPO="nicoamigosa/ralph"
ASSET_PREFIX="ralph-v"
CHECK_FILE=""

valid_version() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

valid_sha256() {
  local value="$1"
  [ "${#value}" -eq 64 ] || return 1
  case "$value" in
    *[!0123456789abcdefABCDEF]*) return 1 ;;
    *) return 0 ;;
  esac
}

checksum_for_asset() {
  local sums_file="$1" asset="$2" hash name found=""
  while read -r hash name; do
    name="${name#\*}"
    name="${name#./}"
    if [ "$name" = "$asset" ] && valid_sha256 "$hash"; then
      if [ -n "$found" ] && [ "$found" != "$hash" ]; then
        return 1
      fi
      found="$hash"
    fi
  done < "$sums_file"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

release_base_url() {
  if [ -n "${RALPH_RELEASE_BASE_URL:-}" ]; then
    printf '%s\n' "$RALPH_RELEASE_BASE_URL"
  else
    printf 'https://github.com/%s/releases/download/v%s\n' "$RELEASE_REPO" "$1"
  fi
}

download_release() {
  local version="$1" archive_file="$2" sums_file="$3" base_url asset expected actual
  asset="${ASSET_PREFIX}${version}.tar.gz"
  base_url="$(release_base_url "$version")"
  curl --fail --silent --show-error --location \
    --output "$archive_file" "$base_url/$asset" \
    || fail "No pude descargar la release v$version ($asset)."
  curl --fail --silent --show-error --location \
    --output "$sums_file" "$base_url/SHA256SUMS" \
    || fail "No pude descargar SHA256SUMS de la release v$version."

  if ! expected="$(checksum_for_asset "$sums_file" "$asset")"; then
    fail "SHA256SUMS no contiene un checksum válido para $asset."
  fi
  if ! actual="$(sha256_file "$archive_file")"; then
    fail "No encontré una herramienta SHA-256 (sha256sum o shasum)."
  fi
  [ "$actual" = "$expected" ] || \
    fail "Checksum SHA-256 incorrecto para $asset; no se aplicó ningún cambio."
}

archive_root_name() {
  local archive_file="$1" listing entry top normalized member_top
  if ! listing="$(tar -tzf "$archive_file" 2>/dev/null)"; then
    fail "El tarball de la release no se pudo listar."
  fi
  [ -n "$listing" ] || fail "El tarball de la release está vacío."

  top=""
  while IFS= read -r entry; do
    normalized="${entry#./}"
    [ -n "$normalized" ] || continue
    case "$normalized" in
      /*|..|../*|*/../*|*/..) fail "El tarball contiene una ruta insegura: $entry." ;;
    esac
    member_top="${normalized%%/*}"
    if [ -z "$top" ]; then
      top="$member_top"
    elif [ "$member_top" != "$top" ]; then
      fail "El tarball contiene más de una raíz: $top y $member_top."
    fi
  done <<< "$listing"
  [ -n "$top" ] || fail "El tarball de la release no contiene archivos."
  printf '%s\n' "$top"
}

validate_manifest() {
  local manifest_file="$1" path
  declare -A seen=()
  [ -f "$manifest_file" ] || fail "Falta MANIFEST en el tarball de la release."
  while IFS= read -r path || [ -n "$path" ]; do
    path="${path%$'\r'}"
    case "$path" in
      ''|'#'*) continue ;;
      /*|..|../*|*/../*|*/..) fail "MANIFEST contiene una ruta insegura: $path." ;;
    esac
    [ -z "${seen[$path]+x}" ] || fail "MANIFEST contiene una entrada duplicada: $path."
    seen["$path"]=1
  done < "$manifest_file"
}

manifest_contains() {
  local manifest_file="$1" wanted="$2" path
  while IFS= read -r path || [ -n "$path" ]; do
    path="${path%$'\r'}"
    [ "$path" = "$wanted" ] && return 0
  done < "$manifest_file"
  return 1
}

read_version() {
  local version_file="$1" version
  [ -f "$version_file" ] || return 1
  IFS= read -r version < "$version_file" || true
  version="${version%$'\r'}"
  valid_version "$version" || return 1
  printf '%s\n' "$version"
}

extract_release() {
  local archive_file="$1" extract_dir="$2" root_name package_root
  root_name="$(archive_root_name "$archive_file")"
  mkdir -p "$extract_dir"
  tar -xzf "$archive_file" -C "$extract_dir" \
    || fail "No pude extraer el tarball de la release."
  package_root="$extract_dir/$root_name"
  [ -d "$package_root" ] || fail "El tarball no contiene el directorio de release esperado."
  printf '%s\n' "$package_root"
}

check_package_contract() {
  local package_root="$1" expected_version="$2" package_version path package_file
  validate_manifest "$package_root/MANIFEST"
  manifest_contains "$package_root/MANIFEST" MANIFEST \
    || fail "MANIFEST debe incluirse a sí mismo en la distribución."
  manifest_contains "$package_root/MANIFEST" VERSION \
    || fail "MANIFEST debe incluir VERSION en la distribución."
  if ! package_version="$(read_version "$package_root/VERSION")"; then
    fail "La release no contiene una VERSION válida."
  fi
  [ "$package_version" = "$expected_version" ] || \
    fail "La VERSION del tarball ($package_version) no coincide con v$expected_version."
  while IFS= read -r path || [ -n "$path" ]; do
    path="${path%$'\r'}"
    case "$path" in
      ''|'#'*) continue ;;
    esac
    package_file="$package_root/$path"
    if [ ! -f "$package_file" ] || [ -L "$package_file" ]; then
      fail "MANIFEST referencia un archivo no regular o ausente: $path."
    fi
  done < "$package_root/MANIFEST"
}

check_local_files() {
  local package_root="$1"
  local expected_manifest="$package_root/MANIFEST"
  local path local_file expected_file actual_expected actual_local
  local -a divergent=()

  if ! cmp -s "$SCRIPT_DIR/MANIFEST" "$expected_manifest"; then
    divergent+=(MANIFEST)
  fi
  while IFS= read -r path || [ -n "$path" ]; do
    path="${path%$'\r'}"
    case "$path" in
      ''|'#'*) continue ;;
    esac
    local_file="$SCRIPT_DIR/$path"
    expected_file="$package_root/$path"
    if [ ! -f "$local_file" ] || [ -L "$local_file" ] || \
       [ ! -f "$expected_file" ] || [ -L "$expected_file" ]; then
      divergent+=("$path")
      continue
    fi
    if ! actual_expected="$(sha256_file "$expected_file")" || \
       ! actual_local="$(sha256_file "$local_file")" || \
       [ "$actual_expected" != "$actual_local" ]; then
      divergent+=("$path")
    fi
  done < "$expected_manifest"

  if [ "${#divergent[@]}" -gt 0 ]; then
    printf '❌ Hay modificaciones locales en archivos comunes; no se aplicó la actualización:\n' >&2
    printf '   %s\n' "${divergent[@]}" >&2
    exit 1
  fi
}

apply_package() {
  local package_root="$1" path source destination
  while IFS= read -r path || [ -n "$path" ]; do
    path="${path%$'\r'}"
    case "$path" in
      ''|'#'*) continue ;;
    esac
    source="$package_root/$path"
    destination="$SCRIPT_DIR/$path"
    [ -f "$source" ] || fail "MANIFEST referencia un archivo ausente: $path."
    [ ! -L "$source" ] || fail "MANIFEST referencia un enlace simbólico: $path."
    mkdir -p "$(dirname "$destination")"
    cp -p "$source" "$destination" \
      || fail "No pude reemplazar el archivo distribuido: $path."
  done < "$package_root/MANIFEST"
}

check_latest_release() {
  local current_version api_url tag latest_version
  if ! current_version="$(read_version "$SCRIPT_DIR/VERSION")"; then
    fail "No encontré una VERSION instalada válida en $SCRIPT_DIR."
  fi
  command -v jq >/dev/null 2>&1 || fail "Falta 'jq' para consultar la última release."
  CHECK_FILE="$(mktemp "$TMP_ROOT/ralph-update-check.XXXXXX")" \
    || fail "No pude crear el temporal para consultar la release."
  trap 'rm -f "$CHECK_FILE"' EXIT
  api_url="${RALPH_RELEASE_API_URL:-https://api.github.com/repos/$RELEASE_REPO/releases/latest}"
  curl --fail --silent --show-error --location \
    --output "$CHECK_FILE" "$api_url" \
    || fail "consulta fallida: no pude consultar la última release estable."
  if ! tag="$(jq -er '.tag_name // empty' "$CHECK_FILE" 2>/dev/null)"; then
    fail "consulta fallida: la respuesta no contiene tag_name."
  fi
  case "$tag" in
    v*) latest_version="${tag#v}" ;;
    *) fail "La última release tiene un tag inesperado: $tag." ;;
  esac
  valid_version "$latest_version" || fail "La última release tiene una VERSION inválida: $latest_version."
  if [ "$current_version" = "$latest_version" ]; then
    printf '✅ actual: v%s.\n' "$current_version"
  else
    printf '⬆️  actualización disponible: v%s (instalada: v%s).\n' \
      "$latest_version" "$current_version"
  fi
}

[ "$#" -eq 1 ] || fail "Uso: $0 <VERSION>"
TARGET_VERSION="$1"
case "$TARGET_VERSION" in
  --check)
    check_latest_release
    exit 0
    ;;
  *)
    valid_version "$TARGET_VERSION" || fail "VERSION inválida: $TARGET_VERSION."
    ;;
esac

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$SCRIPT_DIR"
fi
LOCK_PATH="${RALPH_LOCK_PATH:-$PROJECT_ROOT/.ralph/lock}"
[ ! -e "$LOCK_PATH" ] || fail "Hay una corrida de ralph en curso (lock: $LOCK_PATH)."

if ! INSTALLED_VERSION="$(read_version "$SCRIPT_DIR/VERSION")"; then
  fail "No encontré una VERSION instalada válida en $SCRIPT_DIR."
fi
if [ ! -f "$SCRIPT_DIR/MANIFEST" ]; then
  fail "No encontré MANIFEST en $SCRIPT_DIR."
fi

WORK_DIR="$(mktemp -d "$TMP_ROOT/ralph-update.XXXXXX")" \
  || fail "No pude crear el temporal para la actualización."
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

target_archive="$WORK_DIR/target.tar.gz"
target_sums="$WORK_DIR/target.SHA256SUMS"
download_release "$TARGET_VERSION" "$target_archive" "$target_sums"
target_root="$(extract_release "$target_archive" "$WORK_DIR/target")"
check_package_contract "$target_root" "$TARGET_VERSION"

if [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
  current_root="$target_root"
else
  current_archive="$WORK_DIR/current.tar.gz"
  current_sums="$WORK_DIR/current.SHA256SUMS"
  download_release "$INSTALLED_VERSION" "$current_archive" "$current_sums"
  current_root="$(extract_release "$current_archive" "$WORK_DIR/current")"
  check_package_contract "$current_root" "$INSTALLED_VERSION"
fi

check_local_files "$current_root"
apply_package "$target_root"
printf '✅ Ralph actualizado a v%s.\n' "$TARGET_VERSION"
