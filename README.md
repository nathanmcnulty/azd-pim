# azd-pim

`azd-pim` is an Azure Developer CLI solution for requiring fresh authentication when an eligible Microsoft Entra role is activated through Privileged Identity Management (PIM).

The core deployment discovers the tenant's current role definitions, uses Microsoft Graph's `isPrivileged` classification, creates separate authentication contexts for privileged and less-privileged roles, creates Conditional Access policies for those contexts, and attaches the appropriate context to each selected PIM role setting.

> [!IMPORTANT]
> This repository is under active development. Start in `plan` mode and use a selected-role pilot. Optional notification and session-revocation components deploy only when explicitly selected in `enforced` mode.

## Core behavior

- Discovers role definitions from Microsoft Graph beta and treats `isPrivileged` as authoritative. Role names are never hardcoded.
- Supports `selected` and `all` scope independently for privileged and less-privileged roles.
- Treats an empty selected-role list as **manage none**, never as all.
- Finds unused authentication context IDs from `c1` through `c25` instead of assuming fixed IDs.
- Avoids context slots referenced by existing Conditional Access policies or PIM role rules.
- Creates one primary Conditional Access policy per non-empty tier:
  - Users: All users.
  - Exclusion: Optional existing emergency-access group.
  - Target resource: The tier's authentication context.
  - Grant: MFA or a selected authentication strength.
  - Session: Sign-in frequency, every time.
- Optionally adds device grant policies and a privileged-role exact device allowlist policy.
- Updates only the `AuthenticationContext_EndUser_Assignment` PIM rule for each selected role.
- When a selected role still enables the legacy `MultiFactorAuthentication` activation rule, removes only that value from `Enablement_EndUser_Assignment` because Graph does not allow it to coexist with an authentication context. Justification, ticketing, and other activation requirements are preserved; a failed context attachment immediately attempts to restore MFA.
- Treats PIM authentication-context assignment as forward configuration. Narrowing a later role selection does not detach contexts or restore earlier role settings.

An authentication-context Conditional Access policy does not target every ordinary sign-in to every cloud app. The context is the target resource, and PIM requests that context during activation. This is what produces fresh authentication at elevation time without repeatedly prompting users while they use an already-active role.

## Safety model

The default mode is `plan`. It performs Microsoft Graph reads and writes `reports/azd-pim-plan.json`; it does not change Microsoft Entra.

`enforced` mode:

1. Rebuilds and validates the plan against the current tenant.
2. Requires a separate acknowledgement for each tier whose scope is `all`, after displaying the live role count in that tier.
3. Requires the tenant ID to be typed unless `AZD_PIM_CONFIRM_ENFORCED=true` is set explicitly.
4. Creates or updates authentication contexts.
5. Creates or updates enabled Conditional Access policies while they are inert because no selected PIM role requests the new contexts yet.
6. Attaches the contexts to selected role activation rules.
7. Writes tenant-bound ownership state under `.azure/<environment>/azd-pim-state.json` without retaining prior PIM role-rule bodies. Checkpoints are written before and after each durable mutation. A server-assigned Conditional Access create is reconciled only when one live policy exactly matches its recorded intent; a pending role-rule intent is cleared only after an exact live re-plan proves the desired context is already attached.

Matching pre-existing contexts or policies cause a conflict unless `AZD_PIM_ADOPT_EXISTING=true`. A role that already uses a different context causes a separate conflict unless `AZD_PIM_ADOPT_ROLE_CONTEXTS=true`.

The solution does not create, modify, or require an emergency-access group. When `AZD_PIM_EMERGENCY_ACCESS_GROUP_ID` is supplied, it verifies that the group is security-enabled, reports its direct member count, and excludes it from the solution's Conditional Access policies. Omitting it is supported but produces a recommendation warning.

Deployment validation follows the shared portfolio convention in [`docs/deployment-validation.md`](docs/deployment-validation.md). `Test-Deployment.ps1 -Plan` is fully offline, the default mode reuses cached sessions for read-only drift checks, and `-TestDelivery` is the only mode that may send a clearly labeled Teams test. Validation never initiates authentication, restores removed role settings, detaches roles that leave the current selection, or deletes authentication contexts.

For repository changes, run `./scripts/Test-Repository.ps1`. It parses the PowerShell source, runs the offline Pester and Node suites, restores Node dependencies from the local npm cache, and compiles the root Bicep template to stdout without connecting to a tenant.

Release preparation and verification are documented in [`docs/releasing.md`](docs/releasing.md). Release automation packages only commits already merged to `main`; it does not authenticate to or modify Azure or Microsoft Graph.

Tenant cleanup is opt-in. By default, `azd down` preserves Microsoft Entra configuration. Even with `AZD_PIM_REMOVE_TENANT_CONFIGURATION=true`, PIM role rules, authentication contexts, the session-revocation application registration and service principal, custom extensions, Graph permissions, and custom-extension role links are preserved. The cleanup path is limited to solution-created Conditional Access policies and restoration of adopted Conditional Access policies. This avoids silently weakening role activation after a role is removed from the template's current scope. Review the durable state and remove optional Entra resources manually only when their references have been deliberately detached.

## Start with a pilot

```powershell
azd auth login
az login --tenant <tenant-id>
azd init

azd env set AZD_PIM_MODE plan
azd env set AZD_PIM_PRIVILEGED_ROLE_SCOPE selected
azd env set AZD_PIM_PRIVILEGED_ROLE_IDS '<role-definition-guid>'
azd env set AZD_PIM_LESS_PRIVILEGED_ROLE_SCOPE selected
azd env set AZD_PIM_LESS_PRIVILEGED_ROLE_IDS ''

azd up
```

Review `reports/azd-pim-plan.json`. To apply the same scope:

```powershell
azd env set AZD_PIM_MODE enforced
azd up
```

Use role **definition IDs**, not assignment IDs or display names. Until azd-gui supports trusted tenant-backed option providers, `scripts/Status.ps1` and the plan report provide the live role inventory needed to choose IDs. The GUI design is tracked in [azd-gui issue #41](https://github.com/nathanmcnulty/azd-gui/issues/41).

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `AZD_PIM_MODE` | `plan` | `plan` or `enforced`; report-only CA is intentionally not used. |
| `AZD_PIM_PRIVILEGED_ROLE_SCOPE` | `selected` | `selected` or every role where Graph returns `isPrivileged=true`. |
| `AZD_PIM_CONFIRM_ALL_PRIVILEGED_ROLES` | `false` | Explicit acknowledgement required in enforced mode when every privileged role is selected. |
| `AZD_PIM_PRIVILEGED_ROLE_IDS` | empty | JSON, semicolon, comma, or newline-delimited role definition IDs. |
| `AZD_PIM_LESS_PRIVILEGED_ROLE_SCOPE` | `selected` | `selected` or every role where Graph returns `isPrivileged=false`. |
| `AZD_PIM_CONFIRM_ALL_LESS_PRIVILEGED_ROLES` | `false` | Explicit acknowledgement required in enforced mode when every less-privileged role is selected. |
| `AZD_PIM_LESS_PRIVILEGED_ROLE_IDS` | empty | JSON, semicolon, comma, or newline-delimited role definition IDs. |
| `AZD_PIM_EMERGENCY_ACCESS_GROUP_ID` | empty | Existing security group to exclude; recommended, not required. |
| `AZD_PIM_ADOPT_EXISTING` | `false` | Allow matching pre-existing contexts and CA policies to be managed. |
| `AZD_PIM_ADOPT_ROLE_CONTEXTS` | `false` | Allow replacement of a different context already attached to a selected role. |
| `AZD_PIM_PRIVILEGED_AUTH_PROFILE` | `mfa` | `mfa`, `phishingResistant`, or `custom`. |
| `AZD_PIM_PRIVILEGED_AUTH_STRENGTH_ID` | empty | Required when the privileged profile is `custom`. |
| `AZD_PIM_LESS_PRIVILEGED_AUTH_PROFILE` | `mfa` | `mfa`, `phishingResistant`, or `custom`. |
| `AZD_PIM_LESS_PRIVILEGED_AUTH_STRENGTH_ID` | empty | Required when the less-privileged profile is `custom`. |
| `AZD_PIM_PRIVILEGED_DEVICE_REQUIREMENT` | `none` | `none`, `compliant`, `hybridJoined`, or `compliantOrHybrid`. |
| `AZD_PIM_LESS_PRIVILEGED_DEVICE_REQUIREMENT` | `none` | Same choices for the less-privileged context. |
| `AZD_PIM_PRIVILEGED_ALLOWED_DEVICE_IDS` | empty | Exact device ID allowlist implemented with a companion block policy. |
| `AZD_PIM_CONFIRM_ENFORCED` | `false` | Explicit non-interactive confirmation for enforced automation. |
| `AZD_PIM_REMOVE_TENANT_CONFIGURATION` | `false` | Opt in to Conditional Access cleanup during `azd down`; contexts and PIM rules remain. |
| `AZD_PIM_NOTIFICATION_MODE` | `none` | `none`, `sentinel`, or `polling`. |
| `AZD_PIM_TEAMS_WEBHOOK_URL` | empty | Secret Teams Workflow webhook URL used by either notification mode. |
| `AZD_PIM_SENTINEL_WORKSPACE_RESOURCE_ID` | empty | Existing workspace with Entra `AuditLogs`; required for `sentinel`. |
| `AZD_PIM_SENTINEL_WORKSPACE_LOCATION` | empty | Region of the existing workspace; required for the scheduled-query alert. |
| `AZD_PIM_POLLING_SCHEDULE` | `0 */5 * * * *` | Flex Consumption Function NCRONTAB schedule. |
| `AZD_PIM_POLLING_LOOKBACK_MINUTES` | `30` | Rolling audit window used with durable event-ID deduplication. |
| `AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK` | `false` | Send recent events on first run instead of only seeding the watermark. |
| `AZD_PIM_ENABLE_SESSION_REVOCATION` | `false` | Deploy, onboard, and link preview revocation extensions to every role in scope, selecting the safe activation phase automatically. |
| `AZD_PIM_REVOCATION_FAILURE_BEHAVIOR` | `deny` | `deny` or `approve` when revocation fails. |
| `AZD_PIM_REVOCATION_ALERT_ACTION_GROUP_RESOURCE_ID` | empty | Optional existing Azure Monitor action group for revocation workflow action failures. |

Context and policy display names are also configurable through `AZD_PIM_PRIVILEGED_CONTEXT_NAME`, `AZD_PIM_LESS_PRIVILEGED_CONTEXT_NAME`, `AZD_PIM_PRIVILEGED_CA_POLICY_NAME`, and `AZD_PIM_LESS_PRIVILEGED_CA_POLICY_NAME`.

### Device controls

`compliant` or `hybridJoined` is combined with the tier's authentication requirement using `AND`. `compliantOrHybrid` needs a companion policy because a single flat Conditional Access grant operator cannot express `MFA AND (compliant OR hybrid joined)`.

An exact device ID list creates another companion block policy. The policy excludes the allowed IDs from a block grant, so unregistered, unknown, and non-allowlisted devices are blocked when the PIM context is requested. Pilot and validate this carefully before broad rollout.

## Prerequisites and permissions

- Microsoft Entra ID P2 or Microsoft Entra ID Governance licensing for PIM and Conditional Access features used here.
- A signed-in administrator with Privileged Role Administrator for PIM role-setting writes and Conditional Access Administrator or Security Administrator for authentication contexts and Conditional Access.
- Microsoft Graph PowerShell 2.30.0 or later, connected with delegated permissions sufficient for:
  - `RoleManagementPolicy.ReadWrite.Directory`
  - `Policy.ReadWrite.ConditionalAccess`
  - `AuthenticationContext.ReadWrite.All`
  - Directory/group reads used for role discovery and the optional emergency-access group validation

Optional workflows add permissions only when enabled by the scripts:

- Polling Function managed identity: `AuditLog.Read.All` application permission.
- Polling onboarding operator: `Application.Read.All` and `AppRoleAssignment.ReadWrite.All` delegated permissions.
- Revocation Logic App managed identity: `User.RevokeSessions.All` application permission.
- Revocation onboarding operator: `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, and `PrivilegedAccess-CustomExt.ReadWrite.All` delegated permissions.

The scripts use Microsoft Graph PowerShell for every Graph request and Azure CLI only to bind the run to the selected tenant and administrator. They calculate the core scopes plus permissions for all optional features currently enabled before making one authentication call. The shared authentication component then reuses a delegated `CurrentUser` context only when its tenant, cloud, account, and scopes match and a harmless role-definition read succeeds. When authentication is actually required, Microsoft Graph PowerShell uses its secured cache, Windows broker, or the normal browser flow. It never falls back to an Azure CLI Graph token or another interactive method.

The lifecycle hooks explicitly permit replacing a mismatched inherited Graph context because the expected account and tenant come from the selected Azure CLI user context. This avoids silently continuing as a different administrator. Optional permissions are not requested merely to avoid a possible future sign-in after configuration changes, so enabling a new optional workflow can require consent once on the next run. The plan fails on missing consent or directory roles rather than falling back to a weaker configuration.

The vendored `graph-delegated-authentication` and `flex-scheduled-poller-host` components and their exact source revisions and SHA-256 hashes are recorded in `azd-components.lock.json`. Update them from `azd-reference`; do not edit managed files under `scripts/vendor` or `infra/vendor` locally.

The notification envelope and delivery-result v1 schemas are also pinned from `azd-reference`, but remain data contracts rather than a shared notification runtime. Polling normalization, safe administrator-facing route results, idempotency, and the separate Sentinel adapter boundary are documented in [`docs/notification-contracts.md`](docs/notification-contracts.md).

## Preview API boundary

The following capabilities currently require Microsoft Graph beta:

- Role classification through `roleDefinition.isPrivileged`.
- Conditional Access targeting through `includeAuthenticationContextClassReferences`.
- PIM role-activation custom extensions.

All beta calls are isolated in `scripts/AzdPim.Graph.psm1`, and the plan records the API version used. A missing `isPrivileged` value or unexpected resource shape stops deployment.

## Optional workflows

### Deployment receipt and administrator links

Every run writes `reports/azd-pim-deployment.json`. The receipt reports Azure infrastructure, Microsoft Entra configuration, and operational verification as separate stages. Plan mode records Azure resources as `notChanged` and live checks as `notRun`. If a core or optional phase fails after a durable mutation, it records a sanitized `partial` receipt before rethrowing; it identifies the failed phase but never serializes tokens, callback signatures, webhooks, or raw provider errors. Correct the indicated configuration and rerun the same environment. Do not delete state or adopt same-named Entra resources to bypass the conflict. After enforcement, optional workflows remain `pending` until an administrator proves a real PIM callback or Teams delivery; successful provisioning alone is not treated as live verification.

The applied report and console output include tenant-scoped links for PIM role activation, Conditional Access, the Azure resource group, and each deployed optional Azure resource. The receipt contains only identifiers and local report paths; it does not serialize Graph tokens, Teams webhooks, or Logic App callback signatures. The corresponding azd-gui artifact and guided-verification design is tracked in [azd-gui issue #55](https://github.com/nathanmcnulty/azd-gui/issues/55).

### Teams activation notifications

The Office 365 Management Activity API design is intentionally excluded because it subscribes to the entire `Audit.AzureActiveDirectory` content type, which can invoke a workflow for large volumes of unrelated events.

Two isolated alternatives are available:

- `sentinel`: reuses an existing Microsoft Sentinel or Log Analytics workspace, deploys a stateful scheduled-query alert dimensioned by the stable audit event ID for successful `Add member to role completed (PIM activation)` events, and sends the common alert payload through a small Consumption Logic App to a Teams Workflow webhook. Entra audit log routing is a prerequisite and is not changed by this solution.
- `polling`: deploys a single-instance Flex Consumption Function App that periodically queries Microsoft Graph directory audits. It stores recent event IDs in Blob Storage, persists each successful delivery immediately, uses a rolling lookback for delayed audit arrival, and avoids posting existing events on the first run unless explicitly requested.

Both choices are consumption-based and disabled by default. Sentinel is usually the better fit when the audit data already exists in a workspace. Polling avoids workspace ingestion requirements and should remain inexpensive in low-volume tenants, but it requires the Function managed identity to hold `AuditLog.Read.All` and has polling-interval latency. Distributed delivery cannot guarantee exactly once across a crash between the Teams response and watermark write, so every card includes the stable audit event ID and downstream handling must remain idempotent.

The polling Function uses the independently versioned `flex-scheduled-poller-host` component at 512 MB with a one-instance ceiling and no always-ready instances. PIM keeps its Graph query, watermark, Teams delivery, and notification behavior solution-owned. The Function emits safe route-level contract results for success, baseline suppression, deduplication, and failure. These results contain stable identifiers and environment metadata, but never normalized PII data, recipients, destinations, webhook credentials, rendered cards, or raw provider responses. Sentinel preserves the same event identity but remains a Common Alert Schema to Logic App adapter until a safe durable result sink exists.

### Revoke activator sessions

The component is a PIM `roleManagementCustomCalloutExtension`, not an Entitlement Management workflow extension. The template deploys the Consumption Logic App disabled, then onboarding performs these steps in order:

1. Creates a single-tenant application registration whose Application ID URI host matches the Logic App callback host, checkpoints its exact object ID and app ID, and only reuses that recorded object on rerun. A same-named application or custom extension is never adopted. Existing environment IDs are accepted only once as migration hints after exact live verification, then durable state becomes the ownership authority.
2. Configures the request trigger for OAuth only, validating the tenant issuer, the application client ID as the v2 token audience (and Application ID URI for v1 tokens), and PIM caller application `1c67c054-65c8-4f7f-92a1-eb7ba6e48627`.
3. Grants the Logic App managed identity `User.RevokeSessions.All` and enables the workflow.
4. Creates or updates two beta `roleManagementCustomCalloutExtension` objects for `entraRoles`: one `preApproval` and one `postApproval`.
5. Reads each scoped role's live approval rule. Roles without human approval use `CustomExtension_PreApproval_EndUser_Assignment`; roles requiring human approval use `CustomExtension_PostApproval_EndUser_Assignment`. The opposite rule is disabled only when it references one of this solution's extensions, while foreign extension configuration fails closed.
6. Existing custom-extension rules use isolated rule PATCHes. Policies that predate the rule use the same full-policy append contract as the Entra portal while preserving all existing rules.

The published preview documentation currently describes only pre-approval linkage. The Entra portal now exposes separate pre-approval and post-approval extension types and role-policy rules; this implementation uses the captured beta Graph contract for the post-approval rule. The deployment outputs both `AZD_PIM_REVOCATION_PRE_APPROVAL_CUSTOM_EXTENSION_ID` and `AZD_PIM_REVOCATION_POST_APPROVAL_CUSTOM_EXTENSION_ID`; the older `AZD_PIM_REVOCATION_CUSTOM_EXTENSION_ID` remains an alias for the post-approval ID.

The current beta create endpoint also requires a client-generated GUID `id`, although the preview documentation's request example omits it. The implementation supplies that GUID while retaining the documented Application ID URI in `authenticationConfiguration.resourceId`.

This PIM feature is preview. Live testing confirmed that `postApproval` does not run for roles that have no human approval requirement. The automatic phase selection therefore uses pre-approval only when there is no later human denial risk, and post-approval when approval is required. PIM can deliver the same activation request more than once when retries are enabled, so extension actions must be idempotent and notification implementations must deduplicate on the request `id`. Repeating `revokeSignInSessions` is safe, but it invalidates the activating user's refresh tokens and browser session cookies across Microsoft Entra, not only the PIM page; propagation can take several minutes. A failure response includes the PIM request ID for portal-to-workflow correlation while retaining the extension-generated evaluation ID required by PIM. When an existing action group is supplied, an Azure Monitor metric alert watches the Logic App's `ActionsFailed` metric. The default response is fail closed (`deny`) if revocation fails; fail open is an explicit option. Run a selected-role pilot first and ensure the operator can complete broader reauthentication before enabling it widely.

## References

- [Privileged roles and permissions](https://learn.microsoft.com/entra/identity/role-based-access-control/privileged-roles-permissions?tabs=ms-graph)
- [Change PIM role settings](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-how-to-change-default-settings)
- [Authentication context API](https://learn.microsoft.com/graph/api/authenticationcontextclassreference-update?view=graph-rest-1.0)
- [Update a PIM role-management policy rule](https://learn.microsoft.com/graph/api/unifiedrolemanagementpolicyrule-update?view=graph-rest-1.0)
- [PIM custom extensions](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/privileged-identity-management-custom-extensions)
- [Office 365 Management Activity API](https://learn.microsoft.com/office/office-365-management-api/office-365-management-activity-api-reference)
