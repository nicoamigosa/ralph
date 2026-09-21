#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
TMP_ROOT="${TMPDIR:-/tmp}"
RELEASE_REPO="nicoamigosa/ralph"
LOCK_REF="${RALPH_LOCK_REF:-refs/ralph/lock}"

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

checksum_for_asset() {
  local sums_file="$1" asset="$2" hash name found=""
  while read -r hash name; do
    name="${name#\*}"
    name="${name#./}"
    if [ "$name" = "$asset" ]; then
      case "$hash" in
        ''|*[!0123456789abcdefABCDEF]*) return 1 ;;
      esac
      [ "${#hash}" -eq 64 ] || return 1
      [ -z "$found" ] || [ "$found" = "$hash" ] || return 1
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
  local version="$1" archive_file="$2" sums_file="$3"
  local asset base_url expected actual
  asset="ralph-v${version}.tar.gz"
  base_url="$(release_base_url "$version")"
  curl --fail --silent --show-error --location \
    --output "$archive_file" "$base_url/$asset" \
    || fail "No pude descargar la release v$version ($asset)."
  curl --fail --silent --show-error --location \
    --output "$sums_file" "$base_url/SHA256SUMS" \
    || fail "No pude descargar SHA256SUMS de la release v$version."
  expected="$(checksum_for_asset "$sums_file" "$asset")" \
    || fail "SHA256SUMS no contiene un checksum válido para $asset."
  actual="$(sha256_file "$archive_file")" \
    || fail "No encontré una herramienta SHA-256 (sha256sum o shasum)."
  actual="${actual,,}"
  expected="${expected,,}"
  [ "$actual" = "$expected" ] \
    || fail "Checksum SHA-256 incorrecto para $asset; no se aplicó ningún cambio."
}

archive_root_name() {
  local archive_file="$1" entry normalized top="" member_top listing
  listing="$(tar -tzf "$archive_file" 2>/dev/null)" \
    || fail "El tarball de la release no se pudo listar."
  [ -n "$listing" ] || fail "El tarball de la release está vacío."
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
  [ -n "$top" ] || fail "El tarball de la release está vacío."
  printf '%s\n' "$top"
}

extract_release() {
  local archive_file="$1" extract_dir="$2" root_name
  root_name="$(archive_root_name "$archive_file")"
  mkdir -p "$extract_dir"
  tar -xzf "$archive_file" -C "$extract_dir" \
    || fail "No pude extraer el tarball de la release."
  local symlink
  symlink="$(find "$extract_dir" -type l -print -quit 2>/dev/null)" \
    || fail "No pude verificar los enlaces del tarball de la release."
  [ -z "$symlink" ] || fail "El tarball contiene un enlace simbólico: ${symlink#"$extract_dir"/}."
  [ -d "$extract_dir/$root_name" ] \
    || fail "El tarball no contiene el directorio de release esperado."
  printf '%s\n' "$extract_dir/$root_name"
}

read_version() {
  local version_file="$1" version
  [ -f "$version_file" ] || return 1
  IFS= read -r version < "$version_file" || true
  version="${version%$'\r'}"
  valid_version "$version" || return 1
  printf '%s\n' "$version"
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

manifest_paths() {
  local manifest_file="$1" path
  while IFS= read -r path || [ -n "$path" ]; do
    path="${path%$'\r'}"
    case "$path" in
      ''|'#'*) continue ;;
      *) printf '%s\n' "$path" ;;
    esac
  done < "$manifest_file"
}

check_package() {
  local package_root="$1" expected_version="$2" package_version path
  validate_manifest "$package_root/MANIFEST"
  manifest_contains "$package_root/MANIFEST" MANIFEST \
    || fail "MANIFEST debe incluirse a sí mismo en la distribución."
  manifest_contains "$package_root/MANIFEST" VERSION \
    || fail "MANIFEST debe incluir VERSION en la distribución."
  package_version="$(read_version "$package_root/VERSION")" \
    || fail "La release no contiene una VERSION válida."
  [ "$package_version" = "$expected_version" ] \
    || fail "La VERSION del tarball ($package_version) no coincide con v$expected_version."
  while IFS= read -r path; do
    if [ ! -f "$package_root/$path" ] || [ -L "$package_root/$path" ]; then
      fail "MANIFEST referencia un archivo no regular o ausente: $path."
    fi
  done < <(manifest_paths "$package_root/MANIFEST")
}

check_remote_lock() {
  local remote_lock
  remote_lock="$(git -C "$PROJECT_ROOT" ls-remote origin "$LOCK_REF" 2>/dev/null)" \
    || fail "No pude consultar el lock remoto '$LOCK_REF'; no se actualiza."
  [ -z "$remote_lock" ] \
    || fail "Hay una corrida de ralph en curso (lock remoto: $LOCK_REF)."
}

check_local_files() {
  local package_root="$1" path local_file expected_file
  local -a divergent=()
  if has_symlink_component MANIFEST || ! cmp -s "$SCRIPT_DIR/MANIFEST" "$package_root/MANIFEST"; then
    divergent+=(MANIFEST)
  fi
  while IFS= read -r path; do
    local_file="$SCRIPT_DIR/$path"
    expected_file="$package_root/$path"
    if has_symlink_component "$path" || [ ! -f "$local_file" ] || [ -L "$local_file" ] || \
       ! cmp -s "$local_file" "$expected_file"; then
      divergent+=("$path")
    fi
  done < <(manifest_paths "$package_root/MANIFEST")
  if [ "${#divergent[@]}" -gt 0 ]; then
    printf '❌ Hay modificaciones locales en archivos comunes; no se aplicó la actualización:\n' >&2
    printf '   %s\n' "${divergent[@]}" >&2
    exit 1
  fi
}

has_symlink_component() {
  local path="$1" component candidate="$SCRIPT_DIR"
  local -a components=()
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [ -n "$component" ] || continue
    candidate="$candidate/$component"
    [ ! -L "$candidate" ] || return 0
  done
  return 1
}

apply_package() {
  local package_root="$1" path destination
  while IFS= read -r path; do
    destination="$SCRIPT_DIR/$path"
    has_symlink_component "$path" && \
      fail "No se puede reemplazar un archivo bajo un enlace simbólico: $path."
    mkdir -p "$(dirname "$destination")"
    cp -p "$package_root/$path" "$destination" \
      || fail "No pude reemplazar el archivo distribuido: $path."
  done < <(manifest_paths "$package_root/MANIFEST")
}

[ "$#" -eq 1 ] || fail "Uso: $0 <VERSION>"
TARGET_VERSION="$1"
valid_version "$TARGET_VERSION" || fail "VERSION inválida: $TARGET_VERSION."

INSTALLED_VERSION="$(read_version "$SCRIPT_DIR/VERSION")" \
  || fail "No encontré una VERSION instalada válida en $SCRIPT_DIR."
[ -f "$SCRIPT_DIR/MANIFEST" ] || fail "No encontré MANIFEST en $SCRIPT_DIR."
check_remote_lock

WORK_DIR="$(mktemp -d "$TMP_ROOT/ralph-update.XXXXXX")" \
  || fail "No pude crear el temporal para la actualización."
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

target_archive="$WORK_DIR/target.tar.gz"
target_sums="$WORK_DIR/target.SHA256SUMS"
download_release "$TARGET_VERSION" "$target_archive" "$target_sums"
target_root="$(extract_release "$target_archive" "$WORK_DIR/target")"
check_package "$target_root" "$TARGET_VERSION"

if [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
  current_root="$target_root"
else
  current_archive="$WORK_DIR/current.tar.gz"
  current_sums="$WORK_DIR/current.SHA256SUMS"
  download_release "$INSTALLED_VERSION" "$current_archive" "$current_sums"
  current_root="$(extract_release "$current_archive" "$WORK_DIR/current")"
  check_package "$current_root" "$INSTALLED_VERSION"
fi

check_local_files "$current_root"
apply_package "$target_root"
printf '✅ Ralph actualizado a v%s.\n' "$TARGET_VERSION"
