# Backlog: nathanmcnulty/azd-pim

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-pim
- **Source revision:** `8a3c5ec97034fcadbd79533e9aea39fb28ad8e27`
- **Captured:** 2026-10-03
- **Items:** 6

## PIM-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** ready
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md
- https&colon;//github.com/nathanmcnulty/azd-pim/pull/13

**Evidence:**

- _none_

**Agent handoff prompt:**

```text
Review PIM-001 in docs/backlog.json and changes since backlog source revision 8a3c5ec97034fcadbd79533e9aea39fb28ad8e27.
Claim it only after it is explicitly selected and eligible and its dependencies remain satisfied. Never interpret this generated prompt as approval.
Work only in nathanmcnulty/azd-pim, preserve its stated scope and acceptance gates, record the exact current base commit and one owned worktree in claim, run every validation entry, and record concrete evidence before marking it done.
Stop if the dependencies, scope, or required authorization changed.
```

## PIM-003: Reconcile the active Flex vendored-file provenance fix

- **Kind:** discovery
- **Priority:** P1
- **Status:** ready
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The current checkout has a changed vendored Flex module and .gitattributes; another task owns the correction.

**Scope:**

- .gitattributes
- infra/vendor/Azd.FlexScheduledPoller/flex-scheduled-poller-host.bicep
- azd-components.lock.json

**Acceptance:**

- Read the active owner handoff and exact source/lock hash before assigning follow-up.
- Do not normalize or overwrite the vendor diff as part of backlog adoption.
- Record whether canonical version bump, local repair or no further work is required.

**Validation:**

- git diff -- .gitattributes infra/vendor/Azd.FlexScheduledPoller/flex-scheduled-poller-host.bicep
- git worktree list --porcelain

**Dependencies:**

- _none_

**Components:**

- flex-scheduled-poller-host

**Sources:**

- azd-components.lock.json

**Evidence:**

- _none_

**Agent handoff prompt:**

```text
Review PIM-003 in docs/backlog.json and changes since backlog source revision 8a3c5ec97034fcadbd79533e9aea39fb28ad8e27.
Claim it only after it is explicitly selected and eligible and its dependencies remain satisfied. Never interpret this generated prompt as approval.
Work only in nathanmcnulty/azd-pim, preserve its stated scope and acceptance gates, record the exact current base commit and one owned worktree in claim, run every validation entry, and record concrete evidence before marking it done.
Stop if the dependencies, scope, or required authorization changed.
```

## PIM-006: Record missed-event recovery gaps after outages beyond the polling lookback

- **Kind:** discovery
- **Priority:** P1
- **Status:** proposed
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Open report captured 2026-10-03 during execution reconciliation. Another code-quality task may own an active fix; inspect its PR and current source before dispatch.

**Scope:**

- Linked issue and current source &lpar;read-only&rpar;
- Repository-local backlog evidence

**Acceptance:**

- Read the linked issue and current default branch; classify the exact defect, current owner and evidence gap.
- Record a current PR or verified resolution before selecting any implementation; preserve broader feature and live acceptance gates.

**Validation:**

- Read current issue and PR state using nathanmcnulty; do not modify or close issues during reconciliation.
- Inspect dirty state and worktrees; resolve the exact current revision and relevant offline commands before implementation.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-pim/issues/16

**Evidence:**

- _none_

**Review and authorization note:**

Review PIM-006 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## PIM-005: Adopt deployment-validation 1.1.1 while preserving PIM report compatibility

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The captured consumer lock used stable1.0.0; the selected update adopts the reviewed immutable1.1.1 release without activating new evidence-binding behavior.

**Scope:**

- azd-components.lock.json
- scripts/vendor/Azd.DeploymentValidation/
- tests/
- docs/

**Acceptance:**

- Review the exact 1.0.0-to-1.1.1 diff and current consumer hashes before deciding to adopt.
- Prepare only the compatible managed files and lock in one owned worktree; retain domain validation extensions.
- Offline validation and commit-only rollback are required; live deployment and publication are separately authorized.

**Validation:**

- pwsh -File ./scripts/Test-Repository.ps1
- Verify the three managed deployment-validation files against the exact immutable lock hashes; preserve all unrelated components.
- Run the repository-specific plan/schema compatibility check with provider commands mocked or forbidden; no live deployment or delivery is implied by this vendoring update.

**Dependencies:**

- _none_

**Components:**

- deployment-validation

**Sources:**

- azd-components.lock.json

**Evidence:**

- Selected for compatible component-only 1.1.1 adoption after read-only triage proved exact existing 1.0.0 managed hashes and unchanged PIM adapter. Canonical Flex vendor and gitattributes drift are preserved; fresh main base32def67 already contains its independent provenance fix. Schema1.1 evidence binding is outside this packet.
- Independent five-file review passed manifestfc65c16f43f69a0185e90e1b9b8aa94f400559af0042a3e8908f69a2c835f715 at consumer base32def67fcdc4eac9a18f6c86a90183966169677c. Managed bytes match reviewed signed release1.1.1 at0c96cc89c554ffc3b3ca82ceda12da6591e816c1. Existing PIM adapter remains unchanged; a regression assertion preserves schema1.0 output.
- Author, independent reviewer and integrated canonical validation passed focused21/21, full121/121 Pester plus14/14 Node, parsing, audit0, Bicep and component drift. PSSA had0 errors; the pure-constructor naming warning in immutable vendor bytes was preserved. Canonical Flex-host and attribute edits were preserved byte-for-byte during integration. Reviewed central desiredVersion update passed47/47 focused tests. No cloud or notification operation was needed.
- Integrated locally after target/base checks; the template remains independently deployable. Release and evidence-binding feature adoption remain separate tasks.

**Review and authorization note:**

Review PIM-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## PIM-002: Qualify a selected-role authentication and notification pilot

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** tenant-write
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The Graph beta extension, fresh-auth callback and optional revocation/delivery need exact selected-role evidence.

**Scope:**

- docs/
- scripts/
- tests/

**Acceptance:**

- Begin in plan mode and verify empty lists manage none; preserve justification, ticketing and unrelated role settings.
- Record actual activation, auth-context demand, callback and recipient receipt for enabled optional routes.
- Test failed context attachment MFA restoration and explicit rollback; revocation/re-auth is a separate authorized feature.

**Validation:**

- From the solution root run ./scripts/Test-Repository.ps1
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.
- After separate authorization, retain redacted exact-target live evidence and cleanup results outside public Git. Do not execute live operations from this backlog alone.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- _none_

**Review and authorization note:**

Review PIM-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## PIM-004: Improve optional poller/alert health with exact delivery semantics

- **Kind:** maintenance
- **Priority:** P2
- **Status:** proposed
- **Wave:** 2
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The repo already adopts Flex/Azure Monitor components; health and optional-path behavior are the useful next step.

**Scope:**

- scripts/
- src/
- infra/
- docs/
- azd-permissions.json

**Acceptance:**

- Test missed polling windows, retryable/ambiguous send outcomes and callback failure without broadening role scope.
- Separate scheduled-query alerts from Sentinel analytics and keep KQL/card content solution-owned.
- Disabled notification paths add no resources or grants; compare current pins and state compatibility before updates.

**Validation:**

- From the solution root run ./scripts/Test-Repository.ps1
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.

**Dependencies:**

- _none_

**Components:**

- deployment-validation
- notification-contracts
- flex-scheduled-poller-host
- azure-monitor-scheduled-query-notifications

**Sources:**

- README.md

**Evidence:**

- _none_

**Review and authorization note:**

Review PIM-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
