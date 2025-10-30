# 4. Understanding the Azure Cosmos DB Change Feed

The **Change Feed** is a powerful feature of Azure Cosmos DB that enables applications to react to changes in data without polling the database.
Instead of executing periodic queries to find new or updated documents, consumers read from a log‑like stream that records each modification in order.

## How It Works

When the Change Feed is enabled for a container, Cosmos DB maintains an internal, append‑only log of operations.
Each insert or update to a document is appended to this log exactly once.
Consumers can read from the feed starting from:

* **Now** – only future changes are observed.
* **Beginning** – replay all historical changes.
* **A continuation token** – resume from a previous position.

Internally the Change Feed is partitioned in the same way as the source container.
Each logical partition key has its own change stream, which allows high throughput and horizontal scaling.
The **Change Feed processor library** (used implicitly in this demo) abstracts the complexity of reading from multiple partitions and automatically manages checkpoints.

## When to Use It

Change Feed is ideal for scenarios where you need to:

* Trigger downstream actions whenever new data arrives – e.g., send notifications, call APIs or start workflows.
* Perform real‑time analytics or streaming ETL on high‑velocity data.
* Build materialised views or leaderboards by projecting raw events into aggregated tables.
* Implement event sourcing architectures with an append‑only store.

## Design Considerations

When designing a Change Feed solution, keep the following guidelines in mind:

* **Partition key choice** – since the Change Feed follows partition boundaries, choose a key that distributes load evenly.
  In this demo `/sensor_id` is used for both `readings` and `summaries` to keep related events together.
* **Throughput** – allocate sufficient RU/s to handle both writes and Change Feed consumption.
  Autoscale throughput can help smooth bursty loads.
* **Concurrency** – multiple Change Feed consumers can operate on the same container.
  Use different lease containers or prefixes to avoid conflicting checkpoints.
* **Idempotency** – because the Change Feed offers an **at least once** delivery guarantee, make processing logic idempotent to handle duplicate events gracefully.

Understanding these principles will help you build robust event‑driven architectures using Cosmos DB.

## Anatomy of a Change Feed Processor

In practice you rarely read the Change Feed by manually polling a REST endpoint.
The **Change Feed Processor (CFP) library** in the Azure Cosmos DB SDK abstracts many complexities.
It uses a second container to store **leases** that track progress through each partition.
Each consumer instance acquires leases on a subset of partitions, reads new items and periodically updates the lease checkpoint.
When you scale out by adding more summariser replicas, the leases are redistributed evenly.
The lab uses direct queries on the Change Feed for illustrative simplicity, but in production you would use the CFP library or higher‑level constructs like Azure Functions and Event Hubs connectors.

The following pseudo‑code illustrates a basic CFP loop:

```python
for page in readings_container.read_change_feed(partition_key=pk, start_time=start):
    for item in page:
        process(item)
    save_checkpoint(page.continuation)
```

The continuation token ensures that if your processor crashes, it resumes from the last processed item.
Always make your processing logic **idempotent**: because the Change Feed offers at‑least‑once delivery, the same event may be delivered more than once.

### Scaling and Concurrency

Each logical partition of the source container has its own Change Feed stream.
When your workload grows, you can increase the number of partitions (by increasing RU/s and re‑ingesting data) so that multiple consumers can process different partitions in parallel.
The CFP library uses `leases` to coordinate concurrency across processors:

* Each lease document corresponds to one physical partition of the `readings` container.
* A processor instance reads only partitions for which it owns the lease, ensuring no two processors handle the same events.
* When a new instance starts (e.g. due to scaling out), leases are automatically rebalanced.

This architecture allows you to horizontally scale Change Feed consumers based on throughput requirements.
Use a separate leases container for each distinct processor so that processors do not interfere with each other.

### Advanced Patterns

The Change Feed is often combined with other Azure services:

* **Azure Functions** can be triggered by Change Feed events.
  You configure an input binding to a Cosmos DB container, and Functions handles checkpointing automatically.
  This is ideal for lightweight event handlers or orchestration logic.
* **Event Hubs integration** – Cosmos DB can write Change Feed events directly to Azure Event Hubs, enabling streaming pipelines via Azure Stream Analytics or Apache Kafka consumers.
* **Synapse Link and Data Explorer** – replicates Cosmos DB data into Fabric or Data Explorer for analytical workloads.

Choosing the right pattern depends on latency requirements, downstream systems and operational complexity.
The simple summariser in this lab illustrates the fundamentals; you can build more elaborate pipelines using the same core concept.

## Fine‑Tuning Change Feed Processing

While the demo uses a simple loop to query recent events, production solutions typically employ the **Change Feed Processor** (CFP) library provided by the Azure SDK.
The CFP hides complexity and handles checkpointing and concurrency for you.
Here are some advanced considerations:

### Start positions

The Change Feed can be read from different start points:

* **From now** (`StartFromNow`) – the processor ignores historical documents and only reads new changes going forward.
  Use this when you are interested in real‑time processing and historical data is irrelevant.
* **From beginning** (`StartFromBeginning`) – replays all existing documents in the container.
  This is useful when you need to populate a new materialised view or backfill a downstream system.
* **From a point in time** (`StartFromTime`) – start reading from a specified timestamp.
  This option lets you catch up after a downtime or backfill a partial period.

In the Python SDK you specify the start position when building the Change Feed iterator:

```python
from azure.cosmos import PartitionKey, ChangeFeedPolicy

# Start reading from a specific UTC timestamp
start_time = datetime(2025, 10, 28, 0, 0, tzinfo=timezone.utc)

iterable = readings_container.read_change_feed(
    partition_key=PartitionKey(sensor_id),
    start_time=start_time,
    max_item_count=100
)
for page in iterable:
    for item in page:
        process(item)
```

### Using the Change Feed Processor Library

For high throughput or cross‑partition processing, the CFP library is recommended.
The following pseudo‑code illustrates how to configure and start a processor:

```python
from azure.cosmos import CosmosClient, PartitionKey
from azure.cosmos.change_feed import ChangeFeedProcessor

client = CosmosClient(account_uri, credential=credential)
database = client.get_database_client('sensors')
source_container = database.get_container_client('readings')
lease_container = database.get_container_client('leases')

async def handle_changes(changes: list[dict], partition_key: str):
    for doc in changes:
        await process_change(doc)

processor = ChangeFeedProcessor(
    client,
    source_container,
    lease_container,
    handle_changes,
    instance_name='summariser',
    lease_prefix='readings_'
)

await processor.start()
```

Here, `instance_name` uniquely identifies each summariser instance (useful for logging), and `lease_prefix` allows multiple processors to share the same lease container without colliding.
The handler function receives batches of documents and can perform I/O operations asynchronously.
The CFP automatically scales with the number of physical partitions in the source container, distributing leases evenly across instances.

### Throughput and Cost Considerations

Reading from the Change Feed consumes RU/s similar to standard reads.
Each page read is charged at approximately 2 RU regardless of the number of items returned.
If your summariser frequently polls the Change Feed and the container is mostly idle, you may waste RU/s.
Instead, use a **pull model** with reasonable delays or leverage the CFP’s internal polling optimisations.
Monitor your RU consumption via Azure Monitor metrics and adjust the read `max_item_count` and polling interval accordingly.

The Change Feed only includes inserts and updates; deletions are represented as TTL expirations or soft deletes.
If your use case requires reacting to deletions, set a `ttl` on the container and process `expiry` events.
Remember that TTL deletions also consume Change Feed throughput.

## Optimisation Techniques

Fine‑tuning your Change Feed processing can reduce cost and latency:

* **Batch size and prefetch** – When using the SDK directly, you can specify `max_item_count` per page.
  Larger batches amortise the cost of each request but increase memory usage and latency per item.
  In Python’s `read_change_feed` iterator, choose a `max_item_count` that balances throughput and responsiveness.
* **Start time vs continuation tokens** – Use the `start_time` parameter for deterministic replay of events from a known point in time, and store the continuation token in durable storage (e.g. Blob Storage or the `leases` container) on shutdown.
  This avoids processing duplicates if your service restarts.
* **Deduplication and idempotency** – Even with at‑least‑once semantics, you can eliminate duplicates using unique constraints or upserts.
  For example, store a summary with a composite key of `(sensor_id, window_start)` and use `upsert_item` to update it.
* **Full‑fidelity vs incremental Change Feed** – Cosmos DB supports [full‑fidelity Change Feed](https://learn.microsoft.com/azure/cosmos-db/nosql/change-feed-design-patterns#full-fidelity) that includes delete and intermediate update events.
  Full‑fidelity mode is useful for audit logs and event sourcing but incurs higher storage and RU costs.
  Incremental mode (default) only surfaces final state after updates.
* **Leases partitioning** – When using the CFP, store leases in a separate container with a low throughput (e.g. 400 RU/s) and partition it on a synthetic key (e.g. `/id`).
  Avoid storing application data in the same container as leases.

## Change Feed Triggers and Azure Functions

Azure Functions provides a serverless environment to run code in response to events.
The **Cosmos DB trigger** allows your function to execute whenever there are new documents in the Change Feed:

```python
import azure.functions as func
from azure.cosmos import CosmosClient

def main(documents: func.DocumentList):
    for doc in documents:
        # process each changed document
        do_work(doc)
```

The binding configuration specifies the database, container, and connection string.
Azure Functions handles checkpoints and retries automatically.
This is a great way to integrate with other Azure services (e.g. Service Bus, Event Hubs, SendGrid) without managing infrastructure.
Be mindful of cold start latency and function timeout limits.
For high throughput scenarios, consider using dedicated or premium function plans.

## Event Sourcing and Materialised Views

Because the Change Feed preserves every mutation, you can adopt an **event sourcing** pattern.
Instead of storing current state, each write becomes an immutable event.
Downstream consumers rebuild the state by replaying events.
This provides a complete audit trail and enables temporal queries (e.g. “what was the value at 10 AM?”).
Use full‑fidelity mode to capture deletes and intermediate updates.

To serve queries efficiently, you often maintain **materialised views** or projections tailored to your application’s needs.
In this demo, the `summaries` container is a simple projection of the last 10 readings.
In a more complex system, you might pre‑aggregate metrics per hour/day, group by location or device type, or compute rolling averages with different window lengths.
Each view can be stored in its own container or external systems like Azure Data Explorer, Fabric or SQL Database.

## Cross‑Account Replication and Integration Patterns

Large organisations often maintain multiple Cosmos DB accounts across different subscriptions or tenants.
The Change Feed can be used to propagate changes between these accounts:

* **Cross‑account replication** – A lightweight “copy” worker reads from the Change Feed of the source account and writes to the target account.
  You can configure the destination container with its own partition key and consistency model, effectively replicating data across regions or security boundaries.
* **Event Grid integration** – Azure Cosmos DB Change Feed events can be forwarded to **Event Grid** to fan out notifications to Azure Functions, Logic Apps, or third‑party services.
  Event Grid delivers at‑least once and supports filtering on event types and subject patterns.
* **Cosmos DB to SQL** – Use **Azure Data Factory** or **Fabric Mirroring** to ingest Change Feed data into a relational warehouse.
  This enables complex joins and analytics queries on sensor and summary data.

## Tuning Lease Collections and Throughput

When using the **Change Feed Processor (CFP)** library, each worker maintains a lease on a logical partition.
You can tune CFP to optimise parallelism and cost:

* **Lease container design** – Place leases in a separate container (`leases`) with low throughput (e.g. 400 RU/s).
  The lease key is derived from the source partition key.
  This design ensures that the summariser only processes one partition at a time and that scaling out increases concurrency.
* **Partitioned lease collections** – For very high cardinality sources, use multiple lease containers or add a synthetic suffix to the lease ID.
  The CFP library will distribute leases evenly across workers.
* **Throughput quotas** – The CFP library uses ~2 RU per read.
  If you use a sliding window of 10 items per sensor, factor this into your RU budget.
  You can control the maximum number of parallel calls via the `maxItemCount` and `maxDegreeOfParallelism` options.

## Handling Late Events and Idempotency

Sensors may occasionally emit readings with timestamps far in the past (for example, when clock skew occurs) or duplicate data after a reconnect.
To ensure correctness:

* **Event ordering** – Include the event timestamp in the document and use a composite index on `(sensor_id, timestamp)`.
  In your summarisation logic, discard events older than the sliding window and update the state in sorted order.
* **Deduplication** – Generate a deterministic event ID (e.g. `UUIDv5(sensor_id + timestamp)`) and store it in a hash set or dedicated container.
  Skip processing if the ID already exists.
* **Idempotent writes** – Write summary documents with a stable ID composed of `sensor_id` and the window boundary (e.g. minute or sequence number).
  Upsert these documents so that multiple summariser instances can safely write the same record without duplication.

## Resource Governance and Cost Control

Monitoring and controlling the RU consumption of Change Feed processors is critical:

* **Backpressure handling** – When RU consumption approaches the allocated limit, reduce the `maxItemsPerRead` or increase the lease container RU/s.
  CFP will automatically pause and resume reading based on availability.
* **Throttling detection** – Check the `x-ms-request-charge` and `x-ms-substatus` headers in the `response_headers` of your SDK calls.
  If the substatus is 10003 (rate limited), the SDK will retry.
  Consider reducing concurrency if you see high retry counts.
* **Multi‑region pricing** – If you enable multi‑region writes, remember that RU usage is multiplied across regions.
  Estimate consumption per region and adjust capacity accordingly.

By combining these tuning techniques with the advanced patterns described earlier, you can build robust and efficient Change Feed pipelines suited to complex enterprise scenarios.
