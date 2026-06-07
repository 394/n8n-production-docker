#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

backup_dir="${1:-}"
if [[ -z "${backup_dir}" || ! -d "${backup_dir}" ]]; then
  echo "Usage: scripts/restore.sh backups/YYYYMMDDTHHMMSSZ" >&2
  exit 1
fi

if [[ ! -f "${backup_dir}/postgres.dump" || ! -f "${backup_dir}/n8n_data.tar.gz" || ! -f "${backup_dir}/env.snapshot" ]]; then
  echo "Backup is missing postgres.dump, n8n_data.tar.gz, or env.snapshot." >&2
  exit 1
fi

project_name="$(grep -E '^COMPOSE_PROJECT_NAME=' "${backup_dir}/env.snapshot" | cut -d= -f2- || true)"
project_name="${project_name:-n8n}"

echo "This will stop containers and replace local .env, PostgreSQL data, and n8n data volume."
read -r -p "Type RESTORE to continue: " confirmation
if [[ "${confirmation}" != "RESTORE" ]]; then
  echo "Restore cancelled."
  exit 1
fi

docker compose down
cp "${backup_dir}/env.snapshot" .env
chmod 600 .env
set -a
# shellcheck disable=SC1091
source .env
set +a

docker volume rm "${project_name}_n8n_data" "${project_name}_postgres_data" "${project_name}_redis_data" >/dev/null 2>&1 || true
docker compose up -d postgres

echo "Waiting for PostgreSQL..."
postgres_ready=false
for _ in {1..30}; do
  if docker compose exec -T postgres pg_isready -U "${POSTGRES_USER:-n8n}" -d "${POSTGRES_DB:-n8n}" >/dev/null 2>&1; then
    postgres_ready=true
    break
  fi
  sleep 2
done

if [[ "${postgres_ready}" != "true" ]]; then
  echo "PostgreSQL did not become ready; aborting restore before pg_restore." >&2
  docker compose logs --tail=80 postgres >&2 || true
  exit 1
fi

docker compose cp "${backup_dir}/postgres.dump" postgres:/tmp/postgres.dump
docker compose exec -T postgres pg_restore \
  --clean \
  --if-exists \
  --no-owner \
  --username="${POSTGRES_USER:-n8n}" \
  --dbname="${POSTGRES_DB:-n8n}" \
  /tmp/postgres.dump
docker compose exec -T postgres rm -f /tmp/postgres.dump

docker run --rm \
  -v "${project_name}_n8n_data:/data" \
  -v "${backup_dir}:/backup:ro" \
  alpine:3.20 \
  sh -ec "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true; tar -xzf /backup/n8n_data.tar.gz -C /data"

if [[ -f "${backup_dir}/local_files.tar.gz" ]]; then
  rm -rf local-files
  tar -xzf "${backup_dir}/local_files.tar.gz" -C "${ROOT_DIR}"
fi

docker compose up -d
echo "Restore complete. Check n8n with: docker compose logs -f n8n"
