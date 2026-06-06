#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

check_backup=false
if [[ "${1:-}" == "--backup" ]]; then
  check_backup=true
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

min_cpu_cores="${MIN_CPU_CORES:-2}"
min_memory_mb="${MIN_MEMORY_MB:-2048}"
min_free_disk_mb="${MIN_FREE_DISK_MB:-10240}"
min_backup_free_disk_mb="${MIN_BACKUP_FREE_DISK_MB:-20480}"

cpu_cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
memory_mb="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)"
free_disk_mb="$(df -Pm "${ROOT_DIR}" | awk 'NR==2 {print $4}')"
required_disk_mb="${min_free_disk_mb}"

if [[ "${check_backup}" == "true" ]]; then
  required_disk_mb="${min_backup_free_disk_mb}"
fi

failed=false

if (( cpu_cores < min_cpu_cores )); then
  echo "CPU check failed: ${cpu_cores} cores available, ${min_cpu_cores} required." >&2
  failed=true
fi

if (( memory_mb < min_memory_mb )); then
  echo "Memory check failed: ${memory_mb} MB available, ${min_memory_mb} MB required." >&2
  failed=true
fi

if (( free_disk_mb < required_disk_mb )); then
  echo "Disk check failed: ${free_disk_mb} MB free, ${required_disk_mb} MB required at ${ROOT_DIR}." >&2
  failed=true
fi

if [[ "${failed}" == "true" ]]; then
  echo "Preflight failed. Adjust .env thresholds or resize the host before continuing." >&2
  exit 1
fi

echo "Preflight ok: ${cpu_cores} CPU cores, ${memory_mb} MB RAM, ${free_disk_mb} MB free disk."
