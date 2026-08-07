-- tests/23_promotion_guards_negative.sql
-- ADOPT: upstream sovereign-memory-core#46 — review and promotion guard tests.
--
-- Run against a FRESH database (tests/replay_fresh_install.sh). Self-contained:
-- creates its own principals, batch, and artifacts, and rolls back.
--
-- ── READ THIS BEFORE INTERPRETING A RESULT ──────────────────────────────────
-- Every test here is a FAILING-NEGATIVE: `pass` is TRUE only when the forbidden
-- operation was REJECTED. `pass = false` means the path is OPEN.
--
-- AS OF THIS COMMIT, SECTION B IS EXPECTED TO BE ALL-FALSE. That is not a
-- broken test file; it is the finding. Nine forbidden paths were probed against
-- a clean PG17 replay of sql/00-22 and all nine were open. The tests assert the
-- behaviour the upstream doctrine requires, so they stay red until the guard
-- lands, and they go green the moment it does. Do not "fix" them by weakening
-- the assertion to match current behaviour.
--
-- SECTION A is a positive control. Those seven paths ARE guarded today and must
-- all be TRUE. If section A ever goes false, the harness itself is broken and
-- section B's results mean nothing. A negative-test file with no control is how
-- a suite ends up proving only that it can run.
--
-- ── ON PRIVILEGE CONTEXT ────────────────────────────────────────────────────
-- These run as a superuser, which bypasses RLS. That is deliberate and it is a
-- faithful model of the deployment, not a cheat: `memories` and `wiki_pages`
-- have RLS enabled with ZERO policies and all privileges revoked from anon and
-- authenticated, so every write in production necessarily arrives via
-- service_role (which carries BYPASSRLS) or a SECURITY DEFINER function. RLS is
-- therefore not load-bearing for these paths. Triggers are the only enforcement
-- layer that actually executes, and triggers fire for superusers too.

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;

-- helper: record whether a statement raised. pass = it raised (rejection held).
-- Each attempt runs in its own subtransaction so a failure does not poison the
-- rest of the file.

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
-- SECTION A — POSITIVE CONTROL. All must be TRUE.
-- These prove the harness can distinguish a closed path from an open one.
-- ══════════════════════════════════════════════════════════════════════════

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, status, owner, visibility)
  VALUES ('no basis','manual','current','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',true,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('no citation','manual','source_document','current','11111111-1111-1111-1111-111111111111','shared');
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

DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('already current','manual','human_direct','current','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('A','ctl_cannot_promote_current_row',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_cannot_promote_current_row',true,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status,
                        source_artifact_id, owner, visibility)
  VALUES ('ghost artifact','imported_artifact','imported_artifact','x','proposed',
          'dddddddd-dddd-dddd-dddd-dddddddddddd','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_dangling_artifact_fk_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_dangling_artifact_fk_rejected',true,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — THE #46 FORBIDDEN PATHS. All must be TRUE once the guard lands.
-- Currently all FALSE. See header.
-- ══════════════════════════════════════════════════════════════════════════

-- B1/B2/B3 + B4: a non-promotable artifact must not become authoritative memory.
-- The attempt is the realistic one: normalize to 'proposed' with correct
-- provenance, then promote through the sanctioned human gate. promote_memory()
-- never inspects the source artifact, so the classification is not consulted.
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

-- B5: a structurally valid import package must not, by itself, confer authority.
-- Nothing gates INSERT-time status for non-agent source kinds, so the human
-- gate is optional rather than mandatory.
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

-- B6: same hole via source_kind='ingest', with no artifact at all.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status, owner, visibility)
  VALUES ('ingest asserts itself authoritative','ingest','source_document','doc:x','current',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b6_ingest_cannot_self_confer_authority',false,
    'inserted directly at current with no human gate');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b6_ingest_cannot_self_confer_authority',true,SQLERRM); END $c$;

-- B7: agent-authored content must not reach 'current' without explicit human
-- review. The schema permits it when the agent declares
-- provenance_basis='decision_record' -- but nothing verifies that a decision
-- record exists. The citation below says so in as many words and still lands.
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

-- B8: the sanctioned-transition guard is a transaction GUC any caller can set.
-- Already recorded as an honest limit in sql/13; asserted here so it is visible
-- in the suite rather than only in a comment.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('agent fact awaiting review','agent','A1','imported_artifact','artifact:x',
          'proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM set_config('app.promoting','on',true);
  UPDATE memories SET status='current' WHERE id=v;
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('B','b8_caller_cannot_self_arm_promotion_guard',false,
    'bare UPDATE reached current by setting app.promoting directly');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('B','b8_caller_cannot_self_arm_promotion_guard',true,SQLERRM); END $c$;

-- B9: the approved import path must REMAIN possible (#46 acceptance criterion).
-- This one is TRUE today and must stay TRUE after any fix. A guard that closes
-- B1-B8 by also closing this has broken the system rather than secured it.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status,
                        source_artifact_id, owner, visibility)
  VALUES ('legitimately imported fact','imported_artifact','imported_artifact',
          'raw_artifacts:impt-1','proposed','a0000000-0000-0000-0000-000000000004',
          '11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('B','b9_approved_import_path_still_works',
    (SELECT status='current' FROM memories WHERE id=v),'promoted via human gate');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b9_approved_import_path_still_works',false,SQLERRM); END $c$;


-- ── Results ────────────────────────────────────────────────────────────────
SELECT section, test, pass, left(detail,80) AS detail FROM t ORDER BY section, test;

SELECT 'SECTION_A_control_all_pass' AS summary,
       bool_and(pass) AS pass,
       count(*) FILTER (WHERE NOT pass)::text || ' control failures' AS detail
FROM t WHERE section='A';

SELECT 'SECTION_B_forbidden_paths_all_closed' AS summary,
       bool_and(pass) AS pass,
       count(*) FILTER (WHERE NOT pass)::text || ' of ' || count(*)::text || ' still OPEN' AS detail
FROM t WHERE section='B';

ROLLBACK;
