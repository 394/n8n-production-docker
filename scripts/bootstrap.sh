#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required but was not found in PATH." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required but was not found." >&2
  exit 1
fi

cd "${ROOT_DIR}"
mkdir -p backups local-files

if [[ ! -f "${ENV_FILE}" ]]; then
  cp .env.example .env
  postgres_password="$(openssl rand -base64 36 | tr -d '\n' || true)"
  encryption_key="$(openssl rand -hex 32 | tr -d '\n' || true)"
  runners_auth_token="$(openssl rand -base64 36 | tr -d '\n' || true)"

  if [[ -n "${postgres_password}" && -n "${encryption_key}" && -n "${runners_auth_token}" ]]; then
    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${postgres_password}|" .env
    sed -i "s|N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${encryption_key}|" .env
    sed -i "s|N8N_RUNNERS_AUTH_TOKEN=.*|N8N_RUNNERS_AUTH_TOKEN=${runners_auth_token}|" .env
  else
    echo "Created .env, but could not generate secrets. Edit .env before starting." >&2
  fi

  echo "Created .env. Edit N8N_HOST, WEBHOOK_URL, N8N_EDITOR_BASE_URL, and timezone before production use."
else
  echo ".env already exists; leaving it unchanged."
fi

docker compose config >/dev/null
"${ROOT_DIR}/scripts/preflight.sh"
echo "Bootstrap complete. Start with: docker compose up -d"
