BeforeAll {
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Common.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Graph.psm1') -Force
}

Describe 'owned selected-role pilot wrapper' {
    BeforeEach {
        $script:savedEnvironment = @{}
        Get-ChildItem Env:AZD_PIM_* | ForEach-Object {
            $savedEnvironment[$_.Name] = $_.Value
            Remove-Item -LiteralPath "Env:$($_.Name)"
        }
        $script:configuration = Get-AzdPimConfiguration
        $configuration.PrivilegedRoleIds = @('11111111-1111-1111-1111-111111111111')
        $script:transport = [pscustomobject]@{
            TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            Calls = [System.Collections.Generic.List[object]]::new()
            Checkpoints = [System.Collections.Generic.List[object]]::new()
            Fail = $false
        }
        $transport | Add-Member ScriptMethod RequestPimJson {
            param([string] $Method, [string] $Uri, [AllowNull()] [string] $Body)
            $this.Calls.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body; checkpoints = $this.Checkpoints.Count })
            if ($this.Fail) { throw 'synthetic owned transport failure' }
            if ($Method -cne 'GET') { return '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}' }
            $values = switch -Wildcard ($Uri) {
                '*roleDefinitions*true' { @{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Fixture role'; isBuiltIn = $true; isEnabled = $true; isPrivileged = $true } }
                '*roleManagementPolicyAssignments*' { @{ roleDefinitionId = '11111111-1111-1111-1111-111111111111'; policyId = 'fixture-policy' } }
                '*roleManagementPolicies*' {
                    @{ id = 'fixture-policy'; rules = @(
                        @{ id = 'AuthenticationContext_EndUser_Assignment'; isEnabled = $false; claimValue = '' },
                        @{ id = 'Enablement_EndUser_Assignment'; enabledRules = @('MultiFactorAuthentication', 'Justification') }
                    ) }
                }
                '*authenticationContextClassReferences' { @{ id = 'c8'; displayName = 'PIM - Privileged roles'; description = 'Authentication context managed by azd-pim for privileged Microsoft Entra role activation.'; isAvailable = $true } }
            }
            return (@{ value = @($values | Where-Object { $null -ne $_ }) } | ConvertTo-Json -Depth 30 -Compress)
        }
        $script:state = [pscustomobject]@{
            schemaVersion = '1.1'; tenantId = $transport.TenantId
            contexts = [pscustomobject]@{ privileged = [pscustomobject]@{ id = 'c8'; created = $true; adopted = $false } }
            conditionalAccessPolicies = [pscustomobject]@{}; appliedRoleRules = [pscustomobject]@{}; pendingRoleRules = [pscustomobject]@{}
        }
        Mock Invoke-MgGraphRequest -ModuleName AzdPim.Graph { throw 'Shared SDK fallback is forbidden.' }
    }

    AfterEach {
        Get-ChildItem Env:AZD_PIM_* | Remove-Item
        foreach ($name in $savedEnvironment.Keys) { Set-Item -LiteralPath "Env:$name" -Value $savedEnvironment[$name] }
        InModuleScope AzdPim.Graph { $script:PilotContext | Should -BeNullOrEmpty }
        Should -Invoke Invoke-MgGraphRequest -ModuleName AzdPim.Graph -Times 0 -Exactly
    }

    It 'plans from durable ownership state using only the supplied read transport' {
        $before = $state | ConvertTo-Json -Depth 100 -Compress
        $plan = New-AzdPimOwnedPlan -Configuration $configuration -Context $transport -State $state
        $plan.tenantId | Should -Be $transport.TenantId
        $plan.tiers.privileged.context.id | Should -Be 'c8'
        $plan.tiers.privileged.roles.Count | Should -Be 1
        $plan.tiers.privileged.roleRules[0].activationMfa.desiredEnabledRules | Should -Be @('Justification')
        $transport.Calls.Count | Should -Be 6
        @($transport.Calls | Where-Object method -ne GET).Count | Should -Be 0
        ($state | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $before
        $transport.Checkpoints.Count | Should -Be 0
    }

    It 'does not fall back after owned read failure and releases the module context' {
        $transport.Fail = $true
        { New-AzdPimOwnedPlan -Configuration $configuration -Context $transport -State $state } | Should -Throw '*synthetic owned transport failure*'
        $transport.Calls.Count | Should -Be 1
        InModuleScope AzdPim.Graph { $script:PilotContext | Should -BeNullOrEmpty }
        $transport.Fail = $false
        (New-AzdPimOwnedPlan -Configuration $configuration -Context $transport -State $state).tenantId | Should -Be $transport.TenantId
    }

    It 'rejects state from another tenant before any protected request' {
        $state.tenantId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        { New-AzdPimOwnedPlan -Configuration $configuration -Context $transport -State $state } | Should -Throw '*State belongs to tenant*'
        $transport.Calls.Count | Should -Be 0
    }

    It 'rejects unsupported plan scope or optional work: <field>' -ForEach @(
        @{ field = 'PrivilegedRoleScope'; value = 'all' }
        @{ field = 'LessPrivilegedRoleScope'; value = 'all' }
        @{ field = 'NotificationMode'; value = 'polling' }
        @{ field = 'EnableSessionRevocation'; value = $true }
        @{ field = 'Mode'; value = 'enforced' }
    ) {
        $configuration.$field = $value
        { New-AzdPimOwnedPlan -Configuration $configuration -Context $transport -State $state } | Should -Throw '*selected-role core pilot*'
        $transport.Calls.Count | Should -Be 0
    }

    It 'uses the original apply checkpoints before and after each owned write' {
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = $transport.TenantId; configuration = $configuration
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = [pscustomobject]@{ id = 'c5'; displayName = 'Pilot'; action = 'create'; adopted = $false; existing = $null }; conditionalAccessPolicies = @(); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        $result = Invoke-AzdPimOwnedApply -Plan $plan -Context $transport -ExistingState $null -StateChanged {
            param($checkpoint)
            $transport.Checkpoints.Add(($checkpoint | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100))
        }
        $transport.Calls.Count | Should -Be 1
        $transport.Calls[0].method | Should -Be 'PATCH'
        $transport.Calls[0].uri | Should -Be 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/authenticationContextClassReferences/c5'
        $transport.Calls[0].checkpoints | Should -Be 1
        $transport.Checkpoints.Count | Should -Be 2
        $transport.Checkpoints[0].contexts.privileged.pendingIntent.action | Should -Be 'create'
        $result.contexts.privileged.id | Should -Be 'c5'
        $result.contexts.privileged.created | Should -BeTrue
    }

    It 'preserves the pending checkpoint on write failure and releases the module context' {
        $plan = [pscustomobject]@{
            mode = 'enforced'; tenantId = $transport.TenantId; configuration = $configuration
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ context = [pscustomobject]@{ id = 'c5'; displayName = 'Pilot'; action = 'create'; adopted = $false; existing = $null }; conditionalAccessPolicies = @(); roleRules = @() }
                lessPrivileged = [pscustomobject]@{ context = $null; conditionalAccessPolicies = @(); roleRules = @() }
            }
        }
        $transport.Fail = $true
        { Invoke-AzdPimOwnedApply -Plan $plan -Context $transport -ExistingState $null -StateChanged { param($checkpoint) $transport.Checkpoints.Add(($checkpoint | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)) } } | Should -Throw '*synthetic owned transport failure*'
        $transport.Calls.Count | Should -Be 1
        $transport.Checkpoints.Count | Should -Be 1
        $transport.Checkpoints[0].contexts.privileged.pendingIntent.action | Should -Be 'create'
        InModuleScope AzdPim.Graph { $script:PilotContext | Should -BeNullOrEmpty }
    }

    It 'rejects apply for the wrong tenant or unsupported scope: <field>' -ForEach @(
        @{ field = 'tenantId'; value = 'cccccccc-cccc-cccc-cccc-cccccccccccc' }
        @{ field = 'PrivilegedRoleScope'; value = 'all' }
        @{ field = 'LessPrivilegedRoleScope'; value = 'all' }
        @{ field = 'NotificationMode'; value = 'polling' }
        @{ field = 'EnableSessionRevocation'; value = $true }
    ) {
        $plan = [pscustomobject]@{ mode = 'enforced'; tenantId = $transport.TenantId; configuration = $configuration }
        if ($field -eq 'tenantId') { $plan.tenantId = $value } else { $configuration.$field = $value }
        { Invoke-AzdPimOwnedApply -Plan $plan -Context $transport -ExistingState $state -StateChanged { throw 'No checkpoint permitted.' } } | Should -Throw '*tenant-bound selected-role core pilot*'
        $transport.Calls.Count | Should -Be 0
        $transport.Checkpoints.Count | Should -Be 0
    }
}
