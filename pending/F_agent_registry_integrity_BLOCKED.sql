-- BLOCKED — NOT APPLICABLE AS WRITTEN. Moved out of sql/ 2026-08-08.
--
-- Built before migration 51 (sql/39, custody field locks) was applied. The two
-- designs are incompatible, and this file's own test proves it:
--
--   b5_update_to_unregistered_rejected  expects rejection by THIS file's
--     registry guard; gets rejection by the custody lock instead. It would pass
--     for the wrong reason if the assertion did not check which guard fired.
--   c6_reattribution_between_active_agents_allowed  expects reattribution
--     between two active agents to SUCCEED. sql/39 locks source_agent from
--     insert, so reattribution is impossible by design.
--
-- sql/39 is explicit that this is intended: "Agent attribution had to be
-- resolved by MAPPING before this landed, because afterwards source_agent
-- cannot be rewritten even to correct it."
--
-- So this is not a bug in either file. It is a design fork:
--   custody-first (APPLIED): attribution is immutable, corrections append.
--   registry-first (this file): attribution is correctable between registered,
--     active agents.
-- Both are defensible; they cannot both hold. Resolving it is an owner
-- decision, queued in the exit report -- not something to settle by editing a
-- test until it goes green.
--
-- Applying this as-is would install a guard whose own test fails.
--
-- 33_agent_registry_integrity.sql
--
-- ***** NOT YET APPLIED to any deployment. *****
-- Declares no `-- MIGRATION:` header on purpose; tests/migration_drift.sh reads
-- that absence as "not yet applied".
--
-- ADOPT (partial): sibling protocol repo sovereign-memory-core, its
-- `trusted_agents` registry (sql/01_core.sql lines 24-44) and the referential
-- integrity it hangs off it: `memories.source_agent text NOT NULL REFERENCES
-- trusted_agents(agent_id)` (its sql/01_core.sql line 59).
--
-- ── SOURCING NOTE ──────────────────────────────────────────────────────────
-- The work order cited upstream issue #4. Upstream #4 is CLOSED with the body
-- "This work is tracked privately" and states no requirements. This file is
-- therefore written against the sibling's SHIPPED registry semantics, which are
-- readable, rather than against an issue that says nothing. Flagged, not hidden.
--
-- ── THE DIFF ───────────────────────────────────────────────────────────────
-- What the sibling has that we already have, in a stronger form:
--   trusted_agents.agent_id            -> principals.agent_label (UNIQUE partial index, sql/02)
--   trusted_agents.active / retired_at -> principals.active / deactivated_at
--   trusted_agents.principal           -> vault_auth.principal_identity_bindings (sql/23),
--                                         which binds a real OAuth client to an agent
--                                         principal and is reviewed; a text column
--                                         naming a household member is weaker.
--   (no sibling equivalent)            -> capability_grants (sql/02): what the agent
--                                         may DO, scoped and revocable.
--
-- What the sibling has that we deliberately do NOT adopt:
--   trusted_agents.model, .surface     -> descriptive deployment metadata, not
--                                         governance. Nothing enforces on them
--                                         there either. `capability_grants`
--                                         already answers the only question that
--                                         has consequences, and principals.notes
--                                         holds the rest. Adding two unenforced
--                                         columns would grow the schema without
--                                         growing any invariant.
--   a separate registry TABLE          -> we would then have two writer-identity
--                                         tables that can disagree. principals
--                                         with kind='agent' IS the registry.
--
-- ── WHAT WAS ACTUALLY MISSING, AND IT IS THE WHOLE POINT ───────────────────
-- The sibling's registry is load-bearing because of the FOREIGN KEY, not
-- because of the table. Ours has no such link:
--
--   sql/01_core.sql line 23 : source_agent text,        -- nullable, NO reference
--   sql/22 line 18          : alter table wiki_pages add column source_agent text;
--
-- So `source_agent` is unvalidated free text. Any writer can stamp a row
-- 'AGENT-THAT-NEVER-EXISTED', or the agent_label of an agent that was
-- deactivated years ago, and every provenance trigger in sql/03 passes it.
-- sql/22's own header calls source_agent "an attribution hole ... a page can
-- satisfy every provenance trigger and still not say who produced it" — the
-- hole it closed was the missing COLUMN; the column being unvalidated is the
-- same hole one layer down.
--
-- This matters more here than upstream, because sql/03's
-- enforce_agent_cannot_self_attest() keys on source_kind='agent', and sql/26's
-- header line 30 already records why keying on a caller-declared field is weak:
-- "any rule keyed on it is bypassable by assertion". `source_agent` is the
-- field that is supposed to be checkable. Today it is not.
--
-- ── WHY A TRIGGER AND NOT A FOREIGN KEY ────────────────────────────────────
-- The sibling can use an FK because its registry's primary key IS the agent id.
-- Ours would need an FK to principals(agent_label), which requires a total
-- UNIQUE constraint on that column; sql/02 line 30 deliberately made it a
-- PARTIAL unique index (`where agent_label is not null`) so human principals
-- need not carry a label. Converting it would change the principals table's
-- shape for every other consumer. A trigger also lets us enforce `kind='agent'
-- AND active`, which an FK cannot express at all — and "the writer must be an
-- agent, and must have been an active one" is the actual invariant.
--
-- ── SCOPE: memories AND wiki_pages ONLY ────────────────────────────────────
-- Eleven tables in this schema carry a source_agent column. This file covers
-- two. That asymmetry is deliberate and is asserted as a DOCUMENTED LIMIT in
-- tests/33 Section D rather than left to be discovered:
--   * memories and wiki_pages are the custody substrate, and are the two tables
--     the sibling covers.
--   * The sql/10 and sql/11 domain tables are exercised by tests/12 and
--     tests/20, which carry the deployment-only opt-out marker and therefore DO
--     NOT RUN in a fresh replay. Extending a rejecting guard onto tables whose test suite
--     cannot be executed here would be shipping an unverified break. Extending
--     coverage is a separate, deployment-verified change.
-- sql/26 made the same call for the same reason (its guard is memories-only,
-- with the wiki asymmetry recorded rather than shipped as a break).
--
-- ── LEGITIMATE PATHS THIS MUST NOT CLOSE, AND DOES NOT ─────────────────────
--  1. source_agent IS NULL stays legal. A human-authored or manual row has no
--     agent, and forcing one would make writers invent an attribution. The
--     sibling's NOT NULL is only workable because it seeds a 'system' pseudo-
--     agent; inventing a placeholder agent to satisfy a constraint defeats the
--     constraint. NULL means "no agent wrote this" and that is a true statement.
--  2. Retiring an agent must not freeze the rows it already wrote. On UPDATE the
--     check runs ONLY when source_agent actually changes. Marking a deadline
--     done on a five-year-old row written by a since-deactivated agent still
--     works. A guard that made history unmaintainable would have broken the
--     system, not secured it.
--  3. SUPERSESSION OF A DEACTIVATED AGENT'S WORK. This one nearly shipped as a
--     break, and it is why the guard has two tiers instead of one.
--
--     The first version of this file required source_agent to name an ACTIVE
--     agent on every INSERT. The two supersession paths do not agree on how
--     they carry authorship:
--
--       supersede_memory() (sql/26 line ~397) writes the successor as
--         source_kind='manual', source_agent=NULL, preserving the predecessor's
--         authorship in metadata.corrected_from_source_agent. Unaffected.
--
--       supersede_wiki()   (sql/24 line ~70) COPIES v_old.source_agent forward
--         onto the successor row, unchanged.
--
--     So under a single-tier guard, deactivating an agent would make every wiki
--     page it ever authored PERMANENTLY UNCORRECTABLE: supersede_wiki() inserts
--     a successor stamped with the now-inactive label and is rejected. That is
--     the same "two individually-correct rules composing into a dead end" that
--     sql/26 line ~380 records finding in supersede_memory. Found here by
--     reading sql/24 after making the claim, not by testing — the claim in an
--     earlier draft of this header, that supersession copies nothing forward,
--     was simply false for wiki.
--
--     The fix is to separate two different questions that a single `active`
--     check was conflating:
--
--       REGISTRATION  "does this label name an agent principal at all?"
--                     Unconditional. An unregistered label is a fabricated
--                     attribution and is always rejected.
--       ACTIVENESS    "may this agent author something NEW right now?"
--                     Required for fresh authorship only, and waived inside a
--                     sanctioned transition (app.promoting armed), which is what
--                     supersede_wiki() and promote_memory() set. Carrying a
--                     historical attribution forward through the repo's own
--                     correction path is not fresh authorship.
--
-- ── AND THE LIMITS, STATED THE SAME WAY THE REST OF THE REPO STATES THEM ───
--  * This proves the label names a REGISTERED agent. It does not prove the
--    caller IS that agent. source_agent remains caller-asserted; a service_role
--    caller can still stamp any registered label. This closes "attribution to a
--    writer that does not exist", not "impersonation of one that does". Real
--    enforcement needs per-principal connection identity — vault_auth (sql/23),
--    not this file.
--  * The activeness tier is waived inside a sanctioned transition, and
--    app.promoting is a self-armable session GUC. A caller who arms it can stamp
--    a deactivated agent on a fresh row. Registration is NOT waived and holds
--    regardless. Same limit already recorded for app.promoting in sql/13,
--    sql/20 and sql/26, and asserted in tests/33 Section D.

-- ══════════════════════════════════════════════════════════════════════════
-- PART 1 — the predicate, as a TOTAL function with an explicit vocabulary
-- ══════════════════════════════════════════════════════════════════════════
-- Returns a STATE, not a boolean, for the same reason verify_doc_integrity()
-- returns no-blessing/match/mismatch and verify_promoted_integrity() returns
-- unaudited/match/mismatch: the two failure modes are not the same failure, and
-- collapsing them into one boolean is what produced the supersede_wiki dead end
-- described above. 'unregistered' is a fabricated attribution; 'inactive' is a
-- real agent that has been retired. Different facts, different consequences.
--
--   'no_agent'     -- label is NULL: no agent claimed. Not a failure.
--   'unregistered' -- no principal of kind='agent' carries this label.
--   'inactive'     -- registered agent principal, but active = false.
--   'active'       -- registered and active.
--
-- TOTAL by construction, for the reason sql/31_is_owner_or_shared_total_function
-- gives at length: the trigger below branches on this value, and a NULL would
-- match none of its branches and fall through to `return new` — the guard would
-- fail OPEN while reading as correct. Every path here returns a non-NULL text.
--
-- Deliberately NOT marked STRICT: STRICT returns NULL for a NULL argument, which
-- is precisely the defect being avoided. NULL handling lives in the body.

create or replace function public.agent_label_state(p_agent_label text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_agent_label is null then 'no_agent'
    else coalesce((
      select case when p.active then 'active' else 'inactive' end
      from principals p
      where p.agent_label = p_agent_label
        and p.kind = 'agent'
      limit 1), 'unregistered')
  end;
$$;

comment on function public.agent_label_state(text) is
  'Total function: no_agent | unregistered | inactive | active for a source_agent label. Never returns NULL and is deliberately not STRICT, since the trigger that branches on it would fall through to acceptance on a NULL. Proves the label is registered, NOT that the caller is that agent.';

revoke all on function public.agent_label_state(text) from public, anon, authenticated;
grant execute on function public.agent_label_state(text) to service_role;

-- ══════════════════════════════════════════════════════════════════════════
-- PART 2 — the guard
-- ══════════════════════════════════════════════════════════════════════════

create or replace function public.enforce_registered_source_agent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_state text;
begin
  -- No agent claimed: nothing to validate. See "legitimate paths" rule 1.
  if new.source_agent is null then
    return new;
  end if;

  -- Unchanged on UPDATE: do not re-litigate history. See rule 2. Written with
  -- IS NOT DISTINCT FROM so a NULL->NULL or value->same-value comparison is a
  -- real boolean, not NULL.
  --
  -- Nested rather than `tg_op = 'UPDATE' and new... is not distinct from old...`
  -- deliberately: PL/pgSQL hands that whole expression to SQL, SQL's AND is not
  -- guaranteed to short-circuit, and OLD is unassigned during an INSERT, so the
  -- one-line form can raise "record old is not assigned yet" on the INSERT path.
  -- Found by running it, not by reading it.
  if tg_op = 'UPDATE' then
    if new.source_agent is not distinct from old.source_agent then
      return new;
    end if;
  end if;

  v_state := public.agent_label_state(new.source_agent);

  -- TIER 1 -- REGISTRATION. Unconditional. A label naming no agent principal is
  -- a fabricated attribution, and no transition, sanctioned or not, makes one
  -- legitimate.
  --
  -- RAISE takes only `%` -- it has no %L/%I/%s. Using %L here would emit the
  -- literal text "%L" into the operator's error message.
  if v_state = 'unregistered' then
    raise exception
      'source_agent "%" is not a registered agent principal on %.% (row id: %). Register it as a principals row with kind=''agent'' and agent_label=''%'', or leave source_agent NULL if no agent wrote this row.',
      new.source_agent, tg_table_schema, tg_table_name, new.id, new.source_agent;
  end if;

  -- TIER 2 -- ACTIVENESS. Fresh authorship only. Waived inside a sanctioned
  -- transition, because supersede_wiki() (sql/24) carries the predecessor's
  -- source_agent onto the successor row: without this waiver, deactivating an
  -- agent would make every wiki page it authored permanently uncorrectable.
  -- See the header. The waiver's own limit is that app.promoting is
  -- self-armable, which is recorded there and asserted in tests/33 Section D.
  if v_state = 'inactive'
     and coalesce(current_setting('app.promoting', true), 'off') <> 'on' then
    raise exception
      'source_agent "%" names a DEACTIVATED agent principal on %.% (row id: %). A retired agent cannot author new rows. Reactivate the principal, attribute the row to an active agent, or leave source_agent NULL. Correcting existing work through supersede_wiki()/supersede_memory() is unaffected.',
      new.source_agent, tg_table_schema, tg_table_name, new.id;
  end if;

  return new;
end; $$;

comment on function public.enforce_registered_source_agent() is
  'Two-tier guard on source_agent. Tier 1 (registration) is unconditional: an unregistered label is always rejected. Tier 2 (activeness) applies to fresh authorship only and is waived while app.promoting is armed, so supersede_wiki() can carry a retired agent''s attribution forward. Checked on INSERT always, and on UPDATE only when the value changes, so deactivating an agent does not freeze the rows it already wrote.';

revoke all on function public.enforce_registered_source_agent() from public, anon, authenticated;

drop trigger if exists trg_registered_source_agent_memories on public.memories;
create trigger trg_registered_source_agent_memories
  before insert or update on public.memories
  for each row execute function public.enforce_registered_source_agent();

drop trigger if exists trg_registered_source_agent_wiki on public.wiki_pages;
create trigger trg_registered_source_agent_wiki
  before insert or update on public.wiki_pages
  for each row execute function public.enforce_registered_source_agent();

-- ══════════════════════════════════════════════════════════════════════════
-- PART 3 — detection surface for rows that predate the guard
-- ══════════════════════════════════════════════════════════════════════════
-- Prevention and detection are separate layers, for the reason sql/26 lines
-- 166-169 give. Any row written BEFORE this file was applied was never checked,
-- and the guard says nothing about it. Reported as its own state rather than
-- folded into a pass -- the same discipline as 'unaudited' in
-- verify_promoted_integrity() and 'no-blessing' in verify_doc_integrity().

create or replace function public.source_agent_attribution_report()
returns table (table_name text, record_id uuid, source_agent text, state text)
language sql
stable
security definer
set search_path = public
as $$
  select 'memories'::text, m.id, m.source_agent, public.agent_label_state(m.source_agent)
  from memories m where m.source_agent is not null
  union all
  select 'wiki_pages'::text, w.id, w.source_agent, public.agent_label_state(w.source_agent)
  from wiki_pages w where w.source_agent is not null;
$$;

comment on function public.source_agent_attribution_report() is
  'Every row carrying a source_agent, with that label''s current state (active | inactive | unregistered). Rows written before sql/33 was applied were never checked; state=unregistered names them instead of leaving them silent. state=inactive is not a defect -- it is a retired agent''s preserved historical attribution.';

revoke all on function public.source_agent_attribution_report() from public, anon, authenticated;
grant execute on function public.source_agent_attribution_report() to service_role;
