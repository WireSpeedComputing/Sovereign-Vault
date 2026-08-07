-- tests/sovereign_fixture.sql
--
-- DISPOSABLE FIXTURE SET for the sovereignty export/restore proof (upstream
-- sovereign-memory-core #58). Contains NO real data. Every UUID is a literal,
-- every string is invented, and the whole thing is designed to be thrown away.
--
-- ⚠ NEVER run this against a deployment. It writes to memories, wiki_pages,
--   principals, capability_grants and raw_artifacts. It is meant for a
--   throwaway local cluster created by tests/sovereignty_proof.sh.
--
-- ── WHY A FIXTURE AND NOT A PRODUCTION SLICE ───────────────────────────────
-- #58 allows "a representative, privacy-safe deployment slice OR a
-- deterministic fixture set". A fixture is chosen because a slice cannot be
-- committed (privacy) and therefore cannot be re-run by anyone else, which
-- fails #58's "the proof can be rerun" acceptance criterion. The cost is
-- stated in docs/07: a fixture proves the MECHANISM, not that the deployment's
-- particular data survives a round trip.
--
-- ── WHAT IT DELIBERATELY EXERCISES ─────────────────────────────────────────
-- Each block below exists because verify_restore.sh asserts something about it.
-- A fixture that only contains happy-path rows produces a verifier that only
-- ever sees happy-path values, which is how a check that cannot fail gets
-- shipped.
--
--   lifecycle      proposed / current / superseded / entered_in_error
--                  (NOTE: 'retracted' is NOT produced -- see the gap note at
--                   the bottom of this file. It is a real hole, not an
--                   oversight.)
--   provenance     all four provenance_basis values, with and without citation
--   supersession   a 3-deep memory chain and a 2-deep wiki chain
--   visibility     private and shared rows under two different owners
--   artifacts      one raw_artifact per import_action, including unclassified
--   attention      hot index rows in both 'staged' and 'promoted' states
--   retrieval      projected units + embeddings, one deliberately stale
--   evidence       exact_locator strings for both memories and wiki sections
--   authority      declared scopes, live grants, a revoked grant, a cutover
--
-- Deterministic UUIDs so a failure names the same row every run.

\set ON_ERROR_STOP on
set timezone = 'UTC';
set datestyle = 'ISO, YMD';

-- ══════════════════════════════════════════════════════════════════════════
-- Principals
-- ══════════════════════════════════════════════════════════════════════════
insert into principals (id, kind, display_name, email, agent_label, external_ref, active, notes) values
  ('11111111-0000-4000-8000-000000000001','human','Fixture Founder','founder@fixture.invalid',null,'fixture:sub:founder',true,'disposable fixture principal'),
  ('11111111-0000-4000-8000-000000000002','human','Fixture Reviewer','reviewer@fixture.invalid',null,'fixture:sub:reviewer',true,'disposable fixture principal'),
  ('11111111-0000-4000-8000-000000000003','agent','Fixture Agent',null,'AGENT-FIXTURE','fixture:agent:1',true,'disposable fixture principal'),
  ('11111111-0000-4000-8000-000000000004','service','Fixture Service',null,'SERVICE-FIXTURE','fixture:svc:1',false,'deactivated on purpose: a verifier that never sees an inactive principal cannot prove it filters them');

update principals set deactivated_at = '2026-01-02T00:00:00Z'
 where id = '11111111-0000-4000-8000-000000000004';

-- ══════════════════════════════════════════════════════════════════════════
-- Scopes, grants, cutover  (sql/30 makes resource_scope an FK to scope_registry)
-- ══════════════════════════════════════════════════════════════════════════
insert into scope_registry (scope, kind, identifier, description, declared_by) values
  ('workstream:fixture','workstream','fixture','Disposable fixture workstream','11111111-0000-4000-8000-000000000001'),
  ('workstream:archive','workstream','archive','Retired fixture workstream','11111111-0000-4000-8000-000000000001'),
  ('table:memories','table','memories','The memories relation','11111111-0000-4000-8000-000000000001'),
  ('domain:financial','domain','financial','Consequential financial domain','11111111-0000-4000-8000-000000000001');

update scope_registry set retired_at = '2026-01-02T00:00:00Z' where scope = 'workstream:archive';

insert into capability_grants (id, principal_id, resource_scope, permissions, granted_by, reason) values
  ('22222222-0000-4000-8000-000000000001','11111111-0000-4000-8000-000000000002','workstream:fixture','{read,propose}','11111111-0000-4000-8000-000000000001','reviewer works this stream'),
  ('22222222-0000-4000-8000-000000000002','11111111-0000-4000-8000-000000000003','table:memories','{read}','11111111-0000-4000-8000-000000000001','agent may read'),
  ('22222222-0000-4000-8000-000000000003','11111111-0000-4000-8000-000000000002','domain:financial','{admin}','11111111-0000-4000-8000-000000000001','to be revoked below');

update capability_grants
   set revoked_at = '2026-01-03T00:00:00Z', revoked_by = '11111111-0000-4000-8000-000000000001'
 where id = '22222222-0000-4000-8000-000000000003';

select declare_scope_cutover('workstream:fixture','11111111-0000-4000-8000-000000000001',
  'fixture cutover evidence: package tests/sovereign_fixture.sql','fixture-source-system') \gset cutover_

-- ══════════════════════════════════════════════════════════════════════════
-- Import: batch + one artifact per classification
-- ══════════════════════════════════════════════════════════════════════════
insert into import_batches (id, source_system, description, initiated_by, expected_count, landed_count, completed_at)
values ('33333333-0000-4000-8000-000000000001','fixture-source-system','disposable fixture batch',
        '11111111-0000-4000-8000-000000000001', 5, 5, '2026-01-04T00:00:00Z');

insert into raw_artifacts (id, batch_id, source_system, source_id, payload, payload_sha256, fetched_at, action, zone, action_reason, reviewed_by, reviewed_at) values
  ('44444444-0000-4000-8000-000000000001','33333333-0000-4000-8000-000000000001','fixture-source-system','art-import-1',
   '{"text":"fixture importable artifact","kind":"note"}'::jsonb,
   encode(digest('{"text":"fixture importable artifact","kind":"note"}','sha256'),'hex'),
   '2026-01-04T00:00:00Z','import','vault','classified importable','11111111-0000-4000-8000-000000000001','2026-01-04T00:00:00Z'),
  ('44444444-0000-4000-8000-000000000002','33333333-0000-4000-8000-000000000001','fixture-source-system','art-hold-1',
   '{"text":"fixture held artifact"}'::jsonb,
   encode(digest('{"text":"fixture held artifact"}','sha256'),'hex'),
   '2026-01-04T00:00:00Z','hold','hold','needs owner decision',null,null),
  ('44444444-0000-4000-8000-000000000003','33333333-0000-4000-8000-000000000001','fixture-source-system','art-exclude-1',
   '{"text":"fixture excluded artifact"}'::jsonb,
   encode(digest('{"text":"fixture excluded artifact"}','sha256'),'hex'),
   '2026-01-04T00:00:00Z','exclude','hold','out of scope',null,null),
  ('44444444-0000-4000-8000-000000000004','33333333-0000-4000-8000-000000000001','fixture-source-system','art-evidence-1',
   '{"text":"fixture evidence artifact: a migration transcript"}'::jsonb,
   encode(digest('{"text":"fixture evidence artifact: a migration transcript"}','sha256'),'hex'),
   '2026-01-04T00:00:00Z','evidence','evidence','process record, not knowledge',null,null),
  ('44444444-0000-4000-8000-000000000005','33333333-0000-4000-8000-000000000001','fixture-source-system','art-unclassified-1',
   '{"text":"fixture unclassified artifact"}'::jsonb,
   encode(digest('{"text":"fixture unclassified artifact"}','sha256'),'hex'),
   '2026-01-04T00:00:00Z',null,null,null,null,null);

-- ══════════════════════════════════════════════════════════════════════════
-- Memories
-- ══════════════════════════════════════════════════════════════════════════
-- status='current' is unreachable by direct INSERT (sql/26). Everything lands
-- proposed; promote_memory() is the only door. That is the point of the schema
-- and the fixture must go through it rather than around it.
insert into memories (id, content, workstream, tags, source_kind, source_agent, source_ref,
                      provenance_basis, citation, status, owner, visibility, metadata,
                      observed_at, effective_from, recorded_at) values
  ('55555555-0000-4000-8000-000000000001','Fixture fact A: the founder chose the disposable fixture route.','fixture',
   '{fixture,decision}','manual',null,'fixture:conversation:1','human_direct',null,'proposed',
   '11111111-0000-4000-8000-000000000001','shared','{"fixture":true}'::jsonb,
   '2026-01-01T00:00:00Z','2026-01-05T00:00:00Z','2026-01-05T00:00:00Z'),

  ('55555555-0000-4000-8000-000000000002','Fixture fact B: this row stays proposed forever and must not be counted as authoritative.','fixture',
   '{fixture,unreviewed}','agent','AGENT-FIXTURE','fixture:agent-run:1','decision_record','memory:55555555-0000-4000-8000-000000000001','proposed',
   '11111111-0000-4000-8000-000000000001','shared','{"fixture":true}'::jsonb,
   '2026-01-01T00:00:00Z','2026-01-05T00:00:00Z','2026-01-05T00:00:00Z'),

  ('55555555-0000-4000-8000-000000000003','Fixture fact C: a private row owned by the reviewer, invisible to other principals.','fixture',
   '{fixture,private}','manual',null,'fixture:conversation:2','human_direct',null,'proposed',
   '11111111-0000-4000-8000-000000000002','private','{"fixture":true}'::jsonb,
   '2026-01-01T00:00:00Z','2026-01-05T00:00:00Z','2026-01-05T00:00:00Z'),

  ('55555555-0000-4000-8000-000000000004','Fixture fact D: derived from an artifact classified action=import.','fixture',
   '{fixture,imported}','imported_artifact',null,'fixture-source-system:art-import-1','imported_artifact',
   'raw_artifact:44444444-0000-4000-8000-000000000001','proposed',
   '11111111-0000-4000-8000-000000000001','shared','{"fixture":true}'::jsonb,
   '2026-01-01T00:00:00Z','2026-01-05T00:00:00Z','2026-01-05T00:00:00Z'),

  ('55555555-0000-4000-8000-000000000005','Fixture fact E: this candidate will be rejected and must land at entered_in_error.','fixture',
   '{fixture,rejected}','agent','AGENT-FIXTURE','fixture:agent-run:2','source_document','fixture-doc:spec-v1 s3.2','proposed',
   '11111111-0000-4000-8000-000000000001','shared','{"fixture":true}'::jsonb,
   '2026-01-01T00:00:00Z','2026-01-05T00:00:00Z','2026-01-05T00:00:00Z'),

  ('55555555-0000-4000-8000-000000000006','Fixture fact F: a deadline that is still pending.','fixture',
   '{fixture,deadline}','manual',null,'fixture:conversation:3','human_direct',null,'proposed',
   '11111111-0000-4000-8000-000000000001','shared','{"fixture":true}'::jsonb,
   '2026-01-01T00:00:00Z','2026-01-05T00:00:00Z','2026-01-05T00:00:00Z');

update memories set source_artifact_id = '44444444-0000-4000-8000-000000000001'
 where id = '55555555-0000-4000-8000-000000000004';
update memories set due_date = '2099-01-01T00:00:00Z', due_status = 'pending'
 where id = '55555555-0000-4000-8000-000000000006';

-- Promote four of the six through the sanctioned function.
select promote_memory('55555555-0000-4000-8000-000000000001','11111111-0000-4000-8000-000000000001');
select promote_memory('55555555-0000-4000-8000-000000000003','11111111-0000-4000-8000-000000000001');
select promote_memory('55555555-0000-4000-8000-000000000004','11111111-0000-4000-8000-000000000001');
select promote_memory('55555555-0000-4000-8000-000000000006','11111111-0000-4000-8000-000000000001');

-- Reject one -> entered_in_error, with a receipt.
select reject_memory('55555555-0000-4000-8000-000000000005','11111111-0000-4000-8000-000000000002',
                     'fixture rejection: unverifiable source document');

-- A 3-deep supersession chain off fact A:  A -> A' -> A''
select supersede_memory('55555555-0000-4000-8000-000000000001',
  'Fixture fact A (rev 2): the founder chose the disposable fixture route, recorded with a citation.',
  'decision_record','memory:55555555-0000-4000-8000-000000000001',
  '11111111-0000-4000-8000-000000000001','first correction') \gset chain1_

select supersede_memory(:'chain1_supersede_memory',
  'Fixture fact A (rev 3): final wording of the fixture-route decision.',
  'decision_record','memory:55555555-0000-4000-8000-000000000001',
  '11111111-0000-4000-8000-000000000001','second correction') \gset chain2_

-- ══════════════════════════════════════════════════════════════════════════
-- Wiki pages (+ a 2-deep supersession chain and a blessing)
-- ══════════════════════════════════════════════════════════════════════════
insert into wiki_pages (id, path, title, content, tags, workstream, source_kind, source_ref,
                        provenance_basis, citation, status, owner, visibility, frontmatter,
                        observed_at, effective_from, recorded_at) values
  ('66666666-0000-4000-8000-000000000001','fixture/handbook','Fixture Handbook',
   E'# Fixture Handbook\n\nIntro paragraph for the disposable fixture handbook.\n\n## Section One\n\nFirst section body.\n\n## Section Two\n\nSecond section body.\n',
   '{fixture}','fixture','manual','fixture:file:handbook.md','human_direct',null,'current',
   '11111111-0000-4000-8000-000000000001','shared','{"fixture":true}'::jsonb,
   '2026-01-01T00:00:00Z','2026-01-06T00:00:00Z','2026-01-06T00:00:00Z'),

  ('66666666-0000-4000-8000-000000000002','fixture/private-notes','Fixture Private Notes',
   E'# Fixture Private Notes\n\nOwned by the reviewer and marked private.\n',
   '{fixture,private}','fixture','manual','fixture:file:notes.md','human_direct',null,'current',
   '11111111-0000-4000-8000-000000000002','private','{"fixture":true}'::jsonb,
   '2026-01-01T00:00:00Z','2026-01-06T00:00:00Z','2026-01-06T00:00:00Z');

select supersede_wiki('fixture/handbook','Fixture Handbook (rev 2)',
  E'# Fixture Handbook\n\nRevised intro paragraph.\n\n## Section One\n\nRevised first section body.\n\n## Section Two\n\nSecond section body.\n\n## Section Three\n\nAdded in revision two.\n',
  'decision_record','memory:55555555-0000-4000-8000-000000000001',
  '11111111-0000-4000-8000-000000000001','fixture wiki correction') \gset wikichain_

select bless_doc('fixture/handbook','fixture blessing after revision two');
select bless_doc('fixture/private-notes','fixture blessing');

-- ══════════════════════════════════════════════════════════════════════════
-- Attention layer: one topic staged (single touch), one promoted (two touches)
-- ══════════════════════════════════════════════════════════════════════════
select hot_touch('fixture:topic:staged',   '55555555-0000-4000-8000-000000000004','A topic touched once and therefore only staged','fixture');
select hot_touch('fixture:topic:promoted', '55555555-0000-4000-8000-000000000006','A topic touched twice and therefore promoted','fixture');
select hot_touch('fixture:topic:promoted', '55555555-0000-4000-8000-000000000006','A topic touched twice and therefore promoted','fixture');
select hot_touch('fixture:topic:promoted', '55555555-0000-4000-8000-000000000006','A topic touched twice and therefore promoted','fixture');

-- ══════════════════════════════════════════════════════════════════════════
-- Review queue
-- ══════════════════════════════════════════════════════════════════════════
insert into review_queue (id, kind, incoming_ref, incoming_kind, existing_ref, existing_kind,
                          detail, raised_by, resolution, resolver, resolved_at) values
  ('77777777-0000-4000-8000-000000000001','contradiction','44444444-0000-4000-8000-000000000002','raw_artifact',
   '55555555-0000-4000-8000-000000000003','memory','fixture contradiction awaiting a human',
   '11111111-0000-4000-8000-000000000001','pending',null,null),
  ('77777777-0000-4000-8000-000000000002','stale_state','55555555-0000-4000-8000-000000000002','memory',
   '55555555-0000-4000-8000-000000000001','memory','fixture stale-state probe, already resolved',
   '11111111-0000-4000-8000-000000000001','confirmed','11111111-0000-4000-8000-000000000002','2026-01-07T00:00:00Z'),
  ('77777777-0000-4000-8000-000000000003','low_provenance','44444444-0000-4000-8000-000000000005','raw_artifact',
   null,null,'fixture unclassified artifact needs classification',
   '11111111-0000-4000-8000-000000000001','pending',null,null);

-- ══════════════════════════════════════════════════════════════════════════
-- Retrieval projection + embeddings
-- ══════════════════════════════════════════════════════════════════════════
select * from refresh_retrieval_units();

-- Deterministic pseudo-vectors. These are NOT real embeddings and must never be
-- read as evidence that semantic recall works -- they exist so the restore
-- verifier has vector payloads, unique constraints and staleness states to
-- check. Derived from the unit id so the same fixture always produces the same
-- vector, which is what makes a hash comparison meaningful at all.
insert into retrieval_embeddings (retrieval_unit_id, model_provider, model_name, model_version,
                                  dimensions, embedding, rendered_text_hash, embedded_at)
select ru.id, 'fixture', 'fixture-det', '1', 384,
       ('[' || array_to_string(array(
          select round((((('x'||substr(md5(ru.id::text||':'||g::text),1,8))::bit(32)::bigint) % 2000) / 1000.0)::numeric, 6)::text
          from generate_series(1,384) g), ',') || ']')::vector,
       encode(digest(ru.rendered_text,'sha256'),'hex'),
       '2026-01-08T00:00:00Z'
from retrieval_units ru
where ru.invalidated_at is null
order by ru.id;

-- One embedding deliberately left stale, so the restore verifier sees a
-- non-zero staleness count and cannot pass by reading zero everywhere.
update retrieval_embeddings e set stale_at = '2026-01-09T00:00:00Z'
where e.retrieval_unit_id = (
  select ru.id from retrieval_units ru
  where ru.invalidated_at is null and ru.source_relation = 'wiki_pages'
  order by ru.exact_locator limit 1);

-- ══════════════════════════════════════════════════════════════════════════
-- Source freeze watermark (the "no hidden state in the origin" receipt)
-- ══════════════════════════════════════════════════════════════════════════
insert into source_freeze (id, source_system, batch_id, freeze_mode, frozen_at, actor,
                           source_count, source_max_ts, source_hash, notes)
values ('88888888-0000-4000-8000-000000000001','fixture-source-system',
        '33333333-0000-4000-8000-000000000001','hard_freeze','2026-01-10T00:00:00Z',
        '11111111-0000-4000-8000-000000000001', 5, '2026-01-04T00:00:00Z',
        encode(digest('fixture-source-system:5','sha256'),'hex'),
        'fixture freeze declaration');

-- ══════════════════════════════════════════════════════════════════════════
-- GAPS THIS FIXTURE CANNOT FILL -- read these before trusting a green run
-- ══════════════════════════════════════════════════════════════════════════
-- 1. record_status 'retracted' is never produced. There is no sanctioned
--    function that reaches it: promote_memory -> current, supersede_memory ->
--    superseded, reject_memory -> entered_in_error. The enum value exists with
--    no door into it. verify_restore.sh therefore asserts the distribution it
--    can observe and explicitly records 'retracted' as unexercised rather than
--    quietly asserting a count of zero as if that were a pass.
-- 2. wiki_pages has no promote path (sql/26 Part 1 note), so no proposed wiki
--    row exists to restore. The wiki lifecycle coverage is genuinely narrower
--    than the memory lifecycle coverage.
-- 3. The embeddings are pseudo-random, not model output. Nothing here proves an
--    embedding pipeline survives a restore -- only that vector columns,
--    dimensions, uniqueness and staleness flags do.
-- 4. No vault_auth.principal_identity_bindings rows: a binding requires an
--    issuer/subject pair from a real auth provider, and inventing one would
--    make the fixture look like it proves identity resolution when it does not.
