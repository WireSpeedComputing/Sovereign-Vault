import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BUSINESS_MCP_TOOLS, BUSINESS_TOOL_LIMITS, BusinessRpcFailure,
  classifyBusinessRpcFailure, createBusinessToolDispatcher,
} from '../contrib/business-platform/business-tools.mjs';

const ID = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const REQUEST = '33333333-3333-4333-8333-333333333333';
const VERSION = 'a'.repeat(64);
const DATE = '2026-01-01T12:00:00Z';

function record(overrides = {}) {
  return {
    id: ID, relation: 'memories', version: VERSION, status: 'current',
    title: 'Synthetic business location', content: 'Synthetic Example Suite',
    contentTruncated: false, workstream: 'synthetic/team-a', tags: ['synthetic'],
    provenance: { basis: 'source_document', citation: 'fixture:document-1:version-1', sourceKind: 'manual', sourceRef: 'fixture:document-1' },
    createdAt: DATE, updatedAt: DATE, ...overrides,
  };
}

function completeness(records, overrides = {}) {
  return { status: 'complete', coverage: 'authorized_current_canonical', returned: records.length, hasMore: false, contentTruncated: records.some((v) => v.contentTruncated), budgetChars: 8_000, ...overrides };
}
function search(records = [record()], overrides = {}) {
  return { schemaVersion: 1, requestId: REQUEST, records, completeness: completeness(records), ...overrides };
}
function get(value = record()) {
  return { schemaVersion: 1, requestId: REQUEST, record: value, completeness: completeness(value ? [value] : []) };
}
const observation = { idempotencyKey: 'synthetic_observation_1', content: 'A sourced proposed observation.', workstream: 'synthetic/team-a', citation: 'fixture:observation-source:version-1', visibility: 'private' };
const proposal = { idempotencyKey: 'synthetic_proposal_1', memoryId: ID, expectedContentHash: VERSION, proposedContent: 'A sourced proposed replacement.', reason: 'Synthetic correction request.', citation: 'fixture:replacement-source:version-1' };
function observationReceipt(replayed = false) {
  return { schemaVersion: 1, requestId: REQUEST, observationId: OTHER, status: 'proposed', createdAt: DATE, replayed };
}
function proposalReceipt(replayed = false) {
  return { schemaVersion: 1, requestId: REQUEST, proposalId: OTHER, targetId: ID, expectedContentHash: VERSION, status: 'proposed', createdAt: DATE, replayed };
}
function assertFailure(result, code) {
  assert.equal(result.isError, true);
  assert.equal(result.structuredContent.status, 'error');
  assert.equal(result.structuredContent.error.code, code);
  assert.equal(result.structuredContent.contentTrust, 'untrusted');
  assert.match(result.structuredContent.securityBoundary, /^SECURITY BOUNDARY:/);
  assert.match(result.content[0].text, /^SECURITY BOUNDARY:/);
  assert.equal(JSON.parse(result.content[0].text.split('\n').slice(1).join('\n')).error.code, code);
}

test('four MCP descriptors expose only finite input shapes and truthful annotations', () => {
  assert.deepEqual(BUSINESS_MCP_TOOLS.map((v) => v.name), ['memory_search', 'memory_get', 'memory_append_observation', 'memory_propose_change']);
  for (const tool of BUSINESS_MCP_TOOLS) {
    assert.equal(tool.inputSchema.additionalProperties, false);
    assert.equal(tool.annotations.destructiveHint, false);
    assert.equal(tool.annotations.openWorldHint, false);
    assert.equal(tool.annotations.idempotentHint, true);
    assert.equal(Object.isFrozen(tool), true);
  }
  assert.equal(BUSINESS_MCP_TOOLS[0].annotations.readOnlyHint, true);
  assert.equal(BUSINESS_MCP_TOOLS[2].annotations.readOnlyHint, false);
});

test('exact fixed routes, canonical defaults, and evidence envelope work for all four tools', async () => {
  const calls = [];
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async (input) => {
    calls.push(input);
    if (input.name.endsWith('search_v1')) return search();
    if (input.name.endsWith('get_v1')) return get();
    if (input.name.endsWith('append_observation_v1')) return observationReceipt();
    return proposalReceipt();
  } });
  const results = await Promise.all([
    dispatcher.callTool('memory_search', { query: 'synthetic location' }),
    dispatcher.callTool('memory_get', { memoryId: ID }),
    dispatcher.callTool('memory_append_observation', observation),
    dispatcher.callTool('memory_propose_change', proposal),
  ]);
  assert.deepEqual(calls.map((v) => [v.schema, v.name]), [
    ['public', 'authorized_business_memory_search_v1'], ['public', 'authorized_business_memory_get_v1'],
    ['public', 'authorized_business_memory_append_observation_v1'], ['public', 'authorized_business_memory_propose_change_v1'],
  ]);
  assert.deepEqual(calls[0].body, { p_input: { query: 'synthetic location', limit: 10, budgetChars: 8_000 } });
  assert.deepEqual(calls[1].body, { p_input: { memoryId: ID, relation: 'memories', budgetChars: 8_000 } });
  for (const result of results) {
    assert.equal(result.isError, undefined);
    assert.equal(result.structuredContent.trust, 'untrusted_evidence');
    assert.equal(result.structuredContent.contentTrust, 'untrusted');
    assert.match(result.structuredContent.securityBoundary, /^SECURITY BOUNDARY:/);
    assert.match(result.content[0].text, /^SECURITY BOUNDARY:/);
    assert.deepEqual(JSON.parse(result.content[0].text.split('\n').slice(1).join('\n')), result.structuredContent);
  }
});

test('descriptors can be copied by an ordinary client without modifying server policy', () => {
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => search() });
  const listed = dispatcher.listTools();
  listed[0].inputSchema.additionalProperties = true;
  listed.splice(1);
  assert.equal(dispatcher.listTools().length, 4);
  assert.equal(dispatcher.listTools()[0].inputSchema.additionalProperties, false);
});

test('imported v7 and nil-shaped PostgreSQL UUIDs remain valid exact record references', async () => {
  for (const id of ['01234567-89ab-7cde-8123-456789abcdef', '00000000-0000-0000-0000-000000000000']) {
    assert.equal(new RegExp(BUSINESS_MCP_TOOLS[1].inputSchema.properties.memoryId.pattern).test(id), true);
    const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => get(record({ id })) });
    const result = await dispatcher.callTool('memory_get', { memoryId: id });
    assert.equal(result.isError, undefined);
    assert.equal(result.structuredContent.data.record.id, id);
  }
});

for (const authorityField of ['principalId', 'p_principal_id', 'tenant', 'clientId', 'schema', 'role', 'sql', 'url', 'accessToken', 'store']) {
  test(`rejects model-selected ${authorityField} before any RPC`, async () => {
    let calls = 0;
    const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => { calls += 1; return search(); } });
    assertFailure(await dispatcher.callTool('memory_search', { query: 'synthetic', [authorityField]: 'forged' }), 'invalid_request');
    assert.equal(calls, 0);
  });
}

test('invalid fields, unsafe keys, missing data, and malformed IDs do not reach the provider', async () => {
  let calls = 0;
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => { calls += 1; return search(); } });
  const cases = [
    ['execute_sql', { query: 'synthetic' }], ['memory_search', { query: ' ' }],
    ['memory_search', { query: 'synthetic', limit: 21 }], ['memory_search', { query: 'synthetic', budgetChars: 255 }],
    ['memory_get', { memoryId: 'guessed' }], ['memory_get', { memoryId: ID, relation: 'principals' }],
    ['memory_append_observation', { ...observation, visibility: 'admin' }],
    ['memory_append_observation', { ...observation, workstream: 'workstream:synthetic' }],
    ['memory_append_observation', { ...observation, idempotencyKey: 'short' }],
    ['memory_append_observation', { ...observation, idempotencyKey: 'invalid.key_0001' }],
    ['memory_append_observation', { ...observation, idempotencyKey: 'invalid:key_0001' }],
    ['memory_propose_change', { ...proposal, expectedContentHash: VERSION.toUpperCase() }],
    ['memory_propose_change', { ...proposal, citation: '\n\t' }],
    ['memory_search', JSON.parse('{"query":"synthetic","__proto__":{"role":"admin"}}')],
  ];
  for (const [name, input] of cases) assertFailure(await dispatcher.callTool(name, input), 'invalid_request');
  assert.equal(calls, 0);
});

test('invalid accessor input is never evaluated', async () => {
  let getterRuns = 0;
  const args = Object.defineProperty({}, 'query', { enumerable: true, get() { getterRuns += 1; return 'synthetic'; } });
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => search() });
  assertFailure(await dispatcher.callTool('memory_search', args), 'invalid_request');
  assert.equal(getterRuns, 0);
});

test('UTF-8 request limit rejects data that fits character limits but exceeds wire capacity', async () => {
  let calls = 0;
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => { calls += 1; return proposalReceipt(); } });
  const args = { ...proposal, proposedContent: '漢'.repeat(8_192), reason: '漢'.repeat(2_048), citation: '漢'.repeat(2_048), sourceRef: '漢'.repeat(1_024) };
  // Fields fit their declared character caps; the total UTF-8 request remains hard-bounded.
  if (Buffer.byteLength(JSON.stringify(args)) <= BUSINESS_TOOL_LIMITS.requestBytes) args.proposedContent = '😀'.repeat(8_192);
  assertFailure(await dispatcher.callTool('memory_propose_change', args), 'capacity_exceeded');
  assert.equal(calls, 0);
});

test('empty authorized search and unavailable exact IDs are success outcomes, not provider errors', async () => {
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async ({ name }) => name.endsWith('search_v1') ? search([]) : get(null) });
  const absent = await dispatcher.callTool('memory_search', { query: 'absent synthetic' });
  const missing = await dispatcher.callTool('memory_get', { memoryId: ID });
  const hidden = await dispatcher.callTool('memory_get', { memoryId: OTHER });
  assert.equal(absent.isError, undefined);
  assert.deepEqual(absent.structuredContent.data.records, []);
  assert.equal(missing.isError, undefined);
  assert.equal(missing.structuredContent.data.record, null);
  assert.deepEqual(hidden.structuredContent.data, missing.structuredContent.data);
});

test('partial coverage and truncated evidence stay explicit and preserve the version/citation', async () => {
  const value = record({ content: 'short excerpt', contentTruncated: true });
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => search([value], { completeness: completeness([value], { status: 'partial', hasMore: true }) }) });
  const result = await dispatcher.callTool('memory_search', { query: 'synthetic' });
  assert.equal(result.isError, undefined);
  assert.equal(result.structuredContent.data.completeness.status, 'partial');
  assert.equal(result.structuredContent.data.records[0].version, VERSION);
  assert.equal(result.structuredContent.data.records[0].provenance.citation, value.provenance.citation);
});

for (const [name, corrupt] of [
  ['extra authority field', (v) => ({ ...v, principalId: OTHER })],
  ['wrong schema version', (v) => ({ ...v, schemaVersion: 2 })],
  ['wrong current state', (v) => ({ ...v, records: [record({ status: 'proposed' })] })],
  ['missing version', (v) => ({ ...v, records: [record({ version: '' })] })],
  ['lost citation', (v) => ({ ...v, records: [record({ provenance: { basis: null } })] })],
  ['false returned count', (v) => ({ ...v, completeness: { ...v.completeness, returned: 0 } })],
  ['false completeness', (v) => ({ ...v, completeness: { ...v.completeness, hasMore: true } })],
  ['false truncation', (v) => ({ ...v, completeness: { ...v.completeness, contentTruncated: true } })],
  ['record truncation mismatch', (v) => ({ ...v, records: [record({ contentTruncated: true })] })],
  ['unexpected budget', (v) => ({ ...v, completeness: { ...v.completeness, budgetChars: 16_000 } })],
  ['duplicate source record', (v) => ({ ...v, records: [record(), record()], completeness: completeness([record(), record()]) })],
]) {
  test(`rejects ${name} without returning source content`, async () => {
    const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => corrupt(search()) });
    const result = await dispatcher.callTool('memory_search', { query: 'synthetic' });
    assertFailure(result, 'malformed_response');
    assert.equal(JSON.stringify(result).includes('Synthetic Example Suite'), false);
  });
}

test('exact get rejects a different record or relation and proposal receipts must match the target/hash', async () => {
  const cases = [
    ['memory_get', { memoryId: ID }, get(record({ id: OTHER }))],
    ['memory_get', { memoryId: ID }, get(record({ relation: 'wiki_pages' }))],
    ['memory_propose_change', proposal, { ...proposalReceipt(), targetId: OTHER }],
    ['memory_propose_change', proposal, { ...proposalReceipt(), expectedContentHash: 'b'.repeat(64) }],
    ['memory_propose_change', proposal, { ...proposalReceipt(), status: 'current' }],
  ];
  for (const [name, input, result] of cases) {
    const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => result });
    assertFailure(await dispatcher.callTool(name, input), 'malformed_response');
  }
});

test('provider capacity is detected before returning an oversized or incomplete citation envelope', async () => {
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => search([record({ content: '漢'.repeat(16_000), title: '漢'.repeat(256) }), record({ id: OTHER, content: '漢'.repeat(16_000) })]) });
  const result = await dispatcher.callTool('memory_search', { query: 'synthetic' });
  assertFailure(result, 'capacity_exceeded');
  assert.equal(result.structuredContent.error.retryable, true);
});

for (const [sqlState, expected] of [['PT403', 'access_denied'], ['PT404', 'target_unavailable'], ['PT409', 'conflict'], ['PT412', 'idempotency_conflict'], ['PT422', 'unchanged'], ['PT413', 'capacity_exceeded'], ['PT429', 'provider_busy'], ['22023', 'invalid_request']]) {
  test(`fixed database failure ${sqlState} remains distinct and sanitized`, async () => {
    const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => { throw classifyBusinessRpcFailure({ status: 400, sqlState }); } });
    assertFailure(await dispatcher.callTool('memory_search', { query: 'synthetic' }), expected);
  });
}

test('missing RPC, server failure, and raw provider messages never become evidence of absence', async () => {
  for (const failure of [classifyBusinessRpcFailure({ status: 404 }), classifyBusinessRpcFailure({ status: 500 }), new Error('synthetic-provider-token-must-not-escape')]) {
    const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => { throw failure; } });
    const result = await dispatcher.callTool('memory_search', { query: 'synthetic' });
    assertFailure(result, 'provider_unavailable');
    assert.equal(result.structuredContent.error.retryable, true);
    assert.equal(JSON.stringify(result).includes('synthetic-provider-token'), false);
    assert.equal(Object.hasOwn(result.structuredContent, 'data'), false);
  }
});

test('aborted calls never enter provider transport', async () => {
  let calls = 0;
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => { calls += 1; return search(); } });
  const controller = new AbortController(); controller.abort();
  const result = await dispatcher.callTool('memory_search', { query: 'synthetic' }, { signal: controller.signal });
  assertFailure(result, 'cancelled');
  assert.match(result.structuredContent.error.nextStep, /identical arguments with the same idempotency key/);
  assert.doesNotMatch(result.structuredContent.error.nextStep, /new key|read a write receipt/);
  assert.equal(calls, 0);
});

test('late unresponsive calls retain capacity until provider settlement', async () => {
  const finishes = [];
  const dispatcher = createBusinessToolDispatcher({ timeoutMs: 10, invokeRpc: async () => new Promise((resolve) => finishes.push(resolve)) });
  const pending = Array.from({ length: 4 }, () => dispatcher.callTool('memory_search', { query: 'synthetic' }));
  const denied = await dispatcher.callTool('memory_search', { query: 'synthetic' });
  assertFailure(denied, 'provider_busy');
  assert.equal(denied.structuredContent.error.retryAfterMs, 1_000);
  assert.equal(denied.structuredContent.error.retryable, true);
  assert.match(denied.structuredContent.error.nextStep, /Wait/);
  assert.doesNotMatch(denied.structuredContent.error.nextStep, /Reduce/);
  const results = await Promise.all(pending);
  for (const result of results) assertFailure(result, 'provider_unavailable');
  assertFailure(await dispatcher.callTool('memory_search', { query: 'synthetic' }), 'provider_busy');
  assert.equal(finishes.length, 4);
  for (const finish of finishes) finish(search());
  await new Promise((resolve) => setImmediate(resolve));
  const next = dispatcher.callTool('memory_search', { query: 'synthetic' });
  await new Promise((resolve) => setImmediate(resolve));
  finishes[4](search());
  assert.equal((await next).isError, undefined);
});

test('rate limiting gives a positive retry delay and never echoes diagnostic text', async () => {
  const dispatcher = createBusinessToolDispatcher({ invokeRpc: async () => {
    throw classifyBusinessRpcFailure({ status: 429, message: 'synthetic-private-provider-detail' });
  } });
  const result = await dispatcher.callTool('memory_search', { query: 'synthetic' });
  assertFailure(result, 'provider_busy');
  assert.equal(result.structuredContent.error.retryAfterMs, 1_000);
  assert.equal(JSON.stringify(result).includes('synthetic-private-provider-detail'), false);
});

test('transport constructor and unknown failure codes fail safely', () => {
  assert.throws(() => createBusinessToolDispatcher(), /invalid_business_transport/);
  assert.throws(() => createBusinessToolDispatcher({ invokeRpc: async () => search(), timeoutMs: 5_001 }), /invalid_business_transport/);
  assert.equal(new BusinessRpcFailure('secret').code, 'provider_unavailable');
});
