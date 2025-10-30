# 5. Deployment Guide and Verification

In this section you will deploy the demo to your own Azure subscription and verify that the services are running correctly.
The deployment steps use the **Azure Developer CLI** (`azd`) which orchestrates both infrastructure provisioning and application deployment.

## Step‑by‑Step Deployment

1. **Clone the repository** if you haven’t already:

   ```bash
   git clone https://github.com/rioriost/cosmos-cf-demo/
   cd cosmos-cf-demo
   ```

2. **Sign in to Azure** and initialise the project:

   ```bash
   az login
   azd auth login
   ```

   You will be prompted to select or create an Azure resource group.
   A resource group named `rg-cosmos-cf-demo` is created by default.

3. **Provision and deploy** the resources:

   ```bash
   azd up
   ```

   This command performs two actions:

   * **Provision** – executes the Bicep template to create a Cosmos DB account, database and containers, an Azure Container Registry and a Container Apps environment.
   * **Deploy** – builds the Docker images for `generator`, `summariser` and `visualizer`, pushes them to ACR and creates container apps.

   The process may take several minutes.
   Once complete, azd prints endpoint URLs for the deployed services.

4. **Access the visualiser**:

   Open the URL for the `visualizer` app shown in the output.
   You should see a grid of five charts representing the five sensors.
   As new summaries arrive, the charts update automatically and a red indicator  highlights the updated sensor.

5. **Monitor logs** (optional):

   To view log output from the generator or summariser, use the `az containerapp logs` command.
   For example:

   ```bash
   az containerapp logs --resource-group <resource-group> --name <app-name>
   ```

   Replace `<app-name>` with the container app name, such as `cosmoscf-demo-generator`.

6. **Explore your environment** (optional):

   After deployment, you can inspect the created resources using the Azure Portal or CLI.
   For example, list the resource group contents:

   ```bash
   az resource list --resource-group <resource-group> -o table
   ```

   Check the status and properties of your Container Apps:

   ```bash
   az containerapp show --resource-group <resource-group> --name <app-name>
   ```

   This command returns the fully qualified domain name (FQDN), identity principal ID, scaling configuration, and environment variables.
   You can verify that the managed identity has been assigned to each app and confirm that environment variables such as `COSMOSDB_ENDPOINT` are injected correctly.
   To open an interactive shell inside a running container, use:

   ```bash
   az containerapp exec --resource-group <resource-group> --name <app-name> --command sh
   ```

   This is useful for debugging network connectivity or inspecting environment variables.

## Post‑Deployment Checks

After deployment, confirm the following:

* The **Cosmos DB** account contains a database `sensors` with three containers (`readings`, `summaries`, `leases`).
  You can use the [Data Explorer](https://portal.azure.com/) to inspect items.
* The **generator** logs show that each sensor is writing records at random intervals.
* The **summariser** logs show summary statistics being written every time new readings arrive.
* The **visualiser** page displays charts with data and updates when summaries change.

If any of these checks fail, review the logs and ensure that the environment variables in `azure.yaml` are correctly configured.

## Deployment Parameters and Customisation

The steps above deploy the demo with sensible defaults, but the application and infrastructure are highly configurable.
You can tweak parameters to match your requirements:

* **Cosmos DB throughput** – In `infra/main.bicep` the `sensors` database and its containers are created with an autoscale throughput of 4000 RU/s.
  You can adjust this value or switch to manual throughput by modifying the Bicep file.
  Be aware of minimum RU per partition (10 RU/s) and cost implications.
* **Region selection** – When you run `azd up`, you are prompted to select a region.
  Choose one close to your users to minimise latency.
  If you wish to add a secondary region for disaster recovery, you can update the `main.bicep` to include a second `location` and enable multi‑region writes.
* **Container scaling** – The Bicep templates configure one replica for each Container App.
  To handle higher loads, you can modify the `scale` properties to enable autoscale based on CPU or queue length.
* **Environment variables** – `azure.yaml` maps Bicep outputs into environment variables.
  You can add your own variables (e.g. alert thresholds, sampling intervals) and reference them in your Python code.
  After modifying `azure.yaml`, run `azd deploy` to apply the changes.

To pass parameters into `azd up` at runtime, you can specify the `--location` and `--subscription` flags directly.
For example:

```bash
azd up --location westeurope --subscription <my-subscription>
```

Refer to the [Azure Developer CLI documentation](https://learn.microsoft.com/azure/developer/azure-developer-cli/reference) for the full list of options.

## Continuous Deployment and CI/CD Integration

In team settings you’ll want to automate provisioning and deployment.
`azd` includes commands to scaffold a GitHub Actions or Azure DevOps pipeline.
Run:

```bash
azd pipeline config
```

This generates workflow files in `.github/workflows` (for GitHub) or Azure DevOps YAML pipelines that perform `azd up` on pull requests and `azd deploy` on push to the main branch.
Store Azure service principal credentials as repository secrets (e.g. `AZURE_CREDENTIALS`) to allow the pipeline to authenticate.

For more control you can break the pipeline into stages: `build`, `deploy infrastructure`, `deploy services` and `cleanup`.
Use matrix strategies to deploy to multiple regions or environments simultaneously.

## Running Locally and Packaging

While Azure Container Apps is the target runtime, you can also run services locally during development.
Use `azd package` to build the container images and generate Kubernetes manifests or a docker-compose file in the `.azd` directory.
You can then run the images with Docker:

```bash
azd package
docker compose -f .azd/docker-compose.yaml up
```

Alternatively, use the **Cosmos DB Emulator** and run Python scripts directly.
Set `COSMOSDB_ENDPOINT` to the emulator URL and export a primary key.
This approach speeds up iteration when networking to Azure is slow.

## Troubleshooting Common Issues

If deployment fails or services behave unexpectedly, try the following diagnostics:

* **Bicep errors** – `azd up` will display compilation errors if your template has syntax issues or invalid resource names.
  Use `bicep build <file>` to compile locally and inspect the generated JSON.
  Pay attention to warning codes like `BCP036` (type mismatch) or `BCP045` (invalid concatenation).
* **Container build failures** – When `azd deploy` builds Docker images, check the output for missing dependencies or network timeouts.
  You can run `docker build` locally to reproduce the issue.
* **Container app startup errors** – Use `az containerapp logs --name <app> --follow` to stream logs.
  Look for exceptions in Python traceback.
  If environment variables are missing, verify that `azure.yaml` references the correct Bicep outputs.
* **Connectivity problems** – If services cannot reach Cosmos DB, ensure that the connection string or Entra credentials are correct, and that firewall rules allow traffic from the Container Apps environment.
  Use `az containerapp exec` to open a shell and run `curl` against the Cosmos endpoint.

By incorporating automated pipelines, local development workflows and robust troubleshooting practices, you’ll be better equipped to deploy and manage event‑driven applications in production.

## Advanced Bicep Techniques and Parameterisation

The provided Bicep templates are designed to be simple, but real projects often require greater flexibility.
You can extend the templates to support:

* **Reusable modules** – Break the template into separate Bicep modules for Cosmos DB, ACR and Container Apps.
  Parameters can be exposed at the module boundary with sensible defaults.
  This improves readability and encourages reuse across services.
  The Agentic Shop repo demonstrates modular Bicep patterns with separate `database.bicep`, `ai.bicep` and`container.bicep` components.
* **Conditional resources and loops** – Use the `if` keyword to deploy resources only when needed, such as enabling multi‑region replication.
  Loops (`for`) can create multiple containers or Container Apps from a single parameter array.
* **Naming conventions and tags** – Define variables for resource prefixes and suffixes, and attach tags (e.g. `Environment=Dev`) using the `tags` property.
  This helps with governance and cost allocation.
* **Role assignments** – In addition to the role assignments used for the summariser and visualiser identities, you can assign built‑in roles such as `Cosmos DB Account Reader` or custom roles.
  Use the `guid()` function to generate deterministic role assignment names.
* **Output metadata** – Export values like the visualiser FQDN, Container Apps revision ID or Cosmos account keys via `output` declarations.
  These outputs can be consumed by `azure.yaml` or your pipeline to configure downstream tasks.

## Integrating with Continuous Deployment Pipelines

Although `azd deploy` works well for interactive workflows, you can fully automate the deployment using **GitHub Actions**, **Azure Pipelines** or other CI/CD systems.
A typical pipeline might:

1. Build the container images and push them to ACR using `docker build` or `az acr build`.
2. Run Bicep validation (`az deployment sub validate`) to detect template issues without provisioning resources.
3. Deploy the infrastructure with `azd provision` or `az deployment group create`.
   Use deployment scope locks to avoid accidental changes in production.
4. Deploy the application with `azd deploy` or `az containerapp update`, targeting the specific service.
   Pass parameters via environment variables or parameter files.
5. Trigger smoke tests against the visualiser endpoint to verify end‑to‑end functionality.

The `templates` directory of the Agentic Shop workshop includes examples of pipeline YAML files that integrate `azd` with GitHub Actions.
You can adapt them to your own repository.

## Advanced Local Development Tips

For an optimal inner loop, consider the following techniques:

* **Hot‑reload development servers** – Use Flask’s `--reload` flag or FastAPI with `uvicorn --reload` to automatically restart the visualiser when code changes, speeding up iteration.
* **Python virtual environments** – Use `venv` or `conda` to create isolated environments for the generator and summariser.
  This prevents dependency conflicts and matches the container runtime.
* **Interactive debugging** – Attach a debugger (e.g. VS Code Remote – Containers or VS Code Cloud Shell) to a running
Container App via `az containerapp exec`.
  This allows you to step through code inside the container without redeploying.

By embracing these advanced techniques you can scale this lab into a professional development workflow while maintaining a rapid feedback cycle.
