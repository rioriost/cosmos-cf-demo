// ------------------------------------------------------------------------------------------
//  Generator Container App module
//
//  This module deploys the `generator` Azure Container App.  It creates a
//  dedicated user‑assigned managed identity for the app, retrieves credentials
//  from an Azure Container Registry, and configures the container app to pull
//  its image using those credentials.  The caller must supply the fully
//  qualified image name via the `imageName` parameter (for example,
//  myregistry.azurecr.io/generator:latest).  Environment variables passed in
//  via the `environmentVariables` array will be applied directly to the
//  container.

param name string
param location string = resourceGroup().location
param tags object = {}

@description('Name of the Container Apps environment where the generator will run')
param containerAppsEnvironmentName string

@description('Name of the Azure Container Registry used to store the container images')
param containerRegistryName string

@description('Name of the user‑assigned identity to create for the generator')
param identityName string

@description('Service name used for tagging purposes')
param serviceName string = 'generator'

@description('Environment variables applied to the container. Each entry must contain either a value or a secretRef.')
param environmentVariables array = []

@description('The fully qualified image name to deploy (e.g. myregistry.azurecr.io/repository:tag)')
param imageName string

// Create a user‑assigned managed identity for this service.  The identity is
// used to authenticate to the container registry.  If additional Azure
// resources require RBAC, role assignments can be created in the parent
// template.
resource webIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// Pull the admin credentials for the target Azure Container Registry.  These
// credentials are used to configure the container app registry settings.
var acrCredentials = listCredentials(resourceId('Microsoft.ContainerRegistry/registries', containerRegistryName), '2019-05-01')
var registryServer = '${containerRegistryName}.azurecr.io'
var acrUsername = acrCredentials.username
var acrPassword = acrCredentials.passwords[0].value

// Deploy the container app.  Ingress is omitted for this background service.  The
// app uses the user‑assigned identity created above and pulls its image from
// the registry using an app secret.  Minimum and maximum replicas are both
// configured to 1 to avoid accidental scaling.
resource generatorApp 'Microsoft.App/containerApps@2023-05-01' = {
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
      // No ingress is defined for the generator as it does not expose an HTTP endpoint.
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

// Outputs to support azd conventions.  These values mirror the shape of the
// previously provided template and can be referenced by downstream tasks or
// tooling but are not required for this demo.
output SERVICE_WEB_IDENTITY_PRINCIPAL_ID string = webIdentity.properties.principalId
output SERVICE_WEB_IDENTITY_NAME string = webIdentity.name
output SERVICE_WEB_NAME string = generatorApp.name
// The generator does not expose an ingress endpoint; output an empty string for URI.
output SERVICE_WEB_URI string = ''
output SERVICE_WEB_IMAGE_NAME string = imageName