#Requires -Version 7.6
BeforeAll {
    $scripts = Join-Path $PSScriptRoot '../scripts'
    $fixtureRoot = Join-Path $TestDrive 'producer'
    $fixtureScripts = Join-Path $fixtureRoot 'scripts'
    $fixtureModules = Join-Path $fixtureRoot 'modules'
    $graphModule = Join-Path $fixtureModules 'Microsoft.Graph.Authentication/2.30.0'
    New-Item -ItemType Directory -Path $fixtureScripts,$graphModule,(Join-Path $fixtureRoot 'reports') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $scripts 'Post-Provision.ps1'),(Join-Path $scripts 'Post-Provision.Native.ps1') -Destination $fixtureScripts
    New-ModuleManifest -Path (Join-Path $graphModule 'Microsoft.Graph.Authentication.psd1') -ModuleVersion '2.30.0'

    @'
function Import-AzdEnvironment {
    $env:AZURE_SUBSCRIPTION_ID = '22222222-2222-4222-8222-222222222222'
    $env:AZURE_RESOURCE_GROUP = 'rg-fixture'
    $env:AZURE_ENV_NAME = 'dev'
    $env:AZD_PIM_REVOCATION_LOGIC_APP_RESOURCE_ID = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-fixture/providers/Microsoft.Logic/workflows/pim-revoke-sessions-example'
    $env:AZD_PIM_REVOCATION_LOGIC_APP_PRINCIPAL_ID = '55555555-5555-4555-8555-555555555555'
}
function Get-AzdPimConfiguration {
    [pscustomobject]@{
        Mode = if ($env:AZD_PIM_FIXTURE -eq 'plan') { 'plan' } else { 'enforced' }
        NotificationMode = 'none'
        EnableSessionRevocation = $env:AZD_PIM_FIXTURE -ne 'disabled'
    }
}
function Get-AzdPimState { }
function Save-AzdPimState { }
function Get-AzdPimStatePath { 'fixture-only' }
function Set-AzdEnvironmentValue { param($Name, $Value) }
function Write-AzdPimPlanReport { }
function Get-AzdPimPortalLinks { [pscustomobject]@{ fixture = 'ordinary portal output' } }
function New-AzdPimDeploymentReceipt {
    param($Plan, $Configuration, $PortalLinks, $PlanReportPath, $AppliedReportPath, $AzureResources, $OptionalFailurePhase)
    if ($env:AZD_PIM_FIXTURE -eq 'receipt-failure') { throw 'fixture failure writing the final receipt' }
    [pscustomobject]@{ failedPhase = $OptionalFailurePhase }
}
'@ | Set-Content -LiteralPath (Join-Path $fixtureScripts 'AzdPim.Common.psm1')
    @'
function New-AzdPimPlan {
    $tier = [pscustomobject]@{ roles = @(); roleRules = @() }
    [pscustomobject]@{ tenantId = '11111111-1111-4111-8111-111111111111'; tiers = @{ privileged = $tier; lessPrivileged = $tier } }
}
function Invoke-AzdPimApply { param($Plan, $ExistingState, $Confirm, $StateChanged); [pscustomobject]@{ contexts = @(); conditionalAccessPolicies = @() } }
'@ | Set-Content -LiteralPath (Join-Path $fixtureScripts 'AzdPim.Graph.psm1')
    @'
function Get-AzdPimAzureOperatorContext { [pscustomobject]@{ tenantId = '11111111-1111-4111-8111-111111111111'; account = 'operator@example.invalid' } }
function Connect-AzdPimConfiguredGraph { Write-Host 'ordinary synthetic authentication output' }
'@ | Set-Content -LiteralPath (Join-Path $fixtureScripts 'AzdPim.Authentication.psm1')

    # Run the exact projection and initializer bodies with only synthetic external commands in scope.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'AzdPim.Optional.psm1'), [ref] $null, [ref] $null)
    $names = @('New-AzdPimWorkflowHostObservation', 'Initialize-AzdPimRevocationExtension', 'ConvertTo-AzdPimOAuthCallbackUrl')
    $functions = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names
    }, $false))
    $functions.Count | Should -Be $names.Count
    $fake = @'
$script:callbackReads = 0
function Invoke-AzdPimAzRest {
    param($Method, $Uri)
    $script:callbackReads++
    if ($script:callbackReads -ne 1 -or $Method -cne 'POST' -or $Uri -cne "https://management.azure.com$env:AZD_PIM_REVOCATION_LOGIC_APP_RESOURCE_ID/triggers/manual/listCallbackUrl?api-version=2019-05-01") {
        throw 'unexpected synthetic callback request'
    }
    $hostName = if ($env:AZD_PIM_FIXTURE -eq 'invalid-host') { '127.0.0.1' } else { 'Example.Logic.Azure.COM' }
    [pscustomobject]@{ value = "https://${hostName}:443/workflows/fixture?api-version=2016-10-01&sig=fixture-signature" }
}
function Resolve-AzdPimExtensionApplication {
    param($DisplayName, $EndpointHost, $State, $PersistState)
    [pscustomobject]@{ objectId = '33333333-3333-4333-8333-333333333333'; clientId = '44444444-4444-4444-8444-444444444444'; identifierUri = "api://$EndpointHost/fixture" }
}
function Enable-AzdPimRevocationWorkflowOAuth { }
function Grant-AzdPimGraphApplicationPermission { }
function Set-AzdPimRevocationCustomExtension { param($DisplayName, $TargetUrl, $ResourceId, $Type, $State, $PersistState); $Type }
function Enable-AzdPimRevocationExtensionForRoles {
    if ($script:callbackReads -ne 1) { throw 'exactly one existing callback observation required' }
    if ($env:AZD_PIM_FIXTURE -eq 'role-failure') { throw 'synthetic role linking failure' }
    Write-Host 'ordinary synthetic role linking output'
}
'@
    ($fake + "`n" + (($functions | ForEach-Object { $_.Extent.Text }) -join "`n")) |
        Set-Content -LiteralPath (Join-Path $fixtureScripts 'AzdPim.Optional.psm1')

    function Invoke-SyntheticPostProvision([string] $Scenario, [switch] $Ordinary) {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = [Environment]::ProcessPath
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.WorkingDirectory = $fixtureRoot
        $start.Environment['PSModulePath'] = $fixtureModules
        $start.Environment['PATH'] = $fixtureRoot
        $start.Environment['AZD_PIM_FIXTURE'] = $Scenario
        $entryPoint = if ($Ordinary) { 'Post-Provision.ps1' } else { 'Post-Provision.Native.ps1' }
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $fixtureScripts $entryPoint))) {
            $start.ArgumentList.Add($argument)
        }
        $child = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(20000)) { $child.Kill($true); throw 'Synthetic child timed out.' }
            [pscustomobject]@{ ExitCode = $child.ExitCode; Output = $stdout.GetAwaiter().GetResult(); Error = $stderr.GetAwaiter().GetResult() }
        } finally {
            $child.Dispose()
        }
    }
}

Describe 'Native workflow hostname observation' {
    It 'emits exactly the canonical pair after the existing enforced hook succeeds' {
        $result = Invoke-SyntheticPostProvision 'success'
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        $result.Output.TrimEnd() | Should -BeExactly '{"workflowResourceId":"/subscriptions/22222222-2222-4222-8222-222222222222/resourcegroups/rg-fixture/providers/microsoft.logic/workflows/pim-revoke-sessions-example","hostname":"example.logic.azure.com"}'
        Get-Content -Raw (Join-Path $fixtureRoot 'reports/azd-pim-applied.json') |
            Should -Not -Match 'workflowHostObservation|workflowResourceId|fixture-signature'
    }

    It 'emits no pair for <Scenario> and preserves the terminal outcome' -ForEach @(
        @{ Scenario = 'role-failure'; ExitCode = 1 }
        @{ Scenario = 'receipt-failure'; ExitCode = 1 }
        @{ Scenario = 'plan'; ExitCode = 0 }
        @{ Scenario = 'disabled'; ExitCode = 0 }
        @{ Scenario = 'invalid-host'; ExitCode = 0 }
    ) {
        $result = Invoke-SyntheticPostProvision $Scenario
        $result.ExitCode | Should -Be $ExitCode
        $result.Output | Should -BeNullOrEmpty
        if ($Scenario -eq 'role-failure') {
            $receipt = Get-Content -Raw (Join-Path $fixtureRoot 'reports/azd-pim-deployment.json') | ConvertFrom-Json
            $receipt.failedPhase | Should -Be 'sessionRevocation'
            $applied = Get-Content -Raw (Join-Path $fixtureRoot 'reports/azd-pim-applied.json') | ConvertFrom-Json
            $applied.deploymentStatus | Should -Be 'partial'
            $applied.optionalWorkflows.PSObject.Properties.Name | Should -Not -Contain 'sessionRevocation'
        }
        if ($ExitCode -ne 0) {
            $result.Error.TrimEnd() | Should -BeExactly 'The azd-pim post-provision stage failed.'
        }
    }

    It 'retains ordinary output when the existing hook is called directly' {
        $result = Invoke-SyntheticPostProvision 'success' -Ordinary
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $result.Output | Should -Match 'ordinary synthetic role linking output'
        $result.Output | Should -Not -Match '"workflowResourceId"'
    }
}
