# 3. Azure Services Used

The demo leverages several Azure services to build a scalable, serverless pipeline.
Each service plays a distinct role in data ingestion, processing, storage and presentation.

## Azure Cosmos DB for NoSQL

Cosmos DB is a globally distributed, multi‑model database service with elastic scalability and guaranteed low latency.
The **NoSQL** API supports schema‑free JSON documents and SQL‑like queries.
In this lab, Cosmos DB hosts the `sensors` database with three containers:

* `readings` – stores raw sensor readings.  Partitioned by `/sensor_id`.
* `summaries` – stores aggregated metrics (max, min, avg) per sensor.
  Partitioned by `/sensor_id`.
* `leases` – stores continuation tokens for the Change Feed processor.

Cosmos DB’s appeal lies not just in its flexible document model but also in its **global distribution** and tunable consistency models.
You can replicate a database across any Azure region with a few clicks, and multi‑region writes provide low latency and high availability.
The demo deploys a single‑region account, but you could enable geo‑replication and designate a failover region for greater resiliency.
The consistency level (e.g. *Session*, *Strong* or *Eventual*) controls the trade‑off between latency and freshness; Change Feed always respects the chosen consistency level.

Behind the scenes Cosmos DB automatically indexes every property by default.
For event processing workloads you may customise the index policy to reduce write costs; e.g. exclude large nested properties or string fields that you never query.
Partitioning strategy is equally important: using `/sensor_id` keeps data for each sensor together, maximising Change Feed efficiency.
Alternative patterns include time‑based partition keys (e.g. `/date`) when retention windows are short and per-sensor volumes are low.
The lab encourages you to experiment with these settings.

### Advanced Features and Tuning

Cosmos DB offers a rich set of features beyond the basics used in this lab.
When moving to production, consider the following options:

* **Consistency models** – Cosmos DB provides five [consistency levels](https://learn.microsoft.com/azure/cosmos-db/nosql/consistency-levels): *Strong*, *Bounded Staleness*, *Session*, *Consistent Prefix* and *Eventual*.
  Strong consistency offers linearizability but incurs higher latency, while eventual consistency yields the lowest latency but may return out‑of‑order reads.
  Session consistency is the default and works well for most scenarios; the Change Feed respects whatever level you configure.
* **Automatic indexing policies** – By default, every field in every document is indexed.
  For write‑heavy workloads you can reduce RU consumption by excluding unqueried properties or specifying composite indexes to accelerate complex queries.
  Index policies are defined per container and can be updated online.
* **Autoscale throughput** – In the Bicep template the `sensors` database and containers use autoscale up to 4000 RU/s.
  Autoscale automatically adjusts provisioned throughput based on recent usage.
  For steady workloads you might choose manual throughput to save costs.
  Keep in mind the minimum RU per physical partition is 400 RU/s for autoscale and 10 RU/s for manual throughput.
* **Change Feed retention** – By default the Change Feed retains data indefinitely until the source item is deleted or expired.
  For scenarios where you only care about recent events, you can set a TTL on the source container.
  Items will be automatically purged and removed from the Change Feed after the TTL expires.

## Azure Container Apps

Container Apps is a serverless container platform that runs microservices and event‑driven applications without managing servers.
It provides auto‑scaling based on HTTP requests, CPU/memory and KEDA triggers.
Container Apps supports [**managed identities**](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview) so containers can securely access services like Cosmos DB without secrets.

Each of the three components (generator, summariser, visualiser) runs as its own Container App with a managed identity.
When deploying via `azd`, the Bicep templates automatically configure these identities and assign appropriate data‑plane roles on Cosmos DB.

Container Apps provides many features beyond running arbitrary Docker images.
It offers **autoscaling** triggered by CPU/memory metrics, HTTP queue length or custom event sources through [KEDA]
(https://keda.sh/).
In this lab the summariser uses a fixed replica count, but you could configure horizontal scaling based on the number of Change Feed events queued.
Each scaling action creates or deletes instances seamlessly without downtime.
Container Apps also supports versioned **revisions**: each deployment yields a new revision of an app, and you can roll back or split traffic between revisions for canary testing.
Logging and diagnostics are integrated with Azure Monitor and Application Insights.

Managed identities deserve special mention.
Rather than storing credentials in environment variables, each Container App is assigned a user‑defined identity.
Azure Resource Manager automatically grants the identity access to the Cosmos DB data plane via built‑in roles (e.g. `Cosmos DB Built‑in Data Contributor`).
The services use `DefaultAzureCredential` to obtain tokens for authentication.
This pattern eliminates the risk of secrets being leaked in code or logs and aligns with the principle of least privilege.

### Beyond the Basics

Container Apps includes many advanced capabilities not covered in the core lab:

* **Dapr integration** – When enabled, Dapr (Distributed Application Runtime) provides service invocation, state management and pub/sub messaging between apps via HTTP or gRPC.
  This simplifies microservice communication without managing service discovery.
* **KEDA triggers** – In addition to CPU and HTTP‑based scaling, you can scale apps based on metrics such as the length of a Kafka topic, the number of messages in an Azure Service Bus queue or an Event Hubs partition.
  Define KEDA scalers in the `scale` section of your Bicep or YAML definition.
* **Custom domain and TLS certificates** – You can map your own domain names to Container Apps and upload TLS certificates via the Azure Portal or CLI.
  This is useful for production deployments where users access your app via a branded URL.
* **Revision management** – Each deployment creates a new **revision**.
  You can toggle between **multiple** (traffic can be split across revisions) and **single** (only the latest revision is active) revision modes.
  Use `az containerapp revision list` to view available revisions and `az containerapp ingress traffic set` to control traffic splitting.
* **Secret management** – Secrets defined in the Container Apps environment can be referenced by your app.
  For sensitive values stored outside of Bicep outputs (e.g. API keys), you can integrate with Azure Key Vault and inject secrets into your app at runtime.

Beyond storing images, ACR offers several advanced capabilities:

* **ACR Tasks** – You can define build tasks that automatically build and push images when changes are pushed to your repository.
  Tasks support scheduled builds, multi‑arch images and base image updates.
* **Container image scanning** – Integration with Microsoft Defender for Container Registries scans images for known vulnerabilities upon push.
  You can view vulnerability reports in Azure Security Center and configure alerts or policies.
* **Private link and firewall rules** – ACR can be configured with private endpoints to restrict access to your virtual networks.
  Use firewall rules to allow only specific IP ranges to pull images.
* **Image import** – Use the `az acr import` command to copy images from Docker Hub or other registries into your ACR, keeping external dependencies within your control.

## Azure Container Registry (ACR)

The container images for the services are stored in an Azure Container Registry.
ACR is a private Docker registry that integrates with Container Apps.
The `azd` workflow builds and pushes images during deployment.

ACR supports additional features that become valuable in team settings.
For example, you can enable **geo‑replication** to push images to one region and have them automatically mirrored to others, reducing egress costs and speeding up deployments.
You can configure **retention policies** to automatically clean up old images and save storage costs.
ACR integrates with [Content Trust](https://learn.microsoft.com/azure/container-registry/container-registry-content-trust), allowing you to sign images and verify their integrity at deploy time.
You can also assign granular roles such as `AcrPull` and `AcrPush` via Azure RBAC to restrict who can push or pull images.

## Bicep and Azure Developer CLI

The infrastructure is defined declaratively using **Bicep**.
The `main.bicep` template describes all resources and outputs connection information.
The **Azure Developer CLI (azd)** orchestrates the provisioning and deployment, simplifying repeatable infrastructure operations.

Bicep builds on ARM templates with a more concise syntax and native support for modules, loops and conditions.
Each resource is declared once and automatically reapplied idempotently.
In this project, `main.bicep` sets up the Cosmos DB account, database and containers, Container Apps environment, managed identities and role assignments.
Separate module files create the individual Container Apps.
This modular approach promotes reuse and clarity.
The Bicep template also exposes outputs such as the Cosmos endpoint and identity client IDs, which `azure.yaml` consumes to set environment variables.

The Azure Developer CLI ties everything together.
Running `azd up` initialises the environment (asking for subscription and region), provisions the resources using Bicep and deploys application code in one step.
If you modify the application code but not the infrastructure, `azd deploy` will rebuild and redeploy just the images.
You can tear down everything with `azd down` once you’re done, avoiding unexpected costs.

### Deep Dive into Bicep and `azd`

Bicep is designed to make ARM templates more readable.
Some advanced features you might explore include:

* **Modules and reuse** – Break large templates into modules and reference them with the `module` keyword.
  Inputs are passed via parameters and outputs propagate values back up the call stack.
* **Loops and conditions** – Use `for` expressions to create multiple similar resources or `if` statements to include resources only when a condition is met.
  For example, you could loop through a list of sensors to create separate containers for each.
* **Secure parameters** – Declare sensitive parameters as `secure` to ensure their values are not logged.
  Combine this with Key Vault references to pull secrets at deployment time.
* **Target scopes** – Bicep can deploy resources at different scopes (resource group, subscription, management group).
  For enterprise scenarios you might deploy policies or role assignments at the subscription level.

The Azure Developer CLI (`azd`) builds on top of Bicep and Git to provide an opinionated workflow.
Advanced features include:

* **Environment management** – Use `azd env list`, `azd env new`, `azd env select` and `azd env delete` to manage multiple isolated deployments (e.g. dev/test/prod).
  Each environment stores its configuration in `.azure/{env}.env`.
* **Pipeline integration** – `azd pipeline config` helps generate GitHub Actions or Azure DevOps pipelines that run `azd up` and `azd deploy` as part of your CI/CD process.
  You can configure secrets in your pipeline to authenticate to Azure.
* **Hooks** – Define custom scripts that run before or after provisioning (`preprovision`, `postprovision`) or deployment (`predeploy`, `postdeploy`).
  Hooks allow you to seed databases, run tests or send notifications automatically during `azd up` or `azd deploy`.

### Cosmos DB Indexing and Query Optimisation

Cosmos DB automatically indexes all properties in JSON documents with a range index for strings and numbers.
While this simplifies queries, you may need to tune the index policy for performance and cost:

* **Excluding unnecessary paths** – If your documents contain large nested objects that you never query (e.g. blob metadata), exclude those paths from the index via `excludedPaths`.
  This reduces index storage and write RU consumption.
* **Composite indexes** – When queries filter on multiple properties and sort the result, define a composite index to avoid a full scan.
  For example, to sort readings by `sensor_id` and `timestamp` you can add `{ path: "/sensor_id", order: "ascending" }, { path: "/timestamp", order: "descending" }` to `compositeIndexes`.
* **Spatial and unique indexes** – Cosmos DB also supports geospatial indexes and unique key constraints.
  If sensor events include geolocation, a spatial index allows radius searches.
  A unique key on `id` and `timestamp` prevents duplicate writes.
* **Query cross‑partition** – Queries that do not specify a partition key use cross‑partition scans.
  This is acceptable for low QPS analytic queries but can be expensive at scale.
  Where possible include the `sensor_id` in your `WHERE` clause or specify `PartitionKey` in the SDK.
* **Using dedicated gateways** – Cosmos DB offers dedicated gateways for heavy read workloads.
  These provide additional network throughput and offload query parsing from data nodes.

These optimisations help maintain predictable RU consumption as your data model evolves.

### Container Apps Deep Dive

Azure Container Apps (ACA) abstracts Kubernetes concepts into a serverless experience.
Beyond the basics, ACA provides advanced capabilities:

* **Dapr integration** – Enable **Distributed Application Runtime (Dapr)** sidecars in your Container Apps environment to simplify building microservices.
  Dapr provides pub/sub messaging, secret management, service invocation, state stores and more without heavy infrastructure.
  You can configure Dapr components via YAML and bind them to your app.
* **KEDA scaling** – ACA uses **KEDA** under the hood for event‑driven autoscaling.
  You can configure custom scale triggers (e.g. RabbitMQ queue length, CPU usage, HTTP requests) and specify minimum/maximum replicas.
  This is useful if generator load varies per sensor.
* **Revisions and traffic splitting** – Each deployment of a Container App creates a new **revision**.
  You can control whether new revisions receive 100 % of traffic, gradually roll out changes (e.g. 80/20 split) or pin clients to a specific revision for troubleshooting.
  Use `az containerapp revision` commands or the Azure portal to manage revisions.
* **Networking and security** – ACA supports VNet integration via ingress and egress features.
  You can assign a static IP, restrict ingress to HTTPS only, mount secrets from Key Vault and assign managed identities to authenticate to other Azure services.
  Use secrets to inject sensitive values into your app rather than environment variables.
* **Jobs and cron** – The ACA platform now includes **Container Apps Jobs**, which allow you to run background tasks on a schedule or on demand.
  This can replace the summariser service for batch aggregations or periodic cleanups.

### Advanced Azure Container Registry Capabilities

Azure Container Registry (ACR) is more than a simple image store.
You can leverage advanced functionality to automate your CI/CD pipeline and improve security:

* **ACR Tasks** – Define build tasks that run inside ACR.
  Tasks can build images from Dockerfiles or run multi‑step scripts whenever source code changes.
  This offloads build operations from your local machine or CI agents and standardises your container builds.
* **Image scanning and vulnerability assessment** – ACR integrates with Microsoft Defender for Cloud to scan images for known vulnerabilities.
  You can enforce policies to prevent deployment of insecure images.
* **Content trust and signing** – Use **Notary** to sign images and verify their integrity during deployment.
  This ensures that only trusted images run in your environment.
* **Private link and network rules** – Similar to Cosmos DB, ACR supports private endpoints and firewall rules to restrict access.
* **Image import and geo‑replication** – Import images from Docker Hub or other registries directly into ACR, and enable geo‑replica locations to place images closer to your Container Apps for faster pull times.

These features allow you to build an enterprise‑grade supply chain around your container images.

## Security, Compliance and Observability

Enterprise solutions must take into account regulatory compliance, fine‑grained access control and operational monitoring across all services.
Some key considerations include:

* **Encryption at rest and in transit** – Cosmos DB encrypts data by default and supports **customer‑managed keys (CMK)** via Azure Key Vault for strict compliance requirements.
  Container Apps also support TLS termination at the ingress and can enforce mutual TLS between microservices using Dapr.
* **Network isolation** – Combine private endpoints, IP firewall rules and virtual network (VNET) integration to ensure that your database and container registry are not exposed to the public internet.
  Container Apps environments can be deployed into a VNET with private egress and inbound control via Application Gateway or API Management.
* **Role‑based access control (RBAC)** – Use Azure AD roles to grant least‑privilege access to each component.
  For example, assign **Cosmos DB Data Reader** to the visualiser and **Data Contributor** to the summariser.
  Audit logs can be captured via Azure Monitor and exported to Log Analytics.
* **Observability** – Enable diagnostic settings for Cosmos DB (metrics and logs), Container Apps (revision logs), and ACR to stream data into Azure Monitor or a third‑party system.
  Use queries and alerts to detect high RU consumption, container restart loops or image scan failures.
  Tools like **Azure Monitor Workbook**, **Grafana** or **OpenTelemetry** can help centralise observability.

## Integrating AI and Advanced Data Features

While this demo uses Cosmos DB’s core SQL API, Microsoft’s data platform offers additional capabilities that can enhance your application:

* **Vector search** – Azure Cosmos DB for MongoDB vCore and Azure Cognitive Search support vector indexes for **semantic search** and similarity queries.
  Embeddings can be generated using Azure OpenAI or third‑party libraries and stored alongside your sensor data.
  A summariser variant might detect anomalous patterns by comparing embeddings across time windows.
* **Graph storage** – If your domain involves relationships between sensors (e.g. hierarchical topology or dependencies), consider using **Azure Database for PostgreSQL – with Apache AGE** to store and query graphs.
  This enables path finding and connectivity analysis on your IoT network.
* **In‑database machine learning** – Services like **Azure Database for PostgreSQL** with the `azure_ai` and `pgvector` extensions allow you to call OpenAI models and perform embedding operations directly within your database, as demonstrated in the Agentic Shop workshop.
  The concepts learned there parallel the Change Feed analytics in this lab; both architectures rely on event streams and serverless compute to process data close to where it is stored.

By combining these advanced features with robust security and observability, you can evolve this lab into a comprehensive intelligent data processing platform.
