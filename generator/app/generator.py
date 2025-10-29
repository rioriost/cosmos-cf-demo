import os
import time
import random
import uuid
import threading
from datetime import datetime, timezone
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from azure.core.exceptions import HttpResponseError

COSMOSDB_ENDPOINT = os.environ["COSMOSDB_ENDPOINT"]
# Use Azure AD managed identity for authentication.  The identity must have a
# Cosmos DB data plane role assigned (for example, "Cosmos DB Built-in Data Contributor").
DB_NAME = os.getenv("DATABASE_NAME", "sensors")
READINGS = os.getenv("READINGS_CONTAINER", "readings")

# Define five sensor IDs.  Each sensor will emit readings on its own schedule.
SENSOR_IDS = [f"sensor-{i}" for i in range(1, 6)]


def producer(sensor_id: str, container):
    """Continuously generate readings for a single sensor at random intervals.

    Each sensor sleeps for a random number of seconds between 1 and 10,
    then writes a new temperature reading to the Cosmos DB container.  If an
    error occurs, the exception is logged and the loop continues.
    """
    while True:
        # Wait for a random interval between 1 and 10 seconds
        interval = random.randint(1, 10)
        time.sleep(interval)
        temp_c = round(random.uniform(15.0, 40.0), 2)
        now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        doc = {
            "id": str(uuid.uuid4()),
            "sensor_id": sensor_id,
            "temperature": temp_c,
            "timestamp": now
        }
        try:
            result = container.upsert_item(doc)
            print(
                f"[{now}] sensor={sensor_id} wrote id={result.get('id')} temp={result.get('temperature')}"
            )
        except HttpResponseError as e:
            print(
                f"[{now}] sensor={sensor_id} failed to upsert {doc['id']}: {getattr(e, 'message', e)}"
            )
            # In case of failure, wait a short time before retrying
            time.sleep(1)


def main():
    # Acquire an Azure AD token using the managed identity available to this
    # container app.  DefaultAzureCredential will automatically use the user‑assigned
    # identity assigned to the container app.  See Azure documentation for
    # details: https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-connect-role-based-access-control
    credential = DefaultAzureCredential()
    client = CosmosClient(COSMOSDB_ENDPOINT, credential)
    db = client.get_database_client(DB_NAME)
    container = db.get_container_client(READINGS)

    # Start a thread for each sensor.  Each thread runs its own infinite loop.
    threads = []
    for sensor_id in SENSOR_IDS:
        t = threading.Thread(target=producer, args=(sensor_id, container), daemon=True)
        t.start()
        threads.append(t)

    print(
        "Producer started. Each sensor emits readings at random intervals between 1 and 10 seconds."
    )
    # Keep the main thread alive indefinitely
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("Producer shutting down...")


if __name__ == "__main__":
    main()
