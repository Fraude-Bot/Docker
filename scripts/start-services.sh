#!/usr/bin/env bash
set -euo pipefail

docker_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_root="$(cd "${docker_dir}/../backend" && pwd)"
frontend_root="$(cd "${docker_dir}/../frontend" && pwd)"

choose() {
  local title="$1"
  shift
  local options=("$@")
  local choice

  if ((${#options[@]} == 1)); then
    printf '%s\n' "${options[0]}"
    return
  fi

  echo "${title}" >&2
  select choice in "${options[@]}"; do
    if [[ -n "${choice:-}" ]]; then
      printf '%s\n' "${choice}"
      return
    fi
    echo "Invalid selection." >&2
  done
}

# .env is gitignored, so a new worktree does not have one. Copy the docker-ready
# file from main (or another worktree) so DB/Redis hostnames match Compose.
# storage/ and bootstrap/cache stay mode 755 from git. When the container user
# is root, php-fpm workers run as www-data and cannot create storage/logs/laravel.log.
# A previous root container can also leave cache files owned by root. chmod then
# fails with "cannot access ... Permission denied" and aborts startup, so reclaim
# those paths before widening permissions.
prepare_backend() {
  local dir="$1"
  local source=""
  local candidate

  if [[ ! -f "${dir}/.env" ]]; then
    if [[ -f "${backend_root}/main/.env" && "${dir}" != "${backend_root}/main" ]]; then
      source="${backend_root}/main/.env"
    else
      for candidate in "${backend_root}"/*/.env; do
        [[ -f "${candidate}" ]] || continue
        [[ "${candidate}" == "${dir}/.env" ]] && continue
        source="${candidate}"
        break
      done
    fi

    if [[ -n "${source}" ]]; then
      cp "${source}" "${dir}/.env"
      echo "Copied .env from ${source}"
    elif [[ -f "${dir}/.env.example" ]]; then
      cp "${dir}/.env.example" "${dir}/.env"
      echo "Copied .env from ${dir}/.env.example"
    else
      echo "No .env found for ${dir}, and nothing to copy." >&2
      exit 1
    fi
  fi

  mkdir -p \
    "${dir}/storage/app/private" \
    "${dir}/storage/app/public" \
    "${dir}/storage/framework/cache/data" \
    "${dir}/storage/framework/sessions" \
    "${dir}/storage/framework/views" \
    "${dir}/storage/logs" \
    "${dir}/bootstrap/cache"

  if ! chmod -R a+rwx "${dir}/storage" "${dir}/bootstrap/cache" 2>/dev/null; then
    echo "Reclaiming files in ${dir}/storage and ${dir}/bootstrap/cache not owned by $(id -un)."
    docker run --rm --user 0:0 --entrypoint chown \
      -v "${dir}/storage:/storage" \
      -v "${dir}/bootstrap/cache:/cache" \
      nginx:alpine \
      -R "$(id -u):$(id -g)" /storage /cache
    chmod -R a+rwx "${dir}/storage" "${dir}/bootstrap/cache"
  fi
  echo "Made ${dir}/storage and ${dir}/bootstrap/cache writable."
}

mapfile -t backend_worktrees < <(
  find "${backend_root}" -mindepth 1 -maxdepth 1 -type d \
    -exec test -f '{}/artisan' ';' \
    -printf '%f\n' | sort
)

if ((${#backend_worktrees[@]} == 0)); then
  echo "No Laravel worktrees found in ${backend_root} (expected a folder with artisan)." >&2
  exit 1
fi

mapfile -t frontend_worktrees < <(
  find "${frontend_root}" -mindepth 1 -maxdepth 1 -type d \
    -exec test -f '{}/package.json' ';' \
    -printf '%f\n' | sort
)

if ((${#frontend_worktrees[@]} == 0)); then
  echo "No frontend worktrees found in ${frontend_root} (expected a folder with package.json)." >&2
  exit 1
fi

backend_choice="$(choose "Select a backend worktree:" "${backend_worktrees[@]}")"
frontend_choice="$(choose "Select a frontend worktree:" "${frontend_worktrees[@]}")"

export FRAUDEBOT_UID="$(id -u)"
export FRAUDEBOT_GID="$(id -g)"
export FRAUDEBOT_BACKEND_DIR="${backend_root}/${backend_choice}"
export FRAUDEBOT_FRONTEND_DIR="${frontend_root}/${frontend_choice}"
export FRAUDEBOT_FRONTEND_SLUG="${frontend_choice}"

prepare_backend "${FRAUDEBOT_BACKEND_DIR}"

echo "Starting services with backend: ${FRAUDEBOT_BACKEND_DIR}"
echo "Starting services with frontend: ${FRAUDEBOT_FRONTEND_DIR}"
cd "${docker_dir}"
exec docker compose up -d --build
