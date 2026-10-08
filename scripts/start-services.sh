#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mapfile -t frontend_worktrees < <(list_worktrees "${frontend_root}" package.json)

if ((${#frontend_worktrees[@]} == 0)); then
  echo "No frontend worktrees found in ${frontend_root} (expected a folder with package.json)." >&2
  exit 1
fi

backend_choice="$(select_backend_worktree)"
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
docker compose up -d --build
install_backend_dependencies
