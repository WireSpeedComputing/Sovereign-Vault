-- tests/21_transition_custody_and_retrieval.sql
--
-- Run against a FRESH database (see tests/replay_fresh_install.sh) or inside a
-- transaction you roll back. Creates principals and one memory.
--
-- Covers the gap that shipped untested once: the POSITIVE path of the 6-argument
-- supersede_memory. Negative paths (agent actor, unknown principal) were
-- verified on a live deployment, but "a valid human actor succeeds and the actor
-- is recorded" was asserted rather than executed for one session. Do not trust a
-- transition function whose success path has never been run.

BEGIN;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com'),
 ('22222222-2222-2222-2222-222222222222','human','H2','h2@example.com');
INSERT INTO principals (id,kind,display_name,agent_label) VALUES
 ('33333333-3333-3333-3333-333333333333','agent','A1','A1');

-- Lands 'proposed' and reaches 'current' through the human gate. Since
-- sql/26_propose_then_promote.sql, a direct INSERT at 'current' is rejected --
-- this file previously did exactly that, and updating it is part of the fix
-- rather than a workaround for it. The path under test starts from a genuinely
-- promoted row, which is now the only kind there is.
-- Since sql/36 (migration 43), retrieve_context() requires the principal to hold
-- read on the row's workstream scope. These fixtures predate that gate and
-- created rows with no workstream, which map to workstream:unclassified. Without
-- the scope declared and granted, every retrieval assertion below returns zero --
-- correctly, and for a reason that has nothing to do with what they test.
INSERT INTO scope_registry (scope, kind, identifier, description)
VALUES ('workstream:unclassified','workstream','unclassified','Reserved scope for rows with no workstream')
ON CONFLICT (scope) DO NOTHING;
INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by)
SELECT p.id,'workstream:unclassified','{read}'::capability_permission[], p.id
FROM principals p WHERE p.kind='human';

INSERT INTO memories (id,content,source_kind,provenance_basis,status,owner,visibility)
VALUES ('aaaaaaaa-0000-0000-0000-00000000000a','original fact','manual','human_direct',
        'proposed','11111111-1111-1111-1111-111111111111','shared');

SELECT 'promote_precondition' AS test,
  promote_memory('aaaaaaaa-0000-0000-0000-00000000000a',
                 '11111111-1111-1111-1111-111111111111') = 'promoted' AS pass;

-- actor custody, positive path
SELECT 'supersede_returns_id' AS test,
  supersede_memory('aaaaaaaa-0000-0000-0000-00000000000a','corrected fact',
    'decision_record','test citation','11111111-1111-1111-1111-111111111111',
    'positive path') IS NOT NULL AS pass;

SELECT 'old_row_superseded' AS test, status = 'superseded' AS pass
FROM memories WHERE id='aaaaaaaa-0000-0000-0000-00000000000a';

SELECT 'actor_recorded' AS test,
  metadata->>'superseded_by_principal' = '11111111-1111-1111-1111-111111111111' AS pass
FROM memories WHERE id='aaaaaaaa-0000-0000-0000-00000000000a';

-- the audit trail must state what the actor claim actually proves
SELECT 'assurance_labelled' AS test,
  metadata->>'actor_assurance' = 'caller_asserted_unauthenticated' AS pass
FROM memories WHERE id='aaaaaaaa-0000-0000-0000-00000000000a';

SELECT 'successor_links_back' AS test, count(*) = 1 AS pass
FROM memories WHERE supersedes='aaaaaaaa-0000-0000-0000-00000000000a' AND status='current';

-- one live successor only: concurrent supersession must not fork the record
SELECT 'no_forked_successor' AS test, count(*) = 0 AS pass FROM (
  SELECT supersedes FROM memories
  WHERE supersedes IS NOT NULL AND status='current'
  GROUP BY supersedes HAVING count(*) > 1
) x;

-- retrieval, end to end
SELECT * FROM refresh_retrieval_units();

SELECT 'retrieval_finds_successor' AS test,
  (retrieve_context('11111111-1111-1111-1111-111111111111','corrected fact')
     ->>'units_matched')::int >= 1 AS pass;

-- absent an embedding pipeline the receipt must say fts_only, not imply semantic
SELECT 'receipt_reports_fts_only' AS test,
  (retrieve_context('11111111-1111-1111-1111-111111111111','corrected')
     ->>'mode') = 'fts_only' AS pass;

-- an empty query is NOT a clean pass
SELECT 'empty_query_not_evaluated' AS test,
  (retrieve_context('11111111-1111-1111-1111-111111111111','')
     ->>'retrieval_status') = 'not_evaluated' AS pass;

-- a nonsense query IS evaluated, with zero matches: a different outcome
-- retrieval_status gained a third value in migration 42: with advertised stores
-- this runtime cannot query, an evaluated search reports
-- 'evaluated_partial_coverage'. This assertion previously demanded exactly
-- 'evaluated' and broke on apply -- which is the #70 signature-change failure
-- happening to a real caller, in our own suite. Asserted as "was evaluated at
-- all" rather than pinned to one spelling.
SELECT 'nonsense_query_evaluated' AS test,
  (retrieve_context('11111111-1111-1111-1111-111111111111','zzqq nonexistent')
     ->>'retrieval_status') LIKE 'evaluated%' AS pass;

ROLLBACK;

-- Expected: every `pass` column true. A false is a live defect; investigate the
-- function before the test.
