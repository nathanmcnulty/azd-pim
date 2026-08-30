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

    It 'records a sanitized partial receipt when an optional workflow fails after core configuration' {
        $plan = [pscustomobject]@{ tenantId = '11111111-1111-4111-8111-111111111111'; tiers = [pscustomobject]@{
            privileged = [pscustomobject]@{ roles = @(1) }; lessPrivileged = [pscustomobject]@{ roles = @() }
        } }
        $configuration = [pscustomobject]@{
            Mode = 'enforced'; PrivilegedRoleScope = 'selected'; ConfirmAllPrivilegedRoles = $false
            LessPrivilegedRoleScope = 'selected'; ConfirmAllLessPrivilegedRoles = $false
            EnableSessionRevocation = $true; NotificationMode = 'none'
        }

        $receipt = New-AzdPimDeploymentReceipt -Plan $plan -Configuration $configuration -PortalLinks ([pscustomobject]@{}) `
            -PlanReportPath (Join-Path $TestDrive 'plan.json') -AppliedReportPath (Join-Path $TestDrive 'applied.json') -OptionalFailurePhase sessionRevocation

        $receipt.schemaVersion | Should -Be '1.1'
        $receipt.stages.tenantConfiguration.status | Should -Be 'applied'
        $receipt.stages.optionalWorkflows.status | Should -Be 'partial'
        $receipt.stages.optionalWorkflows.failedPhase | Should -Be 'sessionRevocation'
        $receipt.stages.optionalWorkflows.coreTenantConfigurationApplied | Should -BeTrue
        ($receipt.nextSteps -join ' ') | Should -Match 'Core PIM and Conditional Access configuration was applied'
    }

    It 'writes a partial report and receipt before rethrowing an optional workflow failure' {
        $postProvision = Get-Content -Raw (Join-Path $PSScriptRoot '../scripts/Post-Provision.ps1')

        $postProvision | Should -Match 'catch\s*\{[\s\S]*Write-AppliedReport -OptionalFailurePhase \$currentOptionalPhase[\s\S]*Write-DeploymentReceipt -AppliedReportPath \$appliedReportPath -OptionalFailurePhase \$currentOptionalPhase[\s\S]*throw'
        $postProvision | Should -Match 'coreTenantConfigurationApplied = \$true'
    }

    It 'executes the plan-mode Post-Provision receipt path without passing an empty optional phase' {
        $postProvision = Join-Path $PSScriptRoot '../scripts/Post-Provision.ps1'
        $originalEnvironment = @{}
        foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_ENV_NAME')) {
            $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $env:AZURE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
        $env:AZURE_RESOURCE_GROUP = 'rg-pim-test'
        $env:AZURE_ENV_NAME = 'pim-test'

        try {
            $script:receiptParameters = $null
            function Import-AzdEnvironment { }
            function Get-AzdPimConfiguration { }
            function Get-AzdPimAzureOperatorContext { }
            function Connect-AzdPimConfiguredGraph { }
            function Get-AzdPimState { }
            function New-AzdPimPlan { }
            function Write-AzdPimPlanReport { }
            function Get-AzdPimPortalLinks { }
            function New-AzdPimDeploymentReceipt { }
            Mock Import-Module { }
            Mock Import-AzdEnvironment { }
            Mock Get-AzdPimConfiguration {
                [pscustomobject]@{
                    Mode = 'plan'; PrivilegedRoleScope = 'selected'; ConfirmAllPrivilegedRoles = $false
                    LessPrivilegedRoleScope = 'selected'; ConfirmAllLessPrivilegedRoles = $false
                    EnableSessionRevocation = $false; NotificationMode = 'none'
                }
            }
            Mock Get-AzdPimAzureOperatorContext { [pscustomobject]@{ tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; account = 'operator@example.invalid' } }
            Mock Connect-AzdPimConfiguredGraph { }
            Mock Get-AzdPimState { $null }
            Mock New-AzdPimPlan {
                [pscustomobject]@{
                    tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    tiers = [pscustomobject]@{
                        privileged = [pscustomobject]@{ roles = @() }
                        lessPrivileged = [pscustomobject]@{ roles = @() }
                    }
                }
            }
            Mock Write-AzdPimPlanReport { }
            Mock Get-AzdPimPortalLinks { [pscustomobject]@{} }
            Mock New-AzdPimDeploymentReceipt {
                param(
                    [Parameter(Mandatory)] [object] $Plan,
                    [Parameter(Mandatory)] [object] $Configuration,
                    [Parameter(Mandatory)] [object] $PortalLinks,
                    [Parameter(Mandatory)] [string] $PlanReportPath,
                    [string] $AppliedReportPath,
                    [System.Collections.IDictionary] $AzureResources,
                    [ValidateSet('core', 'polling', 'sessionRevocation')] [string] $OptionalFailurePhase
                )
                [pscustomobject]@{ status = 'plan' }
            }
            Mock Set-Content { }
            Mock Write-Host { }

            { & $postProvision } | Should -Not -Throw
            Should -Invoke New-AzdPimDeploymentReceipt -Times 1 -Exactly
        } finally {
            foreach ($name in $originalEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
            }
        }
    }

    It 'executes the successful enforced Post-Provision report and receipt path without an optional phase' {
        $postProvision = Join-Path $PSScriptRoot '../scripts/Post-Provision.ps1'
        $originalEnvironment = @{}
        foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_ENV_NAME')) {
            $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $env:AZURE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
        $env:AZURE_RESOURCE_GROUP = 'rg-pim-test'
        $env:AZURE_ENV_NAME = 'pim-test'

        try {
            function Import-AzdEnvironment { }
            function Get-AzdPimConfiguration { }
            function Get-AzdPimAzureOperatorContext { }
            function Connect-AzdPimConfiguredGraph { }
            function Get-AzdPimState { }
            function New-AzdPimPlan { }
            function Write-AzdPimPlanReport { }
            function Get-AzdPimPortalLinks { }
            function Invoke-AzdPimApply { }
            function Save-AzdPimState { }
            function New-AzdPimDeploymentReceipt { }
            Mock Import-Module { }
            Mock Import-AzdEnvironment { }
            Mock Get-AzdPimConfiguration {
                [pscustomobject]@{
                    Mode = 'enforced'; PrivilegedRoleScope = 'selected'; ConfirmAllPrivilegedRoles = $false
                    LessPrivilegedRoleScope = 'selected'; ConfirmAllLessPrivilegedRoles = $false
                    EnableSessionRevocation = $false; NotificationMode = 'none'
                }
            }
            Mock Get-AzdPimAzureOperatorContext { [pscustomobject]@{ tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; account = 'operator@example.invalid' } }
            Mock Connect-AzdPimConfiguredGraph { }
            Mock Get-AzdPimState { $null }
            Mock New-AzdPimPlan {
                [pscustomobject]@{
                    tenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    tiers = [pscustomobject]@{
                        privileged = [pscustomobject]@{ roles = @() }
                        lessPrivileged = [pscustomobject]@{ roles = @() }
                    }
                }
            }
            Mock Write-AzdPimPlanReport { }
            Mock Get-AzdPimPortalLinks { [pscustomobject]@{} }
            Mock Invoke-AzdPimApply { [pscustomobject]@{ contexts = @(); conditionalAccessPolicies = @() } }
            Mock Save-AzdPimState { }
            Mock New-AzdPimDeploymentReceipt {
                param(
                    [Parameter(Mandatory)] [object] $Plan,
                    [Parameter(Mandatory)] [object] $Configuration,
                    [Parameter(Mandatory)] [object] $PortalLinks,
                    [Parameter(Mandatory)] [string] $PlanReportPath,
                    [string] $AppliedReportPath,
                    [System.Collections.IDictionary] $AzureResources,
                    [ValidateSet('core', 'polling', 'sessionRevocation')] [string] $OptionalFailurePhase
                )
                [pscustomobject]@{ status = 'applied' }
            }
            Mock Set-Content { }
            Mock Write-Host { }

            { & $postProvision } | Should -Not -Throw
            Should -Invoke Invoke-AzdPimApply -Times 1 -Exactly
            Should -Invoke New-AzdPimDeploymentReceipt -Times 1 -Exactly
        } finally {
            foreach ($name in $originalEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
            }
        }
    }
}
