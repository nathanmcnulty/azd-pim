param environmentName string
param location string
param pollingSchedule string
param pollingLookbackMinutes int
param pollingSendInitialLookback bool
@secure()
param teamsWebhookUrl string
param tags object = {}

var suffix = uniqueString(subscription().id, resourceGroup().id, environmentName)

module pollerHost '../vendor/Azd.FlexScheduledPoller/flex-scheduled-poller-host.bicep' = {
  name: 'pim-notification-poller-host'
  params: {
    storageAccountName: take('stpimpoll${suffix}', 24)
    functionPlanName: 'plan-pim-poll-${suffix}'
    functionAppName: take('func-pim-poll-${suffix}', 60)
    location: location
    environmentName: environmentName
    serviceName: 'pim-notification-poller'
    deploymentContainerName: 'function-releases'
    stateContainerName: 'pim-state'
    deadLetterContainerName: 'pim-dead-letter'
    applicationSettings: {
      AZD_PIM_TEAMS_WEBHOOK_URL: teamsWebhookUrl
      AZURE_TENANT_ID: tenant().tenantId
      AZURE_SUBSCRIPTION_ID: subscription().subscriptionId
      AZURE_RESOURCE_GROUP: resourceGroup().name
      AZD_PIM_POLLING_SCHEDULE: pollingSchedule
      AZD_PIM_POLLING_LOOKBACK_MINUTES: string(pollingLookbackMinutes)
      AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK: string(pollingSendInitialLookback)
    }
    storageAccountSettingAliases: [
      'AZD_PIM_STORAGE_ACCOUNT_NAME'
    ]
    stateContainerSettingAliases: [
      'AZD_PIM_STATE_CONTAINER'
    ]
    instanceMemoryMB: 512
    maximumInstanceCount: 1
    blobDeleteRetentionDays: 7
    tags: tags
  }
}

output functionAppName string = pollerHost.outputs.functionAppName
output functionAppResourceId string = pollerHost.outputs.functionAppResourceId
output functionAppPrincipalId string = pollerHost.outputs.functionAppPrincipalId
output storageAccountName string = pollerHost.outputs.storageAccountName
