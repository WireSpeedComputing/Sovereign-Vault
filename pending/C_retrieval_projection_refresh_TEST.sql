-- Tests for pending/C_retrieval_projection_refresh.sql.
--
-- Lives in pending/ rather than tests/ on purpose: tests/ is executed by
-- tests/replay_fresh_install.sh against sql/ only, and C is not applied. Move
-- this file to tests/ in the same change that moves C to sql/.
--
-- Run against a fresh replay with C applied on top:
--   ./tests/replay_fresh_install.sh          # confirm baseline is clean
--   psql -f pending/C_retrieval_projection_refresh.sql
--   psql -f pending/C_retrieval_projection_refresh_TEST.sql
--
-- Every `pass` must be true.

BEGIN;

CREATE TEMP TABLE t(test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com'),
 ('22222222-2222-2222-2222-222222222222','human','H2','h2@example.com');

-- ── 1. the reported bug: a promoted memory is retrievable without a manual refresh
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('quarterly supplier terms renegotiated','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  INSERT INTO t VALUES ('proposed_row_is_not_projected',
    (SELECT count(*)=0 FROM retrieval_units WHERE source_id=v AND invalidated_at IS NULL),
    'a candidate is not knowledge and must not be retrievable');

  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('promotion_projects_without_manual_refresh',
    (SELECT count(*)=1 FROM retrieval_units WHERE source_id=v AND invalidated_at IS NULL),
    'unit exists with no call to refresh_retrieval_units()');

  INSERT INTO t VALUES ('promoted_row_is_retrievable',
    (retrieve_context('11111111-1111-1111-1111-111111111111','supplier terms')
       ->>'units_matched')::int >= 1,
    'retrieve_context finds it');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('promotion_projects_without_manual_refresh',false,SQLERRM); END $c$;

-- ── 2. supersession: the successor is projected, the predecessor is not
DO $c$ DECLARE v uuid; v2 uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('old price is ten','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  v2 := supersede_memory(v,'new price is twelve','decision_record','cite',
                         '11111111-1111-1111-1111-111111111111','repricing');
  INSERT INTO t VALUES ('superseded_row_leaves_projection',
    (SELECT count(*)=0 FROM retrieval_units WHERE source_id=v AND invalidated_at IS NULL),
    'predecessor no longer retrievable');
  INSERT INTO t VALUES ('successor_enters_projection',
    (SELECT count(*)=1 FROM retrieval_units WHERE source_id=v2 AND invalidated_at IS NULL),
    'successor retrievable immediately');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('successor_enters_projection',false,SQLERRM); END $c$;

-- ── 3. rejection removes a row from the projection
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('claim later withdrawn','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM set_config('app.promoting','on',true);
  UPDATE memories SET status='retracted' WHERE id=v;
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('retracted_row_leaves_projection',
    (SELECT count(*)=0 FROM retrieval_units WHERE source_id=v AND invalidated_at IS NULL),
    'retracted row not retrievable');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('retracted_row_leaves_projection',false,SQLERRM); END $c$;

-- ── 4. THE LEAK. A memory switched to private must stop being visible to
-- others through retrieval. Content is unchanged, so the hash-only
-- invalidation rule in refresh_retrieval_units() does not catch this at all.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('zzsecret merger codename bluefin','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');

  INSERT INTO t VALUES ('leak_precondition_shared_row_is_visible_to_other',
    (retrieve_context('22222222-2222-2222-2222-222222222222','zzsecret bluefin')
       ->>'units_matched')::int >= 1,
    'while shared, H2 can see it -- establishes the test is measuring something');

  UPDATE memories SET visibility='private' WHERE id=v;

  INSERT INTO t VALUES ('leak_closed_private_row_hidden_from_other',
    (retrieve_context('22222222-2222-2222-2222-222222222222','zzsecret bluefin')
       ->>'units_matched')::int = 0,
    'after going private, H2 cannot see it');

  INSERT INTO t VALUES ('leak_owner_still_sees_own_private_row',
    (retrieve_context('11111111-1111-1111-1111-111111111111','zzsecret bluefin')
       ->>'units_matched')::int >= 1,
    'owner retains access -- the fix must not over-close');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('leak_closed_private_row_hidden_from_other',false,SQLERRM); END $c$;

-- ── 5. operational writes must NOT re-run the projection (the WHEN clause)
DO $c$ DECLARE v uuid; before_gen timestamptz; after_gen timestamptz; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility,
                        due_date, due_status)
  VALUES ('deliverable','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared', now()+interval '2 days','pending')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  SELECT generated_at INTO before_gen FROM retrieval_units
   WHERE source_id=v AND invalidated_at IS NULL;
  UPDATE memories SET due_status='done', hot_touched=true WHERE id=v;
  SELECT generated_at INTO after_gen FROM retrieval_units
   WHERE source_id=v AND invalidated_at IS NULL;
  INSERT INTO t VALUES ('operational_write_does_not_reproject',
    before_gen = after_gen AND (SELECT count(*)=1 FROM retrieval_units
      WHERE source_id=v AND invalidated_at IS NULL),
    'same unit, not regenerated');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('operational_write_does_not_reproject',false,SQLERRM); END $c$;

-- ── 6. wiki pages: sections project, and a content change re-sections
DO $c$ DECLARE v uuid; n_before int; n_after int; BEGIN
  INSERT INTO wiki_pages (path,title,content,source_kind,provenance_basis,status,owner,visibility)
  VALUES ('/ops/runbook','Runbook',
          E'# One\nfirst section body\n\n## Two\nsecond section body',
          'manual','human_direct','current','11111111-1111-1111-1111-111111111111','shared')
  RETURNING id INTO v;
  SELECT count(*) INTO n_before FROM retrieval_units
   WHERE source_id=v AND invalidated_at IS NULL;
  INSERT INTO t VALUES ('wiki_insert_projects_sections', n_before >= 2,
    'sections projected on insert: '||n_before);

  UPDATE wiki_pages SET content = E'# One\nrewritten\n\n## Two\nalso rewritten\n\n## Three\nnew section'
   WHERE id=v;
  SELECT count(*) INTO n_after FROM retrieval_units
   WHERE source_id=v AND invalidated_at IS NULL;
  INSERT INTO t VALUES ('wiki_update_resections', n_after >= 3 AND n_after > n_before,
    're-sectioned on content change: '||n_before||' -> '||n_after);
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('wiki_update_resections',false,SQLERRM); END $c$;

-- ── 7. the trigger is incremental, not a rescan: touching one row must not
-- regenerate units belonging to other rows.
DO $c$ DECLARE a uuid; b uuid; b_gen timestamptz; b_gen2 timestamptz; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('row alpha','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO a;
  PERFORM promote_memory(a,'11111111-1111-1111-1111-111111111111');
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('row beta','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO b;
  PERFORM promote_memory(b,'11111111-1111-1111-1111-111111111111');
  SELECT generated_at INTO b_gen FROM retrieval_units WHERE source_id=b AND invalidated_at IS NULL;

  UPDATE memories SET visibility='private' WHERE id=a;

  SELECT generated_at INTO b_gen2 FROM retrieval_units WHERE source_id=b AND invalidated_at IS NULL;
  INSERT INTO t VALUES ('sync_is_scoped_to_one_row', b_gen = b_gen2,
    'unrelated row untouched');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('sync_is_scoped_to_one_row',false,SQLERRM); END $c$;

SELECT test, pass, left(detail,70) AS detail FROM t ORDER BY test;
SELECT 'ALL' AS summary, bool_and(coalesce(pass,false)) AS pass,
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
