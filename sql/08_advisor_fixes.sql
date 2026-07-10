-- 08_advisor_fixes.sql
-- Sovereign Vault (business) — fixes from Supabase security advisor run
--
-- Every function in 01-07 pins search_path explicitly except this one, which
-- was missed because event trigger functions (returns event_trigger) look
-- different from the plpgsql/sql functions the pattern was applied to
-- everywhere else. Supabase's security advisor caught it
-- (function_search_path_mutable) on first run against a real project.
--
-- Idempotent. Safe to re-run.

alter function log_ddl_change() set search_path = public;
