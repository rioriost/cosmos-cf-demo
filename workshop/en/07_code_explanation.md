# 7. Code Walkthrough

This section highlights key portions of the Python services that make up the demo.
Understanding these components will help you adapt the patterns to your own scenarios.

## Generator

The generator service simulates five sensors.
Each sensor runs in its own thread and emits temperature readings at random intervals between 1 and 10 seconds:

```python
def producer(sensor_id: str, container):
    while True:
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
        result = container.upsert_item(doc)
        print(f"[{now}] sensor={sensor_id} wrote id={result.get('id')} temp={result.get('temperature')}")
```

Multiple threads are started for each sensor, and the main thread sleeps indefinitely to keep the process alive.
The managed identity of the container app authenticates the Cosmos DB client.

Several aspects of the generator are worth highlighting:

* **Randomised emission intervals** – each sensor thread sleeps for a random duration between one and ten seconds.
  This pattern models real IoT devices, which often send data at unpredictable times.
  You could substitute other distributions (e.g. exponential or Poisson) to simulate bursty traffic.
* **Unique identifiers and timestamps** – using `uuid.uuid4()` for the document `id` guarantees uniqueness across sensors, preventing accidental overwrites when using `upsert_item`.
  Timestamps are stored as ISO8601 strings; the Python SDK handles conversion to the appropriate data type in Cosmos DB.
  Consider storing timestamps as `datetime` objects if you plan to run range queries on time windows.
* **Idempotent writes** – `upsert_item` inserts the document if it doesn't exist or replaces it if the `id` already exists.
  In this demo the IDs are always new, but `upsert` provides resilience in scenarios where retry logic may cause duplicate submissions.

Replacing the random generator with actual sensor reads is straightforward: read data from serial ports, MQTT brokers or Azure IoT Hub and call `container.upsert_item()` with the payload.
The same partition key considerations apply.

## Summariser

The summariser listens to the Change Feed on the `readings` container using the Azure Cosmos DB SDK’s Change Feed API.
When new items are detected, it groups them by sensor and computes statistics from the latest 10 records:

```python
def summarise_sensor(sensor_id: str, readings_container, summary_container):
    query = (
        "SELECT TOP 10 c.timestamp, c.temperature FROM c WHERE c.sensor_id = @sid "
        "ORDER BY c.timestamp DESC"
    )
    items = list(readings_container.query_items(
        query=query,
        parameters=[{"name": "@sid", "value": sensor_id}],
        enable_cross_partition_query=True,
    ))
    temps = [it.get("temperature") for it in items if isinstance(it.get("temperature"), (int, float))]
    if temps:
        summary = {
            "id": str(uuid.uuid4()),
            "timestamp": utc_now_str(),
            "sensor_id": sensor_id,
            "max_temp": max(temps),
            "min_temp": min(temps),
            "avg_temp": round(mean(temps), 2),
        }
        summary_container.upsert_item(summary)
        return summary
```

The `read_changes` function retrieves batches from the Change Feed and returns the updated continuation token.
A lease document stored in the `leases` container tracks the summariser’s progress so that it can resume where it left off after a restart.

Key points about the summariser implementation:

* **Efficient queries** – the SQL query in `summarise_sensor` selects the top 10 readings for a given sensor, sorted by timestamp.
  Because the `readings` container is partitioned by `/sensor_id`, the query includes a filter on `sensor_id`, which avoids cross‑partition scans.
* **Input validation** – the comprehension filtering out non‑numeric temperatures guards against malformed payloads.
  When interfacing with external sensors, implement validation and error handling to prevent corrupt data from propagating.
* **Idempotent summarisation** – Change Feed processing is **at‑least‑once**, so the same event may be delivered multiple times.
  The summariser should therefore be able to recompute summaries without causing duplicates or inconsistent data.
  One strategy is to include a `last_processed` timestamp in the summaries container and skip items older than that.
  Alternatively, store a high‑water mark in the leases container and check against it.
* **Concurrency** – the lab uses a single thread to process change events, but you can scale out by running multiple summariser instances with the Change Feed processor library.
  Leases ensure partitions are evenly distributed among instances.

## Visualiser

The visualiser is a Flask application that reads from the `summaries` container and produces plots using **matplotlib**.
It defines endpoints to serve an HTML dashboard and PNG images for each sensor.
The HTML uses JavaScript to poll a small API and update charts only when new summaries appear:

```python
@app.route('/')
def index():
    # Build a grid of images, one per sensor
    # JavaScript polls /api/summary-timestamps every 2s to detect updates
    ...

@app.route('/plot/<sensor_id>.png')
def plot_png(sensor_id):
    image_bytes = create_plot(sensor_id)
    return Response(image_bytes, mimetype='image/png')

@app.route('/api/summary-timestamps')
def api_summary_timestamps():
    # Return the latest summary timestamp for each sensor
```

The `create_plot` function fetches the latest summary points for a sensor, creates a figure with max, min and average series, and returns the PNG bytes.
A red dot next to the sensor name flashes when new data arrives.

In the visualiser you see an example of **materialised view** design.
Rather than reading raw events, it queries the `summaries` container which already holds aggregated metrics.
This reduces load on the front‑end and allows the summariser to evolve independently.
The Flask app uses the `Agg` backend of matplotlib to render PNG images in memory.
When generating many charts, you may want to cache figures or precompute additional metrics (such as rolling averages) to reduce rendering time.

## Running Locally

While the lab is designed for deployment to Azure, you can run the services locally for development or testing.
Use the provided Dockerfiles to build images, or run the Python scripts directly with environment variables pointing to your Cosmos DB account.

## Advanced Implementation Notes

As you adapt the code for production scenarios, consider the following enhancements:

### Generator: Asynchronous and Stateful Patterns

The current generator spawns a thread per sensor and sleeps for a random interval.
For high sensor counts or constrained environments, using **asyncio** and a single event loop can be more efficient.
An asynchronous generator might look like this:

```python
async def produce_sensor(sensor_id: str, container):
    while True:
        interval = random.randint(1, 10)
        await asyncio.sleep(interval)
        temp_c = round(random.uniform(15.0, 40.0), 2)
        now = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
        doc = {
            'id': str(uuid.uuid4()),
            'sensor_id': sensor_id,
            'temperature': temp_c,
            'timestamp': now,
        }
        await container.upsert_item(doc)
```

Running multiple `produce_sensor` tasks concurrently allows a single process to handle hundreds of sensors with minimal overhead.
If sensor state must persist across restarts (e.g. calibration values), store metadata in a separate collection or use Azure Digital Twins.

### Summariser: Parallel Processing and Error Handling

To improve throughput, partition the summariser into independent workers per partition key.
The CFP library automatically spreads partitions across workers, but you should also implement robust error handling:

```python
async def handle_changes(docs, partition_key):
    try:
        await summarise_sensor(partition_key)
    except Exception as ex:
        logging.exception('Error processing partition %s', partition_key)
        # Optionally push the failed event to a dead‑letter queue
```

Consider storing the last N readings in a separate **state container** instead of memory.
This allows multiple summariser instances to share state and survive restarts.
Use a composite key `(sensor_id, sequence)` and a TTL to limit its size.

### Visualiser: WebSockets and Client‑Side Rendering

The current visualiser uses server‑side PNG generation and polling.
For interactive dashboards, you can migrate to WebSockets or Server‑Sent Events (SSE) so that updates push to clients immediately.
Libraries like **Flask‑SocketIO** or **FastAPI** make this easy.
On the client side, consider using a JavaScript charting library (Chart.js, Plotly) to render graphs dynamically rather than serving static images.
This offloads rendering work from the server and improves perceived responsiveness.

### Instrumentation and Observability

In production, instrument your services with logging, metrics and distributed tracing:

* **Structured logging** – Emit JSON logs that include correlation IDs (e.g. sensor ID, event ID) and context.
  This makes searching logs in Log Analytics or Elastic easier.
* **Metrics** – Export custom metrics such as processing latency, number of events processed, or errors per sensor via OpenTelemetry.
  Container Apps integrates with **Azure Monitor**; you can scrape metrics via the `/metrics` endpoint or push them to Application Insights.
* **Tracing** – Propagate trace context through the generator, summariser and visualiser using OpenTelemetry SDKs.
  This helps identify bottlenecks across services.

### Further Improvements

* **Backpressure and throttling** – If the summariser cannot keep up with the generator, implement rate limiting on producers or queue events in a buffer (e.g. Service Bus).
  Azure Cosmos DB will throttle writes if RU limits are exceeded, so monitor and respond accordingly.
* **Schema evolution** – When adding new fields to documents, provide default values or versioning logic in your summariser to maintain backward compatibility.
* **Testing** – Use pytest or unittest to write unit tests for your functions.
  Mock the Cosmos DB client to avoid network calls.

By considering these advanced aspects, you can evolve this lab into a robust, production‑grade event‑driven system.

## Distributed Concurrency Patterns

Building on the simple loop examples, you can adopt more advanced concurrency patterns:

* **Task queues** – Offload work from the HTTP request thread by placing summarisation tasks into an in‑memory or distributed queue (e.g. **Azure Queue Storage** or **RabbitMQ**).
  Worker processes fetch tasks and call Cosmos DB.
  This decouples the generator from the summariser and allows dynamic scaling.
* **Async/await and event loops** – Both the Azure SDK for Python and Flask support asynchronous operations.
  Converting the summariser to use `async def` functions and `aiohttp` or `fastapi` can improve throughput when there are many sensors.
* **Idempotent processing** – Use a deterministic composite key for summary documents (e.g. `f"{sensor_id}-{timestamp}"`) and rely on `upsert` semantics to avoid duplicates when multiple instances process the same events.

## Advanced Error Handling and Resilience

Production systems must anticipate failure modes:

* **Transient fault retries** – Wrap Cosmos DB calls in a retry/backoff mechanism (the SDK provides configurable retry policies).
  For long outages, backoff exponentially and surface alerts.
* **Poison messages** – If a particular document causes repeated failures, move it to a dead‑letter queue or mark it as processed with an error flag.
  This prevents the pipeline from stalling.
* **Circuit breakers** – Implement a circuit breaker pattern around dependent services (e.g. the summariser’s use of Cosmos DB).
  If too many requests fail consecutively, open the circuit and return a fallback response until the service recovers.

## Instrumentation and Observability

In addition to logging and tracing, you can instrument specific performance metrics:

* **Custom metrics** – Record the number of readings processed per second, the size of the sliding window per sensor and the RU consumption per summarisation loop.
  Export these metrics to Azure Monitor via the SDK or with StatsD.
* **Structured logging** – Emit logs in JSON format with fields for `sensor_id`, `reading_id` and operation duration.
  Structured logs integrate better with log analytics tools.
* **Exception correlation** – When an unhandled exception occurs in the generator or summariser, include the `correlation_id` of the reading to facilitate debugging across services.

## Environment Configuration Management

As your application grows, you will need to manage many configuration values (e.g. database names, container names, window sizes).
Rather than hard‑coding these in code, externalise them to configuration files or environment variables.
Tools like **Dapr Secrets API** or **Azure App Configuration** can provide dynamic configuration reloads without redeploying your container.
This also facilitates running different configurations for development, staging and production.
