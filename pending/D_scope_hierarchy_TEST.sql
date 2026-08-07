-- Test matrix for pending/D_scope_hierarchy.sql.
--
-- In pending/ because D is not applied; tests/ runs against sql/ only. Move
-- both together.
--
-- Run: fresh replay, then D, then this file. Every `pass` must be true.
--
-- The matrix is the point. Containment has four axes and the failure modes live
-- in the combinations, not the individual rules:
--
--   exact grant           x  conferring / non-conferring ancestor
--   ancestor grant        x  conferring / non-conferring
--   depth                 1  / 2 / unrelated subtree
--   direction             downward only, never upward or sideways

BEGIN;

CREATE TEMP TABLE t(test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','P1','p1@example.com'),
 ('22222222-2222-2222-2222-222222222222','human','P2','p2@example.com'),
 ('44444444-4444-4444-4444-444444444444','human','Granter','g@example.com');

-- Tree:
--   workstream:brand                 confers_descendants = TRUE
--     workstream:brand/social        confers_descendants = false
--       workstream:brand/social/x    (depth 2 below the conferring root)
--   workstream:ops                   confers_descendants = FALSE
--     workstream:ops/deploy
INSERT INTO scope_registry (scope, kind, identifier, description, declared_by,
                            parent_scope, confers_descendants) VALUES
 ('workstream:brand','workstream','brand','Brand','44444444-4444-4444-4444-444444444444',null,true),
 ('workstream:brand/social','workstream','brand/social','Social','44444444-4444-4444-4444-444444444444','workstream:brand',false),
 ('workstream:brand/social/x','workstream','brand/social/x','Deep','44444444-4444-4444-4444-444444444444','workstream:brand/social',false),
 ('workstream:ops','workstream','ops','Ops','44444444-4444-4444-4444-444444444444',null,false),
 ('workstream:ops/deploy','workstream','ops/deploy','Deploy','44444444-4444-4444-4444-444444444444','workstream:ops',false);

INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by) VALUES
 ('11111111-1111-1111-1111-111111111111','workstream:brand','{read}','44444444-4444-4444-4444-444444444444'),
 ('22222222-2222-2222-2222-222222222222','workstream:ops','{read}','44444444-4444-4444-4444-444444444444');

-- ── conferring ancestor: authority flows DOWN ─────────────────────────────
INSERT INTO t SELECT 'm01_exact_grant_holds',
  has_capability('11111111-1111-1111-1111-111111111111','workstream:brand','read'),'depth 0';

INSERT INTO t SELECT 'm02_conferring_parent_reaches_child',
  has_capability('11111111-1111-1111-1111-111111111111','workstream:brand/social','read'),'depth 1';

-- m03 pins the semantic choice with a surprise in it: brand/social has
-- confers_descendants = FALSE, and a grant on brand STILL reaches
-- brand/social/x through it. The flag says what a scope does when GRANTED, not
-- whether it transmits when TRAVERSED. Setting it false does not seal a
-- subtree. If this test ever flips, someone has changed containment from
-- "conferring ancestor reaches all descendants" to "the chain must be
-- unbroken" -- a different model, and every existing grant's reach changes
-- with it.
INSERT INTO t SELECT 'm03_conferring_root_reaches_grandchild_through_nonconferring',
  has_capability('11111111-1111-1111-1111-111111111111','workstream:brand/social/x','read'),
  'depth 2 through a confers=false intermediate -- deliberate, see migration note';

-- ── non-conferring ancestor: authority does NOT flow ──────────────────────
INSERT INTO t SELECT 'm04_non_conferring_parent_does_not_reach_child',
  NOT has_capability('22222222-2222-2222-2222-222222222222','workstream:ops/deploy','read'),
  'ops does not confer; the default is closed';

-- ── never upward ──────────────────────────────────────────────────────────
DO $c$ BEGIN
  INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by)
  VALUES ('22222222-2222-2222-2222-222222222222','workstream:brand/social','{read}',
          '44444444-4444-4444-4444-444444444444');
  INSERT INTO t VALUES ('m05_child_grant_does_not_reach_parent',
    NOT has_capability('22222222-2222-2222-2222-222222222222','workstream:brand','read'),
    'a grant on a child confers nothing on its parent');
  INSERT INTO t VALUES ('m06_child_grant_does_not_reach_sibling_subtree',
    NOT has_capability('22222222-2222-2222-2222-222222222222','workstream:ops/deploy','read'),
    'and nothing sideways');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('m05_child_grant_does_not_reach_parent',false,SQLERRM); END $c$;

-- ── never across trees ────────────────────────────────────────────────────
INSERT INTO t SELECT 'm07_no_cross_tree_leak',
  NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:ops','read')
  AND NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:ops/deploy','read'),
  'brand authority reaches nothing under ops';

-- ── permission is not widened by containment ──────────────────────────────
INSERT INTO t SELECT 'm08_containment_does_not_widen_permission',
  NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:brand/social','write'),
  'read inherited down; write was never granted anywhere';

-- ── inactive principal still loses everything ─────────────────────────────
DO $c$ BEGIN
  UPDATE principals SET active=false WHERE id='11111111-1111-1111-1111-111111111111';
  INSERT INTO t VALUES ('m09_inactive_principal_inherits_nothing',
    NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:brand/social','read'),
    'containment does not survive deactivation');
  UPDATE principals SET active=true WHERE id='11111111-1111-1111-1111-111111111111';
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('m09_inactive_principal_inherits_nothing',false,SQLERRM); END $c$;

-- ── retiring an ancestor stops it conferring ──────────────────────────────
DO $c$ BEGIN
  UPDATE scope_registry SET retired_at=now() WHERE scope='workstream:brand';
  INSERT INTO t VALUES ('m10_retired_ancestor_stops_conferring',
    NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:brand/social','read'),
    'a retired scope confers nothing downward');
  UPDATE scope_registry SET retired_at=null WHERE scope='workstream:brand';
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('m10_retired_ancestor_stops_conferring',false,SQLERRM); END $c$;

-- ── turning containment off revokes the inherited reach immediately ───────
DO $c$ BEGIN
  UPDATE scope_registry SET confers_descendants=false WHERE scope='workstream:brand';
  INSERT INTO t VALUES ('m11_revoking_containment_takes_effect',
    NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:brand/social','read'),
    'flipping the column is a real revocation, not advisory');
  UPDATE scope_registry SET confers_descendants=true WHERE scope='workstream:brand';
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('m11_revoking_containment_takes_effect',false,SQLERRM); END $c$;

-- ── the review surface must actually answer the review question ───────────
INSERT INTO t SELECT 'm12_effective_grants_shows_inherited_route',
  exists (select 1 from scope_effective_grants('workstream:brand/social')
          where principal_id='11111111-1111-1111-1111-111111111111'
            and inherited_from='workstream:brand'),
  'inherited authority is attributed to the conferring ancestor';

INSERT INTO t SELECT 'm13_effective_grants_shows_direct_route',
  exists (select 1 from scope_effective_grants('workstream:brand')
          where principal_id='11111111-1111-1111-1111-111111111111'
            and inherited_from is null),
  'a direct grant reports no ancestor';

-- ── a cycle must not hang the capability check ────────────────────────────
-- A capability check that never returns is an outage, and the recursive
-- resolver is the only place in this schema that could produce one.
DO $c$ BEGIN
  UPDATE scope_registry SET parent_scope='workstream:brand/social/x' WHERE scope='workstream:brand';
  PERFORM has_capability('11111111-1111-1111-1111-111111111111','workstream:brand/social/x','read');
  INSERT INTO t VALUES ('m14_cycle_terminates',true,'depth cap held; no hang');
  UPDATE scope_registry SET parent_scope=null WHERE scope='workstream:brand';
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('m14_cycle_terminates',true,'rejected outright: '||SQLERRM); END $c$;

SELECT test, pass, left(detail,66) AS detail FROM t ORDER BY test;
SELECT 'MATRIX' AS summary, bool_and(coalesce(pass,false)) AS pass,
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

ROLLBACK;
