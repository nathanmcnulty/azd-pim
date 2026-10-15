BeforeAll {
    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Supported PowerShell and Pester baseline' {
    It 'requires PowerShell 7.6 at every owned script and module entry point' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:repositoryRoot 'scripts') -File |
            Where-Object Extension -In '.ps1', '.psm1')
        $files.Count | Should -BeGreaterThan 0
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
            $errors.Count | Should -Be 0
            $ast.ScriptRequirements.RequiredPSVersion | Should -Be ([version] '7.6')
        }
    }

    It 'qualifies and records Pester 6.2.0 in validation and release builds' {
        foreach ($name in 'validate.yml', 'release.yml') {
            $workflow = Get-Content -LiteralPath (Join-Path $script:repositoryRoot ".github/workflows/$name") -Raw
            $workflow | Should -Match 'Install-Module Pester -RequiredVersion 6\.2\.0 -Force -Scope CurrentUser'
            $workflow | Should -Match 'Import-Module Pester -RequiredVersion 6\.2\.0 -Force -ErrorAction Stop'
            $workflow | Should -Match 'Get-Module Pester'
            $workflow | Should -Match 'run: ./scripts/Test-Repository\.ps1 -PesterVersion 6\.2\.0'
            $workflow | Should -Match "PSVersionTable\.PSVersion -ne \[version\]'7\.6\.6'"
            $workflow | Should -Not -Match 'Pester[^\r\n]*5\.7'
        }
    }

    It 'requires Pester 6.2 or later and records local selected versions' {
        $runner = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $runner | Should -Match 'Import-Module Pester -MinimumVersion 6\.2\.0 -Force -ErrorAction Stop'
        $runner | Should -Match 'Import-Module Pester -RequiredVersion \$PesterVersion -Force -ErrorAction Stop'
        $runner | Should -Match 'PSVersionTable\.PSVersion'
        $runner | Should -Match 'Get-Module Pester'
    }

    It 'rejects a requested Pester version below the supported floor before running validation' {
        { & (Join-Path $script:repositoryRoot 'scripts/Test-Repository.ps1') -PesterVersion 5.7.1 } | Should -Throw '*PesterVersion*'
    }

    It 'locks canonical PowerShell 7.6 modules with matching versions and file hashes' {
        $lock = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
        foreach ($id in 'deployment-validation', 'graph-delegated-authentication') {
            $components = @($lock.components | Where-Object id -EQ $id)
            $components.Count | Should -Be 1
            $component = $components[0]
            $component.sourceRepository | Should -Be 'https://github.com/nathanmcnulty/azd-reference'
            $component.sourceRevision | Should -Match '^[0-9a-f]{40}$'
            foreach ($file in $component.files) {
                $path = Join-Path $script:repositoryRoot $file.target
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $file.sha256
                if ($file.target -like '*.psd1') {
                    $manifest = Import-PowerShellDataFile -LiteralPath $path
                    [version] $manifest.PowerShellVersion | Should -Be ([version] '7.6')
                    $manifest.ModuleVersion | Should -Be $component.version
                }
            }
        }
    }
}
