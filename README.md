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

## What is *not* migrated

Schedule migration is a lossy operation — some things only make sense on the source cluster and don't (or can't) transfer. Watch out for:

- **Runtime state.** `info.recent_actions`, `info.next_action_times`, `info.running_workflows`, `info.created_at`, and action counters are all re-derived on the target. Historical run data stays on the source.
- **Search attributes.** Any search attribute referenced by a source schedule (either on the schedule itself or on the workflow it starts) must already be registered on the target namespace. The migrator does **not** pre-check this — Temporal Cloud's namespace-scoped API keys can't call `OperatorService.ListSearchAttributes`, so any check would break the primary use case. Missing SAs surface as per-schedule `INVALID_ARGUMENT` failures in the run summary. Register them on the target first:

  ```bash
  temporal operator search-attribute create --name YourAttribute --type Keyword
  ```
- **Data converters / codecs.** Payloads are copied as raw bytes. If the source encrypts or otherwise encodes payloads with a custom codec, the target's workers must use the same codec — otherwise scheduled workflows will start but fail to decode their input.
- **Task queues and workers.** Task queue names carry over; workers do not. Make sure workers are polling the target task queues before you let schedules fire, or runs will pile up unexecuted.

## Recommended cutover

Both clusters running the same schedule means both will fire. Neither running means missed windows. To keep the switchover clean:

1. Pause the source schedules (or delete them). Bulk-pause via `temporal schedule toggle --pause` per schedule ID, or use `delete-cloud-schedules` against the source.
2. Run the migrator with `create`.
3. Spot-check on the target: `temporal --address <target> --namespace <target-ns> schedule describe --schedule-id <sid>`.
4. Ensure workers are running on the target for every task queue the schedules use.
5. If you seeded the target paused, unpause it now. Otherwise, the migration itself carries over the source's paused state.

## Seed test schedules

`schedules_seeder/seed_schedules.sh` creates ~20 schedules that exercise the payload, spec, state, and metadata combinations most likely to expose migration bugs. Requires the `temporal` CLI and points at `LOCAL_ADDRESS` / `LOCAL_NAMESPACE`.

```bash
./schedules_seeder/seed_schedules.sh          # create
./schedules_seeder/seed_schedules.sh --clean  # delete every demo-* schedule
```

The seeder registers `CustomKeywordField` on the source itself. To migrate the schedule that uses it, register the same SA on the target namespace too:

```bash
temporal operator search-attribute create --name CustomKeywordField --type Keyword
```
