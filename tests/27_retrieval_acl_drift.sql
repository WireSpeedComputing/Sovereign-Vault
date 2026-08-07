-- tests/27_retrieval_acl_drift.sql
-- Covers sql/27_retrieval_acl_drift_fix.sql.
--
-- The point of this file is the REPAIR path. pending/C's triggers keep the
-- projection correct going forward; they cannot correct a unit that was already
-- stale when they were installed. Only the rescan can, and the rescan is
-- exactly what used to preserve the drift instead of fixing it.
--
-- Every `pass` must be true.

BEGIN;

CREATE TEMP TABLE t(test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com'),
 ('22222222-2222-2222-2222-222222222222','human','H2','h2@example.com');

-- ── 1. The regression, end to end: drift is created, detected, and repaired.
DO $c$ DECLARE v uuid; m_before int; m_after int; drift_before int; drift_after int; r record;
BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('zzsecret merger codename bluefin','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM refresh_retrieval_units();

  -- precondition: while shared, the other principal can see it. Without this
  -- the rest of the test could pass because nothing was ever visible.
  SELECT (retrieve_context('22222222-2222-2222-2222-222222222222','zzsecret bluefin')
            ->>'units_matched')::int INTO m_before;
  INSERT INTO t VALUES ('precondition_shared_row_visible_to_other', m_before >= 1,
    'H2 matches while shared: '||m_before);

  -- create the drift: content unchanged, ACL changed
  UPDATE memories SET visibility='private' WHERE id=v;

  SELECT count(*) INTO drift_before FROM retrieval_acl_drift();
  INSERT INTO t VALUES ('drift_is_detected', drift_before >= 1,
    'retrieval_acl_drift() reports '||drift_before||' drifted unit(s)');

  -- THE FIX: a full rescan must now repair it rather than preserve it.
  SELECT * INTO r FROM refresh_retrieval_units();
  INSERT INTO t VALUES ('rescan_reports_repaired_count', r.repaired_acl_drift >= 1,
    'repaired_acl_drift = '||r.repaired_acl_drift);

  SELECT count(*) INTO drift_after FROM retrieval_acl_drift();
  INSERT INTO t VALUES ('drift_is_gone_after_rescan', drift_after = 0,
    'drift after repair: '||drift_after);

  SELECT (retrieve_context('22222222-2222-2222-2222-222222222222','zzsecret bluefin')
            ->>'units_matched')::int INTO m_after;
  INSERT INTO t VALUES ('other_principal_can_no_longer_see_it', m_after = 0,
    'H2 matches after repair: '||m_after);

  INSERT INTO t VALUES ('owner_still_sees_own_private_row',
    (retrieve_context('11111111-1111-1111-1111-111111111111','zzsecret bluefin')
       ->>'units_matched')::int >= 1,
    'the repair must not over-close');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('drift_is_gone_after_rescan',false,SQLERRM); END $c$;

-- ── 2. Owner drift, not just visibility. A private row reassigned to a
-- different owner must follow its new owner.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('zzowner transfer canary','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','private') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM refresh_retrieval_units();

  UPDATE memories SET owner='22222222-2222-2222-2222-222222222222' WHERE id=v;
  PERFORM refresh_retrieval_units();

  INSERT INTO t VALUES ('owner_drift_repaired_new_owner_sees',
    (retrieve_context('22222222-2222-2222-2222-222222222222','zzowner canary')
       ->>'units_matched')::int >= 1, 'new owner sees it');
  INSERT INTO t VALUES ('owner_drift_repaired_old_owner_blind',
    (retrieve_context('11111111-1111-1111-1111-111111111111','zzowner canary')
       ->>'units_matched')::int = 0, 'previous owner no longer sees it');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('owner_drift_repaired_old_owner_blind',false,SQLERRM); END $c$;

-- ── 3. The repair must not be indiscriminate. A clean projection must report
-- zero repaired and must not churn units -- otherwise "repaired 0" carries no
-- information and every rescan would invalidate the whole table.
DO $c$ DECLARE v uuid; gen_before timestamptz; gen_after timestamptz; r record; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('zzstable row','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM refresh_retrieval_units();
  SELECT generated_at INTO gen_before FROM retrieval_units
   WHERE source_id=v AND invalidated_at IS NULL;

  SELECT * INTO r FROM refresh_retrieval_units();
  SELECT generated_at INTO gen_after FROM retrieval_units
   WHERE source_id=v AND invalidated_at IS NULL;

  INSERT INTO t VALUES ('clean_rescan_reports_zero_drift', r.repaired_acl_drift = 0,
    'repaired_acl_drift on a clean projection: '||r.repaired_acl_drift);
  INSERT INTO t VALUES ('clean_rescan_does_not_churn', gen_before = gen_after,
    'unchanged unit not regenerated');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('clean_rescan_does_not_churn',false,SQLERRM); END $c$;

-- ── 4. Embeddings must not outlive the unit they describe.
DO $c$ DECLARE v uuid; u uuid; n_stale int; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility)
  VALUES ('zzembedded row','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared') RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM refresh_retrieval_units();
  SELECT id INTO u FROM retrieval_units WHERE source_id=v AND invalidated_at IS NULL;

  INSERT INTO retrieval_embeddings (retrieval_unit_id, model_provider, model_name,
    model_version, dimensions, embedding, rendered_text_hash)
  VALUES (u,'test','m','1',384,NULL,'hash');

  UPDATE memories SET visibility='private' WHERE id=v;
  PERFORM refresh_retrieval_units();

  SELECT count(*) INTO n_stale FROM retrieval_embeddings
   WHERE retrieval_unit_id=u AND stale_at IS NOT NULL;
  INSERT INTO t VALUES ('embedding_marked_stale_with_its_unit', n_stale = 1,
    'stale embeddings for the invalidated unit: '||n_stale);
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('embedding_marked_stale_with_its_unit',false,SQLERRM); END $c$;

SELECT test, pass, left(detail,70) AS detail FROM t ORDER BY test;
SELECT 'ALL' AS summary, bool_and(pass) AS pass,
       count(*) FILTER (WHERE NOT pass)::text||' of '||count(*)::text||' failed' AS detail FROM t;

ROLLBACK;
