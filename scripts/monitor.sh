#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

min_free_disk_mb="${MONITOR_MIN_FREE_DISK_MB:-10240}"
backup_max_age_hours="${MONITOR_BACKUP_MAX_AGE_HOURS:-26}"
update_log_max_age_hours="${MONITOR_UPDATE_LOG_MAX_AGE_HOURS:-26}"
failed=false

fail() {
  echo "FAIL: $*" >&2
  failed=true
}

ok() {
  echo "OK: $*"
}

if docker compose exec -T n8n node -e "fetch('http://127.0.0.1:5678/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
  ok "n8n health endpoint is responding"
else
  fail "n8n health endpoint is not responding"
fi

free_disk_mb="$(df -Pm "${ROOT_DIR}" | awk 'NR==2 {print $4}')"
if (( free_disk_mb >= min_free_disk_mb )); then
  ok "${free_disk_mb} MB free disk at ${ROOT_DIR}"
else
  fail "only ${free_disk_mb} MB free disk at ${ROOT_DIR}; threshold is ${min_free_disk_mb} MB"
fi

latest_backup="$(find "${ROOT_DIR}/backups" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}')"
if [[ -z "${latest_backup}" ]]; then
  fail "no timestamped backup directory found"
else
  latest_backup_age_hours="$(( ( $(date +%s) - $(stat -c %Y "${latest_backup}") ) / 3600 ))"
  if (( latest_backup_age_hours <= backup_max_age_hours )); then
    ok "latest backup is ${latest_backup_age_hours} hours old"
  else
    fail "latest backup is ${latest_backup_age_hours} hours old; threshold is ${backup_max_age_hours} hours"
  fi
fi

if [[ -f "${ROOT_DIR}/backups/update.log" ]]; then
  update_log_age_hours="$(( ( $(date +%s) - $(stat -c %Y "${ROOT_DIR}/backups/update.log") ) / 3600 ))"
  if (( update_log_age_hours <= update_log_max_age_hours )); then
    ok "update log is ${update_log_age_hours} hours old"
  else
    fail "update log is ${update_log_age_hours} hours old; threshold is ${update_log_max_age_hours} hours"
  fi

  if tail -n 200 "${ROOT_DIR}/backups/update.log" | grep -Eiq 'failed|rollback failed|fatal|error'; then
    fail "recent update log contains failure indicators"
  else
    ok "recent update log has no failure indicators"
  fi
else
  fail "missing backups/update.log; install the update cron or run scripts/update-n8n.sh"
fi

for service in n8n n8n-worker-1 n8n-worker-2 task-runner-worker-1 task-runner-worker-2 postgres redis; do
  container_id="$(docker compose ps -q "${service}" 2>/dev/null || true)"
  if [[ -z "${container_id}" ]]; then
    fail "${service} container is missing"
    continue
  fi

  restart_count="$(docker inspect --format '{{.RestartCount}}' "${container_id}" 2>/dev/null || echo 0)"
  if (( restart_count > 0 )); then
    fail "${service} has restarted ${restart_count} time(s)"
  else
    ok "${service} has no recorded restarts"
  fi
done

if [[ "${failed}" == "true" ]]; then
  exit 1
fi

echo "Monitoring checks passed."
