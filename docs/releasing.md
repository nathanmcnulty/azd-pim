# Releasing azd-pim

Releases are immutable snapshots of commits already merged to `main`. The release workflow validates the tagged commit, builds deterministic source and deployment ZIP archives, generates an SPDX JSON software bill of materials for the Node.js polling Function, writes SHA-256 checksums, creates GitHub build-provenance attestations, and publishes the files in a GitHub Release.

The deployment archive contains the azd template, scripts, infrastructure, contracts, documentation, and optional Function source. It excludes repository-only workflow and test files. The source archive contains every file tracked in the tagged commit. Rebuilding either archive from the same commit and version produces the same bytes.

## Release checklist

1. Confirm the intended commit is merged to `main` and all required hosted checks succeeded.
2. Run `./scripts/Test-Repository.ps1` locally without tenant access.
3. Review user-visible changes, deployment safety, component lock versions, and `SECURITY.md` support language.
4. Choose a semantic version. Use a prerelease suffix until the documented live validation boundary has been completed.
5. Build and inspect the candidate artifacts locally:

   ```powershell
   ./scripts/New-ReleaseArtifacts.ps1 -Version v1.0.0-rc.1
   ```

6. Create and push an annotated tag for the exact reviewed commit:

   ```powershell
   git tag -a v1.0.0-rc.1 -m "azd-pim v1.0.0-rc.1"
   git push origin v1.0.0-rc.1
   ```

7. Verify the release workflow, artifact checksums, SBOM, and attestations before announcing the release.

The workflow rejects malformed tags and tags whose commits are not reachable from `origin/main`. It never signs in to Azure or Microsoft Graph and never reads or modifies a tenant. Commercial-lab validation remains a separate, explicitly authorized activity; a release tag cannot trigger it.

Consumers can verify downloaded files with `Get-FileHash -Algorithm SHA256` and compare the result with `SHA256SUMS`. GitHub CLI users can additionally verify provenance with `gh attestation verify <artifact> --repo nathanmcnulty/azd-pim`.
