# Deployment validation

`scripts/Test-Deployment.ps1` is the solution's structured, read-only deployment verifier. It uses the pinned `deployment-validation` component from `azd-reference` and writes a schema-valid report to `reports/deployment-validation.json` by default.

```powershell
./scripts/Test-Deployment.ps1 -Plan
./scripts/Test-Deployment.ps1
./scripts/Test-Deployment.ps1 -TestDelivery
./scripts/Test-Deployment.ps1 -OutputPath ./reports/pim-validation.json -PassThru
```

## Modes

- `-Plan` lists every check and dependency without loading the azd environment, inspecting cached authentication, calling Azure or Microsoft Graph, making HTTP requests, or delivering a message.
- The default mode reuses the existing Azure CLI and Microsoft Graph sessions. It never starts authentication. It rebuilds the PIM plan with Graph reads and verifies the configured tenant, subscription, role classification, role scope, authentication contexts, Conditional Access policies, PIM role rules, and optional Azure resources.
- `-TestDelivery` performs the same read-only checks and, when notifications are enabled, sends one clearly labeled synthetic card to the configured Teams Workflow webhook. This proves the destination, not the Sentinel alert or polling path. A real PIM activation remains the end-to-end notification proof.

If a cached session is missing or belongs to another tenant, use the normal operating-system broker or browser sign-in and rerun the command. Device-code flow is not used.

`AZURE_SUBSCRIPTION_ID` is required. When a normal azd environment does not contain `AZURE_TENANT_ID`, validation derives the tenant from that configured subscription only after Azure CLI proves the same subscription and tenant are active. The derived value exists only in the validation process; it is not written back to the azd environment.

## Plan and enforced configurations

The template's `AZD_PIM_MODE` and the validation command mode are separate:

- When the solution configuration is `plan`, validation reports proposed context, Conditional Access, and selected-role changes as information. It never applies them.
- When the solution configuration is `enforced`, any remaining planned action is drift and fails validation with a stable failure code.

Both privileged and less-privileged tiers are validated independently. `selected` supports an empty list as manage-none, while `all` is resolved from Graph's current `isPrivileged` classification. The validator never detaches a role removed from the current selection, restores old PIM settings, or deletes an authentication context.

Plan and validation reports never contain the Teams Workflow webhook URL. They record only whether a webhook is configured, and report writing fails closed if an unsafe configuration object reaches the serialization boundary.

Session revocation cannot be safely tested with a synthetic callback because a valid test would revoke a real administrator's sessions and the OAuth-protected endpoint is intended for the PIM service. Prove it by activating one pilot role and correlating the PIM request with the Logic App run.
