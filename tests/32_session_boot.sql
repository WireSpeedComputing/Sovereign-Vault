-- tests/32_session_boot.sql
-- Covers sql/32_session_boot.sql.
-- ADOPT: sibling protocol repo sovereign-memory-core `session_boot()`, under the
-- contract stated in that repo's issue #72. (The work order cited #3; #3 is
-- closed with no content -- see sql/32's SOURCING NOTE.)
--
-- Run against a FRESH database (tests/replay_fresh_install.sh). Self-contained:
-- creates its own principals and rows, and rolls back.
--
-- ── HOW TO READ A RESULT ────────────────────────────────────────────────────
-- Every `pass` must read TRUE. What TRUE means differs by section:
--
--   A  POSITIVE CONTROLS over guards that predate this file and are known to
--      work. They do not test session_boot at all. If A ever goes false the
--      harness is broken and B/C/D mean nothing.
--   B  FAILING-NEGATIVES. TRUE means the forbidden thing was REJECTED or the
--      leak did NOT occur -- not that an operation succeeded. These assert on
--      the rejection itself, never on the mere absence of a row.
--   C  LEGITIMATE PATH. TRUE means the surface still WORKS for the caller it is
--      meant to serve. A boot function that leaked nothing because it returned
--      nothing would pass every B test and be worthless; C is what stops that.
--   D  DOCUMENTED LIMITS. TRUE means a KNOWN, WRITTEN-DOWN weakness is still
--      present. Reads backwards on purpose. A failing D test is a docs bug: the
--      enforcement story changed and sql/32 now overstates or understates it.
--
-- ── DISCRIMINATION ──────────────────────────────────────────────────────────
-- This file was run against a deliberately broken session_boot -- one whose
-- health counts and hot/deadline blocks omitted the is_owner_or_shared() filter
-- -- to confirm the leak assertions (B4-B8) actually go red. They did. A leak
-- test that cannot detect a leak is decoration. See docs/10.
--
-- ── ON PRIVILEGE CONTEXT ────────────────────────────────────────────────────
-- Runs as superuser, which bypasses RLS. Faithful rather than a cheat, for the
-- reason tests/23 gives: memories and wiki_pages have RLS enabled with ZERO
-- policies and everything revoked from anon/authenticated, so every production
-- write arrives via service_role (BYPASSRLS) or a SECURITY DEFINER function.
-- session_boot is SECURITY DEFINER; its filtering is is_owner_or_shared(), and
-- that is what is under test here. RLS is not load-bearing on this path.

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;

-- ── fixture ────────────────────────────────────────────────────────────────
-- P1 is the booting principal. P2 is the other principal whose private material
-- must never surface. AG1 is an agent principal (agents boot too). P3 is
-- inactive.
INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','P1','p1@example.com'),
 ('22222222-2222-2222-2222-222222222222','human','P2','p2@example.com');
INSERT INTO principals (id,kind,display_name,agent_label) VALUES
 ('33333333-3333-3333-3333-333333333333','agent','AG1','AG1');
INSERT INTO principals (id,kind,display_name,email,active) VALUES
 ('44444444-4444-4444-4444-444444444444','human','P3-inactive','p3@example.com',false);

-- P2's private material. Every canary string is unique so a substring search of
-- the whole envelope is conclusive.
DO $f$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, due_date, due_status)
  VALUES ('CANARY-P2-PRIVATE-MEMORY','manual','human_direct','proposed',
          '22222222-2222-2222-2222-222222222222','private', now() + interval '2 days','pending')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'22222222-2222-2222-2222-222222222222');
  -- put it in the hot index too (two touches promote from staging)
  PERFORM hot_touch('p2/private-topic', v, 'CANARY-P2-PRIVATE-TOPIC-SUMMARY', 'p2ws');
  PERFORM hot_touch('p2/private-topic', v, 'CANARY-P2-PRIVATE-TOPIC-SUMMARY', 'p2ws');
END $f$;

-- P1's own private material -- must BE visible to P1 (this is the C-side).
DO $f$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, due_date, due_status)
  VALUES ('CANARY-P1-OWN-PRIVATE-MEMORY','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','private', now() + interval '3 days','pending')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM hot_touch('p1/own-topic', v, 'CANARY-P1-OWN-TOPIC-SUMMARY', 'p1ws');
  PERFORM hot_touch('p1/own-topic', v, 'CANARY-P1-OWN-TOPIC-SUMMARY', 'p1ws');
END $f$;

-- A shared row owned by P2 -- must be visible to BOTH.
--
-- It carries a due date deliberately. The first draft of this fixture did not,
-- and C4 went red: the envelope surfaces row CONTENT only through hot_topics and
-- deadlines, so a shared row with neither is counted but never rendered, and
-- "is the shared row visible to P1" was unanswerable from the envelope text.
-- The test was wrong, not sql/32 -- recorded here rather than quietly patched,
-- because it is also a real property of the surface: session_boot reports
-- COUNTS over everything visible but renders only what is hot or due.
DO $f$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, due_date, due_status)
  VALUES ('CANARY-SHARED-MEMORY','manual','human_direct','proposed',
          '22222222-2222-2222-2222-222222222222','shared', now() + interval '4 days','pending')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
END $f$;

-- Retrieval projections, so retrieval_units_visible has something to count.
SELECT refresh_retrieval_units();

-- A review_queue row carrying free text that must never appear in any envelope.
INSERT INTO review_queue (kind, detail, raised_by)
VALUES ('contradiction','CANARY-REVIEW-DETAIL-FREE-TEXT','22222222-2222-2222-2222-222222222222');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — POSITIVE CONTROLS over pre-existing guards. All must be TRUE.
-- None of these touch session_boot. They prove the harness can still observe a
-- rejection and that the predicate session_boot delegates to is behaving.
-- ══════════════════════════════════════════════════════════════════════════

-- A1: sql/03 still rejects a missing provenance basis.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, status, owner, visibility)
  VALUES ('control no basis','manual','proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',true,SQLERRM); END $c$;

-- A2: sql/26 still makes status=current unreachable by direct INSERT.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('control direct current','manual','human_direct','current','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_direct_insert_at_current_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_direct_insert_at_current_rejected',true,SQLERRM); END $c$;

-- A3: sql/21's retrieve_context still refuses an inactive principal. This is the
-- admission pattern sql/32 copies; if it stopped rejecting, B3 would be testing
-- a rule that no longer exists anywhere.
DO $c$ BEGIN
  PERFORM retrieve_context('44444444-4444-4444-4444-444444444444','anything');
  INSERT INTO t VALUES ('A','ctl_retrieve_context_rejects_inactive',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_retrieve_context_rejects_inactive',true,SQLERRM); END $c$;

-- A4: sql/31's predicate is TOTAL. session_boot's whole non-leak claim rests on
-- it never returning NULL for an ownerless private row.
INSERT INTO t VALUES ('A','ctl_is_owner_or_shared_is_total',
  (SELECT is_owner_or_shared(NULL,'private','11111111-1111-1111-1111-111111111111') IS FALSE),
  'ownerless+private must be FALSE, not NULL');

-- A5: the predicate genuinely excludes another principal's private row. If this
-- were true for everyone, every B leak test would pass vacuously.
INSERT INTO t VALUES ('A','ctl_predicate_excludes_other_private',
  (SELECT is_owner_or_shared('22222222-2222-2222-2222-222222222222','private',
                             '11111111-1111-1111-1111-111111111111') IS FALSE),
  'P2 private must not be visible to P1');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — FAILING-NEGATIVES. All must be TRUE.
-- B1-B3 assert the REJECTION. B4-B8 assert the LEAK DID NOT HAPPEN, and each
-- one is paired with a C test proving the same block is not simply empty.
-- ══════════════════════════════════════════════════════════════════════════

-- B1: a NULL principal is rejected, not silently treated as "everyone".
DO $c$ BEGIN
  PERFORM session_boot(NULL);
  INSERT INTO t VALUES ('B','b1_null_principal_rejected',false,'returned an envelope for NULL');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('B','b1_null_principal_rejected',true,SQLERRM); END $c$;

-- B2: an unknown principal is rejected, not treated as a new one.
DO $c$ BEGIN
  PERFORM session_boot('99999999-9999-9999-9999-999999999999');
  INSERT INTO t VALUES ('B','b2_unknown_principal_rejected',false,'returned an envelope for an unknown id');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('B','b2_unknown_principal_rejected',true,SQLERRM); END $c$;

-- B3: a DEACTIVATED principal is rejected. Deactivation that still boots is
-- deactivation in name only.
DO $c$ BEGIN
  PERFORM session_boot('44444444-4444-4444-4444-444444444444');
  INSERT INTO t VALUES ('B','b3_inactive_principal_rejected',false,'returned an envelope for an inactive principal');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('B','b3_inactive_principal_rejected',true,SQLERRM); END $c$;

-- B4: P2's private memory CONTENT must not appear anywhere in P1's envelope.
-- Searches the serialized envelope, so it catches a leak through any block,
-- including one added later that this file does not know about.
INSERT INTO t VALUES ('B','b4_no_other_principal_private_content',
  (SELECT session_boot('11111111-1111-1111-1111-111111111111')::text
          NOT LIKE '%CANARY-P2-PRIVATE-MEMORY%'),
  'P2 private memory content absent from P1 envelope');

-- B5: nor through the deadlines block specifically. P2's private row HAS a
-- pending due date inside the 14-day window, so it is a live candidate that the
-- filter must exclude -- not a row that was never eligible.
INSERT INTO t VALUES ('B','b5_deadlines_exclude_other_private',
  (SELECT NOT EXISTS (
     SELECT 1 FROM jsonb_array_elements(
       session_boot('11111111-1111-1111-1111-111111111111')->'deadlines'->'items') d
     WHERE d->>'content' LIKE '%CANARY-P2-PRIVATE-MEMORY%')),
  'P2 private deadline excluded');

-- B6: nor through hot_topics. P2's private topic is in the hot index with a
-- higher-or-equal score than P1's, so it would surface if unfiltered.
INSERT INTO t VALUES ('B','b6_hot_topics_exclude_other_private',
  (SELECT NOT EXISTS (
     SELECT 1 FROM jsonb_array_elements(
       session_boot('11111111-1111-1111-1111-111111111111')->'hot_topics'->'items') h
     WHERE h->>'topic_key' = 'p2/private-topic')),
  'P2 private hot topic excluded');

-- B7: the coordination block must never carry review_queue.detail. That column
-- is free text and review_queue has no owner column to filter it by, which is
-- exactly why sql/32 reports aggregates only.
INSERT INTO t VALUES ('B','b7_coordination_leaks_no_free_text',
  (SELECT session_boot('11111111-1111-1111-1111-111111111111')::text
          NOT LIKE '%CANARY-REVIEW-DETAIL-FREE-TEXT%'),
  'review_queue.detail absent from envelope');

-- B8: the health counts must not count another principal's private rows.
-- P1 can see: their own private row + the shared row = 2. P2's private row is
-- the third current memory and must not be counted. Asserted as an exact number
-- rather than "less than total" -- an off-by-one leak passes an inequality.
INSERT INTO t VALUES ('B','b8_health_counts_exclude_other_private',
  (SELECT (session_boot('11111111-1111-1111-1111-111111111111')
           ->'health'->>'memories_current_visible')::int = 2),
  'expected exactly 2 current memories visible to P1 (own private + shared)');

-- B9: same for the retrieval unit count, which is a separate table with its own
-- owner/visibility copy and its own documented drift history (sql/27).
INSERT INTO t VALUES ('B','b9_retrieval_count_excludes_other_private',
  (SELECT (session_boot('11111111-1111-1111-1111-111111111111')
           ->'health'->>'retrieval_units_visible')::int = 2),
  'expected exactly 2 retrieval units visible to P1');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — LEGITIMATE PATH. All must be TRUE.
-- A filter that hides everything would pass all of Section B. These prove the
-- surface still serves the principal it exists for.
-- ══════════════════════════════════════════════════════════════════════════

-- C1: P1 DOES see their own private memory. Pairs with B4.
INSERT INTO t VALUES ('C','c1_own_private_content_is_visible',
  (SELECT session_boot('11111111-1111-1111-1111-111111111111')::text
          LIKE '%CANARY-P1-OWN-PRIVATE-MEMORY%'),
  'P1 sees their own private row');

-- C2: P1 DOES see their own deadline. Pairs with B5 -- proves the deadlines
-- block is filtered, not merely empty.
INSERT INTO t VALUES ('C','c2_own_deadline_is_visible',
  (SELECT EXISTS (
     SELECT 1 FROM jsonb_array_elements(
       session_boot('11111111-1111-1111-1111-111111111111')->'deadlines'->'items') d
     WHERE d->>'content' LIKE '%CANARY-P1-OWN-PRIVATE-MEMORY%')),
  'P1 own deadline present');

-- C3: P1 DOES see their own hot topic. Pairs with B6.
INSERT INTO t VALUES ('C','c3_own_hot_topic_is_visible',
  (SELECT EXISTS (
     SELECT 1 FROM jsonb_array_elements(
       session_boot('11111111-1111-1111-1111-111111111111')->'hot_topics'->'items') h
     WHERE h->>'topic_key' = 'p1/own-topic')),
  'P1 own hot topic present');

-- C4: a SHARED row owned by P2 is visible to P1. Without this, "no leak" could
-- be achieved by scoping on owner alone and discarding the shared half of the
-- model.
INSERT INTO t VALUES ('C','c4_shared_row_crosses_principals',
  (SELECT session_boot('11111111-1111-1111-1111-111111111111')::text
          LIKE '%CANARY-SHARED-MEMORY%'
      AND session_boot('22222222-2222-2222-2222-222222222222')::text
          LIKE '%CANARY-SHARED-MEMORY%'),
  'shared row visible to both principals');

-- C5: the symmetric direction. P2 sees their own private row; the filter is not
-- "P1 sees everything, everyone else sees nothing".
INSERT INTO t VALUES ('C','c5_symmetric_p2_sees_own_private',
  (SELECT session_boot('22222222-2222-2222-2222-222222222222')::text
          LIKE '%CANARY-P2-PRIVATE-MEMORY%'
      AND session_boot('22222222-2222-2222-2222-222222222222')::text
          NOT LIKE '%CANARY-P1-OWN-PRIVATE-MEMORY%'),
  'P2 sees own private, not P1 private');

-- C6: an AGENT principal can boot. Agents are the primary caller; a boot surface
-- that only humans could call would be useless in practice.
INSERT INTO t VALUES ('C','c6_agent_principal_can_boot',
  (SELECT session_boot('33333333-3333-3333-3333-333333333333')
          ->>'principal_kind' = 'agent'),
  'agent principal boots and is reported as kind=agent');

-- C7: the envelope declares its shape. #72 requirement 2 asks for deterministic
-- fields with an explicit schema version.
INSERT INTO t VALUES ('C','c7_envelope_has_declared_shape',
  (SELECT session_boot('11111111-1111-1111-1111-111111111111') ?& ARRAY[
     'boot_schema_version','principal_id','principal_kind','booted_at',
     'hot_topics','deadlines','coordination','instruction_integrity',
     'contract','health','degraded','degraded_reasons']),
  'all declared top-level keys present');

-- C8: every content block carries an explicit coverage state. This is the whole
-- point of #72 requirement 2 -- "queried and empty" must be distinguishable from
-- "not queried". Asserted as an exact set so a block added later without a
-- coverage state fails here.
INSERT INTO t VALUES ('C','c8_every_block_declares_coverage',
  (SELECT bool_and(session_boot('11111111-1111-1111-1111-111111111111')
                   ->blk->>'coverage' IS NOT NULL)
   FROM unnest(ARRAY['hot_topics','deadlines','coordination',
                     'instruction_integrity','health']) AS blk),
  'no block reports its contents without reporting its coverage');

-- C9: the coordination block is honest that it is NOT principal-scoped, rather
-- than implying it was filtered.
INSERT INTO t VALUES ('C','c9_coordination_admits_it_is_unscoped',
  (SELECT session_boot('11111111-1111-1111-1111-111111111111')
          ->'coordination'->>'coverage' = 'unscoped'),
  'coordination declares coverage=unscoped');

-- C10: the coordination block still reports something useful -- the open count
-- and an age. #72 requirement 4 asks for age/blocking metadata, and honesty
-- about scope is not a licence to return nothing.
INSERT INTO t VALUES ('C','c10_coordination_reports_count_and_age',
  (SELECT (session_boot('11111111-1111-1111-1111-111111111111')
           ->'coordination'->>'open_count')::int = 1
      AND (session_boot('11111111-1111-1111-1111-111111111111')
           ->'coordination'->>'oldest_open_age_days') IS NOT NULL),
  'open review counted with an age');

-- C11: `degraded` is COMPUTED, not a constant. Nothing has blessed the
-- instruction doc, so boot must say so.
INSERT INTO t VALUES ('C','c11_degraded_flags_unblessed_instructions',
  (SELECT (session_boot('11111111-1111-1111-1111-111111111111')->>'degraded')::boolean IS TRUE
      AND session_boot('11111111-1111-1111-1111-111111111111')
          ->'degraded_reasons' @> '["instruction_integrity=no-blessing"]'::jsonb),
  'unblessed instructions reported as degraded');

-- C12: and it CHANGES when the underlying fact changes. A hardcoded `degraded`
-- would pass C11 and fail here. This is the test that makes C11 mean anything.
DO $c$ DECLARE v_before jsonb; v_after jsonb; BEGIN
  v_before := session_boot('11111111-1111-1111-1111-111111111111');
  INSERT INTO wiki_pages (path,title,content,source_kind,provenance_basis,citation,
                          status,owner,visibility)
  VALUES ('_system/ai-instructions','AI Operating Instructions','contract body here',
          'manual','human_direct','operator','current',
          '11111111-1111-1111-1111-111111111111','shared');
  PERFORM bless_doc('_system/ai-instructions','test blessing');
  v_after := session_boot('11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('C','c12_instruction_state_is_computed_not_constant',
    (v_before->'instruction_integrity'->>'state' = 'no-blessing'
     AND v_after->'instruction_integrity'->>'state' = 'match'
     AND NOT (v_after->'degraded_reasons' @> '["instruction_integrity=no-blessing"]'::jsonb)),
    'no-blessing -> match after bless_doc');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c12_instruction_state_is_computed_not_constant',false,SQLERRM); END $c$;

-- C13: the contract block reconciles with docs/08 rather than contradicting it.
-- agent_contract() is PROPOSED there and does not exist, so boot must report
-- 'not_implemented' -- never a synthesized contract answer.
INSERT INTO t VALUES ('C','c13_contract_block_defers_to_docs08',
  (SELECT session_boot('11111111-1111-1111-1111-111111111111')->'contract'->>'state'
            = 'not_implemented'
      AND session_boot('11111111-1111-1111-1111-111111111111')->'contract'->>'surface'
            = 'public.agent_contract()'
      AND session_boot('11111111-1111-1111-1111-111111111111')->'contract'->'embedded'
            = 'null'::jsonb),
  'contract delegated to the docs/08 surface, not invented here');

-- C14: session_boot must NOT be reachable by anon/authenticated, and must not
-- have quietly acquired a perimeter_exception. docs/08 lines 389-401 argue an
-- exception must be argued for on its own terms; sql/32 declares none.
INSERT INTO t VALUES ('C','c14_boot_is_not_exposed_at_the_perimeter',
  (SELECT NOT EXISTS (
     SELECT 1 FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname='public'
     CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) acl
     WHERE p.proname='session_boot'
       AND acl.privilege_type='EXECUTE'
       AND acl.grantee::regrole::text IN ('anon','authenticated','-'))
   AND NOT EXISTS (
     SELECT 1 FROM perimeter_exception
     WHERE object_identity LIKE '%session_boot%')),
  'no EXECUTE for anon/authenticated/PUBLIC and no declared exception');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION D — DOCUMENTED LIMITS. TRUE means the known limit is still present.
-- Read sql/32's header before concluding anything from these.
-- ══════════════════════════════════════════════════════════════════════════

-- D1: coordination counts are deployment-wide. The review_queue row above was
-- raised BY P2 and is counted in P1's boot. That is the documented consequence
-- of review_queue having no owner column, and it is asserted so the day someone
-- adds one, this goes red and the header stops being true.
INSERT INTO t VALUES ('D','limit_coordination_counts_are_deployment_wide',
  (SELECT (session_boot('11111111-1111-1111-1111-111111111111')
           ->'coordination'->>'open_count')::int
        = (SELECT count(*) FROM review_queue WHERE resolution='pending')),
  'KNOWN LIMIT: P1 is shown a count that includes another principal''s items');


-- ── Results ────────────────────────────────────────────────────────────────
SELECT section, test, pass, left(detail,72) AS detail FROM t ORDER BY section, test;

SELECT 'A_controls' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed' AS detail
FROM t WHERE section='A'
UNION ALL
SELECT 'B_boot_rejects_and_does_not_leak', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' LEAKED or accepted'
FROM t WHERE section='B'
UNION ALL
SELECT 'C_legitimate_path_still_works', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed'
FROM t WHERE section='C'
UNION ALL
SELECT 'D_documented_limits_still_present', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' changed -- update sql/32'
FROM t WHERE section='D';

-- ── GUARD: an assertion that evaluated to NULL is NOT a pass ───────────────
-- Copied from tests/23 deliberately. A jsonb key that does not exist yields NULL
-- from ->>, so `(... ->> 'k') = 'v'` is NULL rather than false; bool_and()
-- IGNORES nulls, count(*) FILTER (WHERE NOT pass) counts zero, and the replay
-- runner greps for '| f' and sees a blank column. This file is FULL of ->>
-- comparisons, which is exactly the shape that produced 21 of 24 phantom passes
-- against a function that lacked the feature entirely. Any NULL here is a broken
-- assertion, not a passing one.
SELECT 'GUARD_no_null_assertions' AS summary,
       coalesce(bool_and(pass IS NOT NULL), true) AS pass,
       count(*) FILTER (WHERE pass IS NULL)::text||' assertion(s) evaluated to NULL' AS detail
FROM t;

-- ── EXPLICIT VERDICT ──────────────────────────────────────────────────────
-- The runner reads THIS line, not the formatted rows above.
SELECT CASE WHEN bool_and(coalesce(pass,false)) THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict FROM t;

ROLLBACK;
