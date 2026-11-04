#!/usr/bin/env bash
# Shared trusted configuration loader; callers provide REPO_ROOT and fail().
declare -A EXPLICIT_RALPH_ENV=()
declare -a EXPLICIT_RALPH_NAMES=()
EXPLICIT_HOST_CONFIG=0
while IFS= read -r env_name; do
  case "$env_name" in
    RALPH_*)
      EXPLICIT_RALPH_NAMES+=("$env_name")
      EXPLICIT_RALPH_ENV["$env_name"]="${!env_name}"
      [ "$env_name" = RALPH_HOST_CONFIG ] && EXPLICIT_HOST_CONFIG=1
      ;;
  esac
done < <(compgen -e)

restore_explicit_ralph_env() {
  local env_name
  for env_name in "${EXPLICIT_RALPH_NAMES[@]}"; do
    printf -v "$env_name" '%s' "${EXPLICIT_RALPH_ENV[$env_name]}"
    declare -gx "$env_name"
  done
}

load_env_file() {
  local env_file="$1" required="${2:-0}"
  if [ -e "$env_file" ] && [ ! -f "$env_file" ]; then
    fail "La configuración '$env_file' debe ser un archivo regular."
  fi
  if [ -f "$env_file" ]; then
    # Los archivos .env son código shell de confianza, no datos parseados.
    # shellcheck disable=SC1090
    if ! source "$env_file"; then
      fail "No pude cargar la configuración '$env_file'."
    fi
  elif [ "$required" -eq 1 ]; then
    fail "No existe la configuración requerida '$env_file'."
  fi
}

load_env_file "$REPO_ROOT/.ralph/config.env"
restore_explicit_ralph_env
HOST_CONFIG_PATH="${RALPH_HOST_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph/host.env}"
load_env_file "$HOST_CONFIG_PATH" "$EXPLICIT_HOST_CONFIG"
restore_explicit_ralph_env

