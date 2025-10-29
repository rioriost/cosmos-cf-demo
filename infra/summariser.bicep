// ------------------------------------------------------------------------------------------
//  Summariser Container App module
//
//  This module deploys the `summariser` Azure Container App.  Like the generator
//  module, it provisions a user‑assigned identity, retrieves credentials for
//  pulling images from an Azure Container Registry, and creates a container
//  instance that runs continuously.  All environment variables required by the
//  summariser must be provided via the `environmentVariables` parameter; this
//  includes the Cosmos DB endpoint, key, database and container names, and the
//  batch interval.  The image name supplied should include the fully qualified
//  registry server, repository, and tag.

param name string
param location string = resourceGroup().location
param tags object = {}

@description('Name of the Container Apps environment where the summariser will run')
param containerAppsEnvironmentName string

@description('Name of the Azure Container Registry used to store the container images')
param containerRegistryName string

@description('Name of the user‑assigned identity to create for the summariser')
param identityName string

@description('Service name used for tagging purposes')
param serviceName string = 'summariser'

@description('Environment variables applied to the container. Each entry must contain either a value or a secretRef.')
param environmentVariables array = []

@description('The fully qualified image name to deploy (e.g. myregistry.azurecr.io/repository:tag)')
param imageName string

// Create a user‑assigned managed identity for this service
resource webIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// Pull the admin credentials for the target Azure Container Registry
var acrCredentials = listCredentials(resourceId('Microsoft.ContainerRegistry/registries', containerRegistryName), '2019-05-01')
var registryServer = '${containerRegistryName}.azurecr.io'
var acrUsername = acrCredentials.username
var acrPassword = acrCredentials.passwords[0].value

// Deploy the container app.  The summariser reads from the Cosmos change feed and writes
// summaries back to Cosmos.  It runs as a background task and does not expose an ingress endpoint.
resource summariserApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: name
  location: location
  tags: union(tags, { 'azd-service-name': serviceName })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${webIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: resourceId('Microsoft.App/managedEnvironments', containerAppsEnvironmentName)
    configuration: {
      registries: [
        {
          server: registryServer
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
      // No ingress configuration for background service
    }
    template: {
      containers: [
        {
          name: serviceName
          image: imageName
          env: environmentVariables
          resources: {
            cpu: 0.25
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

// Outputs to support azd conventions
output SERVICE_WEB_IDENTITY_PRINCIPAL_ID string = webIdentity.properties.principalId
output SERVICE_WEB_IDENTITY_NAME string = webIdentity.name
output SERVICE_WEB_NAME string = summariserApp.name
output SERVICE_WEB_URI string = ''
output SERVICE_WEB_IMAGE_NAME string = imageName