// ------------------------------------------------------------------------------------------
//  Main Bicep template for the Cosmos DB change feed demo
//
//  This template provisions the core infrastructure required to run a simple
//  change‑feed demo with Azure Cosmos DB and Azure Container Apps.  It creates a
//  Cosmos DB account (for API for NoSQL), a database with three containers, an
//  Azure Container Registry, and an Azure Container Apps environment.  It also
//  exposes a handful of outputs so that downstream modules (such as the
//  generator and summariser container apps) can discover connection
//  information at deploy time.  Resource names are derived from the
//  environment name to ensure uniqueness across environments.

targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment.  This value is used as a prefix for resources and must be unique per subscription.')
param name string

@minLength(1)
@description('Primary location for all resources')
@allowed([
  'australiaeast'
  'brazilsouth'
  'canadaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'koreacentral'
  'northcentralus'
  'norwayeast'
  'polandcentral'
  'spaincentral'
  'southafricanorth'
  'southcentralus'
  'southindia'
  'swedencentral'
  'switzerlandnorth'
  'uaenorth'
  'uksouth'
  'westeurope'
  'westus'
  'westus3'
])
@metadata({ azd: { type: 'location' } })
param location string

// Derive a deterministic unique suffix for resource naming using the subscription ID and environment name.  The uniqueString
// function produces a 13‑character alphanumeric string that can be safely concatenated into resource names.
var uniqueSuffix = toLower(uniqueString(resourceGroup().id, name))

// Construct a base prefix for all resources.  We remove dashes from the environment name to avoid invalid characters in
// account names (such as Cosmos DB account names) and append the unique suffix.
var basePrefix = toLower(replace(name, '-', ''))
var prefix = '${basePrefix}-${uniqueSuffix}'

// Container App names must be 2-32 characters, consist of lower case alphanumeric
// characters or '-', start with a letter and end with an alphanumeric character. The
// generated prefix can exceed this limit when combined with service suffixes (for
// example "-generator"). To avoid validation errors, compute a shortened prefix for
// container apps and append a brief suffix. Each shortened prefix is limited to
// 22 characters and then concatenated with '-gen' or '-sum' to produce names
// well under the 32 character maximum. We use substring() to safely trim the
// prefix without splitting on a hyphen mid-string.
// Compute a safe prefix for container app names. The substring length must not
// exceed the length of the input string, otherwise an InvalidTemplate error will
// occur. We use the min() function to clamp the desired length to the length of
// the generated prefix. The result is then used to construct shortened app
// names.
var containerAppPrefixLen = min(length(prefix), 22)
var containerAppPrefix = substring(prefix, 0, containerAppPrefixLen)
var generatorAppName = toLower('${containerAppPrefix}-gen')
var summariserAppName = toLower('${containerAppPrefix}-sum')

// The visualizer container app exposes an HTTP endpoint for viewing
// summary graphs.  Compute a shortened name using the same prefix logic
// and append '-vis'.  This ensures the name stays under the 32
// character limit for Container Apps.  See variable definitions above
// for details about the containerAppPrefix and length clamping.
var visualizerAppName = toLower('${containerAppPrefix}-vis')

// The Grafana container app provides a dashboard interface for viewing both raw
// sensor readings and aggregated statistics.  Compute a shortened name using
// the same prefix logic and append '-graf'.  This keeps the total length
// under 32 characters, which is required for Container Apps.

// Cosmos DB account name must be globally unique and between 3 and 44 characters.  Build the name using the
// concat() function rather than string concatenation.  This avoids BCP045 errors around '+' operators.
// We prepend the fixed string "cosmos" to the deterministic unique suffix.  The final value is converted
// to lowercase to satisfy Cosmos DB naming rules (3‑44 lowercase alphanumeric characters).
var cosmosAccountName = toLower(concat('cosmos', uniqueSuffix))

// Azure Container Registry name must be between 5 and 50 characters and contain only alphanumeric characters.
// Construct the ACR name by concatenating the dashless basePrefix, uniqueSuffix and the fixed suffix "acr".  The
// value is forced to lowercase since registry names are case insensitive and must be lowercase.
var containerRegistryName = toLower(concat(basePrefix, uniqueSuffix, 'acr'))

// Name of the Container Apps environment.  Compose this from the prefix and a suffix.  Using the string
// interpolation syntax here is safe because the prefix itself is already validated.  The environment name
// includes the hyphen to separate it from the prefix, which is permitted for managed environment names.
var containerAppsEnvironmentName = '${prefix}-cae'

// Tags applied to all resources.  Expose the azd environment name for troubleshooting.
var tags = {
  'azd-env-name': name
}

// ------------------------------------------------------------------------------------------------
// Cosmos DB resources
//
// Create an Azure Cosmos DB account with a single write region.  The default consistency level is
// Session, which is a reasonable balance between throughput and latency.  Throughput on the
// database and containers is configured via manual settings on the containers themselves.

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
    // Use Session consistency for good read/write performance while maintaining monotonic reads.
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    // Enable key-based (primary key) authentication for this Cosmos DB account.  Without
    // explicitly setting disableLocalAuth to false, new accounts default to AAD-only
    // authentication which causes "Local Authorization is disabled" errors when using keys.
    disableLocalAuth: false
  }
  tags: tags
}

// The sensors database containing all containers used by the demo.  Using the parent property
// simplifies the resource name syntax.
resource sensorsDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-11-15' = {
  parent: cosmosAccount
  name: 'sensors'
  properties: {
    resource: {
      id: 'sensors'
    }
    options: {
      autoscaleSettings: {
        maxThroughput: 4000
      }
    }
  }
}

// The container that stores raw sensor readings.  Partition on /sensor_id to ensure distribution of writes
// and to minimize cross‑partition queries when summarising per sensor.
resource readingsContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  parent: sensorsDb
  name: 'readings'
  properties: {
    resource: {
      id: 'readings'
      partitionKey: {
        paths: [ '/sensor_id' ]
        kind: 'Hash'
      }
      defaultTtl: -1
    }
    options: {
      throughput: 400
    }
  }
}

// The container that stores summarised information computed by the summariser.  Partition on the id
// field since summaries are accessed by time ordering rather than key lookups.
resource summariesContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  parent: sensorsDb
  name: 'summaries'
  properties: {
    resource: {
      id: 'summaries'
      partitionKey: {
        paths: [ '/id' ]
        kind: 'Hash'
      }
      defaultTtl: -1
    }
    options: {
      throughput: 400
    }
  }
}

// The leases container used by the change feed reader to persist continuation tokens.  Partition on /id.
resource leasesContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  parent: sensorsDb
  name: 'leases'
  properties: {
    resource: {
      id: 'leases'
      partitionKey: {
        paths: [ '/id' ]
        kind: 'Hash'
      }
      defaultTtl: -1
    }
    options: {
      throughput: 400
    }
  }
}

// Retrieve the primary key for the Cosmos account.  This value will be exposed as an output to allow
// downstream services to authenticate using key‑based authentication.  Note: The listKeys function is
// evaluated at deployment time and is only permitted when run as an administrator of the account.
var cosmosKeys = listKeys(cosmosAccount.id, cosmosAccount.apiVersion)
var cosmosPrimaryKey = cosmosKeys.primaryMasterKey

// ------------------------------------------------------------------------------------------------
// Azure Container Registry
//
// Create a basic Azure Container Registry to store container images for the generator and summariser
// services.  Admin user access is enabled so that the registry credentials can be retrieved in the
// generator/summariser modules to configure image pulls.

resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: containerRegistryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
  tags: tags
}

// ------------------------------------------------------------------------------------------------
// Container Apps environment
//
// Provision a simple Container Apps environment.  To minimise required resources we disable log
// collection by setting the destination to 'none'.  The environment name is based off the prefix to
// guarantee uniqueness.

resource containerEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerAppsEnvironmentName
  location: location
  // Use an empty properties object to satisfy the managed environments schema.  Omitting
  // appLogsConfiguration entirely applies the default Azure Monitor logging configuration.
  properties: {}
  tags: tags
}

// ------------------------------------------------------------------------------------------------
// Deploy container apps for the generator and summariser services
//
// Instead of referencing external modules, the container app resources are defined directly
// in this template.  Each app has its own user‑assigned identity and uses the ACR
// credentials to pull the corresponding image.  Environment variables are set to
// configure the Cosmos DB connection and other runtime parameters.  The Cosmos DB
// primary key is injected via a secret reference for improved security.

var registryLoginServer = acr.properties.loginServer

// Retrieve ACR credentials once for both apps
var acrCreds = listCredentials(acr.id, '2019-05-01')
var acrUsername = acrCreds.username
var acrPassword = acrCreds.passwords[0].value

// Generator user‑assigned identity
resource generatorIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-generator-id'
  location: location
}

// Generator container app
resource generatorApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: generatorAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'generator' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${generatorIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      registries: [
        {
          server: registryLoginServer
          username: acrUsername
          passwordSecretRef: 'acr-password'
        }
      ]
      // Only the ACR password secret is required.  Cosmos DB authentication uses a
      // managed identity instead of a key, so we do not include a cosmos-key secret.
      secrets: [
        {
          name: 'acr-password'
          value: acrPassword
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'generator'
          // Use a publicly available placeholder image during the provision step.  The
          // actual service image will be supplied during `azd deploy` when the
          // container is rebuilt and pushed to the registry.  Without a valid
          // image reference here, the Container App resource fails to provision
          // because the image tag doesn't exist yet in ACR.
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          env: [
            {
              name: 'COSMOSDB_ENDPOINT'
              value: cosmosAccount.properties.documentEndpoint
            }
            {
              name: 'AZURE_CLIENT_ID'
              // Use the clientId of the user‑assigned identity so DefaultAzureCredential
              // picks it up when acquiring a token for Cosmos DB.
              value: generatorIdentity.properties.clientId
            }
            {
              name: 'DATABASE_NAME'
              value: 'sensors'
            }
            {
              name: 'READINGS_CONTAINER'
              value: 'readings'
            }
          ]
          resources: {
            // CPU must be expressed as a string because Bicep only supports integer
            // literals for numeric types. Passing the value as a string ensures
            // the underlying ARM template receives a valid fractional CPU value.
            cpu: '0.25'
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// Summariser user‑assigned identity
resource summariserIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-summariser-id'
  location: location
}

// Visualizer user‑assigned identity
//
// This identity is used by the visualizer container app to authenticate to
// Azure Cosmos DB using DefaultAzureCredential.  It is assigned the built‑in
// data reader role on the Cosmos DB account below.
resource visualizerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-visualizer-id'
  location: location
}

// Summariser container app
resource summariserApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: summariserAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'summariser' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${summariserIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      registries: [
        {
          server: registryLoginServer
          username: acrUsername
          passwordSecretRef: 'acr-password'
        }
      ]
      // Only the ACR password secret is required.  Cosmos DB authentication uses a
      // managed identity instead of a key, so we do not include a cosmos-key secret.
      secrets: [
        {
          name: 'acr-password'
          value: acrPassword
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'summariser'
          // Use a publicly available placeholder image during the provision step.  The
          // actual service image will be supplied during `azd deploy` when the
          // container is rebuilt and pushed to the registry.
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          env: [
            {
              name: 'COSMOSDB_ENDPOINT'
              value: cosmosAccount.properties.documentEndpoint
            }
            {
              name: 'AZURE_CLIENT_ID'
              // Use the clientId of the user‑assigned identity so DefaultAzureCredential
              // picks it up when acquiring a token for Cosmos DB.
              value: summariserIdentity.properties.clientId
            }
            {
              name: 'DATABASE_NAME'
              value: 'sensors'
            }
            {
              name: 'READINGS_CONTAINER'
              value: 'readings'
            }
            {
              name: 'SUMMARIES_CONTAINER'
              value: 'summaries'
            }
            {
              name: 'LEASES_CONTAINER'
              value: 'leases'
            }
            {
              name: 'BATCH_INTERVAL_SECONDS'
              value: '1'
            }
          ]
          resources: {
            // CPU must be expressed as a string because Bicep only supports integer
            // literals for numeric types. Passing the value as a string ensures
            // the underlying ARM template receives a valid fractional CPU value.
            cpu: '0.25'
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// Visualizer container app
//
// The visualizer service exposes an HTTP endpoint that renders a plot of
// summarised sensor data in a browser.  It authenticates to Cosmos DB using
// a user‑assigned managed identity and retrieves data from the summaries
// container.  Ingress is enabled so that the app is accessible via the
// Internet.  A placeholder image is specified during provisioning; the
// actual image will be pushed to ACR and applied when `azd deploy` is
// executed.
resource visualizerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: visualizerAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'visualizer' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${visualizerIdentity.id}': {}
    }
  }
      properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      // Enable external ingress on port 8080.  The visualizer Flask app
      // listens on this port and serves a PNG plot.  No Grafana service is used.
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      registries: [
        {
          server: registryLoginServer
          username: acrUsername
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acrPassword
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'visualizer'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          env: [
            {
              name: 'COSMOSDB_ENDPOINT'
              value: cosmosAccount.properties.documentEndpoint
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: visualizerIdentity.properties.clientId
            }
            {
              name: 'DATABASE_NAME'
              value: 'sensors'
            }
            {
              name: 'SUMMARIES_CONTAINER'
              value: 'summaries'
            }
            {
              name: 'POLL_SECONDS'
              value: '10'
            }
            {
              name: 'POINTS'
              value: '120'
            }
            {
              name: 'PORT'
              value: '8080'
            }
          ]
          resources: {
            // Allocate resources similar to other services.  No Grafana overhead.
            cpu: '0.25'
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}


// ------------------------------------------------------------------------------------------------
// Role assignments for managed identities
//
// Grant data plane permissions on the Cosmos DB account to the generator and summariser
// container apps via their user‑assigned identities.  Without these assignments the
// managed identities cannot access the database.  The built‑in "Cosmos DB Built‑in
// Data Contributor" role has the GUID 00000000-0000-0000-0000-000000000002.  We scope
// the assignment to the entire account using the relative scope '/'.

resource generatorRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-11-15' = {
  parent: cosmosAccount
  // The name of a role assignment resource must be determinable at compilation time.
  // Generate a deterministic GUID using only compile‑time values (the Cosmos account
  // name and a static suffix).  Avoid using principalId in the name expression because
  // that value isn't available until after deployment, which causes BCP120 errors.
  name: guid(cosmosAccount.name, 'generatorDataContributor')
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    // Scope the assignment to the entire account using its fully qualified resource ID.  Using
    // cosmosAccount.id avoids parsing errors when supplying a relative scope such as '/'.
    scope: cosmosAccount.id
    principalId: generatorIdentity.properties.principalId
  }
}

resource summariserRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-11-15' = {
  parent: cosmosAccount
  // Generate a deterministic GUID for the summariser role assignment using only compile‑time
  // values (the Cosmos account name and a static suffix).  Avoid principalId here to
  // satisfy Bicep's compile‑time evaluation requirement for resource names.
  name: guid(cosmosAccount.name, 'summariserDataContributor')
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    // Scope the assignment to the entire account using its fully qualified resource ID.
    scope: cosmosAccount.id
    principalId: summariserIdentity.properties.principalId
  }
}

// Grant the visualizer identity read-only data plane access to Cosmos DB.  The
// built‑in Cosmos DB Data Reader role allows query and read operations but
// prohibits writes.  Use a deterministic GUID based solely on the Cosmos
// account name and a static suffix to satisfy Bicep compile‑time
// requirements for the resource name.
resource visualizerRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-11-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.name, 'visualizerDataReader')
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001'
    scope: cosmosAccount.id
    principalId: visualizerIdentity.properties.principalId
  }
}

// ------------------------------------------------------------------------------------------------
// Outputs
//
// The values below are surfaced through azd as environment variables.  They allow the services to
// discover how to connect to Cosmos DB, the container registry and the container apps environment.

@description('Cosmos DB account endpoint')
output COSMOSDB_ENDPOINT string = cosmosAccount.properties.documentEndpoint

@description('Cosmos DB primary key')
@secure()
output COSMOSDB_KEY string = cosmosPrimaryKey

@description('Cosmos DB database name used by the demo')
output COSMOS_DATABASE_NAME string = 'sensors'

@description('Cosmos DB raw readings container name')
output COSMOS_READINGS_CONTAINER string = 'readings'

// The client IDs of the user‑assigned identities for generator and summariser.  These
// values are used by DefaultAzureCredential to select the correct managed identity
// when the applications authenticate to Azure Cosmos DB.  Exposing them as
// outputs makes them available as environment variables via azd.
@description('Client ID of the generator user‑assigned identity')
output GENERATOR_CLIENT_ID string = generatorIdentity.properties.clientId

@description('Client ID of the summariser user‑assigned identity')
output SUMMARISER_CLIENT_ID string = summariserIdentity.properties.clientId

@description('Cosmos DB summarised data container name')
output COSMOS_SUMMARIES_CONTAINER string = 'summaries'

@description('Cosmos DB leases container name')
output COSMOS_LEASES_CONTAINER string = 'leases'

@description('Azure Container Apps environment name')
output AZURE_CONTAINER_ENVIRONMENT_NAME string = containerEnv.name

@description('Azure Container Registry login server (FQDN)')
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.properties.loginServer

@description('Azure Container Registry resource name')
output AZURE_CONTAINER_REGISTRY_NAME string = acr.name

// The client ID of the visualizer user‑assigned identity.  This is exposed as
// an output so that azd can inject it into the visualizer service via
// environment variables.
@description('Client ID of the visualizer user‑assigned identity')
output VISUALIZER_CLIENT_ID string = visualizerIdentity.properties.clientId

// Base URL of the visualizer service.  This output concatenates the
// service's fully qualified domain name (FQDN) with the https scheme.  It
// is consumed by the Grafana container app via an environment variable so
// that it can query the visualizer's JSON API endpoints.
@description('Base URL of the visualizer service (Grafana UI)')
output VISUALIZER_BASE_URL string = 'https://${visualizerApp.properties.configuration.ingress.fqdn}'