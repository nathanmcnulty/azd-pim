# Releasing azd-pim

Releases are immutable snapshots of commits already merged to `main`. A manual workflow dispatch from protected `main` validates the commit, builds deterministic source and deployment ZIP archives, generates an SPDX JSON software bill of materials for the Node.js polling Function, writes SHA-256 checksums, and passes the validated candidate to a separate publisher. The publisher is gated by the protected `release` GitHub Environment, creates and verifies an annotated tag for the exact validated commit, creates GitHub build-provenance attestations, and publishes the files in a GitHub Release.

The deployment archive contains the azd template, scripts, infrastructure, contracts, documentation, and optional Function source. It excludes repository-only workflow and test files. The source archive contains every file tracked in the tagged commit. Rebuilding either archive from the same commit and version produces the same bytes.

## Release checklist

1. Confirm the intended commit is merged to `main` and all required hosted checks succeeded.
2. Run `./scripts/Test-Repository.ps1` locally without tenant access.
3. Review user-visible changes, deployment safety, component lock versions, and `SECURITY.md` support language.
4. Choose a semantic version. Use a prerelease suffix until the documented live validation boundary has been completed. Prerelease versions are published with GitHub's prerelease flag and never selected as the latest release.
5. Build and inspect the candidate artifacts locally:

   ```powershell
   ./scripts/New-ReleaseArtifacts.ps1 -Version v1.0.0-rc.1
   ```

6. In GitHub Actions, select **Release azd-pim**, choose the protected `main` branch, and enter the reviewed version. Approve the `release` Environment only after confirming the run identifies the intended commit and version.
7. Verify the release artifacts, checksums, SBOM, provenance, and exact annotated tag before announcing the release.

The workflow rejects non-`main` dispatches and malformed versions. Its build job has read-only repository access and disables checkout credential persistence. Only the environment-gated publisher receives tag, attestation, and release permissions. It never signs in to Azure or Microsoft Graph and never reads or modifies a tenant. Commercial-lab validation remains a separate, explicitly authorized activity.

Consumers can verify downloaded files with `Get-FileHash -Algorithm SHA256` and compare the result with `SHA256SUMS`. GitHub CLI users should also constrain provenance verification to this repository, workflow, protected source ref, and the release commit digest:

```powershell
gh attestation verify <artifact> `
  --repo nathanmcnulty/azd-pim `
  --signer-workflow nathanmcnulty/azd-pim/.github/workflows/release.yml `
  --source-ref refs/heads/main `
  --source-digest <40-character-release-commit-sha> `
  --signer-digest <40-character-release-commit-sha> `
  --deny-self-hosted-runners
```
