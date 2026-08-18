"""Delete every schedule in the configured Temporal Cloud namespace.

Reads the same .env as migrate_schedules.py (CLOUD_ADDRESS, CLOUD_NAMESPACE,
CLOUD_API_KEY).

Usage:
  uv run python delete_cloud_schedules.py            # dry run
  uv run python delete_cloud_schedules.py delete     # actually delete
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from temporalio.client import Client

load_dotenv(Path(__file__).with_name(".env"))


async def main() -> None:
    args = sys.argv[1:]
    dry_run = not (args and args[0] in ("delete", "apply"))

    address = os.environ["CLOUD_ADDRESS"]
    namespace = os.environ["CLOUD_NAMESPACE"]
    api_key = os.environ["CLOUD_API_KEY"]

    client = await Client.connect(address, namespace=namespace, api_key=api_key, tls=True)

    ids = [s.id async for s in await client.list_schedules()]
    print(f"Found {len(ids)} schedule(s) in {namespace}")
    if not ids:
        return

    if dry_run:
        for sid in ids:
            print(f"  {sid}")
        print("\nDRY RUN. Re-run with 'delete' to remove them.")
        return

    for sid in ids:
        print(f"deleting {sid}")
        await client.get_schedule_handle(sid).delete()


def main_sync() -> None:
    asyncio.run(main())


if __name__ == "__main__":
    main_sync()
