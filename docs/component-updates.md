# Shared component updates

[azd-components.lock.json](../azd-components.lock.json) records the shared
component versions, exact source revisions, and SHA-256 hashes for azd-pim's
managed files. Use the lock from the same revision as the files you are
reviewing.

The [Reference portfolio update guide](https://github.com/nathanmcnulty/azd-reference/blob/d7f62370da76c2da3bc76e19f6925782c286bec4/docs/portfolio-updates.md#automated-draft-update-pull-requests)
describes how Reference prepares draft pull requests for the versions approved
for the `azd-pim` registry entry. Use the guide and the draft diff to review a
proposed update in GitHub.

1. Compare the old and proposed versions and source revisions in the lock.
   Check the publisher's release notes for breaking changes between the two
   versions.
2. Review the managed paths and hashes alongside the proposed file changes.
   Review any changes to solution-owned files separately.
3. Keep local edits in place while reviewing the draft. Record missing or
   locally modified managed files for follow-up before adopting the update.

The review can be completed in GitHub without Azure or tenant access.
