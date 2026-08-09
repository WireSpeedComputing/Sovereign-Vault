-- tests/50_task_board_policies.sql — covers sql/50_task_board_policies.sql.
--
-- ══════════════════════════════════════════════════════════════════════════
-- HOW TO RUN, AND WHY IT IS NOT A BEGIN/ROLLBACK SUITE
-- ══════════════════════════════════════════════════════════════════════════
-- RLS policies apply to `authenticated`, and vault_auth._trusted_request_claims()
-- returns claims ONLY when session_user = 'authenticator'. `SET ROLE
-- authenticator` from an administrative session leaves session_user unchanged,
-- so the claims path is never reached, every row is denied, EVERY NEGATIVE
-- ASSERTION PASSES, and the suite reports a working policy model having tested
-- nothing. tests/36_rls_policies_TEST.sh documents that trap; this file does not
-- get to ignore it because it has a .sql extension.
--
-- So this suite RECONNECTS, with psql \connect, as the authenticator LOGIN role
-- — the same thing PostgREST does. That means it cannot be wrapped in a single
-- transaction and it leaves fixtures behind.
--
-- REQUIRES-DISPOSABLE-CLUSTER. Run it against a throwaway PG17 cluster that has
-- the whole of sql/ applied, never against a deployment:
--
--   psql -d <disposable_db> -f tests/50_task_board_policies.sql
--
-- It creates the `authenticator` role if absent and a scratch schema t45, and
-- drops t45 at the end. It does NOT drop its fixture rows: on a disposable
-- cluster that is noise, and on anything else this file should not have run.
--
-- ══════════════════════════════════════════════════════════════════════════
-- COUNTS PREDICTED BEFORE THE FIRST RUN
-- ══════════════════════════════════════════════════════════════════════════
-- Written down first, on purpose. A plausible-looking number is not a result.
--   P1 (holds workstream:alpha read) sees 7 tasks  — the seven alpha tasks
--   P2 (holds workstream:beta read)  sees 1 task   — the one beta task
--   P1 sees 1 task_references row     — only alpha task -> alpha memory
--   P2 sees 1 task_references row     — only beta task  -> beta memory
--   P1 sees 1 task_dependencies row   — only the alpha -> alpha edge
--   P2 sees 0 task_dependencies rows
--   after the alpha memory is superseded, P1 sees 0 task_references rows
--
-- ══════════════════════════════════════════════════════════════════════════
-- SECTIONS
-- ══════════════════════════════════════════════════════════════════════════
--   0  positive control — the harness can see anything at all
--   A  cross-principal / cross-scope isolation on tasks
--   B  lifecycle is deliberately NOT narrowed for tasks
--   C  a reference resolves to BOTH sources, and the enumeration is closed
--   D  a dependency edge needs both endpoints
--   E  absence must not read as permission (the unreadable-reference count)
--   F  the definer door and the table door must agree
--   G  privilege posture — no write path, no oracle functions
--   H  unresolved identity fails closed
--   I  documented limit — service_role still bypasses everything

\set ON_ERROR_STOP on
\set ORIGUSER :USER

-- ══════════════════════════════════════════════════════════════════════════
-- SETUP (administrative connection)
-- ══════════════════════════════════════════════════════════════════════════
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
end $$;
grant authenticated to authenticator;
grant usage on schema public to authenticated;

drop schema if exists t45 cascade;
create schema t45;
grant usage on schema t45 to authenticated, authenticator;
create table t45.r (section text, test text, pass boolean, detail text);
create table t45.seen (task_id uuid);
grant insert, select on t45.r, t45.seen to authenticated, authenticator;

insert into principals (id, kind, display_name, email) values
 ('45a1a1a1-0000-0000-0000-00000000a1a1','human','P1','p1-t45@example.test'),
 ('45b2b2b2-0000-0000-0000-00000000b2b2','human','P2','p2-t45@example.test'),
 ('45c3c3c3-0000-0000-0000-00000000c3c3','human','Granter','g@example.test');

insert into scope_registry (scope, kind, identifier, description, declared_by) values
 ('workstream:alpha','workstream','alpha','Alpha','45c3c3c3-0000-0000-0000-00000000c3c3'),
 ('workstream:beta','workstream','beta','Beta','45c3c3c3-0000-0000-0000-00000000c3c3');

insert into capability_grants (principal_id, resource_scope, permissions, granted_by) values
 ('45a1a1a1-0000-0000-0000-00000000a1a1','workstream:alpha','{read}','45c3c3c3-0000-0000-0000-00000000c3c3'),
 ('45b2b2b2-0000-0000-0000-00000000b2b2','workstream:beta','{read}','45c3c3c3-0000-0000-0000-00000000c3c3');

-- reviewed_by/reviewed_at are REQUIRED for an approved binding, and `issuer`
-- must be the LITERAL iss claim URL. A friendly label inserts cleanly and
-- resolves nothing, which is indistinguishable from a working deny-all if you
-- only assert denials. Section 0 exists because that has happened.
insert into vault_auth.principal_identity_bindings
 (identity_kind, issuer, identity_value, principal_id, binding_status, review_status,
  created_by, reviewed_by, reviewed_at, reason, citation, provenance_basis, workstream,
  source_agent) values
 ('auth_subject','https://example.test/auth/v1','p1-sub','45a1a1a1-0000-0000-0000-00000000a1a1',
  'active','approved','45c3c3c3-0000-0000-0000-00000000c3c3',
  '45c3c3c3-0000-0000-0000-00000000c3c3',now(),'test','test','human_direct','alpha','test-harness'),
 ('auth_subject','https://example.test/auth/v1','p2-sub','45b2b2b2-0000-0000-0000-00000000b2b2',
  'active','approved','45c3c3c3-0000-0000-0000-00000000c3c3',
  '45c3c3c3-0000-0000-0000-00000000c3c3',now(),'test','test','human_direct','beta','test-harness');

-- referents: one current memory per scope, and one row in an unenumerated table
do $$ declare v uuid; vi uuid; begin
  insert into memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  values ('zz45 alpha referent record','manual','human_direct','proposed',
          '45a1a1a1-0000-0000-0000-00000000a1a1','shared','alpha') returning id into v;
  perform promote_memory(v,'45a1a1a1-0000-0000-0000-00000000a1a1');

  insert into memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  values ('zz45 beta referent record','manual','human_direct','proposed',
          '45b2b2b2-0000-0000-0000-00000000b2b2','shared','beta') returning id into v;
  perform promote_memory(v,'45b2b2b2-0000-0000-0000-00000000b2b2');

  insert into ingredients (name, canonical_name, provenance_basis)
  values ('zz45 test ingredient','zz45-test-ingredient','human_direct') returning id into vi;
  insert into ingredient_claims (ingredient_id, claim_text, claim_status,
                                 provenance_basis, citation)
  values (vi,'zz45 unenumerated referent','conditional','source_document','synthetic fixture');
end $$;

-- tasks. Bodies are NULL throughout: sql/40's no-copy trigger rejects a body
-- containing a referent's text verbatim, and that guard is tests/40's subject,
-- not this file's.
do $$
declare
  p1 uuid := '45a1a1a1-0000-0000-0000-00000000a1a1';
  p2 uuid := '45b2b2b2-0000-0000-0000-00000000b2b2';
  m_alpha uuid; m_beta uuid; c1 uuid;
  t_sub uuid; t_priv uuid; t_done uuid; t_canc uuid; t_xref uuid; t_claim uuid;
  t_block uuid; t_beta uuid;
begin
  select id into m_alpha from memories where content = 'zz45 alpha referent record' and status='current';
  select id into m_beta  from memories where content = 'zz45 beta referent record'  and status='current';
  select id into c1      from ingredient_claims where claim_text = 'zz45 unenumerated referent';

  insert into tasks (title, kind, created_by, provenance_basis, owner, visibility, workstream)
  values ('zz45 alpha subject','action',p1,'human_direct',p1,'shared','alpha') returning id into t_sub;
  insert into tasks (title, kind, created_by, provenance_basis, owner, visibility, workstream)
  values ('zz45 alpha private','action',p1,'human_direct',p1,'private','alpha') returning id into t_priv;
  insert into tasks (title, kind, created_by, provenance_basis, owner, visibility, workstream, status, completed_at)
  values ('zz45 alpha done','action',p1,'human_direct',p1,'shared','alpha','done',now()) returning id into t_done;
  insert into tasks (title, kind, created_by, provenance_basis, owner, visibility, workstream, status)
  values ('zz45 alpha cancelled','action',p1,'human_direct',p1,'shared','alpha','cancelled') returning id into t_canc;
  insert into tasks (title, kind, created_by, provenance_basis, owner, visibility, workstream)
  values ('zz45 alpha xref','action',p1,'human_direct',p1,'shared','alpha') returning id into t_xref;
  insert into tasks (title, kind, created_by, provenance_basis, owner, visibility, workstream)
  values ('zz45 alpha claimref','action',p1,'human_direct',p1,'shared','alpha') returning id into t_claim;
  insert into tasks (title, kind, created_by, provenance_basis, owner, visibility, workstream)
  values ('zz45 alpha blocker','action',p1,'human_direct',p1,'shared','alpha') returning id into t_block;
  insert into tasks (title, kind, created_by, provenance_basis, owner, visibility, workstream)
  values ('zz45 beta task','action',p2,'human_direct',p2,'shared','beta') returning id into t_beta;

  -- in-scope task -> in-scope referent
  insert into task_references (task_id, ref_table, ref_id, ref_role)
  values (t_sub,'memories',m_alpha,'subject');
  -- in-scope task -> OUT-OF-SCOPE referent, as a constraint: the case where a
  -- hidden reference could render as "no constraints"
  insert into task_references (task_id, ref_table, ref_id, ref_role)
  values (t_xref,'memories',m_beta,'constraint');
  -- in-scope task -> referent in a registered but UNENUMERATED table
  insert into task_references (task_id, ref_table, ref_id, ref_role)
  values (t_claim,'ingredient_claims',c1,'context');
  -- out-of-scope task -> out-of-scope referent
  insert into task_references (task_id, ref_table, ref_id, ref_role)
  values (t_beta,'memories',m_beta,'subject');

  insert into task_dependencies (task_id, depends_on) values (t_sub, t_block);
  insert into task_dependencies (task_id, depends_on) values (t_block, t_beta);
end $$;

-- ══════════════════════════════════════════════════════════════════════════
-- P1's VIEW — reconnect as the authenticator LOGIN role and present claims
-- ══════════════════════════════════════════════════════════════════════════
\connect -reuse-previous=on user=authenticator

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"role":"authenticated","sub":"p1-sub","iss":"https://example.test/auth/v1"}', true);

-- ── SECTION 0: positive control ───────────────────────────────────────────
-- Without this every negative below passes for reasons unrelated to policy.
INSERT INTO t45.r
SELECT '0','ctl_p1_sees_own_in_scope_task',
       count(*) = 1, 'expected 1, got '||count(*)
FROM tasks WHERE title = 'zz45 alpha subject';

INSERT INTO t45.r
SELECT '0','ctl_p1_sees_exactly_seven_alpha_tasks',
       count(*) = 7, 'expected 7, got '||count(*)
FROM tasks;

-- ── SECTION A: isolation ──────────────────────────────────────────────────
INSERT INTO t45.r
SELECT 'A','a1_p1_cannot_see_beta_task',
       count(*) = 0, 'expected 0, got '||count(*)
FROM tasks WHERE title = 'zz45 beta task';

INSERT INTO t45.r
SELECT 'A','a4_p1_sees_own_private_task',
       count(*) = 1, 'expected 1, got '||count(*)||' -- the filter must not over-close'
FROM tasks WHERE title = 'zz45 alpha private';

-- ── SECTION B: lifecycle deliberately NOT narrowed ────────────────────────
-- Reads backwards on purpose. If either of these ever FAILS, someone added a
-- status filter to tasks_read and the reasoning in sql/45 needs re-reading.
INSERT INTO t45.r
SELECT 'B','b1_done_task_still_visible',
       count(*) = 1, 'expected 1, got '||count(*)
FROM tasks WHERE title = 'zz45 alpha done';

INSERT INTO t45.r
SELECT 'B','b2_cancelled_task_still_visible',
       count(*) = 1, 'expected 1, got '||count(*)
FROM tasks WHERE title = 'zz45 alpha cancelled';

-- ── SECTION C: a reference resolves to BOTH sources ───────────────────────
INSERT INTO t45.r
SELECT 'C','c0_ctl_in_scope_reference_visible',
       count(*) = 1, 'expected 1, got '||count(*)
FROM task_references WHERE ref_role = 'subject' AND ref_table = 'memories';

INSERT INTO t45.r
SELECT 'C','c1_reference_to_out_of_scope_referent_hidden',
       count(*) = 0, 'expected 0, got '||count(*)||' -- task readable, referent is not'
FROM task_references WHERE ref_role = 'constraint';

INSERT INTO t45.r
SELECT 'C','c3_unenumerated_ref_table_denied',
       count(*) = 0, 'expected 0, got '||count(*)||' -- registered in task_referenceable, not enumerated in task_referent_acl'
FROM task_references WHERE ref_table = 'ingredient_claims';

INSERT INTO t45.r
SELECT 'C','c4_p1_sees_exactly_one_reference_row',
       count(*) = 1, 'expected 1, got '||count(*)
FROM task_references;

-- ── SECTION D: an edge needs both endpoints ───────────────────────────────
INSERT INTO t45.r
SELECT 'D','d1_p1_sees_exactly_one_dependency_edge',
       count(*) = 1, 'expected 1, got '||count(*)||' -- the alpha->beta edge names a task P1 cannot read'
FROM task_dependencies;

-- record what the TABLE door served, for Section F
INSERT INTO t45.seen SELECT id FROM tasks;
COMMIT;

-- ══════════════════════════════════════════════════════════════════════════
-- P2's VIEW
-- ══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"role":"authenticated","sub":"p2-sub","iss":"https://example.test/auth/v1"}', true);

INSERT INTO t45.r
SELECT '0','ctl_p2_sees_own_in_scope_task',
       count(*) = 1, 'expected 1, got '||count(*)
FROM tasks WHERE title = 'zz45 beta task';

INSERT INTO t45.r
SELECT 'A','a2_p2_cannot_see_shared_alpha_tasks',
       count(*) = 0, 'expected 0, got '||count(*)||' -- shared visibility passes the owner gate; scope must still deny'
FROM tasks WHERE title LIKE 'zz45 alpha%';

INSERT INTO t45.r
SELECT 'A','a3_p2_sees_exactly_one_task',
       count(*) = 1, 'expected 1, got '||count(*)
FROM tasks;

-- The other half of the both-sources rule: P2 CAN read the beta memory, and
-- still cannot see the reference row that points at it, because the task that
-- owns the reference is out of P2's scope.
INSERT INTO t45.r
SELECT 'C','c2_reference_owned_by_unreadable_task_hidden',
       count(*) = 0, 'expected 0, got '||count(*)||' -- referent readable, owning task is not'
FROM task_references tr
WHERE tr.ref_role = 'constraint';

INSERT INTO t45.r
SELECT 'C','c5_p2_sees_exactly_one_reference_row',
       count(*) = 1, 'expected 1, got '||count(*)
FROM task_references;

INSERT INTO t45.r
SELECT 'D','d2_p2_sees_no_dependency_edges',
       count(*) = 0, 'expected 0, got '||count(*)
FROM task_dependencies;
COMMIT;

-- ══════════════════════════════════════════════════════════════════════════
-- SECTION H: unresolved identity fails closed
-- ══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"role":"authenticated","sub":"no-such-sub","iss":"https://example.test/auth/v1"}', true);
INSERT INTO t45.r
SELECT 'H','h1_unknown_subject_sees_nothing',
       count(*) = 0, 'expected 0, got '||count(*) FROM tasks;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
INSERT INTO t45.r
SELECT 'H','h2_no_claims_at_all_sees_nothing',
       count(*) = 0, 'expected 0, got '||count(*) FROM tasks;
COMMIT;

-- ══════════════════════════════════════════════════════════════════════════
-- BACK TO THE ADMINISTRATIVE CONNECTION
-- ══════════════════════════════════════════════════════════════════════════
\connect -reuse-previous=on user=:ORIGUSER

-- ── SECTION E: absence must not read as permission ────────────────────────
-- The hidden constraint reference must still be COUNTED on the board, or a task
-- with a withheld constraint renders as a task with no constraints.
INSERT INTO t45.r
SELECT 'E','e1_hidden_constraint_is_counted',
       b.unreadable_references = 1,
       'unreadable_references='||b.unreadable_references||' (expected 1)'
FROM task_board('45a1a1a1-0000-0000-0000-00000000a1a1') b
WHERE b.title = 'zz45 alpha xref';

INSERT INTO t45.r
SELECT 'E','e2_unreadable_constraint_blocks_actionability',
       b.actionable IS FALSE,
       'actionable='||coalesce(b.actionable::text,'NULL')||' (expected false)'
FROM task_board('45a1a1a1-0000-0000-0000-00000000a1a1') b
WHERE b.title = 'zz45 alpha xref';

-- ...but a 'context' reference is informative by definition and must NOT block.
-- A guard that closes everything has broken the board rather than secured it.
INSERT INTO t45.r
SELECT 'E','e3_unreadable_context_ref_counted_but_not_blocking',
       b.unreadable_references = 1 AND b.actionable IS TRUE,
       'unreadable='||b.unreadable_references||' actionable='||coalesce(b.actionable::text,'NULL')
FROM task_board('45a1a1a1-0000-0000-0000-00000000a1a1') b
WHERE b.title = 'zz45 alpha claimref';

-- ── SECTION F: the two doors must agree ───────────────────────────────────
-- THE ASSERTION THIS FILE EXISTS FOR. Before sql/45, task_board() filtered on
-- is_owner_or_shared alone, so the definer door served every shared task
-- regardless of scope while the table door served only the in-scope ones. Same
-- principal, two answers, no error — migration 49's defect on a new table.
INSERT INTO t45.r
SELECT 'F','f1_definer_and_table_doors_return_the_same_task_set',
       NOT EXISTS (
         SELECT task_id FROM task_board('45a1a1a1-0000-0000-0000-00000000a1a1')
         EXCEPT SELECT task_id FROM t45.seen
       ) AND NOT EXISTS (
         SELECT task_id FROM t45.seen
         EXCEPT SELECT task_id FROM task_board('45a1a1a1-0000-0000-0000-00000000a1a1')
       ),
       'board='||(SELECT count(*) FROM task_board('45a1a1a1-0000-0000-0000-00000000a1a1'))
       ||' table='||(SELECT count(*) FROM t45.seen);

INSERT INTO t45.r
SELECT 'F','f2_board_denies_out_of_scope_shared_tasks',
       count(*) = 0, 'expected 0, got '||count(*)||' -- shared alpha tasks must not reach P2''s board'
FROM task_board('45b2b2b2-0000-0000-0000-00000000b2b2') WHERE title LIKE 'zz45 alpha%';

-- ── SECTION G: privilege posture ──────────────────────────────────────────
-- The policies are SELECT-only. That is only true while no write privilege
-- exists; a policy model that silently gained one looks identical from the read
-- side.
INSERT INTO t45.r
SELECT 'G','g1_no_write_privilege_for_authenticated',
       bool_and(NOT has_table_privilege('authenticated', t, p)),
       string_agg(t||':'||p, ',') FILTER (WHERE has_table_privilege('authenticated', t, p))
FROM unnest(ARRAY['public.tasks','public.task_references','public.task_dependencies']) AS tt(t)
CROSS JOIN unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE']) AS pp(p);

INSERT INTO t45.r
SELECT 'G','g2_read_privilege_present_so_policies_can_run',
       bool_and(has_table_privilege('authenticated', t, 'SELECT')),
       'without SELECT every denial above would pass for the wrong reason'
FROM unnest(ARRAY['public.tasks','public.task_references','public.task_dependencies']) AS tt(t);

-- task_reference_state() takes no principal and applies no access check. It is
-- an enumeration oracle if it is ever granted.
INSERT INTO t45.r
SELECT 'G','g3_reference_state_is_not_executable_by_authenticated',
       NOT has_function_privilege('authenticated','public.task_reference_state(uuid)','EXECUTE'),
       'granting this exposes every referent id of every task';

INSERT INTO t45.r
SELECT 'G','g4_board_and_acl_helpers_not_executable_by_authenticated',
       NOT has_function_privilege('authenticated','public.task_board(uuid)','EXECUTE')
       AND NOT has_function_privilege('authenticated','public.task_referent_acl(text,uuid)','EXECUTE')
       AND NOT has_function_privilege('authenticated','public.task_reference_readable(text,uuid,uuid)','EXECUTE'),
       'only the _as_request predicate is exposed';

INSERT INTO t45.r
SELECT 'G','g5_perimeter_clean',
       count(*) = 0,
       coalesce(string_agg(category||' '||object_name||' -> '||grantee, '; '), 'no findings')
FROM perimeter_assert();

-- ── SECTION C (continued): supersession removes the reference row ─────────
-- Deliberately last: it mutates a referent every earlier count depends on.
DO $c$ BEGIN
  PERFORM supersede_memory(
    (SELECT id FROM memories WHERE content='zz45 alpha referent record' AND status='current'),
    'zz45 alpha referent record, corrected','human_direct',NULL,
    '45a1a1a1-0000-0000-0000-00000000a1a1','test supersession');
END $c$;

INSERT INTO t45.r
SELECT 'E','e4_superseded_referent_still_counted_on_the_board',
       b.stale_references = 1 AND b.actionable IS FALSE,
       'stale='||b.stale_references||' actionable='||coalesce(b.actionable::text,'NULL')
FROM task_board('45a1a1a1-0000-0000-0000-00000000a1a1') b
WHERE b.title = 'zz45 alpha subject';

\connect -reuse-previous=on user=authenticator
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"role":"authenticated","sub":"p1-sub","iss":"https://example.test/auth/v1"}', true);
INSERT INTO t45.r
SELECT 'C','c6_superseded_referent_reference_row_withdrawn',
       count(*) = 0, 'expected 0, got '||count(*)||' -- the referent is no longer current'
FROM task_references WHERE ref_role = 'subject' AND ref_table = 'memories';
COMMIT;

\connect -reuse-previous=on user=:ORIGUSER

-- ── SECTION I: documented limit ───────────────────────────────────────────
-- Passes while the bypass exists. If it ever FAILS the ambient-credential
-- problem was solved and every document repeating this limit is now wrong.
-- Run after G so the grant below cannot pollute the perimeter check.
GRANT SELECT ON public.tasks TO service_role;
DO $c$ DECLARE n bigint; BEGIN
  SET LOCAL ROLE service_role;
  SELECT count(*) INTO n FROM tasks;
  RESET ROLE;
  INSERT INTO t45.r VALUES ('I','limit_service_role_still_bypasses_rls', n >= 8,
    'service_role saw '||n||' of 8 tasks');
END $c$;

-- ══════════════════════════════════════════════════════════════════════════
-- RESULTS
-- ══════════════════════════════════════════════════════════════════════════
SELECT section, test, pass, left(detail, 72) AS detail FROM t45.r ORDER BY section, test;

SELECT '0_control' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' AS detail FROM t45.r WHERE section='0'
UNION ALL SELECT 'A_isolation', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' leaked' FROM t45.r WHERE section='A'
UNION ALL SELECT 'B_lifecycle_not_narrowed', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' over-closed' FROM t45.r WHERE section='B'
UNION ALL SELECT 'C_reference_both_sources', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t45.r WHERE section='C'
UNION ALL SELECT 'D_dependency_both_endpoints', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t45.r WHERE section='D'
UNION ALL SELECT 'E_absence_is_reported', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t45.r WHERE section='E'
UNION ALL SELECT 'F_doors_agree', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' DIVERGED' FROM t45.r WHERE section='F'
UNION ALL SELECT 'G_privilege_posture', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t45.r WHERE section='G'
UNION ALL SELECT 'H_fails_closed', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t45.r WHERE section='H'
UNION ALL SELECT 'I_documented_limit', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' -- docs now overstate the limit' FROM t45.r WHERE section='I';

-- An assertion that never ran cannot fail. This catches both NULL results and a
-- section that produced no rows at all, which is how 21 inert assertions once
-- read as 24 passes.
SELECT 'GUARD_no_null_assertions' AS summary,
       coalesce(bool_and(pass IS NOT NULL), false) AS pass,
       count(*) FILTER (WHERE pass IS NULL)::text||' assertion(s) evaluated to NULL' AS detail
FROM t45.r;

SELECT 'GUARD_expected_assertion_count' AS summary,
       count(*) = 32 AS pass,
       'ran '||count(*)||' assertions, expected 32' AS detail FROM t45.r;

SELECT CASE WHEN bool_and(coalesce(pass,false)) AND count(*) = 32
            THEN 'SUITE_RESULT: PASS' ELSE 'SUITE_RESULT: FAIL' END AS verdict
FROM t45.r;

DROP SCHEMA t45 CASCADE;

-- ── WHY THIS SUITE LEAVES ITS FIXTURES BEHIND, AND WHY THAT IS SAFE ───────
-- This is not a BEGIN/ROLLBACK suite: RLS needs session_user = 'authenticator',
-- so it reconnects, and a reconnect ends the transaction. It is therefore the
-- only suite here that COMMITS its fixtures, and the harness runs suites
-- alphabetically against one database -- so what it leaves lands in whatever
-- runs next. It did: tests/46 inserts principals with fixed ids and died on
-- principals_pkey, then on principals_email_unique.
--
-- The loud collision is the good case. The bad case is a later suite whose
-- assertions merely shift because rows it never created are present, and
-- nothing says so.
--
-- DELETING the fixtures was tried first and is the wrong fix. The rows are the
-- root of an FK graph this suite deliberately builds -- principals own memories
-- own tasks own references -- so the cleanup must unwind that graph in exact
-- order, and a cleanup that fails partway leaves a MORE confusing residue than
-- no cleanup at all. It also runs after the verdict, so a failure there would
-- turn a passing suite into an errored one.
--
-- The defence is namespacing instead: every principal id and email here is
-- prefixed for this suite, so collision is impossible regardless of run order
-- or whether this suite completes. The residue is labelled rather than removed,
-- which is the same choice this project makes about superseded records.
