#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${ROOT_DIR}/backups/update.log"
CRON_LINE="17 3 * * * cd ${ROOT_DIR} && ${ROOT_DIR}/scripts/update-n8n.sh >> ${LOG_FILE} 2>&1"

mkdir -p "${ROOT_DIR}/backups"

existing="$(crontab -l 2>/dev/null || true)"
if grep -Fq "${ROOT_DIR}/scripts/update-n8n.sh" <<< "${existing}"; then
  echo "An n8n auto-update cron entry already exists."
  exit 0
fi

{
  printf '%s\n' "${existing}"
  printf '%s\n' "${CRON_LINE}"
} | crontab -

echo "Installed daily n8n auto-update check at 03:17 server time."
