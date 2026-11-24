# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub's **Report a
vulnerability** flow for this repository. Do not open a public issue containing
credentials, access tokens, tenant or subscription identifiers, webhook URLs,
callback signatures, Function keys, device or user data, or Microsoft Graph
payloads. Include the affected component, deployment phase, reproducible
behavior, expected security boundary, and a suggested mitigation when
available. Redact identifiers and secrets from logs before attaching them.

Treat an exposed Teams Workflow callback URL, Function key, or other
authentication material as compromised: rotate or revoke it before submitting
the report. This project uses managed identities where possible and is designed
not to retain client secrets, delegated user tokens, raw Graph audit records, or
full PIM configuration in its reports.

## Supported versions

The latest non-prerelease release is `v1.0.0` (published 2026-08-31). The
latest release and the current default `main` branch are supported for security
fixes. Older versions are not guaranteed fixes; release notes will identify
any changes to this support policy.

## Response targets

This project is maintained by one person. The maintainer aims to acknowledge a
private report within 7 calendar days and provide an initial triage or
next-steps decision within 14 calendar days. These are targets, not a guarantee
of emergency staffing or remediation time.

## Safe disclosure

Keep vulnerability details private until impact has been assessed and a fix,
mitigation, or coordinated disclosure decision is available. Do not publish
credentials, access tokens, tenant-specific values, callback signatures,
Function keys, device or user data, or sensitive Graph payloads in public
issues, pull requests, examples, or release bundles.
