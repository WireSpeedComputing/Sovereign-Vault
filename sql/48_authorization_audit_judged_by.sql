-- 48_authorization_audit_judged_by.sql
-- MIGRATION: 64_authorization_audit_judged_by
-- Separate the principal authorizing a classification transition from the
-- party making the individual classification judgment. Keep each structured
-- attribution explicit rather than inferring it from free-text reasons.
-- Nullable judgment fields preserve legacy records without inventing actors.

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
