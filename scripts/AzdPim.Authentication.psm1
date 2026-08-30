Set-StrictMode -Version Latest

$vendorModule = Join-Path $PSScriptRoot 'vendor/Azd.GraphAuthentication/Azd.GraphAuthentication.psd1'
Import-Module $vendorModule -Force -ErrorAction Stop

function Get-AzdPimGraphPermissionScope {
    [CmdletBinding()]
    param(
        [switch] $IncludeEmergencyAccessGroup,
        [ValidateSet('none', 'sentinel', 'polling')] [string] $NotificationMode = 'none',
        [switch] $EnableSessionRevocation
    )

    $scopes = @(
        'AuthenticationContext.ReadWrite.All'
        'Policy.Read.All'
        'Policy.ReadWrite.ConditionalAccess'
        'RoleManagement.Read.Directory'
        'RoleManagementPolicy.ReadWrite.Directory'
    )
    if ($IncludeEmergencyAccessGroup) {
        $scopes += 'Group.Read.All'
    }
    if ($NotificationMode -eq 'polling') {
        $scopes += @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All')
    }
    if ($EnableSessionRevocation) {
        $scopes += @(
            'Application.ReadWrite.All'
            'AppRoleAssignment.ReadWrite.All'
            'PrivilegedAccess-CustomExt.ReadWrite.All'
        )
    }
    return @($scopes | Sort-Object -Unique)
}

function Connect-AzdPimGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [guid] $TenantId,
        [Parameter(Mandatory)] [string] $ExpectedAccount,
        [string[]] $Scopes = (Get-AzdPimGraphPermissionScope),
        [switch] $AllowInteractive,
        [switch] $AllowContextReplacement,
        [ValidateRange(60, 900)] [int] $ClientTimeoutSeconds = 300
    )

    $connectParameters = @{
        TenantId = $TenantId.Guid
        ExpectedAccount = $ExpectedAccount
        Scopes = $Scopes
        ProbeUri = '/v1.0/roleManagement/directory/roleDefinitions?$select=id'
        Environment = 'Global'
        ClientTimeoutSeconds = $ClientTimeoutSeconds
    }
    if ($AllowInteractive) {
        $connectParameters.AllowInteractive = $true
    }
    if ($AllowContextReplacement) {
        $connectParameters.AllowContextReplacement = $true
    }

    return Connect-AzdGraphSession @connectParameters
}

function Get-AzdPimAzureOperatorContext {
    [CmdletBinding()]
    param()

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) was not found on PATH.'
    }
    $rawContext = az account show --output json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($rawContext -join [Environment]::NewLine))) {
        throw 'Azure CLI is not signed in. Run az login for the intended tenant and administrator.'
    }
    try {
        $context = ($rawContext -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Azure CLI returned an invalid account context: $($_.Exception.Message)"
    }

    if ([string] $context.user.type -ine 'user') {
        throw 'azd-pim requires an interactive Azure CLI user account so Microsoft Graph can use the same administrator identity.'
    }
    $account = [string] $context.user.name
    if ($account -notmatch '^[^@\s]+@[^@\s]+$') {
        throw 'The selected Azure CLI user does not expose a valid administrator user principal name.'
    }
    $tenantId = [guid]::Empty
    if (-not [guid]::TryParse([string] $context.tenantId, [ref] $tenantId)) {
        throw 'The selected Azure CLI account does not expose a valid tenant ID.'
    }

    return [pscustomobject] [ordered]@{
        tenantId = $tenantId
        account = $account
    }
}

function Connect-AzdPimConfiguredGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [guid] $TenantId,
        [Parameter(Mandatory)] [string] $ExpectedAccount,
        [Parameter(Mandatory)] [object] $Configuration,
        [switch] $AllowInteractive,
        [switch] $AllowContextReplacement
    )

    $scopeParameters = @{
        IncludeEmergencyAccessGroup = -not [string]::IsNullOrWhiteSpace($Configuration.EmergencyAccessGroupId)
        NotificationMode = $Configuration.NotificationMode
        EnableSessionRevocation = $Configuration.EnableSessionRevocation
    }
    $scopes = Get-AzdPimGraphPermissionScope @scopeParameters
    return Connect-AzdPimGraph `
        -TenantId $TenantId `
        -ExpectedAccount $ExpectedAccount `
        -Scopes $scopes `
        -AllowInteractive:$AllowInteractive `
        -AllowContextReplacement:$AllowContextReplacement
}

Export-ModuleMember -Function @(
    'Get-AzdPimGraphPermissionScope',
    'Get-AzdPimAzureOperatorContext',
    'Connect-AzdPimGraph',
    'Connect-AzdPimConfiguredGraph'
)
