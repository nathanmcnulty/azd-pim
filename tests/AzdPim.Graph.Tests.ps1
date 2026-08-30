BeforeAll {
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Graph.psm1') -Force
}

Describe 'Microsoft Graph request transport' {
    It 'uses only the proven Microsoft Graph PowerShell session' {
        Mock Get-MgContext -ModuleName AzdPim.Graph {
            [pscustomobject]@{ TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        }
        Mock Invoke-MgGraphRequest -ModuleName AzdPim.Graph { [pscustomobject]@{ id = 'result' } }
        Mock Invoke-RestMethod -ModuleName AzdPim.Graph { throw 'Azure CLI token fallback must not be used.' }

        $result = Invoke-AzdPimGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me'

        $result.id | Should -Be 'result'
        Should -Invoke Invoke-MgGraphRequest -ModuleName AzdPim.Graph -Times 1 -Exactly
        Should -Invoke Invoke-RestMethod -ModuleName AzdPim.Graph -Times 0 -Exactly
    }

    It 'fails closed when no Graph PowerShell context exists' {
        Mock Get-MgContext -ModuleName AzdPim.Graph { $null }
        Mock Invoke-MgGraphRequest -ModuleName AzdPim.Graph { throw 'No request should be sent.' }
        Mock Invoke-RestMethod -ModuleName AzdPim.Graph { throw 'No fallback should be sent.' }

        { Invoke-AzdPimGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me' } |
            Should -Throw '*proven Microsoft Graph PowerShell session is required*'

        Should -Invoke Invoke-MgGraphRequest -ModuleName AzdPim.Graph -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -ModuleName AzdPim.Graph -Times 0 -Exactly
    }
}

Describe 'plan report secret boundary' {
    It 'replaces the Teams webhook URL with a readiness flag' {
        InModuleScope AzdPim.Graph {
            $secret = 'https://example.invalid/workflows/callback?sig=do-not-serialize'
            $configuration = [pscustomobject]@{
                Mode = 'plan'
                NotificationMode = 'polling'
                TeamsWebhookUrl = $secret
            }

            $safe = ConvertTo-AzdPimReportConfiguration -Configuration $configuration
            $json = $safe | ConvertTo-Json -Depth 10

            $safe.PSObject.Properties.Name | Should -Not -Contain 'TeamsWebhookUrl'
            $safe.TeamsWebhookConfigured | Should -BeTrue
            $json | Should -Not -Match ([regex]::Escape($secret))
            $json | Should -Not -Match 'do-not-serialize'
        }
    }

    It 'refuses to write a plan that still contains a Teams webhook URL' {
        $path = Join-Path $TestDrive 'unsafe-plan.json'
        $plan = [pscustomobject]@{
            configuration = [pscustomobject]@{
                TeamsWebhookUrl = 'https://example.invalid/workflows/callback?sig=do-not-write'
            }
        }

        { Write-AzdPimPlanReport -Plan $plan -Path $path } |
            Should -Throw '*sensitive Teams webhook URL*'
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}

Describe 'role selection' {
    BeforeAll {
        $script:inventory = @(
            [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Privileged'; isPrivileged = $true },
            [pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222'; displayName = 'Less'; isPrivileged = $false }
        )
    }

    It 'derives all privileged roles from isPrivileged' {
        $result = @(Resolve-AzdPimRoleSelection -Inventory $inventory -Scope all -SelectedIds @() -ExpectedPrivileged $true -TierName Privileged)
        $result.Count | Should -Be 1
        $result[0].id | Should -Be '11111111-1111-1111-1111-111111111111'
    }

    It 'does not interpret an empty selected list as all roles' {
        @(Resolve-AzdPimRoleSelection -Inventory $inventory -Scope selected -SelectedIds @() -ExpectedPrivileged $true -TierName Privileged).Count | Should -Be 0
    }

    It 'rejects a role whose live classification is in the other tier' {
        { Resolve-AzdPimRoleSelection -Inventory $inventory -Scope selected -SelectedIds @('22222222-2222-2222-2222-222222222222') -ExpectedPrivileged $true -TierName Privileged } | Should -Throw '*classified by Graph as less-privileged*'
    }
}

Describe 'authentication context allocation' {
    It 'uses the first unconfigured and unreferenced context slot' {
        $contexts = @(
            [pscustomobject]@{ id = 'c1'; displayName = ''; description = ''; isAvailable = $false },
            [pscustomobject]@{ id = 'c2'; displayName = ''; description = ''; isAvailable = $false }
        )
        $reserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$reserved.Add('c1')
        $result = Resolve-AzdPimContext -Tier privileged -DisplayName 'PIM Privileged Roles' -Contexts $contexts -ReservedIds $reserved -State $null -AdoptExisting $false
        $result.id | Should -Be 'c2'
        $result.action | Should -Be 'create'
    }

    It 'requires explicit adoption for a matching existing context' {
        $contexts = @([pscustomobject]@{ id = 'c7'; displayName = 'PIM Privileged Roles'; description = 'existing'; isAvailable = $true })
        $reserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        { Resolve-AzdPimContext -Tier privileged -DisplayName 'PIM Privileged Roles' -Contexts $contexts -ReservedIds $reserved -State $null -AdoptExisting $false } | Should -Throw '*AZD_PIM_ADOPT_EXISTING*'
    }

    It 'does not update a state-owned context whose managed properties already match' {
        $contexts = @([pscustomobject]@{
            id = 'c9'
            displayName = 'PIM Privileged Roles'
            description = 'Authentication context managed by azd-pim for privileged Microsoft Entra role activation.'
            isAvailable = $true
        })
        $state = [pscustomobject]@{ contexts = [pscustomobject]@{ privileged = [pscustomobject]@{ id = 'c9' } } }
        $reserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $result = Resolve-AzdPimContext -Tier privileged -DisplayName 'PIM Privileged Roles' -Contexts $contexts -ReservedIds $reserved -State $state -AdoptExisting $false

        $result.action | Should -Be 'none'
    }
}

Describe 'Conditional Access policy construction' {
    It 'targets the authentication context and all users with MFA and every-time reauthentication' {
        $body = New-AzdPimConditionalAccessBody -DisplayName 'PIM test' -ContextId c3 -EmergencyAccessGroupId '33333333-3333-3333-3333-333333333333' -AuthenticationProfile mfa -DeviceRequirement none
        $body.conditions.applications.includeAuthenticationContextClassReferences | Should -Be @('c3')
        $body.conditions.users.includeUsers | Should -Be @('All')
        $body.conditions.users.excludeGroups | Should -Be @('33333333-3333-3333-3333-333333333333')
        $body.grantControls.builtInControls | Should -Be @('mfa')
        $body.sessionControls.signInFrequency.frequencyInterval | Should -Be 'everyTime'
        $body.sessionControls.signInFrequency.authenticationType | Should -Be 'primaryAndSecondaryAuthentication'
        $body.state | Should -Be 'enabled'
    }

    It 'uses a separate OR policy for compliant or hybrid-joined devices' {
        $body = New-AzdPimDeviceCompanionBody -DisplayName 'PIM test' -ContextId c3 -EmergencyAccessGroupId ''
        $body.grantControls.operator | Should -Be 'OR'
        $body.grantControls.builtInControls | Should -Be @('compliantDevice', 'domainJoinedDevice')
    }

    It 'uses a companion block policy for an exact device allowlist' {
        $body = New-AzdPimDeviceAllowlistBody -DisplayName 'PIM test' -ContextId c3 -EmergencyAccessGroupId '' -AllowedDeviceIds @('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')
        $body.grantControls.builtInControls | Should -Be @('block')
        $body.conditions.devices.deviceFilter.mode | Should -Be 'exclude'
        $body.conditions.devices.deviceFilter.rule | Should -Be 'device.deviceId -in ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"]'
    }

    It 'does not update a state-owned policy when Graph normalizes a single grant control to OR' {
        $body = New-AzdPimConditionalAccessBody -DisplayName 'PIM test' -ContextId c3 -EmergencyAccessGroupId '33333333-3333-3333-3333-333333333333' -AuthenticationProfile mfa -DeviceRequirement none
        $existing = $body | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $existing | Add-Member -NotePropertyName id -NotePropertyValue 'policy-id'
        $existing.grantControls.operator = 'OR'
        $state = [pscustomobject]@{ conditionalAccessPolicies = [pscustomobject]@{ privileged = [pscustomobject]@{ id = 'policy-id' } } }

        $result = & (Get-Module AzdPim.Graph) { Resolve-AzdPimConditionalAccessPolicy -Key privileged -DisplayName 'PIM test' -Body $args[0] -Policies $args[1] -State $args[2] -AdoptExisting $false } $body @($existing) $state

        $result.action | Should -Be 'none'
    }

    It 'updates a state-owned policy when a managed condition drifts' {
        $body = New-AzdPimConditionalAccessBody -DisplayName 'PIM test' -ContextId c3 -EmergencyAccessGroupId '' -AuthenticationProfile mfa -DeviceRequirement none
        $existing = $body | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $existing | Add-Member -NotePropertyName id -NotePropertyValue 'policy-id'
        $existing.conditions.applications.includeAuthenticationContextClassReferences = @('c4')
        $state = [pscustomobject]@{ conditionalAccessPolicies = [pscustomobject]@{ privileged = [pscustomobject]@{ id = 'policy-id' } } }

        $result = & (Get-Module AzdPim.Graph) { Resolve-AzdPimConditionalAccessPolicy -Key privileged -DisplayName 'PIM test' -Body $args[0] -Policies $args[1] -State $args[2] -AdoptExisting $false } $body @($existing) $state

        $result.action | Should -Be 'update'
    }
}

Describe 'deployment state preservation' {
    It 'checkpoints a stable context ownership intent before its first Graph write' {
        $script:checkpoint = $null
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph { throw 'The Graph write must occur after the checkpoint.' }
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = [pscustomobject]@{ id = 'c5'; displayName = 'PIM Privileged Roles'; action = 'create'; adopted = $false; existing = [pscustomobject]@{ id = 'c5'; isAvailable = $false; displayName = ''; description = '' } }; conditionalAccessPolicies = @(); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }

        { Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false -StateChanged { param($checkpoint) $script:checkpoint = $checkpoint; throw 'checkpointed' } } | Should -Throw 'checkpointed'
        $script:checkpoint.contexts.privileged.id | Should -Be 'c5'
        $script:checkpoint.contexts.privileged.pendingIntent.action | Should -Be 'create'
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph -Times 0 -Exactly
    }

    It 'retains a pending context intent when the Graph write succeeds but the final checkpoint fails' {
        $script:checkpoints = @()
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph { [pscustomobject]@{} }
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = [pscustomobject]@{ id = 'c5'; displayName = 'PIM Privileged Roles'; action = 'create'; adopted = $false; existing = [pscustomobject]@{ id = 'c5'; isAvailable = $false; displayName = ''; description = '' } }; conditionalAccessPolicies = @(); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }

        { Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false -StateChanged { param($checkpoint) $script:checkpoints += ($checkpoint | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100); if ($script:checkpoints.Count -eq 2) { throw 'final checkpoint failed' } } } | Should -Throw 'final checkpoint failed'
        $script:checkpoints.Count | Should -Be 2
        $script:checkpoints[0].contexts.privileged.pendingIntent.action | Should -Be 'create'
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph -Times 1 -Exactly
    }

    It 'recovers only an exact unique Conditional Access policy matching a pending create intent' {
        $body = New-AzdPimConditionalAccessBody -DisplayName 'PIM pending' -ContextId c5 -EmergencyAccessGroupId '' -AuthenticationProfile mfa -DeviceRequirement none
        $existing = $body | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $existing | Add-Member -NotePropertyName id -NotePropertyValue 'policy-id'
        $state = [pscustomobject]@{ conditionalAccessPolicies = [pscustomobject]@{ privileged = [pscustomobject]@{ pendingCreate = [pscustomobject]@{ displayName = 'PIM pending'; body = $body } } } }

        $result = & (Get-Module AzdPim.Graph) { Resolve-AzdPimConditionalAccessPolicy -Key privileged -DisplayName 'PIM pending' -Body $args[0] -Policies @($args[1]) -State $args[2] -AdoptExisting $false } $body $existing $state

        $result.action | Should -Be 'none'
        $result.recoveredPendingCreate | Should -BeTrue
        $result.id | Should -Be 'policy-id'
    }

    It 'checkpoints a server-assigned Conditional Access create intent before the POST' {
        $script:checkpoint = $null
        $body = New-AzdPimConditionalAccessBody -DisplayName 'PIM pending' -ContextId c5 -EmergencyAccessGroupId '' -AuthenticationProfile mfa -DeviceRequirement none
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @([pscustomobject]@{ key = 'privileged'; id = $null; action = 'create'; body = $body; adopted = $false; existing = $null; recoveredPendingCreate = $false }); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph { throw 'POST must not run before the state checkpoint.' }

        { Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false -StateChanged { param($checkpoint) $script:checkpoint = $checkpoint; throw 'checkpointed' } } | Should -Throw 'checkpointed'
        $script:checkpoint.conditionalAccessPolicies.privileged.pendingCreate.displayName | Should -Be 'PIM pending'
        $script:checkpoint.conditionalAccessPolicies.privileged.pendingCreate.body.displayName | Should -Be 'PIM pending'
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph -Times 0 -Exactly
    }

    It 'retains a pending Conditional Access create intent if the POST succeeds before final checkpointing' {
        $script:checkpoints = @()
        $body = New-AzdPimConditionalAccessBody -DisplayName 'PIM pending' -ContextId c5 -EmergencyAccessGroupId '' -AuthenticationProfile mfa -DeviceRequirement none
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @([pscustomobject]@{ key = 'privileged'; id = $null; action = 'create'; body = $body; adopted = $false; existing = $null; recoveredPendingCreate = $false }); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph { [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111' } }

        { Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false -StateChanged { param($checkpoint) $script:checkpoints += ($checkpoint | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100); if ($script:checkpoints.Count -eq 2) { throw 'final checkpoint failed' } } } | Should -Throw 'final checkpoint failed'
        $script:checkpoints[0].conditionalAccessPolicies.privileged.pendingCreate.displayName | Should -Be 'PIM pending'
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph -Times 1 -Exactly
    }

    It 'fails closed when pending Conditional Access recovery is ambiguous or mismatched' {
        $body = New-AzdPimConditionalAccessBody -DisplayName 'PIM pending' -ContextId c5 -EmergencyAccessGroupId '' -AuthenticationProfile mfa -DeviceRequirement none
        $existing = $body | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $existing | Add-Member -NotePropertyName id -NotePropertyValue 'policy-id'
        $state = [pscustomobject]@{ conditionalAccessPolicies = [pscustomobject]@{ privileged = [pscustomobject]@{ pendingCreate = [pscustomobject]@{ displayName = 'PIM pending'; body = $body } } } }

        { & (Get-Module AzdPim.Graph) { Resolve-AzdPimConditionalAccessPolicy -Key privileged -DisplayName 'PIM pending' -Body $args[0] -Policies @($args[1], $args[2]) -State $args[3] -AdoptExisting $false } $body $existing ($existing | Select-Object *) $state } | Should -Throw '*Multiple Conditional Access*'
        $existing.conditions.applications.includeAuthenticationContextClassReferences = @('c9')
        { & (Get-Module AzdPim.Graph) { Resolve-AzdPimConditionalAccessPolicy -Key privileged -DisplayName 'PIM pending' -Body $args[0] -Policies @($args[1]) -State $args[2] -AdoptExisting $false } $body $existing $state } | Should -Throw '*does not exactly match*'
    }

    It 'preserves original Conditional Access ownership provenance while clearing a pending update' {
        $body = New-AzdPimConditionalAccessBody -DisplayName 'PIM owned' -ContextId c5 -EmergencyAccessGroupId '' -AuthenticationProfile mfa -DeviceRequirement none
        $prior = [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; created = $true; adopted = $false; previous = [pscustomobject]@{ displayName = 'original' } }
        $state = [pscustomobject]@{ tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; contexts = [pscustomobject]@{}; conditionalAccessPolicies = [pscustomobject]@{ privileged = $prior }; appliedRoleRules = [pscustomobject]@{}; pendingRoleRules = [pscustomobject]@{} }
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = $state.tenantId
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @([pscustomobject]@{ key = 'privileged'; id = $prior.id; action = 'update'; body = $body; adopted = $false; existing = [pscustomobject]@{ id = $prior.id }; recoveredPendingCreate = $false }); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph { [pscustomobject]@{} }

        $result = Invoke-AzdPimApply -Plan $plan -ExistingState $state -Confirm:$false

        $result.conditionalAccessPolicies.privileged.created | Should -BeTrue
        $result.conditionalAccessPolicies.privileged.previous.displayName | Should -Be 'original'
        $result.conditionalAccessPolicies.privileged.PSObject.Properties.Name | Should -Not -Contain 'pendingIntent'
    }

    It 'preserves original authentication-context ownership provenance while clearing a pending update' {
        $state = [pscustomobject]@{ tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; contexts = [pscustomobject]@{ privileged = [pscustomobject]@{ id = 'c5'; created = $true; adopted = $false; previous = $null } }; conditionalAccessPolicies = [pscustomobject]@{}; appliedRoleRules = [pscustomobject]@{}; pendingRoleRules = [pscustomobject]@{} }
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = $state.tenantId
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = [pscustomobject]@{ id = 'c5'; displayName = 'PIM Privileged Roles'; action = 'update'; adopted = $false; existing = [pscustomobject]@{ id = 'c5' } }; conditionalAccessPolicies = @(); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph { [pscustomobject]@{} }

        $result = Invoke-AzdPimApply -Plan $plan -ExistingState $state -Confirm:$false

        $result.contexts.privileged.created | Should -BeTrue
        $result.contexts.privileged.PSObject.Properties.Name | Should -Not -Contain 'pendingIntent'
    }

    It 'clears a pending role-rule intent only after the exact live re-plan is already correct' {
        $roleId = '11111111-1111-1111-1111-111111111111'
        $state = [pscustomobject]@{ tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; contexts = [pscustomobject]@{}; conditionalAccessPolicies = [pscustomobject]@{}; appliedRoleRules = [pscustomobject]@{}; pendingRoleRules = [pscustomobject]@{ $roleId = [pscustomobject]@{ policyId = 'policy-id'; desiredContextId = 'c5'; legacyActivationMfaRemoved = $true } } }
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = $state.tenantId
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @([pscustomobject]@{ role = [pscustomobject]@{ id = $roleId; displayName = 'Recovered role' }; policyId = 'policy-id'; action = 'none'; desiredContextId = 'c5'; activationMfa = [pscustomobject]@{ action = 'none' } }) }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }

        $result = Invoke-AzdPimApply -Plan $plan -ExistingState $state -Confirm:$false

        $result.pendingRoleRules.Contains($roleId) | Should -BeFalse
        $result.appliedRoleRules[$roleId].recoveredPendingIntent | Should -BeTrue
        $result.appliedRoleRules[$roleId].removedLegacyActivationMfa | Should -BeTrue
    }

    It 'checkpoints the legacy-MFA removal phase before a crash can lose it' {
        $roleId = '11111111-1111-1111-1111-111111111111'
        $script:checkpoints = @()
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @([pscustomobject]@{
                    role = [pscustomobject]@{ id = $roleId; displayName = 'Crash recovery role' }; policyId = 'policy-id'; action = 'update'; desiredContextId = 'c5'
                    existing = [pscustomobject]@{ target = [pscustomobject]@{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() } }
                    activationMfa = [pscustomobject]@{ action = 'remove'; desiredEnabledRules = @('Justification'); existing = [pscustomobject]@{ enabledRules = @('MultiFactorAuthentication', 'Justification'); target = [pscustomobject]@{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() } } }
                }) }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph { [pscustomobject]@{} }

        { Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false -StateChanged { param($checkpoint) $script:checkpoints += ($checkpoint | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100); if ($script:checkpoints.Count -eq 2) { throw 'crash after legacy MFA removal' } } } | Should -Throw '*legacy MFA was restored*'
        $pending = $script:checkpoints[1].pendingRoleRules.PSObject.Properties[$roleId].Value
        $pending.legacyActivationMfaRemoved | Should -BeTrue
        $pending.PSObject.Properties.Name | Should -Not -Contain 'existing'
        $script:checkpoints[2].pendingRoleRules.PSObject.Properties[$roleId].Value.legacyActivationMfaRemoved | Should -BeFalse
    }

    It 'resets the legacy-MFA phase after successful restoration before rethrowing an attachment failure' {
        $roleId = '11111111-1111-1111-1111-111111111111'
        $script:checkpoints = @()
        $script:enablementWrites = 0
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @([pscustomobject]@{
                    role = [pscustomobject]@{ id = $roleId; displayName = 'Restore recovery role' }; policyId = 'policy-id'; action = 'update'; desiredContextId = 'c5'
                    existing = [pscustomobject]@{ target = [pscustomobject]@{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() } }
                    activationMfa = [pscustomobject]@{ action = 'remove'; desiredEnabledRules = @('Justification'); existing = [pscustomobject]@{ enabledRules = @('MultiFactorAuthentication', 'Justification'); target = [pscustomobject]@{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() } } }
                }) }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph {
            if ($Uri -like '*/Enablement_EndUser_Assignment') { $script:enablementWrites++; return [pscustomobject]@{} }
            throw 'attachment failed'
        }

        { Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false -StateChanged { param($checkpoint) $script:checkpoints += ($checkpoint | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100) } } | Should -Throw '*legacy MFA was restored*'
        $script:enablementWrites | Should -Be 2
        $pending = $script:checkpoints[2].pendingRoleRules.PSObject.Properties[$roleId].Value
        $pending.legacyActivationMfaRemoved | Should -BeFalse
        $pending.PSObject.Properties.Name | Should -Not -Contain 'existing'
    }

    It 'reports a restored-state checkpoint failure without mislabeling it as Graph restoration failure' {
        $roleId = '11111111-1111-1111-1111-111111111111'
        $script:checkpointCount = 0
        $script:enablementWrites = 0
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @([pscustomobject]@{
                    role = [pscustomobject]@{ id = $roleId; displayName = 'Checkpoint failure role' }; policyId = 'policy-id'; action = 'update'; desiredContextId = 'c5'
                    existing = [pscustomobject]@{ target = [pscustomobject]@{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() } }
                    activationMfa = [pscustomobject]@{ action = 'remove'; desiredEnabledRules = @('Justification'); existing = [pscustomobject]@{ enabledRules = @('MultiFactorAuthentication', 'Justification'); target = [pscustomobject]@{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() } } }
                }) }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph {
            if ($Uri -like '*/Enablement_EndUser_Assignment') { $script:enablementWrites++; return [pscustomobject]@{} }
            throw 'attachment failed'
        }

        { Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false -StateChanged { param($checkpoint) $script:checkpointCount++; if ($script:checkpointCount -eq 3) { throw 'local state write failed' } } } | Should -Throw '*recording the restored state failed*'
        $script:enablementWrites | Should -Be 2
    }

    It 'does not send Graph writes for no-op contexts and policies' {
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph { throw 'No Graph write was expected.' }
        $existingState = [pscustomobject]@{
            tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            contexts = [pscustomobject]@{ privileged = [pscustomobject]@{ id = 'c9'; created = $true } }
            conditionalAccessPolicies = [pscustomobject]@{ privileged = [pscustomobject]@{ id = 'policy-id'; created = $true } }
            appliedRoleRules = [pscustomobject]@{}
        }
        $plan = [pscustomobject]@{
            mode = 'enforced'
            tenantId = $existingState.tenantId
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{
                    context = [pscustomobject]@{ id = 'c9'; displayName = 'PIM Privileged Roles'; action = 'none'; adopted = $false; existing = $null }
                    conditionalAccessPolicies = @([pscustomobject]@{ key = 'privileged'; id = 'policy-id'; action = 'none'; body = [pscustomobject]@{ displayName = 'PIM policy' }; adopted = $false; existing = $null })
                    roleRules = @()
                }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }

        $result = Invoke-AzdPimApply -Plan $plan -ExistingState $existingState -Confirm:$false

        $result.contexts.privileged.id | Should -Be 'c9'
        $result.conditionalAccessPolicies.privileged.id | Should -Be 'policy-id'
        Should -Invoke Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph -Times 0 -Exactly
    }

    It 'tracks no prior PIM rule configuration for an empty idempotent apply' {
        $existingState = [pscustomobject]@{
            tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            contexts = [pscustomobject]@{ privileged = [pscustomobject]@{ id = 'c5'; created = $true; previous = $null } }
            conditionalAccessPolicies = [pscustomobject]@{}
            appliedRoleRules = [pscustomobject]@{}
        }
        $plan = [pscustomobject]@{
            mode = 'enforced'
            tenantId = $existingState.tenantId
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }

        $result = Invoke-AzdPimApply -Plan $plan -ExistingState $existingState -Confirm:$false
        $result.contexts.privileged.id | Should -Be 'c5'
        $result.appliedRoleRules.Count | Should -Be 0
    }

    It 'backfills ownership state for a live-correct scoped role' {
        $plan = [pscustomobject]@{
            mode = 'enforced'
            tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{
                    context = $null
                    conditionalAccessPolicies = @()
                    roleRules = @([pscustomobject]@{
                        role = [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Already correct' }
                        policyId = 'policy-id'
                        action = 'none'
                        desiredContextId = 'c5'
                        activationMfa = [pscustomobject]@{ action = 'none' }
                    })
                }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }

        $result = Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false

        $result.appliedRoleRules.Count | Should -Be 1
        $result.appliedRoleRules['11111111-1111-1111-1111-111111111111'].desiredContextId | Should -Be 'c5'
    }

    It 'records the applied context but not the prior PIM rule body' {
        $script:capturedRoleRuleBody = $null
        $script:capturedEnablementBody = $null
        $script:checkpoints = @()
        Mock Invoke-AzdPimGraphRequest -ModuleName AzdPim.Graph {
            if ($Method -eq 'PATCH' -and $Uri -like '*/Enablement_EndUser_Assignment') {
                $script:capturedEnablementBody = $Body
            }
            if ($Method -eq 'PATCH' -and $Uri -like '*/policies/roleManagementPolicies/*') {
                $script:capturedRoleRuleBody = $Body
            }
            [pscustomobject]@{}
        }
        $plan = [pscustomobject]@{
            mode = 'enforced'
            tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{
                    context = $null
                    conditionalAccessPolicies = @()
                    roleRules = @([pscustomobject]@{
                        role = [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Test role' }
                        policyId = 'policy-id'
                        action = 'update'
                        desiredContextId = 'c5'
                        existing = [pscustomobject]@{
                            isEnabled = $false
                            claimValue = ''
                            target = [pscustomobject]@{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() }
                        }
                        activationMfa = [pscustomobject]@{
                            action = 'remove'
                            desiredEnabledRules = @('Justification')
                            existing = [pscustomobject]@{
                                enabledRules = @('MultiFactorAuthentication', 'Justification')
                                target = [pscustomobject]@{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() }
                            }
                        }
                    })
                }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }

        $result = Invoke-AzdPimApply -Plan $plan -ExistingState $null -Confirm:$false -StateChanged { param($checkpoint) $script:checkpoints += ($checkpoint | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100) }
        $record = $result.appliedRoleRules['11111111-1111-1111-1111-111111111111']
        $record.desiredContextId | Should -Be 'c5'
        $record.removedLegacyActivationMfa | Should -BeTrue
        $record.Keys | Should -Not -Contain 'previous'
        $capturedRoleRuleBody.target | Should -BeOfType [hashtable]
        $capturedRoleRuleBody.target.caller | Should -Be 'EndUser'
        $capturedRoleRuleBody.target.operations | Should -Be @('all')
        $capturedEnablementBody.enabledRules | Should -Be @('Justification')
        $capturedEnablementBody.target | Should -BeOfType [hashtable]
        $script:checkpoints.Count | Should -Be 3
        $script:checkpoints[0].pendingRoleRules.PSObject.Properties['11111111-1111-1111-1111-111111111111'].Value.desiredContextId | Should -Be 'c5'
        $script:checkpoints[1].pendingRoleRules.PSObject.Properties['11111111-1111-1111-1111-111111111111'].Value.legacyActivationMfaRemoved | Should -BeTrue
        $script:checkpoints[2].appliedRoleRules.PSObject.Properties['11111111-1111-1111-1111-111111111111'].Value.desiredContextId | Should -Be 'c5'
    }
}
