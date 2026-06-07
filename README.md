# Production n8n Docker Setup

This setup runs n8n in queue mode with PostgreSQL, Redis, two n8n workers, one external task-runner sidecar per worker, persistent Docker volumes, local file storage, health checks, and backup/restore scripts for a single-server SOC/SOAR production install.

## Quick start

```bash
chmod +x scripts/*.sh
scripts/start.sh
```

`scripts/start.sh` creates `.env` when missing, runs host preflight checks, detects common stale-volume secret mismatches, and then starts the stack.

If you run raw Docker Compose and `.env` does not exist, Compose starts a one-shot `init-env` service that creates it from `.env.example` with generated secrets, then stops before PostgreSQL or n8n start. Because Docker Compose reads `.env` before it starts services, review the generated `.env` and run Compose once more so the n8n and PostgreSQL containers use those generated values:

```bash
docker compose up -d
```

For the cleanest first production start, use the scripts:

```bash
scripts/bootstrap.sh
scripts/start.sh
```

Edit `.env` before production use:

- Set `N8N_HOST` to your domain.
- Set `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` to your public HTTPS URL.
- The default timezone is `Asia/Yangon`; change `GENERIC_TIMEZONE` and `TZ` only if needed.
- Keep `N8N_ENCRYPTION_KEY` unchanged after first start.
- Keep `N8N_RUNNERS_AUTH_TOKEN` secret. It is used by the external task-runner sidecar.
- Keep `N8N_IMAGE_TAG` pinned to a tested n8n version. External task runners do not publish a `stable` tag, and the n8n and task-runner images must use the same version tag.

Start n8n:

```bash
scripts/start.sh
docker compose logs -f n8n
```

If `.env` is regenerated while old Docker volumes still exist, n8n can fail with an encryption-key mismatch or PostgreSQL can reject the new password. `scripts/start.sh` checks for these cases and prints the exact volume reset command for fresh installs. For existing installs, restore the old `N8N_ENCRYPTION_KEY` or `POSTGRES_PASSWORD` instead of deleting volumes.

By default n8n binds to `127.0.0.1:3001`, which is suitable when using a reverse proxy for HTTPS. Change `N8N_BIND_ADDRESS=0.0.0.0` only if you intentionally want to expose the port directly.

## Host sizing and stability

This setup includes host preflight checks and container resource caps so a small VPS fails early instead of degrading unpredictably under load.

Default minimum host checks:

- `MIN_CPU_CORES=2`
- `MIN_MEMORY_MB=2048`
- `MIN_FREE_DISK_MB=10240`
- `MIN_BACKUP_FREE_DISK_MB=20480`

Default queue-mode container caps for an 8 CPU / 32 GB server:

- PostgreSQL: `POSTGRES_CPUS=1.5`, `POSTGRES_MEMORY=8g`
- Redis: `REDIS_CPUS=0.5`, `REDIS_MEMORY=2g`
- n8n main: `N8N_MAIN_CPUS=1.5`, `N8N_MAIN_MEMORY=4g`
- n8n workers: `N8N_WORKER_CPUS=2.0`, `N8N_WORKER_MEMORY=6g` each
- Task-runner sidecars: `N8N_RUNNERS_CPUS=0.5`, `N8N_RUNNERS_MEMORY=1g` each

This leaves RAM for the OS, filesystem cache, reverse proxy, monitoring, and security agents. For heavier workflows, increase worker memory first, then worker count/concurrency.

Run preflight checks manually:

```bash
scripts/preflight.sh
scripts/preflight.sh --backup
```

PostgreSQL memory knobs are exposed in `.env`:

- `POSTGRES_SHARED_BUFFERS`
- `POSTGRES_WORK_MEM`
- `POSTGRES_MAINTENANCE_WORK_MEM`
- `POSTGRES_MAX_CONNECTIONS`

Docker JSON logs are capped with `LOG_MAX_SIZE` and `LOG_MAX_FILES` to avoid log growth filling the disk.

Runtime containers set `no-new-privileges` to reduce container breakout blast radius. n8n main, n8n workers, and task-runner sidecars also drop Linux capabilities and get a bounded `/tmp` tmpfs for temporary writes. PostgreSQL keeps its default capabilities because the official image may need startup permissions while initializing or fixing ownership on the data volume. If you want to go stricter, test a Compose override with `read_only: true` for n8n services after confirming all nodes you use can write only to `/tmp`, `/home/node/.n8n`, and `/files`.

## Queue Mode

This deployment uses n8n queue mode for SOC/SOAR workloads that ingest alert bursts, enrich concurrently, call Elastic, and create notifications or tickets. The main `n8n` service handles the UI, API, schedules, and webhook intake. Redis stores pending execution jobs. `n8n-worker-1` and `n8n-worker-2` process workflow executions. `task-runner-worker-1` and `task-runner-worker-2` connect to their matching worker broker for external code/task execution isolation.

Important queue-mode settings in `.env`:

```bash
EXECUTIONS_MODE=queue
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
N8N_WORKER_CONCURRENCY=5
N8N_CONCURRENCY_PRODUCTION_LIMIT=20
QUEUE_BULL_REDIS_DB=0
QUEUE_HEALTH_CHECK_ACTIVE=true
```

Increase `N8N_WORKER_CONCURRENCY` cautiously. More concurrency can improve throughput, but it also increases concurrent Elastic/API calls and database load. For SOC workflows, prefer explicit retry/backoff and deduplication in workflows before raising concurrency aggressively.

This setup sets `N8N_DEFAULT_BINARY_DATA_MODE=database` for queue-mode compatibility and gives the main process and each worker a unique `N8N_EVENTBUS_LOGWRITER_LOGFULLPATH` because they share the n8n data volume. Do not switch to filesystem binary-data mode with queue mode. For very large binary workloads, move binary data to external object storage such as S3.

## Automatic updates

The update script pulls the configured n8n and task-runner images, compares them with the running containers, creates a backup, recreates the n8n main, workers, and task-runner sidecars, then waits for all n8n processes to become healthy.

Check for an available update without restarting n8n:

```bash
scripts/update-n8n.sh --check
```

Unattended updates are disabled by default. Enable them only after you have tested restore on this host:

```bash
N8N_AUTO_UPDATE=true
```

Install one update manually:

```bash
scripts/update-n8n.sh --force
```

Use the urgent security path only after reviewing an n8n advisory for a high/critical issue such as RCE or sandbox escape:

```bash
scripts/update-n8n.sh --security
```

The security path allows an update even if the current n8n health check is failing. It still runs preflight checks, creates a backup, waits for post-update health, and scans recent logs for crash indicators.

Check n8n security advisories manually:

```bash
scripts/security-check.sh
```

Install a daily cron job:

```bash
scripts/install-auto-update-cron.sh
```

Update logs are written to `backups/update.log`. If the post-update health check fails or recent logs contain crash/error indicators, the script rolls back to the pre-update images by default, exits non-zero, and leaves logs available for inspection.

The update and backup scripts run preflight checks before they start. Updates require the backup disk threshold because a backup is created before containers are recreated.

The update script will not restart n8n when:

- You run `scripts/update-n8n.sh --check`.
- No newer image is available.
- n8n main or any worker is unhealthy before a normal update.
- Host CPU, RAM, or disk preflight checks fail.
- `N8N_AUTO_UPDATE=false` and you did not pass `--force` or `--security`.

The update script will automatically roll back to the pre-update n8n and task-runner images when:

- n8n main or any worker does not become healthy again.
- A task-runner sidecar does not stay running.
- Recent n8n or task-runner logs include common crash indicators such as fatal errors, failed migrations, database errors, out-of-memory errors, or permission/authentication failures.

Rollback uses Docker tags created from the exact image IDs running before the update. Disable it only when you intentionally want to inspect the failed updated containers:

```bash
N8N_UPDATE_AUTO_ROLLBACK=false
```

Old rollback image tags are cleaned after successful updates. Tune or disable this with:

```bash
N8N_ROLLBACK_IMAGE_RETENTION_DAYS=14
N8N_ROLLBACK_IMAGE_RETENTION_DAYS=0
```

If rollback itself fails, restore from the backup created immediately before the update. This can happen when an updated n8n image ran a database migration that is not compatible with the previous image:

```bash
scripts/restore.sh backups/YYYYMMDDTHHMMSSZ
```

These checks reduce update risk, but they do not replace testing restore and checking n8n release notes before planned upgrades.

## Backups

Create a backup manually:

```bash
scripts/backup.sh
```

Backups are stored under `backups/YYYYMMDDTHHMMSSZ/` and include:

- `postgres.dump`
- `n8n_data.tar.gz`
- `local_files.tar.gz`
- `env.snapshot`

Redis queue state is not backed up. During restore, the Redis volume is cleared so stale queued jobs are not replayed against restored database state.

Backup directories are created with owner-only permissions because `env.snapshot` contains secrets. Store encrypted backup copies outside this server as part of your production operations.

Local backup retention defaults to 14 days:

```bash
BACKUP_RETENTION_DAYS=14
```

Set it to `0` to disable retention cleanup.

For offsite backups, configure an encrypted `rclone` remote, such as an `rclone crypt` remote backed by S3, Backblaze B2, or another storage provider, then set:

```bash
RCLONE_REMOTE=n8n-crypt:n8n-production
```

When `RCLONE_REMOTE` is set, `scripts/backup.sh` uploads each completed backup directory after the local archive files are written.

## Restore

Test restore before enabling unattended updates. Restore replaces `.env`, the PostgreSQL volume, the n8n data volume, clears the Redis queue volume, and restores `local-files` from the selected backup:

```bash
scripts/restore.sh backups/YYYYMMDDTHHMMSSZ
```

The restore script requires typing `RESTORE` before it stops containers or replaces data.

The restore script also waits for PostgreSQL and aborts before `pg_restore` if the database does not become ready.

## Reverse proxy

Terminate HTTPS in a reverse proxy and forward traffic to:

```text
http://127.0.0.1:3001
```

Make sure your proxy sends standard forwarded headers such as `X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Forwarded-For`.

Example reverse proxy configs are provided:

- `examples/Caddyfile` for a simple HTTPS Caddy deployment.
- `examples/nginx-n8n.conf` for Nginx with HTTPS redirect, forwarded headers, websocket support, upload limits, and request rate limiting.

Copy the example for your proxy, replace `n8n.example.com`, and point it at `http://127.0.0.1:3001`.

## Monitoring

Run the monitoring check manually:

```bash
scripts/monitor.sh
```

It exits non-zero when n8n main/worker health checks fail, free disk is below `MONITOR_MIN_FREE_DISK_MB`, the newest backup is older than `MONITOR_BACKUP_MAX_AGE_HOURS`, `backups/update.log` is stale or contains recent failure indicators, Redis is missing, a task-runner sidecar is missing, or any container has restarted.

For external monitoring, run it from cron and alert on non-zero exit, or call it from a local agent used by Uptime Kuma, Cronitor, healthchecks.io, or your host monitoring stack.

Useful thresholds:

```bash
MONITOR_MIN_FREE_DISK_MB=10240
MONITOR_BACKUP_MAX_AGE_HOURS=26
MONITOR_UPDATE_LOG_MAX_AGE_HOURS=26
```

## CI

GitHub Actions validates shell syntax, runs ShellCheck, and checks Docker Compose rendering on pushes and pull requests to `main`.

## Notes

- This setup pins `N8N_IMAGE_TAG` because external task runners require a matching versioned `n8nio/runners` image; `n8nio/runners:stable` is not published.
- External task-runner sidecars use the same `N8N_IMAGE_TAG` as n8n, as required by n8n's task-runner guidance. Each worker has its own sidecar.
- PostgreSQL data is stored in the `${COMPOSE_PROJECT_NAME}_postgres_data` Docker volume.
- n8n application data is stored in the `${COMPOSE_PROJECT_NAME}_n8n_data` Docker volume.
- Redis queue data is stored in the `${COMPOSE_PROJECT_NAME}_redis_data` Docker volume.
- Files mounted at `/files` inside n8n are stored in `./local-files`.
