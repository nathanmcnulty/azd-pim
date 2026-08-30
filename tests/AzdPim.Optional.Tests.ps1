BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Graph.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Optional.psm1') -Force
}

Describe 'revocation callback URL protection' {
    It 'retains Logic Apps routing parameters while removing only the SAS signature' {
        $callback = [uri]'https://example.logic.azure.com/workflows/abc/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=secret-value'

        $result = ConvertTo-AzdPimOAuthCallbackUrl -CallbackUri $callback

        $result | Should -Be 'https://example.logic.azure.com/workflows/abc/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0'
        $result | Should -Not -Match 'sig='
        $result | Should -Not -Match 'secret-value'
    }

    It 'fails closed when the callback lacks an API version' {
        { ConvertTo-AzdPimOAuthCallbackUrl -CallbackUri 'https://example.logic.azure.com/workflows/abc?sig=secret' } | Should -Throw '*api-version*'
    }
}

Describe 'revocation endpoint authentication' {
    It 'accepts only the PIM caller for both v1 and v2 tenant token formats' {
        $script:capturedWorkflowBody = $null
        Mock Invoke-AzdPimAzRest -ModuleName AzdPim.Optional {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{
                    location = 'westus'
                    tags = @{}
                    properties = [pscustomobject]@{
                        state = 'Disabled'
                        definition = @{
                            triggers = @{
                                manual = @{ type = 'Request'; operationOptions = 'IncludeAuthorizationHeadersInOutputs' }
                            }
                            actions = @{}
                        }
                        parameters = @{}
                    }
                }
            }
            $script:capturedWorkflowBody = $Body
        }

        Enable-AzdPimRevocationWorkflowOAuth -WorkflowResourceId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Logic/workflows/test' -TenantId '11111111-1111-4111-8111-111111111111' -Audience 'api://example/app' -ApplicationClientId '11111111-2222-3333-4444-555555555555'

        $policies = $capturedWorkflowBody.properties.accessControl.triggers.openAuthenticationPolicies.policies
        $policies.pimV2.claims | Where-Object name -eq 'azp' | Select-Object -ExpandProperty value | Should -Be '1c67c054-65c8-4f7f-92a1-eb7ba6e48627'
        $policies.pimV2.claims | Where-Object name -eq 'iss' | Select-Object -ExpandProperty value | Should -Be 'https://login.microsoftonline.com/11111111-1111-4111-8111-111111111111/v2.0'
        $policies.pimV2.claims | Where-Object name -eq 'aud' | Select-Object -ExpandProperty value | Should -Be '11111111-2222-3333-4444-555555555555'
        $policies.pimV1.claims | Where-Object name -eq 'appid' | Select-Object -ExpandProperty value | Should -Be '1c67c054-65c8-4f7f-92a1-eb7ba6e48627'
        $policies.pimV1.claims | Where-Object name -eq 'iss' | Select-Object -ExpandProperty value | Should -Be 'https://sts.windows.net/11111111-1111-4111-8111-111111111111/'
        $policies.pimV1.claims | Where-Object name -eq 'aud' | Select-Object -ExpandProperty value | Should -Be 'api://example/app'
        $capturedWorkflowBody.properties.accessControl.triggers.sasAuthenticationPolicy.state | Should -Be 'Disabled'
        $capturedWorkflowBody.properties.definition.triggers.manual.ContainsKey('operationOptions') | Should -BeFalse
    }
}

Describe 'post-approval custom extension onboarding' {
    It 'creates a post-approval extension explicitly' {
        $script:capturedExtensionBody = $null
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { @() }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            $script:capturedExtensionBody = $Body
            [pscustomobject]@{ id = 'extension-id' }
        }

        $result = Set-AzdPimRevocationCustomExtension -DisplayName 'Post approval revocation' -TargetUrl 'https://example.logic.azure.com/workflows/abc?api-version=2019-05-01' -ResourceId 'api://example/abc' -Type postApproval

        $result | Should -Be 'extension-id'
        $capturedExtensionBody.type | Should -Be 'postApproval'
        $capturedExtensionBody.resourceType | Should -Be 'entraRoles'
    }

    It 'updates an existing post-approval rule without rewriting the whole role policy' {
        $script:capturedRuleUri = $null
        $script:capturedRuleBody = $null
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{
                    rules = @(
                        [pscustomobject]@{ id = 'Approval_EndUser_Assignment'; setting = [pscustomobject]@{ isApprovalRequired = $true } },
                        [pscustomobject]@{ id = 'CustomExtension_PostApproval_EndUser_Assignment'; isEnabled = $false; customExtensionId = '' }
                    )
                }
            }
            $script:capturedRuleUri = $Uri
            $script:capturedRuleBody = $Body
        }
        $roleRules = @([pscustomobject]@{
            policyId = 'policy-id'
            role = [pscustomobject]@{ id = 'role-id'; displayName = 'AI Reader' }
        })

        $result = @(Enable-AzdPimRevocationExtensionForRoles -RoleRules $roleRules -PreApprovalCustomExtensionId 'pre-extension-id' -PostApprovalCustomExtensionId 'extension-id')

        $result[0].extensionType | Should -Be 'postApproval'
        $result[0].actions | Should -Contain 'updateRule'
        $capturedRuleUri | Should -Be 'https://graph.microsoft.com/beta/policies/roleManagementPolicies/policy-id/rules/CustomExtension_PostApproval_EndUser_Assignment'
        $capturedRuleBody.customExtensionId | Should -Be 'extension-id'
        $capturedRuleBody.isEnabled | Should -BeTrue
    }

    It 'adds the post-approval rule using the portal policy contract when the rule is absent' {
        $script:capturedPolicyBody = $null
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{
                    id = 'policy-id'
                    displayName = 'DirectoryRole'
                    description = 'DirectoryRole'
                    isOrganizationDefault = $false
                    scopeId = '/'
                    scopeType = 'DirectoryRole'
                    rules = @(
                        [pscustomobject]@{ id = 'Approval_EndUser_Assignment'; setting = [pscustomobject]@{ isApprovalRequired = $true } },
                        [pscustomobject]@{ id = 'Enablement_EndUser_Assignment'; '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyEnablementRule'; enabledRules = @('Justification') }
                    )
                }
            }
            $script:capturedPolicyBody = $Body | ConvertFrom-Json -AsHashtable -Depth 100
        }
        $roleRules = @([pscustomobject]@{
            policyId = 'policy-id'
            role = [pscustomobject]@{ id = 'role-id'; displayName = 'AI Reader' }
        })

        $result = @(Enable-AzdPimRevocationExtensionForRoles -RoleRules $roleRules -PreApprovalCustomExtensionId 'pre-extension-id' -PostApprovalCustomExtensionId 'extension-id')

        $result[0].actions | Should -Contain 'addRule'
        @($capturedPolicyBody.rules).Count | Should -Be 3
        $newRule = @($capturedPolicyBody.rules | Where-Object id -eq 'CustomExtension_PostApproval_EndUser_Assignment')[0]
        $newRule.customExtensionId | Should -Be 'extension-id'
        $newRule.isEnabled | Should -BeTrue
    }

    It 'uses pre-approval and disables the managed post-approval rule when human approval is not required' {
        $script:capturedBodies = @{}
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{
                    rules = @(
                        [pscustomobject]@{ id = 'Approval_EndUser_Assignment'; setting = [pscustomobject]@{ isApprovalRequired = $false } },
                        [pscustomobject]@{ id = 'CustomExtension_PreApproval_EndUser_Assignment'; isEnabled = $false; customExtensionId = 'pre-extension-id' },
                        [pscustomobject]@{ id = 'CustomExtension_PostApproval_EndUser_Assignment'; isEnabled = $true; customExtensionId = 'post-extension-id' }
                    )
                }
            }
            $script:capturedBodies[$Uri] = $Body
        }
        $roleRules = @([pscustomobject]@{
            policyId = 'policy-id'
            role = [pscustomobject]@{ id = 'role-id'; displayName = 'Attribute Definition Administrator' }
        })

        $result = @(Enable-AzdPimRevocationExtensionForRoles -RoleRules $roleRules -PreApprovalCustomExtensionId 'pre-extension-id' -PostApprovalCustomExtensionId 'post-extension-id')

        $result[0].extensionType | Should -Be 'preApproval'
        $result[0].actions | Should -Contain 'updateRule'
        $result[0].actions | Should -Contain 'disableOppositeRule'
        $capturedBodies['https://graph.microsoft.com/beta/policies/roleManagementPolicies/policy-id/rules/CustomExtension_PreApproval_EndUser_Assignment'].isEnabled | Should -BeTrue
        $capturedBodies['https://graph.microsoft.com/beta/policies/roleManagementPolicies/policy-id/rules/CustomExtension_PostApproval_EndUser_Assignment'].isEnabled | Should -BeFalse
    }
}

Describe 'optional workflow infrastructure contracts' {
    It 'correlates revocation failures and optionally alerts on failed actions' {
        $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../infra/modules/revocation-logic-app.bicep') -Raw

        $template | Should -Match "'id'"
        $template | Should -Match 'PIM request ID:'
        $template | Should -Match "metricName: 'ActionsFailed'"
        $template | Should -Match 'alertActionGroupResourceId'
        $template | Should -Not -Match 'IncludeAuthorizationHeadersInOutputs'
    }

    It 'uses stable event identifiers for both notification implementations' {
        $sentinel = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../infra/modules/sentinel-notifications.bicep') -Raw
        $poller = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/pim-notification-poller/src/index.js') -Raw

        $sentinel | Should -Match 'ActivationEventId'
        $sentinel | Should -Match 'autoMitigate: true'
        $poller | Should -Match "title: 'Audit event ID'"
        $poller | Should -Match 'currentEtag = await writeState'
    }
}
