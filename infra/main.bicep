@description('The location for all resources.')
param location string = resourceGroup().location

@description('Environment name (e.g. dev, ppd)')
@allowed(['dev', 'ppd'])
param envName string

@description('Application name prefix.')
param appName string = 'azplat'

@description('Docker image for the API')
param apiImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Docker image for the Worker')
param workerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

var resourceSuffix = '${appName}${envName}${uniqueString(resourceGroup().id)}'

// 1. User Assigned Managed Identity
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'mi-${resourceSuffix}'
  location: location
}

// 2. Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: 'acr${resourceSuffix}'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false // Best practice: Use Managed Identity instead
  }
}

// Role Assignment: AcrPull for Managed Identity
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, managedIdentity.id, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// 3. Log Analytics & Application Insights
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${resourceSuffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${resourceSuffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// 4. Azure Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: 'kv-${resourceSuffix}'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true // Best practice: Use Azure RBAC for Key Vault
  }
}

// Role Assignment: Key Vault Secrets User
resource kvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentity.id, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// 5. Azure Service Bus
resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'sb-${resourceSuffix}'
  location: location
  sku: {
    name: 'Standard'
  }
}

resource sbQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBus
  name: 'workqueue'
  properties: {
    deadLetteringOnMessageExpiration: true
    maxDeliveryCount: 10
  }
}

// Role Assignment: Service Bus Data Owner
resource sbRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBus.id, managedIdentity.id, 'ServiceBusDataOwner')
  scope: serviceBus
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '090c5fc2-0c11-482a-a9e9-74d6f4370db0')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// 6. Azure Container Apps Environment
resource acaEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: 'cae-${resourceSuffix}'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// 7. API Container App
resource apiApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-api-${envName}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: managedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: apiImage
          env: [
            { name: 'KeyVaultUri', value: keyVault.properties.vaultUri }
            { name: 'ApplicationInsights__ConnectionString', value: appInsights.properties.ConnectionString }
            { name: 'ServiceBusNamespace', value: '${serviceBus.name}.servicebus.windows.net' }
            { name: 'QueueName', value: sbQueue.name }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                port: 8080
                path: '/health/live'
              }
            }
            {
              type: 'Readiness'
              httpGet: {
                port: 8080
                path: '/health/ready'
              }
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 5
      }
    }
  }
}

// 8. Worker Container App (with KEDA scaling on Service Bus)
resource workerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-worker-${envName}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      registries: [
        {
          server: acr.properties.loginServer
          identity: managedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: workerImage
          env: [
            { name: 'KeyVaultUri', value: keyVault.properties.vaultUri }
            { name: 'ApplicationInsights__ConnectionString', value: appInsights.properties.ConnectionString }
            { name: 'ServiceBusNamespace', value: '${serviceBus.name}.servicebus.windows.net' }
            { name: 'QueueName', value: sbQueue.name }
          ]
        }
      ]
      scale: {
        minReplicas: 0 // Scales to 0 when queue is empty!
        maxReplicas: 10
        rules: [
          {
            name: 'queue-scaling'
            custom: {
              type: 'azure-servicebus'
              metadata: {
                queueName: sbQueue.name
                namespace: serviceBus.name
                messageCount: '10'
              }
              identity: managedIdentity.id
            }
          }
        ]
      }
    }
  }
}

output apiFqdn string = apiApp.properties.configuration.ingress.fqdn
output acrLoginServer string = acr.properties.loginServer
