# Production n8n Docker Setup

This setup runs n8n with PostgreSQL, persistent Docker volumes, local file storage, external task runners, health checks, and backup/restore scripts for a small single-server production install.

## Quick start

```bash
docker compose up -d
```

If `.env` does not exist, Compose starts a one-shot `init-env` service that creates it from `.env.example` with generated secrets, then stops before PostgreSQL or n8n start. Because Docker Compose reads `.env` before it starts services, review the generated `.env` and run this once more so the n8n and PostgreSQL containers use those generated values:

```bash
docker compose up -d
```

For the cleanest first production start, you can generate `.env` before starting containers:

```bash
chmod +x scripts/*.sh
scripts/bootstrap.sh
docker compose up -d
```

Edit `.env` before production use:

- Set `N8N_HOST` to your domain.
- Set `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` to your public HTTPS URL.
- The default timezone is `Asia/Yangon`; change `GENERIC_TIMEZONE` and `TZ` only if needed.
- Keep `N8N_ENCRYPTION_KEY` unchanged after first start.
- Keep `N8N_RUNNERS_AUTH_TOKEN` secret. It is used by the external task-runner sidecar.
- For stricter release control, set `N8N_IMAGE_TAG` to a tested n8n version instead of `stable`. The n8n and task-runner images must use the same version tag.

Start n8n:

```bash
docker compose up -d
docker compose logs -f n8n
```

By default n8n binds to `127.0.0.1:3001`, which is suitable when using a reverse proxy for HTTPS. Change `N8N_BIND_ADDRESS=0.0.0.0` only if you intentionally want to expose the port directly.

## Automatic updates

The update script pulls the configured n8n and task-runner images, compares them with the running containers, creates a backup, recreates the n8n and task-runner containers, and waits for n8n to become healthy.

Unattended updates are disabled by default. Enable them only after you have tested restore on this host:

```bash
N8N_AUTO_UPDATE=true
```

Run one update check manually:

```bash
scripts/update-n8n.sh --force
```

Install a daily cron job:

```bash
scripts/install-auto-update-cron.sh
```

Update logs are written to `backups/update.log`. If the post-update health check fails, the script exits non-zero and leaves the containers/logs available for inspection.

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

Backup directories are created with owner-only permissions because `env.snapshot` contains secrets. Store encrypted backup copies outside this server as part of your production operations.

## Restore

Test restore before enabling unattended updates. Restore replaces `.env`, the PostgreSQL volume, the n8n data volume, and `local-files` from the selected backup:

```bash
scripts/restore.sh backups/YYYYMMDDTHHMMSSZ
```

The restore script requires typing `RESTORE` before it stops containers or replaces data.

## Reverse proxy

Terminate HTTPS in a reverse proxy and forward traffic to:

```text
http://127.0.0.1:3001
```

Make sure your proxy sends standard forwarded headers such as `X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Forwarded-For`.

## Notes

- This defaults to the official n8n `stable` Docker tag, which n8n documents as the production tag. Pin `N8N_IMAGE_TAG` for more controlled production releases.
- External task runners use the same `N8N_IMAGE_TAG` as n8n, as required by n8n's task-runner guidance.
- PostgreSQL data is stored in the `${COMPOSE_PROJECT_NAME}_postgres_data` Docker volume.
- n8n application data is stored in the `${COMPOSE_PROJECT_NAME}_n8n_data` Docker volume.
- Files mounted at `/files` inside n8n are stored in `./local-files`.
