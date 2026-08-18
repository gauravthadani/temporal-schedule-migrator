"""Migrate all schedules from a local Temporal server to Temporal Cloud.

Usage:
  uv run migrate-schedules            # dry run (default): prints each schedule's payloads
  uv run migrate-schedules create     # actually create on Cloud

Configure via env vars (or a .env file next to this script):
  LOCAL_ADDRESS, LOCAL_NAMESPACE     (defaults: localhost:7233, default)
  CLOUD_ADDRESS, CLOUD_NAMESPACE
  CLOUD_API_KEY   (preferred)  OR   CLOUD_TLS_CERT + CLOUD_TLS_KEY
  OVERWRITE=1                        delete existing cloud schedule first
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from temporalio.api.common.v1 import Payload
from temporalio.client import Client, ScheduleActionStartWorkflow, TLSConfig
from temporalio.common import RawValue
from temporalio.service import RPCError, RPCStatusCode

load_dotenv(Path(__file__).with_name(".env"))


def env(name: str, default: str | None = None) -> str | None:
    v = os.environ.get(name, default)
    return v if v not in (None, "") else None


async def connect_local() -> Client:
    return await Client.connect(
        env("LOCAL_ADDRESS", "localhost:7233"),
        namespace=env("LOCAL_NAMESPACE", "default"),
    )


async def connect_cloud() -> Client:
    address = env("CLOUD_ADDRESS")
    namespace = env("CLOUD_NAMESPACE")
    if not address or not namespace:
        sys.exit("CLOUD_ADDRESS and CLOUD_NAMESPACE must be set")

    api_key = env("CLOUD_API_KEY")
    cert = env("CLOUD_TLS_CERT")
    key = env("CLOUD_TLS_KEY")

    if api_key:
        return await Client.connect(address, namespace=namespace, api_key=api_key, tls=True)
    if cert and key:
        return await Client.connect(
            address,
            namespace=namespace,
            tls=TLSConfig(
                client_cert=Path(cert).read_bytes(),
                client_private_key=Path(key).read_bytes(),
            ),
        )
    sys.exit("Set CLOUD_API_KEY or both CLOUD_TLS_CERT and CLOUD_TLS_KEY")


async def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] in ("dry", "dry-run"):
        dry_run = True
    elif args[0] in ("create", "apply"):
        dry_run = False
    else:
        sys.exit(f"unknown argument: {args[0]} (expected: create, or no args for dry run)")

    overwrite = env("OVERWRITE") == "1"

    local = await connect_local()
    cloud = await connect_cloud()

    ids = [s.id async for s in await local.list_schedules()]
    if not ids:
        print("No schedules found on source.")
        return

    print(f"Found {len(ids)} schedule(s) on source")

    failures: list[tuple[str, str]] = []
    for sid in ids:
        print(f"\n=== {sid} ===")
        try:
            desc = await local.get_schedule_handle(sid).describe()

            if overwrite:
                try:
                    await cloud.get_schedule_handle(sid).delete()
                    print("  deleted existing on cloud")
                except RPCError as e:
                    if e.status != RPCStatusCode.NOT_FOUND:
                        raise

            if dry_run:
                print("  DRY: would create")
                action = desc.schedule.action
                if isinstance(action, ScheduleActionStartWorkflow) and action.args:
                    for i, a in enumerate(action.args):
                        p = a.payload if isinstance(a, RawValue) else a
                        if not isinstance(p, Payload):
                            print(f"  payload[{i}]: <{type(p).__name__}> {p!r}")
                            continue
                        encoding = p.metadata.get("encoding", b"").decode(errors="replace")
                        try:
                            data = p.data.decode()
                        except UnicodeDecodeError:
                            data = f"<{len(p.data)} bytes: {p.data!r}>"
                        print(f"  payload[{i}] encoding={encoding} data={data}")
                continue

            memo = await desc.memo() or None
            sas = desc.typed_search_attributes if len(desc.typed_search_attributes) else None
            await cloud.create_schedule(
                sid,
                desc.schedule,
                memo=memo,
                search_attributes=sas,
            )
            print("  created")
        except Exception as e:  # noqa: BLE001
            print(f"  FAILED: {e}", file=sys.stderr)
            failures.append((sid, str(e)))

    print(f"\nDone. {len(ids) - len(failures)} succeeded, {len(failures)} failed.")
    for sid, err in failures:
        print(f"  {sid}: {err}", file=sys.stderr)


def main_sync() -> None:
    asyncio.run(main())


if __name__ == "__main__":
    main_sync()
