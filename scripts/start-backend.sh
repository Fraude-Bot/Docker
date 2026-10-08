#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

backend_choice="$(select_backend_worktree)"
port="$(ask_port "${1:-}")"

export FRAUDEBOT_UID="$(id -u)"
export FRAUDEBOT_GID="$(id -g)"
export FRAUDEBOT_BACKEND_DIR="${backend_root}/${backend_choice}"
export FRAUDEBOT_BACKEND_PORT="${port}"

prepare_backend "${FRAUDEBOT_BACKEND_DIR}"

echo "Starting backend: ${FRAUDEBOT_BACKEND_DIR}"
echo "Listening on http://localhost:${port}"
cd "${docker_dir}"
docker compose up -d --build backend web
install_backend_dependencies
