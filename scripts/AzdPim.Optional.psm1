Set-StrictMode -Version Latest

$script:GraphV1 = 'https://graph.microsoft.com/v1.0'
$script:GraphBeta = 'https://graph.microsoft.com/beta'
$script:MicrosoftGraphAppId = '00000003-0000-0000-c000-000000000000'
$script:PimCallerAppId = '1c67c054-65c8-4f7f-92a1-eb7ba6e48627'

function ConvertTo-AzdPimOAuthCallbackUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [uri] $CallbackUri)

    $queryParts = @($CallbackUri.Query.TrimStart('?') -split '&' | Where-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return $false }
        $name = [uri]::UnescapeDataString(($_ -split '=', 2)[0])
        return $name -ine 'sig'
    })
    if (-not ($queryParts | Where-Object { $_ -match '^(?i:api-version)=' })) {
        throw 'The Logic App callback URL did not contain the required api-version query parameter.'
    }
    return "$($CallbackUri.GetLeftPart([System.UriPartial]::Path))?$($queryParts -join '&')"
}

function Invoke-AzdPimAzRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PATCH', 'PUT')] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [AllowNull()] [object] $Body
    )

    $accessToken = az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
        throw 'Unable to acquire an Azure Resource Manager token from Azure CLI.'
    }
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = @{ Authorization = "Bearer $($accessToken.Trim())" }
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 100 -Compress
        $parameters.ContentType = 'application/json'
    }
    try {
        return Invoke-RestMethod @parameters
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Azure Resource Manager request failed: $Method $Uri. $detail"
    }
}

function Get-AzdPimMicrosoftGraphServicePrincipal {
    [CmdletBinding()]
    param()

    $servicePrincipals = @(Get-AzdPimGraphCollection -Uri "$script:GraphV1/servicePrincipals?`$filter=appId eq '$script:MicrosoftGraphAppId'")
    if ($servicePrincipals.Count -ne 1) {
        throw "Expected one Microsoft Graph service principal but found $($servicePrincipals.Count)."
    }
    return $servicePrincipals[0]
}

function Grant-AzdPimGraphApplicationPermission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PrincipalId,
        [Parameter(Mandatory)] [string] $PermissionValue
    )

    $graph = Get-AzdPimMicrosoftGraphServicePrincipal
    $role = @($graph.appRoles | Where-Object { $_.value -eq $PermissionValue -and 'Application' -in @($_.allowedMemberTypes) }) | Select-Object -First 1
    if (-not $role) { throw "Microsoft Graph application permission '$PermissionValue' was not found." }

    $assignments = @(Get-AzdPimGraphCollection -Uri "$script:GraphV1/servicePrincipals/$PrincipalId/appRoleAssignments")
    $existing = @($assignments | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $role.id }) | Select-Object -First 1
    if ($existing) {
        Write-Host "Microsoft Graph application permission $PermissionValue is already assigned to $PrincipalId."
        return $existing
    }

    $assignment = Invoke-AzdPimGraphRequest -Method POST -Uri "$script:GraphV1/servicePrincipals/$PrincipalId/appRoleAssignments" -Body @{
        principalId = $PrincipalId
        resourceId = $graph.id
        appRoleId = $role.id
    }
    Write-Host "Assigned Microsoft Graph application permission $PermissionValue to $PrincipalId."
    return $assignment
}

function Publish-AzdPimPollingFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FunctionAppName,
        [Parameter(Mandatory)] [string] $FunctionPrincipalId,
        [Parameter(Mandatory)] [string] $ResourceGroupName
    )

    Grant-AzdPimGraphApplicationPermission -PrincipalId $FunctionPrincipalId -PermissionValue 'AuditLog.Read.All' | Out-Null

    $projectRoot = Split-Path -Parent $PSScriptRoot
    $sourcePath = Join-Path $projectRoot 'src/pim-notification-poller'
    $artifactDirectory = Join-Path $projectRoot '.azure/artifacts'
    $artifactPath = Join-Path $artifactDirectory 'pim-notification-poller.zip'
    New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $artifactPath) { Remove-Item -LiteralPath $artifactPath -Force }
    Compress-Archive -Path (Join-Path $sourcePath '*') -DestinationPath $artifactPath -CompressionLevel Optimal
    try {
        az functionapp deployment source config-zip --resource-group $ResourceGroupName --name $FunctionAppName --src $artifactPath --build-remote true --output none
        if ($LASTEXITCODE -ne 0) { throw "One Deploy failed for Flex Consumption Function App '$FunctionAppName'." }
    } finally {
        if (Test-Path -LiteralPath $artifactPath) { Remove-Item -LiteralPath $artifactPath -Force }
    }
    Write-Host "Published the Microsoft Graph PIM activation poller to $FunctionAppName."
}

function Resolve-AzdPimExtensionApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $EndpointHost
    )

    $escapedName = $DisplayName.Replace("'", "''")
    $applications = @(Get-AzdPimGraphCollection -Uri "$script:GraphV1/applications?`$filter=displayName eq '$escapedName'")
    if ($applications.Count -gt 1) { throw "Multiple application registrations are named '$DisplayName'." }
    if ($applications.Count -eq 0) {
        $application = Invoke-AzdPimGraphRequest -Method POST -Uri "$script:GraphV1/applications" -Body @{
            displayName = $DisplayName
            signInAudience = 'AzureADMyOrg'
            api = @{ requestedAccessTokenVersion = 2 }
        }
        Write-Host "Created application registration '$DisplayName'."
    } else {
        $application = $applications[0]
    }

    $identifierUri = "api://$EndpointHost/$($application.appId)"
    Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphV1/applications/$($application.id)" -Body @{
        identifierUris = @($identifierUri)
        api = @{ requestedAccessTokenVersion = 2 }
    } | Out-Null

    $servicePrincipals = @(Get-AzdPimGraphCollection -Uri "$script:GraphV1/servicePrincipals?`$filter=appId eq '$($application.appId)'")
    if ($servicePrincipals.Count -eq 0) {
        Invoke-AzdPimGraphRequest -Method POST -Uri "$script:GraphV1/servicePrincipals" -Body @{ appId = $application.appId } | Out-Null
    } elseif ($servicePrincipals.Count -gt 1) {
        throw "Multiple service principals exist for application '$($application.appId)'."
    }

    return [pscustomobject]@{ objectId = $application.id; clientId = $application.appId; identifierUri = $identifierUri }
}

function Enable-AzdPimRevocationWorkflowOAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkflowResourceId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $Audience,
        [Parameter(Mandatory)] [string] $ApplicationClientId
    )

    $uri = "https://management.azure.com$WorkflowResourceId`?api-version=2019-05-01"
    $workflow = Invoke-AzdPimAzRest -Method GET -Uri $uri
    $definition = $workflow.properties.definition
    $manualTrigger = if ($definition.triggers -is [System.Collections.IDictionary]) {
        $definition.triggers['manual']
    } else {
        $definition.triggers.manual
    }
    if ($manualTrigger -is [System.Collections.IDictionary]) {
        $manualTrigger.Remove('operationOptions')
    } elseif ($manualTrigger) {
        $manualTrigger.PSObject.Properties.Remove('operationOptions')
    }
    $properties = @{
        state = 'Enabled'
        definition = $definition
        parameters = $workflow.properties.parameters
        accessControl = @{
            triggers = @{
                openAuthenticationPolicies = @{
                    policies = @{
                        pimV2 = @{
                            type = 'AAD'
                            claims = @(
                                @{ name = 'iss'; value = "https://login.microsoftonline.com/$TenantId/v2.0" },
                                @{ name = 'aud'; value = $ApplicationClientId },
                                @{ name = 'azp'; value = $script:PimCallerAppId }
                            )
                        }
                        pimV1 = @{
                            type = 'AAD'
                            claims = @(
                                @{ name = 'iss'; value = "https://sts.windows.net/$TenantId/" },
                                @{ name = 'aud'; value = $Audience },
                                @{ name = 'appid'; value = $script:PimCallerAppId }
                            )
                        }
                    }
                }
                sasAuthenticationPolicy = @{ state = 'Disabled' }
            }
        }
    }
    $body = @{
        location = $workflow.location
        identity = @{ type = 'SystemAssigned' }
        properties = @{
            state = $properties.state
            definition = $properties.definition
            parameters = $properties.parameters
            accessControl = $properties.accessControl
        }
    }
    if ($workflow.tags) { $body.tags = $workflow.tags }
    Invoke-AzdPimAzRest -Method PUT -Uri $uri -Body $body | Out-Null
    Write-Host 'Enabled the revocation Logic App with OAuth-only PIM caller validation.'
}

function Set-AzdPimRevocationCustomExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $TargetUrl,
        [Parameter(Mandatory)] [string] $ResourceId,
        [ValidateSet('preApproval', 'postApproval')] [string] $Type = 'postApproval'
    )

    $body = @{
        '@odata.type' = '#microsoft.graph.roleManagementCustomCalloutExtension'
        displayName = $DisplayName
        description = if ($Type -eq 'postApproval') {
            'Revokes existing sign-in sessions after required Microsoft Entra PIM approval and before role activation completes.'
        } else {
            'Revokes existing sign-in sessions before activation for a Microsoft Entra PIM role that does not require human approval.'
        }
        type = $Type
        endpointConfiguration = @{
            '@odata.type' = '#microsoft.graph.httpRequestEndpoint'
            targetUrl = $TargetUrl
        }
        clientConfiguration = @{
            '@odata.type' = '#microsoft.graph.customExtensionClientConfiguration'
            timeoutInMilliseconds = 10000
            maximumRetries = 2
        }
        authenticationConfiguration = @{
            '@odata.type' = '#microsoft.graph.azureAdTokenAuthentication'
            resourceId = $ResourceId
        }
        resourceType = 'entraRoles'
        customAttributes = @()
    }

    $extensions = @(Get-AzdPimGraphCollection -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions")
    $matching = @($extensions | Where-Object { $_.displayName -eq $DisplayName -and $_.type -eq $Type })
    if ($matching.Count -gt 1) { throw "Multiple PIM custom extensions are named '$DisplayName'." }
    if ($matching.Count -eq 1) {
        Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions/$($matching[0].id)" -Body $body | Out-Null
        Write-Host "Updated PIM custom extension '$DisplayName'."
        return $matching[0].id
    }

    # The current beta service requires a client-generated GUID even though the
    # preview documentation omits id from the create request example.
    $body.id = [string]([guid]::NewGuid())
    $created = Invoke-AzdPimGraphRequest -Method POST -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions" -Body $body
    Write-Host "Created PIM custom extension '$DisplayName'."
    return $created.id
}

function New-AzdPimCustomExtensionRuleBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('preApproval', 'postApproval')] [string] $Type,
        [Parameter(Mandatory)] [string] $CustomExtensionId,
        [bool] $IsEnabled = $true
    )

    $phase = if ($Type -eq 'postApproval') { 'PostApproval' } else { 'PreApproval' }
    return @{
        '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyCustomExtensionRule'
        id = "CustomExtension_${phase}_EndUser_Assignment"
        customExtensionId = $CustomExtensionId
        isEnabled = $IsEnabled
        target = @{
            caller = 'EndUser'
            operations = @('All')
            level = 'Assignment'
            inheritableSettings = @()
            enforcedSettings = @()
        }
    }
}

function Enable-AzdPimRevocationExtensionForRoles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $RoleRules,
        [Parameter(Mandatory)] [string] $PreApprovalCustomExtensionId,
        [Parameter(Mandatory)] [string] $PostApprovalCustomExtensionId
    )

    $managedExtensionIds = @($PreApprovalCustomExtensionId, $PostApprovalCustomExtensionId)
    $results = [System.Collections.Generic.List[object]]::new()
    $processedPolicyIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($roleRule in $RoleRules) {
        if (-not $processedPolicyIds.Add([string]$roleRule.policyId)) { continue }

        $policyUri = "$script:GraphBeta/policies/roleManagementPolicies/$($roleRule.policyId)"
        $policy = Invoke-AzdPimGraphRequest -Method GET -Uri "${policyUri}?`$expand=rules"
        $approvalRule = @($policy.rules | Where-Object { $_.id -eq 'Approval_EndUser_Assignment' }) | Select-Object -First 1
        $requiresHumanApproval = [bool]$approvalRule.setting.isApprovalRequired
        $desiredType = if ($requiresHumanApproval) { 'postApproval' } else { 'preApproval' }
        $oppositeType = if ($requiresHumanApproval) { 'preApproval' } else { 'postApproval' }
        $desiredExtensionId = if ($requiresHumanApproval) { $PostApprovalCustomExtensionId } else { $PreApprovalCustomExtensionId }
        $desiredBody = New-AzdPimCustomExtensionRuleBody -Type $desiredType -CustomExtensionId $desiredExtensionId
        $oppositePhase = if ($oppositeType -eq 'postApproval') { 'PostApproval' } else { 'PreApproval' }
        $oppositeRuleId = "CustomExtension_${oppositePhase}_EndUser_Assignment"
        $existingRule = @($policy.rules | Where-Object { $_.id -eq $desiredBody.id }) | Select-Object -First 1
        $oppositeRule = @($policy.rules | Where-Object { $_.id -eq $oppositeRuleId }) | Select-Object -First 1

        if ($existingRule -and $existingRule.customExtensionId -and $existingRule.customExtensionId -ne $desiredExtensionId) {
            throw "Role '$($roleRule.role.displayName)' already references a different $desiredType custom extension."
        }
        if ($oppositeRule -and $oppositeRule.isEnabled -and $oppositeRule.customExtensionId -notin $managedExtensionIds) {
            throw "Role '$($roleRule.role.displayName)' has a foreign $oppositeType custom extension enabled."
        }

        $actions = [System.Collections.Generic.List[string]]::new()
        if ($existingRule) {
            if (-not $existingRule.isEnabled -or $existingRule.customExtensionId -ne $desiredExtensionId) {
                Invoke-AzdPimGraphRequest -Method PATCH -Uri "$policyUri/rules/$($desiredBody.id)" -Body $desiredBody | Out-Null
                $actions.Add('updateRule')
            }
        } else {
            $rules = @($policy.rules | ForEach-Object { $_ | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 })
            foreach ($rule in $rules) {
                if ($rule.id -eq $oppositeRuleId -and $rule.isEnabled -and $rule.customExtensionId -in $managedExtensionIds) {
                    $rule.isEnabled = $false
                    $actions.Add('disableOppositeRule')
                }
            }
            $rules += $desiredBody
            $body = @{
                id = $policy.id
                displayName = $policy.displayName
                description = $policy.description
                isOrganizationDefault = [bool]$policy.isOrganizationDefault
                scopeId = $policy.scopeId
                scopeType = $policy.scopeType
                lastModifiedBy = $null
                lastModifiedDateTime = [DateTimeOffset]::UtcNow.ToString('o')
                effectiveRules = @()
                rules = $rules
            }
            Invoke-AzdPimGraphRequest -Method PATCH -Uri $policyUri -Body ($body | ConvertTo-Json -Depth 100 -Compress) | Out-Null
            $actions.Add('addRule')
        }

        if ($existingRule -and $oppositeRule -and $oppositeRule.isEnabled -and $oppositeRule.customExtensionId -in $managedExtensionIds) {
            $disableBody = New-AzdPimCustomExtensionRuleBody -Type $oppositeType -CustomExtensionId $oppositeRule.customExtensionId -IsEnabled $false
            Invoke-AzdPimGraphRequest -Method PATCH -Uri "$policyUri/rules/$oppositeRuleId" -Body $disableBody | Out-Null
            $actions.Add('disableOppositeRule')
        }
        if ($actions.Count -eq 0) { $actions.Add('none') }
        $results.Add([pscustomobject]@{
            roleId = $roleRule.role.id
            roleDisplayName = $roleRule.role.displayName
            policyId = $roleRule.policyId
            requiresHumanApproval = $requiresHumanApproval
            extensionType = $desiredType
            actions = @($actions)
        })
    }

    return @($results)
}

function Initialize-AzdPimRevocationExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkflowResourceId,
        [Parameter(Mandatory)] [string] $WorkflowPrincipalId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $EnvironmentName
    )

    $callback = Invoke-AzdPimAzRest -Method POST -Uri "https://management.azure.com$WorkflowResourceId/triggers/manual/listCallbackUrl?api-version=2019-05-01"
    $callbackUri = [uri]$callback.value
    $targetUrl = ConvertTo-AzdPimOAuthCallbackUrl -CallbackUri $callbackUri
    $applicationDisplayName = "azd-pim $EnvironmentName - Session Revocation"
    $preApprovalDisplayName = "azd-pim $EnvironmentName - Session Revocation"
    $postApprovalDisplayName = "azd-pim $EnvironmentName - Post-Approval Session Revocation"
    $application = Resolve-AzdPimExtensionApplication -DisplayName $applicationDisplayName -EndpointHost $callbackUri.Host

    Enable-AzdPimRevocationWorkflowOAuth -WorkflowResourceId $WorkflowResourceId -TenantId $TenantId -Audience $application.identifierUri -ApplicationClientId $application.clientId
    Grant-AzdPimGraphApplicationPermission -PrincipalId $WorkflowPrincipalId -PermissionValue 'User.RevokeSessions.All' | Out-Null
    $preApprovalExtensionId = Set-AzdPimRevocationCustomExtension -DisplayName $preApprovalDisplayName -TargetUrl $targetUrl -ResourceId $application.identifierUri -Type preApproval
    $postApprovalExtensionId = Set-AzdPimRevocationCustomExtension -DisplayName $postApprovalDisplayName -TargetUrl $targetUrl -ResourceId $application.identifierUri -Type postApproval

    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID' -Value $application.clientId
    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_CUSTOM_EXTENSION_ID' -Value $postApprovalExtensionId
    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_PRE_APPROVAL_CUSTOM_EXTENSION_ID' -Value $preApprovalExtensionId
    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_POST_APPROVAL_CUSTOM_EXTENSION_ID' -Value $postApprovalExtensionId
    return [pscustomobject]@{
        applicationClientId = $application.clientId
        applicationIdUri = $application.identifierUri
        customExtensionId = $postApprovalExtensionId
        preApprovalCustomExtensionId = $preApprovalExtensionId
        postApprovalCustomExtensionId = $postApprovalExtensionId
        targetUrl = $targetUrl
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-AzdPimOAuthCallbackUrl',
    'Invoke-AzdPimAzRest',
    'Grant-AzdPimGraphApplicationPermission',
    'Publish-AzdPimPollingFunction',
    'Resolve-AzdPimExtensionApplication',
    'Enable-AzdPimRevocationWorkflowOAuth',
    'Set-AzdPimRevocationCustomExtension',
    'New-AzdPimCustomExtensionRuleBody',
    'Enable-AzdPimRevocationExtensionForRoles',
    'Initialize-AzdPimRevocationExtension'
)
