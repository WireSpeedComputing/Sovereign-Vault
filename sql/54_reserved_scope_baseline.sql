-- 54_reserved_scope_baseline.sql
-- MIGRATION: 69_reserved_scope_baseline
-- Register the protocol's reserved workstream:unclassified scope so NULL/blank
-- row mappings have a declared, grantable scope. Registration grants nobody
-- access; reviewed capabilities remain private deployment data.
--
-- Business scopes and agent aliases are deployment vocabulary. This file does
-- not seed them or infer authority from an empty report.

insert into scope_registry (scope, kind, identifier, description)
select 'workstream:unclassified', 'workstream', 'unclassified',
       'Reserved scope for records carrying no workstream. row_scope() maps NULL and empty to this, so it must exist on every deployment; it is protocol, not vocabulary. Granting it is a deliberate act like any other scope -- it is reserved, not exempt.'
where not exists (select 1 from scope_registry where scope = 'workstream:unclassified');
