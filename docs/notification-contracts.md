# PIM notification contracts

`azd-pim` consumes the version 1 notification envelope and delivery-result contracts from `azd-reference`. The exact schema revision and SHA-256 hashes are pinned in `azd-components.lock.json`; these files are portable wire contracts, not a shared renderer, dispatcher, or infrastructure module.

## Polling normalization

The polling Function normalizes each successful PIM activation directory-audit record before routing it:

- `eventType`: `entra.pim.roleActivated`
- `source`: `microsoftGraph.directoryAudit`
- `eventId`: the stable directory-audit event ID
- `correlationId`: the Graph correlation ID, falling back to `eventId`
- `severity`: `high`
- `environment`: azd environment name, tenant ID, subscription ID, and resource group
- `data`: bounded actor, role, and result-reason values needed by the PIM Teams card

The envelope is operational data and can contain administrator PII. It remains inside the Function's normalization and transport path and is never logged wholesale. The Teams renderer remains solution-owned, and the `teams.workflowWebhook` adapter continues to authorize by possession of its protected webhook URL.

## Route results

Each evaluated polling route produces one version 1 result with logical route `admin-primary`, audience `admin`, and transport `teams.workflowWebhook`. The Function logs it with the `AZD_NOTIFICATION_DELIVERY_RESULT` prefix and also returns it to the Functions host for testability. Timer execution does not depend on the return value.

The idempotency key is lowercase SHA-256 over UTF-8 text:

```text
tenantId + "\n" + eventType + "\n" + eventId + "\n" + route.id
```

Results use these states:

- `succeeded` after the Teams Workflow endpoint accepts the card;
- `alreadyDelivered` when the stable event ID is already in the watermark;
- `skipped` with `initialBaseline` when the first run intentionally watermarks existing events; and
- `failed` with a closed category, retry decision, safe code, and optional HTTP status.

The result never contains envelope `data`, administrator names, recipient or destination identifiers, webhook URLs, authorization headers, tokens, rendered cards, provider bodies, or raw exceptions. Provider and transport failures are converted to safe codes before logging or throwing. A Teams success followed by a watermark-write failure can still be delivered again; the stable event ID and route idempotency key make that at-least-once boundary visible.

## Sentinel boundary

Sentinel mode observes the same Graph directory-audit operation and already carries stable `ActivationEventId` and `CorrelationId` dimensions. It therefore maps conceptually to the same `entra.pim.roleActivated` event and `teams.workflowWebhook` transport.

Its actual adapter boundary is different: Azure Monitor sends the Common Alert Schema to a Consumption Logic App, which renders and posts the Teams card. The current workflow has no access-controlled durable sink for administrator-facing route results, so it does not manufacture a polling-style result or log the alert payload as an envelope. A real activation, alert instance, Logic App run, and Teams delivery remain the Sentinel end-to-end proof. A future Sentinel result adapter should adopt the same schemas only when it has a safe result sink and can calculate the canonical key from the individual activation event.
