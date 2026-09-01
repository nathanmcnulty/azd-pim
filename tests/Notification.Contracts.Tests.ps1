BeforeAll {
    $script:templateRoot = Split-Path -Parent $PSScriptRoot
    $script:envelopeSchema = Join-Path $script:templateRoot 'contracts/notifications/notification-envelope.schema.json'
    $script:resultSchema = Join-Path $script:templateRoot 'contracts/notifications/notification-delivery-result.schema.json'
}

Describe 'notification contract provenance' {
    It 'matches the lock version to both vendored schemas and verifies every recorded file hash' {
        $lock = Get-Content -LiteralPath (Join-Path $script:templateRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'notification-contracts')

        $component.Count | Should -Be 1
        $componentVersion = [version] $component[0].version
        $component[0].sourceRevision | Should -Match '^[0-9a-f]{40}$'
        foreach ($file in @($component[0].files)) {
            $targetPath = Join-Path $script:templateRoot $file.target
            $schema = Get-Content -LiteralPath $targetPath -Raw | ConvertFrom-Json
            $schemaVersion = [version] $schema.properties.schemaVersion.const

            $schemaVersion.Major | Should -Be $componentVersion.Major
            $schemaVersion.Minor | Should -Be $componentVersion.Minor
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
            $actualHash | Should -Be $file.sha256
        }
    }
}

Describe 'PIM notification contract registration' {
    It 'provides the Function with canonical environment metadata settings' {
        $template = Get-Content -LiteralPath (Join-Path $script:templateRoot 'infra/modules/polling-function.bicep') -Raw

        foreach ($name in 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP') {
            $template | Should -Match ([regex]::Escape("${name}:"))
        }
        $template | Should -Match 'AZURE_TENANT_ID: tenant\(\)\.tenantId'
        $template | Should -Match 'AZURE_SUBSCRIPTION_ID: subscription\(\)\.subscriptionId'
        $template | Should -Match 'AZURE_RESOURCE_GROUP: resourceGroup\(\)\.name'
        $hostTemplate = Get-Content -LiteralPath (Join-Path $script:templateRoot 'infra/vendor/Azd.FlexScheduledPoller/flex-scheduled-poller-host.bicep') -Raw
        $hostTemplate | Should -Match "name: 'AZURE_ENV_NAME'"
    }

    It 'adopts the right-sized reusable poller host without replacing durable state' {
        $template = Get-Content -LiteralPath (Join-Path $script:templateRoot 'infra/modules/polling-function.bicep') -Raw
        $hostTemplate = Get-Content -LiteralPath (Join-Path $script:templateRoot 'infra/vendor/Azd.FlexScheduledPoller/flex-scheduled-poller-host.bicep') -Raw

        $template | Should -Match "module pollerHost '../vendor/Azd\.FlexScheduledPoller/flex-scheduled-poller-host\.bicep'"
        $template | Should -Match "stateContainerName: 'pim-state'"
        $template | Should -Match "deploymentContainerName: 'function-releases'"
        $template | Should -Match 'blobDeleteRetentionDays: 7'
        $template | Should -Match 'instanceMemoryMB: 512'
        $template | Should -Match 'maximumInstanceCount: 1'
        $template | Should -Match "'AZD_PIM_STORAGE_ACCOUNT_NAME'"
        $template | Should -Match "'AZD_PIM_STATE_CONTAINER'"
        $template | Should -Not -Match "resource\s+\w+\s+'Microsoft\.(?:Web|Storage|Authorization)/"
        $hostTemplate | Should -Match 'alwaysReady: \[\]'
    }

    It 'accepts the Graph directory-audit activation envelope' {
        $envelope = [ordered]@{
            schemaVersion = '1.0'
            eventId = 'event-42'
            eventType = 'entra.pim.roleActivated'
            source = 'microsoftGraph.directoryAudit'
            occurredAt = '2026-08-23T20:00:00Z'
            severity = 'high'
            correlationId = 'correlation-42'
            isTest = $false
            environment = [ordered]@{
                name = 'dev'
                tenantId = '11111111-1111-4111-8111-111111111111'
                subscriptionId = '22222222-2222-4222-8222-222222222222'
                resourceGroup = 'rg-pim-dev'
            }
            data = [ordered]@{
                actor = 'admin@example.test'
                role = 'AI Reader'
                resultReason = 'Completed successfully'
            }
        }

        ($envelope | ConvertTo-Json -Depth 10 |
            Test-Json -SchemaFile $script:envelopeSchema -ErrorAction Stop) | Should -BeTrue
    }

    It 'accepts one safe Teams Workflow route result' {
        $result = [ordered]@{
            schemaVersion = '1.0'
            eventId = 'event-42'
            eventType = 'entra.pim.roleActivated'
            correlationId = 'correlation-42'
            idempotencyKey = '959a7297c0a6959906bcae516f1179312cb439d30923699f6c1c3cf08351ea37'
            route = [ordered]@{
                id = 'admin-primary'
                audience = 'admin'
                transport = 'teams.workflowWebhook'
            }
            status = 'succeeded'
            attempt = 1
            recordedAt = '2026-08-23T20:00:03Z'
            isTest = $false
            environment = [ordered]@{
                name = 'dev'
                tenantId = '11111111-1111-4111-8111-111111111111'
                subscriptionId = '22222222-2222-4222-8222-222222222222'
                resourceGroup = 'rg-pim-dev'
            }
            evidence = [ordered]@{ httpStatusCode = 202 }
        }

        ($result | ConvertTo-Json -Depth 10 |
            Test-Json -SchemaFile $script:resultSchema -ErrorAction Stop) | Should -BeTrue
    }

    It 'rejects rendered content, destinations, recipients, and raw provider errors in a route result' -ForEach @(
        @{ Name = 'card'; Value = @{ type = 'AdaptiveCard' } },
        @{ Name = 'destination'; Value = 'https://example.invalid/workflows/callback?sig=secret' },
        @{ Name = 'recipient'; Value = 'admin@example.test' },
        @{ Name = 'rawError'; Value = 'provider response body' }
    ) {
        $result = [ordered]@{
            schemaVersion = '1.0'
            eventId = 'event-42'
            eventType = 'entra.pim.roleActivated'
            correlationId = 'correlation-42'
            idempotencyKey = '959a7297c0a6959906bcae516f1179312cb439d30923699f6c1c3cf08351ea37'
            route = @{ id = 'admin-primary'; audience = 'admin'; transport = 'teams.workflowWebhook' }
            status = 'succeeded'
            attempt = 1
            recordedAt = '2026-08-23T20:00:03Z'
            isTest = $false
            environment = @{ name = 'dev'; tenantId = '11111111-1111-4111-8111-111111111111' }
            evidence = @{}
        }
        $result[$Name] = $Value

        { $result | ConvertTo-Json -Depth 10 |
            Test-Json -SchemaFile $script:resultSchema -ErrorAction Stop } | Should -Throw
    }
}
