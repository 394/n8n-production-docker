#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "Missing .env. Run scripts/bootstrap.sh first." >&2
  exit 1
fi

"${ROOT_DIR}/scripts/preflight.sh"
docker compose up -d
docker compose ps
