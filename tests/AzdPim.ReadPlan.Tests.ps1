BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Common.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Graph.psm1') -Force
}

Describe 'owned-reader plan boundary' {
    BeforeEach {
        # Do not inherit a developer's deployment configuration into fixtures.
        $script:savedEnvironment = @{}
        Get-ChildItem Env:AZD_PIM_* | ForEach-Object {
            $savedEnvironment[$_.Name] = $_.Value
            Remove-Item -LiteralPath "Env:$($_.Name)"
        }
        $script:configuration = Get-AzdPimConfiguration
        $configuration.PrivilegedRoleIds = @('11111111-1111-1111-1111-111111111111')
        $script:reader = [pscustomobject]@{
            TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            Calls = [System.Collections.Generic.List[string]]::new()
            ConditionalAccessPolicies = @()
            StrengthResponses = @{}
        }
        $reader | Add-Member ScriptMethod ReadPimJson {
            param([string] $Uri)
            $this.Calls.Add($Uri)
            if ($Uri -like 'https://graph.microsoft.com/v1.0/policies/authenticationStrengthPolicies*') {
                if (-not $this.StrengthResponses.ContainsKey($Uri)) { throw 'Unsupported authentication-strength query.' }
                return ($this.StrengthResponses[$Uri] | ConvertTo-Json -Depth 30 -Compress)
            }
            $values = switch -Wildcard ($Uri) {
                '*conditionalAccess/policies*' { $this.ConditionalAccessPolicies }
                '*roleDefinitions*true' {
                    @{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Fixture role'; description = ''; isBuiltIn = $true; isEnabled = $true; isPrivileged = $true }
                }
                '*roleManagementPolicyAssignments*' {
                    @{ roleDefinitionId = '11111111-1111-1111-1111-111111111111'; policyId = 'fixture-policy' }
                }
                '*roleManagementPolicies*' {
                    @{ id = 'fixture-policy'; rules = @(
                        @{ id = 'AuthenticationContext_EndUser_Assignment'; isEnabled = $false; claimValue = '' },
                        @{ id = 'Enablement_EndUser_Assignment'; enabledRules = @('MultiFactorAuthentication', 'Justification') }
                    ) }
                }
            }
            return (@{ value = @($values | Where-Object { $null -ne $_ }) } | ConvertTo-Json -Depth 30 -Compress)
        }
    }

    AfterEach {
        Get-ChildItem Env:AZD_PIM_* | Remove-Item
        foreach ($name in $savedEnvironment.Keys) { Set-Item -LiteralPath "Env:$name" -Value $savedEnvironment[$name] }
    }

    It 'runs the real planner through the supplied reader without SDK authentication' {
        $plan = New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader
        $plan.tenantId | Should -Be $reader.TenantId
        $plan.mode | Should -Be 'plan'
        $plan.tiers.privileged.roles.Count | Should -Be 1
        $plan.tiers.privileged.context.action | Should -Be 'create'
        $plan.tiers.privileged.conditionalAccessPolicies[0].action | Should -Be 'create'
        $plan.tiers.privileged.roleRules[0].activationMfa.desiredEnabledRules | Should -Be @('Justification')
        $reader.Calls.Count | Should -Be 6
        $path = Join-Path $TestDrive 'plan.json'
        Write-AzdPimPlanReport -Plan $plan -Path $path
        (Get-Content -Raw $path | ConvertFrom-Json).tiers.privileged.roles[0].displayName | Should -Be 'Fixture role'
        InModuleScope AzdPim.Graph { $script:ReadPlanContext | Should -BeNullOrEmpty }
    }

    It 'plans ordinary CA policies with absent or null optional context targeting' -ForEach @(
        @{ PolicyJson = '{"id":"ordinary","conditions":{"applications":{"includeApplications":["All"]}}}' },
        @{ PolicyJson = '{"id":"ordinary","conditions":{}}' },
        @{ PolicyJson = '{"id":"ordinary","conditions":{"applications":null}}' },
        @{ PolicyJson = '{"id":"ordinary"}' },
        @{ PolicyJson = '{"id":"ordinary","conditions":null}' },
        @{ PolicyJson = '{"id":"ordinary","conditions":{"applications":{"includeAuthenticationContextClassReferences":null}}}' },
        @{ PolicyJson = '{"id":"ordinary","conditions":{"applications":{"includeAuthenticationContextClassReferences":[]}}}' }
    ) {
        $policy = $PolicyJson | ConvertFrom-Json
        $policy | Add-Member NoteProperty displayName 'Unrelated existing policy'
        $reader.ConditionalAccessPolicies = @($policy)
        $plan = New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader
        $plan.tiers.privileged.context.id | Should -Be 'c1'
        $plan.tiers.privileged.context.action | Should -Be 'create'
        $reader.Calls.Count | Should -Be 6
        InModuleScope AzdPim.Graph { $script:ReadPlanContext | Should -BeNullOrEmpty }
    }

    It 'retains existing context references and never allocates a referenced slot' -ForEach @(
        @{ ReferenceJson = '["c1"]'; ExpectedId = 'c2' },
        @{ ReferenceJson = '["c1","c2"]'; ExpectedId = 'c3' }
    ) {
        $reader.ConditionalAccessPolicies = @((('{"id":"context-policy","displayName":"Unrelated existing policy","conditions":{"applications":{"includeAuthenticationContextClassReferences":' + $ReferenceJson + '}}}') | ConvertFrom-Json))
        $plan = New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader
        $plan.tiers.privileged.context.id | Should -Be $ExpectedId
        $plan.tiers.privileged.context.action | Should -Be 'create'
    }

    It 'rejects malformed CA policy entries instead of ignoring their possible references' -ForEach @(
        @{ PolicyJson = 'null' },
        @{ PolicyJson = '"invalid"' },
        @{ PolicyJson = '1' },
        @{ PolicyJson = '[{}]' }
    ) {
        $policy = ConvertFrom-Json -InputObject $PolicyJson -NoEnumerate
        # A null collection member is rejected by mandatory parameter binding;
        # other invalid shapes reach the explicit policy-object guard.
        if ($null -eq $policy) {
            { Get-AzdPimReferencedContextIds -ConditionalAccessPolicies (, $policy) -RolePolicies @() } | Should -Throw
        } else {
            { Get-AzdPimReferencedContextIds -ConditionalAccessPolicies (, $policy) -RolePolicies @() } | Should -Throw '*context references*invalid policy object*'
        }
    }

    It 'rejects malformed CA context targeting instead of freeing a referenced slot' -ForEach @(
        @{ PolicyJson = '{"conditions":"invalid"}' },
        @{ PolicyJson = '{"conditions":[]}' },
        @{ PolicyJson = '{"conditions":{"applications":"invalid"}}' },
        @{ PolicyJson = '{"conditions":{"applications":[]}}' },
        @{ PolicyJson = '{"conditions":{"applications":{"includeAuthenticationContextClassReferences":"c1"}}}' },
        @{ PolicyJson = '{"conditions":{"applications":{"includeAuthenticationContextClassReferences":{"id":"c1"}}}}' },
        @{ PolicyJson = '{"conditions":{"applications":{"includeAuthenticationContextClassReferences":[null]}}}' },
        @{ PolicyJson = '{"conditions":{"applications":{"includeAuthenticationContextClassReferences":[""]}}}' },
        @{ PolicyJson = '{"conditions":{"applications":{"includeAuthenticationContextClassReferences":[" c1"]}}}' },
        @{ PolicyJson = '{"conditions":{"applications":{"includeAuthenticationContextClassReferences":[1]}}}' },
        @{ PolicyJson = '{"conditions":{"applications":{"includeAuthenticationContextClassReferences":[{"id":"c1"}]}}}' },
        @{ PolicyJson = '{"conditions":{"applications":{"includeAuthenticationContextClassReferences":[["c1"]]}}}' }
    ) {
        $reader.ConditionalAccessPolicies = @($PolicyJson | ConvertFrom-Json)
        { New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader } | Should -Throw '*context references*'
        InModuleScope AzdPim.Graph { $script:ReadPlanContext | Should -BeNullOrEmpty }
    }

    It 'uses the documented strength collection query and follows returned pagination' -ForEach @(
        @{ Profile = 'phishingResistant' },
        @{ Profile = 'custom' }
    ) {
        # The v1.0 list API documents a bare collection and optional $filter,
        # not $top. A strict transport must expose unsupported request options.
        $uri = 'https://graph.microsoft.com/v1.0/policies/authenticationStrengthPolicies'
        $next = $uri + '?$skiptoken=strength-fixture'
        $strengthId = '00000000-0000-0000-0000-000000000004'
        $reader.StrengthResponses[$uri] = @{ value = @(); '@odata.nextLink' = $next }
        $reader.StrengthResponses[$next] = @{ value = @(@{
            id = $strengthId; policyType = 'builtIn'; displayName = 'Phishing-resistant MFA'
        }) }
        $configuration.PrivilegedAuthenticationProfile = $Profile
        $configuration.PrivilegedAuthenticationStrengthId = $strengthId

        { $reader.ReadPimJson($uri + '?$top=100') } | Should -Throw '*Unsupported authentication-strength query*'
        $reader.Calls.Clear()
        $plan = New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader
        $plan.tiers.privileged.authenticationStrength.id | Should -Be $strengthId
        $plan.tiers.privileged.conditionalAccessPolicies[0].body.grantControls.authenticationStrength.id | Should -Be $strengthId
        $reader.Calls.Count | Should -Be 8
        $reader.Calls | Should -Contain $uri
        $reader.Calls | Should -Contain $next
        $reader.Calls | Should -Not -Contain ($uri + '?$top=100')
        InModuleScope AzdPim.Graph { $script:ReadPlanContext | Should -BeNullOrEmpty }
    }

    It 'rejects unsupported configuration before invoking the reader' -ForEach @(
        @{ Property = 'Mode'; Value = 'enforced' },
        @{ Property = 'NotificationMode'; Value = 'polling' },
        @{ Property = 'EnableSessionRevocation'; Value = $true },
        @{ Property = 'EmergencyAccessGroupId'; Value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' },
        @{ Property = 'TeamsWebhookUrl'; Value = 'https://example.invalid/webhook' },
        @{ Property = 'SentinelWorkspaceResourceId'; Value = 'fixture' },
        @{ Property = 'RevocationAlertActionGroupResourceId'; Value = 'fixture' }
    ) {
        $configuration.$Property = $Value
        { New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader } | Should -Throw '*only plan mode*'
        $reader.Calls.Count | Should -Be 0
    }

    It 'rejects writes before dispatch and releases the scoped reader after failure' {
        Mock New-AzdPimPlan -ModuleName AzdPim.Graph {
            Invoke-AzdPimGraphRequest -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/policies/roleManagementPolicies/fixture'
        }
        { New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader } | Should -Throw '*Writes and request bodies are forbidden*'
        $reader.Calls.Count | Should -Be 0
        InModuleScope AzdPim.Graph { $script:ReadPlanContext | Should -BeNullOrEmpty }
    }

    It 'does not retry or fall back when the owned reader fails' {
        $reader | Add-Member ScriptMethod ReadPimJson { param($Uri) $this.Calls.Add($Uri); throw 'Fixture cancellation' } -Force
        { New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader } | Should -Throw '*Fixture cancellation*'
        $reader.Calls.Count | Should -Be 1
        InModuleScope AzdPim.Graph { $script:ReadPlanContext | Should -BeNullOrEmpty }
    }

    It 'rejects even an explicitly null GET body before dispatch' {
        Mock New-AzdPimPlan -ModuleName AzdPim.Graph {
            Invoke-AzdPimGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me' -Body $null
        }
        { New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader } | Should -Throw '*request bodies are forbidden*'
        $reader.Calls.Count | Should -Be 0
    }

    It 'clears the reader after malformed response JSON' {
        $reader | Add-Member ScriptMethod ReadPimJson { param($Uri) return '{invalid' } -Force
        { New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader } | Should -Throw
        InModuleScope AzdPim.Graph { $script:ReadPlanContext | Should -BeNullOrEmpty }
    }

    It 'rejects nested plans without replacing the running reader' {
        Mock New-AzdPimPlan -ModuleName AzdPim.Graph {
            param($Configuration, $State)
            New-AzdPimReadPlan -Configuration $Configuration -ReadContext ([pscustomobject]@{})
        }
        { New-AzdPimReadPlan -Configuration $configuration -ReadContext $reader } | Should -Throw '*already running*'
        InModuleScope AzdPim.Graph { $script:ReadPlanContext | Should -BeNullOrEmpty }
    }
}
