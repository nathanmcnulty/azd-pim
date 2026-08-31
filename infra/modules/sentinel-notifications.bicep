param environmentName string
param location string
param workspaceResourceId string
param workspaceLocation string
@secure()
param teamsWebhookUrl string
param tags object = {}

var suffix = uniqueString(subscription().id, resourceGroup().id, environmentName)
var logicAppName = 'pim-sentinel-notify-${suffix}'
var actionGroupName = 'pim-sentinel-notify-${suffix}'
var alertRuleName = 'pim-entra-activation-${suffix}'
var activationQuery = '''
AuditLogs
| where LoggedByService == "PIM"
| where Category == "RoleManagement"
| where OperationName == "Add member to role completed (PIM activation)"
| where Result =~ "success"
| extend Actor = coalesce(tostring(InitiatedBy.user.userPrincipalName), tostring(InitiatedBy.app.displayName), Identity)
| extend Role = tostring(TargetResources[0].displayName)
| extend ActivationEventId = coalesce(tostring(Id), tostring(CorrelationId))
| project TimeGenerated, ActivationEventId, CorrelationId = tostring(CorrelationId), Actor, Role, ResultReason
'''

resource notificationWorkflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  properties: {
    state: 'Enabled'
    parameters: {
      teamsWebhookUrl: {
        value: teamsWebhookUrl
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        teamsWebhookUrl: {
          type: 'SecureString'
        }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
            }
          }
        }
      }
      actions: {
        Post_adaptive_card_to_Teams: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '''@parameters('teamsWebhookUrl')'''
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              type: 'message'
              attachments: [
                {
                  contentType: 'application/vnd.microsoft.card.adaptive'
                  contentUrl: null
                  content: {
                    '$schema': 'http://adaptivecards.io/schemas/adaptive-card.json'
                    type: 'AdaptiveCard'
                    version: '1.4'
                    body: [
                      {
                        type: 'TextBlock'
                        text: 'Microsoft Entra PIM activation'
                        weight: 'Bolder'
                        size: 'Medium'
                      }
                      {
                        type: 'FactSet'
                        facts: [
                          {
                            title: 'Alert'
                            value: '''@{triggerBody()?['data']?['essentials']?['alertRule']}'''
                          }
                          {
                            title: 'Detected'
                            value: '''@{triggerBody()?['data']?['essentials']?['firedDateTime']}'''
                          }
                          {
                            title: 'Activation details'
                            value: '''@{string(triggerBody()?['data']?['alertContext']?['condition']?['allOf']?[0]?['dimensions'])}'''
                          }
                        ]
                      }
                    ]
                  }
                }
              ]
            }
          }
          runAfter: {}
        }
      }
      outputs: {}
    }
  }
}

module actionGroup '../vendor/Azd.AzureMonitorNotifications/logic-app-action-group.bicep' = {
  name: 'pim-sentinel-action-group'
  params: {
    actionGroupName: actionGroupName
    groupShortName: 'PIM Entra'
    logicAppResourceId: notificationWorkflow.id
    receiverName: 'PIM activation Teams workflow'
    logicAppTriggerName: 'manual'
    tags: tags
  }
}

module activationAlert '../vendor/Azd.AzureMonitorNotifications/scheduled-query-alert.bicep' = {
  name: 'pim-entra-activation-alert'
  params: {
    alertRuleName: alertRuleName
    location: workspaceLocation
    workspaceResourceId: workspaceResourceId
    actionGroupResourceId: actionGroup.outputs.actionGroupResourceId
    displayName: 'Microsoft Entra PIM activation completed'
    alertDescription: 'Sends successful Microsoft Entra PIM activations from an existing Sentinel or Log Analytics workspace to Teams.'
    query: activationQuery
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    autoMitigate: true
    dimensions: [
      {
        name: 'ActivationEventId'
        operator: 'Include'
        values: [
          '*'
        ]
      }
      {
        name: 'CorrelationId'
        operator: 'Include'
        values: [
          '*'
        ]
      }
      {
        name: 'Actor'
        operator: 'Include'
        values: [
          '*'
        ]
      }
      {
        name: 'Role'
        operator: 'Include'
        values: [
          '*'
        ]
      }
    ]
    tags: tags
  }
}

output logicAppName string = notificationWorkflow.name
output logicAppResourceId string = notificationWorkflow.id
output alertRuleResourceId string = activationAlert.outputs.alertRuleResourceId
output actionGroupResourceId string = actionGroup.outputs.actionGroupResourceId
