-- 50_authorization_audit_judged_by.sql
--
-- MIGRATION: 64_authorization_audit_judged_by
--
-- record_authorization_audit could not express who made the judgement.
--
-- THE PROBLEM. reclassify_record() requires a human acting_principal, correctly:
-- changing a record's workstream moves it between authorization scopes and that
-- must be human-authorized. But during a bulk classification, the human
-- authorized the operation while an AGENT made every individual judgement about
-- which scope each record belonged to.
--
-- Every audit row therefore names the human as acting_principal. The reason
-- strings said an agent judged it, but prose is not queryable and the structured
-- field asserted something the structured field could not qualify. Anyone
-- reading the audit table -- rather than reading every reason string --
-- concludes a human classified each record one at a time. That is false, in the
-- table whose entire purpose is being trustworthy.
--
-- SAME SHAPE AS TWO PROBLEMS ALREADY SOLVED HERE, and it takes the same fix:
--   * actor_assurance, which records that a caller-supplied principal proves the
--     identifier belongs to an active human, not that the caller IS that human.
--   * the statement layer's two-claim model, where a world-claim from the source
--     and a fidelity-claim from the extractor are never collapsed into a single
--     author column, because either single answer would be wrong.
--
-- Authorization and judgement are different acts by different parties. A schema
-- that can only name one of them will name the wrong one about half the time.
--
-- THE FIX: separate fields, one truth each. acting_principal keeps its meaning
-- unchanged. Both new fields nullable, because the common case is one party
-- doing both and duplicating the value would add noise without adding truth.
--
-- DELIBERATELY NOT BACKFILLED. Existing rows could be set from their reason
-- strings, but inferring structured custody data from prose is exactly what the
-- mapping-not-rewriting rule exists to prevent. Old rows stay honest about
-- having been imprecise; new rows can be precise.

alter table record_authorization_audit
  add column judged_by uuid references principals(id),
  add column judgement_basis text;

comment on column record_authorization_audit.acting_principal is
  'Who AUTHORIZED the change. Must be an active human. Unchanged meaning.';

comment on column record_authorization_audit.judged_by is
  'Who exercised the JUDGEMENT, if different from the authorizer. Null means the authorizer judged it themselves. Set when a human authorizes an operation whose per-record decisions were made by an agent -- bulk classification being the motivating case.';

comment on column record_authorization_audit.judgement_basis is
  'How the judgement was reached: agent_inspection, human_review, imported_mapping. Free text rather than an enum until the vocabulary is observed rather than guessed.';

comment on table record_authorization_audit is
  'Audit of changes to authorization inputs (workstream, owner, visibility). Authorization and judgement are recorded separately: a human may authorize an operation whose individual decisions an agent made, and collapsing those into one actor field records something false.';
