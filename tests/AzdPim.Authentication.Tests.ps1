BeforeAll {
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzdPim.Authentication.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/vendor/Azd.GraphAuthentication/Azd.GraphAuthentication.psd1') -Force
    $script:tenantId = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:expectedAccount = 'admin@example.com'
}

Describe 'Microsoft Graph permission planning' {
    It 'requests core permissions without optional workflow permissions by default' {
        $scopes = @(Get-AzdPimGraphPermissionScope)

        $scopes | Should -Contain 'RoleManagement.Read.Directory'
        $scopes | Should -Contain 'RoleManagementPolicy.ReadWrite.Directory'
        $scopes | Should -Contain 'Policy.ReadWrite.ConditionalAccess'
        $scopes | Should -Not -Contain 'Application.ReadWrite.All'
        $scopes | Should -Not -Contain 'AppRoleAssignment.ReadWrite.All'
        $scopes | Should -Not -Contain 'PrivilegedAccess-CustomExt.ReadWrite.All'
    }

    It 'adds all configured optional deployment permissions to one unique scope set' {
        $scopes = @(Get-AzdPimGraphPermissionScope -IncludeEmergencyAccessGroup -NotificationMode polling -EnableSessionRevocation)

        $scopes | Should -Contain 'Group.Read.All'
        $scopes | Should -Contain 'Application.Read.All'
        $scopes | Should -Contain 'Application.ReadWrite.All'
        $scopes | Should -Contain 'AppRoleAssignment.ReadWrite.All'
        $scopes | Should -Contain 'PrivilegedAccess-CustomExt.ReadWrite.All'
        ($scopes | Sort-Object -Unique).Count | Should -Be $scopes.Count
    }
}

Describe 'shared Microsoft Graph authentication adapter' {
    BeforeEach {
        Mock Connect-AzdGraphSession -ModuleName AzdPim.Authentication {
            [pscustomobject]@{
                tenantId = $tenantId.Guid
                account = $expectedAccount
                grantedScopes = @($Scopes)
                connectInvoked = $false
                contextReused = $true
                probeSucceeded = $true
            }
        }
    }

    It 'uses the shared exact-context probe and explicitly authorized interactive replacement path' {
        $scopes = @(Get-AzdPimGraphPermissionScope)

        $result = Connect-AzdPimGraph `
            -TenantId $tenantId `
            -ExpectedAccount $expectedAccount `
            -Scopes $scopes `
            -AllowInteractive `
            -AllowContextReplacement

        $result.contextReused | Should -BeTrue
        Should -Invoke Connect-AzdGraphSession -ModuleName AzdPim.Authentication -Times 1 -Exactly -ParameterFilter {
            $TenantId -eq $script:tenantId -and
            $ExpectedAccount -eq $script:expectedAccount -and
            $Environment -eq 'Global' -and
            $ProbeUri -eq '/v1.0/roleManagement/directory/roleDefinitions?$select=id' -and
            $AllowInteractive -and
            $AllowContextReplacement -and
            @($Scopes).Count -eq $scopes.Count
        }
    }

    It 'passes optional permissions to the same shared authentication call' {
        $configuration = [pscustomobject]@{
            EmergencyAccessGroupId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            NotificationMode = 'polling'
            EnableSessionRevocation = $true
        }

        Connect-AzdPimConfiguredGraph `
            -TenantId $tenantId `
            -ExpectedAccount $expectedAccount `
            -Configuration $configuration `
            -AllowInteractive `
            -AllowContextReplacement | Out-Null

        Should -Invoke Connect-AzdGraphSession -ModuleName AzdPim.Authentication -Times 1 -Exactly -ParameterFilter {
            @($Scopes) -contains 'Group.Read.All' -and
            @($Scopes) -contains 'Application.ReadWrite.All' -and
            @($Scopes) -contains 'PrivilegedAccess-CustomExt.ReadWrite.All'
        }
    }

    It 'keeps the role-definition probe on the supported select-only query' {
        $adapterSource = Get-Content -Raw (Join-Path $PSScriptRoot '../scripts/AzdPim.Authentication.psm1')
        $probeMatch = [regex]::Match(
            $adapterSource,
            'ProbeUri\s*=\s*''(?<uri>/v1\.0/roleManagement/directory/roleDefinitions\?[^'']+)'''
        )

        $probeMatch.Success | Should -BeTrue
        $probeMatch.Groups['uri'].Value | Should -Be '/v1.0/roleManagement/directory/roleDefinitions?$select=id'
        $probeMatch.Groups['uri'].Value | Should -Not -Match '\$top(?:=|&|$)'
    }
}

Describe 'Azure operator identity binding' {
    It 'binds Graph authentication to the selected Azure CLI user and tenant' {
        Mock Get-Command -ModuleName AzdPim.Authentication { [pscustomobject]@{ Name = 'az' } } -ParameterFilter { $Name -eq 'az' }
        Mock az -ModuleName AzdPim.Authentication {
            $global:LASTEXITCODE = 0
            '{"tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","user":{"name":"admin@example.com","type":"user"}}'
        }

        $result = Get-AzdPimAzureOperatorContext

        $result.tenantId | Should -Be $tenantId
        $result.account | Should -Be $expectedAccount
        Should -Invoke az -ModuleName AzdPim.Authentication -Times 1 -Exactly
    }

    It 'rejects an Azure CLI service principal instead of selecting a different delegated administrator' {
        Mock Get-Command -ModuleName AzdPim.Authentication { [pscustomobject]@{ Name = 'az' } } -ParameterFilter { $Name -eq 'az' }
        Mock az -ModuleName AzdPim.Authentication {
            $global:LASTEXITCODE = 0
            '{"tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","user":{"name":"app-id","type":"servicePrincipal"}}'
        }

        { Get-AzdPimAzureOperatorContext } | Should -Throw '*interactive Azure CLI user account*'
    }
}

Describe 'vendored Graph authentication component' {
    It 'reuses a matching same-tenant delegated context after one read-only probe' {
        $scopes = @(Get-AzdPimGraphPermissionScope)
        $context = [pscustomobject]@{
            TenantId = $tenantId.Guid
            Environment = 'Global'
            AuthType = 'Delegated'
            ContextScope = 'CurrentUser'
            Account = $expectedAccount
            Scopes = $scopes
        }
        Mock Get-MgEnvironment -ModuleName Azd.GraphAuthentication {
            [pscustomobject]@{ Name = 'Global' }
        }
        Mock Get-MgContext -ModuleName Azd.GraphAuthentication { $context }
        Mock Invoke-MgGraphRequest -ModuleName Azd.GraphAuthentication { [pscustomobject]@{ id = 'probe' } }
        Mock Connect-MgGraph -ModuleName Azd.GraphAuthentication

        $result = Connect-AzdGraphSession `
            -TenantId $tenantId `
            -ExpectedAccount $expectedAccount `
            -Scopes $scopes `
            -ProbeUri '/v1.0/roleManagement/directory/roleDefinitions?$select=id'

        $result.contextReused | Should -BeTrue
        $result.connectInvoked | Should -BeFalse
        Should -Invoke Invoke-MgGraphRequest -ModuleName Azd.GraphAuthentication -Times 1 -Exactly
        Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    }

    It 'matches the vendored module manifest and every file recorded in the component lock' {
        $templateRoot = Split-Path -Parent $PSScriptRoot
        $lock = Get-Content -Raw (Join-Path $templateRoot 'azd-components.lock.json') | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'graph-delegated-authentication')
        $moduleManifest = Test-ModuleManifest -Path (
            Join-Path $templateRoot 'scripts/vendor/Azd.GraphAuthentication/Azd.GraphAuthentication.psd1'
        )

        $component.Count | Should -Be 1
        $component[0].version | Should -Be $moduleManifest.Version.ToString()
        $component[0].sourceRevision | Should -Match '^[0-9a-f]{40}$'
        foreach ($file in @($component[0].files)) {
            $actualHash = (Get-FileHash -Algorithm SHA256 (Join-Path $templateRoot $file.target)).Hash.ToLowerInvariant()
            $actualHash | Should -Be $file.sha256
        }
    }

    It 'contains no alternate device-code authentication switches or credentials' {
        $scriptsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $source = (Get-ChildItem $scriptsRoot -Recurse -File -Include *.ps1,*.psm1,*.psd1 | Get-Content -Raw) -join "`n"

        $source | Should -Not -Match '(?i)UseDeviceCode|--use-device-code|DeviceCodeCredential'
    }
}
