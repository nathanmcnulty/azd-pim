$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AzdPim.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Graph.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Optional.psm1') -Force

Import-AzdEnvironment
Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Authentication.psm1') -Force
$configuration = Get-AzdPimConfiguration
$operator = Get-AzdPimAzureOperatorContext
Connect-AzdPimConfiguredGraph `
    -TenantId $operator.tenantId `
    -ExpectedAccount $operator.account `
    -Configuration $configuration `
    -AllowInteractive `
    -AllowContextReplacement | Out-Null
$existingState = Get-AzdPimState
$plan = New-AzdPimPlan -Configuration $configuration -State $existingState
$reportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'reports/azd-pim-plan.json'
Write-AzdPimPlanReport -Plan $plan -Path $reportPath

$azureResources = [ordered]@{
    pollingFunction = [string]$env:AZD_PIM_POLLING_FUNCTION_RESOURCE_ID
    sentinelNotificationLogicApp = [string]$env:AZD_PIM_SENTINEL_NOTIFICATION_LOGIC_APP_RESOURCE_ID
    sentinelActivationAlert = [string]$env:AZD_PIM_SENTINEL_NOTIFICATION_ALERT_RESOURCE_ID
    sentinelNotificationActionGroup = [string]$env:AZD_PIM_SENTINEL_NOTIFICATION_ACTION_GROUP_RESOURCE_ID
    sessionRevocationLogicApp = [string]$env:AZD_PIM_REVOCATION_LOGIC_APP_RESOURCE_ID
    sessionRevocationFailureAlert = [string]$env:AZD_PIM_REVOCATION_ALERT_RESOURCE_ID
}
$subscriptionId = if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { az account show --query id -o tsv }
$portalLinks = Get-AzdPimPortalLinks -TenantId ([guid]$plan.tenantId) -SubscriptionId $subscriptionId -ResourceGroupName $env:AZURE_RESOURCE_GROUP -AzureResources $azureResources
$receiptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'reports/azd-pim-deployment.json'

function Write-DeploymentReceipt {
    param([string] $AppliedReportPath, [ValidateSet('core', 'polling', 'sessionRevocation')] [string] $OptionalFailurePhase)

    $receiptParameters = @{
        Plan = $plan
        Configuration = $configuration
        PortalLinks = $portalLinks
        PlanReportPath = $reportPath
        AppliedReportPath = $AppliedReportPath
        AzureResources = $azureResources
    }
    if (-not [string]::IsNullOrWhiteSpace($OptionalFailurePhase)) {
        $receiptParameters.OptionalFailurePhase = $OptionalFailurePhase
    }
    $receipt = New-AzdPimDeploymentReceipt @receiptParameters
    $receipt | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
}

function Write-AppliedReport {
    param(
        [ValidateSet('core', 'polling', 'sessionRevocation')] [string] $OptionalFailurePhase,
        [bool] $CoreTenantConfigurationApplied = $true
    )

    $appliedReportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'reports/azd-pim-applied.json'
    [pscustomobject]@{
        appliedAt = [DateTimeOffset]::UtcNow.ToString('o')
        tenantId = $plan.tenantId
        deploymentStatus = if ($OptionalFailurePhase) { 'partial' } else { 'applied' }
        coreTenantConfigurationApplied = $CoreTenantConfigurationApplied
        optionalFailurePhase = $OptionalFailurePhase
        privilegedRoles = @($plan.tiers.privileged.roles | Select-Object id, displayName, isPrivileged)
        lessPrivilegedRoles = @($plan.tiers.lessPrivileged.roles | Select-Object id, displayName, isPrivileged)
        contexts = if ($state) { $state.contexts } else { @() }
        conditionalAccessPolicies = if ($state) { $state.conditionalAccessPolicies } else { @() }
        optionalWorkflows = $optionalResults
        portalLinks = $portalLinks
    } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $appliedReportPath -Encoding utf8NoBOM
    return $appliedReportPath
}

function Write-PortalLinks {
    Write-Host 'Administrator links:'
    foreach ($link in $portalLinks.PSObject.Properties) {
        Write-Host "  $($link.Name): $($link.Value)"
    }
}

if ($configuration.Mode -eq 'plan') {
    Write-DeploymentReceipt
    Write-Host "Plan mode completed without Microsoft Entra changes. Review $reportPath"
    Write-Host "Deployment receipt: $receiptPath"
    Write-PortalLinks
    return
}

$optionalResults = [ordered]@{}
$state = $existingState
try {
    $state = Invoke-AzdPimApply -Plan $plan -ExistingState $existingState -Confirm:$false -StateChanged {
        param($checkpoint)
        Save-AzdPimState -State $checkpoint
    }
    Save-AzdPimState -State $state
} catch {
    $state = Get-AzdPimState
    $appliedReportPath = Write-AppliedReport -OptionalFailurePhase core -CoreTenantConfigurationApplied $false
    Write-DeploymentReceipt -AppliedReportPath $appliedReportPath -OptionalFailurePhase core
    Write-Warning 'Core PIM or Conditional Access configuration did not complete; a sanitized partial receipt was written before rethrowing.'
    throw
}

$currentOptionalPhase = $null
try {
    if ($configuration.NotificationMode -eq 'polling') {
        $currentOptionalPhase = 'polling'
        if ([string]::IsNullOrWhiteSpace($env:AZD_PIM_POLLING_FUNCTION_NAME) -or [string]::IsNullOrWhiteSpace($env:AZD_PIM_POLLING_FUNCTION_PRINCIPAL_ID)) {
            throw 'The polling Function App deployment outputs are missing.'
        }
        Publish-AzdPimPollingFunction -FunctionAppName $env:AZD_PIM_POLLING_FUNCTION_NAME -FunctionPrincipalId $env:AZD_PIM_POLLING_FUNCTION_PRINCIPAL_ID -ResourceGroupName $env:AZURE_RESOURCE_GROUP
        $optionalResults.pollingFunctionApp = $env:AZD_PIM_POLLING_FUNCTION_NAME
    } elseif ($configuration.NotificationMode -eq 'sentinel') {
        $optionalResults.notificationMode = 'sentinel'
    }

    if ($configuration.EnableSessionRevocation) {
        $currentOptionalPhase = 'sessionRevocation'
        if ([string]::IsNullOrWhiteSpace($env:AZD_PIM_REVOCATION_LOGIC_APP_RESOURCE_ID) -or [string]::IsNullOrWhiteSpace($env:AZD_PIM_REVOCATION_LOGIC_APP_PRINCIPAL_ID)) {
            throw 'The session-revocation Logic App deployment outputs are missing.'
        }
        $sessionRevocation = Initialize-AzdPimRevocationExtension -WorkflowResourceId $env:AZD_PIM_REVOCATION_LOGIC_APP_RESOURCE_ID -WorkflowPrincipalId $env:AZD_PIM_REVOCATION_LOGIC_APP_PRINCIPAL_ID -TenantId $plan.tenantId -EnvironmentName $env:AZURE_ENV_NAME -State $state -PersistState { param($checkpoint) Save-AzdPimState -State $checkpoint }
        $scopedRoleRules = @($plan.tiers.privileged.roleRules) + @($plan.tiers.lessPrivileged.roleRules)
        $sessionRevocation | Add-Member -NotePropertyName roleLinking -NotePropertyValue @(
            Enable-AzdPimRevocationExtensionForRoles -RoleRules $scopedRoleRules -PreApprovalCustomExtensionId $sessionRevocation.preApprovalCustomExtensionId -PostApprovalCustomExtensionId $sessionRevocation.postApprovalCustomExtensionId
        )
        $optionalResults.sessionRevocation = $sessionRevocation
    }
} catch {
    $appliedReportPath = Write-AppliedReport -OptionalFailurePhase $currentOptionalPhase
    Write-DeploymentReceipt -AppliedReportPath $appliedReportPath -OptionalFailurePhase $currentOptionalPhase
    Write-Warning "Core PIM and Conditional Access configuration was applied. Optional workflow '$currentOptionalPhase' failed; a sanitized partial receipt was written before rethrowing."
    throw
}

$appliedReportPath = Write-AppliedReport

Write-DeploymentReceipt -AppliedReportPath $appliedReportPath

Write-Host "Applied azd-pim configuration to tenant $($plan.tenantId)."
Write-Host "Deployment report: $appliedReportPath"
Write-Host "Deployment receipt: $receiptPath"
Write-Host "State file: $(Get-AzdPimStatePath)"
Write-PortalLinks
