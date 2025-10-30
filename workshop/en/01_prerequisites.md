# 1. Prerequisites and Audience

## Target Audience

This hands‑on lab is designed for developers and architects who are new to **Azure Cosmos DB** and wish to learn how to build event‑driven applications using the Change Feed.
No prior experience with Cosmos DB or Container Apps is required.
Basic familiarity with Python and the command line will help, but the instructions include all necessary commands.

## Permissions and Subscription

To complete the lab you will need:

* An **Azure subscription** where you have permission to create resource groups and deploy resources.
  A Pay‑As‑You‑Go or MSDN subscription is sufficient.
  If you do not have a subscription, you can sign up for a free trial at [Azure free account](https://azure.microsoft.com/free/).
* The ability to create new **resource groups** within the subscription.

## Tools and Environment

Before starting the exercises, please install and configure the following.
Many of the tools are the same as you would use for any Azure development project, but there are a few important additions and considerations that will make your experience smoother:

* **[Azure CLI](https://aka.ms/install-azure-cli)** (`az`) – used to authenticate and manage resources.
  Be sure to update to the latest version (`az --version`) to avoid compatibility issues, and sign in with `az login` before starting the lab.
* **[Azure Developer CLI](https://aka.ms/azd)** (`azd`) – simplifies provisioning and deployment of the application.
  On first run you will be prompted to sign in.
  You can check your version with `azd version`; a recent release (≥ 1.5) is recommended.
* **Git** – to clone the repository.
  On Windows you may install it via [Git for Windows](https://gitforwindows.org/) or use the version included
  with WSL.
* **Python 3.10+** – required only if you plan to run the services locally.
  The deployment uses container images, so Python is not required on your workstation.
  If you do run locally, install dependencies from the `requirements.txt` files using `pip install -r requirements.txt`.
* **Docker** – optional but useful if you want to build and test the container images yourself.
  The `azd` workflow will build images in Azure Container Registry, but a local Docker installation can help with
  troubleshooting.

In addition to the tools above, take a moment to check your **network connectivity**.
If you are behind a corporate proxy, ensure that `az` and `azd` can reach Azure endpoints.
You may need to configure proxy settings via environment variables (`HTTP_PROXY`/`HTTPS_PROXY`) or the Azure CLI config.

### Verifying your toolchain

Before diving into the lab it’s a good idea to verify that the versions of the tools on your machine meet the minimum requirements.
Run the following commands and compare the output against the versions listed below.
If you see a much older release, upgrade the tool before continuing.

```bash
# check Azure CLI version
az --version

# check Azure Developer CLI version
azd version

# check Git version
git --version

# check Python interpreter
python --version
# or
python3 --version

# check Docker (optional)
docker --version
```

At the time of writing this lab we tested with **Azure CLI 2.77+**, **Azure Developer CLI 1.17+**, **Git 2.45.4+** and **Python 3.12.9+**.
Newer versions should work fine but older releases may lack features or bug fixes.
If you encounter unexpected errors during deployment, upgrading the toolchain is often the first troubleshooting step.

### Setting up your working environment

You can complete this lab from your local workstation or from **Azure Cloud Shell**.
A local environment gives you full control over tool versions and allows offline development, while Cloud Shell runs in
Azure and comes pre‑installed with `az`, `azd` and `git`.

If you choose to work locally, ensure that you have a Bash or PowerShell terminal configured with the prerequisites listed above.
On Windows we recommend using **WSL2** with the Ubuntu distribution to provide a native Linux environment.
WSL2 reduces friction when running containerised workloads and Python scripts.
In PowerShell you can translate the Bash commands in this guide to their PowerShell equivalents.

If you prefer Cloud Shell, open [https://shell.azure.com](https://shell.azure.com) in your browser and select **Bash**.
Cloud Shell provisions a temporary VM with the Azure CLI, Developer CLI and Git preinstalled.
Because Cloud Shell uses an Azure Files share for persistent storage, cloning large repositories can take time; consider
downloading a ZIP archive instead.

### Managing environment variables and secrets

Throughout the lab you will notice that configuration values are supplied via environment variables.
When you run `azd up` the CLI creates an **environment** (for example, `prod`, `dev` or your own custom name) and stores outputs in a `.env` file under the `.azure` directory.
You can inspect or modify these values using `azd env list`, `azd env get` and `azd env set`.
The environment file contains **endpoint URLs**, **Cosmos DB keys**, and other secrets.
Do not commit this file to source control.

If you wish to deploy multiple copies of the application (e.g. dev, test and prod), simply create additional environments using `azd env new`.
Each environment will have its own resource group, Cosmos DB account and Container Apps environment.
This isolation allows you to experiment without impacting other deployments.

### Windows Users

If you are using Windows, it is recommended to enable the **Windows Subsystem for Linux (WSL2)** and use the Ubuntu distribution.
Follow Microsoft’s documentation to install WSL2.
All commands in this lab can be executed from a Bash shell within WSL or PowerShell.

### Region and Quota Considerations

Cosmos DB and Container Apps are available in most Azure regions, but some regions offer better latency or cost.
For a smooth experience, select a region that is geographically close to you (e.g. `eastus`, `westeurope` or
`japaneast`) and confirm that the Cosmos DB **NoSQL** API and Container Apps are available there.
You can view service availability using the Azure Portal or CLI:

```bash
az account list-locations --query "[].{Name:name, CosmosDB:isPreview?}" -o table
```

In addition, verify that your subscription has sufficient **request units (RU/s) quota** for Cosmos DB.
Free and trial subscriptions have limited throughput allocations.
You can view and request quota increases via the Azure Portal under *Subscriptions* → *Usage + quotas*.

If you plan to extend the lab with AI/ML features, ensure your subscription also has access to Azure OpenAI resources.
This project does not require OpenAI, but Cosmos DB Change Feed patterns are often combined with AI models for streaming analytics.

## Understanding Azure Cosmos DB account types

Although the lab uses a single‑region, manually provisioned Cosmos DB account for simplicity, production systems require careful selection of account capabilities and pricing models.
Azure Cosmos DB offers several options:

* **Free tier accounts** provide up to **1000 RU/s** and **25 GB** of storage at no cost for one account per subscription.
  Free tier is ideal for personal projects and early development, but it cannot be converted to serverless or multi‑region later.
  Provisioning multiple free tier accounts in the same subscription is not supported.
* **Provisioned throughput accounts** let you reserve a fixed number of **Request Units per second (RU/s)** on a database or container.
  This model delivers predictable performance.
  You can scale throughput up or down at runtime using the Azure Portal or CLI commands such as `az cosmosdb sql container throughput update`.
  For high‑volume workloads, database‑level throughput shared across containers simplifies capacity planning.
* **Autoscale accounts** automatically adjust RU/s between a minimum and maximum value based on consumption.
  Autoscale is well suited for bursty workloads like IoT or gaming traffic because you pay for peak consumption only when needed.
  The minimum RU/s is typically 10 % of the maximum, so plan accordingly when specifying `maxThroughput` in the ARM/Bicep template.
* **Serverless accounts** charge only for RU/s actually consumed by requests.
  There is no pre‑allocation of throughput, and storage is limited to **5 GB** per container.
  Serverless can be cost effective for intermittent workloads or prototypes, but it does not support multi‑region replication or guaranteed high availability.

When deciding on a deployment model, factor in latency, availability, and cost.
Multi‑region accounts replicate your data across selected Azure regions, providing near real‑time failover and up to **99.999 %** availability.
You pay for each replica’s throughput and storage, so cross‑region read patterns and consistency levels (strong vs eventual) should be evaluated early in the design.

## Network planning and security

Corporate networks may restrict outbound traffic or require private connectivity.
Here are several network and security options you may encounter when deploying Cosmos DB and Container Apps:

* **Private endpoints** – You can create a private endpoint for your Cosmos DB account within a virtual network (VNet).
  This maps a private IP address to the Cosmos DB endpoint, ensuring that traffic remains on the corporate network.
  Configure DNS accordingly so that the FQDN (`cosmosaccount.documents.azure.com`) resolves to the private IP.
* **IP firewall rules** – If you keep public access enabled, restrict inbound traffic by specifying allowed IPv4 ranges.
  Use `az cosmosdb update --ip-range-filter` to update the firewall via CLI.
* **Proxy configurations** – Within corporate proxies, set `HTTP_PROXY` and `HTTPS_PROXY` environment variables so that CLI tools and Docker can reach Azure endpoints.
  In WSL you may need to modify `/etc/apt/apt.conf.d` or use `proxychains` for system package managers.
* **Customer‑managed keys (CMK)** – By default Cosmos DB uses Microsoft‑managed encryption keys.
  For stricter compliance you can configure a Key Vault key as the encryption root.
  This adds operational overhead because you must rotate and monitor the key.

Consider performing a simple connectivity check before running `azd`:

```bash
# check outbound HTTPS connectivity to Azure service endpoints
curl -I https://management.azure.com
```

If the response is blocked by a proxy or firewall, consult your network team to obtain the necessary egress permissions.

## Cost considerations

Cloud resources accrue charges even when idle.  To avoid surprises:

* **Right‑size throughput** – For this workshop the default 4000 RU/s for the database is over‑provisioned.
  Feel free to lower the value via the `main.parameters.json` file when creating your own lab.
* **Disable diagnostic logs when not needed** – Azure Monitor can collect metrics and logs from Container Apps and Cosmos DB, but ingestion into Log Analytics is billable.
  Unless you explicitly require persistent logs, configure `destination: none` for `appLogsConfiguration` or point logs to an existing workspace.
* **Delete unused resources promptly** – At the end of the lab run `azd down` or manually delete the resource group.
  This cleans up the Cosmos DB account, registry and Container Apps environment.

## Tools for local development and testing

While the lab leverages Azure services, you can also experiment locally:

* **Cosmos DB emulator** – The emulator runs on Windows or Linux via Docker and provides a fully functional NoSQL endpoint with Change Feed.
  Use it for unit tests and offline development.
  Be sure to set the connection mode to `Gateway` when connecting from Linux.
* **Dev tunnels and port forwarding** – Tools such as `ngrok` or `Azure Dev Tunnels` let you expose your local visualiser or API to colleagues for demos.
  This is helpful when running the lab from a laptop behind a firewall.
* **Version control best practices** – Use a Git branching strategy (e.g. feature branches) and protect your `main` branch with pull requests.
  Integrate linting and unit tests into your workflow via GitHub Actions or Azure DevOps pipelines.
  The `infra` folder demonstrates how Bicep modules can be iteratively developed and tested with `azd`.

By planning for capacity, security and cost up front, you’ll avoid common pitfalls and create a smoother experience as you work through this hands‑on lab.

### Exploring advanced Cosmos DB account features

In this lab you will provision a **single region Cosmos DB account** using the recommended defaults (session consistency and provisioned throughput).
In production scenarios you might choose to enable additional features that improve global resilience and performance:

* **Multiple write regions** – Cosmos DB can automatically replicate data across two or more regions and accept writes into any region, transparently handling conflict resolution.
  This is valuable for IoT solutions where devices are distributed across regions and latency must be minimised.
  You configure multi‑region replication via the Azure portal or Bicep by specifying the `locations` array.
* **Autopilot (autoscale) provisioned throughput** – Instead of specifying a fixed RU/s value, autoscale mode automatically adjusts throughput between a minimum and maximum.
  This can simplify capacity planning for workloads with spiky traffic.
  You can enable autoscale at the database or container level in Bicep by using the `autoscaleSettings` property.
* **Dedicated gateway and private endpoints** – Production systems often route all Cosmos DB traffic through a dedicated gateway (for predictable latency and network isolation) and restrict access via **private endpoints**.
  To follow along locally you may use the public endpoint, but it’s worth familiarising yourself with the networking options described in the [Cosmos DB networking](https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-configure-network) guidance.

### Understanding distributed infrastructure for IoT

IoT and telemetry applications place special demands on your infrastructure beyond simple CRUD operations.
As you progress through this lab, keep the following considerations in mind:

* **Intermittent connectivity** – Field devices might be offline or only intermittently connected.
  Design your ingestion pipeline to handle bursts of events when devices reconnect and to buffer locally when connectivity drops.
  Azure IoT Hub provides built‑in device queues that integrate with Cosmos DB via Change Feed.
* **Time series modelling** – Sensor values often arrive out of order or with varying cadence.
  Partitioning by `sensor_id` combined with composite indexes on timestamp fields allows you to efficiently query recent history while still supporting scalable ingestion.
  Later sections of the lab explore how summariser uses a sliding window over the last ten readings.
* **Edge analytics** – In some deployments you may perform initial aggregation at the edge (e.g. computing local averages) and then forward the reduced dataset to the cloud.
  The same Change Feed patterns you learn in this lab can be reused in edge computing scenarios where a local IoT Edge module writes to an on‑premises Cosmos DB instance.

By exploring these advanced scenarios early, you will be better prepared to adapt the core concepts from this lab to real‑world projects.
