# Architecture

## Two layers

**Generic knowledge layer** (`sql/01_core.sql` onward): memories, wiki pages,
hot index, deadlines, doc integrity, DDL changelog, principals, capability
grants, provenance enforcement, temporal truth. This is domain-agnostic and
should not need business-specific changes.

**Domain layer** (bring your own schema): products, orders, suppliers,
customers, whatever your business actually tracks. Not included in this repo.
Each business builds this layer on top of the generic one, following the
contract below.

## Contract for domain tables

If a domain table holds facts that matter enough to need a history (pricing,
supplier terms, headcount, contract status — the "consequential" tables),
give it:

1. **Temporal columns**, matching `sql/04_temporal.sql`'s pattern:
   `observed_at`, `effective_from`, `effective_to`, `recorded_at`,
   `record_status` (the enum from `sql/01_core.sql`), `supersedes` (self-FK).
2. **A `supersede_<table>()` function**, not direct `UPDATE` on current rows.
   Template:

   ```sql
   create or replace function supersede_<table>(
     p_old_id uuid, p_new_row <table>, p_reason text default null
   ) returns uuid language plpgsql security definer set search_path = public as $$
   declare v_new_id uuid;
   begin
     update <table> set record_status = 'superseded', effective_to = now()
     where id = p_old_id and record_status = 'current';
     if not found then raise exception 'no current row % to supersede', p_old_id; end if;

     insert into <table> (/* columns */, record_status, supersedes, effective_from, recorded_at)
     values (/* values from p_new_row */, 'current', p_old_id, now(), now())
     returning id into v_new_id;

     return v_new_id;
   end; $$;
   ```

3. **Provenance columns** (`provenance_basis`, `citation`) if the table should
   reject unsourced writes. Register it:

   ```sql
   insert into provenance_registry (table_name) values ('<table>');
   create trigger trg_enforce_provenance_<table>
     before insert or update on <table>
     for each row execute function enforce_provenance();
   ```

4. **RLS enabled, default-deny**, with policies built on `has_capability()`:

   ```sql
   alter table <table> enable row level security;
   revoke all on <table> from anon, authenticated;

   create policy <table>_read on <table> for select
     using (has_capability(auth.uid()::uuid, 'table:<table>', 'read'));
   create policy <table>_write on <table> for insert
     with check (has_capability(auth.uid()::uuid, 'table:<table>', 'write'));
   -- etc for update/delete, mapped to appropriate permissions
   ```

   Note: `auth.uid()` returning a Postgres-auth UUID needs to map to a
   `principals.id`. Decide whether `principals.id` IS the auth UID (simplest)
   or needs a join table — pick one and document it before Phase 2 onboarding.
   This repo assumes `principals.id = auth.uid()` for humans authenticated via
   Supabase Auth, and a separate `external_ref` lookup for service/agent
   principals that don't go through Supabase Auth at all.

## Why the split

A business's canonical facts (what do you sell, who's your supplier) are
too varied to standardize across businesses, and forcing them into this
repo would turn "bring your own schema" into "inherit our opinions about your
business." The generic layer only owns what's actually universal: how facts
get recorded, corrected, sourced, and who's allowed to touch them.

## Multi-agent coordination (unchanged concept from personal core, reused here)

Agents register as `principals` with `kind = 'agent'`. Cross-instance
coordination (model channels, in the personal core's language) is just
`memories` tagged appropriately and filtered by `source_agent` — no separate
mechanism needed, which is a simplification relative to a dedicated channel
table. If message volume between agents grows large enough that this becomes
noisy, a dedicated table is a reasonable Phase 3+ addition, not a Phase 1 one.

## The open question this repo does not close

Every write today, regardless of which agent or human initiates it, likely
authenticates as one Supabase service-role key. `principals` and
`capability_grants` describe who *should* be able to do what, but nothing in
Phase 1's SQL *enforces* that at the connection layer — RLS policies built on
`has_capability()` only bind if the connecting role's identity maps to a real
`principals.id`. Until each principal (or at minimum each agent) connects
with its own identity — a scoped Supabase JWT claim, a per-agent API key
mapped through `principals.external_ref`, or equivalent — the service-role
key is a skeleton key that bypasses everything above it. This is explicitly
called out in STATUS.md as unresolved and is the single most important thing
to fix before calling Phase 1 complete.
