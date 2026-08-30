param environmentName string
param location string
@allowed([
  'deny'
  'approve'
])
param failureBehavior string
param alertActionGroupResourceId string = ''
param tags object = {}

var suffix = uniqueString(subscription().id, resourceGroup().id, environmentName)
var logicAppName = 'pim-revoke-sessions-${suffix}'
var failureAlertName = 'pim-revocation-action-failed-${suffix}'
var failureOutcome = failureBehavior == 'deny' ? 'Denied' : 'Approved'
var failureReason = failureBehavior == 'deny'
  ? 'Session revocation failed, so activation was denied by policy.'
  : 'Session revocation failed, but activation was allowed by configured fail-open policy.'

resource revocationWorkflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Disabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {}
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              required: [
                'id'
                'principalId'
                'roleDefinitionId'
              ]
              properties: {
                id: {
                  type: 'string'
                }
                principalId: {
                  type: 'string'
                }
                roleDefinitionId: {
                  type: 'string'
                }
                justification: {
                  type: 'string'
                }
                action: {
                  type: 'string'
                }
              }
            }
          }
        }
      }
      actions: {
        Revoke_sign_in_sessions: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '''@concat('https://graph.microsoft.com/v1.0/users/', encodeUriComponent(triggerBody()?['principalId']), '/revokeSignInSessions')'''
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://graph.microsoft.com'
            }
            retryPolicy: {
              type: 'exponential'
              count: 2
              interval: 'PT5S'
            }
          }
          runAfter: {}
        }
        Return_approved: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            statusCode: 200
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              evaluationId: '@guid()'
              evaluationOutcome: 'Approved'
              reason: [
                'Existing sign-in sessions were revoked for the activating administrator.'
              ]
            }
          }
          runAfter: {
            Revoke_sign_in_sessions: [
              'Succeeded'
            ]
          }
        }
        Return_configured_failure_outcome: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            statusCode: 200
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              evaluationId: '@guid()'
              evaluationOutcome: failureOutcome
              reason: [
                '@concat(\'${failureReason} PIM request ID: \', coalesce(triggerBody()?[\'id\'], \'unavailable\'), \'.\')'
              ]
            }
          }
          runAfter: {
            Revoke_sign_in_sessions: [
              'Failed'
              'Skipped'
              'TimedOut'
            ]
          }
        }
      }
      outputs: {}
    }
  }
}

resource revocationFailureAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(alertActionGroupResourceId)) {
  name: failureAlertName
  location: 'global'
  tags: tags
  properties: {
    description: 'Alerts when an action in the PIM session-revocation workflow fails.'
    severity: 1
    enabled: true
    scopes: [
      revocationWorkflow.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'SessionRevocationActionFailure'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'ActionsFailed'
          metricNamespace: 'Microsoft.Logic/workflows'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: alertActionGroupResourceId
      }
    ]
  }
}

output logicAppName string = revocationWorkflow.name
output logicAppResourceId string = revocationWorkflow.id
output logicAppPrincipalId string = revocationWorkflow.identity.principalId
output failureAlertResourceId string = empty(alertActionGroupResourceId) ? '' : revocationFailureAlert!.id
