# temporal-schedule-migrator

Copy Temporal Schedules from one cluster/namespace to another (e.g. self-hosted → Temporal Cloud).

Useful when you're moving workloads to a new cluster but don't want to migrate the namespace itself — you still need to recreate your Schedules on the target.

## Build

```bash
docker build -t temporal-schedule-migrator .
```

## Migrate

Dry run (default — prints what would be created, changes nothing):

```bash
docker run --rm --env-file .env temporal-schedule-migrator
```

Apply:

```bash
docker run --rm --env-file .env temporal-schedule-migrator create
```

Replace Schedules that already exist on the target:

```bash
docker run --rm --env-file .env -e OVERWRITE=1 temporal-schedule-migrator create
```

## Delete all Schedules on the target

```bash
# dry run
docker run --rm --env-file .env \
  --entrypoint delete-cloud-schedules \
  temporal-schedule-migrator

# actually delete
docker run --rm --env-file .env \
  --entrypoint delete-cloud-schedules \
  temporal-schedule-migrator delete
```

No confirmation prompt — run the dry-run first.

## Environment variables

| Variable | Required | Default |
|---|---|---|
| `LOCAL_ADDRESS` | no | `localhost:7233` |
| `LOCAL_NAMESPACE` | no | `default` |
| `CLOUD_ADDRESS` | yes | — |
| `CLOUD_NAMESPACE` | yes | — |
| `CLOUD_API_KEY` | one of | — |
| `CLOUD_TLS_CERT` + `CLOUD_TLS_KEY` | one of | — |
| `OVERWRITE` | no | unset (`1` to enable) |

To reach a Temporal server on your host from the container: use `LOCAL_ADDRESS=host.docker.internal:7233` on Mac/Windows, or `--network host` on Linux.
