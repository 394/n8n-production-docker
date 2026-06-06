#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "Missing .env. Creating it first..."
  "${ROOT_DIR}/scripts/bootstrap.sh"
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

project_name="${COMPOSE_PROJECT_NAME:-n8n}"
n8n_volume="${project_name}_n8n_data"
postgres_volume="${project_name}_postgres_data"

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

check_n8n_encryption_key() {
  local config_key

  if ! volume_exists "${n8n_volume}"; then
    return 0
  fi

  config_key="$(
    docker run --rm -v "${n8n_volume}:/data:ro" alpine:3.20 \
      sh -ec "if [ -f /data/config ]; then sed -n 's/.*\"encryptionKey\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' /data/config; fi" 2>/dev/null || true
  )"

  if [[ -n "${config_key}" && "${config_key}" != "${N8N_ENCRYPTION_KEY}" ]]; then
    cat >&2 <<EOF
n8n data volume encryption key does not match .env.

This usually happens when .env was regenerated while ${n8n_volume} already existed.

For a fresh install, reset the n8n app-data volume:
  docker compose down --remove-orphans
  docker volume rm ${n8n_volume}
  scripts/start.sh

For an existing install, restore the old N8N_ENCRYPTION_KEY instead. Do not delete the volume if it contains real credentials.
EOF
    exit 1
  fi
}

check_postgres_password() {
  local postgres_ready=false

  if ! volume_exists "${postgres_volume}"; then
    return 0
  fi

  echo "Starting PostgreSQL first so database credentials can be checked..."
  docker compose up -d postgres

  echo "Checking PostgreSQL credentials..."
  for _ in {1..30}; do
    if docker compose exec -T postgres pg_isready -U "${POSTGRES_USER:-n8n}" -d "${POSTGRES_DB:-n8n}" >/dev/null 2>&1; then
      postgres_ready=true
      break
    fi
    sleep 2
  done

  if [[ "${postgres_ready}" != "true" ]]; then
    echo "PostgreSQL did not become ready. Inspect with: docker compose logs --tail=120 postgres" >&2
    exit 1
  fi

  if ! docker compose exec -T postgres env PGPASSWORD="${POSTGRES_PASSWORD}" \
    psql -U "${POSTGRES_USER:-n8n}" -d "${POSTGRES_DB:-n8n}" -c "select 1" >/dev/null 2>&1; then
    cat >&2 <<EOF
PostgreSQL rejected the password from .env.

This usually happens when .env was regenerated while ${postgres_volume} already existed.

For a fresh install, reset the database volume:
  docker compose down --remove-orphans
  docker volume rm ${postgres_volume}
  scripts/start.sh

For an existing install, restore the old POSTGRES_PASSWORD instead. Do not delete the volume if it contains real workflow data.
EOF
    exit 1
  fi
}

"${ROOT_DIR}/scripts/preflight.sh"
check_n8n_encryption_key
check_postgres_password
docker compose up -d
docker compose ps
