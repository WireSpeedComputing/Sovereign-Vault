-- tests/33_agent_registry_integrity.sql
-- Covers sql/33_agent_registry_integrity.sql.
-- ADOPT: sibling protocol repo sovereign-memory-core, the referential integrity
-- behind its `trusted_agents` registry. (The work order cited #4; #4 is closed
-- with no content -- see sql/33's SOURCING NOTE.)
--
-- Run against a FRESH database (tests/replay_fresh_install.sh). Self-contained.
--
-- ── HOW TO READ A RESULT ────────────────────────────────────────────────────
--   A  POSITIVE CONTROLS over guards that predate this file. If A goes false the
--      harness is broken and nothing else here means anything.
--   B  FAILING-NEGATIVES. TRUE means the write was REJECTED.
--   C  LEGITIMATE PATH. TRUE means writing still WORKS where it should. C4 is
--      the one that matters most: an earlier draft of sql/33 made every wiki
--      page authored by a since-deactivated agent permanently uncorrectable,
--      and C4 is the test that catches it.
--   D  DOCUMENTED LIMITS. TRUE means a known, written-down weakness is still
--      present. A failing D test is a docs bug.
--
-- ── DISCRIMINATION ──────────────────────────────────────────────────────────
-- Run against a schema with sql/33 absent: every B assertion goes red (the
-- writes are accepted) while A, C and D stay green. See docs/10.

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com');
-- An ACTIVE agent.
INSERT INTO principals (id,kind,display_name,agent_label) VALUES
 ('33333333-3333-3333-3333-333333333333','agent','A1','A1'),
 ('77777777-7777-7777-7777-777777777777','agent','A2','A2');
-- A RETIRED agent. Its historical work must stay correctable.
INSERT INTO principals (id,kind,display_name,agent_label,active,deactivated_at) VALUES
 ('55555555-5555-5555-5555-555555555555','agent','A-RETIRED','A-RETIRED',false, now());
-- A HUMAN that happens to carry an agent_label. agent_label is a partial unique
-- index, not a kind constraint, so nothing in sql/02 stops this. The guard must
-- key on kind='agent', not merely on the label resolving to some principal.
INSERT INTO principals (id,kind,display_name,email,agent_label) VALUES
 ('66666666-6666-6666-6666-666666666666','human','H-LABELLED','h2@example.com','NOT-AN-AGENT');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — POSITIVE CONTROLS. All must be TRUE.
-- ══════════════════════════════════════════════════════════════════════════

-- A1: sql/03 still rejects a missing provenance basis.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, status, owner, visibility)
  VALUES ('control no basis','manual','proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',true,SQLERRM); END $c$;

-- A2: sql/03 still rejects an agent claiming human_direct authorship. This is
-- the OTHER agent-related guard; if it silently stopped firing, a reader could
-- mistake B's greens for it rather than for sql/33.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, status, owner, visibility)
  VALUES ('agent claims human','agent','A1','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_agent_human_direct_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_agent_human_direct_rejected',true,SQLERRM); END $c$;

-- A3: sql/26 still makes status=current unreachable by direct INSERT.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('control direct current','manual','human_direct','current',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_direct_insert_at_current_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_direct_insert_at_current_rejected',true,SQLERRM); END $c$;

-- A4: the state function is TOTAL. The trigger BRANCHES on this value, so a
-- NULL would match no branch and fall through to acceptance -- fail open.
INSERT INTO t VALUES ('A','ctl_agent_label_state_is_total',
  (SELECT bool_and(agent_label_state(v) IS NOT NULL)
   FROM (VALUES (NULL::text),('A1'),('A-RETIRED'),('NOT-AN-AGENT'),('NEVER-EXISTED'),('')) x(v)),
  'no input yields NULL');

-- A5: and it discriminates. If every input returned the same state, every B and
-- C test below would be testing one branch.
INSERT INTO t VALUES ('A','ctl_agent_label_state_discriminates',
  (SELECT agent_label_state(NULL) = 'no_agent'
      AND agent_label_state('A1') = 'active'
      AND agent_label_state('A-RETIRED') = 'inactive'
      AND agent_label_state('NEVER-EXISTED') = 'unregistered'
      AND agent_label_state('NOT-AN-AGENT') = 'unregistered'),
  'no_agent / active / inactive / unregistered all reachable');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — FAILING-NEGATIVES. All must be TRUE (= the write was REJECTED).
-- ══════════════════════════════════════════════════════════════════════════

-- B1: a source_agent naming nothing at all is rejected on memories.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('fabricated attribution','agent','GHOST-AGENT','source_document','doc p.1',
          'proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b1_unregistered_agent_rejected_memories',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('B','b1_unregistered_agent_rejected_memories',
  (SQLERRM LIKE '%not a registered agent principal%'), SQLERRM); END $c$;

-- B2: and on wiki_pages. sql/22 added the column; nothing validated it.
--
-- status='proposed' deliberately. The first draft of this test inserted at
-- 'current', went green, and was green on the WRONG GUARD: sql/03's
-- enforce_agent_cannot_self_attest rejects any agent-sourced row landing at
-- 'current' without provenance_basis='decision_record', so the row never
-- reached sql/33 at all. Caught by reading the SQLERRM in the result column
-- rather than the pass column. Inserting at 'proposed' clears sql/03 and leaves
-- sql/33 as the only thing that can reject this row.
DO $c$ BEGIN
  INSERT INTO wiki_pages (path,title,content,source_kind,source_agent,provenance_basis,
                          citation,status,owner,visibility)
  VALUES ('test/ghost','Ghost','body','agent','GHOST-AGENT','source_document','doc p.1',
          'proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b2_unregistered_agent_rejected_wiki',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('B','b2_unregistered_agent_rejected_wiki',
  -- assert on WHICH guard rejected it, not merely that something did
  (SQLERRM LIKE '%not a registered agent principal%'), SQLERRM); END $c$;

-- B3: a label that resolves to a HUMAN principal is rejected. The registry is
-- "agent principals", not "any principal that happens to carry a label".
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('human wearing an agent label','agent','NOT-AN-AGENT','source_document','doc p.2',
          'proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b3_human_label_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('B','b3_human_label_rejected',
  (SQLERRM LIKE '%not a registered agent principal%'), SQLERRM); END $c$;

-- B4: a DEACTIVATED agent cannot author a NEW row. Deactivation that still
-- permits authorship is deactivation in name only.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('retired agent writes new','agent','A-RETIRED','source_document','doc p.3',
          'proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('B','b4_deactivated_agent_cannot_author_new',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('B','b4_deactivated_agent_cannot_author_new',
  (SQLERRM LIKE '%DEACTIVATED agent principal%'), SQLERRM); END $c$;

-- B5: an UPDATE that CHANGES source_agent to an unregistered label is rejected.
-- Without this the guard covers only the INSERT door -- exactly the hole sql/26
-- found in the promotion guards ("no guard ran on the INSERT path at all",
-- inverted).
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('legit then relabelled','agent','A1','source_document','doc p.4',
          'proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  UPDATE memories SET source_agent = 'GHOST-AGENT' WHERE id = v;
  INSERT INTO t VALUES ('B','b5_update_to_unregistered_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('B','b5_update_to_unregistered_rejected',
  (SQLERRM LIKE '%not a registered agent principal%'), SQLERRM); END $c$;

-- B6: REGISTRATION is not waived by a sanctioned transition. The activeness tier
-- is waived while app.promoting is armed; the registration tier must NOT be, or
-- arming the GUC would buy a fabricated attribution as well as a retired one.
DO $c$ BEGIN
  PERFORM set_config('app.promoting','on',true);
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('ghost inside a sanctioned transition','agent','GHOST-AGENT','source_document','doc p.5',
          'proposed','11111111-1111-1111-1111-111111111111','shared');
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('B','b6_registration_not_waived_by_promoting_guc',false,'accepted');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('B','b6_registration_not_waived_by_promoting_guc',
    (SQLERRM LIKE '%not a registered agent principal%'), SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — LEGITIMATE PATH. All must be TRUE.
-- A guard that rejected every source_agent would pass all of Section B.
-- ══════════════════════════════════════════════════════════════════════════

-- C1: source_agent NULL stays legal. A manual, human-authored row has no agent
-- and must not be forced to invent one.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('no agent wrote this','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('C','c1_null_source_agent_accepted',true,'accepted as it should be');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('C','c1_null_source_agent_accepted',false,SQLERRM); END $c$;

-- C2: a registered ACTIVE agent can write. This is the whole point.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('registered agent fact','agent','A1','source_document','doc p.6',
          'proposed','11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('C','c2_registered_active_agent_accepted',true,'accepted as it should be');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('C','c2_registered_active_agent_accepted',false,SQLERRM); END $c$;

-- C3: RETIRING AN AGENT MUST NOT FREEZE ITS EXISTING ROWS. Marking a deadline
-- done on a row an agent wrote before it was retired is ordinary maintenance.
-- The row is stamped while A1 is active, then A1 is retired inside this
-- transaction, then an unrelated column is updated.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility, due_date, due_status)
  VALUES ('written while A1 was active','agent','A1','source_document','doc p.7',
          'proposed','11111111-1111-1111-1111-111111111111','shared', now()+interval '1 day','pending')
  RETURNING id INTO v;
  UPDATE principals SET active=false, deactivated_at=now()
   WHERE id='33333333-3333-3333-3333-333333333333';
  UPDATE memories SET due_status='done' WHERE id=v;
  UPDATE principals SET active=true, deactivated_at=null
   WHERE id='33333333-3333-3333-3333-333333333333';
  INSERT INTO t VALUES ('C','c3_retiring_agent_does_not_freeze_its_rows',
    (SELECT due_status='done' FROM memories WHERE id=v),
    'unrelated update on a retired agent''s row still works');
EXCEPTION WHEN others THEN
  UPDATE principals SET active=true, deactivated_at=null
   WHERE id='33333333-3333-3333-3333-333333333333';
  INSERT INTO t VALUES ('C','c3_retiring_agent_does_not_freeze_its_rows',false,SQLERRM); END $c$;

-- C4: THE ONE THAT CAUGHT A REAL BREAK.
-- supersede_wiki() (sql/24) copies the predecessor's source_agent onto the
-- successor row. Under a single-tier guard that required an ACTIVE agent on
-- every INSERT, a wiki page authored by a since-retired agent became
-- PERMANENTLY UNCORRECTABLE. sql/33's two-tier design exists because of this
-- test. If it ever goes red, the activeness waiver has been removed and the
-- dead end is back.
-- provenance_basis='decision_record' on BOTH the original and the successor is
-- forced by sql/03, not chosen: supersede_wiki() copies source_kind='agent'
-- forward and lands the successor at status='current', and
-- enforce_agent_cannot_self_attest permits that combination only for
-- decision_record. Any other basis makes this test red for a reason that has
-- nothing to do with sql/33.
DO $c$ DECLARE v_new uuid; BEGIN
  -- author a page as A1 while it is active, then retire A1
  INSERT INTO wiki_pages (path,title,content,source_kind,source_agent,provenance_basis,
                          citation,status,owner,visibility)
  VALUES ('test/retired-agent-page','Page','original body','agent','A1','decision_record',
          'decision: adopt page','current','11111111-1111-1111-1111-111111111111','shared');
  UPDATE principals SET active=false, deactivated_at=now()
   WHERE id='33333333-3333-3333-3333-333333333333';

  v_new := supersede_wiki('test/retired-agent-page','Page','corrected body',
                          'decision_record','decision: adopt page rev B',
                          '11111111-1111-1111-1111-111111111111','correcting a retired agent''s page');

  UPDATE principals SET active=true, deactivated_at=null
   WHERE id='33333333-3333-3333-3333-333333333333';
  INSERT INTO t VALUES ('C','c4_retired_agents_wiki_page_is_still_correctable',
    (SELECT content='corrected body' AND source_agent='A1' FROM wiki_pages WHERE id=v_new),
    'supersede_wiki carried the retired attribution forward and was allowed');
EXCEPTION WHEN others THEN
  UPDATE principals SET active=true, deactivated_at=null
   WHERE id='33333333-3333-3333-3333-333333333333';
  INSERT INTO t VALUES ('C','c4_retired_agents_wiki_page_is_still_correctable',false,SQLERRM); END $c$;

-- C5: supersede_memory() is unaffected for the other reason -- it writes the
-- successor as manual/NULL rather than carrying authorship forward. Asserted so
-- that if sql/26 ever starts copying source_agent, this file notices.
DO $c$ DECLARE v uuid; v_new uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('agent fact to be corrected','agent','A1','source_document','doc p.9',
          'proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  v_new := supersede_memory(v,'corrected content','human_direct',NULL,
                            '11111111-1111-1111-1111-111111111111','correction');
  INSERT INTO t VALUES ('C','c5_supersede_memory_nulls_source_agent',
    (SELECT source_agent IS NULL AND source_kind='manual'
       AND metadata->>'corrected_from_source_agent'='A1' FROM memories WHERE id=v_new),
    'successor is manual/NULL with the original attribution in metadata');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c5_supersede_memory_nulls_source_agent',false,SQLERRM); END $c$;

-- C6: RE-ATTRIBUTION between two registered active agents is allowed. B5 proves
-- an UPDATE to an unregistered label is rejected; without this, that guard could
-- be implemented as "source_agent is immutable", which would reject the
-- legitimate correction too. The pair is what pins the behaviour.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('misattributed to A1','agent','A1','source_document','doc p.10',
          'proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  UPDATE memories SET source_agent='A2' WHERE id=v;
  INSERT INTO t VALUES ('C','c6_reattribution_between_active_agents_allowed',
    (SELECT source_agent='A2' FROM memories WHERE id=v),
    'A1 -> A2 re-attribution accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c6_reattribution_between_active_agents_allowed',false,SQLERRM); END $c$;

-- C7: the detection surface reports the real state per row rather than a
-- boolean pass/fail. 'inactive' is a preserved historical attribution, not a
-- defect, and must not be reported as 'unregistered'.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('attribution report row','agent','A1','source_document','doc p.11',
          'proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  INSERT INTO t VALUES ('C','c7_attribution_report_states_are_real',
    (SELECT state='active' FROM source_agent_attribution_report() WHERE record_id=v),
    'row authored by an active agent reports active');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c7_attribution_report_states_are_real',false,SQLERRM); END $c$;

-- C8: the new functions are not reachable at the perimeter.
INSERT INTO t VALUES ('C','c8_new_functions_not_exposed',
  (SELECT NOT EXISTS (
     SELECT 1 FROM pg_proc p
     JOIN pg_namespace n ON n.oid=p.pronamespace AND n.nspname='public'
     CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) acl
     WHERE p.proname IN ('agent_label_state','enforce_registered_source_agent',
                         'source_agent_attribution_report')
       AND acl.privilege_type='EXECUTE'
       AND acl.grantee::regrole::text IN ('anon','authenticated','-'))),
  'no EXECUTE for anon/authenticated/PUBLIC');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION D — DOCUMENTED LIMITS. TRUE means the known limit is still present.
-- ══════════════════════════════════════════════════════════════════════════

-- D1: IMPERSONATION IS NOT CLOSED. Any caller may stamp any REGISTERED label;
-- nothing proves the caller is that agent. sql/33's header says so; asserted
-- here so it appears in test output rather than only in prose.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('a human session stamping A1','agent','A1','source_document','doc p.12',
          'proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  INSERT INTO t VALUES ('D','limit_any_caller_may_stamp_any_registered_agent',
    (SELECT source_agent='A1' FROM memories WHERE id=v),
    'KNOWN LIMIT: source_agent is caller-asserted; registration is checked, identity is not');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','limit_any_caller_may_stamp_any_registered_agent',false,
    'enforcement changed -- sql/33 now understates it: '||SQLERRM); END $c$;

-- D2: the activeness tier is waived by a SELF-ARMABLE GUC. A caller who sets
-- app.promoting can stamp a retired agent on a fresh row. Registration still
-- holds (B6); activeness does not.
DO $c$ DECLARE v uuid; BEGIN
  PERFORM set_config('app.promoting','on',true);
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility)
  VALUES ('self-armed retired-agent write','agent','A-RETIRED','source_document','doc p.13',
          'proposed','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('D','limit_self_armed_guc_waives_activeness',
    (SELECT source_agent='A-RETIRED' FROM memories WHERE id=v),
    'KNOWN LIMIT: arming app.promoting waives the activeness tier');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('D','limit_self_armed_guc_waives_activeness',false,
    'enforcement changed -- sql/33 now overstates the limit: '||SQLERRM); END $c$;

-- D3: COVERAGE IS TWO TABLES, NOT ELEVEN. Eleven tables carry a source_agent
-- column; sql/33 guards memories and wiki_pages. Asserted against the sql/10
-- supplier domain, whose test suite carries the deployment-only opt-out marker
-- and therefore cannot be exercised in a fresh replay -- which is precisely why
-- coverage was not extended there. TRUE means the gap is still the documented
-- one.
--
-- That marker is described here and never spelled: the runner greps every test
-- file for the literal string anywhere in it, comments included, so naming it
-- opted this whole file out of the suite as a silent SKIP.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO suppliers (company, source_kind, source_agent, provenance_basis, citation, status)
  VALUES ('Ghostwritten Supplier Ltd','agent','GHOST-AGENT','source_document','doc p.14','proposed')
  RETURNING id INTO v;
  INSERT INTO t VALUES ('D','limit_domain_tables_are_not_covered',
    (SELECT source_agent='GHOST-AGENT' FROM suppliers WHERE id=v),
    'KNOWN GAP: suppliers.source_agent accepts an unregistered label');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','limit_domain_tables_are_not_covered',false,
    'coverage changed, or the insert failed for an unrelated reason -- read this: '||SQLERRM); END $c$;


-- ── Results ────────────────────────────────────────────────────────────────
SELECT section, test, pass, left(detail,72) AS detail FROM t ORDER BY section, test;

SELECT 'A_controls' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed' AS detail
FROM t WHERE section='A'
UNION ALL
SELECT 'B_unregistered_attribution_rejected', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' still ACCEPTED'
FROM t WHERE section='B'
UNION ALL
SELECT 'C_legitimate_path_still_works', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed'
FROM t WHERE section='C'
UNION ALL
SELECT 'D_documented_limits_still_present', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' changed -- update sql/33'
FROM t WHERE section='D';

-- ── GUARD: an assertion that evaluated to NULL is NOT a pass ───────────────
-- See tests/23 for the full account. Several assertions here are of the form
-- (SELECT col=... FROM tbl WHERE id=v), which yields NULL rather than false when
-- the row does not exist -- exactly the shape that reads as a pass at every
-- layer. Any NULL here is a broken assertion.
SELECT 'GUARD_no_null_assertions' AS summary,
       coalesce(bool_and(pass IS NOT NULL), true) AS pass,
       count(*) FILTER (WHERE pass IS NULL)::text||' assertion(s) evaluated to NULL' AS detail
FROM t;

-- ── EXPLICIT VERDICT ──────────────────────────────────────────────────────
-- The runner reads THIS line, not the formatted rows above.
SELECT CASE WHEN bool_and(coalesce(pass,false)) THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict FROM t;

ROLLBACK;
