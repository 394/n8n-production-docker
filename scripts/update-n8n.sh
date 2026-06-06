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
check_only=false
security_update=false

for arg in "$@"; do
  case "${arg}" in
    --check)
      check_only=true
      ;;
    --force)
      force_update=true
      ;;
    --security)
      force_update=true
      security_update=true
      ;;
    -h|--help)
      cat <<'USAGE'
Usage:
  scripts/update-n8n.sh --check       Pull images and report whether an update exists. Does not restart n8n.
  scripts/update-n8n.sh --force       Backup, update, and health-check n8n.
  scripts/update-n8n.sh --security    Urgent security update path for known RCE/high-critical advisories.

Unattended cron updates require N8N_AUTO_UPDATE=true.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

if [[ "${check_only}" == "true" ]]; then
  "${ROOT_DIR}/scripts/preflight.sh"
else
  "${ROOT_DIR}/scripts/preflight.sh" --backup
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

container_status() {
  local service="$1"
  local id status
  id="$(docker compose ps -q "${service}" || true)"
  if [[ -z "${id}" ]]; then
    echo "missing"
    return
  fi
  status="$(docker inspect --format '{{.State.Status}}' "${id}" 2>/dev/null || true)"
  echo "${status:-unknown}"
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

check_n8n_health() {
  docker compose exec -T n8n node -e "fetch('http://127.0.0.1:5678/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1
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

check_security_advisories() {
  if [[ "${N8N_UPDATE_SECURITY_ADVISORY_CHECK:-true}" != "true" ]]; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "Security advisory check skipped: curl is not installed." >&2
    return 0
  fi

  echo "Checking n8n GitHub security advisories for high/critical RCE indicators..."
  advisories="$(curl -fsSL --max-time 15 "https://api.github.com/repos/n8n-io/n8n/security-advisories?per_page=20" 2>/dev/null || true)"
  if [[ -z "${advisories}" ]]; then
    echo "Security advisory check unavailable. Check https://github.com/n8n-io/n8n/security/advisories manually." >&2
    return 0
  fi

  if printf '%s\n' "${advisories}" | grep -Eiq '"severity"[[:space:]]*:[[:space:]]*"(critical|high)"|remote code execution|RCE|sandbox escape'; then
    echo "Security advisory signal found. Review n8n advisories before delaying this update:"
    echo "https://github.com/n8n-io/n8n/security/advisories"
    if [[ "${security_update}" != "true" && "${N8N_SECURITY_UPDATE_OVERRIDE:-false}" != "true" ]]; then
      echo "Use scripts/update-n8n.sh --security for an urgent security patch after reviewing advisories." >&2
    fi
  else
    echo "No high/critical/RCE advisory signal found in the latest public n8n advisories."
  fi
}

scan_recent_logs() {
  if [[ "${N8N_UPDATE_LOG_ERROR_SCAN:-true}" != "true" ]]; then
    return 0
  fi

  if docker compose logs --since 3m n8n task-runners 2>/dev/null | grep -Eiq 'fatal|panic|uncaught|migration.*failed|database.*error|out of memory|heap out of memory|permission denied|auth.*failed|connection refused'; then
    echo "Recent logs contain crash/error indicators. Inspect with: docker compose logs --since 10m n8n task-runners" >&2
    return 1
  fi
}

n8n_container_id="$(require_container n8n)"
runner_container_id="$(docker compose ps -q task-runners || true)"

pre_update_status="$(container_status n8n)"
if [[ "${pre_update_status}" != "running" ]]; then
  echo "n8n is not running before update; status=${pre_update_status}. Aborting." >&2
  exit 1
fi

if ! check_n8n_health; then
  if [[ "${security_update}" == "true" || "${N8N_SECURITY_UPDATE_OVERRIDE:-false}" == "true" ]]; then
    echo "n8n health check failed before update, but security override is enabled. Continuing with backup and update." >&2
  else
    echo "n8n is unhealthy before update. Fix the current instance first, or use --security for an urgent security patch." >&2
    exit 1
  fi
fi

running_n8n_image_id="$(docker inspect --format '{{.Image}}' "${n8n_container_id}")"
running_runner_image_id=""
if [[ -n "${runner_container_id}" ]]; then
  running_runner_image_id="$(docker inspect --format '{{.Image}}' "${runner_container_id}")"
fi

check_security_advisories

echo "Checking for newer n8n and task runner images..."
docker compose pull n8n task-runners

target_image_id="$(docker compose images -q n8n)"
target_runner_image_id="$(docker compose images -q task-runners)"
if [[ "${running_n8n_image_id}" == "${target_image_id}" && "${running_runner_image_id}" == "${target_runner_image_id}" ]]; then
  echo "n8n and task runners are already running the latest pulled images."
  exit 0
fi

echo "Update available:"
echo "  n8n image: ${running_n8n_image_id} -> ${target_image_id}"
echo "  runner image: ${running_runner_image_id:-not-running} -> ${target_runner_image_id}"

if [[ "${check_only}" == "true" ]]; then
  echo "Check complete. No containers were restarted. Install with: scripts/update-n8n.sh --force"
  exit 0
fi

if [[ "${force_update}" != "true" && "${N8N_AUTO_UPDATE:-false}" != "true" ]]; then
  echo "Unattended updates are disabled. Set N8N_AUTO_UPDATE=true or run: scripts/update-n8n.sh --force" >&2
  exit 1
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

if ! scan_recent_logs; then
  exit 1
fi

docker image prune -f --filter "label=org.opencontainers.image.title=n8n" >/dev/null || true
echo "n8n update complete."
