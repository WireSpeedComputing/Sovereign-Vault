-- tests/59_supersede_by_existing.sql
--
-- WO-19 Task D. Proves the operation works AND that it refuses the shapes that
-- would make supersession meaningless.
--
-- The refusals matter more than the happy path here. A supersession function
-- that accepts a cycle, a self-reference, or a retired successor produces data
-- that LOOKS structured and resolves to nothing -- strictly worse than the
-- English prose it replaces, because prose at least reads as a warning.

\set ON_ERROR_STOP on
BEGIN;

CREATE TEMPORARY TABLE t_res(n int, name text, pass boolean, detail text) ON COMMIT DROP;
CREATE TEMPORARY TABLE t_id(k text primary key, v uuid) ON COMMIT DROP;
INSERT INTO t_id(k,v) SELECT k, gen_random_uuid()
FROM unnest(ARRAY['human','agent','old_a','old_b','successor','other']) k;
CREATE OR REPLACE FUNCTION pg_temp.id(text) RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT v FROM t_id WHERE k = $1 $$;

INSERT INTO principals(id,kind,display_name,active) VALUES
  (pg_temp.id('human'),'human','suite59 human',true),
  (pg_temp.id('agent'),'agent','suite59 agent',true);

SET LOCAL app.promoting = 'on';
INSERT INTO memories (id, content, workstream, source_kind, provenance_basis, status)
VALUES
  (pg_temp.id('old_a'),'SUPERSEDED: obsolete record A','suite59','manual','human_direct','current'),
  (pg_temp.id('old_b'),'SUPERSEDED: obsolete record B','suite59','manual','human_direct','current'),
  (pg_temp.id('successor'),'The authoritative record','suite59','manual','human_direct','current'),
  (pg_temp.id('other'),'An unrelated current record','suite59','manual','human_direct','current');
SET LOCAL app.promoting = 'off';

-- ── A: the detector finds the prose workaround ────────────────────────────
INSERT INTO t_res
SELECT 1, 'A: detector finds content-level supersession suspects',
       (SELECT count(*) FROM content_level_supersession_suspects()
         WHERE id IN (pg_temp.id('old_a'), pg_temp.id('old_b'))) = 2,
       (SELECT count(*)::text FROM content_level_supersession_suspects()) || ' suspect(s) total';

-- CONTROL: a record that MENTIONS supersession without announcing its own
-- obsolescence must NOT be flagged. The real authoritative pricing row says
-- "supersedes all prior pricing records"; flagging it would retire the live one.
INSERT INTO t_res
SELECT 2, 'A control: a record that merely MENTIONS supersession is not flagged',
       (SELECT count(*) FROM content_level_supersession_suspects()
         WHERE id = pg_temp.id('successor')) = 0,
       'authoritative record must not appear as a suspect';

-- ── B: refusals ───────────────────────────────────────────────────────────
DO $c$ BEGIN
  PERFORM supersede_memory_by_existing(pg_temp.id('old_a'), pg_temp.id('old_a'),
                                       pg_temp.id('human'), 'self');
  INSERT INTO t_res VALUES (10,'B: self-supersession is refused',false,'ACCEPTED');
EXCEPTION WHEN others THEN
  INSERT INTO t_res VALUES (10,'B: self-supersession is refused',true,left(SQLERRM,60));
END $c$;

DO $c$ BEGIN
  PERFORM supersede_memory_by_existing(pg_temp.id('old_a'), pg_temp.id('successor'),
                                       pg_temp.id('human'), NULL);
  INSERT INTO t_res VALUES (11,'B: a missing reason is refused',false,'ACCEPTED');
EXCEPTION WHEN others THEN
  INSERT INTO t_res VALUES (11,'B: a missing reason is refused',true,left(SQLERRM,60));
END $c$;

DO $c$ BEGIN
  PERFORM supersede_memory_by_existing(pg_temp.id('old_a'), pg_temp.id('successor'),
                                       pg_temp.id('agent'), 'agent tries it');
  INSERT INTO t_res VALUES (12,'B: an AGENT principal is refused',false,'ACCEPTED');
EXCEPTION WHEN others THEN
  INSERT INTO t_res VALUES (12,'B: an AGENT principal is refused',true,left(SQLERRM,60));
END $c$;

-- ── C: the happy path, twice, onto ONE successor ──────────────────────────
-- The arity that `supersedes` (a single uuid on the successor) cannot express,
-- and the reason this migration adds a column rather than a function alone.
INSERT INTO t_res
SELECT 20, 'C: first record retires into the existing successor',
       supersede_memory_by_existing(pg_temp.id('old_a'), pg_temp.id('successor'),
         pg_temp.id('human'), 'obsolete ownership record, successor already existed')
         LIKE 'superseded by existing record%',
       'first call';

INSERT INTO t_res
SELECT 21, 'C: a SECOND record retires into the SAME successor',
       supersede_memory_by_existing(pg_temp.id('old_b'), pg_temp.id('successor'),
         pg_temp.id('human'), 'second obsolete ownership record, same successor')
         LIKE 'superseded by existing record%',
       'many-to-one is the whole point';

INSERT INTO t_res
SELECT 22, 'C: both are now status=superseded',
       (SELECT count(*) FROM memories
         WHERE id IN (pg_temp.id('old_a'), pg_temp.id('old_b')) AND status = 'superseded') = 2,
       (SELECT string_agg(status::text, ',') FROM memories
         WHERE id IN (pg_temp.id('old_a'), pg_temp.id('old_b')));

INSERT INTO t_res
SELECT 23, 'C: the detector no longer reports them',
       (SELECT count(*) FROM content_level_supersession_suspects()
         WHERE id IN (pg_temp.id('old_a'), pg_temp.id('old_b'))) = 0,
       'retired rows drop out because the detector keys on status=current';

INSERT INTO t_res
SELECT 24, 'C: memory_successor resolves both to the authoritative record',
       memory_successor(pg_temp.id('old_a')) = pg_temp.id('successor')
       AND memory_successor(pg_temp.id('old_b')) = pg_temp.id('successor'),
       'resolution from either predecessor';

INSERT INTO t_res
SELECT 25, 'C: the reason is recorded, not just the link',
       (SELECT metadata->>'supersede_reason' FROM memories WHERE id = pg_temp.id('old_a'))
         IS NOT NULL,
       coalesce((SELECT left(metadata->>'supersede_reason',40) FROM memories
                 WHERE id = pg_temp.id('old_a')),'NULL');

-- ── D: refusals that only exist once something is retired ─────────────────
DO $c$ BEGIN
  PERFORM supersede_memory_by_existing(pg_temp.id('other'), pg_temp.id('old_a'),
                                       pg_temp.id('human'), 'into a retired successor');
  INSERT INTO t_res VALUES (30,'D: a NON-CURRENT successor is refused',false,'ACCEPTED');
EXCEPTION WHEN others THEN
  INSERT INTO t_res VALUES (30,'D: a NON-CURRENT successor is refused',true,left(SQLERRM,60));
END $c$;

DO $c$ BEGIN
  PERFORM supersede_memory_by_existing(pg_temp.id('old_a'), pg_temp.id('other'),
                                       pg_temp.id('human'), 'already retired');
  INSERT INTO t_res VALUES (31,'D: retiring an already-retired record is refused',false,'ACCEPTED');
EXCEPTION WHEN others THEN
  INSERT INTO t_res VALUES (31,'D: retiring an already-retired record is refused',true,left(SQLERRM,60));
END $c$;

-- ── E: cycles ────────────────────────────────────────────────────────────
-- HONEST NOTE, and the first draft of this file got it wrong. A cycle cannot
-- be created THROUGH this function: closing one requires a successor that is
-- already superseded, and the non-current-successor check rejects that first.
-- The draft asserted "a CYCLE is refused" and passed -- on the non-current
-- check, never reaching the cycle guard. A green assertion attributed to the
-- wrong mechanism is exactly the failure this project keeps cataloguing.
--
-- So: assert what is actually true. The function refuses the attempt, and the
-- cycle guard is defence-in-depth for data that arrives another way -- a direct
-- UPDATE, an import, a restore. That path is tested by writing the cycle
-- directly and proving RESOLUTION still terminates.
INSERT INTO t_res
SELECT 40, 'E setup: successor itself retires into another record',
       supersede_memory_by_existing(pg_temp.id('successor'), pg_temp.id('other'),
         pg_temp.id('human'), 'setup: chain is old_a/old_b -> successor -> other')
         LIKE 'superseded%',
       'chain built';

DO $c$ BEGIN
  PERFORM supersede_memory_by_existing(pg_temp.id('other'), pg_temp.id('successor'),
                                       pg_temp.id('human'), 'would close a cycle');
  INSERT INTO t_res VALUES (41,'E: closing a cycle through the function is refused',false,'ACCEPTED');
EXCEPTION WHEN others THEN
  INSERT INTO t_res VALUES (41,'E: closing a cycle through the function is refused',true,
    'refused by the non-current-successor check, not the cycle guard');
END $c$;

INSERT INTO t_res
SELECT 42, 'E: resolution follows the chain to the end',
       memory_successor(pg_temp.id('old_a')) = pg_temp.id('other'),
       'old_a -> successor -> other';

-- A cycle written AROUND the function. This is the case the guard exists for.
SET LOCAL app.promoting = 'on';
UPDATE memories SET superseded_by = pg_temp.id('successor') WHERE id = pg_temp.id('other');
SET LOCAL app.promoting = 'off';

INSERT INTO t_res
SELECT 43, 'E: resolution TERMINATES on a cycle written around the function',
       memory_successor(pg_temp.id('old_a')) IS NOT NULL,
       'hop cap returns a value instead of hanging the caller';

INSERT INTO t_res
SELECT 99, 'GUARD_no_null_assertions', count(*) = 0,
       count(*)::text || ' assertion(s) evaluated to NULL' FROM t_res WHERE pass IS NULL;

SELECT n, name, coalesce(pass,false) AS pass, left(detail,58) AS detail FROM t_res ORDER BY n;

SELECT CASE WHEN count(*) = 0 THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict
FROM t_res WHERE pass IS NOT TRUE;

ROLLBACK;

-- Discrimination check for whoever maintains this: remove the cycle guard and
-- confirm assertion 33 fails and 34 hangs or hits the hop cap. If 33 still
-- passes, the guard is not doing the work its comment claims.
