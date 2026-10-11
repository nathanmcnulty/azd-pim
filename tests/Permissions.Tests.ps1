BeforeAll { $script:permissionRoot = Split-Path -Parent $PSScriptRoot }
Describe 'Partial optional poller permission evidence' {
    It 'keeps all requirements default-disabled with current byte hashes and explicit gaps' {
        $manifest = Get-Content (Join-Path $script:permissionRoot 'azd-permissions.json') -Raw | ConvertFrom-Json
        $manifest.coverage | Should -Be 'partial'
        @($manifest.gaps).Count | Should -BeGreaterThan 0
        @($manifest.requirements).Count | Should -Be 3
        foreach ($requirement in $manifest.requirements) {
            $requirement.defaultEnabled | Should -BeFalse
            $requirement.feature | Should -Be 'polling-notifications'
            foreach ($evidence in $requirement.evidence) {
                (Get-FileHash -LiteralPath (Join-Path $script:permissionRoot $evidence.path)).Hash.ToLowerInvariant() | Should -BeExactly $evidence.sha256
            }
        }
    }
}
