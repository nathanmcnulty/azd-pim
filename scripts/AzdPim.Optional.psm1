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
    $stagingPath = Join-Path $artifactDirectory 'pim-notification-poller'
    New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $artifactPath) { Remove-Item -LiteralPath $artifactPath -Force }
    try {
        if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
        New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
        foreach ($file in @('host.json', 'package.json', 'package-lock.json')) {
            Copy-Item -LiteralPath (Join-Path $sourcePath $file) -Destination (Join-Path $stagingPath $file) -Force
        }
        Copy-Item -LiteralPath (Join-Path $sourcePath 'src') -Destination (Join-Path $stagingPath 'src') -Recurse -Force
        Compress-Archive -Path (Join-Path $stagingPath '*') -DestinationPath $artifactPath -CompressionLevel Optimal
        az functionapp deployment source config-zip --resource-group $ResourceGroupName --name $FunctionAppName --src $artifactPath --build-remote true --output none
        if ($LASTEXITCODE -ne 0) { throw "One Deploy failed for Flex Consumption Function App '$FunctionAppName'." }
    } finally {
        if (Test-Path -LiteralPath $artifactPath) { Remove-Item -LiteralPath $artifactPath -Force }
        if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
    }
    Write-Host "Published the Microsoft Graph PIM activation poller to $FunctionAppName."
}

function Get-AzdPimObjectProperty {
    param([AllowNull()] [object] $Object, [Parameter(Mandatory)] [string] $Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Set-AzdPimObjectProperty {
    param([Parameter(Mandatory)] [object] $Object, [Parameter(Mandatory)] [string] $Name, [AllowNull()] [object] $Value)

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-AzdPimSessionRevocationState {
    param([Parameter(Mandatory)] [object] $State)

    $optionalResources = Get-AzdPimObjectProperty -Object $State -Name 'optionalResources'
    if (-not $optionalResources) {
        $optionalResources = [ordered]@{}
        Set-AzdPimObjectProperty -Object $State -Name 'optionalResources' -Value $optionalResources
    }
    $sessionRevocation = Get-AzdPimObjectProperty -Object $optionalResources -Name 'sessionRevocation'
    if (-not $sessionRevocation) {
        $sessionRevocation = [ordered]@{ customExtensions = [ordered]@{} }
        Set-AzdPimObjectProperty -Object $optionalResources -Name 'sessionRevocation' -Value $sessionRevocation
    }
    if (-not (Get-AzdPimObjectProperty -Object $sessionRevocation -Name 'customExtensions')) {
        Set-AzdPimObjectProperty -Object $sessionRevocation -Name 'customExtensions' -Value ([ordered]@{})
    }
    return $sessionRevocation
}

function Assert-AzdPimGuid {
    param([Parameter(Mandatory)] [string] $Value, [Parameter(Mandatory)] [string] $Name)

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed)) { throw "$Name must be a GUID." }
}

function Assert-AzdPimExtensionApplication {
    param(
        [Parameter(Mandatory)] [object] $Application,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $ObjectId,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $IdentifierUri,
        [switch] $AllowMissingIdentifierUri,
        [switch] $AllowIncorrectAccessTokenVersion
    )

    Assert-AzdPimGuid -Value $ObjectId -Name 'The state-owned application object ID'
    Assert-AzdPimGuid -Value $ClientId -Name 'The state-owned application appId'
    if ([string]$Application.id -cne $ObjectId) { throw 'The application returned for the state-owned object ID did not match that object ID.' }
    if ([string]$Application.appId -cne $ClientId) { throw 'The state-owned application appId did not match the recorded client ID.' }
    if ([string]$Application.displayName -cne $DisplayName) { throw 'The state-owned application display name did not match the expected session-revocation application.' }
    if ([string]$Application.signInAudience -cne 'AzureADMyOrg') { throw 'The state-owned application must remain single-tenant (AzureADMyOrg).' }
    $uris = @($Application.identifierUris | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($AllowMissingIdentifierUri -and $uris.Count -eq 0) { return }
    if ($uris.Count -ne 1 -or [string]$uris[0] -cne $IdentifierUri) { throw 'The state-owned application must have exactly its recorded session-revocation Application ID URI.' }
    if ([int](Get-AzdPimObjectProperty -Object $Application.api -Name 'requestedAccessTokenVersion') -ne 2 -and -not $AllowIncorrectAccessTokenVersion) { throw 'The state-owned application must require access token version 2.' }
}

function Resolve-AzdPimExtensionApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $EndpointHost,
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [scriptblock] $PersistState
    )

    $sessionState = Get-AzdPimSessionRevocationState -State $State
    $recorded = Get-AzdPimObjectProperty -Object $sessionState -Name 'application'
    if ($recorded) {
        $objectId = [string](Get-AzdPimObjectProperty -Object $recorded -Name 'objectId')
        $clientId = [string](Get-AzdPimObjectProperty -Object $recorded -Name 'clientId')
        Assert-AzdPimGuid -Value $objectId -Name 'The state-owned application object ID'
        Assert-AzdPimGuid -Value $clientId -Name 'The state-owned application appId'
        $identifierUri = "api://$EndpointHost/$clientId"
        if ([string](Get-AzdPimObjectProperty -Object $recorded -Name 'identifierUri') -cne $identifierUri) {
            throw 'The session-revocation callback host does not match the state-owned application Application ID URI.'
        }
        $application = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphV1/applications/${objectId}?`$select=id,appId,displayName,signInAudience,identifierUris,api"
        $allowMissing = [string](Get-AzdPimObjectProperty -Object $recorded -Name 'configurationState') -eq 'created'
        Assert-AzdPimExtensionApplication -Application $application -DisplayName $DisplayName -ObjectId $objectId -ClientId $clientId -IdentifierUri $identifierUri -AllowMissingIdentifierUri:$allowMissing -AllowIncorrectAccessTokenVersion
    } else {
        $legacyObjectId = ([string]$env:AZD_PIM_REVOCATION_APPLICATION_OBJECT_ID).Trim()
        $legacyClientId = ([string]$env:AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID).Trim()
        if ($legacyObjectId) {
            Assert-AzdPimGuid -Value $legacyObjectId -Name 'AZD_PIM_REVOCATION_APPLICATION_OBJECT_ID'
            if ($legacyClientId) { Assert-AzdPimGuid -Value $legacyClientId -Name 'AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID' }
            $application = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphV1/applications/${legacyObjectId}?`$select=id,appId,displayName,signInAudience,identifierUris,api"
            $resolvedClientId = if ($legacyClientId) { $legacyClientId } else { [string]$application.appId }
            $identifierUri = "api://$EndpointHost/$resolvedClientId"
            Assert-AzdPimExtensionApplication -Application $application -DisplayName $DisplayName -ObjectId $legacyObjectId -ClientId $resolvedClientId -IdentifierUri $identifierUri
            Set-AzdPimObjectProperty -Object $sessionState -Name 'application' -Value ([ordered]@{
                objectId = $legacyObjectId; clientId = $resolvedClientId; identifierUri = $identifierUri; configurationState = 'configured'; ownershipSource = 'legacyEnvironmentValidated'; recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
            })
            & $PersistState $State
        } elseif ($legacyClientId) {
            Assert-AzdPimGuid -Value $legacyClientId -Name 'AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID'
            $application = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphV1/applications(appId='$legacyClientId')?`$select=id,appId,displayName,signInAudience,identifierUris,api"
            $identifierUri = "api://$EndpointHost/$legacyClientId"
            Assert-AzdPimExtensionApplication -Application $application -DisplayName $DisplayName -ObjectId ([string]$application.id) -ClientId $legacyClientId -IdentifierUri $identifierUri
            Set-AzdPimObjectProperty -Object $sessionState -Name 'application' -Value ([ordered]@{
                objectId = [string]$application.id; clientId = $legacyClientId; identifierUri = $identifierUri; configurationState = 'configured'; ownershipSource = 'legacyEnvironmentValidated'; recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
            })
            & $PersistState $State
        } else {
            $escapedName = $DisplayName.Replace("'", "''")
            $applications = @(Get-AzdPimGraphCollection -Uri "$script:GraphV1/applications?`$filter=displayName eq '$escapedName'")
            if ($applications.Count -gt 0) { throw "Application registration '$DisplayName' already exists but is not recorded as state-owned. Refuse to adopt or modify it." }
        $application = Invoke-AzdPimGraphRequest -Method POST -Uri "$script:GraphV1/applications" -Body @{
            displayName = $DisplayName
            signInAudience = 'AzureADMyOrg'
            api = @{ requestedAccessTokenVersion = 2 }
        }
        Assert-AzdPimGuid -Value ([string]$application.id) -Name 'The created application object ID'
        Assert-AzdPimGuid -Value ([string]$application.appId) -Name 'The created application appId'
        $identifierUri = "api://$EndpointHost/$($application.appId)"
        Set-AzdPimObjectProperty -Object $sessionState -Name 'application' -Value ([ordered]@{
            objectId = [string]$application.id; clientId = [string]$application.appId; identifierUri = $identifierUri; configurationState = 'created'; ownershipSource = 'created'; createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        })
        $recorded = Get-AzdPimObjectProperty -Object $sessionState -Name 'application'
        & $PersistState $State
        Write-Host "Created application registration '$DisplayName'."
        $application = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphV1/applications/$($application.id)?`$select=id,appId,displayName,signInAudience,identifierUris,api"
        Assert-AzdPimExtensionApplication -Application $application -DisplayName $DisplayName -ObjectId ([string]$application.id) -ClientId ([string]$application.appId) -IdentifierUri $identifierUri -AllowMissingIdentifierUri
        }
    }

    $currentUris = @($application.identifierUris | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $needsTokenVersionRepair = [int](Get-AzdPimObjectProperty -Object $application.api -Name 'requestedAccessTokenVersion') -ne 2
    if ($currentUris.Count -eq 0 -or $needsTokenVersionRepair) {
        $applicationUpdate = @{ api = @{ requestedAccessTokenVersion = 2 } }
        if ($currentUris.Count -eq 0) { $applicationUpdate.identifierUris = @($identifierUri) }
        Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphV1/applications/$($application.id)" -Body $applicationUpdate | Out-Null
        $application = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphV1/applications/$($application.id)?`$select=id,appId,displayName,signInAudience,identifierUris,api"
        Assert-AzdPimExtensionApplication -Application $application -DisplayName $DisplayName -ObjectId ([string]$application.id) -ClientId ([string]$application.appId) -IdentifierUri $identifierUri
        $recorded = Get-AzdPimObjectProperty -Object $sessionState -Name 'application'
        Set-AzdPimObjectProperty -Object $recorded -Name 'configurationState' -Value 'configured'
        & $PersistState $State
    } elseif ([string](Get-AzdPimObjectProperty -Object $recorded -Name 'configurationState') -eq 'created') {
        Set-AzdPimObjectProperty -Object $recorded -Name 'configurationState' -Value 'configured'
        & $PersistState $State
    }

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
        [ValidateSet('preApproval', 'postApproval')] [string] $Type = 'postApproval',
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [scriptblock] $PersistState
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

    $sessionState = Get-AzdPimSessionRevocationState -State $State
    $customExtensions = Get-AzdPimObjectProperty -Object $sessionState -Name 'customExtensions'
    $recorded = Get-AzdPimObjectProperty -Object $customExtensions -Name $Type
    if ($recorded) {
        $extensionId = [string](Get-AzdPimObjectProperty -Object $recorded -Name 'id')
        Assert-AzdPimGuid -Value $extensionId -Name "The state-owned $Type PIM custom extension ID"
        $extension = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions/$extensionId"
        if ([string]$extension.id -cne $extensionId -or [string]$extension.displayName -cne $DisplayName -or [string]$extension.type -cne $Type -or [string]$extension.resourceType -cne 'entraRoles' -or [string]$extension.authenticationConfiguration.resourceId -cne $ResourceId -or [string]$extension.endpointConfiguration.targetUrl -cne $TargetUrl) {
            throw "The state-owned $Type PIM custom extension does not match the expected session-revocation configuration."
        }
        Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions/$extensionId" -Body $body | Out-Null
        Write-Host "Updated state-owned PIM custom extension '$DisplayName'."
        return $extensionId
    }

    $legacyExtensionId = if ($Type -eq 'preApproval') { ([string]$env:AZD_PIM_REVOCATION_PRE_APPROVAL_CUSTOM_EXTENSION_ID).Trim() } else { ([string]$env:AZD_PIM_REVOCATION_POST_APPROVAL_CUSTOM_EXTENSION_ID).Trim() }
    if ($legacyExtensionId) {
        Assert-AzdPimGuid -Value $legacyExtensionId -Name "The legacy $Type PIM custom extension ID"
        $extension = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions/$legacyExtensionId"
        if ([string]$extension.id -cne $legacyExtensionId -or [string]$extension.displayName -cne $DisplayName -or [string]$extension.type -cne $Type -or [string]$extension.resourceType -cne 'entraRoles' -or [string]$extension.authenticationConfiguration.resourceId -cne $ResourceId -or [string]$extension.endpointConfiguration.targetUrl -cne $TargetUrl) {
            throw "The legacy $Type PIM custom extension environment value did not identify the expected session-revocation resource."
        }
        Set-AzdPimObjectProperty -Object $customExtensions -Name $Type -Value ([ordered]@{ id = $legacyExtensionId; displayName = $DisplayName; type = $Type; ownershipSource = 'legacyEnvironmentValidated'; recordedAt = [DateTimeOffset]::UtcNow.ToString('o') })
        & $PersistState $State
        Invoke-AzdPimGraphRequest -Method PATCH -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions/$legacyExtensionId" -Body $body | Out-Null
        Write-Host "Updated legacy-validated PIM custom extension '$DisplayName'."
        return $legacyExtensionId
    }

    $extensions = @(Get-AzdPimGraphCollection -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions")
    $matching = @($extensions | Where-Object { $_.displayName -eq $DisplayName -and $_.type -eq $Type })
    if ($matching.Count -gt 0) { throw "PIM custom extension '$DisplayName' ($Type) already exists but is not recorded as state-owned. Refuse to adopt or modify it." }

    # The current beta service requires a client-generated GUID even though the
    # preview documentation omits id from the create request example.
    $body.id = [string]([guid]::NewGuid())
    Invoke-AzdPimGraphRequest -Method POST -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions" -Body $body | Out-Null
    Set-AzdPimObjectProperty -Object $customExtensions -Name $Type -Value ([ordered]@{ id = [string]$body.id; displayName = $DisplayName; type = $Type; ownershipSource = 'created'; createdAt = [DateTimeOffset]::UtcNow.ToString('o') })
    & $PersistState $State
    $created = Invoke-AzdPimGraphRequest -Method GET -Uri "$script:GraphBeta/identityGovernance/privilegedAccess/customExtensions/$($body.id)"
    if ([string]$created.id -cne [string]$body.id -or [string]$created.displayName -cne $DisplayName -or [string]$created.type -cne $Type -or [string]$created.resourceType -cne 'entraRoles' -or [string]$created.authenticationConfiguration.resourceId -cne $ResourceId -or [string]$created.endpointConfiguration.targetUrl -cne $TargetUrl) { throw "The created $Type PIM custom extension did not match the expected session-revocation configuration." }
    Write-Host "Created PIM custom extension '$DisplayName'."
    return $body.id
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
    $rolePolicyCount = @($RoleRules | ForEach-Object { [string]$_.policyId } | Sort-Object -Unique).Count
    $progressInterval = 25
    $showProgress = $rolePolicyCount -gt $progressInterval
    $processedPolicyCount = 0
    if ($showProgress) {
        Write-Host "Configuring PIM session-revocation extensions for $rolePolicyCount role policies."
    }
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
        $processedPolicyCount++
        if ($showProgress -and $processedPolicyCount -lt $rolePolicyCount -and ($processedPolicyCount % $progressInterval -eq 0)) {
            Write-Host "PIM session-revocation extension progress: $processedPolicyCount of $rolePolicyCount role policies processed."
        }
    }
    if ($showProgress) {
        Write-Host "PIM session-revocation extension configuration complete: $processedPolicyCount of $rolePolicyCount role policies processed."
    }

    return @($results)
}

function Initialize-AzdPimRevocationExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkflowResourceId,
        [Parameter(Mandatory)] [string] $WorkflowPrincipalId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [scriptblock] $PersistState
    )

    $callback = Invoke-AzdPimAzRest -Method POST -Uri "https://management.azure.com$WorkflowResourceId/triggers/manual/listCallbackUrl?api-version=2019-05-01"
    $callbackUri = [uri]$callback.value
    $targetUrl = ConvertTo-AzdPimOAuthCallbackUrl -CallbackUri $callbackUri
    $applicationDisplayName = "azd-pim $EnvironmentName - Session Revocation"
    $preApprovalDisplayName = "azd-pim $EnvironmentName - Session Revocation"
    $postApprovalDisplayName = "azd-pim $EnvironmentName - Post-Approval Session Revocation"
    $application = Resolve-AzdPimExtensionApplication -DisplayName $applicationDisplayName -EndpointHost $callbackUri.Host -State $State -PersistState $PersistState

    Enable-AzdPimRevocationWorkflowOAuth -WorkflowResourceId $WorkflowResourceId -TenantId $TenantId -Audience $application.identifierUri -ApplicationClientId $application.clientId
    Grant-AzdPimGraphApplicationPermission -PrincipalId $WorkflowPrincipalId -PermissionValue 'User.RevokeSessions.All' | Out-Null
    $preApprovalExtensionId = Set-AzdPimRevocationCustomExtension -DisplayName $preApprovalDisplayName -TargetUrl $targetUrl -ResourceId $application.identifierUri -Type preApproval -State $State -PersistState $PersistState
    $postApprovalExtensionId = Set-AzdPimRevocationCustomExtension -DisplayName $postApprovalDisplayName -TargetUrl $targetUrl -ResourceId $application.identifierUri -Type postApproval -State $State -PersistState $PersistState

    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_APPLICATION_OBJECT_ID' -Value $application.objectId
    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_APPLICATION_CLIENT_ID' -Value $application.clientId
    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_CUSTOM_EXTENSION_ID' -Value $postApprovalExtensionId
    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_PRE_APPROVAL_CUSTOM_EXTENSION_ID' -Value $preApprovalExtensionId
    Set-AzdEnvironmentValue -Name 'AZD_PIM_REVOCATION_POST_APPROVAL_CUSTOM_EXTENSION_ID' -Value $postApprovalExtensionId
    return [pscustomobject]@{
        applicationObjectId = $application.objectId
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
