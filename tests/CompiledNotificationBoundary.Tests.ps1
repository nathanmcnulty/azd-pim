BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $json = & az bicep build --file (Join-Path $script:root 'infra/main.bicep') --stdout
    if ($LASTEXITCODE -ne 0) { throw 'Actual root compilation failed.' }
    $script:compiled = ($json -join "`n") | ConvertFrom-Json -Depth 100
    function Get-NestedResourceTypes($Template) {
        foreach ($resource in $Template.resources) {
            $resource.type
            if ($resource.type -eq 'Microsoft.Resources/deployments') {
                Get-NestedResourceTypes $resource.properties.template
            }
        }
    }
}

Describe 'Compiled optional notification resource and grant gates' {
    It 'binds the finite gate evaluator to the actual compiled expressions and defaults' {
        $script:compiled.parameters.pimMode.defaultValue | Should -Be 'plan'
        $script:compiled.parameters.notificationMode.defaultValue | Should -Be 'none'
        $script:compiled.parameters.enableSessionRevocation.defaultValue | Should -BeFalse
        $script:compiled.variables.deployOptionalResources | Should -Be "[equals(parameters('pimMode'), 'enforced')]"
        $script:compiled.variables.deployPollingNotifications | Should -Be "[and(variables('deployOptionalResources'), equals(parameters('notificationMode'), 'polling'))]"
        $script:compiled.variables.deploySentinelNotifications | Should -Be "[and(variables('deployOptionalResources'), equals(parameters('notificationMode'), 'sentinel'))]"
        $script:compiled.variables.deploySessionRevocation | Should -Be "[and(variables('deployOptionalResources'), parameters('enableSessionRevocation'))]"
        @($script:compiled.resources).Count | Should -Be 3
        $script:compiled.resources.name | Should -Be @('sentinel-notifications', 'polling-notifications', 'session-revocation')
        $script:compiled.resources.condition | Should -Be @("[variables('deploySentinelNotifications')]", "[variables('deployPollingNotifications')]", "[variables('deploySessionRevocation')]")
    }

    It 'deploys only the selected gated module for <Mode>/<Route>, with revocation disabled' -ForEach @(
        @{ Mode = 'plan'; Route = 'none'; Expected = @() }
        @{ Mode = 'plan'; Route = 'polling'; Expected = @() }
        @{ Mode = 'plan'; Route = 'sentinel'; Expected = @() }
        @{ Mode = 'enforced'; Route = 'none'; Expected = @() }
        @{ Mode = 'enforced'; Route = 'polling'; Expected = @('polling-notifications') }
        @{ Mode = 'enforced'; Route = 'sentinel'; Expected = @('sentinel-notifications') }
    ) {
        # This deliberately supports only the exact finite expressions checked above.
        # Unknown compiled conditions fail closed; no ARM service is queried.
        $gates = @{
            "[variables('deployPollingNotifications')]" = ($Mode -eq 'enforced' -and $Route -eq 'polling')
            "[variables('deploySentinelNotifications')]" = ($Mode -eq 'enforced' -and $Route -eq 'sentinel')
            "[variables('deploySessionRevocation')]" = $false
        }
        $selected = @($script:compiled.resources | Where-Object {
            if (-not $gates.ContainsKey($_.condition)) { throw 'Unknown compiled resource gate.' }
            $gates[$_.condition]
        })
        @($selected | ForEach-Object { $_.name }) | Should -Be $Expected
        $types = @($selected | ForEach-Object { Get-NestedResourceTypes $_.properties.template })
        if ($Expected.Count -eq 0) {
            $types.Count | Should -Be 0 # Includes all nested roleAssignments as well as resources.
        } elseif ($Route -eq 'polling') {
            $types | Should -Contain 'Microsoft.Authorization/roleAssignments'
        } else {
            $types | Should -Contain 'Microsoft.Insights/scheduledQueryRules'
            $types | Should -Not -Contain 'Microsoft.SecurityInsights/alertRules'
            $types | Should -Not -Contain 'Microsoft.Authorization/roleAssignments'
        }
    }
}
