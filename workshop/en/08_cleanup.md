# 8. Cleanup and Summary

## Cleaning Up Azure Resources

When you are finished with the lab, it is important to delete the　resources you created to avoid unexpected charges.  The **Azure　Developer CLI** makes cleanup simple:

```bash
azd down
```

This command removes the resource group created during provisioning and　all associated resources (Cosmos DB account, Container Apps, Container　Registry, etc.).
You can also delete the resource group manually via　the Azure Portal or `az group delete --name <resource-group>`.

When running hands‑on labs in a sandbox or personal subscription,　proactive cleanup is important to avoid unnecessary charges.
Cosmos DB　accounts and Container Apps incur costs even when idle.
If you plan to　continue experimenting, you can keep the resource group but scale down　the Container Apps to zero replicas and lower the Cosmos DB RU/s to　100.
Use `az containerapp revision set-inactive` to disable revisions　and `az cosmosdb sql database throughput update` to adjust RU/s.

To check which resources were created by the lab before deletion, run:

```bash
az resource list --resource-group <resource-group> -o table
```

This lists all resources and their types.
You can delete individual　resources if you wish to retain some parts (for example, keep the　Cosmos DB account but remove Container Apps).
Remember that you will　continue to incur storage charges for the database even if no　applications are using it.

## Summary

In this hands‑on lab you learned how to:

* Use **Azure Cosmos DB Change Feed** to process data incrementally　without scanning entire containers.
* Implement a **generator** service that writes IoT‑like readings at random intervals.
* Build a **summariser** that reads the Change Feed, computes per‑sensor statistics over the last 10 readings and writes them back to Cosmos DB.
* Deploy a **visualiser** that queries aggregated data and displays responsive plots in a browser.
* Provision and deploy resources using **Bicep** templates and the **Azure Developer CLI**.

We hope this demo inspires you to explore more advanced patterns such as　event sourcing, materialised views and multi‑region replication using the　Change Feed.
Feel free to extend the codebase with your own sensors,　analytics or visualisation tools.
Happy building!

## Next Steps and Further Exploration

Now that you have completed the lab, here are some ideas to deepen your　understanding and challenge yourself:

* **Experiment with larger datasets** – increase the number of sensors or the frequency of events.
  Observe how throughput and latency change, and adjust RU/s and scaling settings accordingly.
  Use Azure　Monitor to view RU consumption and container CPU/memory usage.
* **Add new aggregates** – modify the summariser to compute rolling percentiles, variance or domain‑specific metrics.
  You could write these results to a new container and visualise them using an additional dashboard.
  Experiment with window sizes other than 10.
* **Integrate Azure Functions or Logic Apps** – trigger actions based on summary values (e.g. send an alert when temperature exceeds a threshold).
  This demonstrates how to connect Cosmos DB to other Azure services via the Change Feed.
  Functions handle checkpointing automatically, simplifying your code.
* **Enable multi‑region replication** – configure the Cosmos DB account with a secondary region and test failover.
  Learn how the Change Feed behaves in a globally distributed setup and how to control consistency levels across regions.

Exploring these paths will give you confidence in building reliable,　event‑driven systems on Azure and help you apply these patterns to your　own applications.

## Advanced Cleanup and Governance

While this lab deletes resources at the resource group level, real　deployments benefit from more granular governance:

* **Tagging and cost management** – Apply tags like `Project=CosmosChangeFeed` and `Owner=<yourname>` to all resources  in your Bicep templates.
  This simplifies cost tracking in Azure Cost Management.
  Automate budget alerts to notify you when monthly spend exceeds thresholds.
* **Resource locks and policies** – Use `ReadOnly` or `Delete` locks to prevent accidental modification of critical resources (e.g. Cosmos DB accounts).
  Azure Policy can enforce naming patterns, TLS requirements or allowed SKUs to maintain compliance across environments.
* **Soft delete and backups** – Cosmos DB offers a retention period for deleted data via the **continuous backup** feature.
  Enable it if you need to recover from accidental deletions.
  For Container Apps, maintain image version history in ACR and set retention policies.
* **Automated teardown scripts** – Use scripts (PowerShell, Bash or azd hooks) to deallocate unused resources regularly.
  For example, schedule a nightly job that runs `azd down` on dev environments to avoid unexpected charges.

## Next Steps and Learning Resources

To continue your learning journey, explore the following topics:

* **Serverless PostgreSQL with AI** – The Agentic Shop workshop demonstrates how to build a multi‑agent orchestrator that queries PostgreSQL with vector search and calls OpenAI models.
  Combining this with Cosmos DB Change Feed pipelines enables hybrid transactional/analytical processing.
* **Real‑time dashboards with Power BI** – Use Power BI’s direct query connector for Cosmos DB or ingest Change Feed into Azure Synapse Analytics to build interactive reports and dashboards.
* **Event grid and durable functions** – Connect the Change Feed to Event Grid and orchestrate complex workflows using Durable Functions.
  Implement compensating actions, sagas and long‑running workflows.
* **Chaos engineering** – Test your system’s resilience by injecting faults into Cosmos DB, network latency or Container App crashes.
  Use frameworks like **chaos‑mesh** or custom scripts to validate retry logic and scaling behaviour.

These next steps will help you evolve your solution into a fully　featured, resilient architecture capable of meeting enterprise　requirements.
