-- 48_custody_field_locks_wiki_pages.sql
--
-- MIGRATION: 57_custody_field_locks_wiki_pages
--
-- Extends chain-of-custody field locking to wiki_pages, closing an asymmetry
-- flagged in the memories lock but not acted on at the time: 1 custody trigger
-- on memories, 0 on wiki_pages. Every claim recorded there was rewritable in
-- place while the equivalent claims in memories were not.
--
-- That asymmetry was invisible to any review asking whether custody locking
-- existed, because it did -- on one table. **An implementation is only as
-- immutable as its least-protected record type.**
--
-- WHY IT WAS HELD BACK, and why that was right: applying it required verifying
-- supersede_wiki() against it first. A lock that also broke the sanctioned
-- correction path would look identical in a trigger listing and would fail
-- silently at the first correction, under a workflow nobody exercises while
-- implementing. Verified in a rolled-back transaction against the deployment
-- before applying: content and source_agent rejected, supersede_wiki()
-- succeeds, tags still mutable.
--
-- LOCKED: identity, path, recorded/observed/effective times, provenance basis,
-- citation, source kind and agent, supersession pointer, content.
--
-- `path` is locked here where memories has no equivalent, because path is the
-- addressable locator. Retrieval emits locators of the form 'wiki:<path>#<n>',
-- so a mutable path silently invalidates every citation that ever pointed at
-- the page. Supersession does not need it mutable -- it appends a successor AT
-- the same path rather than moving the predecessor.
--
-- MUTABLE: status, effective_to, title, tags, workstream, owner, visibility,
-- frontmatter, embedding and its bookkeeping, confidence, updated_at.
-- frontmatter must stay mutable because supersede_wiki() records the acting
-- principal and assurance there on the predecessor row.
--
-- Title deliberately NOT locked, unlike content: it is presentation metadata,
-- and locking it would force superseding an entire accurate document to correct
-- a heading typo.

create or replace function enforce_custody_field_locks_wiki()
returns trigger language plpgsql as $fn$
declare v text := '';
begin
  if new.id               is distinct from old.id               then v := v||'id '; end if;
  if new.path             is distinct from old.path             then v := v||'path '; end if;
  if new.recorded_at      is distinct from old.recorded_at      then v := v||'recorded_at '; end if;
  if new.observed_at      is distinct from old.observed_at      then v := v||'observed_at '; end if;
  if new.effective_from   is distinct from old.effective_from   then v := v||'effective_from '; end if;
  if new.provenance_basis is distinct from old.provenance_basis then v := v||'provenance_basis '; end if;
  if new.citation         is distinct from old.citation         then v := v||'citation '; end if;
  if new.source_kind      is distinct from old.source_kind      then v := v||'source_kind '; end if;
  if new.source_agent     is distinct from old.source_agent     then v := v||'source_agent '; end if;
  if new.supersedes       is distinct from old.supersedes       then v := v||'supersedes '; end if;
  if new.content          is distinct from old.content          then v := v||'content '; end if;
  if v <> '' then
    raise exception 'custody fields are locked after recording on wiki_pages (attempted: %). Corrections append a successor via supersede_wiki(); they never rewrite the original claim.', btrim(v);
  end if;
  return new;
end; $fn$;

drop trigger if exists trg_custody_locks_wiki on wiki_pages;
create trigger trg_custody_locks_wiki
  before update on wiki_pages
  for each row execute function enforce_custody_field_locks_wiki();

comment on function enforce_custody_field_locks_wiki() is
  'Chain-of-custody field locking for wiki_pages. Mirrors the memories lock, with path additionally locked because it is the addressable locator cited by retrieval. Title stays mutable as presentation metadata.';
