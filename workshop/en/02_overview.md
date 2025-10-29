# 2. Application Overview

In this lab you will build and deploy a simple but powerful event‑driven
application on Azure.  The scenario emulates an **IoT** environment in
which multiple sensors send temperature readings at random intervals.  A
backend summariser processes the data in real time using **Azure Cosmos DB
change feed**, and a visualiser displays aggregated metrics in a web
interface.

Although the example focuses on IoT, the architecture applies to many
domains, including:

* **Gaming leaderboards** – update player scores and compute rankings
  without reprocessing all data.
* **E‑commerce** – react to orders or inventory changes to update
  recommendations or trigger workflows.
* **Financial services** – feed transaction events into analytics
  pipelines for fraud detection or auditing.

### Why Use the Change Feed?

The change feed provides a lightweight way to process new data as it is
written to a Cosmos DB container.  Instead of repeatedly querying the
database for changes, your application reads from an append‑only stream
that captures each insert or update exactly once【437749716107481†L47-L66】.
This pattern enables:

* **Real‑time processing** – changes are available almost immediately after
  write, making it ideal for live dashboards and notifications.
* **Scalability** – the feed partitions scale with your container, so
  multiple consumers can process data in parallel.
* **High availability** – Cosmos DB guarantees 99.999 % availability for
  reads and writes and provides an **at‑least once** delivery guarantee on
  the change feed【437749716107481†L116-L166】.
* **Event sourcing** – you can replay the entire history of events to
  rebuild state or materialised views when needed【437749716107481†L149-L166】.

Throughout this lab you will experience how the change feed simplifies the
construction of event‑driven pipelines.

## Deeper Dive into the Scenario

At a glance the application might seem like a toy IoT demo, but the
pattern scales to production workloads.  Each sensor in the generator
represents a stream of events.  In manufacturing, sensors may report
temperature, vibration or pressure; in logistics, packages may emit GPS
coordinates and status; in games, player actions generate scoring events.

Traditionally such systems poll a database or message queue to retrieve
new events.  With Cosmos DB change feed you subscribe to the stream of
changes itself.  The summariser acts as a streaming aggregator: for each
sensor partition it computes running statistics (max/min/average) over
the last 10 events.  This is a form of **sliding window aggregation**,
commonly used in streaming analytics.  You could extend the logic to
compute percentile values, rolling standard deviations or anomaly
detections.  The change feed makes it trivial to build these pipelines
without an external stream processor.

The visualiser illustrates how to present data to end users.  Each chart
is independent and can be refreshed on demand.  Because the summariser
writes aggregated documents back into Cosmos DB, the visualiser can use
simple queries to fetch the latest state rather than reading the change
feed directly.  If you wish to visualise raw events (e.g. to plot
timestamped spikes), you could add endpoints to stream from the
`readings` container or export data to time‑series databases like
Azure Data Explorer.  This architecture is flexible and open to
extension.

### Extending the Architecture

The core pattern here – **producer → change feed → consumer → materialised
view** – underpins many event‑driven systems.  In more complex
applications, you may introduce additional microservices downstream of
the summariser.  For example:

* **Notification service** – triggers alerts when the maximum
  temperature exceeds a threshold, sending e‑mails or SMS messages.
* **Machine learning inference** – feeds recent sensor data into a
  trained model to predict failures or maintenance needs.
* **Data lake ingestion** – writes change feed events to Azure Data Lake
  Storage for offline analytics or training.  Azure Cosmos DB
  integrates natively with Azure Synapse Link to replicate data into
  Synapse for near real‑time analytics.

The modularity of Container Apps and managed identities means you can add
these services without changing your database.  Each consumer simply
reads from the change feed and processes events according to its own
logic.  This decoupling helps teams iterate quickly and scale
independently.

## Exploring Streaming Analytics Patterns

To appreciate the power of the change feed pattern, it helps to view
your application through the lens of **stream processing**.  In a
streaming system, two notions of time are important: **event time** (when
the sensor generated the reading) and **processing time** (when your
application sees the event).  A windowed aggregator like the
summariser computes metrics over a moving window of events ordered by
event time.  In this lab the window size is simply the last 10 events
per sensor, but in production you might use time‑based windows (e.g.
the last 5 minutes) or session windows that close after inactivity.

The choice of windowing strategy affects the semantics and complexity
of your pipeline.  Libraries like Apache Flink or Azure Stream
Analytics implement sophisticated window operations, but Cosmos DB’s
change feed combined with your own logic can handle many common
patterns.  For example, to compute a rolling average over the past
hour you could query all readings with a timestamp greater than
`utc_now() - timedelta(hours=1)` and compute the mean.  Because all
readings for a sensor live in a single partition, these queries are
efficient.

The summariser also demonstrates **sliding window aggregation**.  Each
time a new reading arrives, the oldest reading in the window is
discarded and statistics are recomputed.  This pattern generalises to
more complex metrics: you could maintain a list of the last _N_ values
and use `statistics.pstdev` to compute the population standard
deviation, or track the median using a balanced heap.  When storing
more than 10 values, consider storing the window in a separate
container or using a dedicated caching layer like Redis to avoid
repeated reads from the `readings` container.

### Event‐Driven Microservice Architecture

The lab implements a classic **producer–consumer** architecture where
the generator and summariser are decoupled through the change feed.
This separation of concerns brings several benefits:

* **Resilience** – failures in the summariser do not block event
  ingestion.  The change feed retains events until they are processed.
* **Scalability** – the generator can scale up to thousands of
  instances without modifying the summariser.  Additional summariser
  replicas can be added later to handle higher throughput.
* **Extensibility** – new downstream services (e.g. alerting or
  machine‑learning inference) can subscribe to the change feed without
  changing existing producers.

In larger systems the change feed may feed into a message broker such
as Event Hubs or Kafka.  This introduces buffering and ordering
guarantees, enabling patterns like **fan‑out** (multiple consumers
receive the same event) and **fan‑in** (multiple producers write to the
same stream).  You can combine Cosmos DB change feed with Azure
Functions or Logic Apps to orchestrate multi‑step workflows.

### Advanced Extensions

There are many ways to extend the basic architecture:

* **Graph and vector search** – Azure Cosmos DB offers other APIs such
  as Gremlin (graph) and Cassandra.  For IoT scenarios you might
  model sensors and devices as vertices and use graph traversals to
  detect relationships or anomalies.  In the [`postgres‑agentic‑shop`](https://github.com/Azure-Samples/postgres-agentic-shop)
  sample, multiple AI agents interact with a Postgres database using
  vector search and graph queries to retrieve product information.  You
  could similarly enrich sensor data with vector embeddings and search
  for similar patterns【716571452689310†L9-L58】.
* **Materialised views** – Instead of computing metrics on demand, you
  can maintain additional containers (or tables) that store rolled‑up
  data at different granularities (e.g. hourly, daily).  A
  summariser consumer could write to these materialised views in
  parallel.
* **Event sourcing and audit logs** – Because the change feed retains
  every mutation, you can replay events to rebuild state or audit
  past behaviour.  This pattern is described in detail in the
  Cosmos DB change feed design patterns document【437749716107481†L149-L166】.  For
  example, if your summariser logic changes, you can recompute
  historical summaries by replaying events from the beginning.
* **Integration with machine learning** – Real‑time sensor streams
  lend themselves to anomaly detection.  You could deploy an Azure
  Function that triggers on new summaries, feeds data into a trained
  model (hosted in Azure ML or as a container) and raises an alert
  when unusual patterns appear.

By understanding the conceptual foundations of stream processing and
microservice architectures, you will be better equipped to tailor this
demo to your own use cases.

## Real‑World Use Cases

The patterns demonstrated in this lab extend far beyond the simple
thermometer example.  Here are a few concrete scenarios where a
change‑feed‑driven architecture excels:

* **Fleet management and logistics** – Vehicles or shipping containers
  periodically emit GPS coordinates, temperatures and load status.  A
  change feed processor can update dashboards and notify operators
  when thresholds are exceeded (e.g., refrigeration failure).
* **Smart building automation** – Sensors in a building monitor
  occupancy, air quality and power consumption.  Real‑time processing
  enables dynamic HVAC adjustments and predictive maintenance.  Events
  can be routed to facility management systems or digital twins.
* **Game state synchronisation** – Multiplayer games require low
  latency updates to leaderboards, matchmaking queues and player
  inventories.  Storing events in Cosmos DB and projecting them into
  materialised views avoids read contention and enables rollback in
  case of cheating.
* **Financial transactions** – Payment gateways and trading platforms
  produce streams of orders and trades.  Change feed consumers can
  perform real‑time risk checks, generate account statements or feed
  analytics pipelines for fraud detection.

These examples illustrate how the same building blocks—producers,
change feed, consumers and visualisers—can be composed in different
domains.  As you design your own solution, think about the nature of
your events (volume, latency sensitivity, ordering) and choose the
appropriate processing and storage patterns.

## Decision Points and Trade‑Offs

When adapting this architecture for production, you will face several
design choices.  Understanding the trade‑offs helps you make informed
decisions:

* **Throughput mode (serverless vs provisioned)** – Serverless
  accounts simplify cost management but limit container size and
  concurrent throughput.  Provisioned accounts provide stable RU/s
  with predictable latency.  Autoscale sits in between.  Consider
  expected peak load and growth when choosing.
* **Consistency level** – Cosmos DB offers five consistency models
  ranging from `Strong` to `Eventual`.  Strong consistency guarantees
  linearizability but increases latency in multi‑region setups.
  Bounded Staleness or Session consistency often suffice for
  analytics use cases.
* **Event boundaries** – Should you produce one document per sensor
  reading, or batch multiple readings into a single document?  Fine
  granularity allows selective processing but increases overhead.  When
  ingesting millions of events per second you may choose coarser
  documents and handle unpacking downstream.
* **Summarisation strategy** – This demo computes simple max, min and
  average metrics over a sliding window.  In practice you might need
  quantiles, standard deviation, or custom domain‑specific aggregates.
  Choosing the right window size (time‑based vs count‑based) affects
  responsiveness and noise.
* **State management** – We keep the last nine values in memory in the
  summariser.  For larger windows or multiple consumers, consider
  storing the state in a separate container or cache (e.g. Redis) to
  enable horizontal scaling.

Document these decisions in your architecture design.  Azure Well‑Architected
Framework provides guidance on cost optimisation, performance
efficiency and reliability that you can apply to change‑feed
solutions.

## Extending the Demo

Once you understand the fundamentals, there are many ways to extend
and customise the demo:

* **Add more sensors or data sources** – Modify the generator to
  simulate hundreds of devices or integrate real hardware via MQTT or
  OPC‑UA gateways.  This will test the scalability of the change
  feed.
* **Compute additional statistics** – Implement functions to calculate
  median, percentile or time‑weighted averages.  For example, using
  a `collections.deque` to maintain a sorted sliding window makes
  median calculation efficient.
* **Persist state in another data store** – Rather than keeping the
  last nine readings in memory, write them to a dedicated container
  (e.g. `sensorHistory`) or use Azure Cache for Redis.  This allows
  multiple summariser instances to share state and survive restarts.
* **Expose APIs or stream output** – Provide REST or gRPC endpoints for
  downstream clients to consume aggregated data.  Alternatively,
  publish summaries to Event Hubs or Service Bus for further
  processing by other microservices.
* **Integrate authentication and permissions** – Use Azure App Service
  Authentication or Azure API Management to secure your visualiser
  endpoints.  For fine‑grained access control, assign roles at the
  container level via Azure RBAC.

With these extensions the lab evolves into a production‑ready
reference architecture.  The next sections of this workshop delve
deeper into the implementation details of each service.

## Advanced Event‑Driven Patterns

Beyond the core change feed pipeline demonstrated in this lab, there
are numerous ways to expand the architecture using event‑driven
patterns:

* **Fan‑out/Fan‑in pipelines** – Instead of a single summariser, you
  could route readings through **Azure Event Hubs** or **Service Bus**
  topics with multiple downstream consumers.  For example, one
  consumer calculates statistics while another triggers alerts when
  thresholds are exceeded.  A final stage can aggregate the streams
  back into a single output.
* **CQRS and command/event segregation** – In systems where commands
  (writes) and queries (reads) need to scale independently, the
  summariser can publish events to a separate read model.  This
  decouples write latency from read scalability and allows you to
  maintain multiple materialised views.
* **Time travel and replay** – Because the change feed is an
  append‑only log, you can replay historical events by starting from
  an earlier continuation token.  This makes it possible to rebuild
  derived state when your summarisation logic changes or to backfill
  new metrics without downtime.
* **Integration with AI and search** – Azure Cosmos DB can store
  **vector embeddings** or **graph data** in dedicated containers and
  expose them via the new `vector` and `gremlin` APIs.  For instance,
  you might compute an embedding of the last 10 readings and use
  Azure Cognitive Search or a `pgvector`‑like library to find
  anomalous patterns.  Similarly, mapping sensor relationships in a
  graph enables complex network queries.
* **Edge to cloud handoff** – Use IoT Edge modules to perform
  pre‑processing or anomaly detection at the edge, then forward
  enriched events into the cloud change feed pipeline for durable
  storage and further analysis.

## Multi‑Tenant and Multi‑Sensor Considerations

In larger systems you may have hundreds or thousands of sensors
belonging to different customers or tenants.  Adapting this
architecture requires thoughtful design:

* **Partitioning strategy** – Use a synthetic partition key composed
  of `tenant_id` and `sensor_id` (e.g. `"tenant1-sensor42"`) to
  ensure an even distribution of reads and writes across physical
  partitions.  Avoid large “hot” partitions by using random suffixes
  or hashed IDs when necessary.
* **Namespace isolation** – Deploy each tenant into its own Cosmos
  database or container to enforce data separation.  Alternatively,
  implement access controls via Azure Active Directory roles and
  policies to restrict which tenant data a summariser can read.
* **Concurrency control** – When multiple summariser instances process
  the same sensor streams (for redundancy), implement idempotent
  writes and use the **Change Feed Processor** library’s leasing
  mechanism to avoid duplicate work.
* **Temporal semantics** – Decide whether your sliding window should be
  event‑time based (using timestamps from the sensor) or
  processing‑time based.  Event‑time windows require handling late
  arrivals and out‑of‑order events with watermarks, while
  processing‑time windows are simpler but may misalign with
  real‑world timelines.

These design considerations echo concepts from distributed systems
literature such as the **Kappa architecture** and provide a
foundation for scaling beyond the lab.
