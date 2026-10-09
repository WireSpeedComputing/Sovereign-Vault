-- 52_audit_triggers_enable_always.sql
-- MIGRATION: 67_audit_triggers_enable_always
-- Origin-mode triggers do not run under session_replication_role=replica.
-- Verify parameter privileges on the selected host; administrative connections
-- remain outside the ordinary user boundary.
--
-- Harden only append-only audit UPDATE/DELETE guards to ENABLE ALWAYS. The
-- restore path uses TRUNCATE/COPY and requires other canonical guards to retain
-- their reviewed restore behavior. This does not prevent a privileged owner
-- from explicitly disabling triggers or altering the schema.

alter table hard_delete_audit
  enable always trigger trg_hard_delete_audit_append_only;

alter table record_authorization_audit
  enable always trigger trg_record_auth_audit_append_only;

comment on table hard_delete_audit is
  'Append-only receipt for sanctioned hard deletes. Its guard is ENABLE ALWAYS, so it fires even under session_replication_role=replica: an audit that a single session-level SET can switch off is not an audit. Disabling it now requires an explicit ALTER TABLE, which is DDL and is recorded.';

comment on table record_authorization_audit is
  'Append-only record of changes to authorization inputs (workstream, owner, visibility). Its guard is ENABLE ALWAYS for the same reason as hard_delete_audit: replica mode must not silently switch off the record of who changed who-can-read-what.';
