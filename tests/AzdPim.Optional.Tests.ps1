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

Describe 'session-revocation resource ownership' {
    BeforeEach {
        $script:applicationObjectId = '11111111-1111-1111-1111-111111111111'
        $script:applicationClientId = '22222222-2222-2222-2222-222222222222'
        $script:identifierUri = "api://example.logic.azure.com/$script:applicationClientId"
        $script:application = [pscustomobject]@{
            id = $script:applicationObjectId; appId = $script:applicationClientId; displayName = 'azd-pim dev - Session Revocation'
            signInAudience = 'AzureADMyOrg'; identifierUris = @($script:identifierUri); api = [pscustomobject]@{ requestedAccessTokenVersion = 2 }
        }
        $env:AZD_PIM_REVOCATION_APPLICATION_OBJECT_ID = ''
        $env:AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID = ''
        $env:AZD_PIM_REVOCATION_PRE_APPROVAL_CUSTOM_EXTENSION_ID = ''
        $env:AZD_PIM_REVOCATION_POST_APPROVAL_CUSTOM_EXTENSION_ID = ''
    }

    It 'records a cleanly created application before configuration and reuses its exact state-owned ID' {
        $state = [ordered]@{}
        $script:checkpointCount = 0
        $script:applicationGetCount = 0
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { @() }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            if ($Method -eq 'POST') { return [pscustomobject]@{ id = $script:application.id; appId = $script:application.appId; displayName = $script:application.displayName; signInAudience = $script:application.signInAudience; identifierUris = @(); api = $script:application.api } }
            if ($Method -eq 'GET') {
                $script:applicationGetCount++
                if ($script:applicationGetCount -eq 1) { return [pscustomobject]@{ id = $script:application.id; appId = $script:application.appId; displayName = $script:application.displayName; signInAudience = $script:application.signInAudience; identifierUris = @(); api = $script:application.api } }
                return $script:application
            }
        }

        $result = Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) $script:checkpointCount++ }

        $result.objectId | Should -Be $applicationObjectId
        $state.optionalResources.sessionRevocation.application.objectId | Should -Be $applicationObjectId
        $state.optionalResources.sessionRevocation.application.ownershipSource | Should -Be 'created'
        $state.optionalResources.sessionRevocation.application.configurationState | Should -Be 'configured'
        $script:checkpointCount | Should -Be 2
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional -ParameterFilter { $Method -eq 'PATCH' } -Times 1 -Exactly
    }

    It 'uses only the exact state-owned application object ID on rerun' {
        $state = [ordered]@{ optionalResources = [ordered]@{ sessionRevocation = [ordered]@{ application = [ordered]@{ objectId = $applicationObjectId; clientId = $applicationClientId; identifierUri = $identifierUri; configurationState = 'configured'; ownershipSource = 'created' }; customExtensions = [ordered]@{} } } }
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional {
            if ($Uri -match '/servicePrincipals\?') { return @([pscustomobject]@{ id = '55555555-5555-5555-5555-555555555555' }) }
            throw 'A rerun must not search by display name.'
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional { $script:application }

        $result = Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) throw 'No checkpoint expected.' }

        $result.clientId | Should -Be $applicationClientId
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional -ParameterFilter { $Uri -match '/applications/11111111-1111-1111-1111-111111111111\?' } -Times 1 -Exactly
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional -ParameterFilter { $Method -eq 'PATCH' } -Times 0 -Exactly
    }

    It 'checkpoints a sparse application create response before exact verification can fail' {
        $state = [ordered]@{}
        $script:checkpointCount = 0
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { @() }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            if ($Method -eq 'POST') { return [pscustomobject]@{ id = $applicationObjectId; appId = $applicationClientId } }
            throw 'Exact verification failed after creation.'
        }

        { Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) $script:checkpointCount++ } } | Should -Throw '*Exact verification failed*'
        $state.optionalResources.sessionRevocation.application.objectId | Should -Be $applicationObjectId
        $script:checkpointCount | Should -Be 1
    }

    It 'repairs only the token-version setting on an otherwise verified state-owned application' {
        $state = [ordered]@{ optionalResources = [ordered]@{ sessionRevocation = [ordered]@{ application = [ordered]@{ objectId = $applicationObjectId; clientId = $applicationClientId; identifierUri = $identifierUri; configurationState = 'configured'; ownershipSource = 'created' }; customExtensions = [ordered]@{} } } }
        $script:application.api.requestedAccessTokenVersion = 1
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { if ($Uri -match '/servicePrincipals\?') { return @([pscustomobject]@{ id = '55555555-5555-5555-5555-555555555555' }) }; throw 'No name lookup expected.' }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            if ($Method -eq 'PATCH') { $script:application.api.requestedAccessTokenVersion = 2; return }
            return $script:application
        }

        Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) } | Out-Null

        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional -ParameterFilter { $Method -eq 'PATCH' -and $Body.api.requestedAccessTokenVersion -eq 2 -and -not $Body.ContainsKey('identifierUris') } -Times 1 -Exactly
    }

    It 'fails closed when a same-name application is not state-owned' {
        $state = [ordered]@{}
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { @($script:application) }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional { throw 'Must not mutate a same-name application.' }

        { Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) } } | Should -Throw '*not recorded as state-owned*'
    }

    It 'fails closed before patching a state-owned application with multiple or wrong Application ID URIs' {
        $state = [ordered]@{ optionalResources = [ordered]@{ sessionRevocation = [ordered]@{ application = [ordered]@{ objectId = $applicationObjectId; clientId = $applicationClientId; identifierUri = $identifierUri; configurationState = 'configured' }; customExtensions = [ordered]@{} } } }
        $script:application.identifierUris = @($identifierUri, 'api://foreign.example/other')
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional { $script:application }

        { Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) } } | Should -Throw '*exactly its recorded*'
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional -ParameterFilter { $Method -eq 'PATCH' } -Times 0 -Exactly
    }

    It 'fails closed for state-owned application identity and audience mismatches' {
        $state = [ordered]@{ optionalResources = [ordered]@{ sessionRevocation = [ordered]@{ application = [ordered]@{ objectId = $applicationObjectId; clientId = $applicationClientId; identifierUri = $identifierUri; configurationState = 'configured' }; customExtensions = [ordered]@{} } } }
        $script:application.appId = '33333333-3333-3333-3333-333333333333'
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional { $script:application }

        { Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) } } | Should -Throw '*appId did not match*'

        $script:application.appId = $applicationClientId
        $script:application.signInAudience = 'AzureADMultipleOrgs'
        { Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) } } | Should -Throw '*single-tenant*'

        $script:application.signInAudience = 'AzureADMyOrg'
        $script:application.id = '44444444-4444-4444-4444-444444444444'
        { Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) } } | Should -Throw '*object ID did not match*'
    }

    It 'migrates only a strictly verified legacy application client ID into durable ownership state' {
        $state = [ordered]@{}
        $env:AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID = $applicationClientId
        $script:checkpointCount = 0
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional {
            if ($Uri -match '/servicePrincipals\?') { return @([pscustomobject]@{ id = '55555555-5555-5555-5555-555555555555' }) }
            throw 'Legacy migration must use the exact appId alternate key.'
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional { $script:application }

        Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) $script:checkpointCount++ } | Out-Null

        $state.optionalResources.sessionRevocation.application.ownershipSource | Should -Be 'legacyEnvironmentValidated'
        $script:checkpointCount | Should -Be 1
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional -ParameterFilter { $Uri -match "applications\(appId='22222222-2222-2222-2222-222222222222'\)" } -Times 1 -Exactly
    }

    It 'prefers a legacy application object ID and fails closed when its client ID disagrees' {
        $state = [ordered]@{}
        $env:AZD_PIM_REVOCATION_APPLICATION_OBJECT_ID = $applicationObjectId
        $env:AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID = $applicationClientId
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { if ($Uri -match '/servicePrincipals\?') { return @([pscustomobject]@{ id = '55555555-5555-5555-5555-555555555555' }) }; throw 'No name lookup expected.' }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional { $script:application }

        Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) } | Out-Null

        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional -ParameterFilter { $Uri -match '/applications/11111111-1111-1111-1111-111111111111\?' } -Times 1 -Exactly
        $state = [ordered]@{}
        $env:AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID = '33333333-3333-3333-3333-333333333333'
        { Resolve-AzdPimExtensionApplication -DisplayName 'azd-pim dev - Session Revocation' -EndpointHost 'example.logic.azure.com' -State $state -PersistState { param($checkpoint) } } | Should -Throw '*appId did not match*'
    }

    It 'fails closed when a same-name custom extension is not state-owned' {
        $state = [ordered]@{}
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { @([pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333'; displayName = 'azd-pim dev - Session Revocation'; type = 'preApproval' }) }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional { throw 'Must not mutate a same-name custom extension.' }

        { Set-AzdPimRevocationCustomExtension -DisplayName 'azd-pim dev - Session Revocation' -TargetUrl 'https://example.logic.azure.com/workflows/test?api-version=2019-05-01' -ResourceId $identifierUri -Type preApproval -State $state -PersistState { param($checkpoint) } } | Should -Throw '*not recorded as state-owned*'
    }

    It 'checkpoints a created custom extension before exact verification can fail' {
        $state = [ordered]@{}
        $script:checkpointCount = 0
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { @() }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            if ($Method -eq 'POST') { return [pscustomobject]@{} }
            throw 'Exact custom-extension verification failed after creation.'
        }

        { Set-AzdPimRevocationCustomExtension -DisplayName 'azd-pim dev - Session Revocation' -TargetUrl 'https://example.logic.azure.com/workflows/test?api-version=2019-05-01' -ResourceId $identifierUri -Type preApproval -State $state -PersistState { param($checkpoint) $script:checkpointCount++ } } | Should -Throw '*Exact custom-extension verification failed*'
        $state.optionalResources.sessionRevocation.customExtensions.preApproval.id | Should -Match '^[0-9a-f-]{36}$'
        $script:checkpointCount | Should -Be 1
    }
}

Describe 'post-approval custom extension onboarding' {
    It 'creates a post-approval extension explicitly' {
        $script:capturedExtensionBody = $null
        Mock Get-AzdPimGraphCollection -ModuleName AzdPim.Optional { @() }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{
                    id = $script:capturedExtensionBody.id; displayName = $script:capturedExtensionBody.displayName; type = $script:capturedExtensionBody.type; resourceType = $script:capturedExtensionBody.resourceType
                    authenticationConfiguration = [pscustomobject]$script:capturedExtensionBody.authenticationConfiguration; endpointConfiguration = [pscustomobject]$script:capturedExtensionBody.endpointConfiguration
                }
            }
            $script:capturedExtensionBody = $Body
            [pscustomobject]@{ id = $Body.id }
        }
        $state = [ordered]@{}

        $result = Set-AzdPimRevocationCustomExtension -DisplayName 'Post approval revocation' -TargetUrl 'https://example.logic.azure.com/workflows/abc?api-version=2019-05-01' -ResourceId 'api://example/abc' -Type postApproval -State $state -PersistState { param($checkpoint) }

        $result | Should -Match '^[0-9a-f-]{36}$'
        $capturedExtensionBody.type | Should -Be 'postApproval'
        $capturedExtensionBody.resourceType | Should -Be 'entraRoles'
        $state.optionalResources.sessionRevocation.customExtensions.postApproval.ownershipSource | Should -Be 'created'
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

    It 'keeps small role-policy linking runs quiet' {
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            [pscustomobject]@{
                rules = @(
                    [pscustomobject]@{ id = 'Approval_EndUser_Assignment'; setting = [pscustomobject]@{ isApprovalRequired = $false } },
                    [pscustomobject]@{ id = 'CustomExtension_PreApproval_EndUser_Assignment'; isEnabled = $true; customExtensionId = 'pre-extension-id' }
                )
            }
        }
        Mock Write-Host -ModuleName AzdPim.Optional { }
        $roleRules = @([pscustomobject]@{ policyId = 'policy-id'; role = [pscustomobject]@{ id = 'role-id'; displayName = 'Sensitive role name' } })

        @(Enable-AzdPimRevocationExtensionForRoles -RoleRules $roleRules -PreApprovalCustomExtensionId 'pre-extension-id' -PostApprovalCustomExtensionId 'post-extension-id').Count | Should -Be 1
        Should -Invoke Write-Host -ModuleName AzdPim.Optional -Times 0 -Exactly
    }

    It 'reports bounded sanitized progress for large role-policy linking runs' {
        $script:progressMessages = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Optional {
            [pscustomobject]@{
                rules = @(
                    [pscustomobject]@{ id = 'Approval_EndUser_Assignment'; setting = [pscustomobject]@{ isApprovalRequired = $false } },
                    [pscustomobject]@{ id = 'CustomExtension_PreApproval_EndUser_Assignment'; isEnabled = $true; customExtensionId = 'pre-extension-id' }
                )
            }
        }
        Mock Write-Host -ModuleName AzdPim.Optional {
            param($Object)
            $script:progressMessages.Add([string]$Object)
        }
        $roleRules = @(1..26 | ForEach-Object {
            [pscustomobject]@{ policyId = "policy-$_"; role = [pscustomobject]@{ id = "role-$_"; displayName = "Sensitive role $_" } }
        })

        @(Enable-AzdPimRevocationExtensionForRoles -RoleRules $roleRules -PreApprovalCustomExtensionId 'pre-extension-id' -PostApprovalCustomExtensionId 'post-extension-id').Count | Should -Be 26
        @($script:progressMessages) | Should -Be @(
            'Configuring PIM session-revocation extensions for 26 role policies.',
            'PIM session-revocation extension progress: 25 of 26 role policies processed.',
            'PIM session-revocation extension configuration complete: 26 of 26 role policies processed.'
        )
        ($script:progressMessages -join ' ') | Should -Not -Match 'Sensitive role|role-[0-9]+'
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

    It 'stages only the Function runtime files before creating the deployment archive' {
        $optional = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/AzdPim.Optional.psm1') -Raw

        $optional | Should -Match 'foreach \(\$file in @\(''host.json'', ''package.json'', ''package-lock.json''\)\)'
        $optional | Should -Match 'Copy-Item -LiteralPath \(Join-Path \$sourcePath ''src''\)'
        $optional | Should -Not -Match 'Compress-Archive -Path \(Join-Path \$sourcePath ''\*''\)'
    }
}
