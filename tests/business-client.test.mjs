import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createBusinessToolDispatcher, classifyBusinessRpcFailure } from '../contrib/business-platform/business-tools.mjs';
import { createBusinessFixtureDatabase, SYNTHETIC, expectedContentHash, invokeRpcAs, adminSql } from './64_business_user_tools.mjs';

const RPCS = new Set([
  'authorized_business_memory_search_v1', 'authorized_business_memory_get_v1',
  'authorized_business_memory_append_observation_v1', 'authorized_business_memory_propose_change_v1',
]);

// The actor/client context is bound by the trusted transport, outside tool input.
// This synthetic seam executes the real candidate RPCs with authenticator custody.
function ordinaryClient(db, options = {}, calls = []) {
  return createBusinessToolDispatcher({ invokeRpc: async ({ schema, name, body, signal }) => {
    assert.equal(schema, 'public');
    assert.equal(RPCS.has(name), true);
    assert.equal(signal.aborted, false);
    assert.deepEqual(Object.keys(body), ['p_input']);
    for (const key of ['principalId', 'clientId', 'sessionId', 'role', 'schema', 'sql', 'accessToken'])
      assert.equal(Object.hasOwn(body.p_input, key), false);
    calls.push(name);
    try { return await invokeRpcAs(db, options, name, body.p_input); }
    catch (error) { throw classifyBusinessRpcFailure({ sqlState: error.code }); }
  } });
}

function accepted(result) {
  assert.equal(result.isError, undefined, JSON.stringify(result.structuredContent));
  assert.equal(result.structuredContent.contentTrust, 'untrusted');
  assert.match(result.content[0].text, /^SECURITY BOUNDARY:/);
  return result.structuredContent.data;
}

function denied(result, code) {
  assert.equal(result.isError, true);
  assert.equal(result.structuredContent.error.code, code);
  assert.match(result.content[0].text, /^SECURITY BOUNDARY:/);
  assert.equal(Object.hasOwn(result.structuredContent, 'data'), false);
  return result.structuredContent.error;
}

test('ordinary scripted client searches, reads, stages, replays and verifies unchanged canonical data', async (t) => {
  const db = await createBusinessFixtureDatabase();
  t.after(() => db.close());
  const calls = [];
  const client = ordinaryClient(db, {}, calls);
  const search = accepted(await client.callTool('memory_search', { query: 'business address' }));
  assert.equal(search.completeness.coverage, 'authorized_current_canonical');
  assert.equal(search.records.some((record) => record.id === SYNTHETIC.currentId), true);
  assert.deepEqual(search.records.find((record) => record.id === SYNTHETIC.currentId).tags, ['address', 'office']);
  assert.equal(search.records.some((record) => [SYNTHETIC.otherScopeId, SYNTHETIC.proposedId, SYNTHETIC.supersededId].includes(record.id)), false);

  const current = accepted(await client.callTool('memory_get', { memoryId: SYNTHETIC.currentId })).record;
  assert.equal(current.content, SYNTHETIC.content);
  assert.equal(current.version, expectedContentHash);
  assert.equal(current.provenance.citation, 'synthetic citation');
  assert.equal(current.contentTruncated, false);
  assert.deepEqual(current.tags, ['address', 'office']);
  const observation = {
    idempotencyKey: 'scripted_observation_0001', content: 'Zebralanternreceipt observation awaiting review.',
    workstream: SYNTHETIC.workstream, citation: 'fixture:observation:version-1', visibility: 'private',
  };
  const first = accepted(await client.callTool('memory_append_observation', observation));
  const replay = accepted(await client.callTool('memory_append_observation', observation));
  assert.equal(first.status, 'proposed');
  assert.equal(first.replayed, false);
  assert.equal(replay.replayed, true);
  assert.equal(replay.observationId, first.observationId);
  assert.equal(replay.requestId, first.requestId);
  assert.equal(replay.createdAt, first.createdAt);
  denied(await client.callTool('memory_append_observation', { ...observation, content: 'Changed input needs a new key.' }), 'idempotency_conflict');

  const proposal = {
    idempotencyKey: 'scripted_proposal_0001', memoryId: current.id, expectedContentHash: current.version,
    proposedContent: 'Synthetic proposed new office reference.', reason: 'A sourced synthetic correction.',
    citation: 'fixture:correction:version-1', sourceRef: 'fixture:correction',
  };
  const staged = accepted(await client.callTool('memory_propose_change', proposal));
  const proposalReplay = accepted(await client.callTool('memory_propose_change', proposal));
  assert.equal(staged.status, 'proposed');
  assert.equal(staged.targetId, current.id);
  assert.equal(proposalReplay.proposalId, staged.proposalId);
  assert.equal(proposalReplay.requestId, staged.requestId);
  assert.equal(proposalReplay.replayed, true);
  denied(await client.callTool('memory_propose_change', { ...proposal, idempotencyKey: 'scripted_stale_0001', expectedContentHash: '0'.repeat(64) }), 'conflict');
  denied(await client.callTool('memory_propose_change', { ...proposal, idempotencyKey: 'scripted_unchanged_0001', proposedContent: current.content }), 'unchanged');

  const after = accepted(await client.callTool('memory_get', { memoryId: current.id })).record;
  assert.deepEqual(after, current);
  assert.deepEqual(accepted(await client.callTool('memory_search', { query: 'zebralanternreceipt' })).records, []);
  assert.deepEqual(new Set(calls), RPCS);
  // There is no inference, embedding provider, promotion or admin RPC in this client.
  assert.equal(calls.every((name) => RPCS.has(name)), true);
  const stagedCount = (await adminSql(db, 'SELECT count(*)::int AS n FROM business_user_tools_private.submissions_v1')).rows[0].n;
  assert.equal(stagedCount, 2);
});

test('ordinary client preserves missing/hidden parity and denies forged or revoked authority', async (t) => {
  const db = await createBusinessFixtureDatabase();
  t.after(() => db.close());
  const bob = ordinaryClient(db, { actor: 'bob' });
  const hidden = accepted(await bob.callTool('memory_get', { memoryId: SYNTHETIC.privateId }));
  const missing = accepted(await bob.callTool('memory_get', { memoryId: '80000000-0000-4000-8000-000000000001' }));
  assert.equal(hidden.record, null);
  assert.deepEqual({ ...hidden, requestId: null }, { ...missing, requestId: null });
  const client = ordinaryClient(db);
  denied(await client.callTool('memory_get', { memoryId: SYNTHETIC.privateId, principalId: SYNTHETIC.bob.principalId }), 'invalid_request');
  const wiki = accepted(await client.callTool('memory_get', { memoryId: SYNTHETIC.wikiId, relation: 'wiki_pages' }));
  assert.equal(wiki.record.relation, 'wiki_pages');
  const observation = {
    idempotencyKey: 'scripted_revocation_0001', content: 'Synthetic staged item.', workstream: SYNTHETIC.workstream,
    citation: 'fixture:revocation:version-1', visibility: 'private',
  };
  accepted(await client.callTool('memory_append_observation', observation));
  await adminSql(db, 'DELETE FROM auth.sessions WHERE id=$1', [SYNTHETIC.alice.sessionId]);
  denied(await client.callTool('memory_get', { memoryId: SYNTHETIC.currentId }), 'access_denied');
  denied(await client.callTool('memory_append_observation', observation), 'access_denied');
});

test('real database truncation stays explicit and provenance capacity is not absence', async (t) => {
  const db = await createBusinessFixtureDatabase();
  t.after(() => db.close());
  const client = ordinaryClient(db);
  await adminSql(db, 'UPDATE public.memories SET content=$2 WHERE id=$1', [SYNTHETIC.currentId, 'x'.repeat(1_000)]);
  const partial = accepted(await client.callTool('memory_get', { memoryId: SYNTHETIC.currentId, budgetChars: 256 }));
  assert.equal(partial.record.content.length, 256);
  assert.equal(partial.record.contentTruncated, true);
  assert.equal(partial.completeness.contentTruncated, true);
  assert.equal(partial.completeness.status, 'partial');
  assert.equal(partial.record.provenance.citation, 'synthetic citation');
  await adminSql(db, 'UPDATE public.memories SET citation=$2 WHERE id=$1', [SYNTHETIC.currentId, 'x'.repeat(2_049)]);
  const failure = denied(await client.callTool('memory_get', { memoryId: SYNTHETIC.currentId }), 'capacity_exceeded');
  assert.equal(failure.retryable, true);
});

test('NULL and blank workstream proposals require both exact unclassified grants and replay safely', async (t) => {
  const db = await createBusinessFixtureDatabase();
  t.after(() => db.close());
  const client = ordinaryClient(db);
  for (const memoryId of [SYNTHETIC.unclassifiedId, SYNTHETIC.blankScopeId])
    assert.equal(accepted(await client.callTool('memory_get', { memoryId })).record, null);

  await adminSql(db,
    "INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,'workstream:unclassified','{read,propose}')",
    [SYNTHETIC.alice.principalId]);
  for (const memoryId of [SYNTHETIC.unclassifiedId, SYNTHETIC.blankScopeId])
    assert.equal(accepted(await client.callTool('memory_get', { memoryId })).record, null);

  await adminSql(db,
    "INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,'workstream:unclassified','{read,propose}')",
    [SYNTHETIC.clientA.principalId]);
  for (const [index, memoryId] of [SYNTHETIC.unclassifiedId, SYNTHETIC.blankScopeId].entries()) {
    const before = accepted(await client.callTool('memory_get', { memoryId })).record;
    assert.equal(before.id, memoryId);
    assert.equal(before.workstream, null);
    const proposal = {
      idempotencyKey: `scripted_unclassified_000${index}`, memoryId,
      expectedContentHash: before.version, proposedContent: 'Synthetic sourced unclassified correction.',
      reason: 'Fixture control for the exact stored scope.', citation: 'fixture:unclassified:version-1',
    };
    denied(await client.callTool('memory_propose_change', { ...proposal, workstream: 'operations' }), 'invalid_request');
    const staged = accepted(await client.callTool('memory_propose_change', proposal));
    const replay = accepted(await client.callTool('memory_propose_change', proposal));
    assert.equal(staged.targetId, memoryId);
    assert.equal(staged.status, 'proposed');
    assert.equal(replay.replayed, true);
    assert.equal(replay.proposalId, staged.proposalId);
    assert.equal(replay.requestId, staged.requestId);
    assert.deepEqual(accepted(await client.callTool('memory_get', { memoryId })).record, before);
  }
  await adminSql(db,
    "UPDATE public.capability_grants SET revoked_at=now() WHERE principal_id=$1 AND resource_scope='workstream:unclassified'",
    [SYNTHETIC.clientA.principalId]);
  for (const memoryId of [SYNTHETIC.unclassifiedId, SYNTHETIC.blankScopeId])
    assert.equal(accepted(await client.callTool('memory_get', { memoryId })).record, null);
});
