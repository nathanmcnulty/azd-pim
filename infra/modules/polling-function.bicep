param environmentName string
param location string
param pollingSchedule string
param pollingLookbackMinutes int
param pollingSendInitialLookback bool
@secure()
param teamsWebhookUrl string
param tags object = {}

var suffix = uniqueString(subscription().id, resourceGroup().id, environmentName)
var storageAccountName = take('stpimpoll${suffix}', 24)
var functionPlanName = 'plan-pim-poll-${suffix}'
var functionAppName = take('func-pim-poll-${suffix}', 60)
var deploymentContainerName = 'function-releases'
var stateContainerName = 'pim-state'
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: stateContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource functionPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: functionPlanName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: union(tags, {
    'azd-service-name': 'pim-notification-poller'
  })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: storageConnectionString
        }
        {
          name: 'AZD_PIM_STORAGE_ACCOUNT_NAME'
          value: storage.name
        }
        {
          name: 'AZD_PIM_STATE_CONTAINER'
          value: stateContainer.name
        }
        {
          name: 'AZD_PIM_TEAMS_WEBHOOK_URL'
          value: teamsWebhookUrl
        }
        {
          name: 'AZURE_ENV_NAME'
          value: environmentName
        }
        {
          name: 'AZURE_TENANT_ID'
          value: tenant().tenantId
        }
        {
          name: 'AZURE_SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'AZURE_RESOURCE_GROUP'
          value: resourceGroup().name
        }
        {
          name: 'AZD_PIM_POLLING_SCHEDULE'
          value: pollingSchedule
        }
        {
          name: 'AZD_PIM_POLLING_LOOKBACK_MINUTES'
          value: string(pollingLookbackMinutes)
        }
        {
          name: 'AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK'
          value: string(pollingSendInitialLookback)
        }
      ]
    }
    functionAppConfig: {
      runtime: {
        name: 'node'
        version: '22'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 1
        instanceMemoryMB: 2048
        alwaysReady: []
      }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
    }
  }
}

resource stateBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, 'Storage Blob Data Contributor')
  scope: storage
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

output functionAppName string = functionApp.name
output functionAppResourceId string = functionApp.id
output functionAppPrincipalId string = functionApp.identity.principalId
output storageAccountName string = storage.name
