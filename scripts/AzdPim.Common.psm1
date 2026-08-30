Set-StrictMode -Version Latest

function Import-AzdEnvironment {
    [CmdletBinding()]
    param()

    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
        throw 'Azure Developer CLI (azd) was not found on PATH.'
    }

    foreach ($line in (azd env get-values)) {
        if ([string]::IsNullOrWhiteSpace($line) -or -not $line.Contains('=')) {
            continue
        }

        $parts = $line.Split('=', 2)
        $value = $parts[1]
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2).Replace('\"', '"')
        }
        Set-Item -Path "env:$($parts[0])" -Value $value
    }
}

function Set-AzdEnvironmentValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    azd env set $Name $Value | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to set azd environment value '$Name'."
    }
    Set-Item -Path "env:$Name" -Value $Value
}

function Get-AzdPimBoolean {
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Value,
        [bool] $Default = $false,
        [string] $Name = 'value'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        default { throw "$Name must be true or false." }
    }
}

function Get-AzdPimChoice {
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory)] [string] $Default,
        [Parameter(Mandatory)] [string[]] $Allowed,
        [Parameter(Mandatory)] [string] $Name
    )

    $resolved = if ([string]::IsNullOrWhiteSpace($Value)) { $Default } else { $Value.Trim() }
    $match = @($Allowed | Where-Object { $_ -ieq $resolved }) | Select-Object -First 1
    if (-not $match) {
        throw "$Name must be one of: $($Allowed -join ', ')."
    }
    return $match
}

function ConvertFrom-AzdPimList {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('[')) {
        try {
            $items = @($trimmed | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            throw "List value is not valid JSON: $($_.Exception.Message)"
        }
    } else {
        $items = @($trimmed -split '[;,\r\n]+')
    }

    return @($items | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Assert-AzdPimGuidList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Values,
        [Parameter(Mandatory)] [string] $Name
    )

    foreach ($value in $Values) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($value, [ref]$parsed)) {
            throw "$Name contains an invalid GUID: '$value'."
        }
    }
}

function Get-AzdPimConfiguration {
    [CmdletBinding()]
    param()

    $privilegedRoleIds = @(ConvertFrom-AzdPimList -Value $env:AZD_PIM_PRIVILEGED_ROLE_IDS)
    $lessPrivilegedRoleIds = @(ConvertFrom-AzdPimList -Value $env:AZD_PIM_LESS_PRIVILEGED_ROLE_IDS)
    $allowedDeviceIds = @(ConvertFrom-AzdPimList -Value $env:AZD_PIM_PRIVILEGED_ALLOWED_DEVICE_IDS)

    Assert-AzdPimGuidList -Values $privilegedRoleIds -Name 'AZD_PIM_PRIVILEGED_ROLE_IDS'
    Assert-AzdPimGuidList -Values $lessPrivilegedRoleIds -Name 'AZD_PIM_LESS_PRIVILEGED_ROLE_IDS'
    Assert-AzdPimGuidList -Values $allowedDeviceIds -Name 'AZD_PIM_PRIVILEGED_ALLOWED_DEVICE_IDS'

    if (-not [string]::IsNullOrWhiteSpace($env:AZD_PIM_EMERGENCY_ACCESS_GROUP_ID)) {
        Assert-AzdPimGuidList -Values @($env:AZD_PIM_EMERGENCY_ACCESS_GROUP_ID.Trim()) -Name 'AZD_PIM_EMERGENCY_ACCESS_GROUP_ID'
    }

    $configuration = [ordered]@{
        Mode                           = Get-AzdPimChoice -Value $env:AZD_PIM_MODE -Default 'plan' -Allowed @('plan', 'enforced') -Name 'AZD_PIM_MODE'
        PrivilegedRoleScope            = Get-AzdPimChoice -Value $env:AZD_PIM_PRIVILEGED_ROLE_SCOPE -Default 'selected' -Allowed @('selected', 'all') -Name 'AZD_PIM_PRIVILEGED_ROLE_SCOPE'
        ConfirmAllPrivilegedRoles      = Get-AzdPimBoolean -Value $env:AZD_PIM_CONFIRM_ALL_PRIVILEGED_ROLES -Default $false -Name 'AZD_PIM_CONFIRM_ALL_PRIVILEGED_ROLES'
        PrivilegedRoleIds              = $privilegedRoleIds
        LessPrivilegedRoleScope        = Get-AzdPimChoice -Value $env:AZD_PIM_LESS_PRIVILEGED_ROLE_SCOPE -Default 'selected' -Allowed @('selected', 'all') -Name 'AZD_PIM_LESS_PRIVILEGED_ROLE_SCOPE'
        ConfirmAllLessPrivilegedRoles  = Get-AzdPimBoolean -Value $env:AZD_PIM_CONFIRM_ALL_LESS_PRIVILEGED_ROLES -Default $false -Name 'AZD_PIM_CONFIRM_ALL_LESS_PRIVILEGED_ROLES'
        LessPrivilegedRoleIds          = $lessPrivilegedRoleIds
        PrivilegedAuthenticationProfile = Get-AzdPimChoice -Value $env:AZD_PIM_PRIVILEGED_AUTH_PROFILE -Default 'mfa' -Allowed @('mfa', 'phishingResistant', 'custom') -Name 'AZD_PIM_PRIVILEGED_AUTH_PROFILE'
        PrivilegedAuthenticationStrengthId = ([string]$env:AZD_PIM_PRIVILEGED_AUTH_STRENGTH_ID).Trim()
        LessPrivilegedAuthenticationProfile = Get-AzdPimChoice -Value $env:AZD_PIM_LESS_PRIVILEGED_AUTH_PROFILE -Default 'mfa' -Allowed @('mfa', 'phishingResistant', 'custom') -Name 'AZD_PIM_LESS_PRIVILEGED_AUTH_PROFILE'
        LessPrivilegedAuthenticationStrengthId = ([string]$env:AZD_PIM_LESS_PRIVILEGED_AUTH_STRENGTH_ID).Trim()
        PrivilegedDeviceRequirement    = Get-AzdPimChoice -Value $env:AZD_PIM_PRIVILEGED_DEVICE_REQUIREMENT -Default 'none' -Allowed @('none', 'compliant', 'hybridJoined', 'compliantOrHybrid') -Name 'AZD_PIM_PRIVILEGED_DEVICE_REQUIREMENT'
        LessPrivilegedDeviceRequirement = Get-AzdPimChoice -Value $env:AZD_PIM_LESS_PRIVILEGED_DEVICE_REQUIREMENT -Default 'none' -Allowed @('none', 'compliant', 'hybridJoined', 'compliantOrHybrid') -Name 'AZD_PIM_LESS_PRIVILEGED_DEVICE_REQUIREMENT'
        PrivilegedAllowedDeviceIds     = $allowedDeviceIds
        EmergencyAccessGroupId         = ([string]$env:AZD_PIM_EMERGENCY_ACCESS_GROUP_ID).Trim()
        AdoptExisting                  = Get-AzdPimBoolean -Value $env:AZD_PIM_ADOPT_EXISTING -Default $false -Name 'AZD_PIM_ADOPT_EXISTING'
        AdoptRoleContexts              = Get-AzdPimBoolean -Value $env:AZD_PIM_ADOPT_ROLE_CONTEXTS -Default $false -Name 'AZD_PIM_ADOPT_ROLE_CONTEXTS'
        NotificationMode               = Get-AzdPimChoice -Value $env:AZD_PIM_NOTIFICATION_MODE -Default 'none' -Allowed @('none', 'sentinel', 'polling') -Name 'AZD_PIM_NOTIFICATION_MODE'
        TeamsWebhookUrl                = ([string]$env:AZD_PIM_TEAMS_WEBHOOK_URL).Trim()
        SentinelWorkspaceResourceId    = ([string]$env:AZD_PIM_SENTINEL_WORKSPACE_RESOURCE_ID).Trim()
        SentinelWorkspaceLocation      = ([string]$env:AZD_PIM_SENTINEL_WORKSPACE_LOCATION).Trim()
        PollingSchedule                 = if ($env:AZD_PIM_POLLING_SCHEDULE) { $env:AZD_PIM_POLLING_SCHEDULE.Trim() } else { '0 */5 * * * *' }
        PollingLookbackMinutes          = if ($env:AZD_PIM_POLLING_LOOKBACK_MINUTES) { [int]$env:AZD_PIM_POLLING_LOOKBACK_MINUTES } else { 30 }
        PollingSendInitialLookback      = Get-AzdPimBoolean -Value $env:AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK -Default $false -Name 'AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK'
        EnableSessionRevocation        = Get-AzdPimBoolean -Value $env:AZD_PIM_ENABLE_SESSION_REVOCATION -Default $false -Name 'AZD_PIM_ENABLE_SESSION_REVOCATION'
        RevocationFailureBehavior      = Get-AzdPimChoice -Value $env:AZD_PIM_REVOCATION_FAILURE_BEHAVIOR -Default 'deny' -Allowed @('deny', 'approve') -Name 'AZD_PIM_REVOCATION_FAILURE_BEHAVIOR'
        RevocationAlertActionGroupResourceId = ([string]$env:AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID).Trim()
        PrivilegedContextDisplayName   = if ($env:AZD_PIM_PRIVILEGED_CONTEXT_NAME) { $env:AZD_PIM_PRIVILEGED_CONTEXT_NAME.Trim() } else { 'PIM Privileged Roles' }
        LessPrivilegedContextDisplayName = if ($env:AZD_PIM_LESS_PRIVILEGED_CONTEXT_NAME) { $env:AZD_PIM_LESS_PRIVILEGED_CONTEXT_NAME.Trim() } else { 'PIM Less-Privileged Roles' }
        PrivilegedPolicyDisplayName    = if ($env:AZD_PIM_PRIVILEGED_CA_POLICY_NAME) { $env:AZD_PIM_PRIVILEGED_CA_POLICY_NAME.Trim() } else { 'PIM - Privileged Roles - Require reauthentication' }
        LessPrivilegedPolicyDisplayName = if ($env:AZD_PIM_LESS_PRIVILEGED_CA_POLICY_NAME) { $env:AZD_PIM_LESS_PRIVILEGED_CA_POLICY_NAME.Trim() } else { 'PIM - Less-Privileged Roles - Require reauthentication' }
    }

    foreach ($tier in @('Privileged', 'LessPrivileged')) {
        $authenticationProfile = $configuration["${tier}AuthenticationProfile"]
        $strengthId = $configuration["${tier}AuthenticationStrengthId"]
        if ($authenticationProfile -eq 'custom') {
            Assert-AzdPimGuidList -Values @($strengthId) -Name "${tier}AuthenticationStrengthId"
        }
    }

    if ($configuration.NotificationMode -ne 'none') {
        if ([string]::IsNullOrWhiteSpace($configuration.TeamsWebhookUrl)) {
            throw 'AZD_PIM_TEAMS_WEBHOOK_URL is required when notifications are enabled.'
        }
        $teamsWebhook = $null
        if (-not [uri]::TryCreate($configuration.TeamsWebhookUrl, [System.UriKind]::Absolute, [ref]$teamsWebhook) -or $teamsWebhook.Scheme -ne 'https') {
            throw 'AZD_PIM_TEAMS_WEBHOOK_URL must be an absolute HTTPS URL.'
        }
    }

    if ($configuration.NotificationMode -eq 'sentinel') {
        if ($configuration.SentinelWorkspaceResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
            throw 'AZD_PIM_SENTINEL_WORKSPACE_RESOURCE_ID must be a Log Analytics workspace resource ID when sentinel notifications are selected.'
        }
        if ([string]::IsNullOrWhiteSpace($configuration.SentinelWorkspaceLocation)) {
            throw 'AZD_PIM_SENTINEL_WORKSPACE_LOCATION is required when sentinel notifications are selected.'
        }
    }

    if ($configuration.PollingLookbackMinutes -lt 5 -or $configuration.PollingLookbackMinutes -gt 1440) {
        throw 'AZD_PIM_POLLING_LOOKBACK_MINUTES must be between 5 and 1440.'
    }

    if (-not [string]::IsNullOrWhiteSpace($configuration.RevocationAlertActionGroupResourceId) -and
        $configuration.RevocationAlertActionGroupResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Insights/actionGroups/[^/]+$') {
        throw 'AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID must be an Azure Monitor action group resource ID.'
    }
    if (-not [string]::IsNullOrWhiteSpace($configuration.RevocationAlertActionGroupResourceId) -and -not $configuration.EnableSessionRevocation) {
        throw 'AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID requires AZD_PIM_ENABLE_SESSION_REVOCATION=true.'
    }

    return [pscustomobject]$configuration
}

function Get-AzdPimStatePath {
    [CmdletBinding()]
    param()

    if ($env:AZD_PIM_STATE_PATH) {
        return [System.IO.Path]::GetFullPath($env:AZD_PIM_STATE_PATH)
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    $environmentName = if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { 'default' }
    return Join-Path $projectRoot ".azure/$environmentName/azd-pim-state.json"
}

function Get-AzdPimState {
    [CmdletBinding()]
    param()

    $path = Get-AzdPimStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
}

function Save-AzdPimState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $State)

    $path = Get-AzdPimStatePath
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporaryPath = "$path.tmp"
    $State | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Get-AzdPimPortalLinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [guid] $TenantId,
        [string] $SubscriptionId,
        [string] $ResourceGroupName,
        [System.Collections.IDictionary] $AzureResources = [ordered]@{}
    )

    $links = [ordered]@{
        pimRoleActivation = 'https://entra.microsoft.com/#view/Microsoft_AAD_PIM/ActivationMenuBlade/~/aadmigratedroles'
        conditionalAccessPolicies = 'https://entra.microsoft.com/#view/Microsoft_AAD_ConditionalAccess/ConditionalAccessBlade/~/Policies'
    }
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId) -and -not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $resourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
        $links.azureResourceGroup = "https://portal.azure.com/#@$($TenantId.Guid)/resource$resourceGroupId/overview"
    }
    foreach ($entry in $AzureResources.GetEnumerator()) {
        $resourceId = ([string]$entry.Value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($resourceId)) {
            $links[[string]$entry.Key] = "https://portal.azure.com/#@$($TenantId.Guid)/resource$resourceId/overview"
        }
    }
    return [pscustomobject]$links
}

function New-AzdPimDeploymentReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [object] $Configuration,
        [Parameter(Mandatory)] [object] $PortalLinks,
        [Parameter(Mandatory)] [string] $PlanReportPath,
        [string] $AppliedReportPath,
        [System.Collections.IDictionary] $AzureResources = [ordered]@{},
        [ValidateSet('core', 'polling', 'sessionRevocation')] [string] $OptionalFailurePhase
    )

    $resourceEntries = @($AzureResources.GetEnumerator() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object {
        [pscustomobject]@{ name = [string]$_.Key; resourceId = [string]$_.Value }
    })
    $verificationChecks = [System.Collections.Generic.List[object]]::new()
    if ($Configuration.EnableSessionRevocation) {
        $verificationChecks.Add([pscustomobject]@{
            id = 'sessionRevocation'
            status = if ($Configuration.Mode -eq 'plan') { 'notRun' } else { 'pending' }
            evidenceRequired = 'Activate one selected PIM role and confirm the callback and Revoke_sign_in_sessions action succeed.'
        })
    }
    if ($Configuration.NotificationMode -ne 'none') {
        $verificationChecks.Add([pscustomobject]@{
            id = 'teamsNotificationDelivery'
            status = if ($Configuration.Mode -eq 'plan') { 'notRun' } else { 'pending' }
            evidenceRequired = 'Confirm a real PIM activation is delivered to the configured Teams channel with its stable event ID.'
        })
    }

    $isPlan = $Configuration.Mode -eq 'plan'
    $nextSteps = [System.Collections.Generic.List[string]]::new()
    if ($isPlan) {
        $nextSteps.Add('Review the plan report, preserve the selected scope, and change AZD_PIM_MODE to enforced only when ready.')
    } else {
        if ($OptionalFailurePhase -eq 'core') {
            $nextSteps.Add('Core PIM and Conditional Access configuration did not complete. Review the partial receipt and durable state, correct the failure, and rerun the same environment without adopting same-named Entra resources.')
        } elseif ($OptionalFailurePhase) {
            $nextSteps.Add("Core PIM and Conditional Access configuration was applied. Correct the failed optional '$OptionalFailurePhase' workflow and rerun the same environment; do not delete or adopt same-named Entra resources.")
        }
        if ($verificationChecks.Count -gt 0) {
            $nextSteps.Add('Complete each pending live verification check; deployment success alone is not delivery or callback proof.')
        } else {
            $nextSteps.Add('Review the applied report and activate a selected pilot role to validate the authentication-context experience.')
        }
    }

    return [pscustomobject]@{
        schemaVersion = '1.1'
        generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        environmentName = [string]$env:AZURE_ENV_NAME
        tenantId = [string]$Plan.tenantId
        mode = [string]$Configuration.Mode
        scope = [pscustomobject]@{
            privileged = [pscustomobject]@{
                selection = [string]$Configuration.PrivilegedRoleScope
                roleCount = @($Plan.tiers.privileged.roles).Count
                allRolesAcknowledged = [bool]$Configuration.ConfirmAllPrivilegedRoles
            }
            lessPrivileged = [pscustomobject]@{
                selection = [string]$Configuration.LessPrivilegedRoleScope
                roleCount = @($Plan.tiers.lessPrivileged.roles).Count
                allRolesAcknowledged = [bool]$Configuration.ConfirmAllLessPrivilegedRoles
            }
        }
        stages = [pscustomobject]@{
            azureInfrastructure = [pscustomobject]@{
                status = if ($isPlan) { 'notChanged' } elseif ($resourceEntries.Count -gt 0) { 'deployed' } else { 'notRequired' }
                resources = $resourceEntries
            }
            tenantConfiguration = [pscustomobject]@{
                status = if ($isPlan) { 'planned' } elseif ($OptionalFailurePhase -eq 'core') { 'partial' } else { 'applied' }
                privilegedRoleCount = @($Plan.tiers.privileged.roles).Count
                lessPrivilegedRoleCount = @($Plan.tiers.lessPrivileged.roles).Count
            }
            operationalVerification = [pscustomobject]@{
                status = if ($isPlan -and $verificationChecks.Count -gt 0) { 'notRun' } elseif ($verificationChecks.Count -gt 0) { 'pending' } else { 'notRequired' }
                checks = @($verificationChecks)
            }
            optionalWorkflows = [pscustomobject]@{
                status = if ($OptionalFailurePhase -eq 'core') { 'notRun' } elseif ($OptionalFailurePhase) { 'partial' } elseif ($Configuration.NotificationMode -ne 'none' -or $Configuration.EnableSessionRevocation) { 'configured' } else { 'notRequired' }
                failedPhase = if ($OptionalFailurePhase) { $OptionalFailurePhase } else { $null }
                coreTenantConfigurationApplied = (-not $isPlan -and $OptionalFailurePhase -ne 'core')
            }
        }
        artifacts = [pscustomobject]@{
            plan = [System.IO.Path]::GetFullPath($PlanReportPath)
            applied = if ([string]::IsNullOrWhiteSpace($AppliedReportPath)) { $null } else { [System.IO.Path]::GetFullPath($AppliedReportPath) }
        }
        portalLinks = $PortalLinks
        nextSteps = @($nextSteps)
    }
}

function Confirm-AzdPimAllRoleScopes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Configuration,
        [Parameter(Mandatory)] [object] $Plan,
        [scriptblock] $Prompt = { param($Message) Read-Host $Message }
    )

    $scopeConfirmations = @(
        [pscustomobject]@{
            IsAll = $Configuration.PrivilegedRoleScope -eq 'all'
            IsConfirmed = [bool]$Configuration.ConfirmAllPrivilegedRoles
            Count = @($Plan.tiers.privileged.roles).Count
            Label = 'privileged'
            ConfirmationText = 'ALL PRIVILEGED ROLES'
        }
        [pscustomobject]@{
            IsAll = $Configuration.LessPrivilegedRoleScope -eq 'all'
            IsConfirmed = [bool]$Configuration.ConfirmAllLessPrivilegedRoles
            Count = @($Plan.tiers.lessPrivileged.roles).Count
            Label = 'less-privileged'
            ConfirmationText = 'ALL LESS-PRIVILEGED ROLES'
        }
    )
    foreach ($scopeConfirmation in $scopeConfirmations | Where-Object IsAll) {
        if ($scopeConfirmation.IsConfirmed) {
            Write-Host "Confirmed all $($scopeConfirmation.Count) $($scopeConfirmation.Label) roles through the explicit environment acknowledgement."
            continue
        }

        $message = "This plan targets all $($scopeConfirmation.Count) $($scopeConfirmation.Label) roles. Type '$($scopeConfirmation.ConfirmationText)' to continue"
        $answer = [string](& $Prompt $message)
        if ($answer.Trim() -cne $scopeConfirmation.ConfirmationText) {
            throw "Enforcement for all $($scopeConfirmation.Label) roles was not confirmed. The plan report is available for review."
        }
    }
}

Export-ModuleMember -Function @(
    'Import-AzdEnvironment',
    'Set-AzdEnvironmentValue',
    'Get-AzdPimBoolean',
    'Get-AzdPimChoice',
    'ConvertFrom-AzdPimList',
    'Assert-AzdPimGuidList',
    'Get-AzdPimConfiguration',
    'Get-AzdPimStatePath',
    'Get-AzdPimState',
    'Save-AzdPimState',
    'Get-AzdPimPortalLinks',
    'New-AzdPimDeploymentReceipt',
    'Confirm-AzdPimAllRoleScopes'
)
