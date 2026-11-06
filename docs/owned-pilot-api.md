# Owned selected-role pilot host API

`New-AzdPimOwnedPlan` and `Invoke-AzdPimOwnedApply` expose the existing core planner and apply engine to a host that owns its Graph credential in the same process. They do not authenticate, approve execution, load shared SDK sessions, or implement a second deployment engine. The independent CLI hooks retain their existing behavior.

The host supplies a context with `TenantId` and `RequestPimJson(method, uri, bodyJson)`. The method returns response JSON; successful empty write responses should return JSON `null`. The planner accepts only `plan` mode, selected roles in each tier, no notifications, and no session revocation. Apply requires an enforced, tenant-matching plan with the same scope restrictions. An empty selected tier remains empty.

The host must:

- Validate the exact tenant, principal, client, resource and granted scopes at sign-in and on every request. Permit only registered core read endpoints and narrowly authorized write methods, object IDs and bodies; reject redirects and unregistered pagination. Never fall back to an ambient SDK session or expose a credential/token through this API.
- Keep the reviewed plan and ownership state native/process-owned. Bind approval to the project, environment, tenant, principal, source revision, complete configuration, object IDs, current properties, proposed bodies and durable state. A display-name match or a cached report is evidence to review, never authorization to adopt.
- Require explicit approval, then re-read and compare live state before applying. Consume approval on use, change, cancellation, error or restart. The wrapper itself is not an approval mechanism.
- Pass the existing durable state into both planning and application. Persist every `StateChanged` checkpoint atomically before permitting the next request. A checkpoint failure must prevent its write. Preserve pending intents, original ownership and failed-attempt receipts.
- Serialize mutation workers for the same tenant/environment, revoke cancellation promptly, and treat a lost response or interrupted checkpoint as uncertain. Do not retry an uncertain POST or infer failure from the absence of a response. Re-read and reconcile before presenting a new reviewed resume plan.
- Distinguish applied operations from read-back verification. A successful apply response does not prove activation behavior. Offer a read-only recheck and guide the administrator through eligible-role activation, fresh authentication, preserved justification/ticketing, device controls where selected, and audit review.

The module clears its process-owned context in `finally`, including after errors. The existing engine still owns write ordering, pre/post checkpoints, pending-intent recovery and legacy activation-MFA removal/restoration. A host must retain enough valid transport capability for the engine's restoration attempt after a known rejected attachment write; identity changes and uncertain writes require conservative recovery guidance.

## Pending Conditional Access create recovery

A server-assigned policy ID may be lost after a successful POST. Recovery requires one unique same-name live policy whose entire writable body matches the recorded pending-create body. The pending body must also match the current desired configuration. `Test-AzdPimPendingPolicyMatches` is separate from the ordinary managed-property drift comparator: extra user/group/application targeting, locations, risk conditions, grants and session settings cannot silently establish ownership.

Only explicitly enumerated response metadata and null/empty defaults shown in the [Microsoft Graph policy response example](https://learn.microsoft.com/en-us/graph/api/conditionalaccesspolicy-get?view=graph-rest-beta) are tolerated. The authentication-strength reference compares its ID; enumerated expanded descriptive response fields are metadata. Unknown fields, even null or empty, fail closed. This is intentionally conservative: reordered arrays, single-grant operator normalization, newly introduced Graph defaults and other response normalization may require manual review instead of automatic recovery. The comparator does not claim to prove which actor created an otherwise identical policy; the host must show its exact tenant, ID and properties for the administrator's fresh review before any further changes.
