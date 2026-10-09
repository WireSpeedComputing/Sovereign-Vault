-- 19_schema_changelog_rls.sql
-- Ensure the schema-change ledger participates in the same enabled-RLS
-- perimeter as other repository-owned tables. This migration changes no
-- row content and creates no permissive runtime policy.

alter table public.schema_changelog enable row level security;

revoke all on public.schema_changelog from anon, authenticated;

-- No policy is added: the changelog is written by a SECURITY DEFINER event
-- trigger function and read by the service/admin path only. RLS enabled with
-- no policy is default-deny, which is the intended posture. If a future
-- capability-aware read policy is wanted, follow the template in
-- docs/01-architecture.md.
