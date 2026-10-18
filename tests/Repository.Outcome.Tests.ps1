BeforeAll {
    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:pwsh = (Get-Process -Id $PID).Path
}

Describe 'Shared repository validator outcome boundary' {
    It 'requires a real passing suite before later commands: <Case>' -ForEach @(
        @{ Case = 'pass'; Accepted = $true; Calls = 5 },
        @{ Case = 'inconclusive'; Accepted = $false; Calls = 0 }
    ) {
        $fixtureRoot = Join-Path $TestDrive $Case
        & $script:pwsh -NoProfile -File (Join-Path $PSScriptRoot 'helpers/Invoke-RepositoryOutcomeFixture.ps1') `
            -RepositoryRoot $script:repositoryRoot -FixtureRoot $fixtureRoot -Case $Case | Out-Null
        $LASTEXITCODE | Should -Be 0
        $receipt = Get-Content -LiteralPath (Join-Path $fixtureRoot 'receipt.json') -Raw | ConvertFrom-Json
        $receipt.fixtureRan | Should -BeTrue
        $receipt.pester | Should -Be '6.2.0'
        $receipt.succeeded | Should -Be $Accepted
        @($receipt.nativeCalls).Count | Should -Be $Calls
        if (-not $Accepted) {
            $receipt.failure | Should -Be 'Every registered Pester test must pass without skipped, inconclusive or unexecuted cases.'
        }
    }
}
