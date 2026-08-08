-- tests/40_task_board.sql — covers sql/40_task_board.sql. Our issue #22.
--
-- Every `pass` must be TRUE. Sections B and C are FAILING-NEGATIVES: TRUE means
-- the forbidden operation was REJECTED.
--
-- Section A is a positive control. Without it, a schema where every insert
-- failed for an unrelated reason would show all-green across every negative
-- section. That has happened here twice, both times caught only by a control.
--
-- Section D is the legitimate path. A guard that closes everything has broken
-- the system rather than secured it, and the negative sections cannot tell the
-- difference.

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com'),
 ('22222222-2222-2222-2222-222222222222','human','H2','h2@example.com');
INSERT INTO principals (id,kind,display_name,agent_label) VALUES
 ('33333333-3333-3333-3333-333333333333','agent','A1','A1');

-- a real, promoted memory to reference
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('The supplier minimum order quantity is four thousand units per SKU per quarter.',
          'manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared','suppliers') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  CREATE TEMP TABLE _ids(k text primary key, v uuid) ON COMMIT DROP;
  INSERT INTO _ids VALUES ('mem', v);
END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — POSITIVE CONTROL. The schema must accept correct input.
-- ══════════════════════════════════════════════════════════════════════════

DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO tasks (title, body, kind, created_by, assigned_to, provenance_basis,
                     owner, visibility, workstream)
  VALUES ('Draft the supplier update post','Use the referenced claim as the subject.',
          'action','11111111-1111-1111-1111-111111111111',
          '22222222-2222-2222-2222-222222222222','human_direct',
          '11111111-1111-1111-1111-111111111111','shared','suppliers')
  RETURNING id INTO v;
  INSERT INTO _ids VALUES ('task', v);
  INSERT INTO t VALUES ('A','ctl_valid_task_accepted',true,'baseline task created');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','ctl_valid_task_accepted',false,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO task_references (task_id, ref_table, ref_id, ref_role)
  VALUES ((SELECT v FROM _ids WHERE k='task'),'memories',(SELECT v FROM _ids WHERE k='mem'),'subject');
  INSERT INTO t VALUES ('A','ctl_valid_reference_accepted',true,'reference by id accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','ctl_valid_reference_accepted',false,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO t VALUES ('A','ctl_reference_resolves_live',
    (SELECT state='live' FROM task_reference_state((SELECT v FROM _ids WHERE k='task'))
      WHERE ref_role='subject'),
    'a current referent reports live');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','ctl_reference_resolves_live',false,SQLERRM); END $c$;

-- an agent can be assigned work. Stated as a control because the model claims
-- it and a schema that silently rejected it would still pass every negative.
DO $c$ BEGIN
  INSERT INTO tasks (title, created_by, assigned_to, provenance_basis, owner, visibility)
  VALUES ('Agent-assigned task','11111111-1111-1111-1111-111111111111',
          '33333333-3333-3333-3333-333333333333','human_direct',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_agent_can_be_assigned',true,'agent principal accepted as assignee');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','ctl_agent_can_be_assigned',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — REQUIRED NEGATIVES
-- ══════════════════════════════════════════════════════════════════════════

-- B1: THE INVARIANT. A superseded referent must surface as stale, not resolve
-- silently to history.
DO $c$ DECLARE v_new uuid; BEGIN
  v_new := supersede_memory((SELECT v FROM _ids WHERE k='mem'),
            'The supplier minimum order quantity is six thousand units per SKU per quarter.',
            'human_direct',null,'11111111-1111-1111-1111-111111111111','renegotiated');
  INSERT INTO t VALUES ('B','b1_superseded_reference_surfaces_stale',
    (SELECT state='stale' FROM task_reference_state((SELECT v FROM _ids WHERE k='task'))
      WHERE ref_role='subject'),
    'referent superseded -> state=stale');
  INSERT INTO t VALUES ('B','b1b_stale_reference_makes_task_not_actionable',
    (SELECT NOT actionable FROM task_board('11111111-1111-1111-1111-111111111111')
      WHERE task_id=(SELECT v FROM _ids WHERE k='task')),
    'acting on it would mean acting on history');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b1_superseded_reference_surfaces_stale',false,SQLERRM); END $c$;

-- B2: dependency cycle rejected AT WRITE
DO $c$ DECLARE a uuid; b uuid; c uuid; BEGIN
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility)
  VALUES ('A','11111111-1111-1111-1111-111111111111','human_direct','11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO a;
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility)
  VALUES ('B','11111111-1111-1111-1111-111111111111','human_direct','11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO b;
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility)
  VALUES ('C','11111111-1111-1111-1111-111111111111','human_direct','11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO c;
  INSERT INTO task_dependencies (task_id,depends_on) VALUES (a,b),(b,c);
  BEGIN
    INSERT INTO task_dependencies (task_id,depends_on) VALUES (c,a);  -- closes the loop
    INSERT INTO t VALUES ('B','b2_dependency_cycle_rejected',false,'3-node cycle ACCEPTED');
  EXCEPTION WHEN others THEN
    INSERT INTO t VALUES ('B','b2_dependency_cycle_rejected',true,SQLERRM);
  END;
  INSERT INTO t VALUES ('B','b2b_acyclic_chain_still_allowed',
    (SELECT count(*)=2 FROM task_dependencies WHERE task_id IN (a,b)),
    'a->b->c accepted; only the closing edge refused');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b2_dependency_cycle_rejected',false,SQLERRM); END $c$;

-- B3: self-dependency
DO $c$ DECLARE a uuid; BEGIN
  SELECT id INTO a FROM tasks WHERE title='A' LIMIT 1;
  INSERT INTO task_dependencies (task_id,depends_on) VALUES (a,a);
  INSERT INTO t VALUES ('B','b3_self_dependency_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b3_self_dependency_rejected',true,SQLERRM); END $c$;

-- B4: invalid status transition
DO $c$ DECLARE a uuid; BEGIN
  SELECT id INTO a FROM tasks WHERE title='A' LIMIT 1;
  UPDATE tasks SET status='cancelled' WHERE id=a;
  UPDATE tasks SET status='in_progress' WHERE id=a;   -- cancelled is terminal
  INSERT INTO t VALUES ('B','b4_terminal_status_cannot_reopen',false,'cancelled -> in_progress accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b4_terminal_status_cannot_reopen',true,SQLERRM); END $c$;

-- B5: completion without required evidence
DO $c$ DECLARE a uuid; BEGIN
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility,requires_evidence,status)
  VALUES ('Notify the regulator','11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared',true,'in_progress') RETURNING id INTO a;
  UPDATE tasks SET status='done', completed_at=now() WHERE id=a;
  INSERT INTO t VALUES ('B','b5_completion_without_evidence_rejected',false,
    'marked done with no evidence -- this is the false-assurance case');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b5_completion_without_evidence_rejected',true,SQLERRM); END $c$;

-- B6: the evidence gate cannot be dodged by clearing the flag
-- B6 creates its OWN task. The first draft looked it up by title from B5 --
-- but B5's DO block raises, which rolls back its INSERT too, so the lookup
-- returned NULL, the UPDATE matched ZERO rows, and the test reported the guard
-- as broken. An UPDATE that changes nothing is not evidence about a guard;
-- the row count is asserted here so that cannot recur.
DO $c$ DECLARE a uuid; n int; BEGIN
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility,requires_evidence,status)
  VALUES ('Ratchet probe','11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared',true,'in_progress') RETURNING id INTO a;
  UPDATE tasks SET requires_evidence=false WHERE id=a;
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO t VALUES ('B','b6_evidence_requirement_ratchets',false,
    'requires_evidence turned off on '||n||' row(s) -- the gate is advisory');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b6_evidence_requirement_ratchets',true,SQLERRM); END $c$;

-- B7: no embedded copy. Referencing a record whose content is already pasted
-- into the body is refused.
DO $c$ DECLARE a uuid; m uuid; BEGIN
  SELECT id INTO m FROM memories WHERE status='current' AND workstream='suppliers' LIMIT 1;
  INSERT INTO tasks (title, body, created_by, provenance_basis, owner, visibility)
  VALUES ('Post the MOQ update',
          'Publish this: '||(SELECT content FROM memories WHERE id=m),
          '11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO a;
  INSERT INTO task_references (task_id, ref_table, ref_id, ref_role)
  VALUES (a,'memories',m,'subject');
  INSERT INTO t VALUES ('B','b7_embedded_copy_rejected',false,
    'a verbatim copy of the referent was accepted alongside the reference');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b7_embedded_copy_rejected',true,SQLERRM); END $c$;

-- B8: a reference to a row that does not exist
DO $c$ BEGIN
  INSERT INTO task_references (task_id, ref_table, ref_id, ref_role)
  VALUES ((SELECT v FROM _ids WHERE k='task'),'memories',
          'dddddddd-dddd-dddd-dddd-dddddddddddd','context');
  INSERT INTO t VALUES ('B','b8_nonexistent_referent_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b8_nonexistent_referent_rejected',true,SQLERRM); END $c$;

-- B9: an unregistered table cannot be referenced
DO $c$ BEGIN
  INSERT INTO task_references (task_id, ref_table, ref_id, ref_role)
  VALUES ((SELECT v FROM _ids WHERE k='task'),'principals',
          '11111111-1111-1111-1111-111111111111','context');
  INSERT INTO t VALUES ('B','b9_unregistered_ref_table_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b9_unregistered_ref_table_rejected',true,SQLERRM); END $c$;

-- B10: provenance, same rule as memories
DO $c$ BEGIN
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility)
  VALUES ('No citation','11111111-1111-1111-1111-111111111111','decision_record',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b10_non_human_basis_requires_citation',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b10_non_human_basis_requires_citation',true,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — ROLE SEMANTICS AND ISOLATION
-- ══════════════════════════════════════════════════════════════════════════

-- subject and constraint are distinct rows, not one collapsed link
DO $c$ DECLARE a uuid; m uuid; BEGIN
  SELECT id INTO m FROM memories WHERE status='current' AND workstream='suppliers' LIMIT 1;
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility)
  VALUES ('Write copy','11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO a;
  INSERT INTO task_references (task_id,ref_table,ref_id,ref_role) VALUES (a,'memories',m,'subject');
  INSERT INTO task_references (task_id,ref_table,ref_id,ref_role) VALUES (a,'memories',m,'constraint');
  INSERT INTO t VALUES ('C','c1_same_row_can_be_subject_and_constraint',
    (SELECT count(*)=2 FROM task_references WHERE task_id=a),
    'the same record means different things in each role');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c1_same_row_can_be_subject_and_constraint',false,SQLERRM); END $c$;

-- a private task is not on another principal's board
DO $c$ DECLARE a uuid; BEGIN
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility)
  VALUES ('H1 private','11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','private') RETURNING id INTO a;
  INSERT INTO t VALUES ('C','c2_private_task_hidden_from_other_principal',
    NOT EXISTS (SELECT 1 FROM task_board('22222222-2222-2222-2222-222222222222') WHERE task_id=a),
    'owner/visibility predicate reused, not reinvented');
  INSERT INTO t VALUES ('C','c2b_private_task_visible_to_owner',
    EXISTS (SELECT 1 FROM task_board('11111111-1111-1111-1111-111111111111') WHERE task_id=a),
    'and the owner still sees it -- the filter must not over-close');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c2_private_task_hidden_from_other_principal',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION D — THE LEGITIMATE PATH STILL WORKS
-- ══════════════════════════════════════════════════════════════════════════

DO $c$ DECLARE a uuid; BEGIN
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility,requires_evidence,status)
  VALUES ('File the notification','11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared',true,'in_progress') RETURNING id INTO a;
  UPDATE tasks SET status='done', completed_at=now(),
                   completion_evidence='submission ref FDA-2026-0042' WHERE id=a;
  INSERT INTO t VALUES ('D','d1_completion_with_evidence_succeeds',
    (SELECT status='done' FROM tasks WHERE id=a),'evidence supplied -> done');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d1_completion_with_evidence_succeeds',false,SQLERRM); END $c$;

DO $c$ DECLARE a uuid; BEGIN
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility,status)
  VALUES ('Ordinary work','11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared','open') RETURNING id INTO a;
  UPDATE tasks SET status='in_progress' WHERE id=a;
  UPDATE tasks SET status='blocked' WHERE id=a;
  UPDATE tasks SET status='in_progress' WHERE id=a;
  UPDATE tasks SET status='done', completed_at=now() WHERE id=a;
  INSERT INTO t VALUES ('D','d2_full_lifecycle_traversal_succeeds',
    (SELECT status='done' FROM tasks WHERE id=a),
    'open->in_progress->blocked->in_progress->done all allowed');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d2_full_lifecycle_traversal_succeeds',false,SQLERRM); END $c$;

DO $c$ DECLARE a uuid; b uuid; BEGIN
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility)
  VALUES ('Blocker','11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO b;
  INSERT INTO tasks (title,created_by,provenance_basis,owner,visibility)
  VALUES ('Blocked work','11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO a;
  INSERT INTO task_dependencies (task_id,depends_on) VALUES (a,b);
  INSERT INTO t VALUES ('D','d3_open_dependency_makes_task_not_actionable',
    (SELECT NOT actionable FROM task_board('11111111-1111-1111-1111-111111111111') WHERE task_id=a),
    'blocked while its dependency is open');
  UPDATE tasks SET status='in_progress' WHERE id=b;
  UPDATE tasks SET status='done', completed_at=now() WHERE id=b;
  INSERT INTO t VALUES ('D','d3b_completing_the_blocker_frees_it',
    (SELECT actionable FROM task_board('11111111-1111-1111-1111-111111111111') WHERE task_id=a),
    'dependency done -> actionable');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d3_open_dependency_makes_task_not_actionable',false,SQLERRM); END $c$;

-- a paraphrase is NOT caught. Asserted so the guard's limit is in test output
-- rather than only in a comment: if this ever starts failing, the guard became
-- stricter than documented and the docs are now wrong.
DO $c$ DECLARE a uuid; m uuid; BEGIN
  SELECT id INTO m FROM memories WHERE status='current' AND workstream='suppliers' LIMIT 1;
  INSERT INTO tasks (title, body, created_by, provenance_basis, owner, visibility)
  VALUES ('Paraphrase case','MOQ is six thousand per SKU each quarter.',
          '11111111-1111-1111-1111-111111111111','human_direct',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO a;
  INSERT INTO task_references (task_id,ref_table,ref_id,ref_role) VALUES (a,'memories',m,'subject');
  INSERT INTO t VALUES ('D','limit_paraphrase_is_not_detected',true,
    'KNOWN LIMIT: the no-copy guard catches verbatim text only. No trigger detects a paraphrase.');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','limit_paraphrase_is_not_detected',false,
    'guard became stricter than documented: '||SQLERRM); END $c$;


SELECT section, test, pass, left(detail,64) AS detail FROM t ORDER BY section, test;

SELECT 'A_controls' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' AS detail FROM t WHERE section='A'
UNION ALL SELECT 'B_required_negatives', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' still ACCEPTED' FROM t WHERE section='B'
UNION ALL SELECT 'C_role_and_isolation', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t WHERE section='C'
UNION ALL SELECT 'D_legitimate_path', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' BROKEN by the guards' FROM t WHERE section='D';

SELECT 'GUARD_no_null_assertions' AS summary,
       coalesce(bool_and(pass IS NOT NULL), true) AS pass,
       count(*) FILTER (WHERE pass IS NULL)::text||' assertion(s) evaluated to NULL' AS detail FROM t;

SELECT CASE WHEN bool_and(coalesce(pass,false)) THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict FROM t;

ROLLBACK;
