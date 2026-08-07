-- PENDING OWNER APPROVAL — DO NOT APPLY
--
-- Migration A for upstream issue #71: wiki page supersession.
--
-- Placed in pending/ rather than sql/ deliberately: tests/replay_fresh_install.sh
-- globs sql/*.sql, so filing an unapproved migration there would make the
-- replay prove something that is not true of the deployment.
--
-- STATUS: fully built. Dry-run end-to-end against the live database inside a
-- rolled-back transaction on 2026-08-07. All assertions passed; rollback left
-- zero residue (old constraint intact, no new index, no function, no rows).
-- NOT applied to any deployment.
--
-- Preflight verified live before the dry run:
--   * wiki_pages_path_key UNIQUE (path) present, exactly as upstream #71 found
--   * 0 duplicate active paths
--   * only inbound FK is wiki_pages_supersedes_fkey, referencing id, not path
--   * the only ON CONFLICT (path) caller is bless_doc, which targets
--     doc_integrity, a different table with its own primary key on path
--
-- FINDING BEYOND UPSTREAM #71: supersession is blocked by TWO independent
-- mechanisms. Besides UNIQUE(path), enforce_bounded_status_transition rejects
-- the status change, and its sanctioned-function list names only
-- promote_memory and supersede_memory, both memories-only. wiki_pages is
-- therefore append-only in practice: insertable, never supersedable. Replacing
-- the constraint alone would NOT have worked, which is why supersede_wiki() is
-- part of this migration rather than a follow-up.

ALTER TABLE public.wiki_pages DROP CONSTRAINT wiki_pages_path_key;

CREATE UNIQUE INDEX wiki_pages_active_path_uq
  ON public.wiki_pages (path) WHERE status = 'current';

-- Hardened, attributed supersession API mirroring supersede_memory: human
-- principal required, row locked, expected-state predicate with an explicit
-- lost-race exception, GUC set/reset wrapped so the guard cannot be left
-- armed, and actor_assurance recorded because a caller-supplied principal UUID
-- proves the UUID belongs to an active human, not that the caller IS that
-- human under a shared credential.
CREATE OR REPLACE FUNCTION supersede_wiki(
  p_path text, p_new_title text, p_new_content text,
  p_new_provenance_basis provenance_basis, p_new_citation text,
  p_acting_principal uuid, p_reason text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_new uuid; v_old wiki_pages%rowtype; v_kind principal_kind;
BEGIN
  SELECT * INTO v_old FROM wiki_pages WHERE path = p_path AND status = 'current' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'no current wiki page at path %', p_path; END IF;

  SELECT kind INTO v_kind FROM principals WHERE id = p_acting_principal AND active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'acting principal % is not an active principal', p_acting_principal;
  END IF;
  IF v_kind <> 'human' THEN
    RAISE EXCEPTION 'only human principals supersede wiki pages (%: %)', p_acting_principal, v_kind;
  END IF;

  BEGIN
    SET LOCAL app.promoting = 'on';
    UPDATE wiki_pages SET status = 'superseded', effective_to = now(), updated_at = now(),
      frontmatter = frontmatter || jsonb_build_object(
        'superseded_by_principal', p_acting_principal, 'superseded_at', now(),
        'actor_assurance', 'caller_asserted_unauthenticated')
    WHERE id = v_old.id AND status = 'current';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'transition lost a race: wiki page % is no longer current', p_path;
    END IF;

    INSERT INTO wiki_pages (path, title, content, tags, workstream, source_kind, source_agent,
      source_ref, provenance_basis, citation, status, supersedes, visibility, owner,
      observed_at, effective_from, recorded_at, frontmatter)
    VALUES (p_path, p_new_title, p_new_content, v_old.tags, v_old.workstream, v_old.source_kind,
      v_old.source_agent, v_old.source_ref, p_new_provenance_basis, p_new_citation, 'current',
      v_old.id, v_old.visibility, v_old.owner, now(), now(), now(),
      coalesce(v_old.frontmatter, '{}'::jsonb) || jsonb_build_object('supersede_reason', p_reason))
    RETURNING id INTO v_new;

    SET LOCAL app.promoting = 'off';
  EXCEPTION WHEN OTHERS THEN
    SET LOCAL app.promoting = 'off';
    RAISE;
  END;

  RETURN v_new;
END; $fn$;

REVOKE EXECUTE ON FUNCTION supersede_wiki(text, text, text, provenance_basis, text, uuid, text)
  FROM anon, authenticated, public;
