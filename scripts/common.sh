# Shared by start-services.sh and start-backend.sh.

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
# A previous root container can also leave cache files owned by root. A new
# worktree can leave vendor/ owned by root as well. chmod then fails with
# "cannot access ... Permission denied" and aborts startup, so reclaim those
# paths before widening permissions.
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

  ensure_writable "${dir}/storage" "${dir}/bootstrap/cache"
  echo "Made ${dir}/storage and ${dir}/bootstrap/cache writable."

  if [[ -d "${dir}/vendor" ]]; then
    ensure_writable "${dir}/vendor"
    echo "Made ${dir}/vendor writable."
  fi
}

# vendor/ is a bind mount, so the image never contains installed packages.
# A new worktree has no vendor/ until this runs. `up -d` returns as soon as
# the container process has started, which on a first start can be before
# `exec` is accepted, so wait for the container and then install.
install_backend_dependencies() {
  local attempt

  for attempt in $(seq 1 60); do
    if docker compose exec -T backend true >/dev/null 2>&1; then
      break
    fi
    if ((attempt == 1)); then
      echo "Waiting for the backend container..."
    fi
    if ((attempt == 60)); then
      echo "Backend container is not running, so Composer was not executed." >&2
      exit 1
    fi
    sleep 1
  done

  echo "Running composer install..."
  docker compose exec -T -w /var/www/backend backend \
    composer install --no-interaction --prefer-dist

  echo "Running composer dump-autoload..."
  docker compose exec -T -w /var/www/backend backend \
    composer dump-autoload
}

# chmod -R a+rwx fails when a path is owned by root. Take ownership, then retry.
ensure_writable() {
  local path
  local index=0
  local -a paths=()
  local -a mounts=()
  local -a targets=()

  for path in "$@"; do
    [[ -e "${path}" ]] || continue
    paths+=("${path}")
  done

  if ((${#paths[@]} == 0)); then
    return 0
  fi

  if chmod -R a+rwx "${paths[@]}" 2>/dev/null; then
    return 0
  fi

  echo "Reclaiming files not owned by $(id -un): ${paths[*]}"
  for path in "${paths[@]}"; do
    mounts+=(-v "${path}:/reclaim/${index}")
    targets+=("/reclaim/${index}")
    index=$((index + 1))
  done

  docker run --rm --user 0:0 --entrypoint chown \
    "${mounts[@]}" \
    nginx:alpine \
    -R "$(id -u):$(id -g)" "${targets[@]}"
  chmod -R a+rwx "${paths[@]}"
}

list_worktrees() {
  local root="$1"
  local marker="$2"

  find "${root}" -mindepth 1 -maxdepth 1 -type d \
    -exec test -f "{}/${marker}" ';' \
    -printf '%f\n' | sort
}

# FRAUDEBOT_BACKEND_WORKTREE skips the prompt when a caller already chose.
select_backend_worktree() {
  local -a backend_worktrees=()
  local choice candidate found

  mapfile -t backend_worktrees < <(list_worktrees "${backend_root}" artisan)

  if ((${#backend_worktrees[@]} == 0)); then
    echo "No Laravel worktrees found in ${backend_root} (expected a folder with artisan)." >&2
    exit 1
  fi

  choice="${FRAUDEBOT_BACKEND_WORKTREE:-}"
  if [[ -n "${choice}" ]]; then
    found=0
    for candidate in "${backend_worktrees[@]}"; do
      if [[ "${candidate}" == "${choice}" ]]; then
        found=1
        break
      fi
    done
    if ((found == 0)); then
      echo "Unknown backend worktree: ${choice}" >&2
      echo "Expected one of: ${backend_worktrees[*]}" >&2
      exit 1
    fi
    printf '%s\n' "${choice}"
    return
  fi

  choose "Select a backend worktree:" "${backend_worktrees[@]}"
}

ask_port() {
  local port=""

  if [[ -n "${1:-}" ]]; then
    port="$1"
  else
    read -r -p "Port for the backend [9000]: " port
    port="${port:-9000}"
  fi

  if [[ ! "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    echo "Port must be a number from 1 to 65535." >&2
    exit 1
  fi

  printf '%s\n' "${port}"
}
