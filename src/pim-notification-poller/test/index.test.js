import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';

import {
  createIdempotencyKey,
  normalizePimActivation,
  pollPimActivations,
} from '../src/index.js';

const managedSettings = [
  'AZD_PIM_POLLING_LOOKBACK_MINUTES',
  'AZD_PIM_POLLING_SEND_INITIAL_LOOKBACK',
  'AZD_PIM_STATE_CONTAINER',
  'AZD_PIM_STORAGE_ACCOUNT_NAME',
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
    AZD_PIM_STATE_CONTAINER: 'pim-state',
    AZD_PIM_STORAGE_ACCOUNT_NAME: 'stateaccount',
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
  assert.equal(callsTo(harness, (call) => call.url.startsWith('https://attacker.example.test')).length, 0);
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
    category: 'destinationUnavailable',
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
