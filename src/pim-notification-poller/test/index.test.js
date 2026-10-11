import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { createServer } from 'node:https';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import {
  createIdempotencyKey,
  normalizePimActivation,
  planPimRecoveryWindow,
  pollPimActivations,
} from '../src/index.js';

const managedSettings = [
  'AZD_PIM_POLLING_LOOKBACK_MINUTES',
  'AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK',
  'AZD_POLLER_STATE_CONTAINER',
  'AZD_POLLER_STORAGE_ACCOUNT_NAME',
  'AZD_PIM_TEAMS_WEBHOOK_URL',
  'IDENTITY_ENDPOINT',
  'IDENTITY_HEADER',
  'AZURE_ENV_NAME',
  'AZURE_RESOURCE_GROUP',
  'AZURE_SUBSCRIPTION_ID',
  'AZURE_TENANT_ID',
];
const originalFetch = globalThis.fetch;
const originalSettings = Object.fromEntries(
  managedSettings.map((name) => [name, process.env[name]]),
);

afterEach(() => {
  globalThis.fetch = originalFetch;
  for (const name of managedSettings) {
    if (originalSettings[name] === undefined) {
      delete process.env[name];
    } else {
      process.env[name] = originalSettings[name];
    }
  }
});

function setRequiredSettings(overrides = {}) {
  Object.assign(process.env, {
    AZD_PIM_POLLING_LOOKBACK_MINUTES: '30',
    AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK: 'false',
    AZD_POLLER_STATE_CONTAINER: 'pim-state',
    AZD_POLLER_STORAGE_ACCOUNT_NAME: 'stateaccount',
    AZD_PIM_TEAMS_WEBHOOK_URL: 'https://teams.example.test/workflows/sensitive-signature',
    IDENTITY_ENDPOINT: 'http://identity.example.test/token',
    IDENTITY_HEADER: 'sensitive-identity-header',
    AZURE_ENV_NAME: 'dev',
    AZURE_RESOURCE_GROUP: 'rg-pim-dev',
    AZURE_SUBSCRIPTION_ID: '22222222-2222-4222-8222-222222222222',
    AZURE_TENANT_ID: '11111111-1111-4111-8111-111111111111',
    ...overrides,
  });
}

function response(body, { status = 200, headers = {} } = {}) {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: {
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...headers,
    },
  });
}

function activation(id, time, overrides = {}) {
  return {
    id,
    activityDateTime: time,
    activityDisplayName: 'Add member to role completed (PIM activation)',
    category: 'RoleManagement',
    correlationId: `correlation-${id}`,
    initiatedBy: { user: { userPrincipalName: `${id}@example.test` } },
    loggedByService: 'PIM',
    result: 'success',
    resultReason: 'Completed successfully',
    targetResources: [{ displayName: `Role ${id}`, type: 'Role' }],
    ...overrides,
  };
}

function irrelevantEvent(id, overrides = {}) {
  return activation(id, '2026-08-23T12:00:00.000Z', {
    activityDisplayName: 'Add member to role requested (PIM activation)',
    ...overrides,
  });
}

function createHarness({
  graphPages = [{ value: [] }],
  readState = { exists: true, etag: 'etag-0', value: { recent: [] } },
  teamsResponses = [],
  writeResponses = [],
} = {}) {
  const calls = [];
  let graphPage = 0;
  let teamsCall = 0;
  let writeCall = 0;

  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    const method = init.method ?? 'GET';
    calls.push({ url, method, headers: init.headers ?? {}, body: init.body });

    if (url.startsWith('http://identity.example.test/token')) {
      const resource = new URL(url).searchParams.get('resource');
      return response({
        access_token: resource === 'https://graph.microsoft.com'
          ? 'sensitive-graph-token'
          : 'sensitive-storage-token',
      });
    }

    if (url.startsWith('https://graph.microsoft.com/')) {
      const page = graphPages[graphPage++];
      if (!page) {
        throw new Error(`Unexpected Graph request: ${url}`);
      }
      return page instanceof Response ? page : response(page);
    }

    if (url === 'https://stateaccount.blob.core.windows.net/pim-state/pim-notification-watermark.json') {
      if (method === 'GET') {
        if (!readState.exists) {
          return response({ error: 'not found' }, { status: 404 });
        }
        return response(readState.value, { headers: { etag: readState.etag } });
      }
      if (method === 'PUT') {
        const configured = writeResponses[writeCall++];
        return configured instanceof Response
          ? configured
          : response(undefined, { status: 201, headers: { etag: configured ?? `etag-${writeCall}` } });
      }
    }

    if (url === process.env.AZD_PIM_TEAMS_WEBHOOK_URL && method === 'POST') {
      const configured = teamsResponses[teamsCall++];
      if (configured instanceof Error) {
        throw configured;
      }
      return configured instanceof Response
        ? configured
        : response(undefined, { status: configured ?? 202 });
    }

    throw new Error(`Unexpected request: ${method} ${url}`);
  };

  return { calls };
}

function contextCapture() {
  const logs = [];
  return {
    context: { log: (message) => logs.push(String(message)) },
    logs,
  };
}

function callsTo(harness, predicate) {
  return harness.calls.filter(predicate);
}

function deliveryResultsFromLogs(logs) {
  const prefix = 'AZD_NOTIFICATION_DELIVERY_RESULT ';
  return logs
    .filter((entry) => entry.startsWith(prefix))
    .map((entry) => JSON.parse(entry.slice(prefix.length)));
}

function propertyNames(value) {
  if (value === null || typeof value !== 'object') return [];
  if (Array.isArray(value)) return value.flatMap(propertyNames);
  return Object.entries(value).flatMap(([name, child]) => [name, ...propertyNames(child)]);
}

function assertAdministratorSafe(result) {
  const serialized = JSON.stringify(result);
  const names = propertyNames(result);
  for (const forbidden of [
    'data', 'recipient', 'userPrincipalName', 'email', 'teamId', 'channelId',
    'card', 'html', 'body', 'destination', 'webhookUrl', 'token', 'authorization',
  ]) {
    assert.equal(names.includes(forbidden), false, `${forbidden} must not be recorded`);
  }
  assert.doesNotMatch(serialized, /sensitive-|Bearer |[?&]sig=|Approval automation|Global Reader|@example\.test/);
}

test('normalizes a Graph directory audit into the PIM notification envelope', () => {
  setRequiredSettings();
  const envelope = normalizePimActivation(activation('event-42', '2026-08-23T20:00:00Z', {
    correlationId: 'correlation-42',
    initiatedBy: { user: { userPrincipalName: 'admin@example.test' } },
    targetResources: [{ displayName: 'AI Reader', type: 'Role' }],
  }));

  assert.deepEqual(Object.keys(envelope), [
    'schemaVersion', 'eventId', 'eventType', 'source', 'occurredAt', 'severity',
    'correlationId', 'isTest', 'environment', 'data',
  ]);
  assert.equal(envelope.schemaVersion, '1.0');
  assert.equal(envelope.eventType, 'entra.pim.roleActivated');
  assert.equal(envelope.source, 'microsoftGraph.directoryAudit');
  assert.equal(envelope.severity, 'high');
  assert.equal(envelope.isTest, false);
  assert.deepEqual(envelope.environment, {
    name: 'dev',
    tenantId: '11111111-1111-4111-8111-111111111111',
    subscriptionId: '22222222-2222-4222-8222-222222222222',
    resourceGroup: 'rg-pim-dev',
  });
  assert.deepEqual(envelope.data, {
    actor: 'admin@example.test',
    role: 'AI Reader',
    resultReason: 'Completed successfully',
  });
});

test('uses the stable event ID as correlation fallback and rejects unsafe identifiers', () => {
  setRequiredSettings();
  const envelope = normalizePimActivation(activation('event-42', '2026-08-23T20:00:00Z', {
    correlationId: null,
  }));
  assert.equal(envelope.correlationId, 'event-42');

  assert.throws(
    () => normalizePimActivation(activation('https://example.invalid/hook?sig=secret', '2026-08-23T20:00:00Z')),
    /invalid opaque identifier/,
  );
});

test('matches the notification-contract SHA-256 idempotency vector', () => {
  assert.equal(
    createIdempotencyKey(
      '11111111-1111-4111-8111-111111111111',
      'entra.pim.roleActivated',
      'event-42',
      'admin-primary',
    ),
    '959a7297c0a6959906bcae516f1179312cb439d30923699f6c1c3cf08351ea37',
  );
});

test('rejects an invalid lookback before making any network request', async () => {
  setRequiredSettings({ AZD_PIM_POLLING_LOOKBACK_MINUTES: '4' });
  let fetchCalled = false;
  globalThis.fetch = async () => {
    fetchCalled = true;
    throw new Error('fetch should not be called');
  };

  await assert.rejects(
    pollPimActivations(null, contextCapture().context),
    /must be between 5 and 1440/,
  );
  assert.equal(fetchCalled, false);
});

test('plans bounded recovery from the last successful query and marks an older gap', () => {
  const now = new Date('2026-08-23T12:00:00Z');
  const recent = planPimRecoveryWindow(now, 30, {
    exists: true, value: { lastSuccessfulQueryAt: '2026-08-23T09:00:00Z' },
  });
  assert.equal(recent.since.toISOString(), '2026-08-23T08:55:00.000Z');
  assert.equal(recent.gap, null);
  const old = planPimRecoveryWindow(now, 30, {
    exists: true, value: { lastSuccessfulQueryAt: '2026-08-21T12:00:00Z' },
  });
  assert.equal(old.since.toISOString(), '2026-08-22T12:00:00.000Z');
  assert.deepEqual(old.gap, {
    reason: 'recoveryLimitExceeded', from: '2026-08-21T12:00:00.000Z',
    to: '2026-08-22T12:00:00.000Z', detectedAt: now.toISOString(),
  });
});

test('treats an old legacy run timestamp as an unknown coverage gap', () => {
  const now = new Date('2026-08-23T12:00:00Z');
  const window = planPimRecoveryWindow(now, 30, {
    exists: true, value: { lastRunAt: '2026-08-23T09:00:00Z' },
  });
  assert.equal(window.since.toISOString(), '2026-08-22T12:00:00.000Z');
  assert.equal(window.gap.reason, 'missingWatermark');
});

test('establishes a first-run watermark without sending historical activations', async () => {
  setRequiredSettings();
  const matching = activation('baseline-event', '2026-08-23T12:00:00.000Z');
  const harness = createHarness({
    readState: { exists: false },
    graphPages: [{
      value: [
        matching,
        irrelevantEvent('wrong-operation'),
        activation('failed-event', '2026-08-23T12:01:00.000Z', { result: 'failure' }),
        activation('wrong-service', '2026-08-23T12:02:00.000Z', { loggedByService: 'Core Directory' }),
      ],
    }],
  });
  const { context, logs } = contextCapture();

  const results = await pollPimActivations(null, context);

  assert.equal(callsTo(harness, (call) => call.url.includes('teams.example.test')).length, 0);
  const writes = callsTo(harness, (call) => call.method === 'PUT');
  assert.equal(writes.length, 1);
  assert.equal(writes[0].headers['If-None-Match'], '*');
  const state = JSON.parse(writes[0].body);
  assert.deepEqual(state.recent.map((item) => item.id), ['baseline-event']);
  assert.equal(results.length, 1);
  assert.equal(results[0].status, 'skipped');
  assert.equal(results[0].skipReason, 'initialBaseline');
  assert.equal(results[0].attempt, 0);
  assertAdministratorSafe(results[0]);
  assert.deepEqual(deliveryResultsFromLogs(logs), results);
  assert.match(logs.at(-1), /Processed 1 activation events; delivered 0/);
});

test('follows Graph pagination, filters and sorts events, maps cards, and advances the ETag after each delivery', async () => {
  setRequiredSettings({ AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK: 'true' });
  const later = activation('later', '2026-08-23T12:05:00.000Z', {
    initiatedBy: { user: { displayName: 'Later Admin' } },
    targetResources: [
      { displayName: 'Not the role', type: 'User' },
      { displayName: 'Global Reader', type: 'Role' },
    ],
  });
  const earlier = activation('earlier', '2026-08-23T12:00:00.000Z', {
    correlationId: null,
    initiatedBy: { app: { displayName: 'Approval automation' } },
    result: 'SUCCESS',
    resultReason: 'x'.repeat(350),
  });
  const nextLink = 'https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$skiptoken=next-page';
  const harness = createHarness({
    readState: { exists: false },
    graphPages: [
      { value: [later, irrelevantEvent('ignored')], '@odata.nextLink': nextLink },
      { value: [earlier] },
    ],
    writeResponses: ['etag-1', 'etag-2', 'etag-3'],
  });
  const { context, logs } = contextCapture();

  const results = await pollPimActivations(null, context);

  const graphCalls = callsTo(harness, (call) => call.url.startsWith('https://graph.microsoft.com/'));
  assert.equal(graphCalls.length, 2);
  assert.equal(graphCalls[1].url, nextLink);
  assert.equal(graphCalls[0].headers.Authorization, 'Bearer sensitive-graph-token');

  const teamsCalls = callsTo(harness, (call) => call.url.includes('teams.example.test'));
  assert.equal(teamsCalls.length, 2);
  const cards = teamsCalls.map((call) => JSON.parse(call.body).attachments[0].content);
  const facts = cards.map((card) => Object.fromEntries(card.body[1].facts.map((fact) => [fact.title, fact.value])));
  assert.equal(facts[0].Administrator, 'Approval automation');
  assert.equal(facts[0].Role, 'Role earlier');
  assert.equal(facts[0]['Correlation ID'], 'earlier');
  assert.equal(facts[0].Result.length, 300);
  assert.equal(facts[1].Administrator, 'Later Admin');
  assert.equal(facts[1].Role, 'Global Reader');

  const writes = callsTo(harness, (call) => call.method === 'PUT');
  assert.equal(writes.length, 3);
  assert.deepEqual(writes.map((call) => call.headers['If-Match'] ?? call.headers['If-None-Match']), [
    '*',
    'etag-1',
    'etag-2',
  ]);
  assert.deepEqual(JSON.parse(writes[1].body).recent.map((item) => item.id), ['earlier', 'later']);
  assert.deepEqual(results.map((result) => result.status), ['succeeded', 'succeeded']);
  assert.deepEqual(results.map((result) => result.eventId), ['earlier', 'later']);
  assert.equal(results[0].route.transport, 'teams.workflowWebhook');
  assert.equal(results[0].route.audience, 'admin');
  assert.equal(results[0].evidence.httpStatusCode, 202);
  assert.match(results[0].idempotencyKey, /^[0-9a-f]{64}$/);
  for (const result of results) assertAdministratorSafe(result);
  assert.deepEqual(deliveryResultsFromLogs(logs), results);
  assert.match(logs.at(-1), /Processed 2 activation events; delivered 2/);

  const observableOutput = JSON.stringify({ logs, states: writes.map((call) => JSON.parse(call.body)) });
  assert.doesNotMatch(observableOutput, /sensitive-signature|sensitive-graph-token|sensitive-storage-token|sensitive-identity-header/);
});

test('replays an outage and advances the query watermark only after all deliveries finish', async () => {
  setRequiredSettings();
  const prior = new Date(Date.now() - 3 * 60 * 60_000);
  const event = activation('recovered-event', new Date(prior.getTime() + 60 * 60_000).toISOString());
  const harness = createHarness({
    readState: { exists: true, etag: 'etag-0', value: { recent: [], lastSuccessfulQueryAt: prior.toISOString() } },
    graphPages: [{ value: [event] }],
    writeResponses: ['etag-after-event', 'etag-final'],
  });
  const { context, logs } = contextCapture();
  await pollPimActivations(null, context);

  const graph = callsTo(harness, (call) => call.url.startsWith('https://graph.microsoft.com/'));
  const filter = new URL(graph[0].url).searchParams.get('$filter');
  const since = Date.parse(filter.replace('activityDateTime ge ', ''));
  assert.ok(Math.abs(since - (prior.getTime() - 5 * 60_000)) < 5_000);
  const writes = callsTo(harness, (call) => call.method === 'PUT').map((call) => JSON.parse(call.body));
  assert.equal(writes.length, 2);
  assert.equal(writes[0].lastSuccessfulQueryAt, prior.toISOString());
  assert.ok(Date.parse(writes[1].lastSuccessfulQueryAt) > prior.getTime());
  assert.equal(writes[1].recoveryGap, null);
  assert.equal(logs.some((entry) => entry.startsWith('AZD_POLLER_RECOVERY_GAP ')), false);
});

test('persists an unfillable outage gap and logs a safe warning', async () => {
  setRequiredSettings();
  const prior = new Date(Date.now() - 2 * 24 * 60 * 60_000);
  const harness = createHarness({
    readState: { exists: true, etag: 'etag-0', value: { recent: [], lastSuccessfulQueryAt: prior.toISOString() } },
  });
  const { context, logs } = contextCapture();
  await pollPimActivations(null, context);
  const written = JSON.parse(callsTo(harness, (call) => call.method === 'PUT')[0].body);
  assert.equal(written.recoveryGap.reason, 'recoveryLimitExceeded');
  assert.ok(written.recoveryGap.from < written.recoveryGap.to);
  assert.equal(logs.filter((entry) => entry.startsWith('AZD_POLLER_RECOVERY_GAP ')).length, 1);
  assert.doesNotMatch(JSON.stringify(logs), /sensitive-graph-token|sensitive-storage-token|sensitive-signature/);
});

test('stops before sending when replay would evict active deduplication IDs', async () => {
  setRequiredSettings();
  const now = new Date().toISOString();
  const recent = Array.from({ length: 10000 }, (_, index) => ({ id: `prior-${index}`, seenAt: now }));
  const harness = createHarness({
    readState: { exists: true, etag: 'etag-0', value: { recent, lastSuccessfulQueryAt: now } },
    graphPages: [{ value: [activation('one-more', now)] }],
  });
  const { context } = contextCapture();

  await assert.rejects(pollPimActivations(null, context), /event state limit/);
  assert.equal(callsTo(harness, (call) => call.url.includes('teams.example.test')).length, 0);
  assert.equal(callsTo(harness, (call) => call.method === 'PUT').length, 0);
});

test('deduplicates previously seen events and drops expired watermark entries', async () => {
  setRequiredSettings();
  const harness = createHarness({
    readState: {
      exists: true,
      etag: 'etag-current',
      value: {
        recent: [
          { id: 'already-seen', seenAt: new Date().toISOString() },
          { id: 'expired', seenAt: '2000-01-01T00:00:00.000Z' },
        ],
      },
    },
    graphPages: [{
      value: [
        activation('already-seen', '2026-08-23T12:00:00.000Z'),
        activation('new-event', '2026-08-23T12:01:00.000Z'),
      ],
    }],
    writeResponses: ['etag-after-event', 'etag-final'],
  });

  const { context, logs } = contextCapture();
  const results = await pollPimActivations(null, context);

  const teamsCalls = callsTo(harness, (call) => call.url.includes('teams.example.test'));
  assert.equal(teamsCalls.length, 1);
  assert.match(teamsCalls[0].body, /new-event/);
  const finalState = JSON.parse(callsTo(harness, (call) => call.method === 'PUT').at(-1).body);
  assert.deepEqual(finalState.recent.map((item) => item.id), ['already-seen', 'new-event']);
  assert.deepEqual(results.map((result) => [result.eventId, result.status]), [
    ['already-seen', 'alreadyDelivered'],
    ['new-event', 'succeeded'],
  ]);
  assert.equal(results[0].attempt, 0);
  assert.deepEqual(deliveryResultsFromLogs(logs), results);
});

test('collapses overlapping Graph pages to one route result and Teams post per stable event ID', async () => {
  setRequiredSettings();
  const duplicate = activation('overlap-event', '2026-08-23T12:00:00.000Z');
  const nextLink = 'https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$skiptoken=overlap-page';
  const harness = createHarness({
    graphPages: [
      { value: [duplicate], '@odata.nextLink': nextLink },
      { value: [{ ...duplicate }] },
    ],
    writeResponses: ['etag-after-event', 'etag-final'],
  });
  const { context, logs } = contextCapture();

  const results = await pollPimActivations(null, context);

  assert.equal(callsTo(harness, (call) => call.url.includes('teams.example.test')).length, 1);
  assert.equal(results.length, 1);
  assert.equal(results[0].eventId, 'overlap-event');
  assert.equal(results[0].status, 'succeeded');
  assert.equal(deliveryResultsFromLogs(logs).length, 1);
  const writes = callsTo(harness, (call) => call.method === 'PUT');
  assert.equal(writes.length, 2);
  assert.deepEqual(JSON.parse(writes[0].body).recent.map((item) => item.id), ['overlap-event']);
  assert.deepEqual(JSON.parse(writes[1].body).recent.map((item) => item.id), ['overlap-event']);
});

test('fails a paginated Graph query without delivering or advancing the watermark', async () => {
  setRequiredSettings();
  const harness = createHarness({
    graphPages: [
      {
        value: [activation('first-page', '2026-08-23T12:00:00.000Z')],
        '@odata.nextLink': 'https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$skiptoken=failing-page',
      },
      response({ error: 'temporarily unavailable' }, { status: 503 }),
    ],
  });

  await assert.rejects(
    pollPimActivations(null, contextCapture().context),
    (error) => {
      assert.match(error.message, /directory audit query failed \(HTTP 503\)/);
      assert.doesNotMatch(error.message, /temporarily unavailable|Bearer|sig=/);
      return true;
    },
  );
  assert.equal(callsTo(harness, (call) => call.url.includes('teams.example.test')).length, 0);
  assert.equal(callsTo(harness, (call) => call.method === 'PUT').length, 0);
});

test('rejects a non-Graph continuation link before forwarding the bearer token', async () => {
  setRequiredSettings();
  const harness = createHarness({
    graphPages: [{
      value: [],
      '@odata.nextLink': 'https://attacker.example.test/collect?token=do-not-send',
    }],
  });

  await assert.rejects(
    pollPimActivations(null, contextCapture().context),
    /invalid directory audit continuation link/,
  );
  assert.equal(callsTo(harness, (call) => new URL(call.url).hostname === 'attacker.example.test').length, 0);
  assert.equal(callsTo(harness, (call) => call.url.startsWith('https://graph.microsoft.com/')).length, 1);
  assert.equal(callsTo(harness, (call) => call.method === 'PUT').length, 0);
});

test('leaves a failed Teams delivery unwatermarked so a later invocation can retry it', async () => {
  setRequiredSettings();
  const firstAttempt = createHarness({
    graphPages: [{ value: [activation('retry-event', '2026-08-23T12:00:00.000Z')] }],
    teamsResponses: [response({ error: 'workflow unavailable' }, { status: 503 })],
  });

  const firstContext = contextCapture();
  await assert.rejects(
    pollPimActivations(null, firstContext.context),
    (error) => {
      assert.match(error.message, /Teams Workflow webhook delivery failed \(TeamsHttp503\)/);
      assert.doesNotMatch(error.message, /workflow unavailable|sensitive-signature/);
      return true;
    },
  );
  const failure = deliveryResultsFromLogs(firstContext.logs)[0];
  assert.equal(failure.status, 'failed');
  assert.deepEqual(failure.failure, {
    category: 'transientProvider',
    retryable: true,
    code: 'TeamsHttp503',
  });
  assert.deepEqual(failure.evidence, { httpStatusCode: 503 });
  assertAdministratorSafe(failure);
  assert.equal(callsTo(firstAttempt, (call) => call.method === 'PUT').length, 0);

  const retry = createHarness({
    graphPages: [{ value: [activation('retry-event', '2026-08-23T12:00:00.000Z')] }],
    writeResponses: ['etag-retry', 'etag-final'],
  });
  const retryContext = contextCapture();
  const retryResults = await pollPimActivations(null, retryContext.context);

  assert.equal(callsTo(retry, (call) => call.url.includes('teams.example.test')).length, 1);
  const retryState = JSON.parse(callsTo(retry, (call) => call.method === 'PUT')[0].body);
  assert.deepEqual(retryState.recent.map((item) => item.id), ['retry-event']);
  assert.equal(retryResults[0].idempotencyKey, failure.idempotencyKey);
  assert.equal(retryResults[0].status, 'succeeded');
});

test('turns a transport exception into a retryable result without leaking the destination or provider error', async () => {
  setRequiredSettings();
  const harness = createHarness({
    graphPages: [{ value: [activation('network-event', '2026-08-23T12:00:00.000Z')] }],
    teamsResponses: [new Error('Bearer sensitive-token failed at https://teams.example.test/hook?sig=secret')],
  });
  const { context, logs } = contextCapture();

  await assert.rejects(
    pollPimActivations(null, context),
    (error) => {
      assert.equal(error.message, 'Teams Workflow webhook delivery failed (TeamsTransportError).');
      assert.doesNotMatch(error.message, /Bearer|teams\.example|sig=|sensitive-token/);
      return true;
    },
  );

  const results = deliveryResultsFromLogs(logs);
  assert.equal(results.length, 1);
  assert.deepEqual(results[0].failure, {
    category: 'unknown',
    retryable: true,
    code: 'TeamsTransportError',
  });
  assert.deepEqual(results[0].evidence, {});
  assertAdministratorSafe(results[0]);
  assert.equal(callsTo(harness, (call) => call.method === 'PUT').length, 0);
});

test('stops the delivery loop if a successful Teams post cannot be watermarked', async () => {
  setRequiredSettings();
  const harness = createHarness({
    graphPages: [{
      value: [
        activation('first-event', '2026-08-23T12:00:00.000Z'),
        activation('second-event', '2026-08-23T12:01:00.000Z'),
      ],
    }],
    writeResponses: [response({ error: 'etag conflict' }, { status: 412 })],
  });

  const { context, logs } = contextCapture();
  await assert.rejects(
    pollPimActivations(null, context),
    /Unable to update polling watermark \(HTTP 412\)/,
  );
  const teamsCalls = callsTo(harness, (call) => call.url.includes('teams.example.test'));
  assert.equal(teamsCalls.length, 1);
  assert.match(teamsCalls[0].body, /first-event/);
  assert.doesNotMatch(teamsCalls[0].body, /second-event/);
  const results = deliveryResultsFromLogs(logs);
  assert.equal(results.length, 1);
  assert.equal(results[0].status, 'succeeded');
  assert.equal(results[0].eventId, 'first-event');
  assertAdministratorSafe(results[0]);
});

test('records a blank webhook as destination unavailable before throwing without secrets', async () => {
  setRequiredSettings();
  process.env.AZD_PIM_TEAMS_WEBHOOK_URL = '   ';
  const harness = createHarness({
    graphPages: [{ value: [activation('secret-safe-event', '2026-08-23T12:00:00.000Z')] }],
  });
  const { context, logs } = contextCapture();

  await assert.rejects(
    pollPimActivations(null, context),
    (error) => {
      assert.equal(error.message, 'Teams Workflow webhook delivery failed (TeamsDestinationMissing).');
      assert.doesNotMatch(error.message, /AZD_PIM_TEAMS_WEBHOOK_URL|sensitive-|https:/i);
      return true;
    },
  );

  const results = deliveryResultsFromLogs(logs);
  assert.equal(results.length, 1);
  assert.equal(results[0].status, 'failed');
  assert.equal(results[0].attempt, 0);
  assert.deepEqual(results[0].failure, {
    category: 'destinationUnavailable',
    retryable: false,
    code: 'TeamsDestinationMissing',
  });
  assert.deepEqual(results[0].evidence, {});
  assertAdministratorSafe(results[0]);
  assert.equal(callsTo(harness, (call) => call.method === 'PUT').length, 0);
});

test('refuses invalid callback destinations before POST and watermark advance', async () => {
  for (const destination of ['http://teams.example.test/hook', 'https://user:secret@teams.example.test/hook',
    'https://@teams.example.test/hook', 'https://teams.example.test/hook#',
    'https://teams.example.test/ho\tok', 'not-a-url']) {
    setRequiredSettings({ AZD_PIM_TEAMS_WEBHOOK_URL: destination });
    const harness = createHarness({ graphPages: [{ value: [activation('invalid-destination', new Date().toISOString())] }] });
    const { context, logs } = contextCapture();
    await assert.rejects(pollPimActivations(null, context), /TeamsDestinationInvalid/);
    const result = deliveryResultsFromLogs(logs)[0];
    assert.equal(result.attempt, 0);
    assert.equal(result.failure.retryable, false);
    assert.equal(result.failure.category, 'invalidRequest');
    assertAdministratorSafe(result);
    assert.equal(callsTo(harness, (call) => call.method === 'POST' || call.method === 'PUT').length, 0);
  }
});

test('actual local TLS callback acknowledgement boundaries preserve replay and privacy', { timeout: 45_000 }, async () => {
  const directory = mkdtempSync(join(tmpdir(), 'azd-pim-callback-'));
  const certificatePath = join(directory, 'localhost.pem');
  const keyPath = join(directory, 'localhost-key.pem');
  const scriptPath = join(directory, 'certificate.ps1');
  // Ephemeral localhost-only certificate, no certificate-store installation or global trust change.
  writeFileSync(scriptPath, `#Requires -Version 7.6
param([string]$CertificatePath,[string]$KeyPath)
$ErrorActionPreference='Stop'
$rsa=[Security.Cryptography.RSA]::Create(2048)
try {
 $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=localhost',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
 $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
 $san.AddDnsName('localhost');$san.AddIpAddress([Net.IPAddress]::Loopback)
 $request.CertificateExtensions.Add($san.Build())
 $certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddDays(1))
 try {[IO.File]::WriteAllText($CertificatePath,$certificate.ExportCertificatePem());[IO.File]::WriteAllText($KeyPath,$rsa.ExportPkcs8PrivateKeyPem())} finally {$certificate.Dispose()}
} finally {$rsa.Dispose()}
`);
  let server;
  try {
    execFileSync('pwsh', ['-NoProfile', '-File', scriptPath, '-CertificatePath', certificatePath, '-KeyPath', keyPath]);
    let mode;
    const requests = [];
    server = createServer({ cert: readFileSync(certificatePath), key: readFileSync(keyPath) }, (request, reply) => {
      let body = '';
      request.on('data', (chunk) => { body += chunk; });
      request.on('end', () => {
        requests.push({ path: request.url, body: JSON.parse(body), authorization: request.headers.authorization });
        if (mode === 'drop' && requests.length === 1) { request.socket.destroy(); return; }
        if (mode === 'stall') return;
        if (mode === 'redirect') { reply.writeHead(302, { Location: `https://localhost:${server.address().port}/foreign?sig=provider-secret` }); }
        else reply.writeHead(mode.startsWith('http') ? Number(mode.slice(4)) : 202);
        reply.end('Bearer provider-secret and raw destination must never be persisted');
      });
    });
    await new Promise((done) => server.listen(0, '127.0.0.1', done));
    const callback = `https://localhost:${server.address().port}/callback?sig=synthetic-secret`;
    const importUrl = new URL('../src/index.js', import.meta.url).href;
    const run = promisify(execFile);
    // The child trusts only this generated certificate in its own process. Identity/Graph/Blob
    // requests remain fake, while the actual sender and native fetch cross the TLS wire.
    const functions = [setRequiredSettings, response, activation, createHarness, contextCapture,
      deliveryResultsFromLogs].map((fn) => fn.toString()).join('\n');
    for (mode of ['drop', 'stall', 'redirect', 'http408', 'http429', 'http500', 'ack412']) {
      requests.length = 0;
      const repeated = mode === 'drop' || mode === 'ack412';
      const code = `import { pollPimActivations } from ${JSON.stringify(importUrl)};
${functions}
const nativeFetch=globalThis.fetch;
setRequiredSettings({AZD_PIM_TEAMS_WEBHOOK_URL:${JSON.stringify(callback)}});
const event=activation('wire-event',new Date().toISOString());
const outcomes=[];
for(let attempt=0;attempt<${repeated ? 2 : 1};attempt++){
 const harness=createHarness({graphPages:[{value:[event]}],writeResponses:${mode === 'ack412' ? "attempt===0?[response({}, {status:412})]:[]" : '[]'}});
 const fakeFetch=globalThis.fetch;
 globalThis.fetch=(input,init)=>String(input)===process.env.AZD_PIM_TEAMS_WEBHOOK_URL?nativeFetch(input,init):fakeFetch(input,init);
 const capture=contextCapture();let error=null;
 try{await pollPimActivations(null,capture.context)}catch(caught){error=caught.message}
 outcomes.push({results:deliveryResultsFromLogs(capture.logs),error,writes:harness.calls.filter(c=>c.method==='PUT').map(c=>JSON.parse(c.body))});
}
console.log('WIRE_RESULT '+JSON.stringify(outcomes));`;
      const started = Date.now();
      const { stdout } = await run(process.execPath, ['--input-type=module', '-e', code], {
        env: { ...process.env, NODE_EXTRA_CA_CERTS: certificatePath }, timeout: 25_000, maxBuffer: 256 * 1024,
      });
      const outcomes = JSON.parse(stdout.split('\n').find((line) => line.startsWith('WIRE_RESULT ')).slice(12));
      assert.equal(requests.length, repeated ? 2 : 1, 'one POST per invocation, no automatic retry or redirect');
      assert.equal(requests.filter((request) => request.path.startsWith('/foreign')).length, 0);
      assert.equal(requests.every((request) => request.authorization === undefined), true);
      assert.equal(requests.every((request) => request.body.type === 'message'), true);
      for (const outcome of outcomes) for (const result of outcome.results) assertAdministratorSafe(result);
      const first = outcomes[0].results[0];
      if (mode === 'drop' || mode === 'stall') {
        assert.equal(first.status, 'failed');
        assert.equal(first.failure.category, mode === 'stall' ? 'timeout' : 'unknown');
        assert.equal(first.failure.retryable, true);
        assert.deepEqual(first.evidence, {});
        assert.equal(outcomes[0].writes.length, 0);
        if (mode === 'stall') assert.ok(Date.now() - started >= 9_000 && Date.now() - started < 20_000);
      } else if (mode !== 'ack412') {
        assert.equal(first.status, 'failed');
        assert.equal(first.evidence.httpStatusCode, mode === 'redirect' ? 302 : Number(mode.slice(4)));
        assert.equal(first.failure.retryable, mode !== 'redirect');
        assert.equal(outcomes[0].writes.length, 0);
      } else {
        assert.equal(first.status, 'succeeded', 'acknowledgement is retained despite failed persistence');
        assert.match(outcomes[0].error, /HTTP 412/);
      }
      if (repeated) {
        assert.equal(outcomes[1].results[0].idempotencyKey, first.idempotencyKey);
        assert.equal(outcomes[1].results[0].status, 'succeeded');
        assert.equal(outcomes[1].writes.at(-1).recent[0].id, 'wire-event');
      }
      assert.doesNotMatch(JSON.stringify(outcomes), /synthetic-secret|provider-secret|localhost|Bearer/);
    }
  } finally {
    if (server) { server.closeAllConnections(); await new Promise((done) => server.close(done)); }
    if (resolve(directory).startsWith(resolve(tmpdir()) + '\\') || resolve(directory).startsWith(resolve(tmpdir()) + '/')) {
      rmSync(directory, { recursive: true, force: true });
    } else throw new Error('Unexpected test directory');
  }
});
