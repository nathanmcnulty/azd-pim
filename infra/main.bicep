targetScope = 'resourceGroup'

@description('Azure Developer CLI environment name.')
param environmentName string

@description('Azure region for optional workflow resources.')
param location string = resourceGroup().location

@allowed([
  'plan'
  'enforced'
])
@description('Core azd-pim deployment mode. Optional Azure resources deploy only in enforced mode.')
param pimMode string = 'plan'

@allowed([
  'none'
  'sentinel'
  'polling'
])
@description('Optional Teams notification event source.')
param notificationMode string = 'none'

@secure()
@description('Teams Workflow webhook URL used by either notification implementation.')
param teamsWebhookUrl string = ''

@description('Existing Log Analytics or Microsoft Sentinel workspace resource ID.')
param sentinelWorkspaceResourceId string = ''

@description('Azure location of the existing Sentinel or Log Analytics workspace.')
param sentinelWorkspaceLocation string = ''

@description('NCRONTAB schedule for Graph polling.')
param pollingSchedule string = '0 */5 * * * *'

@minValue(5)
@maxValue(1440)
@description('Rolling Graph audit lookback window. Recent event IDs provide deduplication.')
param pollingLookbackMinutes int = 30

@description('Send events found during the first polling lookback. False avoids an initial notification flood.')
param pollingSendInitialLookback bool = false

@description('Deploy the optional PIM session-revocation custom extension endpoint.')
param enableSessionRevocation bool = false

@allowed([
  'deny'
  'approve'
])
@description('PIM evaluation outcome if Microsoft Graph session revocation fails.')
param revocationFailureBehavior string = 'deny'

@description('Optional existing Azure Monitor action group resource ID for session-revocation workflow action failures.')
param revocationAlertActionGroupResourceId string = ''

var deployOptionalResources = pimMode == 'enforced'
var deploySentinelNotifications = deployOptionalResources && notificationMode == 'sentinel'
var deployPollingNotifications = deployOptionalResources && notificationMode == 'polling'
var deploySessionRevocation = deployOptionalResources && enableSessionRevocation
var tags = {
  'azd-env-name': environmentName
  'azd-pim-managed': 'true'
}

module sentinelNotifications 'modules/sentinel-notifications.bicep' = if (deploySentinelNotifications) {
  name: 'sentinel-notifications'
  params: {
    environmentName: environmentName
    location: location
    workspaceResourceId: sentinelWorkspaceResourceId
    workspaceLocation: sentinelWorkspaceLocation
    teamsWebhookUrl: teamsWebhookUrl
    tags: tags
  }
}

module pollingNotifications 'modules/polling-function.bicep' = if (deployPollingNotifications) {
  name: 'polling-notifications'
  params: {
    environmentName: environmentName
    location: location
    pollingSchedule: pollingSchedule
    pollingLookbackMinutes: pollingLookbackMinutes
    pollingSendInitialLookback: pollingSendInitialLookback
    teamsWebhookUrl: teamsWebhookUrl
    tags: tags
  }
}

module sessionRevocation 'modules/revocation-logic-app.bicep' = if (deploySessionRevocation) {
  name: 'session-revocation'
  params: {
    environmentName: environmentName
    location: location
    failureBehavior: revocationFailureBehavior
    alertActionGroupResourceId: revocationAlertActionGroupResourceId
    tags: tags
  }
}

output AZD_PIM_NOTIFICATION_MODE string = notificationMode
output AZD_PIM_POLLING_FUNCTION_NAME string = deployPollingNotifications ? pollingNotifications!.outputs.functionAppName : ''
output AZD_PIM_POLLING_FUNCTION_RESOURCE_ID string = deployPollingNotifications ? pollingNotifications!.outputs.functionAppResourceId : ''
output AZD_PIM_POLLING_FUNCTION_PRINCIPAL_ID string = deployPollingNotifications ? pollingNotifications!.outputs.functionAppPrincipalId : ''
output AZD_PIM_SENTINEL_NOTIFICATION_LOGIC_APP_RESOURCE_ID string = deploySentinelNotifications ? sentinelNotifications!.outputs.logicAppResourceId : ''
output AZD_PIM_SENTINEL_NOTIFICATION_ALERT_RESOURCE_ID string = deploySentinelNotifications ? sentinelNotifications!.outputs.alertRuleResourceId : ''
output AZD_PIM_SENTINEL_NOTIFICATION_ACTION_GROUP_RESOURCE_ID string = deploySentinelNotifications ? sentinelNotifications!.outputs.actionGroupResourceId : ''
output AZD_PIM_REVOCATION_LOGIC_APP_NAME string = deploySessionRevocation ? sessionRevocation!.outputs.logicAppName : ''
output AZD_PIM_REVOCATION_LOGIC_APP_RESOURCE_ID string = deploySessionRevocation ? sessionRevocation!.outputs.logicAppResourceId : ''
output AZD_PIM_REVOCATION_LOGIC_APP_PRINCIPAL_ID string = deploySessionRevocation ? sessionRevocation!.outputs.logicAppPrincipalId : ''
output AZD_PIM_REVOCATION_ALERT_RESOURCE_ID string = deploySessionRevocation ? sessionRevocation!.outputs.failureAlertResourceId : ''
