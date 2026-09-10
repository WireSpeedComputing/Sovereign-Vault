-- Tests for pending/B_retrieval_topology_ISSUE72.sql (Parts 1 and 2).
--
-- In pending/ because B is not applied; tests/ runs against sql/ only. Move
-- both together.
--
-- Run: fresh replay, then B, then this file. Every `pass` must be true.
--
-- ── WHAT THIS IS TRYING TO CATCH ───────────────────────────────────────────
-- The defect #72 describes is not a wrong number. units_matched=0 was always
-- accurate. The defect is that an accurate local number was rendered in a way
-- that reads as a global claim. So the assertions below are mostly about
-- DISTINGUISHABILITY: can a caller tell "we searched everything and found
-- nothing" from "we searched what we could reach and found nothing"?
--
-- A test that merely checked units_matched=0 would pass against the broken
-- version and prove nothing. Several of these are written specifically so they
-- would FAIL against the pre-Part-2 function.

BEGIN;

CREATE TEMP TABLE t(test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com'),
 ('22222222-2222-2222-2222-222222222222','human','H2','h2@example.com');

-- Since sql/36 (migration 43) retrieve_context() is scope-gated, and these rows
-- carry no workstream, so they map to workstream:unclassified. Without the scope
-- declared and granted every assertion below reads not_evaluated -- correctly,
-- and for a reason unrelated to topology.
INSERT INTO scope_registry (scope, kind, identifier, description)
VALUES ('workstream:unclassified','workstream','unclassified','Reserved scope for rows with no workstream')
ON CONFLICT (scope) DO NOTHING;
INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by)
SELECT p.id,'workstream:unclassified','{read}'::capability_permission[], p.id
FROM principals p WHERE p.kind='human';

-- one visible, matchable memory
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('zzalpha supplier terms renegotiated','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM refresh_retrieval_units();
END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — the core #72 requirement: a miss is not a global negative
-- ══════════════════════════════════════════════════════════════════════════

-- A1: a local MISS under incomplete coverage must NOT say 'evaluated'.
-- This is the assertion that fails against the old function, which returned
-- 'evaluated' here and thereby claimed more than it searched.
INSERT INTO t SELECT 'a1_miss_under_partial_coverage_is_not_plain_evaluated',
  (retrieve_context('11111111-1111-1111-1111-111111111111','zznonexistentterm')
     ->>'retrieval_status') = 'evaluated_partial_coverage',
  'status = '||(retrieve_context('11111111-1111-1111-1111-111111111111','zznonexistentterm')->>'retrieval_status');

-- A2: and it says WHY, in a field a human reads
INSERT INTO t SELECT 'a2_miss_states_the_reason',
  (retrieve_context('11111111-1111-1111-1111-111111111111','zznonexistentterm')
     ->>'reason') = 'one_or_more_advertised_stores_not_queried',
  'reason names the unqueried stores rather than implying absence';

-- A3: a HIT under incomplete coverage is ALSO partial. Finding something here
-- is not evidence that nothing more exists elsewhere. A status that flipped to
-- 'evaluated' on a hit would teach callers that a hit means full coverage.
INSERT INTO t SELECT 'a3_hit_under_partial_coverage_is_still_partial',
  (retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha supplier')
     ->>'retrieval_status') = 'evaluated_partial_coverage'
  AND (retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha supplier')
     ->>'units_matched')::int >= 1,
  'matched, and still not claiming completeness';

-- A4: with FULL coverage the status is plain 'evaluated' -- the distinction is
-- real, not a constant. Without this, A1 could pass because the function always
-- returns partial regardless of topology.
DO $c$ BEGIN
  UPDATE retrieval_topology SET queryable_by_this_runtime = true WHERE status='current';
  INSERT INTO t VALUES ('a4_full_coverage_reports_plain_evaluated',
    (retrieve_context('11111111-1111-1111-1111-111111111111','zznonexistentterm')
       ->>'retrieval_status') = 'evaluated',
    'all stores queryable -> evaluated');
  INSERT INTO t VALUES ('a4b_full_coverage_sets_global_completeness',
    (retrieve_context('11111111-1111-1111-1111-111111111111','zznonexistentterm')
       ->>'global_completeness')::boolean,
    'global_completeness true only when every store is reachable');
  UPDATE retrieval_topology SET queryable_by_this_runtime = false
   WHERE store_key <> 'local-knowledge-store' AND status='current';
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('a4_full_coverage_reports_plain_evaluated',false,SQLERRM); END $c$;

-- A5: not_evaluated still wins over coverage. An empty query searched nothing,
-- and calling that 'partial coverage' would imply a search happened.
INSERT INTO t SELECT 'a5_empty_query_is_not_evaluated_not_partial',
  (retrieve_context('11111111-1111-1111-1111-111111111111','')
     ->>'retrieval_status') = 'not_evaluated',
  'precedence: nothing searched outranks incomplete coverage';


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — topology surface and coverage vocabulary
-- ══════════════════════════════════════════════════════════════════════════

INSERT INTO t SELECT 'b1_topology_lists_every_current_store',
  jsonb_array_length(retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')
    ->'topology'->'stores') = (select count(*) from retrieval_topology where status='current'),
  'one entry per current store';

INSERT INTO t SELECT 'b2_topology_carries_a_schema_version',
  (retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')
     ->'topology'->>'schema_version') IS NOT NULL,
  '#72 requires an explicit schema/version on the boot surface';

INSERT INTO t SELECT 'b3_unqueried_stores_is_populated_not_assumed_empty',
  jsonb_array_length(retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')
    ->'unqueried_stores') = 3,
  'the three non-queryable seed stores are named';

-- b4: the local store's coverage is per-call, not static. An empty query
-- queried nothing, so the local store must say not_queried even though its
-- default is 'queried'.
INSERT INTO t SELECT 'b4_local_coverage_reflects_this_call',
  (select s->>'coverage_state' from jsonb_array_elements(
     retrieve_context('11111111-1111-1111-1111-111111111111','')->'topology'->'stores') s
   where s->>'store_key'='local-knowledge-store') = 'not_queried',
  'empty query -> local store not_queried, despite default_coverage_state=queried';

INSERT INTO t SELECT 'b4b_local_coverage_is_queried_when_it_was',
  (select s->>'coverage_state' from jsonb_array_elements(
     retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')->'topology'->'stores') s
   where s->>'store_key'='local-knowledge-store') = 'queried',
  'real query -> queried';

-- b5: the four-state vocabulary survives to the envelope rather than collapsing
-- to a boolean. #72 item 2 requires queried/not_queried/unreachable/unknown.
INSERT INTO t SELECT 'b5_coverage_vocabulary_is_not_collapsed',
  (select s->>'coverage_state' from jsonb_array_elements(
     retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')->'topology'->'stores') s
   where s->>'store_key'='document-corpus') = 'unknown',
  'unknown is distinguishable from not_queried';

-- b6: an unreachable peer must be reported as unreachable and must NOT make the
-- local store unavailable. #72 item 3: fail closed without losing read-only
-- recovery.
DO $c$ BEGIN
  INSERT INTO retrieval_topology (store_key, store_role, queryable_by_this_runtime,
                                  default_coverage_state, notes)
  VALUES ('downed-peer','peer',false,'unreachable','simulated outage');
  INSERT INTO t VALUES ('b6_unreachable_peer_reported',
    (select s->>'coverage_state' from jsonb_array_elements(
       retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')->'topology'->'stores') s
     where s->>'store_key'='downed-peer') = 'unreachable',
    'peer outage is visible, not silent');
  INSERT INTO t VALUES ('b6b_unreachable_peer_does_not_break_local_read',
    (retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha supplier')
       ->>'units_matched')::int >= 1,
    'local store still serves reads while a peer is down');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('b6_unreachable_peer_reported',false,SQLERRM); END $c$;

-- b7: no topology configured at all must behave exactly as the system does
-- today. An empty table is the absence of a claim, not a claim of completeness.
DO $c$ BEGIN
  UPDATE retrieval_topology SET status='superseded' WHERE status='current';
  INSERT INTO t VALUES ('b7_no_topology_configured_behaves_as_before',
    (retrieve_context('11111111-1111-1111-1111-111111111111','zznonexistentterm')
       ->>'retrieval_status') = 'evaluated'
    AND jsonb_array_length(retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')
       ->'topology'->'stores') = 0,
    'empty topology -> plain evaluated, empty store list, no crash');
  UPDATE retrieval_topology SET status='current' WHERE status='superseded';
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('b7_no_topology_configured_behaves_as_before',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — disclosure. #72 item 4.
-- ══════════════════════════════════════════════════════════════════════════

-- c1: notes describe what each store IS ("separate runtime holding coordination
-- traffic") -- deployment intelligence, not routing a caller needs. It must
-- never appear in the envelope. Asserted rather than left to reviewer
-- vigilance, because a later `select *` refactor is how such a field escapes.
INSERT INTO t SELECT 'c1_notes_never_reach_the_envelope',
  retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')::text
    NOT LIKE '%coordination traffic%'
  AND retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')::text
    NOT LIKE '%predecessor store%',
  'no notes text anywhere in the serialized envelope';

INSERT INTO t SELECT 'c1b_no_notes_key_in_any_store_entry',
  NOT EXISTS (select 1 from jsonb_array_elements(
      retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')->'topology'->'stores') s
    where s ? 'notes'),
  'store entries expose store_key/store_role/coverage_state only';

-- c2: topology is identical for a principal with no visible units. Topology
-- must not become an oracle for what another principal can see.
INSERT INTO t SELECT 'c2_topology_does_not_vary_by_principal_visibility',
  (retrieve_context('22222222-2222-2222-2222-222222222222','zzalpha')->'topology')
  = (retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha')->'topology'),
  'same topology regardless of what the caller can read';


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION D — the pre-existing envelope contract must not regress
-- ══════════════════════════════════════════════════════════════════════════
-- Part 2 rewrites the whole function. These are the properties sql/21 and
-- tests/21 established, re-asserted here so a rewrite cannot quietly drop one.

INSERT INTO t SELECT 'd1_hit_still_returns_results',
  jsonb_array_length(retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha supplier')
    ->'results') >= 1, 'results array still populated';

INSERT INTO t SELECT 'd2_mode_still_reports_fts_only',
  (retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha supplier')
     ->>'mode') = 'fts_only',
  'absent an embedding pipeline the receipt must not imply semantic recall';

INSERT INTO t SELECT 'd3_units_visible_still_reported',
  (retrieve_context('11111111-1111-1111-1111-111111111111','zzalpha supplier')
     ->>'units_visible')::int >= 1, 'visibility accounting intact';

INSERT INTO t SELECT 'd4_nonsense_query_is_evaluated_with_zero_matches',
  (retrieve_context('11111111-1111-1111-1111-111111111111','zzqq nonexistent')
     ->>'units_matched')::int = 0, 'a nonsense query is searched, not skipped';

INSERT INTO t SELECT 'd5_inactive_principal_still_rejected',
  NOT EXISTS (select 1 from principals where id='99999999-9999-9999-9999-999999999999'),
  'precondition for d5b';

DO $c$ BEGIN
  PERFORM retrieve_context('99999999-9999-9999-9999-999999999999','zzalpha');
  INSERT INTO t VALUES ('d5b_unknown_principal_raises',false,'accepted an unknown principal');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('d5b_unknown_principal_raises',true,SQLERRM); END $c$;


SELECT test, pass, left(detail,66) AS detail FROM t ORDER BY test;
SELECT 'ALL' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed' AS detail FROM t;

-- ── GUARD: an assertion that evaluated to NULL is NOT a pass ───────────────
-- Added after a discrimination run exposed this at every layer. A jsonb key
-- that does not exist yields NULL from ->>, so `(... ->> 'k') = 'v'` is NULL
-- rather than false; bool_and() IGNORES nulls, count(*) FILTER (WHERE NOT pass)
-- counts zero, and the replay runner greps for '| f' and sees a blank column.
-- 21 of 24 assertions in one file "passed" against a function that lacked the
-- feature entirely. Any NULL here is a broken assertion, not a passing one.
SELECT 'GUARD_no_null_assertions' AS summary,
       coalesce(bool_and(pass IS NOT NULL), true) AS pass,
       count(*) FILTER (WHERE pass IS NULL)::text||' assertion(s) evaluated to NULL' AS detail
FROM t;

-- ── EXPLICIT VERDICT ──────────────────────────────────────────────────────
-- The runner reads THIS line, not the formatted rows above. Grepping output
-- for '| f |' was wrong in both directions: it missed assertions that
-- evaluated to NULL (blank cell), and it invented failures in files that
-- legitimately print boolean `actual`/`expected` data columns. A test suite
-- must state its own verdict rather than have one inferred from its table
-- formatting.
SELECT CASE WHEN bool_and(coalesce(pass,false)) THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict FROM t;

ROLLBACK;
