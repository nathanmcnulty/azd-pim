$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AzdPim.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Graph.psm1') -Force

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
$state = Get-AzdPimState
$plan = New-AzdPimPlan -Configuration $configuration -State $state
$reportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'reports/azd-pim-status.json'
Write-AzdPimPlanReport -Plan $plan -Path $reportPath

Write-Host "Tenant: $($plan.tenantId)"
Write-Host "Mode: $($configuration.Mode)"
Write-Host "Privileged roles in scope: $(@($plan.tiers.privileged.roles).Count)"
Write-Host "Less-privileged roles in scope: $(@($plan.tiers.lessPrivileged.roles).Count)"
Write-Host "Current-state report: $reportPath"
foreach ($warning in @($plan.warnings)) { Write-Warning $warning }
