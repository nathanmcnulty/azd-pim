$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AzdPim.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Graph.psm1') -Force

Import-AzdEnvironment

$graphModule = Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1
if (-not $graphModule -or $graphModule.Version -lt [version]'2.30.0') {
    throw 'Microsoft.Graph.Authentication 2.30.0 or later is required. Install-PSResource Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Authentication.psm1') -Force

$defaults = [ordered]@{
    AZD_PIM_MODE = 'plan'
    AZD_PIM_PRIVILEGED_ROLE_SCOPE = 'selected'
    AZD_PIM_CONFIRM_ALL_PRIVILEGED_ROLES = 'false'
    AZD_PIM_PRIVILEGED_ROLE_IDS = ''
    AZD_PIM_LESS_PRIVILEGED_ROLE_SCOPE = 'selected'
    AZD_PIM_CONFIRM_ALL_LESS_PRIVILEGED_ROLES = 'false'
    AZD_PIM_LESS_PRIVILEGED_ROLE_IDS = ''
    AZD_PIM_PRIVILEGED_AUTH_PROFILE = 'mfa'
    AZD_PIM_LESS_PRIVILEGED_AUTH_PROFILE = 'mfa'
    AZD_PIM_PRIVILEGED_DEVICE_REQUIREMENT = 'none'
    AZD_PIM_LESS_PRIVILEGED_DEVICE_REQUIREMENT = 'none'
    AZD_PIM_NOTIFICATION_MODE = 'none'
    AZD_PIM_TEAMS_WEBHOOK_URL = ''
    AZD_PIM_SENTINEL_WORKSPACE_RESOURCE_ID = ''
    AZD_PIM_SENTINEL_WORKSPACE_LOCATION = ''
    AZD_PIM_POLLING_SCHEDULE = '0 */5 * * * *'
    AZD_PIM_POLLING_LOOKBACK_MINUTES = '30'
    AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK = 'false'
    AZD_PIM_ENABLE_SESSION_REVOCATION = 'false'
    AZD_PIM_REVOCATION_FAILURE_BEHAVIOR = 'deny'
    AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID = ''
    AZD_PIM_ADOPT_EXISTING = 'false'
    AZD_PIM_ADOPT_ROLE_CONTEXTS = 'false'
}

foreach ($entry in $defaults.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($entry.Key))) {
        Set-AzdEnvironmentValue -Name $entry.Key -Value $entry.Value
    }
}

$configuration = Get-AzdPimConfiguration
$operator = Get-AzdPimAzureOperatorContext
Connect-AzdPimConfiguredGraph `
    -TenantId $operator.tenantId `
    -ExpectedAccount $operator.account `
    -Configuration $configuration `
    -AllowInteractive `
    -AllowContextReplacement | Out-Null

$state = Get-AzdPimState
$plan = New-AzdPimPlan -Configuration $configuration -State $state
$reportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'reports/azd-pim-plan.json'
Write-AzdPimPlanReport -Plan $plan -Path $reportPath

$privilegedCount = @($plan.tiers.privileged.roles).Count
$lessPrivilegedCount = @($plan.tiers.lessPrivileged.roles).Count
Write-Host "Microsoft Entra plan written to $reportPath"
Write-Host "Tenant: $($plan.tenantId)"
Write-Host "Privileged roles selected: $privilegedCount"
Write-Host "Less-privileged roles selected: $lessPrivilegedCount"
foreach ($warning in @($plan.warnings)) { Write-Warning $warning }

if ($configuration.NotificationMode -eq 'sentinel') {
    Write-Host 'Sentinel notification mode will reuse the configured Log Analytics workspace and deploy a scheduled alert plus Logic App.'
} elseif ($configuration.NotificationMode -eq 'polling') {
    Write-Host 'Polling notification mode will deploy a Flex Consumption Function App with a durable event watermark.'
}
if ($configuration.EnableSessionRevocation) {
    Write-Host 'Session revocation will deploy and onboard an OAuth-protected PIM custom-extension endpoint.'
    if (-not [string]::IsNullOrWhiteSpace($configuration.RevocationAlertActionGroupResourceId)) {
        Write-Host 'Revocation action failures will alert the configured existing Azure Monitor action group.'
    }
}

if ($configuration.Mode -eq 'enforced') {
    if (($privilegedCount + $lessPrivilegedCount) -eq 0) {
        throw 'Enforced mode selected no roles. Select role IDs or change a role scope to all.'
    }

    Confirm-AzdPimAllRoleScopes -Configuration $configuration -Plan $plan

    $confirmed = Get-AzdPimBoolean -Value $env:AZD_PIM_CONFIRM_ENFORCED -Default $false -Name 'AZD_PIM_CONFIRM_ENFORCED'
    if (-not $confirmed) {
        $answer = Read-Host "Type the tenant ID '$($plan.tenantId)' to apply this plan after provisioning"
        if ($answer.Trim() -ne $plan.tenantId) {
            throw 'Enforced deployment was not confirmed. The plan report is available for review.'
        }
    }
}
