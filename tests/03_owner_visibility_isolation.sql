-- Owner/visibility isolation test.
-- REQUIRES-DEPLOYMENT: needs real principal ids substituted for :'principal_N'.
-- Written per-principal, run inside a transaction that is always rolled back -- no
-- fixture data is left behind. Assert that each principal's owner-scoped boot surfaces
-- (memory_hot_ranked_for, deadlines_upcoming_for) return their own private rows plus all
-- shared rows, and ZERO rows privately owned by a different principal.
--
-- Requires: visibility_level enum, owner/visibility columns on memories, is_owner_or_shared(),
-- memory_hot_ranked_for(uuid), deadlines_upcoming_for(uuid), hot_touch(). Substitute real
-- principal ids for the three placeholders below when running against a live database.

BEGIN;

-- FIXTURE SETUP, not an authority claim. Since sql/25_propose_then_promote.sql
-- a direct INSERT at status='current' is rejected; this file needs current rows
-- to exist so the owner/visibility surfaces have something to filter, and it is
-- testing isolation, not promotion. Arming the documented transaction guard for
-- the fixture inserts keeps the test focused on what it actually covers. Going
-- through promote_memory() here would additionally require every :principal_N
-- to be an active HUMAN principal, which this test does not otherwise assume.
--
-- That this is possible at all is the documented limit recorded in sql/25 and
-- asserted in tests/23 section D. Fixture convenience here is the same hole a
-- bypasser would use; it is not evidence the guard works.
SET LOCAL app.promoting = 'on';

INSERT INTO memories (id, content, source_kind, provenance_basis, status, owner, visibility)
VALUES
  ('bbbbbbbb-0000-0000-0000-00000000a001', 'principal-1-private test memory', 'manual', 'human_direct', 'current', :'principal_1', 'private'),
  ('bbbbbbbb-0000-0000-0000-00000000a002', 'principal-2-private test memory', 'manual', 'human_direct', 'current', :'principal_2', 'private'),
  ('bbbbbbbb-0000-0000-0000-00000000a003', 'principal-3-private test memory', 'manual', 'human_direct', 'current', :'principal_3', 'private'),
  ('bbbbbbbb-0000-0000-0000-00000000a004', 'shared test memory visible to all', 'manual', 'human_direct', 'current', :'principal_1', 'shared');

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM memories WHERE id::text LIKE 'bbbbbbbb-%' LOOP
    PERFORM hot_touch('isolation-test-' || r.id, r.id, 'iso test summary', 'test');
    PERFORM hot_touch('isolation-test-' || r.id, r.id, 'iso test summary', 'test');
  END LOOP;
END $$;

INSERT INTO memories (id, content, source_kind, provenance_basis, status, owner, visibility, due_date, due_status)
VALUES
  ('bbbbbbbb-0000-0000-0000-00000000b001', 'principal-1-private deadline', 'manual', 'human_direct', 'current', :'principal_1', 'private', now() + interval '2 days', 'pending'),
  ('bbbbbbbb-0000-0000-0000-00000000b002', 'principal-2-private deadline', 'manual', 'human_direct', 'current', :'principal_2', 'private', now() + interval '2 days', 'pending'),
  ('bbbbbbbb-0000-0000-0000-00000000b003', 'principal-3-private deadline', 'manual', 'human_direct', 'current', :'principal_3', 'private', now() + interval '2 days', 'pending'),
  ('bbbbbbbb-0000-0000-0000-00000000b004', 'shared deadline visible to all', 'manual', 'human_direct', 'current', :'principal_1', 'shared', now() + interval '2 days', 'pending');

SET LOCAL app.promoting = 'off';

DO $$
DECLARE
  principals uuid[] := ARRAY[:'principal_1'::uuid, :'principal_2'::uuid, :'principal_3'::uuid];
  p uuid;
  foreign_hot int;
  foreign_deadline int;
  own_hot int;
  shared_hot int;
BEGIN
  FOREACH p IN ARRAY principals LOOP
    SELECT count(*) INTO foreign_hot
    FROM memory_hot_ranked_for(p) hr JOIN memories m ON m.id = hr.memory_id
    WHERE m.owner <> p AND m.visibility = 'private';
    IF foreign_hot <> 0 THEN
      RAISE EXCEPTION 'FAIL: principal % sees % foreign-owner private hot-ranked rows', p, foreign_hot;
    END IF;

    SELECT count(*) INTO foreign_deadline
    FROM deadlines_upcoming_for(p) d JOIN memories m ON m.id = d.id
    WHERE m.owner <> p AND m.visibility = 'private';
    IF foreign_deadline <> 0 THEN
      RAISE EXCEPTION 'FAIL: principal % sees % foreign-owner private deadline rows', p, foreign_deadline;
    END IF;

    SELECT count(*) INTO own_hot FROM memory_hot_ranked_for(p) hr JOIN memories m ON m.id = hr.memory_id
    WHERE m.owner = p AND m.visibility = 'private' AND m.id::text LIKE 'bbbbbbbb-%';
    IF own_hot = 0 THEN
      RAISE EXCEPTION 'FAIL: principal % does not see their own private hot-ranked row', p;
    END IF;

    SELECT count(*) INTO shared_hot FROM memory_hot_ranked_for(p) hr JOIN memories m ON m.id = hr.memory_id
    WHERE m.visibility = 'shared' AND m.id = 'bbbbbbbb-0000-0000-0000-00000000a004';
    IF shared_hot = 0 THEN
      RAISE EXCEPTION 'FAIL: principal % does not see the shared hot-ranked row', p;
    END IF;

    RAISE NOTICE 'PASS: principal % -- own+shared visible, zero foreign-owner private rows', p;
  END LOOP;
END $$;

ROLLBACK;
