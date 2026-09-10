-- tests/51_derived_obligations.sql — covers sql/51_derived_obligations.sql.
--
-- Every `pass` must be TRUE. Section B is FAILING-NEGATIVES: TRUE means the
-- forbidden operation was REJECTED.
--
-- Section A is a positive control. Without it, a schema where every insert
-- failed for an unrelated reason would show all-green across every negative
-- section. That has happened in this repo twice, both times caught only by a
-- control.
--
-- Section D is the legitimate path. A guard that closes everything has broken
-- the system rather than secured it, and the negative sections cannot tell the
-- difference.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT THIS SUITE IS FOR
-- ══════════════════════════════════════════════════════════════════════════
-- Section C is the one that matters. sql/46 claims that completing the task
-- which generated a duty can NEVER discharge that duty, and that the claim is
-- structural rather than a habit. C tests it three ways:
--   c1  behaviourally — complete the source task, the obligation is still open
--   c2  from the catalog — no trigger on tasks carries a write verb toward
--       obligations, so no side-effect path exists to find
--   c3  the near-miss — the task's own completion evidence, which is the
--       artifact someone would most plausibly mistake for discharge, leaves the
--       obligation untouched
-- and B2/B3 close the two ways round it: a direct UPDATE of status, and
-- offering the originating task as the obligation's evidence.
--
-- ══════════════════════════════════════════════════════════════════════════
-- PREDICTED BEFORE THE FIRST RUN
-- ══════════════════════════════════════════════════════════════════════════
--   seed_obligation_rules() inserts 2 rules, both requires_confirmation=true
--   one 'decision' task created   -> 1 obligation, due 14 days out
--   one 'action' task completed   -> 1 obligation, due 30 days out
--   a 'review' task matches neither seeded rule -> 0 obligations
--   basis_confirmed is false for every obligation until the rule is confirmed
--   40 assertions run

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;
CREATE TEMP TABLE _ids(k text primary key, v uuid) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('a1a1a1a1-0000-0000-0000-00000000a1a1','human','P1','p1@example.test'),
 ('b2b2b2b2-0000-0000-0000-00000000b2b2','human','P2','p2@example.test');

-- ON CONFLICT DO NOTHING because tests/45 commits its fixtures (it reconnects
-- for RLS, so it cannot roll back) and may already have declared these scopes.
-- A scope already existing is not an error for this suite -- it needs the scope
-- REGISTERED, not registered by itself. Registering it twice is the only thing
-- that would fail, and that is a property of the run order, not of the code
-- under test.
INSERT INTO scope_registry (scope,kind,identifier,description,declared_by) VALUES
 ('workstream:alpha','workstream','alpha','Alpha','a1a1a1a1-0000-0000-0000-00000000a1a1'),
 ('workstream:beta','workstream','beta','Beta','a1a1a1a1-0000-0000-0000-00000000a1a1')
ON CONFLICT (scope) DO NOTHING;

-- P1 holds both scopes; P2 holds only beta. obligation_board resolves visibility
-- back to the SOURCE TASK through can_read_row(), so without a grant the board
-- is empty for reasons that have nothing to do with obligations -- which would
-- make Section D pass for the wrong reason.
INSERT INTO capability_grants (principal_id,resource_scope,permissions,granted_by) VALUES
 ('a1a1a1a1-0000-0000-0000-00000000a1a1','workstream:alpha','{read}','a1a1a1a1-0000-0000-0000-00000000a1a1'),
 ('a1a1a1a1-0000-0000-0000-00000000a1a1','workstream:beta','{read}','a1a1a1a1-0000-0000-0000-00000000a1a1'),
 ('b2b2b2b2-0000-0000-0000-00000000b2b2','workstream:beta','{read}','a1a1a1a1-0000-0000-0000-00000000a1a1');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — POSITIVE CONTROL
-- ══════════════════════════════════════════════════════════════════════════

DO $c$ DECLARE n int; BEGIN
  n := seed_obligation_rules('a1a1a1a1-0000-0000-0000-00000000a1a1');
  INSERT INTO t VALUES ('A','a1_seed_inserts_two_unconfirmed_rules',
    n = 2 AND (SELECT bool_and(requires_confirmation) FROM obligation_rules),
    'seeded '||n||' rules, all requires_confirmation');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','a1_seed_inserts_two_unconfirmed_rules',false,SQLERRM); END $c$;

-- a decision task fires the task_created rule
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO tasks (title,kind,created_by,provenance_basis,owner,visibility,workstream)
  VALUES ('zz46 record the decision','decision','a1a1a1a1-0000-0000-0000-00000000a1a1',
          'human_direct','a1a1a1a1-0000-0000-0000-00000000a1a1','shared','alpha')
  RETURNING id INTO v;
  INSERT INTO _ids VALUES ('t_decision', v);
  INSERT INTO t VALUES ('A','a2_decision_task_generates_on_create',
    (SELECT count(*)=1 FROM obligations WHERE source_task_id=v),
    'one duty generated at task creation');
  INSERT INTO _ids SELECT 'o_decision', id FROM obligations WHERE source_task_id=v;
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','a2_decision_task_generates_on_create',false,SQLERRM); END $c$;

-- an action task fires the task_completed rule, and NOT at creation
DO $c$ DECLARE v uuid; n_before int; BEGIN
  INSERT INTO tasks (title,kind,created_by,provenance_basis,owner,visibility,workstream,
                     requires_evidence,status)
  VALUES ('zz46 ship the change','action','a1a1a1a1-0000-0000-0000-00000000a1a1',
          'human_direct','a1a1a1a1-0000-0000-0000-00000000a1a1','shared','alpha',
          true,'in_progress')
  RETURNING id INTO v;
  INSERT INTO _ids VALUES ('t_action', v);
  SELECT count(*) INTO n_before FROM obligations WHERE source_task_id=v;

  UPDATE tasks SET status='done', completed_at=now(),
                   completion_evidence='synthetic build reference zz46-0001'
   WHERE id=v;

  INSERT INTO t VALUES ('A','a3_action_task_generates_on_completion_only',
    n_before = 0 AND (SELECT count(*)=1 FROM obligations WHERE source_task_id=v),
    'before completion '||n_before||', after completion '
      ||(SELECT count(*) FROM obligations WHERE source_task_id=v));
  INSERT INTO _ids SELECT 'o_action', id FROM obligations WHERE source_task_id=v;
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','a3_action_task_generates_on_completion_only',false,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO t VALUES ('A','a4_deadline_is_the_rule_interval_from_generation',
    (SELECT o.due_at - o.generated_at = r.deadline_interval
       FROM obligations o JOIN obligation_rules r ON r.id=o.rule_id
      WHERE o.id=(SELECT _ids.v FROM _ids WHERE k='o_action')),
    'due_at - generated_at equals the rule''s declared interval');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','a4_deadline_is_the_rule_interval_from_generation',false,SQLERRM); END $c$;

-- Re-running the generator must not manufacture a second duty. A board that
-- doubles a duty every time a status is touched is a board nobody believes.
DO $c$ DECLARE n int; BEGIN
  n := generate_obligations_for_task((SELECT _ids.v FROM _ids WHERE k='t_action'),'task_completed');
  INSERT INTO t VALUES ('A','a5_generation_is_idempotent',
    n = 0 AND (SELECT count(*)=1 FROM obligations
                WHERE source_task_id=(SELECT _ids.v FROM _ids WHERE k='t_action')),
    'second run inserted '||n||' rows');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','a5_generation_is_idempotent',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — REQUIRED NEGATIVES
-- ══════════════════════════════════════════════════════════════════════════

-- B1: THE REQUIREMENT. No evidence, no closure.
DO $c$ BEGIN
  PERFORM close_obligation((SELECT _ids.v FROM _ids WHERE k='o_action'),
                           'a1a1a1a1-0000-0000-0000-00000000a1a1','satisfied');
  INSERT INTO t VALUES ('B','b1_closure_without_evidence_rejected',false,
    'an obligation was marked satisfied with nothing behind it');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b1_closure_without_evidence_rejected',true,SQLERRM); END $c$;

-- B2: and the sanctioned path cannot be stepped around with a direct UPDATE.
-- This is what makes "no trigger on tasks can close a duty" structural: any such
-- trigger would be issuing exactly this UPDATE.
DO $c$ BEGIN
  UPDATE obligations SET status='satisfied', closed_at=now(),
         closed_by='a1a1a1a1-0000-0000-0000-00000000a1a1'
   WHERE id=(SELECT _ids.v FROM _ids WHERE k='o_action');
  INSERT INTO t VALUES ('B','b2_direct_status_update_rejected',false,
    'status changed outside close_obligation()');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b2_direct_status_update_rejected',true,SQLERRM); END $c$;

-- B3: the originating task is not evidence that its own duty was discharged.
DO $c$ BEGIN
  INSERT INTO obligation_evidence (obligation_id,task_id,description,recorded_by)
  VALUES ((SELECT _ids.v FROM _ids WHERE k='o_action'),
          (SELECT _ids.v FROM _ids WHERE k='t_action'),
          'the change was shipped','a1a1a1a1-0000-0000-0000-00000000a1a1');
  INSERT INTO t VALUES ('B','b3_source_task_not_admissible_as_its_own_evidence',false,
    'completing the action was accepted as proof the duty was met');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b3_source_task_not_admissible_as_its_own_evidence',true,SQLERRM); END $c$;

-- B4: the deadline does not move.
DO $c$ BEGIN
  UPDATE obligations SET due_at = due_at + interval '90 days'
   WHERE id=(SELECT _ids.v FROM _ids WHERE k='o_action');
  INSERT INTO t VALUES ('B','b4_deadline_is_immutable',false,'due_at was pushed out');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b4_deadline_is_immutable',true,SQLERRM); END $c$;

-- B5: and the duty cannot be re-parented onto a different action or reading.
DO $c$ BEGIN
  UPDATE obligations SET source_task_id=(SELECT _ids.v FROM _ids WHERE k='t_decision')
   WHERE id=(SELECT _ids.v FROM _ids WHERE k='o_action');
  INSERT INTO t VALUES ('B','b5_source_task_and_rule_immutable',false,'re-parented');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b5_source_task_and_rule_immutable',true,SQLERRM); END $c$;

-- B6: a deadline in the past at generation time is a typo that reads as
-- permanently overdue. Direct inserts are the only place it could enter.
DO $c$ BEGIN
  INSERT INTO obligations (rule_id,source_task_id,title,generated_at,due_at)
  VALUES ((SELECT id FROM obligation_rules WHERE rule_key='example.notify_after_change'),
          (SELECT _ids.v FROM _ids WHERE k='t_decision'),'backwards window',
          now(), now() - interval '1 day');
  INSERT INTO t VALUES ('B','b6_deadline_before_generation_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b6_deadline_before_generation_rejected',true,SQLERRM); END $c$;

-- B7: evidence that names nothing is a checkbox.
DO $c$ BEGIN
  INSERT INTO obligation_evidence (obligation_id,description,recorded_by)
  VALUES ((SELECT _ids.v FROM _ids WHERE k='o_action'),'done','a1a1a1a1-0000-0000-0000-00000000a1a1');
  INSERT INTO t VALUES ('B','b7_evidence_naming_nothing_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b7_evidence_naming_nothing_rejected',true,SQLERRM); END $c$;

-- B8: a rule with no citation is an opinion with a due date.
DO $c$ BEGIN
  INSERT INTO obligation_rules (rule_key,description,on_task_kind,generate_on,duty_title,
                                deadline_interval,evidence_requirement,authority,citation,declared_by)
  VALUES ('zz46.uncited','no basis','action','task_created','something',
          interval '7 days','something','somebody','   ',
          'a1a1a1a1-0000-0000-0000-00000000a1a1');
  INSERT INTO t VALUES ('B','b8_rule_without_citation_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b8_rule_without_citation_rejected',true,SQLERRM); END $c$;

-- B9: a non-positive window is not a deadline.
DO $c$ BEGIN
  INSERT INTO obligation_rules (rule_key,description,on_task_kind,generate_on,duty_title,
                                deadline_interval,evidence_requirement,authority,citation,declared_by)
  VALUES ('zz46.zero_window','zero','action','task_created','something',
          interval '0','something','somebody','somewhere',
          'a1a1a1a1-0000-0000-0000-00000000a1a1');
  INSERT INTO t VALUES ('B','b9_non_positive_deadline_interval_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b9_non_positive_deadline_interval_rejected',true,SQLERRM); END $c$;

-- B10: the confirmation flag ratchets. Otherwise whoever is inconvenienced by
-- an unconfirmed basis clears the flag instead of confirming the reading.
DO $c$ DECLARE n int; BEGIN
  UPDATE obligation_rules SET requires_confirmation=false
   WHERE rule_key='example.notify_after_change';
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO t VALUES ('B','b10_requires_confirmation_ratchets',false,
    'flag cleared on '||n||' row(s) -- the basis marker is advisory');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b10_requires_confirmation_ratchets',true,SQLERRM); END $c$;

-- B11: a confirmation is not withdrawable; a bad reading is retired, not erased.
--
-- The ratification and the forbidden rewrite are in SEPARATE blocks, and the
-- first is asserted. Written as one block they both roll back when the rewrite
-- raises -- so the rule ends up never confirmed, B11 passes on a rule that was
-- never in the state it claims to test, and D4 then measures against the wrong
-- world. That is exactly the failure tests/40 records at B6, met again here.
DO $c$ BEGIN
  UPDATE obligation_rules
     SET confirmed_by='a1a1a1a1-0000-0000-0000-00000000a1a1', confirmed_at=now()
   WHERE rule_key='example.retain_records_after_decision';
  INSERT INTO t VALUES ('B','b11a_ctl_rule_ratification_persisted',
    (SELECT confirmed_at IS NOT NULL FROM obligation_rules
      WHERE rule_key='example.retain_records_after_decision'),
    'without this control B11 below can pass against an unconfirmed rule');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b11a_ctl_rule_ratification_persisted',false,SQLERRM); END $c$;

DO $c$ BEGIN
  UPDATE obligation_rules SET confirmed_at = now() + interval '1 day'
   WHERE rule_key='example.retain_records_after_decision';
  INSERT INTO t VALUES ('B','b11_confirmation_is_not_withdrawable',false,'confirmed_at rewritten');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b11_confirmation_is_not_withdrawable',true,SQLERRM); END $c$;

-- B12 and B13 need a CLOSED obligation, so they are set up here on the decision
-- duty and then asserted. The decision rule was confirmed by B11, which is also
-- what D5 measures against.
DO $c$ BEGIN
  INSERT INTO obligation_evidence (obligation_id,external_ref,description,recorded_by)
  VALUES ((SELECT _ids.v FROM _ids WHERE k='o_decision'),'zz46-filing-0001',
          'synthetic filing reference','a1a1a1a1-0000-0000-0000-00000000a1a1');
  PERFORM close_obligation((SELECT _ids.v FROM _ids WHERE k='o_decision'),
                           'a1a1a1a1-0000-0000-0000-00000000a1a1','satisfied','closed in test');
END $c$;

-- B12: back-filling evidence onto a closed duty would let the record be made to
-- justify a closure it did not support.
DO $c$ BEGIN
  INSERT INTO obligation_evidence (obligation_id,external_ref,description,recorded_by)
  VALUES ((SELECT _ids.v FROM _ids WHERE k='o_decision'),'zz46-filing-0002',
          'added after the fact','a1a1a1a1-0000-0000-0000-00000000a1a1');
  INSERT INTO t VALUES ('B','b12_evidence_cannot_be_added_after_closure',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b12_evidence_cannot_be_added_after_closure',true,SQLERRM); END $c$;

-- B13: nor removed, which would leave a satisfied duty with nothing behind it.
DO $c$ DECLARE n int; BEGIN
  DELETE FROM obligation_evidence
   WHERE obligation_id=(SELECT _ids.v FROM _ids WHERE k='o_decision');
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO t VALUES ('B','b13_closure_evidence_cannot_be_deleted',false,
    n||' evidence row(s) removed from a closed obligation');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b13_closure_evidence_cannot_be_deleted',true,SQLERRM); END $c$;


-- B14: the closure record is the attribution for the closure. Rewriting it
-- afterwards leaves a duty that still reads as properly satisfied by someone who
-- did not satisfy it.
--
-- THIS ASSERTION EXISTS BECAUSE A BROKEN RUN FOUND THE HOLE. With the evidence
-- check removed from the closure trigger, B2's "direct UPDATE is refused" turned
-- into a PASS-shaped failure: the row was already closed, so status did not
-- change, so the closure trigger returned early and the UPDATE went through on
-- the columns nobody was guarding. B2 alone could not see it because B2 only
-- exercises an OPEN obligation.
DO $c$ DECLARE n int; BEGIN
  UPDATE obligations
     SET closed_by='b2b2b2b2-0000-0000-0000-00000000b2b2', closure_note='rewritten'
   WHERE id=(SELECT _ids.v FROM _ids WHERE k='o_decision');
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO t VALUES ('B','b14_closure_record_immutable_once_closed',false,
    'closure attribution rewritten on '||n||' row(s) without reopening anything');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b14_closure_record_immutable_once_closed',true,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — COMPLETING THE ACTION NEVER DISCHARGES THE DUTY
-- ══════════════════════════════════════════════════════════════════════════

-- c1: the source task was driven to 'done' in Section A, with its own completion
-- evidence. The duty it generated is still open.
DO $c$ BEGIN
  INSERT INTO t VALUES ('C','c1_completing_source_task_leaves_duty_open',
    (SELECT o.status='open' AND o.closed_at IS NULL
       FROM obligations o WHERE o.id=(SELECT _ids.v FROM _ids WHERE k='o_action'))
    AND (SELECT status='done' FROM tasks WHERE id=(SELECT _ids.v FROM _ids WHERE k='t_action')),
    'task done, obligation still open');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c1_completing_source_task_leaves_duty_open',false,SQLERRM); END $c$;

-- c2: STRUCTURAL. No trigger on tasks carries a write verb toward obligations.
-- A source-text scan, and it says so: the enforcement is trg_obligation_closure_path
-- (proved by B2). This is the tripwire that makes a NEW such trigger show up in
-- a test run rather than in an audit.
DO $c$ BEGIN
  INSERT INTO t VALUES ('C','c2_no_task_trigger_writes_obligations',
    (SELECT coalesce(bool_and(NOT mentions_update_or_delete), false)
       FROM obligation_write_paths_from_tasks()),
    (SELECT string_agg(trigger_name||'->'||function_name, ', ')
       FROM obligation_write_paths_from_tasks() WHERE mentions_obligations));
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c2_no_task_trigger_writes_obligations',false,SQLERRM); END $c$;

-- c3: the near-miss. The task's own completion_evidence is the artifact most
-- likely to be mistaken for discharge. It is recorded on the task and touches
-- nothing on the obligation.
DO $c$ BEGIN
  INSERT INTO t VALUES ('C','c3_task_completion_evidence_does_not_touch_the_duty',
    (SELECT completion_evidence IS NOT NULL FROM tasks
      WHERE id=(SELECT _ids.v FROM _ids WHERE k='t_action'))
    AND (SELECT count(*)=0 FROM obligation_evidence
          WHERE obligation_id=(SELECT _ids.v FROM _ids WHERE k='o_action')),
    'task carries completion evidence; the duty has none');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c3_task_completion_evidence_does_not_touch_the_duty',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION D — THE LEGITIMATE PATH
-- ══════════════════════════════════════════════════════════════════════════

-- d1: a DIFFERENT task is admissible evidence, and closure then succeeds.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO tasks (title,kind,created_by,provenance_basis,owner,visibility,workstream,status,completed_at)
  VALUES ('zz46 file the notification','review','a1a1a1a1-0000-0000-0000-00000000a1a1',
          'human_direct','a1a1a1a1-0000-0000-0000-00000000a1a1','shared','alpha','done',now())
  RETURNING id INTO v;
  INSERT INTO _ids VALUES ('t_filing', v);
  INSERT INTO obligation_evidence (obligation_id,task_id,external_ref,description,recorded_by)
  VALUES ((SELECT _ids.v FROM _ids WHERE k='o_action'), v, 'zz46-submission-0007',
          'notification filed; submission identifier recorded',
          'a1a1a1a1-0000-0000-0000-00000000a1a1');
  INSERT INTO t VALUES ('D','d1_a_different_task_is_admissible_evidence',
    (SELECT count(*)=1 FROM obligation_evidence
      WHERE obligation_id=(SELECT _ids.v FROM _ids WHERE k='o_action')),
    'only the ORIGINATING task is refused');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d1_a_different_task_is_admissible_evidence',false,SQLERRM); END $c$;

DO $c$ BEGIN
  PERFORM close_obligation((SELECT _ids.v FROM _ids WHERE k='o_action'),
                           'a1a1a1a1-0000-0000-0000-00000000a1a1','satisfied',
                           'notification filed');
  INSERT INTO t VALUES ('D','d2_closure_with_evidence_succeeds',
    (SELECT status='satisfied' AND closed_by IS NOT NULL FROM obligations
      WHERE id=(SELECT _ids.v FROM _ids WHERE k='o_action')),
    'evidence present -> satisfied, attributed');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d2_closure_with_evidence_succeeds',false,SQLERRM); END $c$;

-- d3: terminal means terminal.
DO $c$ BEGIN
  PERFORM close_obligation((SELECT _ids.v FROM _ids WHERE k='o_action'),
                           'a1a1a1a1-0000-0000-0000-00000000a1a1','waived');
  INSERT INTO t VALUES ('D','d3_closed_duty_cannot_be_reopened_or_reclosed',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d3_closed_duty_cannot_be_reopened_or_reclosed',true,SQLERRM); END $c$;

-- d4: a seeded reading is not relied upon until someone ratifies it.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO tasks (title,kind,created_by,provenance_basis,owner,visibility,workstream)
  VALUES ('zz46 second decision','decision','a1a1a1a1-0000-0000-0000-00000000a1a1',
          'human_direct','a1a1a1a1-0000-0000-0000-00000000a1a1','shared','alpha')
  RETURNING id INTO v;
  INSERT INTO _ids VALUES ('t_decision2', v);
  -- example.notify_after_change is still UNCONFIRMED (B10 could not clear the
  -- flag and nobody ratified it), so a duty from it must report an unconfirmed
  -- basis. example.retain_records_after_decision WAS confirmed in B11.
  INSERT INTO t VALUES ('D','d4_confirmed_rule_reports_confirmed_basis',
    (SELECT basis_confirmed FROM obligation_board('a1a1a1a1-0000-0000-0000-00000000a1a1')
      WHERE source_task_id=v),
    'the decision rule was ratified in B11');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d4_confirmed_rule_reports_confirmed_basis',false,SQLERRM); END $c$;

-- d5: basis_confirmed is COMPUTED. The duty generated from the unratified rule
-- reports false, and nothing on the obligation row records it either way.
DO $c$ BEGIN
  INSERT INTO t VALUES ('D','d5_unconfirmed_rule_reports_unconfirmed_basis',
    (SELECT NOT basis_confirmed FROM obligation_board('a1a1a1a1-0000-0000-0000-00000000a1a1')
      WHERE obligation_id=(SELECT _ids.v FROM _ids WHERE k='o_action')),
    'example.notify_after_change was never ratified')
  ;
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d5_unconfirmed_rule_reports_unconfirmed_basis',false,SQLERRM); END $c$;

-- d6: and it flips the moment the reading is ratified, with no write to the
-- obligation. A stored copy would still be reporting the old answer.
DO $c$ BEGIN
  UPDATE obligation_rules
     SET confirmed_by='a1a1a1a1-0000-0000-0000-00000000a1a1', confirmed_at=now()
   WHERE rule_key='example.notify_after_change';
  INSERT INTO t VALUES ('D','d6_ratifying_a_rule_flips_basis_without_touching_the_duty',
    (SELECT basis_confirmed FROM obligation_board('a1a1a1a1-0000-0000-0000-00000000a1a1')
      WHERE obligation_id=(SELECT _ids.v FROM _ids WHERE k='o_action')),
    'computed on read, never stored');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d6_ratifying_a_rule_flips_basis_without_touching_the_duty',false,SQLERRM); END $c$;

-- d7: the board resolves visibility back to the SOURCE TASK. A duty derived from
-- a task P2 cannot read must not appear on P2's board -- and P1's must not be
-- emptied by the same rule.
DO $c$ DECLARE v uuid; o uuid; BEGIN
  INSERT INTO tasks (title,kind,created_by,provenance_basis,owner,visibility,workstream)
  VALUES ('zz46 private decision','decision','a1a1a1a1-0000-0000-0000-00000000a1a1',
          'human_direct','a1a1a1a1-0000-0000-0000-00000000a1a1','private','alpha')
  RETURNING id INTO v;
  SELECT id INTO o FROM obligations WHERE source_task_id=v;
  INSERT INTO t VALUES ('D','d7_board_resolves_visibility_from_the_source_task',
    NOT EXISTS (SELECT 1 FROM obligation_board('b2b2b2b2-0000-0000-0000-00000000b2b2')
                 WHERE obligation_id=o)
    AND EXISTS (SELECT 1 FROM obligation_board('a1a1a1a1-0000-0000-0000-00000000a1a1')
                 WHERE obligation_id=o),
    'hidden from the other principal, still visible to the owner');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d7_board_resolves_visibility_from_the_source_task',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION E — RULES ARE DATA
-- ══════════════════════════════════════════════════════════════════════════

-- e1: a new rule is a ROW. No DDL runs anywhere in this block.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO obligation_rules (rule_key,description,on_task_kind,on_task_workstream,
                                generate_on,duty_title,deadline_interval,evidence_requirement,
                                authority,citation,declared_by)
  VALUES ('zz46.alpha_review_followup','EXAMPLE ONLY, UNCONFIRMED.','review','alpha',
          'task_created','Produce the follow-up record',interval '5 days',
          'The follow-up record, cited by id.','synthetic authority','synthetic citation',
          'a1a1a1a1-0000-0000-0000-00000000a1a1');

  INSERT INTO tasks (title,kind,created_by,provenance_basis,owner,visibility,workstream)
  VALUES ('zz46 alpha review','review','a1a1a1a1-0000-0000-0000-00000000a1a1',
          'human_direct','a1a1a1a1-0000-0000-0000-00000000a1a1','shared','alpha')
  RETURNING id INTO v;

  INSERT INTO t VALUES ('E','e1_a_new_rule_is_a_row_not_a_migration',
    (SELECT count(*)=1 FROM obligations WHERE source_task_id=v),
    'rule inserted as data, next matching action generated a duty');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('E','e1_a_new_rule_is_a_row_not_a_migration',false,SQLERRM); END $c$;

-- e2: and the workstream selector actually selects.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO tasks (title,kind,created_by,provenance_basis,owner,visibility,workstream)
  VALUES ('zz46 beta review','review','a1a1a1a1-0000-0000-0000-00000000a1a1',
          'human_direct','a1a1a1a1-0000-0000-0000-00000000a1a1','shared','beta')
  RETURNING id INTO v;
  INSERT INTO t VALUES ('E','e2_workstream_scoped_rule_matches_only_that_workstream',
    (SELECT count(*)=0 FROM obligations WHERE source_task_id=v),
    'a beta review does not attract the alpha rule');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('E','e2_workstream_scoped_rule_matches_only_that_workstream',false,SQLERRM); END $c$;

-- e3: retiring a reading stops it generating, and leaves duties already
-- generated alone. Retiring is not a retraction of history.
DO $c$ DECLARE v uuid; n_before bigint; BEGIN
  SELECT count(*) INTO n_before FROM obligations o
    JOIN obligation_rules r ON r.id=o.rule_id
   WHERE r.rule_key='zz46.alpha_review_followup';
  UPDATE obligation_rules SET retired_at=now() WHERE rule_key='zz46.alpha_review_followup';
  INSERT INTO tasks (title,kind,created_by,provenance_basis,owner,visibility,workstream)
  VALUES ('zz46 alpha review after retirement','review','a1a1a1a1-0000-0000-0000-00000000a1a1',
          'human_direct','a1a1a1a1-0000-0000-0000-00000000a1a1','shared','alpha')
  RETURNING id INTO v;
  INSERT INTO t VALUES ('E','e3_retired_rule_stops_generating_but_keeps_history',
    (SELECT count(*)=0 FROM obligations WHERE source_task_id=v)
    AND (SELECT count(*) FROM obligations o JOIN obligation_rules r ON r.id=o.rule_id
          WHERE r.rule_key='zz46.alpha_review_followup') = n_before,
    'no new duty; the '||n_before||' existing one(s) untouched');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('E','e3_retired_rule_stops_generating_but_keeps_history',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION F — PERIMETER POSTURE
-- ══════════════════════════════════════════════════════════════════════════
-- A deny-all table and a table with a permissive policy look identical from the
-- service_role side, which is the only side this suite runs on.

DO $c$ BEGIN
  INSERT INTO t VALUES ('F','f1_rls_enabled_on_all_three_tables',
    (SELECT count(*)=3 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relrowsecurity
        AND c.relname IN ('obligation_rules','obligations','obligation_evidence')),
    'RLS enabled');
  INSERT INTO t VALUES ('F','f2_no_policies_so_deny_all',
    (SELECT count(*)=0 FROM pg_policies
      WHERE schemaname='public'
        AND tablename IN ('obligation_rules','obligations','obligation_evidence')),
    'RLS on with no policy is deny-all -- the sql/40 posture, deliberately');
  INSERT INTO t VALUES ('F','f3_no_privileges_for_anon_or_authenticated',
    (SELECT bool_and(NOT has_table_privilege(g, tb, p))
       FROM unnest(ARRAY['anon','authenticated']) AS gg(g)
       CROSS JOIN unnest(ARRAY['public.obligation_rules','public.obligations',
                               'public.obligation_evidence']) AS tt(tb)
       CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) AS pp(p)),
    'no table privilege of any kind');
  INSERT INTO t VALUES ('F','f4_functions_not_executable_by_authenticated',
    NOT has_function_privilege('authenticated','public.close_obligation(uuid,uuid,obligation_status,text)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.obligation_board(uuid)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.seed_obligation_rules(uuid)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.generate_obligations_for_task(uuid,obligation_trigger)','EXECUTE'),
    'the whole surface is service_role only');
  -- Migration 62 revoked TRUNCATE from service_role across public and vault_auth
  -- and stopped ALTER DEFAULT PRIVILEGES re-granting it. That sweep ran BEFORE
  -- these three tables existed, so it cannot have cleaned them -- the only thing
  -- keeping them clean is the changed default, and a changed default is exactly
  -- the kind of thing that gets re-established by a later grant nobody reads.
  -- Asserted here rather than assumed inherited.
  INSERT INTO t VALUES ('F','f5_new_tables_do_not_confer_truncate_on_service_role',
    (SELECT bool_and(NOT has_table_privilege('service_role', tb, 'TRUNCATE'))
       FROM unnest(ARRAY['public.obligation_rules','public.obligations',
                         'public.obligation_evidence']) AS tt(tb)),
    'tables created after migration 62 must not inherit TRUNCATE');
  -- ...and the destructive_grant category must not be reporting them either.
  -- CATEGORY-FILTERED, so it keeps using the primitive -- but it is paired with
  -- the evaluation status, because a category filter is the exact shape that
  -- fails open: on a host missing the platform roles the primitive returns no
  -- rows at all and this filter reports clean. Migration 76.
  INSERT INTO t VALUES ('F','f6_no_destructive_grant_findings_on_the_new_tables',
    (SELECT evaluation_status='evaluated' FROM perimeter_report())
    AND (SELECT count(*)=0 FROM perimeter_assert()
      WHERE category='destructive_grant'
        AND object_name IN ('obligation_rules','obligations','obligation_evidence')),
    'the migration 62 checker sees nothing on these three, on a host where it could look');
  INSERT INTO t VALUES ('F','f7_perimeter_clean',
    (SELECT evaluation_status='evaluated' AND violation_count=0 FROM perimeter_report()),
    (SELECT 'status='||evaluation_status||' violations='||
            coalesce(violation_count::text,'NULL') FROM perimeter_report()));
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('F','f1_rls_enabled_on_all_three_tables',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- RESULTS
-- ══════════════════════════════════════════════════════════════════════════
SELECT section, test, pass, left(detail,72) AS detail FROM t ORDER BY section, test;

SELECT 'A_controls' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' AS detail FROM t WHERE section='A'
UNION ALL SELECT 'B_required_negatives', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' still ACCEPTED' FROM t WHERE section='B'
UNION ALL SELECT 'C_action_never_discharges_duty', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t WHERE section='C'
UNION ALL SELECT 'D_legitimate_path', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' BROKEN by the guards' FROM t WHERE section='D'
UNION ALL SELECT 'E_rules_are_data', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t WHERE section='E'
UNION ALL SELECT 'F_perimeter_posture', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' failed' FROM t WHERE section='F';

SELECT 'GUARD_no_null_assertions' AS summary,
       coalesce(bool_and(pass IS NOT NULL), false) AS pass,
       count(*) FILTER (WHERE pass IS NULL)::text||' assertion(s) evaluated to NULL' AS detail FROM t;

-- A DO block that raises before its INSERT records nothing, and a section that
-- silently produced no rows reads as a section with no failures. Pinning the
-- count is what makes the two distinguishable.
SELECT 'GUARD_expected_assertion_count' AS summary,
       count(*) = 40 AS pass,
       'ran '||count(*)||' assertions, expected 40' AS detail FROM t;

SELECT CASE WHEN bool_and(coalesce(pass,false)) AND count(*) = 40
            THEN 'SUITE_RESULT: PASS' ELSE 'SUITE_RESULT: FAIL' END AS verdict FROM t;

ROLLBACK;
