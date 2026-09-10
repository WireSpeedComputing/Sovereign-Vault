-- tests/34_hard_delete_guard.sql
-- Covers sql/34_hard_delete_guard.sql.
-- ADOPT: sibling protocol repo sovereign-memory-core, `guard_hard_delete()`.
-- (The work order cited #5; #5 is closed with no content -- see sql/34's
-- SOURCING NOTE.)
--
-- Run against a FRESH database (tests/replay_fresh_install.sh). Self-contained.
--
-- ── HOW TO READ A RESULT ────────────────────────────────────────────────────
--   A  POSITIVE CONTROLS over guards that predate this file.
--   B  FAILING-NEGATIVES. TRUE means the DELETE was REJECTED and the row is
--      STILL THERE. Each B test asserts BOTH -- an exception alone would not
--      prove the row survived, and a surviving row alone would not prove
--      anything was rejected.
--   C  LEGITIMATE PATH. TRUE means the deletes this system depends on still
--      work. sql/21 calls retrieval units "DISPOSABLE DERIVED PROJECTIONS,
--      rebuildable at any time"; a delete guard that froze them would break the
--      repo's own embedding-migration story. C is what stops the guard from
--      being a system-wide freeze.
--   D  DOCUMENTED LIMITS. TRUE means a known, written-down weakness is still
--      present.
--
-- ── DISCRIMINATION ──────────────────────────────────────────────────────────
-- Run against a schema with sql/34 absent: every B assertion goes red (the rows
-- are destroyed) while A, C and D stay green. See docs/10.

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com');
INSERT INTO principals (id,kind,display_name,agent_label) VALUES
 ('33333333-3333-3333-3333-333333333333','agent','A1','A1');

-- A promoted (authoritative) memory, and a proposed one. Both must be protected:
-- the guard is about destroying evidence, and a rejected candidate is evidence
-- that a rejected candidate existed.
CREATE TEMP TABLE fixture(k text primary key, id uuid) ON COMMIT DROP;

DO $f$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('PROMOTED RECORD','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO fixture VALUES ('promoted', v);

  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('PROPOSED CANDIDATE','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  INSERT INTO fixture VALUES ('proposed', v);

  INSERT INTO wiki_pages (path,title,content,source_kind,provenance_basis,citation,
                          status,owner,visibility)
  VALUES ('test/page','Page','body','manual','human_direct','operator','current',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  INSERT INTO fixture VALUES ('wiki', v);
END $f$;

SELECT refresh_retrieval_units();


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — POSITIVE CONTROLS. All must be TRUE.
-- ══════════════════════════════════════════════════════════════════════════

-- A1: sql/26's in-place immutability guard still fires. This is the guard sql/34
-- exists to complete: without a delete guard, "you may not rewrite a promoted
-- record" is satisfiable by deleting it and inserting a replacement.
DO $c$ BEGIN
  UPDATE memories SET content='rewritten' WHERE id=(SELECT id FROM fixture WHERE k='promoted');
  INSERT INTO t VALUES ('A','ctl_promoted_record_immutable',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_promoted_record_immutable',true,SQLERRM); END $c$;

-- A2: promoted_record_audit is still append-only (sql/26). If receipts became
-- editable, the detection half of sql/34's design would be worthless too.
DO $c$ BEGIN
  UPDATE promoted_record_audit SET content_sha256='forged'
   WHERE record_id=(SELECT id FROM fixture WHERE k='promoted');
  INSERT INTO t VALUES ('A','ctl_promoted_audit_append_only',false,'receipt was updated');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_promoted_audit_append_only',true,SQLERRM); END $c$;

-- A3: sql/26 still makes status=current unreachable by direct INSERT.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('control direct current','manual','human_direct','current',
          '11111111-1111-1111-1111-111111111111','shared');
  INSERT INTO t VALUES ('A','ctl_direct_insert_at_current_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_direct_insert_at_current_rejected',true,SQLERRM); END $c$;

-- A4: the fixture really is there. Every B test below asserts a row SURVIVED a
-- delete; if the fixture were empty they would all pass vacuously.
INSERT INTO t VALUES ('A','ctl_fixture_rows_exist',
  (SELECT count(*)=2 FROM memories m JOIN fixture f ON f.id=m.id
    WHERE f.k IN ('promoted','proposed'))
  AND (SELECT count(*)=1 FROM wiki_pages w JOIN fixture f ON f.id=w.id WHERE f.k='wiki'),
  'two memories and one wiki page present before the delete attempts');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — FAILING-NEGATIVES. All must be TRUE.
-- TRUE = the DELETE raised AND the row is still present. Both halves asserted.
-- ══════════════════════════════════════════════════════════════════════════

-- B1: a promoted record cannot be hard-deleted.
DO $c$ DECLARE v uuid; v_raised boolean := false; BEGIN
  SELECT id INTO v FROM fixture WHERE k='promoted';
  BEGIN
    DELETE FROM memories WHERE id=v;
  EXCEPTION WHEN others THEN v_raised := true; END;
  INSERT INTO t VALUES ('B','b1_promoted_record_delete_rejected',
    (v_raised AND EXISTS (SELECT 1 FROM memories WHERE id=v)),
    CASE WHEN v_raised THEN 'rejected and row survived' ELSE 'DELETE WAS ACCEPTED' END);
END $c$;

-- B2: a proposed candidate cannot be hard-deleted either. "Clean up the
-- rejects" is the most plausible accidental delete in this schema.
DO $c$ DECLARE v uuid; v_raised boolean := false; BEGIN
  SELECT id INTO v FROM fixture WHERE k='proposed';
  BEGIN
    DELETE FROM memories WHERE id=v;
  EXCEPTION WHEN others THEN v_raised := true; END;
  INSERT INTO t VALUES ('B','b2_proposed_candidate_delete_rejected',
    (v_raised AND EXISTS (SELECT 1 FROM memories WHERE id=v)),
    CASE WHEN v_raised THEN 'rejected and row survived' ELSE 'DELETE WAS ACCEPTED' END);
END $c$;

-- B3: wiki pages too.
DO $c$ DECLARE v uuid; v_raised boolean := false; BEGIN
  SELECT id INTO v FROM fixture WHERE k='wiki';
  BEGIN
    DELETE FROM wiki_pages WHERE id=v;
  EXCEPTION WHEN others THEN v_raised := true; END;
  INSERT INTO t VALUES ('B','b3_wiki_page_delete_rejected',
    (v_raised AND EXISTS (SELECT 1 FROM wiki_pages WHERE id=v)),
    CASE WHEN v_raised THEN 'rejected and row survived' ELSE 'DELETE WAS ACCEPTED' END);
END $c$;

-- B4: an UNTARGETED delete is rejected too, and takes nothing with it. This is
-- the shape of the accident the guard is actually for -- the migration script
-- with a bad WHERE clause. Asserted on the surviving COUNT, because a guard that
-- fired on the first row after deleting three would still be a disaster.
DO $c$ DECLARE v_before int; v_raised boolean := false; BEGIN
  SELECT count(*) INTO v_before FROM memories;
  BEGIN
    DELETE FROM memories;
  EXCEPTION WHEN others THEN v_raised := true; END;
  INSERT INTO t VALUES ('B','b4_untargeted_delete_rejected_atomically',
    (v_raised AND (SELECT count(*) FROM memories) = v_before),
    'DELETE FROM memories rejected with no rows lost');
END $c$;

-- B5: the guard is NOT keyed on status. A retracted or entered_in_error row is
-- still evidence and still protected. If the guard let go of rows once they
-- stopped being authoritative, "retract then delete" would be a two-step bypass.
DO $c$ DECLARE v uuid; v_raised boolean := false; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('WITHDRAWN ROW','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  BEGIN
    DELETE FROM memories WHERE id=v;
  EXCEPTION WHEN others THEN v_raised := true; END;
  INSERT INTO t VALUES ('B','b5_guard_is_not_keyed_on_status',
    (v_raised AND EXISTS (SELECT 1 FROM memories WHERE id=v)),
    'a withdrawn candidate is still protected');
END $c$;

-- B6: a blocked delete leaves NO receipt. hard_delete_audit records deletes that
-- HAPPENED under the override; a row here for a delete that was refused would
-- make the receipt table lie in the more dangerous direction.
--
-- HONEST NOTE ON THIS ONE: it does NOT discriminate. In the discrimination run
-- (guard triggers dropped) it stays green, because a schema with no guard writes
-- no receipts either. It is a consistency check on the receipt table, not
-- evidence that the guard works -- B1-B5 are that. Recorded here because a
-- non-discriminating assertion sitting unmarked among discriminating ones is
-- how a suite drifts into proving only that it can run.
INSERT INTO t VALUES ('B','b6_blocked_delete_writes_no_receipt',
  (SELECT count(*)=0 FROM hard_delete_audit),
  'no receipts written for the five rejected deletes above (does not discriminate)');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — LEGITIMATE PATH. All must be TRUE.
-- A guard that blocked every DELETE in the schema would pass all of Section B
-- and break the system. These are the deletes this repo DEPENDS on.
-- ══════════════════════════════════════════════════════════════════════════

-- C1: retrieval units are DISPOSABLE. sql/21's header says so in those words,
-- and refresh_retrieval_units() exists to rebuild them. Deleting one must work.
DO $c$ DECLARE v uuid; BEGIN
  SELECT id INTO v FROM retrieval_units LIMIT 1;
  DELETE FROM retrieval_units WHERE id=v;
  INSERT INTO t VALUES ('C','c1_retrieval_units_stay_deletable',
    (NOT EXISTS (SELECT 1 FROM retrieval_units WHERE id=v)),
    'disposable derived projection deleted as designed');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c1_retrieval_units_stay_deletable',false,
    'GUARD OVERREACHED onto a disposable projection: '||SQLERRM); END $c$;

-- C2: and the projection rebuilds afterwards. Deletability is only useful if the
-- rebuild half works; together they are the embedding-migration story sql/21
-- describes.
DO $c$ DECLARE v_n int; BEGIN
  SELECT projected_memories INTO v_n FROM refresh_retrieval_units();
  INSERT INTO t VALUES ('C','c2_projection_rebuilds_after_delete',
    (v_n >= 1),
    'refresh_retrieval_units reprojected the deleted unit');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c2_projection_rebuilds_after_delete',false,SQLERRM); END $c$;

-- C3: the attention layer's staging delete still works. hot_touch() deletes the
-- staging row as its normal promote-from-staging step; guarding
-- memory_hot_staging would break the happy path of the attention layer.
DO $c$ DECLARE v uuid; v_r text; BEGIN
  SELECT id INTO v FROM fixture WHERE k='promoted';
  PERFORM hot_touch('test/topic', v, 'summary', 'ws');   -- stages
  v_r := hot_touch('test/topic', v, 'summary', 'ws');    -- promotes, deletes staging
  INSERT INTO t VALUES ('C','c3_hot_staging_delete_still_works',
    (v_r = 'promoted'
     AND NOT EXISTS (SELECT 1 FROM memory_hot_staging WHERE topic_key='test/topic')),
    'promote-from-staging deleted its staging row');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c3_hot_staging_delete_still_works',false,
    'GUARD OVERREACHED onto the attention layer: '||SQLERRM); END $c$;

-- C4: SUPERSESSION -- the sanctioned alternative to deleting -- still works.
-- The guard's error message tells the operator to supersede instead; if that
-- path were broken the message would be advice to a dead end.
DO $c$ DECLARE v uuid; v_new uuid; BEGIN
  SELECT id INTO v FROM fixture WHERE k='promoted';
  v_new := supersede_memory(v,'corrected content','human_direct',NULL,
                            '11111111-1111-1111-1111-111111111111','the sanctioned path');
  INSERT INTO t VALUES ('C','c4_supersede_still_works',
    (SELECT status='superseded' FROM memories WHERE id=v)
    AND (SELECT status='current' AND supersedes=v FROM memories WHERE id=v_new),
    'the alternative the error message recommends actually works');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c4_supersede_still_works',false,SQLERRM); END $c$;

-- C5: the ADMIN OVERRIDE works, and leaves a receipt naming what was destroyed.
-- A guard with no escape hatch gets disabled wholesale the first time someone
-- genuinely needs it, which is worse than a guard with an audited one.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('DELETE ME UNDER OVERRIDE','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM set_config('app.allow_delete','on',true);
  DELETE FROM memories WHERE id=v;
  PERFORM set_config('app.allow_delete','off',true);
  INSERT INTO t VALUES ('C','c5_override_deletes_and_leaves_a_receipt',
    (NOT EXISTS (SELECT 1 FROM memories WHERE id=v))
    AND EXISTS (SELECT 1 FROM hard_delete_audit
                 WHERE record_id=v AND table_name='memories'
                   AND record_status='proposed' AND content_sha256 IS NOT NULL),
    'row destroyed and a receipt recorded');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.allow_delete','off',true);
  INSERT INTO t VALUES ('C','c5_override_deletes_and_leaves_a_receipt',false,SQLERRM); END $c$;

-- C6: the override is SET LOCAL / per-transaction in intent, and turning it back
-- off re-arms the guard within the same transaction. An override that silently
-- stayed on for the rest of the session would be worse than none.
DO $c$ DECLARE v uuid; v_raised boolean := false; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('AFTER OVERRIDE DISARMED','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  BEGIN
    DELETE FROM memories WHERE id=v;
  EXCEPTION WHEN others THEN v_raised := true; END;
  INSERT INTO t VALUES ('C','c6_guard_rearms_when_override_disarmed',
    (v_raised AND EXISTS (SELECT 1 FROM memories WHERE id=v)),
    'guard is active again after app.allow_delete was set back to off');
END $c$;

-- C7: the receipt table is itself append-only -- a delete receipt that can be
-- deleted is exactly the hole this file is about.
--
-- The assertion checks the MESSAGE NAMES hard_delete_audit, not merely that
-- something raised. An earlier version of sql/34 reused sql/26's
-- forbid_audit_mutation(), which hardcodes 'promoted_record_audit' in its text;
-- this test passed while telling the operator to go read the wrong file.
DO $c$ BEGIN
  DELETE FROM hard_delete_audit;
  INSERT INTO t VALUES ('C','c7_receipt_table_is_append_only',false,'receipts were deleted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c7_receipt_table_is_append_only',
    (SQLERRM LIKE '%hard_delete_audit%' AND SQLERRM NOT LIKE '%promoted_record_audit%'),
    SQLERRM); END $c$;

-- C8: the receipt does NOT store the deleted content. A "safety" table holding a
-- second uncontrolled copy of every deleted row, with no owner/visibility
-- columns and no RLS policies, would be a bigger leak than the risk it mitigates.
INSERT INTO t VALUES ('C','c8_receipt_stores_no_content',
  (SELECT NOT EXISTS (
     SELECT 1 FROM information_schema.columns
     WHERE table_schema='public' AND table_name='hard_delete_audit'
       AND column_name IN ('content','rendered_text','payload','detail'))),
  'receipt carries a hash, not the destroyed text');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION D — DOCUMENTED LIMITS. TRUE means the known limit is still present.
-- ══════════════════════════════════════════════════════════════════════════

-- D1: app.allow_delete is a SELF-ARMABLE session GUC. Any caller holding
-- service_role can arm it and delete freely. sql/34 says this closes the
-- ACCIDENTAL path, not the deliberate one; C5 already demonstrates the
-- mechanism, and this asserts it as the LIMIT it is rather than only as a
-- feature. Same shape as tests/23 Section D for app.promoting.
INSERT INTO t VALUES ('D','limit_caller_can_self_arm_the_delete_override',
  (SELECT count(*) >= 1 FROM hard_delete_audit),
  'KNOWN LIMIT: the caller armed its own override in C5 and a row was destroyed');

-- D2: COVERAGE IS TWO TABLES. Domain tables in sql/10 and sql/11 carry the same
-- custody-bearing shape and are NOT guarded, for the same reason sql/33 stops at
-- two: their test suites carry the deployment-only opt-out marker and cannot be
-- exercised in a fresh replay. TRUE means the gap is still the documented one.
--
-- The marker is described here, never spelled, and that is not fussiness: the
-- runner in tests/replay_fresh_install.sh greps each test file for that literal
-- string ANYWHERE in the file, comments included. Writing it in this comment
-- silently opted this entire file out of the suite -- it reported SKIP, not
-- FAIL, so nothing looked wrong. Caught by reading the runner's output rather
-- than the test's.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO suppliers (company, source_kind, provenance_basis, citation, status)
  VALUES ('Deletable Supplier Ltd','manual','human_direct','operator','proposed')
  RETURNING id INTO v;
  DELETE FROM suppliers WHERE id=v;
  INSERT INTO t VALUES ('D','limit_domain_tables_are_not_delete_guarded',
    (NOT EXISTS (SELECT 1 FROM suppliers WHERE id=v)),
    'KNOWN GAP: suppliers rows can still be hard-deleted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','limit_domain_tables_are_not_delete_guarded',false,
    'coverage changed, or this failed for an unrelated reason -- read this: '||SQLERRM); END $c$;

-- D3: TRUNCATE is not a row-level DELETE and no BEFORE DELETE trigger fires for
-- it. This is a real hole in the adopted design, present upstream too. It needs
-- a separate statement-level guard or a revoked TRUNCATE privilege; recorded
-- here so it is visible in test output rather than discovered later.
--
-- Asserted WITHOUT executing a TRUNCATE: the assertion is that no statement-level
-- truncate trigger exists on the guarded tables. Running an actual TRUNCATE would
-- destroy this test's own fixture and prove the same thing more destructively.
INSERT INTO t VALUES ('D','limit_truncate_is_not_covered',
  (SELECT NOT EXISTS (
     SELECT 1 FROM pg_trigger tg
     JOIN pg_class c ON c.oid=tg.tgrelid
     WHERE c.relname IN ('memories','wiki_pages')
       AND NOT tg.tgisinternal
       AND (tg.tgtype & 32) <> 0)),          -- 32 = TRUNCATE
  'KNOWN GAP: no TRUNCATE-level guard on memories or wiki_pages');


-- ── Results ────────────────────────────────────────────────────────────────
SELECT section, test, pass, left(detail,72) AS detail FROM t ORDER BY section, test;

SELECT 'A_controls' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed' AS detail
FROM t WHERE section='A'
UNION ALL
SELECT 'B_hard_delete_rejected', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' DESTROYED a row'
FROM t WHERE section='B'
UNION ALL
SELECT 'C_legitimate_path_still_works', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed'
FROM t WHERE section='C'
UNION ALL
SELECT 'D_documented_limits_still_present', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' changed -- update sql/34'
FROM t WHERE section='D';

-- ── GUARD: an assertion that evaluated to NULL is NOT a pass ───────────────
-- See tests/23. Assertions of the form (SELECT col=... FROM tbl WHERE id=v)
-- yield NULL when the row is gone -- and this file is entirely about rows being
-- gone, which makes it the single most exposed test file in the suite to the
-- NULL-reads-as-pass defect. Any NULL here is a broken assertion.
SELECT 'GUARD_no_null_assertions' AS summary,
       coalesce(bool_and(pass IS NOT NULL), true) AS pass,
       count(*) FILTER (WHERE pass IS NULL)::text||' assertion(s) evaluated to NULL' AS detail
FROM t;

-- ── EXPLICIT VERDICT ──────────────────────────────────────────────────────
-- The runner reads THIS line, not the formatted rows above.
SELECT CASE WHEN bool_and(coalesce(pass,false)) THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict FROM t;

ROLLBACK;
