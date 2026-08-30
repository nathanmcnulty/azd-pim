$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AzdPim.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Graph.psm1') -Force

Import-AzdEnvironment
Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Authentication.psm1') -Force
$removeTenantConfiguration = Get-AzdPimBoolean -Value $env:AZD_PIM_REMOVE_TENANT_CONFIGURATION -Default $false -Name 'AZD_PIM_REMOVE_TENANT_CONFIGURATION'
if (-not $removeTenantConfiguration) {
    Write-Warning 'Microsoft Entra configuration will be preserved. Set AZD_PIM_REMOVE_TENANT_CONFIGURATION=true before azd down to restore adopted Conditional Access objects and remove solution-created Conditional Access policies. PIM role rules and authentication contexts are always preserved.'
    return
}

$state = Get-AzdPimState
if (-not $state) {
    Write-Warning 'No azd-pim state file exists; no tenant objects will be changed.'
    return
}

$operator = Get-AzdPimAzureOperatorContext
if ($state.tenantId -ne $operator.tenantId.Guid) {
    throw "Refusing cleanup: state belongs to tenant '$($state.tenantId)' and Azure CLI is signed in to '$($operator.tenantId)'."
}
Connect-AzdPimGraph `
    -TenantId $operator.tenantId `
    -ExpectedAccount $operator.account `
    -AllowInteractive `
    -AllowContextReplacement | Out-Null

foreach ($property in @($state.conditionalAccessPolicies.PSObject.Properties)) {
    $entry = $property.Value
    $uri = "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/$($entry.id)"
    if ($entry.created) {
        Invoke-AzdPimGraphRequest -Method DELETE -Uri $uri -AllowNotFound | Out-Null
        Write-Host "Removed solution-created Conditional Access policy $($entry.id)."
        continue
    }

    if ($entry.previous) {
        $previous = $entry.previous
        $body = @{
            displayName = $previous.displayName
            state = $previous.state
            conditions = $previous.conditions
            grantControls = $previous.grantControls
            sessionControls = $previous.sessionControls
        }
        Invoke-AzdPimGraphRequest -Method PATCH -Uri $uri -Body $body | Out-Null
        Write-Host "Restored adopted Conditional Access policy $($entry.id)."
    }
}

Write-Host 'PIM role rules and authentication contexts were preserved by design.'

Write-Host "Conditional Access cleanup completed. Ownership state remains at $(Get-AzdPimStatePath) because PIM rules and authentication contexts remain configured."
