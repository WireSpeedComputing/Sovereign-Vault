-- tests/23_promotion_guards_negative.sql
-- ADOPT: upstream sovereign-memory-core #46 (promotion guards) and #47
-- (promoted-record mutation audit). Covers sql/26_propose_then_promote.sql.
--
-- Run against a FRESH database (tests/replay_fresh_install.sh). Self-contained:
-- creates its own principals, batch, and artifacts, and rolls back.
--
-- ── HOW TO READ A RESULT ────────────────────────────────────────────────────
-- Sections A, B and C: `pass` must be TRUE. B and C are FAILING-NEGATIVES —
-- TRUE means the forbidden operation was REJECTED, not that it succeeded.
--
-- Section A is a positive control over guards that predate this work. If A ever
-- goes false, the harness is broken and B/C mean nothing. A negative-test file
-- with no control is how a suite ends up proving only that it can run.
--
-- Section D is DOCUMENTED LIMITS. Those tests pass when the known bypass still
-- works. That reads backwards on purpose: the limit is real, it is written into
-- sql/13, sql/20 and sql/26, and encoding it here means it shows up in test
-- output instead of living only in prose. If a D test starts FAILING, someone
-- has changed the enforcement story and the documentation is now wrong — that
-- is a docs bug, not a test bug.
--
-- ── HISTORY ─────────────────────────────────────────────────────────────────
-- At commit 161b835 this file was all-red in Section B: nine forbidden paths
-- probed, eight open. sql/26 closes them. The assertions were written against
-- the doctrine BEFORE the fix existed and were not relaxed to fit it.
--
-- ── ON PRIVILEGE CONTEXT ────────────────────────────────────────────────────
-- These run as a superuser, which bypasses RLS. Deliberate, and a faithful model
-- of the deployment rather than a cheat: `memories` and `wiki_pages` have RLS
-- enabled with ZERO policies and all privileges revoked from anon and
-- authenticated, so every write in production necessarily arrives via
-- service_role (which carries BYPASSRLS) or a SECURITY DEFINER function. RLS is
-- not load-bearing for these paths. Triggers are the only enforcement layer that
-- actually executes, and triggers fire for superusers too.

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com');
INSERT INTO principals (id,kind,display_name,agent_label) VALUES
 ('33333333-3333-3333-3333-333333333333','agent','A1','A1');

INSERT INTO import_batches (id, source_system, description, initiated_by)
VALUES ('bbbbbbbb-0000-0000-0000-00000000000b','test-source','#46 guard tests',
        '11111111-1111-1111-1111-111111111111');

INSERT INTO raw_artifacts (id,batch_id,source_system,source_id,payload,payload_sha256,action,zone,action_reason)
VALUES
 ('a0000000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-00000000000b','test-source','hold-1','{"t":"held"}','h1','hold','hold','test fixture'),
 ('a0000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-00000000000b','test-source','excl-1','{"t":"excluded"}','h2','exclude','vault','test fixture'),
 ('a0000000-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-00000000000b','test-source','evid-1','{"t":"evidence"}','h3','evidence','evidence','test fixture'),
 ('a0000000-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-00000000000b','test-source','impt-1','{"t":"import"}','h4','import','vault','test fixture');
-- action IS NULL by design: "classification is explicit, never defaulted".
INSERT INTO raw_artifacts (id,batch_id,source_system,source_id,payload,payload_sha256)
VALUES ('a0000000-0000-0000-0000-000000000005','bbbbbbbb-0000-0000-0000-00000000000b','test-source','unclass-1','{"t":"unclassified"}','h5');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — POSITIVE CONTROL over pre-existing guards. All must be TRUE.
-- Every insert here lands at 'proposed'. That is not incidental: after sql/26,
-- inserting at 'current' is rejected by the status sanction, so a control that
-- inserted at 'current' would go green on the wrong guard and stop proving the
-- thing it names.
-- ══════════════════════════════════════════════════════════════════════════

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, status, owner, visibility)
  VALUES ('no basis','manual','proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',true,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('no citation','manual','source_document','proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_missing_citation_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_missing_citation_rejected',true,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, status, owner, visibility)
  VALUES ('agent claims human','agent','A1','human_direct','proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_agent_human_direct_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_agent_human_direct_rejected',true,SQLERRM); END $c$;

DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('candidate','manual','human_direct','proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  UPDATE memories SET status='current' WHERE id=v;
  INSERT INTO t VALUES ('A','ctl_bare_status_update_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_bare_status_update_rejected',true,SQLERRM); END $c$;

DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('candidate2','manual','human_direct','proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'33333333-3333-3333-3333-333333333333');
  INSERT INTO t VALUES ('A','ctl_agent_principal_cannot_promote',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_agent_principal_cannot_promote',true,SQLERRM); END $c$;

-- double promotion: reaches 'current' only through the sanctioned path, which
-- is now the only way a current row can exist at all.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('already current','manual','human_direct','proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('A','ctl_cannot_promote_twice',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_cannot_promote_twice',true,SQLERRM); END $c$;

-- An artifact id that does not exist is rejected. Post-sql/26 the classification
-- allowlist catches this before the FK does (an unknown id has no action, and
-- the allowlist requires action='import'), so this control no longer isolates
-- FK integrity -- it is named for what it now proves, not what it used to.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status,
                        source_artifact_id, owner, visibility)
  VALUES ('ghost artifact','imported_artifact','imported_artifact','x','proposed',
          'dddddddd-dddd-dddd-dddd-dddddddddddd','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_unknown_artifact_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_unknown_artifact_rejected',true,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — THE #46 FORBIDDEN PATHS. All must be TRUE.
-- ══════════════════════════════════════════════════════════════════════════

-- B1-B4: a non-promotable artifact must not become authoritative memory. The
-- attempt is the realistic one: normalize to 'proposed' with correct provenance,
-- then promote through the sanctioned human gate.
-- B4 is the case upstream #46 does not name: action IS NULL. It is the DEFAULT
-- state of every landed artifact, which is why the guard is an allowlist on
-- action='import' and not a denylist on hold/exclude/evidence.
DO $c$
DECLARE r record; v_id uuid;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('b1_hold_artifact_cannot_become_authority',        'a0000000-0000-0000-0000-000000000001'::uuid),
      ('b2_exclude_artifact_cannot_become_authority',     'a0000000-0000-0000-0000-000000000002'::uuid),
      ('b3_evidence_artifact_cannot_normalize_to_fact',   'a0000000-0000-0000-0000-000000000003'::uuid),
      ('b4_unclassified_artifact_cannot_become_authority','a0000000-0000-0000-0000-000000000005'::uuid)
    ) AS v(label, art)
  LOOP
    BEGIN
      INSERT INTO memories (content, source_kind, provenance_basis, citation, status,
                            source_artifact_id, owner, visibility)
      VALUES ('normalized from '||r.label,'imported_artifact','imported_artifact',
              'raw_artifacts:'||r.art,'proposed',r.art,
              '11111111-1111-1111-1111-111111111111','shared')
      RETURNING id INTO v_id;
      PERFORM promote_memory(v_id,'11111111-1111-1111-1111-111111111111');
      INSERT INTO t VALUES ('B',r.label,false,'normalized and promoted to current');
    EXCEPTION WHEN others THEN
      INSERT INTO t VALUES ('B',r.label,true,SQLERRM);
    END;
  END LOOP;
END $c$;

-- B4b: an ordinary writer that never mentions status must still work. The
-- column default was 'current' (sql/01), so before sql/26 moved it to
-- 'proposed' this insert was rejected with an error naming a value the caller
-- never set -- which would have broken every existing writer on apply day.
-- This asserts the default and the guard agree.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, owner, visibility)
  VALUES ('ordinary write, status omitted','manual','human_direct',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  INSERT INTO t VALUES ('B','b4b_status_omitted_write_lands_proposed',
    (SELECT status='proposed' FROM memories WHERE id=v),
    'default is proposed, so omitting status is not a trap');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b4b_status_omitted_write_lands_proposed',false,SQLERRM); END $c$;

-- B5: a structurally valid import package must not, by itself, confer authority.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status,
                        source_artifact_id, owner, visibility)
  VALUES ('import package asserts itself authoritative','imported_artifact',
          'imported_artifact','raw_artifacts:impt-1','current',
          'a0000000-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b5_import_package_cannot_self_confer_authority',false,
    'inserted directly at current, bypassing promote_memory entirely');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b5_import_package_cannot_self_confer_authority',true,SQLERRM); END $c$;

-- B6: same hole via source_kind='ingest', with no artifact at all. This is the
-- test that proves the guard is not keyed on source_kind -- a caller-declared
-- field would be bypassable by simply declaring something else.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status, owner, visibility)
  VALUES ('ingest asserts itself authoritative','ingest','source_document','doc:x','current',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b6_ingest_cannot_self_confer_authority',false,
    'inserted directly at current with no human gate');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b6_ingest_cannot_self_confer_authority',true,SQLERRM); END $c$;

-- B6b: and via source_kind='manual', the declaration a bypasser would actually use.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('manual assertion of authority','manual','human_direct','current',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b6b_manual_cannot_self_confer_authority',false,
    'inserted directly at current with no human gate');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b6b_manual_cannot_self_confer_authority',true,SQLERRM); END $c$;

-- B7: agent-authored content must not reach 'current' without explicit review.
-- Pre-sql/26 the schema permitted this whenever the agent declared
-- provenance_basis='decision_record', with nothing verifying such a record
-- existed. The citation below says so in as many words.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('agent fact, self-declared decision record','agent','A1','decision_record',
          'decision: none actually exists','current',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b7_agent_cannot_self_certify_decision_record',false,
    'agent row landed at current on an unverified decision_record claim');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b7_agent_cannot_self_certify_decision_record',true,SQLERRM); END $c$;

-- B8: the approved import path must REMAIN possible (#46 acceptance criterion).
-- A guard that closes B1-B7 by also closing this has broken the system rather
-- than secured it.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status,
                        source_artifact_id, owner, visibility)
  VALUES ('legitimately imported fact','imported_artifact','imported_artifact',
          'raw_artifacts:impt-1','proposed','a0000000-0000-0000-0000-000000000004',
          '11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('B','b8_approved_import_path_still_works',
    (SELECT status='current' FROM memories WHERE id=v),'promoted via human gate');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b8_approved_import_path_still_works',false,SQLERRM); END $c$;

-- B9: supersession must REMAIN possible. This is the regression test for the
-- bug the Part 1 trigger exposed: supersede_memory's successor row is inserted
-- at status='current', so if the GUC span does not cover that INSERT, the new
-- guard blocks legitimate supersession. Verified failing before the span was
-- widened.
DO $c$ DECLARE v uuid; v_new uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('fact to be corrected','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  v_new := supersede_memory(v,'corrected fact','decision_record','cite',
                            '11111111-1111-1111-1111-111111111111','regression');
  INSERT INTO t VALUES ('B','b9_supersession_still_works',
    (SELECT status='current' FROM memories WHERE id=v_new)
    AND (SELECT status='superseded' FROM memories WHERE id=v),
    'successor current, predecessor superseded');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b9_supersession_still_works',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — #47 PROMOTED-RECORD MUTATION AUDIT. All must be TRUE.
-- ══════════════════════════════════════════════════════════════════════════

-- C1: a silent post-promotion content edit must be refused.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('promoted truth','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  UPDATE memories SET content='silently rewritten after promotion' WHERE id=v;
  INSERT INTO t VALUES ('C','c1_promoted_content_edit_rejected',false,
    'content of a current row rewritten in place');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c1_promoted_content_edit_rejected',true,SQLERRM); END $c$;

-- C2: swapping the citation is the same class of tamper as rewriting the prose.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status, owner, visibility)
  VALUES ('sourced claim','imported_artifact','source_document','contract A, p3','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  UPDATE memories SET citation='contract B, p9' WHERE id=v;
  INSERT INTO t VALUES ('C','c2_promoted_citation_swap_rejected',false,'citation swapped in place');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c2_promoted_citation_swap_rejected',true,SQLERRM); END $c$;

-- C3: editing a PROPOSED candidate must remain unrestricted. This is the
-- distinction the docs previously did not draw: a candidate is work in progress,
-- a promoted record is a published claim.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('draft claim','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  UPDATE memories SET content='revised draft claim' WHERE id=v;
  INSERT INTO t VALUES ('C','c3_proposed_candidate_stays_editable',
    (SELECT content='revised draft claim' FROM memories WHERE id=v),'candidate edited');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c3_proposed_candidate_stays_editable',false,SQLERRM); END $c$;

-- C4: operational fields on a promoted row must stay mutable. Marking a
-- deadline done is not a rewrite of what was promoted.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility,
                        due_date, due_status)
  VALUES ('deliverable due','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared', now()+interval '2 days','pending')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  UPDATE memories SET due_status='done' WHERE id=v;
  INSERT INTO t VALUES ('C','c4_operational_fields_stay_mutable',
    (SELECT due_status='done' FROM memories WHERE id=v),'due_status updated on a current row');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c4_operational_fields_stay_mutable',false,SQLERRM); END $c$;

-- C5: promotion writes a receipt.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('receipted fact','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('C','c5_promotion_writes_audit_receipt',
    (SELECT count(*)=1 FROM promoted_record_audit
      WHERE record_id=v AND event='promoted'
        AND actor='11111111-1111-1111-1111-111111111111'),'receipt present with actor');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c5_promotion_writes_audit_receipt',false,SQLERRM); END $c$;

-- C6: an untampered promoted row verifies as 'match'.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('verifiable fact','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('C','c6_untampered_row_verifies_match',
    (SELECT state='match' FROM verify_promoted_integrity() WHERE record_id=v),'state=match');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c6_untampered_row_verifies_match',false,SQLERRM); END $c$;

-- C7: THE DETECTION TEST. The guard in C1 is prevention; this proves the audit
-- catches an edit that got PAST prevention. The trigger is disabled to simulate
-- exactly the bypass the docs admit is possible -- a superuser, or a caller who
-- armed the GUC. If this ever goes false, tampering is undetectable and the
-- whole #47 answer is hollow.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('tamper target','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  ALTER TABLE memories DISABLE TRIGGER trg_promoted_record_immutable_memories;
  UPDATE memories SET content='tampered behind the guard' WHERE id=v;
  ALTER TABLE memories ENABLE TRIGGER trg_promoted_record_immutable_memories;
  INSERT INTO t VALUES ('C','c7_bypassed_edit_is_detected',
    (SELECT state='mismatch' FROM verify_promoted_integrity() WHERE record_id=v),
    'verify_promoted_integrity reports mismatch');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c7_bypassed_edit_is_detected',false,SQLERRM); END $c$;

-- C8: the receipt table is append-only. An audit trail that can be edited is not one.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('audit immutability','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  UPDATE promoted_record_audit SET content_sha256='forged' WHERE record_id=v;
  INSERT INTO t VALUES ('C','c8_audit_table_is_append_only',false,'receipt was updated');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c8_audit_table_is_append_only',true,SQLERRM); END $c$;

-- C9: a current row with no receipt reports 'unaudited', not 'match'. Silence
-- about a row must never read as a clean bill of health -- every row promoted
-- BEFORE sql/26 is in exactly this state.
--
-- The unaudited row is produced by arming the GUC and inserting at 'current'
-- directly, which is precisely how a pre-migration row looks: authoritative,
-- no receipt. The first draft of this test deleted the receipt instead, and the
-- append-only guard (C8) correctly refused -- the test was wrong, not the guard.
DO $c$ DECLARE v uuid; BEGIN
  PERFORM set_config('app.promoting','on',true);
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('legacy promoted row','manual','human_direct','current',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('C','c9_unaudited_row_reports_unaudited',
    (SELECT state='unaudited' FROM verify_promoted_integrity() WHERE record_id=v),
    'state=unaudited');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('C','c9_unaudited_row_reports_unaudited',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION D — DOCUMENTED LIMITS. TRUE means the known bypass still works.
-- Read the header before concluding anything from these.
-- ══════════════════════════════════════════════════════════════════════════

-- D1: app.promoting is a session GUC. Any caller holding service_role can arm it
-- and walk through every guard in sql/26. This closes the ACCIDENTAL path, not
-- the deliberate one. Recorded in sql/13, sql/20 and sql/26; asserted here so it
-- is visible in test output rather than only in prose.
-- Closing it for real requires per-principal connection identity (vault_auth),
-- not another trigger.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('agent fact awaiting review','agent','A1','imported_artifact','artifact:x',
          'proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM set_config('app.promoting','on',true);
  UPDATE memories SET status='current' WHERE id=v;
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('D','limit_caller_can_self_arm_promotion_guard',
    (SELECT status='current' FROM memories WHERE id=v),
    'KNOWN LIMIT: bare UPDATE reached current by setting app.promoting directly');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('D','limit_caller_can_self_arm_promotion_guard',false,
    'enforcement changed -- sql/13, sql/20, sql/26 and STATUS.md now overstate the limit: '||SQLERRM); END $c$;

-- D2: the same GUC also opens the INSERT path added by sql/26. Stated separately
-- because a reader could reasonably assume the new BEFORE INSERT guard is
-- stronger than the older BEFORE UPDATE one. It is not; it is the same GUC.
DO $c$ BEGIN
  PERFORM set_config('app.promoting','on',true);
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('self-armed direct insert','manual','human_direct','current',
          '11111111-1111-1111-1111-111111111111','shared');
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('D','limit_self_armed_guc_permits_direct_insert',true,
    'KNOWN LIMIT: direct INSERT at current succeeds while the GUC is armed');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('D','limit_self_armed_guc_permits_direct_insert',false,
    'enforcement changed -- docs now overstate the limit: '||SQLERRM); END $c$;


-- ── Results ────────────────────────────────────────────────────────────────
SELECT section, test, pass, left(detail,72) AS detail FROM t ORDER BY section, test;

SELECT 'A_controls'  AS summary, bool_and(pass) AS pass,
       count(*) FILTER (WHERE NOT pass)::text||' of '||count(*)::text||' failed' AS detail
FROM t WHERE section='A'
UNION ALL
SELECT 'B_46_forbidden_paths_closed', bool_and(pass),
       count(*) FILTER (WHERE NOT pass)::text||' of '||count(*)::text||' still OPEN'
FROM t WHERE section='B'
UNION ALL
SELECT 'C_47_mutation_audit', bool_and(pass),
       count(*) FILTER (WHERE NOT pass)::text||' of '||count(*)::text||' failed'
FROM t WHERE section='C'
UNION ALL
SELECT 'D_documented_limits_still_present', bool_and(pass),
       count(*) FILTER (WHERE NOT pass)::text||' of '||count(*)::text||' changed -- update the docs'
FROM t WHERE section='D';

ROLLBACK;
