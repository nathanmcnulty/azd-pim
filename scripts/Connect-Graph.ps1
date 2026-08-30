[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $TenantId,
    [switch] $IncludeAllOptionalPermissions
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Authentication.psm1') -Force

$scopeParameters = if ($IncludeAllOptionalPermissions) {
    @{ IncludeEmergencyAccessGroup = $true; NotificationMode = 'polling'; EnableSessionRevocation = $true }
} else {
    @{}
}
$scopes = Get-AzdPimGraphPermissionScope @scopeParameters
$operator = Get-AzdPimAzureOperatorContext
if ($operator.tenantId -ne $TenantId) {
    throw "The requested tenant '$TenantId' does not match the selected Azure CLI tenant '$($operator.tenantId)'."
}
$session = Connect-AzdPimGraph `
    -TenantId $TenantId `
    -ExpectedAccount $operator.account `
    -Scopes $scopes `
    -AllowInteractive `
    -AllowContextReplacement
$session | ConvertTo-Json -Depth 5
