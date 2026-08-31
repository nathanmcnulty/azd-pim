BeforeAll {
    $script:templateRoot = Split-Path -Parent $PSScriptRoot
    $script:sentinelModulePath = Join-Path $script:templateRoot 'infra/modules/sentinel-notifications.bicep'
    $script:lockPath = Join-Path $script:templateRoot 'azd-components.lock.json'
}

Describe 'Azure Monitor notification component provenance' {
    It 'pins the reviewed pilot tag and verifies every managed vendor file hash' {
        $lock = Get-Content -LiteralPath $script:lockPath -Raw | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'azure-monitor-scheduled-query-notifications')

        $component.Count | Should -Be 1
        $component[0].version | Should -Be '0.1.0'
        $component[0].sourceRepository | Should -Be 'https://github.com/nathanmcnulty/azd-reference'
        $component[0].sourceRevision | Should -Be '3424613b6b1ba38a1af60c2ab9bea9ef973c5bed'
        @($component[0].files).Count | Should -Be 2

        foreach ($file in @($component[0].files)) {
            $targetPath = Join-Path $script:templateRoot $file.target
            (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant() |
                Should -Be $file.sha256
        }
    }
}

Describe 'PIM Azure Monitor notification boundary' {
    It 'keeps the PIM-owned workflow and alert contract while delegating only the Azure Monitor resources' {
        $source = Get-Content -LiteralPath $script:sentinelModulePath -Raw

        $source | Should -Match "resource notificationWorkflow 'Microsoft\.Logic/workflows@2019-05-01'"
        $source | Should -Not -Match "resource actionGroup 'Microsoft\.Insights/actionGroups"
        $source | Should -Not -Match "resource activationAlert 'Microsoft\.Insights/scheduledQueryRules"
        $source | Should -Match "module actionGroup '../vendor/Azd\.AzureMonitorNotifications/logic-app-action-group\.bicep'"
        $source | Should -Match "module activationAlert '../vendor/Azd\.AzureMonitorNotifications/scheduled-query-alert\.bicep'"
        $source | Should -Match 'actionGroupName: actionGroupName'
        $source | Should -Match "groupShortName: 'PIM Entra'"
        $source | Should -Match 'logicAppResourceId: notificationWorkflow\.id'
        $source | Should -Match "receiverName: 'PIM activation Teams workflow'"
        $source | Should -Match 'actionGroupResourceId: actionGroup\.outputs\.actionGroupResourceId'
        $source | Should -Match 'workspaceResourceId: workspaceResourceId'
        $source | Should -Match "displayName: 'Microsoft Entra PIM activation completed'"
        $source | Should -Match ([regex]::Escape("alertDescription: 'Sends successful Microsoft Entra PIM activations from an existing Sentinel or Log Analytics workspace to Teams.'"))
        $source | Should -Match 'query: activationQuery'
        $source | Should -Match "evaluationFrequency: 'PT5M'"
        $source | Should -Match "windowSize: 'PT5M'"
        $source | Should -Match 'autoMitigate: true'
        $source | Should -Match 'tags: tags'
        $source | Should -Match 'output alertRuleResourceId string = activationAlert\.outputs\.alertRuleResourceId'
        $source | Should -Match 'output actionGroupResourceId string = actionGroup\.outputs\.actionGroupResourceId'
    }

    It 'preserves the PIM activation query and all four exact alert dimensions' {
        $source = Get-Content -LiteralPath $script:sentinelModulePath -Raw

        foreach ($requiredQueryLine in @(
            'AuditLogs',
            '| where LoggedByService == "PIM"',
            '| where Category == "RoleManagement"',
            '| where OperationName == "Add member to role completed (PIM activation)"',
            '| where Result =~ "success"',
            '| project TimeGenerated, ActivationEventId, CorrelationId = tostring(CorrelationId), Actor, Role, ResultReason'
        )) {
            $source | Should -Match ([regex]::Escape($requiredQueryLine))
        }

        $dimensionMatch = [regex]::Match($source, '(?s)dimensions:\s*\[(?<content>.*?)\n\s*\]\n\s*tags: tags')
        $dimensionMatch.Success | Should -BeTrue
        $actualDimensions = @([regex]::Matches($dimensionMatch.Groups['content'].Value, "name: '(?<name>[^']+)'")) |
            ForEach-Object { $_.Groups['name'].Value }

        $actualDimensions | Should -Be @('ActivationEventId', 'CorrelationId', 'Actor', 'Role')
        @([regex]::Matches($dimensionMatch.Groups['content'].Value, "operator: 'Include'")).Count | Should -Be 4
        @([regex]::Matches($dimensionMatch.Groups['content'].Value, [regex]::Escape("'*'"))).Count | Should -Be 4
    }
}
