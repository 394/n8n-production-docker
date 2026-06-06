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

"${ROOT_DIR}/scripts/preflight.sh" --backup

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${ROOT_DIR}/backups/${timestamp}"
project_name="${COMPOSE_PROJECT_NAME:-n8n}"

mkdir -p "${backup_dir}"
chmod 700 "${backup_dir}"

echo "Backing up PostgreSQL database..."
docker compose exec -T postgres pg_dump \
  --username="${POSTGRES_USER}" \
  --dbname="${POSTGRES_DB}" \
  --format=custom \
  --file="/tmp/n8n-${timestamp}.dump"
docker compose cp "postgres:/tmp/n8n-${timestamp}.dump" "${backup_dir}/postgres.dump"
docker compose exec -T postgres rm -f "/tmp/n8n-${timestamp}.dump"

echo "Backing up n8n data volume..."
docker run --rm \
  -v "${project_name}_n8n_data:/data:ro" \
  -v "${backup_dir}:/backup" \
  alpine:3.20 \
  tar -czf /backup/n8n_data.tar.gz -C /data .

echo "Backing up local files..."
tar -czf "${backup_dir}/local_files.tar.gz" -C "${ROOT_DIR}" local-files

cp .env "${backup_dir}/env.snapshot"
chmod 600 "${backup_dir}/env.snapshot"
echo "Backup written to ${backup_dir}"
