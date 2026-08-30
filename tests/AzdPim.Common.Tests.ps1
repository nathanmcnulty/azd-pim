BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Common.psm1') -Force
}

Describe 'azd-pim configuration parsing' {
    It 'treats an empty list as an empty selection' {
        @(ConvertFrom-AzdPimList -Value '').Count | Should -Be 0
    }

    It 'accepts JSON and delimited lists deterministically' {
        @(ConvertFrom-AzdPimList -Value '["b","a","a"]').Count | Should -Be 2
        (ConvertFrom-AzdPimList -Value 'b;a,a') | Should -Be @('a', 'b')
    }

    It 'rejects invalid booleans instead of guessing' {
        { Get-AzdPimBoolean -Value 'sometimes' -Name 'TEST' } | Should -Throw '*must be true or false*'
    }

    It 'rejects invalid GUID list members' {
        { Assert-AzdPimGuidList -Values @('not-a-guid') -Name 'TEST' } | Should -Throw '*invalid GUID*'
    }

    It 'does not expose a selectable Graph authentication method' {
        (Get-AzdPimConfiguration).PSObject.Properties.Name | Should -Not -Contain 'GraphAuthenticationMethod'
    }

    It 'defaults both all-role acknowledgements to false' {
        $configuration = Get-AzdPimConfiguration
        $configuration.ConfirmAllPrivilegedRoles | Should -BeFalse
        $configuration.ConfirmAllLessPrivilegedRoles | Should -BeFalse
    }

    It 'rejects a malformed revocation alert action group resource ID' {
        $priorValue = $env:AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID
        try {
            $env:AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID = '/subscriptions/not-valid/actionGroups/example'
            { Get-AzdPimConfiguration } | Should -Throw '*action group resource ID*'
        } finally {
            $env:AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID = $priorValue
        }
    }

    It 'rejects revocation alerting when session revocation is disabled' {
        $priorActionGroup = $env:AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID
        $priorRevocation = $env:AZD_PIM_ENABLE_SESSION_REVOCATION
        try {
            $env:AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Insights/actionGroups/admins'
            $env:AZD_PIM_ENABLE_SESSION_REVOCATION = 'false'
            { Get-AzdPimConfiguration } | Should -Throw '*requires AZD_PIM_ENABLE_SESSION_REVOCATION=true*'
        } finally {
            $env:AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID = $priorActionGroup
            $env:AZD_PIM_ENABLE_SESSION_REVOCATION = $priorRevocation
        }
    }

    It 'builds tenant-scoped portal links only for populated Azure resources' {
        $links = Get-AzdPimPortalLinks -TenantId '11111111-1111-4111-8111-111111111111' `
            -SubscriptionId '11111111-2222-3333-4444-555555555555' -ResourceGroupName 'rg-pim' `
            -AzureResources ([ordered]@{ sessionRevocationLogicApp = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-pim/providers/Microsoft.Logic/workflows/revoke'; pollingFunction = '' })

        $links.pimRoleActivation | Should -Match '^https://entra\.microsoft\.com/'
        $links.azureResourceGroup | Should -Match '11111111-1111-4111-8111-111111111111'
        $links.sessionRevocationLogicApp | Should -Match '/Microsoft\.Logic/workflows/revoke/overview$'
        $links.PSObject.Properties.Name | Should -Not -Contain 'pollingFunction'
    }

    It 'separates applied configuration from pending operational verification in the receipt' {
        $plan = [pscustomobject]@{
            tenantId = '11111111-1111-4111-8111-111111111111'
            tiers = [pscustomobject]@{
                privileged = [pscustomobject]@{ roles = @([pscustomobject]@{ id = '1' }) }
                lessPrivileged = [pscustomobject]@{ roles = @() }
            }
        }
        $configuration = [pscustomobject]@{
            Mode = 'enforced'
            PrivilegedRoleScope = 'all'
            ConfirmAllPrivilegedRoles = $true
            LessPrivilegedRoleScope = 'selected'
            ConfirmAllLessPrivilegedRoles = $false
            EnableSessionRevocation = $true
            NotificationMode = 'none'
        }
        $receipt = New-AzdPimDeploymentReceipt -Plan $plan -Configuration $configuration -PortalLinks ([pscustomobject]@{}) `
            -PlanReportPath (Join-Path $TestDrive 'plan.json') -AppliedReportPath (Join-Path $TestDrive 'applied.json') `
            -AzureResources ([ordered]@{ sessionRevocationLogicApp = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Logic/workflows/revoke' })

        $receipt.stages.azureInfrastructure.status | Should -Be 'deployed'
        $receipt.stages.tenantConfiguration.status | Should -Be 'applied'
        $receipt.stages.operationalVerification.status | Should -Be 'pending'
        $receipt.stages.operationalVerification.checks[0].id | Should -Be 'sessionRevocation'
        $receipt.scope.privileged.allRolesAcknowledged | Should -BeTrue
    }

    It 'requires the exact privileged all-role acknowledgement when the environment flag is false' {
        $configuration = [pscustomobject]@{
            PrivilegedRoleScope = 'all'; ConfirmAllPrivilegedRoles = $false
            LessPrivilegedRoleScope = 'selected'; ConfirmAllLessPrivilegedRoles = $false
        }
        $plan = [pscustomobject]@{ tiers = [pscustomobject]@{
            privileged = [pscustomobject]@{ roles = @(1, 2, 3) }
            lessPrivileged = [pscustomobject]@{ roles = @() }
        } }

        { Confirm-AzdPimAllRoleScopes -Configuration $configuration -Plan $plan -Prompt { 'no' } } | Should -Throw '*all privileged roles was not confirmed*'
        { Confirm-AzdPimAllRoleScopes -Configuration $configuration -Plan $plan -Prompt { 'ALL PRIVILEGED ROLES' } } | Should -Not -Throw
    }

    It 'accepts explicit environment acknowledgements without prompting' {
        $configuration = [pscustomobject]@{
            PrivilegedRoleScope = 'all'; ConfirmAllPrivilegedRoles = $true
            LessPrivilegedRoleScope = 'all'; ConfirmAllLessPrivilegedRoles = $true
        }
        $plan = [pscustomobject]@{ tiers = [pscustomobject]@{
            privileged = [pscustomobject]@{ roles = @(1) }
            lessPrivileged = [pscustomobject]@{ roles = @(1, 2) }
        } }

        { Confirm-AzdPimAllRoleScopes -Configuration $configuration -Plan $plan -Prompt { throw 'Prompt should not run.' } } | Should -Not -Throw
    }

    It 'marks plan-mode resources unchanged and live verification not run' {
        $plan = [pscustomobject]@{ tenantId = '11111111-1111-4111-8111-111111111111'; tiers = [pscustomobject]@{
            privileged = [pscustomobject]@{ roles = @(1) }; lessPrivileged = [pscustomobject]@{ roles = @() }
        } }
        $configuration = [pscustomobject]@{
            Mode = 'plan'; PrivilegedRoleScope = 'selected'; ConfirmAllPrivilegedRoles = $false
            LessPrivilegedRoleScope = 'selected'; ConfirmAllLessPrivilegedRoles = $false
            EnableSessionRevocation = $true; NotificationMode = 'none'
        }
        $receipt = New-AzdPimDeploymentReceipt -Plan $plan -Configuration $configuration -PortalLinks ([pscustomobject]@{}) `
            -PlanReportPath (Join-Path $TestDrive 'plan.json') -AzureResources ([ordered]@{ sessionRevocationLogicApp = '/subscriptions/sub/workflows/revoke' })

        $receipt.stages.azureInfrastructure.status | Should -Be 'notChanged'
        $receipt.stages.tenantConfiguration.status | Should -Be 'planned'
        $receipt.stages.operationalVerification.status | Should -Be 'notRun'
        $receipt.stages.operationalVerification.checks[0].status | Should -Be 'notRun'
    }
}
