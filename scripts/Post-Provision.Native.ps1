#Requires -Version 7.6
# Entry point for a separately reviewed native runner that owns this process's stdout.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$workflowHostObservation = $null
try {
    & (Join-Path $PSScriptRoot 'Post-Provision.ps1') -NativeWorkflowHostObservation ([ref] $workflowHostObservation) *> $null
    if ($null -ne $workflowHostObservation) {
        [Console]::Out.WriteLine(($workflowHostObservation | ConvertTo-Json -Compress))
    }
} catch {
    [Console]::Error.WriteLine('The azd-pim post-provision stage failed.')
    exit 1
}
