-- 19_schema_changelog_rls.sql
-- Sovereign Vault — close an RLS gap on the DDL changelog table.
--
-- Why this file exists: sql/01_core.sql creates schema_changelog and enables
-- RLS on every other core table, but omitted this one. sql/07's remediation
-- sweep revokes GRANTS on pre-existing tables, which is a different control:
-- revoking grants without enabling RLS leaves the table dependent on grant
-- hygiene alone, and any future grant (including a default-privilege grant
-- from an extension or a hand-run GRANT) reopens it with no policy backstop.
--
-- This was found on a live deployment where the table showed RLS disabled
-- while every sibling table had it enabled. Fixed there first; committed here
-- afterward so a fresh install from this repo is not weaker than the
-- deployment it was extracted from.
--
-- Idempotent. Safe to re-run.

alter table public.schema_changelog enable row level security;

revoke all on public.schema_changelog from anon, authenticated;

-- No policy is added: the changelog is written by a SECURITY DEFINER event
-- trigger function and read by the service/admin path only. RLS enabled with
-- no policy is default-deny, which is the intended posture. If a future
-- capability-aware read policy is wanted, follow the template in
-- docs/01-architecture.md.
