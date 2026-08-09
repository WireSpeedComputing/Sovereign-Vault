-- 52_audit_triggers_enable_always.sql
--
-- MIGRATION: 67_audit_triggers_enable_always
--
-- WO-15 Phase B2. "TRUNCATE is revoked, so find the next table-level operation
-- that bypasses row-level enforcement."
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE ANSWER: session_replication_role = replica
-- ══════════════════════════════════════════════════════════════════════════
-- One SET, session-scoped, and every ORIGIN-mode trigger stops firing. Measured
-- on the live deployment: 39 of 39 non-internal triggers in `public` are origin
-- mode, including all 25 on the governed tables --
--
--   custody field locks           trg_custody_locks_memories / _wiki
--   authorization input locks     trg_authorization_input_locks / _wiki
--   bounded status transitions    trg_bounded_status_memories / _wiki
--   hard-delete guard             trg_guard_hard_delete_memories / _wiki
--   provenance enforcement        trg_enforce_provenance_*
--   agent self-attestation guard  trg_agent_no_self_attest_*
--   consequential domain ratchet  trg_consequential_domain_*
--   append-only audit guards      trg_hard_delete_audit_append_only,
--                                 trg_record_auth_audit_append_only
--
-- It is strictly worse than the TRUNCATE hole in one respect: TRUNCATE only
-- destroys, and destruction is at least conspicuous. Replica mode permits
-- silent, selective, in-place UPDATE of custody-locked fields, with the
-- delete-audit and authorization-audit guards off at the same time. The record
-- afterwards is not merely unattributed -- it is FALSE, and nothing in the
-- database contradicts it. That is the property B2 asks about.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHO CAN ACTUALLY DO IT -- and this is better news than TRUNCATE was
-- ══════════════════════════════════════════════════════════════════════════
-- Measured, not assumed:
--   pg_settings.context for session_replication_role : superuser
--   service_role is superuser                        : false
--   explicit SET grants on that parameter            : 0
--
-- So unlike TRUNCATE, this is NOT reachable by the shared service credential
-- that every agent runs under. It needs a superuser session -- which in
-- practice means the platform owner role, and that role can already DROP the
-- tables. It therefore sits inside the "a sufficiently privileged role can do
-- anything" class that docs/04 already records, rather than opening a new one.
--
-- Recorded precisely because the instinct is to rank it with TRUNCATE. It is a
-- different severity for a specific, checkable reason.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT THIS CHANGES, AND WHAT IT DELIBERATELY DOES NOT
-- ══════════════════════════════════════════════════════════════════════════
-- ENABLE ALWAYS makes a trigger fire even in replica mode. The tempting move is
-- to apply it to all 25. That would break the restore.
--
-- tests/restore_sovereign_package.sh loads the data payload with
-- session_replication_role = replica precisely so provenance, custody and
-- projection-sync triggers do NOT fire on every restored row -- otherwise the
-- restore either aborts or mutates the data as it lands. Making those triggers
-- ALWAYS would make the system unrestorable, which trades a
-- superuser-only bypass for a guaranteed loss of recoverability. That is a bad
-- trade and it is the reason this file is narrow.
--
-- So: ONLY the two append-only AUDIT guards become ALWAYS.
--
-- They are safe to harden because of what they actually do: they refuse UPDATE
-- and DELETE. A restore does neither to these tables -- it clears them with
-- TRUNCATE (statement-level, never fires a row trigger) and repopulates with
-- COPY (an INSERT path, which these guards do not touch). Verified against the
-- restore script rather than assumed.
--
-- The bar this raises: silently rewriting the audit used to cost one SET. It
-- now costs an explicit ALTER TABLE ... DISABLE TRIGGER per guard, which is DDL,
-- which the schema changelog records. The evidence of tampering does not become
-- impossible to destroy -- it becomes impossible to destroy QUIETLY, which is
-- the honest form of the claim.

alter table hard_delete_audit
  enable always trigger trg_hard_delete_audit_append_only;

alter table record_authorization_audit
  enable always trigger trg_record_auth_audit_append_only;

comment on table hard_delete_audit is
  'Append-only receipt for sanctioned hard deletes. Its guard is ENABLE ALWAYS, so it fires even under session_replication_role=replica: an audit that a single session-level SET can switch off is not an audit. Disabling it now requires an explicit ALTER TABLE, which is DDL and is recorded.';

comment on table record_authorization_audit is
  'Append-only record of changes to authorization inputs (workstream, owner, visibility). Its guard is ENABLE ALWAYS for the same reason as hard_delete_audit: replica mode must not silently switch off the record of who changed who-can-read-what.';
