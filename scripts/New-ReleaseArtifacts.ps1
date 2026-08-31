[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:(?:0|[1-9]\d*)|(?:\d*[A-Za-z-][0-9A-Za-z-]*))(?:\.(?:(?:0|[1-9]\d*)|(?:\d*[A-Za-z-][0-9A-Za-z-]*)))*)?$')]
    [string] $Version,

    [Parameter()]
    [string] $Commit = 'HEAD',

    [Parameter()]
    [string] $OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$archivePrefix = "azd-pim-$Version/"
$sourceArchiveName = "azd-pim-$Version-source.zip"
$deploymentArchiveName = "azd-pim-$Version-deployment.zip"
$checksumsName = 'SHA256SUMS'

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = & git -C $repositoryRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return @($output)
}

$resolvedCommitOutput = @(Invoke-Git -Arguments @('rev-parse', '--verify', "$Commit^{commit}"))
$resolvedCommit = ([string] $resolvedCommitOutput[0]).Trim()
if ($resolvedCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Unable to resolve '$Commit' to a full commit identifier."
}

New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null

$sourceArchivePath = Join-Path $resolvedOutputDirectory $sourceArchiveName
$deploymentArchivePath = Join-Path $resolvedOutputDirectory $deploymentArchiveName
$checksumsPath = Join-Path $resolvedOutputDirectory $checksumsName

foreach ($path in @($sourceArchivePath, $deploymentArchivePath, $checksumsPath)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

[void] (Invoke-Git -Arguments @(
    'archive',
    '--format=zip',
    '-0',
    "--prefix=$archivePrefix",
    "--output=$sourceArchivePath",
    $resolvedCommit
))

$deploymentPaths = @(
    '.azd',
    'contracts',
    'docs',
    'infra',
    'scripts',
    'src',
    'azd-components.lock.json',
    'azd-gui.json',
    'azure.yaml',
    'LICENSE',
    'README.md',
    'SECURITY.md'
)
$deploymentArchiveArguments = @(
    'archive',
    '--format=zip',
    '-0',
    "--prefix=$archivePrefix",
    "--output=$deploymentArchivePath",
    $resolvedCommit,
    '--'
) + $deploymentPaths
[void] (Invoke-Git -Arguments $deploymentArchiveArguments)

$checksumLines = foreach ($path in @($deploymentArchivePath, $sourceArchivePath) | Sort-Object) {
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($path))"
}
[System.IO.File]::WriteAllText(
    $checksumsPath,
    (($checksumLines -join "`n") + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    Version = $Version
    Commit = $resolvedCommit
    SourceArchive = $sourceArchivePath
    DeploymentArchive = $deploymentArchivePath
    Checksums = $checksumsPath
}
