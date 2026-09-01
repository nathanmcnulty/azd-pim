Describe 'Flex scheduled-poller component provenance' {
    BeforeAll {
        $script:templateRoot = Split-Path -Parent $PSScriptRoot
        $script:lock = Get-Content -LiteralPath (Join-Path $script:templateRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
        $script:component = @($script:lock.components | Where-Object id -eq 'flex-scheduled-poller-host')
    }

    It 'pins the reviewed release and exact vendored bytes' {
        $script:component.Count | Should -Be 1
        $script:component[0].version | Should -Be '0.1.0'
        $script:component[0].sourceRepository | Should -Be 'https://github.com/nathanmcnulty/azd-reference'
        $script:component[0].sourceRevision | Should -Be 'a79ed9ab9ae2ec10ff3d3c50a011d878c9524592'
        @($script:component[0].files.target) | Should -Be @(
            'infra/vendor/Azd.FlexScheduledPoller/flex-scheduled-poller-host.bicep'
        )

        foreach ($file in @($script:component[0].files)) {
            $target = Join-Path $script:templateRoot $file.target
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -Be $file.sha256
        }
    }

    It 'moves the package to generic storage settings after the compatibility deployment' {
        $source = Get-Content -LiteralPath (Join-Path $script:templateRoot 'src/pim-notification-poller/src/index.js') -Raw

        $source | Should -Match 'AZD_POLLER_STORAGE_ACCOUNT_NAME'
        $source | Should -Match 'AZD_POLLER_STATE_CONTAINER'
        $source | Should -Not -Match 'AZD_PIM_(?:STORAGE_ACCOUNT_NAME|STATE_CONTAINER)'
    }
}
