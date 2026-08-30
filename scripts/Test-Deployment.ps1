[CmdletBinding()]
param(
    [Alias('PlanOnly')]
    [switch] $Plan,

    [switch] $TestDelivery,

    [string] $OutputPath = 'reports/deployment-validation.json',

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Plan -and $TestDelivery) {
    throw '-Plan and -TestDelivery are mutually exclusive.'
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$enginePath = Join-Path $PSScriptRoot 'vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1'
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    throw 'The deployment-validation component is missing. Synchronize it from azd-reference before validation.'
}

Import-Module $enginePath -Force
Import-Module (Join-Path $PSScriptRoot 'Deployment.Validation.psm1') -Force

$startedAt = [datetimeoffset]::UtcNow
$mode = if ($Plan) { 'plan' } elseif ($TestDelivery) { 'delivery' } else { 'verify' }
$definitions = @(Get-ProjectValidationDefinition)
$checks = @(Invoke-AzdValidationSet -Definitions $definitions -Plan:$Plan -AllowSyntheticDelivery:$TestDelivery)
$report = New-AzdValidationReport `
    -TemplateName 'azd-pim' `
    -TemplateVersion '0.1.0' `
    -Mode $mode `
    -StartedAt $startedAt `
    -Checks $checks `
    -Environment @{
        name = [string] $env:AZURE_ENV_NAME
        tenantId = [string] $env:AZURE_TENANT_ID
        subscriptionId = [string] $env:AZURE_SUBSCRIPTION_ID
        resourceGroup = [string] $env:AZURE_RESOURCE_GROUP
    } `
    -Requirements @{
        tools = @('az', 'azd')
        modules = @('Microsoft.Graph.Authentication >= 2.30.0')
        permissions = @('Azure resource read access', 'Microsoft Graph delegated read access for the configured PIM scope')
    } `
    -NextSteps @(
        'Use selected-role scope for the first enforced pilot and review every reported role count before broadening to all.',
        'After enforcement, activate one role from each managed tier to prove fresh authentication and any configured custom extension.',
        'Use -TestDelivery only when a clearly labeled Teams destination test is acceptable.'
    )

$writtenPath = Write-AzdValidationReport -Report $report -OutputPath $OutputPath -RepositoryRoot $repositoryRoot
Write-AzdValidationSummary -Report $report
Write-Host "Validation report: $writtenPath"
if ($PassThru) { $report }
Assert-AzdValidationSucceeded -Report $report
