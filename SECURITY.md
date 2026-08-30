# Security policy

Report vulnerabilities privately through GitHub's **Report a vulnerability** flow for this repository. Do not open a public issue containing credentials, access tokens, tenant or subscription identifiers, webhook URLs, callback signatures, Function keys, device or user data, or Microsoft Graph payloads.

Include the affected component, deployment phase, reproducible behavior, expected security boundary, and suggested mitigation when available. Redact identifiers and secrets from logs before attaching them.

Treat an exposed Teams Workflow callback URL, Function key, or other authentication material as compromised: rotate or revoke it before submitting the report. This project uses managed identities where possible and is designed not to retain client secrets, delegated user tokens, raw Graph audit records, or full PIM configuration in its reports.

Only the current default branch is maintained until releases identify supported versions and security-fix policy.
