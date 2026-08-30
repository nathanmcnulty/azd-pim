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

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: 'PIM Entra'
    enabled: true
    logicAppReceivers: [
      {
        name: 'PIM activation Teams workflow'
        resourceId: notificationWorkflow.id
        callbackUrl: listCallbackUrl('${notificationWorkflow.id}/triggers/manual', '2019-05-01').value
        useCommonAlertSchema: true
      }
    ]
  }
}

resource activationAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: alertRuleName
  location: workspaceLocation
  tags: tags
  properties: {
    displayName: 'Microsoft Entra PIM activation completed'
    description: 'Sends successful Microsoft Entra PIM activations from an existing Sentinel or Log Analytics workspace to Teams.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [
      workspaceResourceId
    ]
    criteria: {
      allOf: [
        {
          query: activationQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
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
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

output logicAppName string = notificationWorkflow.name
output logicAppResourceId string = notificationWorkflow.id
output alertRuleResourceId string = activationAlert.id
output actionGroupResourceId string = actionGroup.id
