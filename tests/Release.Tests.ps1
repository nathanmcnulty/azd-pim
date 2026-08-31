BeforeAll {
    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:releaseScript = Join-Path $script:repositoryRoot 'scripts/New-ReleaseArtifacts.ps1'
}

Describe 'Release artifacts' {
    It 'builds byte-identical archives for the same commit and version' {
        $firstDirectory = Join-Path $TestDrive 'first'
        $secondDirectory = Join-Path $TestDrive 'second'

        $first = & $script:releaseScript -Version 'v1.2.3-rc.1' -OutputDirectory $firstDirectory
        $second = & $script:releaseScript -Version 'v1.2.3-rc.1' -OutputDirectory $secondDirectory

        (Get-FileHash -LiteralPath $first.SourceArchive -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $second.SourceArchive -Algorithm SHA256).Hash
        (Get-FileHash -LiteralPath $first.DeploymentArchive -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $second.DeploymentArchive -Algorithm SHA256).Hash
        Get-Content -LiteralPath $first.Checksums -Raw |
            Should -Be (Get-Content -LiteralPath $second.Checksums -Raw)
    }

    It 'keeps repository-only files out of the deployment archive' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $outputDirectory = Join-Path $TestDrive 'contents'
        $result = & $script:releaseScript -Version 'v1.2.3' -OutputDirectory $outputDirectory
        $archive = [System.IO.Compression.ZipFile]::OpenRead($result.DeploymentArchive)
        try {
            $entries = @($archive.Entries.FullName)
            $entries | Should -Contain 'azd-pim-v1.2.3/azure.yaml'
            $entries | Should -Contain 'azd-pim-v1.2.3/infra/main.bicep'
            $entries | Should -Contain 'azd-pim-v1.2.3/LICENSE'
            @($entries | Where-Object { $_ -like 'azd-pim-v1.2.3/.github/*' }).Count | Should -Be 0
            @($entries | Where-Object { $_ -like 'azd-pim-v1.2.3/tests/*' }).Count | Should -Be 0
        }
        finally {
            $archive.Dispose()
        }
    }

    It 'requires a semantic release version' {
        { & $script:releaseScript -Version 'latest' -OutputDirectory (Join-Path $TestDrive 'invalid') } |
            Should -Throw
        { & $script:releaseScript -Version 'v01.2.3' -OutputDirectory (Join-Path $TestDrive 'leading-zero') } |
            Should -Throw
        { & $script:releaseScript -Version 'v1.2.3-01' -OutputDirectory (Join-Path $TestDrive 'numeric-prerelease') } |
            Should -Throw
    }

    It 'keeps release publication behind protected main and the release environment' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repositoryRoot '.github/workflows/release.yml') -Raw

        $workflow | Should -Match '(?m)^  workflow_dispatch:'
        $workflow | Should -Not -Match '(?m)^\s+tags:'
        $workflow | Should -Match '(?m)^    environment: release$'
        $workflow | Should -Match 'persist-credentials: false'
        $workflow | Should -Match 'npm ci --ignore-scripts'
        $workflow | Should -Not -Match '\$\{\{ github\.ref_name \}\}'
        $workflow | Should -Match "GITHUB_REF -cne 'refs/heads/main'"
        $workflow | Should -Match '--prerelease.*--latest=false'
    }

    It 'documents constrained provenance verification' {
        $releaseGuide = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'docs/releasing.md') -Raw

        foreach ($requiredArgument in @(
            '--repo nathanmcnulty/azd-pim',
            '--signer-workflow nathanmcnulty/azd-pim/.github/workflows/release.yml',
            '--source-ref refs/heads/main',
            '--source-digest',
            '--signer-digest',
            '--deny-self-hosted-runners'
        )) {
            $releaseGuide | Should -Match ([regex]::Escape($requiredArgument))
        }
    }
}
