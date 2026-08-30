import { app } from '@azure/functions';
import { createHash } from 'node:crypto';

const graphResource = 'https://graph.microsoft.com';
const storageResource = 'https://storage.azure.com/';
const graphBase = 'https://graph.microsoft.com/v1.0';
const activationOperation = 'Add member to role completed (PIM activation)';
const activationEventType = 'entra.pim.roleActivated';
const activationSource = 'microsoftGraph.directoryAudit';
const teamsRoute = Object.freeze({
  id: 'admin-primary',
  audience: 'admin',
  transport: 'teams.workflowWebhook',
});

function requiredSetting(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Required application setting ${name} is missing.`);
  }
  return value;
}

function optionalSetting(name) {
  return process.env[name]?.trim() || null;
}

async function safeFetch(url, init, failureMessage) {
  try {
    return await fetch(url, init);
  } catch {
    throw new Error(failureMessage);
  }
}

async function getManagedIdentityToken(resource) {
  const endpoint = requiredSetting('IDENTITY_ENDPOINT');
  const identityHeader = requiredSetting('IDENTITY_HEADER');
  const url = new URL(endpoint);
  url.searchParams.set('api-version', '2019-08-01');
  url.searchParams.set('resource', resource);
  const response = await safeFetch(
    url,
    { headers: { 'X-IDENTITY-HEADER': identityHeader } },
    'Managed identity token request failed because the identity endpoint was unavailable.',
  );
  if (!response.ok) {
    throw new Error(`Managed identity token request failed (HTTP ${response.status}).`);
  }
  let tokenResponse;
  try {
    tokenResponse = await response.json();
  } catch {
    throw new Error('Managed identity token response was invalid.');
  }
  if (!tokenResponse?.access_token) {
    throw new Error('Managed identity token response did not contain an access token.');
  }
  return tokenResponse.access_token;
}

function stateBlobUrl() {
  const account = requiredSetting('AZD_PIM_STORAGE_ACCOUNT_NAME');
  const container = requiredSetting('AZD_PIM_STATE_CONTAINER');
  return `https://${account}.blob.core.windows.net/${container}/pim-notification-watermark.json`;
}

async function readState(token) {
  const response = await safeFetch(
    stateBlobUrl(),
    {
      headers: {
        Authorization: `Bearer ${token}`,
        'x-ms-version': '2023-11-03',
      },
    },
    'Unable to read the polling watermark because Blob Storage was unavailable.',
  );
  if (response.status === 404) {
    return { exists: false, etag: null, value: { recent: [] } };
  }
  if (!response.ok) {
    throw new Error(`Unable to read polling watermark (HTTP ${response.status}).`);
  }
  let value;
  try {
    value = await response.json();
  } catch {
    throw new Error('The polling watermark response was invalid.');
  }
  return {
    exists: true,
    etag: response.headers.get('etag'),
    value,
  };
}

async function writeState(token, state, etag) {
  const headers = {
    Authorization: `Bearer ${token}`,
    'x-ms-version': '2023-11-03',
    'x-ms-blob-type': 'BlockBlob',
    'Content-Type': 'application/json',
  };
  if (etag) {
    headers['If-Match'] = etag;
  } else {
    headers['If-None-Match'] = '*';
  }
  const response = await safeFetch(
    stateBlobUrl(),
    {
      method: 'PUT',
      headers,
      body: JSON.stringify(state),
    },
    'Unable to update the polling watermark because Blob Storage was unavailable.',
  );
  if (!response.ok) {
    throw new Error(`Unable to update polling watermark (HTTP ${response.status}).`);
  }
  return response.headers.get('etag');
}

async function getDirectoryAudits(token, since) {
  const filter = `activityDateTime ge ${since.toISOString()}`;
  let url = `${graphBase}/auditLogs/directoryAudits?$filter=${encodeURIComponent(filter)}&$top=100`;
  const events = [];
  while (url) {
    const response = await safeFetch(
      url,
      { headers: { Authorization: `Bearer ${token}` } },
      'Microsoft Graph directory audit query failed because the provider was unavailable.',
    );
    if (!response.ok) {
      throw new Error(`Microsoft Graph directory audit query failed (HTTP ${response.status}).`);
    }
    let page;
    try {
      page = await response.json();
    } catch {
      throw new Error('Microsoft Graph returned an invalid directory audit response.');
    }
    if (!Array.isArray(page.value)) {
      throw new Error('Microsoft Graph returned an invalid directory audit collection.');
    }
    events.push(...page.value);
    const nextLink = page['@odata.nextLink'] ?? null;
    if (nextLink && !String(nextLink).startsWith(`${graphBase}/`)) {
      throw new Error('Microsoft Graph returned an invalid directory audit continuation link.');
    }
    url = nextLink;
  }
  return events
    .filter((event) =>
      event
      && typeof event === 'object'
      && event.loggedByService === 'PIM'
      && event.category === 'RoleManagement'
      && event.activityDisplayName === activationOperation
      && String(event.result ?? '').toLowerCase() === 'success')
    .sort((left, right) => String(left.activityDateTime).localeCompare(String(right.activityDateTime)));
}

function safeOpaqueIdentifier(value) {
  const identifier = String(value ?? '');
  if (!/^[A-Za-z0-9][A-Za-z0-9._:|-]{0,255}$/.test(identifier)) {
    throw new Error('A PIM activation contained an invalid opaque identifier.');
  }
  return identifier;
}

function normalizedText(value, fallback, maximumLength) {
  const normalized = String(value ?? '')
    .replace(/[\u0000-\u001F\u007F]/g, ' ')
    .trim();
  return (normalized || fallback).slice(0, maximumLength);
}

function environmentMetadata() {
  const name = requiredSetting('AZURE_ENV_NAME');
  const tenantId = requiredSetting('AZURE_TENANT_ID');
  const subscriptionId = optionalSetting('AZURE_SUBSCRIPTION_ID');
  const resourceGroup = optionalSetting('AZURE_RESOURCE_GROUP');
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (name.length > 128 || /[\u0000-\u001F]/.test(name)) {
    throw new Error('AZURE_ENV_NAME is invalid for notification metadata.');
  }
  if (!uuid.test(tenantId)) {
    throw new Error('AZURE_TENANT_ID must be a UUID for notification metadata.');
  }
  if (subscriptionId && !uuid.test(subscriptionId)) {
    throw new Error('AZURE_SUBSCRIPTION_ID must be a UUID for notification metadata.');
  }
  if (resourceGroup && (resourceGroup.length > 256 || /[\u0000-\u001F]/.test(resourceGroup))) {
    throw new Error('AZURE_RESOURCE_GROUP is invalid for notification metadata.');
  }
  return {
    name,
    tenantId,
    ...(subscriptionId ? { subscriptionId } : {}),
    ...(resourceGroup ? { resourceGroup } : {}),
  };
}

export function normalizePimActivation(event) {
  const eventId = safeOpaqueIdentifier(event.id);
  const correlationId = safeOpaqueIdentifier(event.correlationId ?? eventId);
  const occurredAt = new Date(event.activityDateTime);
  if (Number.isNaN(occurredAt.getTime())) {
    throw new Error('A PIM activation contained an invalid occurrence time.');
  }
  const actor = event.initiatedBy?.user?.userPrincipalName
    ?? event.initiatedBy?.app?.displayName
    ?? event.initiatedBy?.user?.displayName
    ?? null;
  const roleTarget = event.targetResources?.find((target) => target.type === 'Role')
    ?? event.targetResources?.[0];
  return {
    schemaVersion: '1.0',
    eventId,
    eventType: activationEventType,
    source: activationSource,
    occurredAt: occurredAt.toISOString(),
    severity: 'high',
    correlationId,
    isTest: false,
    environment: environmentMetadata(),
    data: {
      actor: normalizedText(actor, 'Unknown', 256),
      role: normalizedText(roleTarget?.displayName, 'Unknown role', 256),
      resultReason: normalizedText(event.resultReason, 'Completed successfully', 300),
    },
  };
}

export function createIdempotencyKey(tenantId, eventType, eventId, routeId) {
  return createHash('sha256')
    .update(`${tenantId}\n${eventType}\n${eventId}\n${routeId}`, 'utf8')
    .digest('hex');
}

function newDeliveryResult(envelope, status, options = {}) {
  return {
    schemaVersion: '1.0',
    eventId: envelope.eventId,
    eventType: envelope.eventType,
    correlationId: envelope.correlationId,
    idempotencyKey: createIdempotencyKey(
      envelope.environment.tenantId,
      envelope.eventType,
      envelope.eventId,
      teamsRoute.id,
    ),
    route: { ...teamsRoute },
    status,
    attempt: options.attempt ?? 0,
    recordedAt: new Date().toISOString(),
    isTest: envelope.isTest,
    environment: { ...envelope.environment },
    ...(options.durationMs === undefined ? {} : { durationMs: options.durationMs }),
    ...(options.skipReason ? { skipReason: options.skipReason } : {}),
    evidence: options.evidence ?? {},
    ...(options.failure ? { failure: options.failure } : {}),
  };
}

function classifyTeamsFailure(status) {
  if (status === 401) return { category: 'authentication', retryable: false };
  if (status === 403) return { category: 'authorization', retryable: false };
  if (status === 408) return { category: 'timeout', retryable: true };
  if (status === 429) return { category: 'throttled', retryable: true };
  if (status === 404 || status === 410) return { category: 'destinationUnavailable', retryable: false };
  if (status >= 500) return { category: 'transientProvider', retryable: true };
  return { category: 'invalidRequest', retryable: false };
}

function renderTeamsCard(envelope) {
  return {
    type: 'message',
    attachments: [{
      contentType: 'application/vnd.microsoft.card.adaptive',
      contentUrl: null,
      content: {
        $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
        type: 'AdaptiveCard',
        version: '1.4',
        body: [
          { type: 'TextBlock', text: 'Microsoft Entra PIM activation', weight: 'Bolder', size: 'Medium' },
          {
            type: 'FactSet',
            facts: [
              { title: 'Administrator', value: envelope.data.actor },
              { title: 'Role', value: envelope.data.role },
              { title: 'Activated', value: envelope.occurredAt },
              { title: 'Audit event ID', value: envelope.eventId },
              { title: 'Correlation ID', value: envelope.correlationId },
              { title: 'Result', value: envelope.data.resultReason },
            ],
          },
        ],
      },
    }],
  };
}

async function sendTeamsNotification(envelope) {
  const startedAt = Date.now();
  let webhookUrl;
  try {
    webhookUrl = requiredSetting('AZD_PIM_TEAMS_WEBHOOK_URL');
  } catch {
    return newDeliveryResult(envelope, 'failed', {
      attempt: 0,
      durationMs: Date.now() - startedAt,
      failure: {
        category: 'destinationUnavailable',
        retryable: false,
        code: 'TeamsDestinationMissing',
      },
    });
  }
  let response;
  try {
    response = await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(renderTeamsCard(envelope)),
    });
  } catch {
    return newDeliveryResult(envelope, 'failed', {
      attempt: 1,
      durationMs: Date.now() - startedAt,
      failure: {
        category: 'destinationUnavailable',
        retryable: true,
        code: 'TeamsTransportError',
      },
    });
  }
  if (!response.ok) {
    return newDeliveryResult(envelope, 'failed', {
      attempt: 1,
      durationMs: Date.now() - startedAt,
      evidence: { httpStatusCode: response.status },
      failure: {
        ...classifyTeamsFailure(response.status),
        code: `TeamsHttp${response.status}`,
      },
    });
  }
  return newDeliveryResult(envelope, 'succeeded', {
    attempt: 1,
    durationMs: Date.now() - startedAt,
    evidence: { httpStatusCode: response.status },
  });
}

function recordDeliveryResult(context, results, result) {
  results.push(result);
  context.log(`AZD_NOTIFICATION_DELIVERY_RESULT ${JSON.stringify(result)}`);
}

export async function pollPimActivations(_timer, context) {
  const lookbackMinutes = Number.parseInt(process.env.AZD_PIM_POLLING_LOOKBACK_MINUTES ?? '30', 10);
  if (!Number.isInteger(lookbackMinutes) || lookbackMinutes < 5 || lookbackMinutes > 1440) {
    throw new Error('AZD_PIM_POLLING_LOOKBACK_MINUTES must be between 5 and 1440.');
  }

  const now = new Date();
  const since = new Date(now.getTime() - lookbackMinutes * 60_000);
  const [graphToken, storageToken] = await Promise.all([
    getManagedIdentityToken(graphResource),
    getManagedIdentityToken(storageResource),
  ]);
  const stored = await readState(storageToken);
  const recent = Array.isArray(stored.value.recent) ? stored.value.recent : [];
  const seenIds = new Set(recent.map((item) => item.id));
  const activations = await getDirectoryAudits(graphToken, since);
  const normalizedEnvelopes = activations.map((event) => normalizePimActivation(event));
  const envelopes = [...new Map(
    normalizedEnvelopes.map((envelope) => [envelope.eventId, envelope]),
  ).values()];
  const unseen = envelopes.filter((envelope) => !seenIds.has(envelope.eventId));
  const sendInitial = process.env.AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK?.toLowerCase() === 'true';
  const deliver = stored.exists || sendInitial ? unseen : [];
  const deliveryResults = [];
  const retentionStart = new Date(now.getTime() - Math.max(lookbackMinutes * 2, 60) * 60_000);
  let currentEtag = stored.etag;
  let nextRecent = recent.filter((item) => new Date(item.seenAt) >= retentionStart);

  for (const envelope of envelopes.filter((item) => seenIds.has(item.eventId))) {
    recordDeliveryResult(context, deliveryResults, newDeliveryResult(envelope, 'alreadyDelivered'));
  }
  if (!stored.exists && !sendInitial) {
    for (const envelope of unseen) {
      recordDeliveryResult(context, deliveryResults, newDeliveryResult(envelope, 'skipped', {
        skipReason: 'initialBaseline',
      }));
    }
  }

  for (const envelope of deliver) {
    const result = await sendTeamsNotification(envelope);
    recordDeliveryResult(context, deliveryResults, result);
    if (result.status === 'failed') {
      throw new Error(`Teams Workflow webhook delivery failed (${result.failure.code}).`);
    }
    seenIds.add(envelope.eventId);
    nextRecent.push({ id: envelope.eventId, seenAt: now.toISOString() });
    nextRecent = nextRecent.slice(-2000);
    currentEtag = await writeState(storageToken, {
      schemaVersion: '1.0',
      lastRunAt: now.toISOString(),
      recent: nextRecent,
    }, currentEtag);
  }

  nextRecent = [
    ...nextRecent,
    ...envelopes.filter((envelope) => !seenIds.has(envelope.eventId)).map((envelope) => ({
      id: envelope.eventId,
      seenAt: now.toISOString(),
    })),
  ].slice(-2000);
  await writeState(storageToken, {
    schemaVersion: '1.0',
    lastRunAt: now.toISOString(),
    recent: nextRecent,
  }, currentEtag);

  context.log(`Processed ${activations.length} activation events; delivered ${deliver.length}.`);
  return deliveryResults;
}

app.timer('pollPimActivations', {
  schedule: process.env.AZD_PIM_POLLING_SCHEDULE ?? '0 */5 * * * *',
  runOnStartup: false,
  useMonitor: true,
  handler: pollPimActivations,
});
