[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$templateRoot = Split-Path -Parent $PSScriptRoot
$pollerRoot = Join-Path $templateRoot 'src/pim-notification-poller'

function Assert-NativeSucceeded {
    param(
        [Parameter(Mandatory)] [string] $Tool,
        [Parameter(Mandatory)] [scriptblock] $Action
    )

    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool failed with exit code $LASTEXITCODE."
    }
}

Write-Host 'Parsing repository PowerShell files.'
$parseErrors = [System.Collections.Generic.List[object]]::new()
$powerShellFiles = @(
    Get-ChildItem -LiteralPath $templateRoot -Recurse -File |
        Where-Object {
            $_.Extension -in '.ps1', '.psm1', '.psd1' -and
            $_.FullName -notmatch '[\\/](?:\.azure|node_modules|reports)[\\/]'
        }
)
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $fileErrors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref] $tokens,
        [ref] $fileErrors
    )
    foreach ($parseError in @($fileErrors)) {
        $parseErrors.Add($parseError)
    }
}
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Format-List | Out-String)
}

Write-Host 'Running repository Pester tests without tenant access.'
Import-Module Pester -MinimumVersion 5.7.1 -Force -ErrorAction Stop
Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force -ErrorAction Stop
$pesterResult = Invoke-Pester -Path (Join-Path $templateRoot 'tests') -Output Detailed -PassThru
if ($pesterResult.FailedCount -gt 0) {
    throw "$($pesterResult.FailedCount) Pester test(s) failed."
}

Write-Host 'Checking and testing the polling Function with local Node dependencies.'
Assert-NativeSucceeded -Tool 'npm ci --offline' -Action {
    & npm ci --offline --ignore-scripts --prefix $pollerRoot
}
Assert-NativeSucceeded -Tool 'node --check' -Action {
    & node --check (Join-Path $pollerRoot 'src/index.js')
}
Assert-NativeSucceeded -Tool 'npm test' -Action {
    & npm test --offline --prefix $pollerRoot
}

Write-Host 'Building the root Bicep template to stdout.'
Assert-NativeSucceeded -Tool 'az bicep version' -Action {
    & az bicep version
}
Assert-NativeSucceeded -Tool 'az bicep build' -Action {
    & az bicep build --file (Join-Path $templateRoot 'infra/main.bicep') --stdout | Out-Null
}

Write-Host 'Repository validation passed.'
