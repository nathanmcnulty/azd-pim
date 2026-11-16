#Requires -Version 7.6
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $FixtureRoot,
    [Parameter(Mandatory)][ValidateSet('pass', 'inconclusive')][string] $Case
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path (Join-Path $FixtureRoot 'scripts'), (Join-Path $FixtureRoot 'tests') | Out-Null
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/Test-Repository.ps1') -Destination (Join-Path $FixtureRoot 'scripts/Test-Repository.ps1')
$env:PIM_OUTCOME_MARKER = Join-Path $FixtureRoot 'executed.txt'
$statement = if ($Case -eq 'pass') { '1 | Should -Be 1' } else { "Set-ItResult -Inconclusive -Because 'Controlled fixture'" }
$fixture = 'Describe ''Controlled suite'' { It ''executes'' { [IO.File]::WriteAllText($env:PIM_OUTCOME_MARKER, ''executed''); ' + $statement + ' } }'
Set-Content -LiteralPath (Join-Path $FixtureRoot 'tests/Fixture.Tests.ps1') -Value $fixture

# Only dependency loading is stubbed; the maintained runner invokes real Pester.
function Import-Module {
    param($Name, $RequiredVersion, $MinimumVersion, [switch] $Force, $ErrorAction)
    if ($Name -eq 'Microsoft.Graph.Authentication') { return }
    Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
}
$global:pimFixtureNativeCalls = [Collections.Generic.List[string]]::new()
$pollerRoot = Join-Path $FixtureRoot 'src/pim-notification-poller'
$global:pimFixtureAllowedCalls = @(
    "npm ci --offline --ignore-scripts --prefix $pollerRoot",
    "node --check $(Join-Path $pollerRoot 'src/index.js')",
    "npm test --offline --prefix $pollerRoot",
    'az bicep version',
    "az bicep build --file $(Join-Path $FixtureRoot 'infra/main.bicep') --stdout"
)
function Invoke-FixtureNative {
    param([string] $Tool, [object[]] $Arguments)
    $command = "$Tool $($Arguments -join ' ')"
    if ($command -notin $global:pimFixtureAllowedCalls) { throw "Forbidden fixture command: $command" }
    $global:pimFixtureNativeCalls.Add($command)
    $global:LASTEXITCODE = 0
}
function npm { Invoke-FixtureNative -Tool npm -Arguments $args }
function node { Invoke-FixtureNative -Tool node -Arguments $args }
function az { Invoke-FixtureNative -Tool az -Arguments $args }

$succeeded = $false
$failure = $null
try {
    & (Join-Path $FixtureRoot 'scripts/Test-Repository.ps1') -PesterVersion 6.2.0
    $succeeded = $true
}
catch { $failure = $_.Exception.Message }
[ordered]@{
    succeeded = $succeeded
    fixtureRan = Test-Path -LiteralPath $env:PIM_OUTCOME_MARKER
    nativeCalls = @($global:pimFixtureNativeCalls)
    failure = $failure
    pester = (Get-Module Pester).Version.ToString()
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'receipt.json')
