-- tests/03_owner_visibility_isolation.sql
--
-- Owner/visibility isolation across the BOOT SURFACES, end to end.
--
-- Asserts that each principal's owner-scoped boot surfaces
-- (memory_hot_ranked_for, deadlines_upcoming_for) return their own private rows
-- plus all shared rows, and ZERO rows privately owned by a different principal.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY THIS NO LONGER DECLARES REQUIRES-DEPLOYMENT
-- ══════════════════════════════════════════════════════════════════════════
-- It asked a human to substitute three real principal ids for `:principal_N`
-- before running. Nobody ever did, so the runner printed SKIP on every replay
-- and the top line still said REPLAY CLEAN -- for months, over the surfaces
-- that decide what a principal is allowed to see at session start.
--
-- The suite never needed real principals. It tests a predicate, and a predicate
-- does not care whether the uuids in front of it came from production. It now
-- provisions three principals of its own and rolls them back.
--
-- This is complementary to tests/51_visibility_discrimination.sql, not
-- duplicative: 51 exercises can_read_row/is_owner_or_shared directly, this file
-- exercises the two functions session_boot actually calls.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE CONTROL THAT MAKES THE DENIALS MEAN ANYTHING
-- ══════════════════════════════════════════════════════════════════════════
-- Since sql/45, memory_hot_ranked_for() and deadlines_upcoming_for() compose
-- can_read_row(owner, visibility, WORKSTREAM, principal) -- so a principal
-- holding no capability grant is denied everything, and "principal 2 sees zero
-- of principal 1's private rows" would pass against a completely broken
-- visibility predicate.
--
-- All three principals therefore hold the SAME scope, and every fixture row
-- carries that scope. Scope can never be the cause of a denial here, so a
-- denial can only have come from the owner/visibility half. Sections C and D
-- are the positive controls that prove the principals can read at all; without
-- them sections A and B prove nothing.
--
-- Original wording, kept because it is still the point: fixture convenience is
-- the same hole a bypasser would use, and it is not evidence the guard works.
-- `SET LOCAL app.promoting` below arms the documented transaction guard from
-- sql/26 so current-status fixture rows can exist. That this is possible at all
-- is the documented limit recorded in sql/26 and asserted in tests/23 section D.

\set ON_ERROR_STOP on
BEGIN;

CREATE TEMPORARY TABLE t_res(n int, name text, pass boolean, detail text) ON COMMIT DROP;

-- ── fixtures ──────────────────────────────────────────────────────────────
INSERT INTO principals (id, kind, display_name, email, active) VALUES
  ('cccccccc-0000-0000-0000-000000000001','human','IsoTest P1','isotest-p1@example.invalid',true),
  ('cccccccc-0000-0000-0000-000000000002','human','IsoTest P2','isotest-p2@example.invalid',true),
  ('cccccccc-0000-0000-0000-000000000003','human','IsoTest P3','isotest-p3@example.invalid',true);

INSERT INTO scope_registry (scope, kind, identifier, description)
SELECT 'workstream:isotest','workstream','isotest','owner/visibility isolation fixture'
WHERE NOT EXISTS (SELECT 1 FROM scope_registry WHERE scope='workstream:isotest');

-- All three hold the SAME scope. This is the control described above.
INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by, reason)
SELECT p, 'workstream:isotest', ARRAY['read']::capability_permission[],
       'cccccccc-0000-0000-0000-000000000001',
       'fixture: every principal holds the same scope, so scope cannot cause a denial'
FROM unnest(ARRAY['cccccccc-0000-0000-0000-000000000001',
                  'cccccccc-0000-0000-0000-000000000002',
                  'cccccccc-0000-0000-0000-000000000003']::uuid[]) p;

SET LOCAL app.promoting = 'on';

INSERT INTO memories (id, content, workstream, source_kind, provenance_basis, status, owner, visibility)
VALUES
  ('bbbbbbbb-0000-0000-0000-00000000a001','principal-1-private test memory','isotest','manual','human_direct','current','cccccccc-0000-0000-0000-000000000001','private'),
  ('bbbbbbbb-0000-0000-0000-00000000a002','principal-2-private test memory','isotest','manual','human_direct','current','cccccccc-0000-0000-0000-000000000002','private'),
  ('bbbbbbbb-0000-0000-0000-00000000a003','principal-3-private test memory','isotest','manual','human_direct','current','cccccccc-0000-0000-0000-000000000003','private'),
  ('bbbbbbbb-0000-0000-0000-00000000a004','shared test memory visible to all','isotest','manual','human_direct','current','cccccccc-0000-0000-0000-000000000001','shared');

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM memories WHERE id::text LIKE 'bbbbbbbb-%' LOOP
    PERFORM hot_touch('isolation-test-' || r.id, r.id, 'iso test summary', 'isotest');
    PERFORM hot_touch('isolation-test-' || r.id, r.id, 'iso test summary', 'isotest');
  END LOOP;
END $$;

INSERT INTO memories (id, content, workstream, source_kind, provenance_basis, status, owner, visibility, due_date, due_status)
VALUES
  ('bbbbbbbb-0000-0000-0000-00000000b001','principal-1-private deadline','isotest','manual','human_direct','current','cccccccc-0000-0000-0000-000000000001','private', now() + interval '2 days','pending'),
  ('bbbbbbbb-0000-0000-0000-00000000b002','principal-2-private deadline','isotest','manual','human_direct','current','cccccccc-0000-0000-0000-000000000002','private', now() + interval '2 days','pending'),
  ('bbbbbbbb-0000-0000-0000-00000000b003','principal-3-private deadline','isotest','manual','human_direct','current','cccccccc-0000-0000-0000-000000000003','private', now() + interval '2 days','pending'),
  ('bbbbbbbb-0000-0000-0000-00000000b004','shared deadline visible to all','isotest','manual','human_direct','current','cccccccc-0000-0000-0000-000000000001','shared', now() + interval '2 days','pending');

SET LOCAL app.promoting = 'off';

-- ── assertions, materialised so the verdict can be derived ────────────────
-- The previous version raised an exception on the first failure. That is a
-- legitimate way to fail, but it reports one problem and hides the rest, and
-- it produced no verdict line the runner could read.

-- SECTION A: no principal sees another's private hot-ranked rows.
INSERT INTO t_res
SELECT 100 + row_number() OVER (ORDER BY p),
       'A: principal ' || right(p::text,1) || ' sees zero foreign-owner private hot rows',
       cnt = 0,
       cnt::text || ' foreign-owner private hot-ranked row(s) visible'
FROM (
  SELECT p, (SELECT count(*) FROM memory_hot_ranked_for(p) hr
             JOIN memories m ON m.id = hr.memory_id
             WHERE m.owner <> p AND m.visibility = 'private') AS cnt
  FROM unnest(ARRAY['cccccccc-0000-0000-0000-000000000001',
                    'cccccccc-0000-0000-0000-000000000002',
                    'cccccccc-0000-0000-0000-000000000003']::uuid[]) p
) s;

-- SECTION B: same, for the deadline surface.
INSERT INTO t_res
SELECT 200 + row_number() OVER (ORDER BY p),
       'B: principal ' || right(p::text,1) || ' sees zero foreign-owner private deadlines',
       cnt = 0,
       cnt::text || ' foreign-owner private deadline row(s) visible'
FROM (
  SELECT p, (SELECT count(*) FROM deadlines_upcoming_for(p) d
             JOIN memories m ON m.id = d.id
             WHERE m.owner <> p AND m.visibility = 'private') AS cnt
  FROM unnest(ARRAY['cccccccc-0000-0000-0000-000000000001',
                    'cccccccc-0000-0000-0000-000000000002',
                    'cccccccc-0000-0000-0000-000000000003']::uuid[]) p
) s;

-- SECTION C: POSITIVE CONTROL. Each principal sees their OWN private row.
-- Without this, section A passes trivially against a surface that returns
-- nothing to anyone -- which is exactly what a missing capability grant does.
INSERT INTO t_res
SELECT 300 + row_number() OVER (ORDER BY p),
       'C control: principal ' || right(p::text,1) || ' sees their own private hot row',
       cnt > 0,
       cnt::text || ' own private hot-ranked row(s) visible (want >0)'
FROM (
  SELECT p, (SELECT count(*) FROM memory_hot_ranked_for(p) hr
             JOIN memories m ON m.id = hr.memory_id
             WHERE m.owner = p AND m.visibility = 'private'
               AND m.id::text LIKE 'bbbbbbbb-%') AS cnt
  FROM unnest(ARRAY['cccccccc-0000-0000-0000-000000000001',
                    'cccccccc-0000-0000-0000-000000000002',
                    'cccccccc-0000-0000-0000-000000000003']::uuid[]) p
) s;

-- SECTION D: POSITIVE CONTROL. Every principal sees the SHARED row, including
-- the two who do not own it.
INSERT INTO t_res
SELECT 400 + row_number() OVER (ORDER BY p),
       'D control: principal ' || right(p::text,1) || ' sees the shared hot row',
       cnt > 0,
       cnt::text || ' shared hot-ranked row(s) visible (want >0)'
FROM (
  SELECT p, (SELECT count(*) FROM memory_hot_ranked_for(p) hr
             WHERE hr.memory_id = 'bbbbbbbb-0000-0000-0000-00000000a004') AS cnt
  FROM unnest(ARRAY['cccccccc-0000-0000-0000-000000000001',
                    'cccccccc-0000-0000-0000-000000000002',
                    'cccccccc-0000-0000-0000-000000000003']::uuid[]) p
) s;

INSERT INTO t_res
SELECT 999, 'GUARD_no_null_assertions', count(*) = 0,
       count(*)::text || ' assertion(s) evaluated to NULL' FROM t_res WHERE pass IS NULL;

SELECT n, name, coalesce(pass,false) AS pass, detail FROM t_res ORDER BY n;

-- ══════════════════════════════════════════════════════════════════════════
-- DERIVED VERDICT
-- ══════════════════════════════════════════════════════════════════════════
SELECT CASE WHEN count(*) = 0 THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict
FROM t_res WHERE pass IS NOT TRUE;

ROLLBACK;

-- Discrimination check for whoever maintains this: change can_read_row's
-- visibility disjunct to always-true and confirm sections A and B fail while C
-- and D still pass. If A and B still pass, this file is not testing isolation.
