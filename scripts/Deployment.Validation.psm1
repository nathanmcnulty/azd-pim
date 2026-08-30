Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AzdPim.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Graph.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AzdPim.Authentication.psm1') -Force

$script:ValidationConfiguration = $null
$script:ValidationPlan = $null
$script:ValidationGraphContext = $null

function Resolve-AzdPimValidationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('context', 'configuration', 'discovery', 'infrastructure', 'delivery')] [string] $Category,
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $message = [string] $ErrorRecord.Exception.Message
    switch ($Category) {
        'context' {
            if ($message -like '*tenant*does not match*' -or $message -like '*tenant mismatch*') {
                return New-AzdCheckFailure -Code 'context.tenantMismatch' `
                    -Summary 'The azd, Azure CLI, and Microsoft Graph tenants do not match.' `
                    -Expected 'One exact tenant across every cached context.' `
                    -Remediation 'Use the normal broker or browser sign-in for the expected tenant, select the configured subscription, and rerun validation.'
            }
            if ($message -like '*subscription*does not match*' -or $message -like '*subscription mismatch*') {
                return New-AzdCheckFailure -Code 'context.subscriptionMismatch' `
                    -Summary 'The active Azure CLI subscription does not match the azd environment.' `
                    -Expected 'The exact azd subscription is active in Azure CLI.' `
                    -Remediation 'Select the expected subscription with az account set and rerun validation.'
            }
            if ($message -like '*required Microsoft Graph delegated scopes*') {
                return New-AzdCheckFailure -Code 'context.graphScopesMissing' `
                    -Summary 'The cached Microsoft Graph context lacks required delegated scopes.' `
                    -Expected 'Every scope needed for the configured PIM features.' `
                    -Remediation 'Run the solution through the normal broker or browser sign-in so the configured scopes can be consented, then rerun validation.'
            }
            return New-AzdCheckFailure -Code 'context.sessionUnavailable' `
                -Summary 'The cached azd, Azure CLI, and Microsoft Graph context could not be validated.' `
                -Expected 'Usable cached sessions for the configured tenant and subscription.' `
                -Remediation 'Sign in through the normal broker or browser flow for the intended tenant and rerun validation.'
        }
        'configuration' {
            return New-AzdCheckFailure -Code 'configuration.invalid' `
                -Summary 'The PIM environment configuration is invalid.' `
                -Expected 'Valid independent selected or all scope for both role tiers and valid optional workflow settings.' `
                -Remediation 'Correct the azd environment values described in README.md and rerun validation.'
        }
        'discovery' {
            return New-AzdCheckFailure -Code 'discovery.planFailed' `
                -Summary 'The read-only Microsoft Entra PIM plan could not be rebuilt.' `
                -Expected 'Complete Graph role classification, PIM policy, authentication context, and Conditional Access reads.' `
                -Remediation 'Confirm the cached Graph context, delegated scopes, directory roles, and selected role definition IDs, then rerun validation.'
        }
        'infrastructure' {
            return New-AzdCheckFailure -Code 'infrastructure.optionalResourceReadFailed' `
                -Summary 'A configured optional Azure resource could not be verified.' `
                -Expected 'Every enabled optional workflow resource is readable in the selected subscription.' `
                -Remediation 'Confirm provisioning completed and the active Azure subscription matches the azd environment.'
        }
        default {
            return New-AzdCheckFailure -Code 'delivery.teamsDestinationFailed' `
                -Summary 'The clearly labeled Teams destination test was not accepted.' `
                -Expected 'An HTTP success response from the configured Teams Workflow webhook.' `
                -Remediation 'Confirm the Teams Workflow is enabled and the webhook secret is current, then rerun with -TestDelivery.'
        }
    }
}

function Initialize-AzdPimValidationContext {
    [CmdletBinding()]
    param()

    Import-AzdEnvironment
    if ([string]::IsNullOrWhiteSpace($env:AZURE_SUBSCRIPTION_ID)) {
        throw 'AZURE_SUBSCRIPTION_ID is required.'
    }
    $expectedSubscriptionId = [guid]::Empty
    if (-not [guid]::TryParse([string] $env:AZURE_SUBSCRIPTION_ID, [ref] $expectedSubscriptionId)) {
        throw 'AZURE_SUBSCRIPTION_ID must be a valid GUID.'
    }
    $explicitTenantId = [guid]::Empty
    $hasExplicitTenantId = -not [string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID)
    if ($hasExplicitTenantId -and
        -not [guid]::TryParse([string] $env:AZURE_TENANT_ID, [ref] $explicitTenantId)) {
        throw 'AZURE_TENANT_ID must be a valid GUID when supplied.'
    }

    $configuredJson = & az account show --subscription $expectedSubscriptionId.Guid `
        --query '{id:id,tenantId:tenantId}' --only-show-errors --output json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($configuredJson)) {
        throw 'The configured Azure subscription could not be read from the cached Azure CLI session.'
    }
    $activeJson = & az account show --query '{id:id,tenantId:tenantId}' --only-show-errors --output json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($activeJson)) {
        throw 'The active Azure CLI context could not be read.'
    }
    try {
        $configured = $configuredJson | ConvertFrom-Json -ErrorAction Stop
        $active = $activeJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'Azure CLI returned an invalid subscription or active account context.'
    }
    $configuredSubscriptionId = [guid]::Empty
    $configuredTenantId = [guid]::Empty
    $activeSubscriptionId = [guid]::Empty
    $activeTenantId = [guid]::Empty
    if (-not [guid]::TryParse([string] $configured.id, [ref] $configuredSubscriptionId) -or
        -not [guid]::TryParse([string] $configured.tenantId, [ref] $configuredTenantId) -or
        -not [guid]::TryParse([string] $active.id, [ref] $activeSubscriptionId) -or
        -not [guid]::TryParse([string] $active.tenantId, [ref] $activeTenantId)) {
        throw 'Azure CLI returned a subscription or tenant context without valid GUIDs.'
    }
    if ($configuredSubscriptionId -ne $expectedSubscriptionId -or $activeSubscriptionId -ne $expectedSubscriptionId) {
        throw 'Azure subscription context does not match the azd environment.'
    }
    if ($configuredTenantId -ne $activeTenantId -or
        ($hasExplicitTenantId -and $configuredTenantId -ne $explicitTenantId)) {
        throw 'Azure tenant context does not match the azd environment.'
    }
    $effectiveTenantId = if ($hasExplicitTenantId) { $explicitTenantId } else { $configuredTenantId }
    if (-not $hasExplicitTenantId) {
        [Environment]::SetEnvironmentVariable(
            'AZURE_TENANT_ID',
            $effectiveTenantId.Guid,
            [EnvironmentVariableTarget]::Process
        )
    }

    $graphModule = Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $graphModule -or $graphModule.Version -lt [version] '2.30.0') {
        throw 'Microsoft.Graph.Authentication 2.30.0 or later is required.'
    }
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
    $context = Get-MgContext
    $graphTenantId = [guid]::Empty
    if (-not $context -or
        -not [guid]::TryParse([string] $context.TenantId, [ref] $graphTenantId) -or
        $graphTenantId -ne $effectiveTenantId) {
        throw 'Microsoft Graph tenant context does not match the azd environment.'
    }
    $script:ValidationGraphContext = $context
}

function Assert-AzdPimValidationGraphScope {
    [CmdletBinding()]
    param()

    if (-not $script:ValidationConfiguration -or -not $script:ValidationGraphContext) {
        throw 'The validation configuration and Microsoft Graph context must be initialized first.'
    }
    $scopeParameters = @{
        IncludeEmergencyAccessGroup = -not [string]::IsNullOrWhiteSpace($script:ValidationConfiguration.EmergencyAccessGroupId)
        NotificationMode = $script:ValidationConfiguration.NotificationMode
        EnableSessionRevocation = $script:ValidationConfiguration.EnableSessionRevocation
    }
    $requiredScopes = @(Get-AzdPimGraphPermissionScope @scopeParameters)
    $missingScopes = @($requiredScopes | Where-Object { $_ -notin @($script:ValidationGraphContext.Scopes) })
    if ($missingScopes.Count -gt 0) {
        throw 'The cached context is missing required Microsoft Graph delegated scopes.'
    }
    return @($requiredScopes)
}

function Get-AzdPimPlanDriftCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('contexts', 'policies', 'roleRules', 'activationMfa')] [string] $Kind
    )

    $count = 0
    foreach ($tierName in @('privileged', 'lessPrivileged')) {
        $tier = $script:ValidationPlan.tiers.$tierName
        switch ($Kind) {
            'contexts' {
                if ($tier.context -and $tier.context.action -ne 'none') { $count++ }
            }
            'policies' {
                $count += @($tier.conditionalAccessPolicies | Where-Object action -ne 'none').Count
            }
            'roleRules' {
                $count += @($tier.roleRules | Where-Object action -ne 'none').Count
            }
            'activationMfa' {
                $count += @($tier.roleRules | Where-Object { $_.activationMfa.action -ne 'none' }).Count
            }
        }
    }
    return $count
}

function Resolve-AzdPimPlanStateOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [int] $PendingCount,
        [Parameter(Mandatory)] [string] $FailureCode,
        [Parameter(Mandatory)] [string] $Remediation
    )

    if ($script:ValidationConfiguration.Mode -eq 'plan') {
        return New-AzdCheckOutcome -Status info `
            -Summary "$Subject were evaluated in solution plan mode; no tenant change was made." `
            -Expected 'Read-only planning.' -Actual ([ordered] @{ pendingChangeCount = $PendingCount })
    }
    if ($PendingCount -gt 0) {
        return New-AzdCheckFailure -Code $FailureCode `
            -Summary "$Subject have drifted from the enforced plan." `
            -Expected 0 -Details @{ pendingChangeCount = $PendingCount } -Remediation $Remediation
    }
    New-AzdCheckOutcome -Summary "$Subject match the enforced plan." -Expected 0 -Actual 0
}

function Get-AzdPimOptionalResourceId {
    [CmdletBinding()]
    param()

    $resources = [System.Collections.Generic.List[string]]::new()
    if ($script:ValidationConfiguration.NotificationMode -eq 'polling') {
        if ([string]::IsNullOrWhiteSpace($env:AZD_PIM_POLLING_FUNCTION_RESOURCE_ID)) {
            throw 'The polling Function App resource ID is missing.'
        }
        $resources.Add([string] $env:AZD_PIM_POLLING_FUNCTION_RESOURCE_ID)
    }
    if ($script:ValidationConfiguration.NotificationMode -eq 'sentinel') {
        foreach ($name in @(
            'AZD_PIM_SENTINEL_NOTIFICATION_LOGIC_APP_RESOURCE_ID',
            'AZD_PIM_SENTINEL_NOTIFICATION_ALERT_RESOURCE_ID',
            'AZD_PIM_SENTINEL_NOTIFICATION_ACTION_GROUP_RESOURCE_ID'
        )) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ([string]::IsNullOrWhiteSpace($value)) { throw "$name is missing." }
            $resources.Add($value)
        }
    }
    if ($script:ValidationConfiguration.EnableSessionRevocation) {
        foreach ($name in @('AZD_PIM_REVOCATION_LOGIC_APP_RESOURCE_ID', 'AZD_PIM_REVOCATION_ALERT_RESOURCE_ID')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ($name -eq 'AZD_PIM_REVOCATION_ALERT_RESOURCE_ID' -and [string]::IsNullOrWhiteSpace($script:ValidationConfiguration.RevocationAlertActionGroupResourceId)) {
                continue
            }
            if ([string]::IsNullOrWhiteSpace($value)) { throw "$name is missing." }
            $resources.Add($value)
        }
    }
    return @($resources)
}

function Send-AzdPimTeamsDestinationTest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [uri] $WebhookUri)

    $trackingId = [guid]::NewGuid().Guid
    $payload = @{
        type = 'message'
        attachments = @(
            @{
                contentType = 'application/vnd.microsoft.card.adaptive'
                contentUrl = $null
                content = @{
                    '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                    type = 'AdaptiveCard'
                    version = '1.4'
                    body = @(
                        @{ type = 'TextBlock'; weight = 'Bolder'; text = 'azd-pim delivery test' },
                        @{ type = 'TextBlock'; wrap = $true; text = 'This is an explicit synthetic test. It is not a PIM activation.' },
                        @{ type = 'FactSet'; facts = @(
                            @{ title = 'Tracking ID'; value = $trackingId },
                            @{ title = 'Generated'; value = [datetimeoffset]::UtcNow.ToString('o') }
                        ) }
                    )
                }
            }
        )
    } | ConvertTo-Json -Depth 12 -Compress
    $response = Invoke-WebRequest -Method Post -Uri $WebhookUri -ContentType 'application/json' -Body $payload
    return [pscustomobject] @{ trackingId = $trackingId; statusCode = [int] $response.StatusCode }
}

function Get-ProjectValidationDefinition {
    [CmdletBinding()]
    param()

    $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ValidationConfiguration = $null
    $script:ValidationPlan = $null
    $script:ValidationGraphContext = $null

    New-AzdValidationCheckDefinition `
        -Id 'context.template-root' -Phase context -Title 'Template root is complete' `
        -Summary 'azure.yaml and the PIM domain modules exist at the template root.' -SideEffect none `
        -Action ({
            foreach ($path in @('azure.yaml', 'scripts/AzdPim.Graph.psm1', 'scripts/AzdPim.Common.psm1')) {
                if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $path) -PathType Leaf)) {
                    throw "Required template file $path was not found."
                }
            }
        }.GetNewClosure())

    New-AzdValidationCheckDefinition `
        -Id 'context.cached-sessions' -Phase context -Title 'Tenant and subscription context is exact' `
        -Summary 'The cached azd, Azure CLI, and Microsoft Graph contexts match exactly without initiating authentication.' `
        -SideEffect readOnly -DependsOn 'context.template-root' `
        -Remediation 'Use the normal broker or browser sign-in for the intended tenant and select the configured subscription.' `
        -Action {
            try {
                Initialize-AzdPimValidationContext
                New-AzdCheckOutcome -Summary 'The cached contexts match the azd tenant and subscription.' `
                    -Expected 'One tenant and subscription.' -Actual 'Validated'
            }
            catch { Resolve-AzdPimValidationFailure -Category context -ErrorRecord $_ }
        }

    New-AzdValidationCheckDefinition `
        -Id 'configuration.role-scope' -Phase configuration -Title 'Independent role scopes are valid' `
        -Summary 'Privileged and less-privileged tiers each use a valid selected or all role scope.' `
        -SideEffect none -DependsOn 'context.cached-sessions' `
        -Action {
            try {
                $configuration = Get-AzdPimConfiguration
                $script:ValidationConfiguration = $configuration
                New-AzdCheckOutcome -Summary 'Both role tiers have explicit and independent scope.' `
                    -Expected @('selected', 'all') `
                    -Actual ([ordered] @{
                        privilegedScope = [string] $configuration.PrivilegedRoleScope
                        privilegedSelectedCount = @($configuration.PrivilegedRoleIds).Count
                        lessPrivilegedScope = [string] $configuration.LessPrivilegedRoleScope
                        lessPrivilegedSelectedCount = @($configuration.LessPrivilegedRoleIds).Count
                    })
            }
            catch { Resolve-AzdPimValidationFailure -Category configuration -ErrorRecord $_ }
        }

    New-AzdValidationCheckDefinition `
        -Id 'identity.graph-scopes' -Phase identity -Title 'Microsoft Graph delegated scopes are complete' `
        -Summary 'The existing same-tenant Graph context contains every scope needed by the configured PIM features.' `
        -SideEffect readOnly -DependsOn 'configuration.role-scope' `
        -Remediation 'Run the solution through the normal broker or browser sign-in to consent the configured scopes, then rerun validation.' `
        -Action {
            try {
                $requiredScopes = @(Assert-AzdPimValidationGraphScope)
                New-AzdCheckOutcome -Summary 'The cached Graph context contains every configured delegated scope.' `
                    -Expected $requiredScopes -Actual $requiredScopes `
                    -Evidence @{ verifiedScopeCount = $requiredScopes.Count }
            }
            catch { Resolve-AzdPimValidationFailure -Category context -ErrorRecord $_ }
        }

    New-AzdValidationCheckDefinition `
        -Id 'discovery.entra-plan' -Phase identity -Title 'Graph-derived PIM plan is complete' `
        -Summary 'Microsoft Graph classifies every current Entra role and resolves each selected role to the correct tier.' `
        -SideEffect readOnly -DependsOn 'identity.graph-scopes' `
        -Remediation 'Confirm Graph read access and correct any stale or misclassified selected role IDs.' `
        -Action {
            try {
                $script:ValidationPlan = New-AzdPimPlan -Configuration $script:ValidationConfiguration -State (Get-AzdPimState)
                New-AzdCheckOutcome -Summary 'The Graph-derived PIM plan is complete for both role tiers.' `
                    -Expected 'Every role has an explicit isPrivileged classification.' `
                    -Actual ([ordered] @{
                        inventoryCount = @($script:ValidationPlan.inventory).Count
                        privilegedRoleCount = @($script:ValidationPlan.tiers.privileged.roles).Count
                        lessPrivilegedRoleCount = @($script:ValidationPlan.tiers.lessPrivileged.roles).Count
                    }) `
                    -Evidence @{ roleClassificationApi = [string] $script:ValidationPlan.graphApiVersions.roleClassification }
            }
            catch { Resolve-AzdPimValidationFailure -Category discovery -ErrorRecord $_ }
        }

    New-AzdValidationCheckDefinition `
        -Id 'configuration.authentication-contexts' -Phase configuration -Title 'Authentication contexts match the plan' `
        -Summary 'The non-empty role tiers use available, non-conflicting authentication contexts.' `
        -SideEffect readOnly -DependsOn 'discovery.entra-plan' `
        -Remediation 'Review the planned context action and rerun enforcement; existing contexts are never deleted by this solution.' `
        -Action {
            Resolve-AzdPimPlanStateOutcome -Subject 'Authentication contexts' `
                -PendingCount (Get-AzdPimPlanDriftCount -Kind contexts) `
                -FailureCode 'configuration.authenticationContextDrift' `
                -Remediation 'Review ownership and adoption settings, then rerun enforced deployment. Authentication contexts are preserved during cleanup.'
        }

    New-AzdValidationCheckDefinition `
        -Id 'configuration.conditional-access' -Phase configuration -Title 'Conditional Access policies match the plan' `
        -Summary 'Context-targeted policies retain their authentication, device, emergency-access exclusion, and every-time session controls.' `
        -SideEffect readOnly -DependsOn 'discovery.entra-plan' `
        -Remediation 'Review policy drift and rerun enforced deployment after confirming the intended controls.' `
        -Action {
            Resolve-AzdPimPlanStateOutcome -Subject 'Conditional Access policies' `
                -PendingCount (Get-AzdPimPlanDriftCount -Kind policies) `
                -FailureCode 'configuration.conditionalAccessDrift' `
                -Remediation 'Review policy drift and rerun enforced deployment after confirming the intended controls.'
        }

    New-AzdValidationCheckDefinition `
        -Id 'configuration.pim-role-rules' -Phase configuration -Title 'Selected PIM role rules match the plan' `
        -Summary 'Every currently selected role requests its tier authentication context without a conflicting legacy activation MFA rule.' `
        -SideEffect readOnly -DependsOn 'discovery.entra-plan' `
        -Remediation 'Review the exact selected role set and rerun enforced deployment; roles removed from scope are not restored or detached.' `
        -Action {
            $pendingRules = Get-AzdPimPlanDriftCount -Kind roleRules
            $pendingMfa = Get-AzdPimPlanDriftCount -Kind activationMfa
            Resolve-AzdPimPlanStateOutcome -Subject 'Selected PIM role rules' `
                -PendingCount ($pendingRules + $pendingMfa) `
                -FailureCode 'configuration.pimRoleRuleDrift' `
                -Remediation 'Review the exact selected role set and rerun enforced deployment. Roles removed from scope remain unchanged.'
        }

    New-AzdValidationCheckDefinition `
        -Id 'infrastructure.optional-workflows' -Phase infrastructure -Title 'Optional Azure workflows are readable' `
        -Summary 'Every Azure resource required by the enabled notification or session-revocation options exists in the selected subscription.' `
        -SideEffect readOnly -DependsOn 'configuration.role-scope' `
        -Remediation 'Confirm provisioning completed and the optional workflow outputs are present.' `
        -Action {
            try {
                if ($script:ValidationConfiguration.Mode -eq 'plan') {
                    return New-AzdCheckOutcome -Status info `
                        -Summary 'Optional Azure workflows were evaluated in solution plan mode; no deployed resource is required.' `
                        -Expected 'No optional Azure resource change in plan mode.' -Actual 'Not required'
                }
                $resourceIds = @(Get-AzdPimOptionalResourceId)
                foreach ($resourceId in $resourceIds) {
                    $result = & az resource show --ids $resourceId --subscription $env:AZURE_SUBSCRIPTION_ID `
                        --query id --only-show-errors --output tsv
                    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($result)) {
                        throw 'An optional Azure resource could not be read.'
                    }
                }
                New-AzdCheckOutcome -Summary 'Every configured optional Azure workflow resource is readable.' `
                    -Expected @($resourceIds).Count -Actual @($resourceIds).Count
            }
            catch { Resolve-AzdPimValidationFailure -Category infrastructure -ErrorRecord $_ }
        }

    New-AzdValidationCheckDefinition `
        -Id 'delivery.teams-destination' -Phase delivery -Title 'Teams destination accepts a labeled test' `
        -Summary 'The configured Teams Workflow webhook accepts one clearly labeled synthetic test card.' `
        -SideEffect syntheticDelivery -DependsOn 'infrastructure.optional-workflows' `
        -Remediation 'Confirm the Teams Workflow webhook and rerun with -TestDelivery. Real PIM activation remains a separate operational proof.' `
        -Action {
            if ($script:ValidationConfiguration.NotificationMode -eq 'none') {
                return New-AzdCheckOutcome -Status info -Summary 'Teams notifications are disabled, so no destination test was sent.' `
                    -Expected 'No notification delivery when disabled.' -Actual 'Disabled'
            }
            try {
                $webhook = [uri] $script:ValidationConfiguration.TeamsWebhookUrl
                $result = Send-AzdPimTeamsDestinationTest -WebhookUri $webhook
                New-AzdCheckOutcome -Summary 'The Teams destination accepted the labeled synthetic test.' `
                    -Expected 'HTTP success.' -Actual ([int] $result.statusCode) `
                    -Evidence @{ trackingId = [string] $result.trackingId; notificationMode = [string] $script:ValidationConfiguration.NotificationMode }
            }
            catch { Resolve-AzdPimValidationFailure -Category delivery -ErrorRecord $_ }
        }
}

Export-ModuleMember -Function @('Get-ProjectValidationDefinition')
