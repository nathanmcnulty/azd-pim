BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/Deployment.Validation.psm1') -Force

    function New-TestPimPlan {
        param(
            [string] $ContextAction = 'none',
            [string] $PolicyAction = 'none',
            [string] $RoleRuleAction = 'none',
            [string] $ActivationMfaAction = 'none'
        )

        [pscustomobject] @{
            inventory = @(
                [pscustomobject] @{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Privileged'; isPrivileged = $true },
                [pscustomobject] @{ id = '22222222-2222-2222-2222-222222222222'; displayName = 'Less'; isPrivileged = $false }
            )
            graphApiVersions = [pscustomobject] @{ roleClassification = 'beta' }
            tiers = [pscustomobject] @{
                privileged = [pscustomobject] @{
                    roles = @([pscustomobject] @{ id = '11111111-1111-1111-1111-111111111111'; isPrivileged = $true })
                    context = [pscustomobject] @{ id = 'c1'; action = $ContextAction }
                    conditionalAccessPolicies = @([pscustomobject] @{ action = $PolicyAction })
                    roleRules = @([pscustomobject] @{
                        action = $RoleRuleAction
                        activationMfa = [pscustomobject] @{ action = $ActivationMfaAction }
                    })
                }
                lessPrivileged = [pscustomobject] @{
                    roles = @([pscustomobject] @{ id = '22222222-2222-2222-2222-222222222222'; isPrivileged = $false })
                    context = [pscustomobject] @{ id = 'c2'; action = 'none' }
                    conditionalAccessPolicies = @([pscustomobject] @{ action = 'none' })
                    roleRules = @([pscustomobject] @{
                        action = 'none'
                        activationMfa = [pscustomobject] @{ action = 'none' }
                    })
                }
            }
        }
    }
}

Describe 'azd-pim deployment validation definitions' {
    It 'matches the vendored module manifest and every file recorded in the component lock' {
        $templateRoot = Split-Path -Parent $PSScriptRoot
        $lock = Get-Content -LiteralPath (Join-Path $templateRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'deployment-validation')
        $moduleManifest = Test-ModuleManifest -Path (
            Join-Path $templateRoot 'scripts/vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1'
        )

        $component.Count | Should -Be 1
        $component[0].version | Should -Be $moduleManifest.Version.ToString()
        $component[0].sourceRevision | Should -Match '^[0-9a-f]{40}$'
        foreach ($file in @($component[0].files)) {
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $templateRoot $file.target)).Hash.ToLowerInvariant()
            $actualHash | Should -Be $file.sha256
        }
    }

    It 'plans every check without calling authentication, cloud, HTTP, or delivery functions' {
        Mock Import-AzdEnvironment -ModuleName Deployment.Validation { throw 'Plan must not load azd environment values.' }
        Mock Get-MgContext -ModuleName Deployment.Validation { throw 'Plan must not inspect Graph context.' }
        Mock New-AzdPimPlan -ModuleName Deployment.Validation { throw 'Plan must not query Microsoft Graph.' }
        Mock Send-AzdPimTeamsDestinationTest -ModuleName Deployment.Validation { throw 'Plan must not send delivery tests.' }

        $definitions = @(Get-ProjectValidationDefinition)
        $results = @(Invoke-AzdValidationSet -Definitions $definitions -Plan)

        $results.Count | Should -Be 10
        @($results | Where-Object status -ne 'planned').Count | Should -Be 0
        Should -Invoke Import-AzdEnvironment -ModuleName Deployment.Validation -Times 0 -Exactly
        Should -Invoke Get-MgContext -ModuleName Deployment.Validation -Times 0 -Exactly
        Should -Invoke New-AzdPimPlan -ModuleName Deployment.Validation -Times 0 -Exactly
        Should -Invoke Send-AzdPimTeamsDestinationTest -ModuleName Deployment.Validation -Times 0 -Exactly
    }

    It 'declares only earlier dependencies and one explicit synthetic-delivery check' {
        $definitions = @(Get-ProjectValidationDefinition)
        $declared = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($definition in $definitions) {
            foreach ($dependency in @($definition.dependsOn)) {
                $declared.Contains($dependency) | Should -BeTrue -Because "$($definition.id) depends only on an earlier check"
            }
            [void] $declared.Add($definition.id)
        }

        @($definitions | Where-Object sideEffect -eq 'syntheticDelivery').id | Should -Be @('delivery.teams-destination')
        @($definitions | Where-Object sideEffect -notin @('none', 'readOnly', 'syntheticDelivery')).Count | Should -Be 0
    }

    It 'produces a schema-valid structured report in plan mode' {
        $relativeOutputPath = "reports/deployment-validation-test-$([guid]::NewGuid().Guid).json"
        $outputPath = Join-Path $PSScriptRoot "../$relativeOutputPath"
        $report = & (Join-Path $PSScriptRoot '../scripts/Test-Deployment.ps1') -Plan -PassThru -OutputPath $relativeOutputPath

        $report.template.name | Should -Be 'azd-pim'
        $report.mode | Should -Be 'plan'
        @($report.checks | Where-Object status -ne 'planned').Count | Should -Be 0
        (Get-Content -LiteralPath $outputPath -Raw) | Test-Json `
            -SchemaFile (Join-Path $PSScriptRoot '../scripts/vendor/Azd.DeploymentValidation/deployment-validation.schema.json') | Should -BeTrue
        Remove-Item -LiteralPath $outputPath -Force
    }
}

Describe 'azd-pim exact cached context validation' {
    BeforeEach {
        $env:AZURE_TENANT_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $env:AZURE_SUBSCRIPTION_ID = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    }

    AfterEach {
        Remove-Item Env:AZURE_TENANT_ID, Env:AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
    }

    It 'accepts one exact azd, Azure CLI, and Graph context without connecting' {
        InModuleScope Deployment.Validation {
            Mock Import-AzdEnvironment
            Mock Get-Module {
                [pscustomobject] @{ Version = [version] '2.30.0' }
            } -ParameterFilter { $ListAvailable }
            Mock Import-Module
            Mock Get-MgContext { [pscustomobject] @{
                TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                Scopes = @('RoleManagement.Read.Directory')
            } }
            Mock az {
                '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
            }

            { Initialize-AzdPimValidationContext } | Should -Not -Throw
            Should -Invoke az -Times 2 -Exactly
            Should -Invoke Get-MgContext -Times 1 -Exactly
        }
    }

    It 'derives a missing tenant from the exact configured subscription for Graph and report use without persisting it' {
        Remove-Item Env:AZURE_TENANT_ID -ErrorAction SilentlyContinue
        InModuleScope Deployment.Validation {
            Mock Import-AzdEnvironment
            Mock Get-Module {
                [pscustomobject] @{ Version = [version] '2.30.0' }
            } -ParameterFilter { $ListAvailable }
            Mock Import-Module
            Mock Get-MgContext { [pscustomobject] @{
                TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                Scopes = @('RoleManagement.Read.Directory')
            } }
            Mock Set-AzdEnvironmentValue
            Mock az {
                $global:LASTEXITCODE = 0
                '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
            }

            Initialize-AzdPimValidationContext

            $env:AZURE_TENANT_ID | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            Should -Invoke az -Times 2 -Exactly
            Should -Invoke Get-MgContext -Times 1 -Exactly
            Should -Invoke Set-AzdEnvironmentValue -Times 0 -Exactly
        }

        $testDeployment = Get-Content -Raw (Join-Path $PSScriptRoot '../scripts/Test-Deployment.ps1')
        $testDeployment | Should -Match 'tenantId = \[string\] \$env:AZURE_TENANT_ID'
        $validationModule = Get-Content -Raw (Join-Path $PSScriptRoot '../scripts/Deployment.Validation.psm1')
        $validationModule | Should -Not -Match 'azd\s+env\s+set[\s\S]*AZURE_TENANT_ID|Set-AzdEnvironmentValue[\s\S]*AZURE_TENANT_ID'
    }

    It 'rejects an explicit tenant that differs from the configured and active subscription tenant' {
        InModuleScope Deployment.Validation {
            Mock Import-AzdEnvironment
            Mock az {
                $global:LASTEXITCODE = 0
                '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"cccccccc-cccc-cccc-cccc-cccccccccccc"}'
            }
            Mock Get-MgContext

            { Initialize-AzdPimValidationContext } | Should -Throw '*tenant context does not match*'
            Should -Invoke Get-MgContext -Times 0 -Exactly
        }
    }

    It 'requires a valid configured subscription before reading Azure CLI contexts' {
        InModuleScope Deployment.Validation {
            Mock Import-AzdEnvironment
            Mock az

            Remove-Item Env:AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
            { Initialize-AzdPimValidationContext } | Should -Throw '*AZURE_SUBSCRIPTION_ID is required*'
            Should -Invoke az -Times 0 -Exactly

            $env:AZURE_SUBSCRIPTION_ID = 'not-a-guid'
            { Initialize-AzdPimValidationContext } | Should -Throw '*must be a valid GUID*'
            Should -Invoke az -Times 0 -Exactly
        }
    }

    It 'rejects invalid or missing Azure CLI subscription context data' {
        InModuleScope Deployment.Validation {
            $script:azCalls = 0
            Mock Import-AzdEnvironment
            Mock az {
                $global:LASTEXITCODE = 0
                $script:azCalls++
                if ($script:azCalls -eq 1) {
                    return '{"id":"not-a-guid","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
                }
                '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
            }

            { Initialize-AzdPimValidationContext } | Should -Throw '*without valid GUIDs*'

            $script:azCalls = 0
            Mock az {
                $global:LASTEXITCODE = 0
                $script:azCalls++
                if ($script:azCalls -eq 1) {
                    return '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
                }
                ''
            }

            { Initialize-AzdPimValidationContext } | Should -Throw '*active Azure CLI context could not be read*'
        }
    }

    It 'rejects a missing or invalid Microsoft Graph tenant context' {
        InModuleScope Deployment.Validation {
            Mock Import-AzdEnvironment
            Mock Get-Module {
                [pscustomobject] @{ Version = [version] '2.30.0' }
            } -ParameterFilter { $ListAvailable }
            Mock Import-Module
            Mock az {
                $global:LASTEXITCODE = 0
                '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
            }
            Mock Get-MgContext { $null }

            { Initialize-AzdPimValidationContext } | Should -Throw '*Microsoft Graph tenant context does not match*'

            Mock Get-MgContext { [pscustomobject] @{ TenantId = 'not-a-guid' } }
            { Initialize-AzdPimValidationContext } | Should -Throw '*Microsoft Graph tenant context does not match*'
        }
    }

    It 'rejects an active subscription mismatch even when the tenant matches' {
        InModuleScope Deployment.Validation {
            $script:azCalls = 0
            Mock Import-AzdEnvironment
            Mock az {
                $script:azCalls++
                if ($script:azCalls -eq 1) {
                    return '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
                }
                '{"id":"cccccccc-cccc-cccc-cccc-cccccccccccc","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
            }

            { Initialize-AzdPimValidationContext } | Should -Throw '*subscription context does not match*'
        }
    }

    It 'reports missing Graph scopes without initiating another connection' {
        InModuleScope Deployment.Validation {
            $script:ValidationConfiguration = [pscustomobject] @{
                EmergencyAccessGroupId = ''
                NotificationMode = 'none'
                EnableSessionRevocation = $false
            }
            $script:ValidationGraphContext = [pscustomobject] @{
                Scopes = @('RoleManagement.Read.Directory')
            }
            Mock Get-AzdPimGraphPermissionScope {
                @('RoleManagement.Read.Directory', 'Policy.ReadWrite.ConditionalAccess')
            }
            Mock Connect-MgGraph

            { Assert-AzdPimValidationGraphScope } | Should -Throw '*missing required Microsoft Graph delegated scopes*'
            Should -Invoke Connect-MgGraph -Times 0 -Exactly
        }
    }
}

Describe 'role scope and drift outcomes' {
    It 'reports selected role counts independently for both tiers' {
        InModuleScope Deployment.Validation {
            $definition = @(Get-ProjectValidationDefinition | Where-Object id -eq 'configuration.role-scope')[0]
            $configuration = [pscustomobject] @{
                PrivilegedRoleScope = 'selected'
                PrivilegedRoleIds = @('11111111-1111-1111-1111-111111111111')
                LessPrivilegedRoleScope = 'selected'
                LessPrivilegedRoleIds = @()
            }
            Mock Get-AzdPimConfiguration { $configuration }
            $result = & $definition.action

            $result.status | Should -Be 'pass'
            $result.actual.privilegedScope | Should -Be 'selected'
            $result.actual.privilegedSelectedCount | Should -Be 1
            $result.actual.lessPrivilegedSelectedCount | Should -Be 0
        }
    }

    It 'reports all scope independently for both tiers' {
        InModuleScope Deployment.Validation {
            $definition = @(Get-ProjectValidationDefinition | Where-Object id -eq 'configuration.role-scope')[0]
            $configuration = [pscustomobject] @{
                PrivilegedRoleScope = 'all'
                PrivilegedRoleIds = @()
                LessPrivilegedRoleScope = 'all'
                LessPrivilegedRoleIds = @()
            }
            Mock Get-AzdPimConfiguration { $configuration }
            $result = & $definition.action

            $result.status | Should -Be 'pass'
            $result.actual.privilegedScope | Should -Be 'all'
            $result.actual.lessPrivilegedScope | Should -Be 'all'
        }
    }

    It 'treats pending actions as informational in solution plan mode' {
        InModuleScope Deployment.Validation {
            $script:ValidationConfiguration = [pscustomobject] @{ Mode = 'plan' }
            $result = Resolve-AzdPimPlanStateOutcome -Subject 'Authentication contexts' -PendingCount 2 `
                -FailureCode 'configuration.authenticationContextDrift' -Remediation 'Apply the plan.'

            $result.status | Should -Be 'info'
            $result.actual.pendingChangeCount | Should -Be 2
        }
    }

    It 'returns a safe coded failure for drift in enforced mode' {
        InModuleScope Deployment.Validation {
            $script:ValidationConfiguration = [pscustomobject] @{ Mode = 'enforced' }
            $result = Resolve-AzdPimPlanStateOutcome -Subject 'Conditional Access policies' -PendingCount 1 `
                -FailureCode 'configuration.conditionalAccessDrift' -Remediation 'Apply the plan.'

            $result.status | Should -Be 'fail'
            $result.actual.failureCode | Should -Be 'configuration.conditionalAccessDrift'
            $result.actual.pendingChangeCount | Should -Be 1
        }
    }

    It 'counts authentication context, policy, selected role, and legacy MFA drift separately' {
        $plan = New-TestPimPlan -ContextAction update -PolicyAction update -RoleRuleAction update -ActivationMfaAction remove
        InModuleScope Deployment.Validation -Parameters @{ TestPlan = $plan } {
            param($TestPlan)
            $script:ValidationPlan = $TestPlan
            Get-AzdPimPlanDriftCount -Kind contexts | Should -Be 1
            Get-AzdPimPlanDriftCount -Kind policies | Should -Be 1
            Get-AzdPimPlanDriftCount -Kind roleRules | Should -Be 1
            Get-AzdPimPlanDriftCount -Kind activationMfa | Should -Be 1
        }
    }
}

Describe 'optional workflow and delivery boundaries' {
    It 'requires no Azure resources when optional workflows are disabled' {
        InModuleScope Deployment.Validation {
            $script:ValidationConfiguration = [pscustomobject] @{
                NotificationMode = 'none'
                EnableSessionRevocation = $false
                RevocationAlertActionGroupResourceId = ''
            }
            @(Get-AzdPimOptionalResourceId).Count | Should -Be 0
        }
    }

    It 'does not require undeployed optional resources in solution plan mode' {
        InModuleScope Deployment.Validation {
            $definition = @(Get-ProjectValidationDefinition | Where-Object id -eq 'infrastructure.optional-workflows')[0]
            $script:ValidationConfiguration = [pscustomobject] @{
                Mode = 'plan'
                NotificationMode = 'polling'
                EnableSessionRevocation = $true
                RevocationAlertActionGroupResourceId = ''
            }
            Mock az { throw 'Plan configuration must not inspect optional Azure resources.' }

            $result = & $definition.action

            $result.status | Should -Be 'info'
            Should -Invoke az -Times 0 -Exactly
        }
    }

    It 'does not send a Teams message when notifications are disabled' {
        InModuleScope Deployment.Validation {
            $definition = @(Get-ProjectValidationDefinition | Where-Object id -eq 'delivery.teams-destination')[0]
            $script:ValidationConfiguration = [pscustomobject] @{ NotificationMode = 'none' }
            Mock Send-AzdPimTeamsDestinationTest
            $result = & $definition.action

            $result.status | Should -Be 'info'
            Should -Invoke Send-AzdPimTeamsDestinationTest -Times 0 -Exactly
        }
    }

    It 'returns one safe outcome after an explicit Teams destination test' {
        InModuleScope Deployment.Validation {
            $definition = @(Get-ProjectValidationDefinition | Where-Object id -eq 'delivery.teams-destination')[0]
            $script:ValidationConfiguration = [pscustomobject] @{
                NotificationMode = 'polling'
                TeamsWebhookUrl = 'https://example.invalid/workflows/test'
            }
            Mock Send-AzdPimTeamsDestinationTest {
                [pscustomobject] @{ trackingId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'; statusCode = 202 }
            }
            $results = @(& $definition.action)

            $results.Count | Should -Be 1
            $results[0].status | Should -Be 'pass'
            $results[0].evidence.trackingId | Should -Be 'dddddddd-dddd-dddd-dddd-dddddddddddd'
            Should -Invoke Send-AzdPimTeamsDestinationTest -Times 1 -Exactly
        }
    }
}
