Set-StrictMode -Version Latest

$script:GraphBaseV1 = 'https://graph.microsoft.com/v1.0'
$script:GraphBaseBeta = 'https://graph.microsoft.com/beta'
$script:AuthenticationContextRuleId = 'AuthenticationContext_EndUser_Assignment'

function Invoke-AzdPimGraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [AllowNull()] [object] $Body,
        [switch] $AllowNotFound
    )

    $attempt = 0
    while ($attempt -lt 5) {
        $attempt++
        try {
            if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or
                -not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue) -or
                -not (Get-MgContext)) {
                throw 'A proven Microsoft Graph PowerShell session is required. Run the azd-pim authentication hook before issuing Graph requests.'
            }

            $mgParameters = @{
                Method = $Method
                Uri = $Uri
                OutputType = 'PSObject'
                ErrorAction = 'Stop'
            }
            if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
                $mgParameters.Body = $Body
            }
            return Invoke-MgGraphRequest @mgParameters
        } catch {
            $statusCode = $null
            $responseProperty = $_.Exception.PSObject.Properties['Response']
            $response = if ($responseProperty) { $responseProperty.Value } else { $null }
            if ($response) {
                $statusCodeProperty = $response.PSObject.Properties['StatusCode']
                if ($statusCodeProperty) {
                    $statusCode = [int]$statusCodeProperty.Value
                }
            }
            if ($AllowNotFound -and $statusCode -eq 404) {
                return $null
            }
            if ($statusCode -in @(429, 500, 502, 503, 504) -and $attempt -lt 5) {
                $retryAfter = 0
                $headersProperty = $response.PSObject.Properties['Headers']
                $headers = if ($headersProperty) { $headersProperty.Value } else { $null }
                $retryAfterProperty = if ($headers) { $headers.PSObject.Properties['RetryAfter'] } else { $null }
                if ($retryAfterProperty -and $retryAfterProperty.Value) {
                    $retryAfter = [int]$retryAfterProperty.Value.Delta.TotalSeconds
                }
                if ($retryAfter -le 0) {
                    $retryAfter = [math]::Pow(2, $attempt)
                }
                Start-Sleep -Seconds ([math]::Min($retryAfter, 30))
                continue
            }

            $errorDetailsProperty = $_.PSObject.Properties['ErrorDetails']
            $detail = if ($errorDetailsProperty -and $errorDetailsProperty.Value) { $errorDetailsProperty.Value.Message } else { $null }
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = $_.Exception.Message
            }
            throw "Microsoft Graph $Method $Uri failed$(if ($statusCode) { " with HTTP $statusCode" }): $detail"
        }
    }
}

function Get-AzdPimGraphCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Uri)

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while (-not [string]::IsNullOrWhiteSpace($next)) {
        $response = Invoke-AzdPimGraphRequest -Method GET -Uri $next
        foreach ($item in @($response.value)) {
            $items.Add($item)
        }
        $nextProperty = $response.PSObject.Properties['@odata.nextLink']
        $next = if ($nextProperty) { [string]$nextProperty.Value } else { $null }
    }
    return @($items)
}

function Get-AzdPimTenantId {
    [CmdletBinding()]
    param()

    $graphContext = if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) { Get-MgContext } else { $null }
    if (-not $graphContext -or [string]::IsNullOrWhiteSpace([string] $graphContext.TenantId)) {
        throw 'Unable to resolve the current tenant from a proven Microsoft Graph session.'
    }
    return ([string] $graphContext.TenantId).Trim()
}

function Get-AzdPimRoleInventory {
    [CmdletBinding()]
    param()

    # This preview endpoint currently rejects otherwise common $select and $top
    # options. Use the exact documented isPrivileged filters and combine both
    # classifications so the less-privileged tier is also Graph-derived.
    $privilegedUri = "$script:GraphBaseBeta/roleManagement/directory/roleDefinitions?`$filter=isPrivileged%20eq%20true"
    $lessPrivilegedUri = "$script:GraphBaseBeta/roleManagement/directory/roleDefinitions?`$filter=isPrivileged%20eq%20false"
    $roles = @(
        @(Get-AzdPimGraphCollection -Uri $privilegedUri)
        @(Get-AzdPimGraphCollection -Uri $lessPrivilegedUri)
    )
    if ($roles.Count -eq 0) {
        throw 'Microsoft Graph returned no Microsoft Entra role definitions.'
    }

    $unknown = @($roles | Where-Object { $null -eq $_.isPrivileged })
    if ($unknown.Count -gt 0) {
        throw "Graph returned $($unknown.Count) role definitions without isPrivileged. Classification cannot safely continue."
    }

    $duplicates = @($roles | Group-Object id | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        throw "Graph returned duplicate role definition IDs: $($duplicates.Name -join ', ')."
    }

    return @($roles | Select-Object id, displayName, description, isBuiltIn, isEnabled, isPrivileged | Sort-Object displayName, id)
}

function Resolve-AzdPimRoleSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Inventory,
        [Parameter(Mandatory)] [ValidateSet('all', 'selected')] [string] $Scope,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $SelectedIds,
        [Parameter(Mandatory)] [bool] $ExpectedPrivileged,
        [Parameter(Mandatory)] [string] $TierName
    )

    if ($Scope -eq 'all') {
        return @($Inventory | Where-Object { [bool]$_.isPrivileged -eq $ExpectedPrivileged })
    }

    $resolved = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $SelectedIds) {
        $role = @($Inventory | Where-Object { $_.id -eq $id }) | Select-Object -First 1
        if (-not $role) {
            throw "$TierName selected role definition '$id' does not exist in the current tenant."
        }
        if ([bool]$role.isPrivileged -ne $ExpectedPrivileged) {
            $actual = if ($role.isPrivileged) { 'privileged' } else { 'less-privileged' }
            throw "$TierName selected role '$($role.displayName)' ($id) is classified by Graph as $actual."
        }
        $resolved.Add($role)
    }
    return @($resolved | Sort-Object displayName, id)
}

function Get-AzdPimRolePolicyAssignments {
    [CmdletBinding()]
    param()

    $filter = [uri]::EscapeDataString("scopeId eq '/' and scopeType eq 'DirectoryRole'")
    return @(Get-AzdPimGraphCollection -Uri "$script:GraphBaseV1/policies/roleManagementPolicyAssignments?`$filter=$filter&`$top=999")
}

function Get-AzdPimRolePoliciesWithRules {
    [CmdletBinding()]
    param()

    $filter = [uri]::EscapeDataString("scopeId eq '/' and scopeType eq 'DirectoryRole'")
    return @(Get-AzdPimGraphCollection -Uri "$script:GraphBaseV1/policies/roleManagementPolicies?`$filter=$filter&`$expand=rules&`$top=999")
}

function Get-AzdPimAuthenticationContexts {
    [CmdletBinding()]
    param()

    return @(Get-AzdPimGraphCollection -Uri "$script:GraphBaseV1/identity/conditionalAccess/authenticationContextClassReferences")
}

function Get-AzdPimConditionalAccessPolicies {
    [CmdletBinding()]
    param()

    return @(Get-AzdPimGraphCollection -Uri "$script:GraphBaseBeta/identity/conditionalAccess/policies?`$top=999")
}

function Get-AzdPimReferencedContextIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $ConditionalAccessPolicies,
        [Parameter(Mandatory)] [object[]] $RolePolicies
    )

    $references = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($policy in $ConditionalAccessPolicies) {
        foreach ($id in @($policy.conditions.applications.includeAuthenticationContextClassReferences)) {
            if ($id) { [void]$references.Add([string]$id) }
        }
    }
    foreach ($policy in $RolePolicies) {
        foreach ($rule in @($policy.rules)) {
            if ($rule.id -eq $script:AuthenticationContextRuleId -and $rule.isEnabled -and $rule.claimValue) {
                [void]$references.Add([string]$rule.claimValue)
            }
        }
    }
    return @($references)
}

function Get-AzdPimStateProperty {
    [CmdletBinding()]
    param(
        [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-AzdPimRuleTargetBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Target)

    return @{
        '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyRuleTarget'
        caller = [string]$Target.caller
        operations = @($Target.operations | ForEach-Object { [string]$_ })
        level = [string]$Target.level
        inheritableSettings = @($Target.inheritableSettings | ForEach-Object { [string]$_ })
        enforcedSettings = @($Target.enforcedSettings | ForEach-Object { [string]$_ })
    }
}

function Test-AzdPimStringSetEqual {
    [CmdletBinding()]
    param(
        [AllowNull()] [object[]] $Left,
        [AllowNull()] [object[]] $Right
    )

    $leftValues = @($Left | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    $rightValues = @($Right | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    return ($leftValues -join "`0") -ceq ($rightValues -join "`0")
}

function Test-AzdPimContextMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Existing,
        [Parameter(Mandatory)] [string] $Tier,
        [Parameter(Mandatory)] [string] $DisplayName
    )

    $description = "Authentication context managed by azd-pim for $Tier Microsoft Entra role activation."
    return (
        [string]$Existing.displayName -ceq $DisplayName -and
        [string]$Existing.description -ceq $description -and
        [bool]$Existing.isAvailable
    )
}

function Test-AzdPimConditionalAccessPolicyMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Existing,
        [Parameter(Mandatory)] [object] $Desired
    )

    if ([string]$Existing.displayName -cne [string]$Desired.displayName -or [string]$Existing.state -cne [string]$Desired.state) {
        return $false
    }

    $existingConditions = Get-AzdPimStateProperty -Object $Existing -Name 'conditions'
    $desiredConditions = Get-AzdPimStateProperty -Object $Desired -Name 'conditions'
    $existingApplications = Get-AzdPimStateProperty -Object $existingConditions -Name 'applications'
    $desiredApplications = Get-AzdPimStateProperty -Object $desiredConditions -Name 'applications'
    $existingUsers = Get-AzdPimStateProperty -Object $existingConditions -Name 'users'
    $desiredUsers = Get-AzdPimStateProperty -Object $desiredConditions -Name 'users'
    if (-not (Test-AzdPimStringSetEqual -Left (Get-AzdPimStateProperty -Object $existingConditions -Name 'clientAppTypes') -Right (Get-AzdPimStateProperty -Object $desiredConditions -Name 'clientAppTypes'))) { return $false }
    if (-not (Test-AzdPimStringSetEqual -Left (Get-AzdPimStateProperty -Object $existingApplications -Name 'includeAuthenticationContextClassReferences') -Right (Get-AzdPimStateProperty -Object $desiredApplications -Name 'includeAuthenticationContextClassReferences'))) { return $false }
    if (-not (Test-AzdPimStringSetEqual -Left (Get-AzdPimStateProperty -Object $existingUsers -Name 'includeUsers') -Right (Get-AzdPimStateProperty -Object $desiredUsers -Name 'includeUsers'))) { return $false }
    if (-not (Test-AzdPimStringSetEqual -Left (Get-AzdPimStateProperty -Object $existingUsers -Name 'excludeGroups') -Right (Get-AzdPimStateProperty -Object $desiredUsers -Name 'excludeGroups'))) { return $false }

    $existingGrant = Get-AzdPimStateProperty -Object $Existing -Name 'grantControls'
    $desiredGrant = Get-AzdPimStateProperty -Object $Desired -Name 'grantControls'
    $desiredBuiltInControls = @(Get-AzdPimStateProperty -Object $desiredGrant -Name 'builtInControls')
    if (-not (Test-AzdPimStringSetEqual -Left (Get-AzdPimStateProperty -Object $existingGrant -Name 'builtInControls') -Right $desiredBuiltInControls)) { return $false }
    $existingStrength = Get-AzdPimStateProperty -Object $existingGrant -Name 'authenticationStrength'
    $desiredStrength = Get-AzdPimStateProperty -Object $desiredGrant -Name 'authenticationStrength'
    if ([string](Get-AzdPimStateProperty -Object $existingStrength -Name 'id') -cne [string](Get-AzdPimStateProperty -Object $desiredStrength -Name 'id')) { return $false }
    $grantControlCount = $desiredBuiltInControls.Count + $(if ($desiredStrength) { 1 } else { 0 })
    if ($grantControlCount -gt 1 -and [string]$existingGrant.operator -cne [string]$desiredGrant.operator) { return $false }

    $existingSession = Get-AzdPimStateProperty -Object $Existing -Name 'sessionControls'
    $desiredSession = Get-AzdPimStateProperty -Object $Desired -Name 'sessionControls'
    $existingFrequency = Get-AzdPimStateProperty -Object $existingSession -Name 'signInFrequency'
    $desiredFrequency = Get-AzdPimStateProperty -Object $desiredSession -Name 'signInFrequency'
    if ($desiredFrequency) {
        if (-not $existingFrequency) { return $false }
        foreach ($propertyName in @('isEnabled', 'frequencyInterval', 'authenticationType')) {
            if ([string](Get-AzdPimStateProperty -Object $existingFrequency -Name $propertyName) -cne [string](Get-AzdPimStateProperty -Object $desiredFrequency -Name $propertyName)) { return $false }
        }
    } elseif ($existingFrequency -and [bool](Get-AzdPimStateProperty -Object $existingFrequency -Name 'isEnabled')) {
        return $false
    }

    $existingDevices = Get-AzdPimStateProperty -Object $existingConditions -Name 'devices'
    $desiredDevices = Get-AzdPimStateProperty -Object $desiredConditions -Name 'devices'
    $existingFilter = Get-AzdPimStateProperty -Object $existingDevices -Name 'deviceFilter'
    $desiredFilter = Get-AzdPimStateProperty -Object $desiredDevices -Name 'deviceFilter'
    if ($desiredFilter) {
        if (-not $existingFilter) { return $false }
        foreach ($propertyName in @('mode', 'rule')) {
            if ([string](Get-AzdPimStateProperty -Object $existingFilter -Name $propertyName) -cne [string](Get-AzdPimStateProperty -Object $desiredFilter -Name $propertyName)) { return $false }
        }
    } elseif ($existingFilter) {
        return $false
    }

    return $true
}

function Resolve-AzdPimContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Tier,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [object[]] $Contexts,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $ReservedIds,
        [AllowNull()] [object] $State,
        [Parameter(Mandatory)] [bool] $AdoptExisting
    )

    $stateContexts = Get-AzdPimStateProperty -Object $State -Name 'contexts'
    $stateEntry = Get-AzdPimStateProperty -Object $stateContexts -Name $Tier
    $ownedId = [string](Get-AzdPimStateProperty -Object $stateEntry -Name 'id')

    if ($ownedId) {
        $owned = @($Contexts | Where-Object { $_.id -eq $ownedId }) | Select-Object -First 1
        if ($owned) {
            [void]$ReservedIds.Add($owned.id)
            $action = if (Test-AzdPimContextMatches -Existing $owned -Tier $Tier -DisplayName $DisplayName) { 'none' } else { 'update' }
            return [pscustomobject]@{ id = $owned.id; action = $action; existing = $owned; adopted = $false }
        }
    }

    $matching = @($Contexts | Where-Object { $_.displayName -eq $DisplayName })
    if ($matching.Count -gt 1) {
        throw "Multiple authentication contexts are named '$DisplayName'. Resolve the duplicate names before deployment."
    }
    if ($matching.Count -eq 1) {
        if (-not $AdoptExisting) {
            throw "Authentication context '$DisplayName' already exists as $($matching[0].id). Set AZD_PIM_ADOPT_EXISTING=true only after reviewing it."
        }
        [void]$ReservedIds.Add($matching[0].id)
        return [pscustomobject]@{ id = $matching[0].id; action = 'adoptAndUpdate'; existing = $matching[0]; adopted = $true }
    }

    foreach ($number in 1..25) {
        $id = "c$number"
        if ($ReservedIds.Contains($id)) { continue }
        $existing = @($Contexts | Where-Object { $_.id -eq $id }) | Select-Object -First 1
        $unused = -not $existing -or (
            -not $existing.isAvailable -and
            [string]::IsNullOrWhiteSpace([string]$existing.displayName) -and
            [string]::IsNullOrWhiteSpace([string]$existing.description)
        )
        if ($unused) {
            [void]$ReservedIds.Add($id)
            return [pscustomobject]@{ id = $id; action = 'create'; existing = $existing; adopted = $false }
        }
    }

    throw 'No unused authentication context slots are available between c1 and c25.'
}

function Resolve-AzdPimAuthenticationStrength {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('mfa', 'phishingResistant', 'custom')] [string] $AuthenticationProfile,
        [AllowEmptyString()] [string] $CustomId
    )

    if ($AuthenticationProfile -eq 'mfa') { return $null }
    $policies = @(Get-AzdPimGraphCollection -Uri "$script:GraphBaseV1/policies/authenticationStrengthPolicies?`$top=100")
    if ($AuthenticationProfile -eq 'custom') {
        $match = @($policies | Where-Object { $_.id -eq $CustomId }) | Select-Object -First 1
        if (-not $match) { throw "Authentication strength '$CustomId' does not exist in the tenant." }
        return $match
    }

    $strengthMatches = @($policies | Where-Object {
        $_.policyType -eq 'builtIn' -and $_.displayName -match '(?i)^phishing[- ]resistant MFA$'
    })
    if ($strengthMatches.Count -ne 1) {
        throw "Expected one built-in phishing-resistant MFA authentication strength, found $($strengthMatches.Count)."
    }
    return $strengthMatches[0]
}

function New-AzdPimGrantControls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('mfa', 'phishingResistant', 'custom')] [string] $AuthenticationProfile,
        [AllowNull()] [object] $AuthenticationStrength,
        [Parameter(Mandatory)] [ValidateSet('none', 'compliant', 'hybridJoined', 'compliantOrHybrid')] [string] $DeviceRequirement
    )

    $controls = [System.Collections.Generic.List[string]]::new()
    if ($AuthenticationProfile -eq 'mfa') { $controls.Add('mfa') }
    if ($DeviceRequirement -eq 'compliant') { $controls.Add('compliantDevice') }
    if ($DeviceRequirement -eq 'hybridJoined') { $controls.Add('domainJoinedDevice') }

    $grant = [ordered]@{ operator = 'AND' }
    if ($controls.Count -gt 0) { $grant.builtInControls = @($controls) }
    if ($AuthenticationProfile -ne 'mfa') { $grant.authenticationStrength = @{ id = $AuthenticationStrength.id } }
    return $grant
}

function New-AzdPimConditionalAccessBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $ContextId,
        [AllowEmptyString()] [string] $EmergencyAccessGroupId,
        [Parameter(Mandatory)] [string] $AuthenticationProfile,
        [AllowNull()] [object] $AuthenticationStrength,
        [Parameter(Mandatory)] [string] $DeviceRequirement,
        [ValidateSet('enabled', 'disabled')] [string] $State = 'enabled'
    )

    $users = [ordered]@{ includeUsers = @('All') }
    if ($EmergencyAccessGroupId) { $users.excludeGroups = @($EmergencyAccessGroupId) }
    $primaryDeviceRequirement = if ($DeviceRequirement -eq 'compliantOrHybrid') { 'none' } else { $DeviceRequirement }

    return [ordered]@{
        displayName = $DisplayName
        state = $State
        conditions = [ordered]@{
            clientAppTypes = @('all')
            applications = @{ includeAuthenticationContextClassReferences = @($ContextId) }
            users = $users
        }
        grantControls = New-AzdPimGrantControls -AuthenticationProfile $AuthenticationProfile -AuthenticationStrength $AuthenticationStrength -DeviceRequirement $primaryDeviceRequirement
        sessionControls = @{
            signInFrequency = @{
                isEnabled = $true
                frequencyInterval = 'everyTime'
                authenticationType = 'primaryAndSecondaryAuthentication'
            }
        }
    }
}

function New-AzdPimDeviceCompanionBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $ContextId,
        [AllowEmptyString()] [string] $EmergencyAccessGroupId
    )

    $users = [ordered]@{ includeUsers = @('All') }
    if ($EmergencyAccessGroupId) { $users.excludeGroups = @($EmergencyAccessGroupId) }
    return [ordered]@{
        displayName = "$DisplayName - Device requirement"
        state = 'enabled'
        conditions = [ordered]@{
            clientAppTypes = @('all')
            applications = @{ includeAuthenticationContextClassReferences = @($ContextId) }
            users = $users
        }
        grantControls = @{
            operator = 'OR'
            builtInControls = @('compliantDevice', 'domainJoinedDevice')
        }
    }
}

function New-AzdPimDeviceAllowlistBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $ContextId,
        [AllowEmptyString()] [string] $EmergencyAccessGroupId,
        [Parameter(Mandatory)] [string[]] $AllowedDeviceIds
    )

    $users = [ordered]@{ includeUsers = @('All') }
    if ($EmergencyAccessGroupId) { $users.excludeGroups = @($EmergencyAccessGroupId) }
    $quotedIds = @($AllowedDeviceIds | ForEach-Object { "`"$($_.ToLowerInvariant())`"" }) -join ','
    return [ordered]@{
        displayName = "$DisplayName - Block unapproved devices"
        state = 'enabled'
        conditions = [ordered]@{
            clientAppTypes = @('all')
            applications = @{ includeAuthenticationContextClassReferences = @($ContextId) }
            users = $users
            devices = @{
                deviceFilter = @{
                    mode = 'exclude'
                    rule = "device.deviceId -in [$quotedIds]"
                }
            }
        }
        grantControls = @{ operator = 'OR'; builtInControls = @('block') }
    }
}

function Resolve-AzdPimConditionalAccessPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [object] $Body,
        [Parameter(Mandatory)] [object[]] $Policies,
        [AllowNull()] [object] $State,
        [Parameter(Mandatory)] [bool] $AdoptExisting
    )

    $statePolicies = Get-AzdPimStateProperty -Object $State -Name 'conditionalAccessPolicies'
    $stateEntry = Get-AzdPimStateProperty -Object $statePolicies -Name $Key
    $ownedId = [string](Get-AzdPimStateProperty -Object $stateEntry -Name 'id')
    if ($ownedId) {
        $owned = @($Policies | Where-Object { $_.id -eq $ownedId }) | Select-Object -First 1
        if ($owned) {
            $action = if (Test-AzdPimConditionalAccessPolicyMatches -Existing $owned -Desired $Body) { 'none' } else { 'update' }
            return [pscustomobject]@{ key = $Key; id = $owned.id; action = $action; existing = $owned; body = $Body; adopted = $false }
        }
    }

    $matching = @($Policies | Where-Object { $_.displayName -eq $DisplayName })
    if ($matching.Count -gt 1) { throw "Multiple Conditional Access policies are named '$DisplayName'." }
    if ($matching.Count -eq 1) {
        if (-not $AdoptExisting) {
            throw "Conditional Access policy '$DisplayName' already exists. Set AZD_PIM_ADOPT_EXISTING=true only after reviewing it."
        }
        return [pscustomobject]@{ key = $Key; id = $matching[0].id; action = 'adoptAndUpdate'; existing = $matching[0]; body = $Body; adopted = $true }
    }
    return [pscustomobject]@{ key = $Key; id = $null; action = 'create'; existing = $null; body = $Body; adopted = $false }
}

function Test-AzdPimEmergencyGroup {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $GroupId)

    if (-not $GroupId) { return $null }
    $group = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphBaseV1/groups/${GroupId}?`$select=id,displayName,securityEnabled,membershipRule"
    if (-not $group.securityEnabled) {
        throw "Emergency-access group '$($group.displayName)' is not security-enabled."
    }
    $members = Get-AzdPimGraphCollection -Uri "$script:GraphBaseV1/groups/$GroupId/members?`$select=id&`$top=999"
    return [pscustomobject]@{ id = $group.id; displayName = $group.displayName; memberCount = @($members).Count }
}

function ConvertTo-AzdPimReportConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Configuration)

    $safeConfiguration = [ordered]@{}
    foreach ($property in $Configuration.PSObject.Properties) {
        if ($property.Name -eq 'TeamsWebhookUrl') { continue }
        $safeConfiguration[$property.Name] = $property.Value
    }
    $safeConfiguration.TeamsWebhookConfigured = -not [string]::IsNullOrWhiteSpace(
        [string] $Configuration.TeamsWebhookUrl
    )
    return [pscustomobject] $safeConfiguration
}

function New-AzdPimPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Configuration,
        [AllowNull()] [object] $State
    )

    $tenantId = Get-AzdPimTenantId
    if ($State -and $State.tenantId -and $State.tenantId -ne $tenantId) {
        throw "State belongs to tenant '$($State.tenantId)', but Azure CLI is signed in to '$tenantId'."
    }

    $inventory = @(Get-AzdPimRoleInventory)
    $privilegedRoles = @(Resolve-AzdPimRoleSelection -Inventory $inventory -Scope $Configuration.PrivilegedRoleScope -SelectedIds $Configuration.PrivilegedRoleIds -ExpectedPrivileged $true -TierName 'Privileged')
    $lessPrivilegedRoles = @(Resolve-AzdPimRoleSelection -Inventory $inventory -Scope $Configuration.LessPrivilegedRoleScope -SelectedIds $Configuration.LessPrivilegedRoleIds -ExpectedPrivileged $false -TierName 'Less-privileged')
    $emergencyGroup = Test-AzdPimEmergencyGroup -GroupId $Configuration.EmergencyAccessGroupId
    $assignments = @(Get-AzdPimRolePolicyAssignments)
    $rolePolicies = @(Get-AzdPimRolePoliciesWithRules)
    $contexts = @(Get-AzdPimAuthenticationContexts)
    $caPolicies = @(Get-AzdPimConditionalAccessPolicies)
    $referencedIds = @(Get-AzdPimReferencedContextIds -ConditionalAccessPolicies $caPolicies -RolePolicies $rolePolicies)
    $reservedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $referencedIds) { [void]$reservedIds.Add($id) }

    $warnings = [System.Collections.Generic.List[string]]::new()
    if (-not $emergencyGroup) {
        $warnings.Add('No emergency-access group was supplied. This is supported, but excluding an established emergency-access group is recommended.')
    } else {
        $warnings.Add("Emergency-access group '$($emergencyGroup.displayName)' has $($emergencyGroup.memberCount) direct members. Membership is informational and is not modified.")
    }
    if ($Configuration.NotificationMode -eq 'sentinel') {
        $warnings.Add('Sentinel notifications require Microsoft Entra AuditLogs to already be routed to the selected workspace.')
    } elseif ($Configuration.NotificationMode -eq 'polling') {
        $warnings.Add('Polling notifications read Microsoft Graph directory audits on a schedule; delivery latency is bounded by the polling interval and Graph audit availability.')
    }
    if ($Configuration.EnableSessionRevocation) {
        $warnings.Add('Session revocation uses preview PIM custom extensions. Roles without human approval use pre-approval; roles requiring human approval use post-approval. Revocation is not instantaneous.')
    }

    $tiers = [ordered]@{}
    foreach ($definition in @(
        @{ Key = 'privileged'; Roles = $privilegedRoles; ContextName = $Configuration.PrivilegedContextDisplayName; PolicyName = $Configuration.PrivilegedPolicyDisplayName; Profile = $Configuration.PrivilegedAuthenticationProfile; StrengthId = $Configuration.PrivilegedAuthenticationStrengthId; Device = $Configuration.PrivilegedDeviceRequirement; DeviceIds = $Configuration.PrivilegedAllowedDeviceIds },
        @{ Key = 'lessPrivileged'; Roles = $lessPrivilegedRoles; ContextName = $Configuration.LessPrivilegedContextDisplayName; PolicyName = $Configuration.LessPrivilegedPolicyDisplayName; Profile = $Configuration.LessPrivilegedAuthenticationProfile; StrengthId = $Configuration.LessPrivilegedAuthenticationStrengthId; Device = $Configuration.LessPrivilegedDeviceRequirement; DeviceIds = @() }
    )) {
        if (@($definition.Roles).Count -eq 0) {
            $tiers[$definition.Key] = [pscustomobject]@{ roles = @(); context = $null; authenticationStrength = $null; conditionalAccessPolicies = @(); roleRules = @() }
            continue
        }

        $context = Resolve-AzdPimContext -Tier $definition.Key -DisplayName $definition.ContextName -Contexts $contexts -ReservedIds $reservedIds -State $State -AdoptExisting $Configuration.AdoptExisting
        $strength = Resolve-AzdPimAuthenticationStrength -AuthenticationProfile $definition.Profile -CustomId $definition.StrengthId
        $caBodies = [System.Collections.Generic.List[object]]::new()
        $caBodies.Add((New-AzdPimConditionalAccessBody -DisplayName $definition.PolicyName -ContextId $context.id -EmergencyAccessGroupId $Configuration.EmergencyAccessGroupId -AuthenticationProfile $definition.Profile -AuthenticationStrength $strength -DeviceRequirement $definition.Device))
        if ($definition.Device -eq 'compliantOrHybrid') {
            $caBodies.Add((New-AzdPimDeviceCompanionBody -DisplayName $definition.PolicyName -ContextId $context.id -EmergencyAccessGroupId $Configuration.EmergencyAccessGroupId))
        }
        if (@($definition.DeviceIds).Count -gt 0) {
            $caBodies.Add((New-AzdPimDeviceAllowlistBody -DisplayName $definition.PolicyName -ContextId $context.id -EmergencyAccessGroupId $Configuration.EmergencyAccessGroupId -AllowedDeviceIds $definition.DeviceIds))
        }

        $resolvedCa = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $caBodies.Count; $index++) {
            $policyKey = if ($index -eq 0) { $definition.Key } elseif ($caBodies[$index].displayName -like '*unapproved devices') { "$($definition.Key)DeviceAllowlist" } else { "$($definition.Key)Device" }
            $resolvedCa.Add((Resolve-AzdPimConditionalAccessPolicy -Key $policyKey -DisplayName $caBodies[$index].displayName -Body $caBodies[$index] -Policies $caPolicies -State $State -AdoptExisting $Configuration.AdoptExisting))
        }

        $roleRules = [System.Collections.Generic.List[object]]::new()
        foreach ($role in $definition.Roles) {
            $assignment = @($assignments | Where-Object { $_.roleDefinitionId -eq $role.id }) | Select-Object -First 1
            if (-not $assignment) { throw "No PIM role management policy assignment was found for '$($role.displayName)' ($($role.id))." }
            $policy = @($rolePolicies | Where-Object { $_.id -eq $assignment.policyId }) | Select-Object -First 1
            if (-not $policy) { throw "PIM policy '$($assignment.policyId)' for '$($role.displayName)' was not returned by Graph." }
            $rule = @($policy.rules | Where-Object { $_.id -eq $script:AuthenticationContextRuleId }) | Select-Object -First 1
            if (-not $rule) { throw "PIM policy '$($policy.id)' has no $script:AuthenticationContextRuleId rule." }
            $enablementRule = @($policy.rules | Where-Object { $_.id -eq 'Enablement_EndUser_Assignment' }) | Select-Object -First 1
            if (-not $enablementRule) { throw "PIM policy '$($policy.id)' has no Enablement_EndUser_Assignment rule." }
            $differentContext = $rule.isEnabled -and $rule.claimValue -and $rule.claimValue -ne $context.id
            if ($differentContext -and -not $Configuration.AdoptRoleContexts) {
                throw "Role '$($role.displayName)' already requires authentication context '$($rule.claimValue)'. Set AZD_PIM_ADOPT_ROLE_CONTEXTS=true only after reviewing the conflict."
            }
            $action = if ($rule.isEnabled -and $rule.claimValue -eq $context.id) { 'none' } else { 'update' }
            $existingEnabledRules = @($enablementRule.enabledRules | ForEach-Object { [string]$_ })
            $activationMfaAction = if ('MultiFactorAuthentication' -in $existingEnabledRules) { 'remove' } else { 'none' }
            $roleRules.Add([pscustomobject]@{
                role = $role
                policyId = $policy.id
                action = $action
                existing = $rule
                desiredContextId = $context.id
                activationMfa = [pscustomobject]@{
                    action = $activationMfaAction
                    existing = $enablementRule
                    desiredEnabledRules = @($existingEnabledRules | Where-Object { $_ -ne 'MultiFactorAuthentication' })
                }
            })
        }

        $activationMfaChanges = @($roleRules | Where-Object { $_.activationMfa.action -eq 'remove' }).Count
        if ($activationMfaChanges -gt 0) {
            $warnings.Add("$activationMfaChanges $($definition.Key) role activation policies currently enable the legacy PIM MultiFactorAuthentication rule. Enforcement will remove only that value because it cannot coexist with an authentication context; other activation requirements are preserved.")
        }

        $tiers[$definition.Key] = [pscustomobject]@{
            roles = @($definition.Roles)
            context = [pscustomobject]@{ id = $context.id; displayName = $definition.ContextName; action = $context.action; existing = $context.existing; adopted = $context.adopted }
            authenticationStrength = $strength
            conditionalAccessPolicies = @($resolvedCa)
            roleRules = @($roleRules)
        }
    }

    return [pscustomobject]@{
        schemaVersion = '1.0'
        generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        tenantId = $tenantId
        mode = $Configuration.Mode
        graphApiVersions = @{ roleClassification = 'beta'; conditionalAccessContextTargeting = 'beta'; pimRoleRules = 'v1.0'; authenticationContexts = 'v1.0'; pimCustomExtensions = 'beta' }
        configuration = ConvertTo-AzdPimReportConfiguration -Configuration $Configuration
        emergencyAccessGroup = $emergencyGroup
        warnings = @($warnings)
        inventory = @($inventory)
        tiers = [pscustomobject]$tiers
    }
}

function Write-AzdPimPlanReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $Path
    )

    $configurationContainsWebhook = if ($Plan.configuration -is [System.Collections.IDictionary]) {
        $Plan.configuration.Contains('TeamsWebhookUrl')
    } else {
        @($Plan.configuration.PSObject.Properties.Name) -contains 'TeamsWebhookUrl'
    }
    if ($configurationContainsWebhook) {
        throw 'The PIM plan contains a sensitive Teams webhook URL and cannot be written.'
    }

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $Plan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Invoke-AzdPimApply {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [AllowNull()] [object] $ExistingState
    )

    if ($Plan.mode -ne 'enforced') { throw 'Invoke-AzdPimApply requires an enforced plan.' }
    $state = [ordered]@{
        schemaVersion = '1.0'
        tenantId = $Plan.tenantId
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        contexts = [ordered]@{}
        conditionalAccessPolicies = [ordered]@{}
        appliedRoleRules = [ordered]@{}
    }
    if ($ExistingState) {
        foreach ($sectionName in @('contexts', 'conditionalAccessPolicies', 'appliedRoleRules')) {
            $existingSection = Get-AzdPimStateProperty -Object $ExistingState -Name $sectionName
            if (-not $existingSection) { continue }
            foreach ($property in @($existingSection.PSObject.Properties)) {
                $state[$sectionName][$property.Name] = $property.Value
            }
        }
    }

    foreach ($tierName in @('privileged', 'lessPrivileged')) {
        $tier = $Plan.tiers.$tierName
        if (-not $tier.context) { continue }
        $contextBody = @{
            displayName = $tier.context.displayName
            description = "Authentication context managed by azd-pim for $tierName Microsoft Entra role activation."
            isAvailable = $true
        }
        if ($tier.context.action -ne 'none' -and $PSCmdlet.ShouldProcess("authentication context $($tier.context.id)", $tier.context.action)) {
            Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphBaseV1/identity/conditionalAccess/authenticationContextClassReferences/$($tier.context.id)" -Body $contextBody | Out-Null
        }
        $recordedContext = if ($state.contexts.Contains($tierName)) { $state.contexts[$tierName] } else { $null }
        if (-not $recordedContext -or $recordedContext.id -ne $tier.context.id) {
            $state.contexts[$tierName] = [ordered]@{ id = $tier.context.id; created = ($tier.context.action -eq 'create'); adopted = [bool]$tier.context.adopted; previous = $tier.context.existing }
        }
    }

    foreach ($tierName in @('privileged', 'lessPrivileged')) {
        $tier = $Plan.tiers.$tierName
        foreach ($policy in @($tier.conditionalAccessPolicies)) {
            $policyId = $policy.id
            if ($policy.action -eq 'create') {
                if ($PSCmdlet.ShouldProcess($policy.body.displayName, 'create Conditional Access policy')) {
                    $created = Invoke-AzdPimGraphRequest -Method POST -Uri "$script:GraphBaseBeta/identity/conditionalAccess/policies" -Body $policy.body
                    $policyId = $created.id
                }
            } elseif ($policy.action -ne 'none') {
                if ($PSCmdlet.ShouldProcess($policy.body.displayName, 'update Conditional Access policy')) {
                    Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphBaseBeta/identity/conditionalAccess/policies/$policyId" -Body $policy.body | Out-Null
                }
            }
            $recordedPolicy = if ($state.conditionalAccessPolicies.Contains($policy.key)) { $state.conditionalAccessPolicies[$policy.key] } else { $null }
            if (-not $recordedPolicy -or $recordedPolicy.id -ne $policyId) {
                $state.conditionalAccessPolicies[$policy.key] = [ordered]@{ id = $policyId; created = ($policy.action -eq 'create'); adopted = [bool]$policy.adopted; previous = $policy.existing }
            }
        }
    }

    foreach ($tierName in @('privileged', 'lessPrivileged')) {
        $tier = $Plan.tiers.$tierName
        foreach ($roleRule in @($tier.roleRules)) {
            $activationMfa = Get-AzdPimStateProperty -Object $roleRule -Name 'activationMfa'
            $removedActivationMfa = $false
            if ($activationMfa -and $activationMfa.action -eq 'remove' -and $roleRule.action -eq 'none') {
                throw "Role '$($roleRule.role.displayName)' unexpectedly requires legacy MFA removal without an authentication-context update."
            }
            if ($activationMfa -and $activationMfa.action -eq 'remove') {
                $enablementBody = @{
                    '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyEnablementRule'
                    id = 'Enablement_EndUser_Assignment'
                    enabledRules = @($activationMfa.desiredEnabledRules | ForEach-Object { [string]$_ })
                    target = ConvertTo-AzdPimRuleTargetBody -Target $activationMfa.existing.target
                }
                if ($PSCmdlet.ShouldProcess($roleRule.role.displayName, 'remove legacy PIM activation MFA before attaching an authentication context')) {
                    Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphBaseV1/policies/roleManagementPolicies/$($roleRule.policyId)/rules/Enablement_EndUser_Assignment" -Body $enablementBody | Out-Null
                    $removedActivationMfa = $true
                }
            }

            if ($roleRule.action -eq 'none') {
                if (-not $state.appliedRoleRules.Contains($roleRule.role.id)) {
                    $state.appliedRoleRules[$roleRule.role.id] = [ordered]@{ policyId = $roleRule.policyId; roleDisplayName = $roleRule.role.displayName; desiredContextId = $roleRule.desiredContextId; removedLegacyActivationMfa = $false; appliedAt = [DateTimeOffset]::UtcNow.ToString('o') }
                }
                continue
            }
            $body = @{
                '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyAuthenticationContextRule'
                isEnabled = $true
                claimValue = $roleRule.desiredContextId
                target = ConvertTo-AzdPimRuleTargetBody -Target $roleRule.existing.target
            }
            try {
                if ($PSCmdlet.ShouldProcess($roleRule.role.displayName, "attach authentication context $($roleRule.desiredContextId)")) {
                    Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphBaseV1/policies/roleManagementPolicies/$($roleRule.policyId)/rules/$script:AuthenticationContextRuleId" -Body $body | Out-Null
                }
            } catch {
                $activationError = $_
                if ($removedActivationMfa) {
                    $restoreBody = @{
                        '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyEnablementRule'
                        id = 'Enablement_EndUser_Assignment'
                        enabledRules = @($activationMfa.existing.enabledRules | ForEach-Object { [string]$_ })
                        target = ConvertTo-AzdPimRuleTargetBody -Target $activationMfa.existing.target
                    }
                    try {
                        Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphBaseV1/policies/roleManagementPolicies/$($roleRule.policyId)/rules/Enablement_EndUser_Assignment" -Body $restoreBody | Out-Null
                    } catch {
                        throw "Authentication-context attachment failed for '$($roleRule.role.displayName)', and restoring its legacy activation MFA rule also failed. Attachment: $($activationError.Exception.Message) Restore: $($_.Exception.Message)"
                    }
                }
                throw $activationError
            }
            $state.appliedRoleRules[$roleRule.role.id] = [ordered]@{ policyId = $roleRule.policyId; roleDisplayName = $roleRule.role.displayName; desiredContextId = $roleRule.desiredContextId; removedLegacyActivationMfa = $removedActivationMfa; appliedAt = [DateTimeOffset]::UtcNow.ToString('o') }
        }
    }

    return [pscustomobject]$state
}

Export-ModuleMember -Function @(
    'Invoke-AzdPimGraphRequest',
    'Get-AzdPimGraphCollection',
    'Get-AzdPimTenantId',
    'Get-AzdPimRoleInventory',
    'Resolve-AzdPimRoleSelection',
    'Get-AzdPimAuthenticationContexts',
    'Get-AzdPimConditionalAccessPolicies',
    'Get-AzdPimReferencedContextIds',
    'Resolve-AzdPimContext',
    'Resolve-AzdPimAuthenticationStrength',
    'New-AzdPimGrantControls',
    'New-AzdPimConditionalAccessBody',
    'New-AzdPimDeviceCompanionBody',
    'New-AzdPimDeviceAllowlistBody',
    'New-AzdPimPlan',
    'Write-AzdPimPlanReport',
    'Invoke-AzdPimApply'
)
