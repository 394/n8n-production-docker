#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "Missing .env. Run scripts/bootstrap.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

force_update=false
if [[ "${1:-}" == "--force" ]]; then
  force_update=true
fi

if [[ "${force_update}" != "true" && "${N8N_AUTO_UPDATE:-false}" != "true" ]]; then
  echo "Unattended updates are disabled. Set N8N_AUTO_UPDATE=true or run: scripts/update-n8n.sh --force" >&2
  exit 1
fi

require_container() {
  local service="$1"
  local id
  id="$(docker compose ps -q "${service}" || true)"
  if [[ -z "${id}" ]]; then
    echo "Service ${service} is not running. Start the stack before updating." >&2
    exit 1
  fi
  printf '%s\n' "${id}"
}

wait_for_n8n() {
  local attempts=30
  local i
  for ((i = 1; i <= attempts; i++)); do
    if docker compose exec -T n8n node -e "fetch('http://127.0.0.1:5678/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_for_running() {
  local service="$1"
  local id status
  local attempts=12
  local i
  for ((i = 1; i <= attempts; i++)); do
    id="$(docker compose ps -q "${service}" || true)"
    status=""
    if [[ -n "${id}" ]]; then
      status="$(docker inspect --format '{{.State.Status}}' "${id}" 2>/dev/null || true)"
    fi
    if [[ "${status}" == "running" ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

n8n_container_id="$(require_container n8n)"
runner_container_id="$(docker compose ps -q task-runners || true)"

running_n8n_image_id="$(docker inspect --format '{{.Image}}' "${n8n_container_id}")"
running_runner_image_id=""
if [[ -n "${runner_container_id}" ]]; then
  running_runner_image_id="$(docker inspect --format '{{.Image}}' "${runner_container_id}")"
fi

echo "Checking for newer n8n and task runner images..."
docker compose pull n8n task-runners

target_image_id="$(docker compose images -q n8n)"
target_runner_image_id="$(docker compose images -q task-runners)"
if [[ "${running_n8n_image_id}" == "${target_image_id}" && "${running_runner_image_id}" == "${target_runner_image_id}" ]]; then
  echo "n8n and task runners are already running the latest pulled images."
  exit 0
fi

echo "New image found. Creating backup before update..."
"${ROOT_DIR}/scripts/backup.sh"

echo "Starting updated n8n and task runner containers..."
docker compose up -d n8n task-runners

if ! wait_for_n8n; then
  echo "n8n did not become healthy after update. Check logs before continuing." >&2
  exit 1
fi

if ! wait_for_running task-runners; then
  echo "Task runner container did not stay running after update. Check logs before continuing." >&2
  exit 1
fi

docker image prune -f --filter "label=org.opencontainers.image.title=n8n" >/dev/null || true
echo "n8n update complete."
