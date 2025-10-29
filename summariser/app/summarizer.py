import os
import time
import uuid
from datetime import datetime, timezone
from statistics import mean
from typing import List, Dict, Optional, Set

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

COSMOSDB_ENDPOINT = os.environ["COSMOSDB_ENDPOINT"]
# Managed identity authentication; no key is needed.  The container app's
# assigned identity must have a Cosmos DB data plane role with sufficient
# permissions.
DB_NAME = os.getenv("DATABASE_NAME", "sensors")
READINGS = os.getenv("READINGS_CONTAINER", "readings")
SUMMARIES = os.getenv("SUMMARIES_CONTAINER", "summaries")
LEASES = os.getenv("LEASES_CONTAINER", "leases")
INTERVAL = int(os.getenv("BATCH_INTERVAL_SECONDS", "1"))

LEASE_ID = "readings_changefeed_lease"

def utc_now_str() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def load_lease(lease_container):
    try:
        return lease_container.read_item(item=LEASE_ID, partition_key=LEASE_ID)
    except Exception:
        lease = {"id": LEASE_ID, "continuation": None, "last_run_utc": None}
        lease_container.upsert_item(lease)
        return lease

def save_lease(lease_container, lease):
    lease_container.upsert_item(lease)

def read_changes(container, continuation: Optional[str]):
    # Use change feed pull model and capture continuation token via response_hook.
    latest_token = {"value": continuation}

    def hook(headers, _):
        token = headers.get("etag") or headers.get("x-ms-continuation")
        if token:
            latest_token["value"] = token

    kwargs = {
        "max_item_count": 1000,
        "response_hook": hook,
        "mode": "LatestVersion",
    }
    if continuation:
        kwargs["continuation"] = continuation
    else:
        kwargs["start_time"] = "Now"

    items = list(container.query_items_change_feed(**kwargs))
    return items, latest_token["value"]

def summarise_sensor(sensor_id: str, readings_container, summary_container):
    """Compute summary statistics for the last 10 readings of a sensor.

    Queries the readings container for the most recent 10 documents matching
    the given sensor_id, ordered by timestamp descending.  Calculates the
    maximum, minimum and average temperature and writes a summary record to
    the summaries container.  Returns the summary dict on success or None if
    no data was found.
    """
    query = (
        f"SELECT TOP 10 c.timestamp, c.temperature FROM c WHERE c.sensor_id = @sid "
        f"ORDER BY c.timestamp DESC"
    )
    params = [
        {"name": "@sid", "value": sensor_id},
    ]
    # Query the readings container; enable cross-partition query for safety.
    items = list(
        readings_container.query_items(
            query=query,
            parameters=params,
            enable_cross_partition_query=True,
        )
    )
    if not items:
        return None
    temps = [it.get("temperature") for it in items if isinstance(it.get("temperature"), (int, float))]
    if not temps:
        return None
    max_temp = max(temps)
    min_temp = min(temps)
    avg_temp = round(mean(temps), 2)
    out = {
        "id": str(uuid.uuid4()),
        "timestamp": utc_now_str(),
        "sensor_id": sensor_id,
        "max_temp": max_temp,
        "min_temp": min_temp,
        "avg_temp": avg_temp,
    }
    summary_container.upsert_item(out)
    return out

def main():
    """Entry point for the summariser.

    This function listens to the change feed on the readings container.  Whenever
    new readings arrive, it computes per-sensor summary statistics based on the
    most recent 10 readings for each sensor observed in the batch and writes
    those statistics to the summaries container.
    """
    # Use DefaultAzureCredential to authenticate using the container app's
    # managed identity.  Ensure the identity has been assigned the
    # "Cosmos DB Built-in Data Contributor" role on the target database account.
    credential = DefaultAzureCredential()
    client = CosmosClient(COSMOSDB_ENDPOINT, credential)
    db = client.get_database_client(DB_NAME)
    readings = db.get_container_client(READINGS)
    summaries = db.get_container_client(SUMMARIES)
    leases = db.get_container_client(LEASES)

    lease = load_lease(leases)
    print(f"Summarizer started. Interval={INTERVAL}s")

    while True:
        # Pull changes since the last continuation token.  This returns a batch
        # of change feed items and an updated continuation token.  If the
        # continuation token is None, the change feed starts from the current
        # time (no historical data).
        batch, new_token = read_changes(readings, lease.get("continuation"))
        if batch:
            # Determine which sensors have new data in this batch
            sensors_in_batch: Set[str] = set(
                item.get("sensor_id") for item in batch if item.get("sensor_id")
            )
            for sid in sensors_in_batch:
                summary = summarise_sensor(sid, readings, summaries)
                if summary:
                    print(
                        f"[{summary['timestamp']}] summary for {sid}: "
                        f"max={summary['max_temp']}, min={summary['min_temp']}, avg={summary['avg_temp']}"
                    )
        else:
            print(f"[{utc_now_str()}] no new changes")

        lease["continuation"] = new_token
        lease["last_run_utc"] = utc_now_str()
        save_lease(leases, lease)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
