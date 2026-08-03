-- tests/22_identity_capability_enforcement.sql
--
-- Run after sql/23 on a fresh database, or against a disposable database.
-- Every fixture is transaction-local and must roll back.

begin;

create temporary table identity_test_ids (
  name text primary key,
  id uuid not null
) on commit drop;

do $test$
declare
  reviewer_id uuid;
  human_id uuid;
  inactive_id uuid;
  agent_id uuid;
  expired_id uuid;
  superseded_id uuid;
begin
  insert into public.principals(kind, display_name, agent_label, active, notes)
  values ('agent', 'identity test reviewer', 'identity-test-reviewer', true, 'transactional test; rollback required')
  returning id into reviewer_id;

  insert into public.principals(kind, display_name, email, active, notes)
  values ('human', 'identity test human', 'identity-test@example.invalid', true, 'transactional test; rollback required')
  returning id into human_id;

  insert into public.principals(kind, display_name, email, active, deactivated_at, notes)
  values ('human', 'identity test inactive', 'identity-test-inactive@example.invalid', false, now(), 'transactional test; rollback required')
  returning id into inactive_id;

  insert into public.principals(kind, display_name, agent_label, active, notes)
  values ('agent', 'identity test agent', 'identity-test-agent', true, 'transactional test; rollback required')
  returning id into agent_id;

  insert into public.principals(kind, display_name, email, active, notes)
  values ('human', 'identity test expired', 'identity-test-expired@example.invalid', true, 'transactional test; rollback required')
  returning id into expired_id;

  insert into public.principals(kind, display_name, email, active, notes)
  values ('human', 'identity test superseded', 'identity-test-superseded@example.invalid', true, 'transactional test; rollback required')
  returning id into superseded_id;

  insert into identity_test_ids(name,id) values
    ('reviewer', reviewer_id),
    ('human', human_id),
    ('inactive', inactive_id),
    ('agent', agent_id),
    ('expired', expired_id),
    ('superseded', superseded_id);

  insert into public.capability_grants(principal_id, resource_scope, permissions, granted_by, reason)
  values
    (human_id, 'test:scope', array['read']::public.capability_permission[], reviewer_id, 'transactional test; rollback required'),
    (inactive_id, 'test:scope', array['admin']::public.capability_permission[], reviewer_id, 'transactional test; rollback required'),
    (agent_id, 'test:scope', array['read']::public.capability_permission[], reviewer_id, 'transactional test; rollback required');

  assert public.has_capability(human_id, 'test:scope', 'read'),
    'active principal exact capability must be true';
  assert not public.has_capability(inactive_id, 'test:scope', 'read'),
    'inactive principal must be denied even with admin grant';
  assert not public.has_capability(human_id, 'test:*', 'read'),
    'wildcard scope behavior must remain absent';

  insert into vault_auth.principal_identity_bindings(
    identity_kind, issuer, identity_value, principal_id,
    binding_status, review_status, valid_from, valid_until,
    created_by, reviewed_by, reviewed_at,
    reason, citation, provenance_basis, workstream, source_agent
  ) values
    ('auth_subject', 'https://test.invalid/auth/v1', 'human-sub', human_id,
     'active', 'approved', now() - interval '1 minute', null,
     reviewer_id, reviewer_id, now(),
     'transactional test', 'transactional test', 'source_document', 'tech', 'test-suite'),
    ('oauth_client', 'https://test.invalid/auth/v1', 'agent-client', agent_id,
     'active', 'approved', now() - interval '1 minute', null,
     reviewer_id, reviewer_id, now(),
     'transactional test', 'transactional test', 'source_document', 'tech', 'test-suite'),
    ('auth_subject', 'https://test.invalid/auth/v1', 'expired-sub', expired_id,
     'active', 'approved', now() - interval '2 hours', now() - interval '1 hour',
     reviewer_id, reviewer_id, now(),
     'transactional test', 'transactional test', 'source_document', 'tech', 'test-suite'),
    ('auth_subject', 'https://test.invalid/auth/v1', 'superseded-sub', superseded_id,
     'superseded', 'approved', now() - interval '1 hour', null,
     reviewer_id, reviewer_id, now(),
     'transactional test', 'transactional test', 'source_document', 'tech', 'test-suite'),
    ('auth_subject', 'https://test.invalid/auth/v1', 'inactive-sub', inactive_id,
     'active', 'approved', now() - interval '1 minute', null,
     reviewer_id, reviewer_id, now(),
     'transactional test', 'transactional test', 'source_document', 'tech', 'test-suite');

  assert vault_auth._resolve_human_principal(
    '{"iss":"https://test.invalid/auth/v1","sub":"human-sub"}'::jsonb
  ) = human_id, 'active reviewed human binding must resolve';

  assert vault_auth._resolve_agent_principal(
    '{"iss":"https://test.invalid/auth/v1","sub":"human-sub","client_id":"agent-client"}'::jsonb
  ) = agent_id, 'active reviewed agent binding must resolve';

  assert vault_auth._resolve_human_principal(
    '{"iss":"https://test.invalid/auth/v1","sub":"unknown-sub"}'::jsonb
  ) is null, 'unknown human must fail closed';

  assert vault_auth._resolve_agent_principal(
    '{"iss":"https://test.invalid/auth/v1","sub":"human-sub","client_id":"unknown-client"}'::jsonb
  ) is null, 'unknown agent must fail closed';

  assert vault_auth._resolve_human_principal(
    '{"iss":"https://test.invalid/auth/v1","sub":"expired-sub"}'::jsonb
  ) is null, 'expired binding must fail closed';

  assert vault_auth._resolve_human_principal(
    '{"iss":"https://test.invalid/auth/v1","sub":"superseded-sub"}'::jsonb
  ) is null, 'superseded binding must fail closed';

  assert vault_auth._resolve_human_principal(
    '{"iss":"https://test.invalid/auth/v1","sub":"inactive-sub"}'::jsonb
  ) is null, 'deactivated principal binding must fail closed';

  perform set_config(
    'request.jwt.claims',
    '{"role":"authenticated","iss":"https://test.invalid/auth/v1","sub":"human-sub","client_id":"agent-client"}',
    true
  );
  assert vault_auth.current_human_principal_id() is null,
    'administrative session must not trust forged claims';
  assert vault_auth.request_has_capability('test:scope','read') is false,
    'administrative session with forged claims must return false';
  assert vault_auth.request_has_capability('test:scope','read') is not null,
    'request capability must never return null';

  assert (select count(*) from vault_auth.principal_identity_binding_audit) = 5,
    'every binding insert must have an audit receipt';
end;
$test$;

set role authenticated;
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","iss":"https://test.invalid/auth/v1","sub":"human-sub","client_id":"agent-client","jti":"forged-admin-token"}',
  true
);
do $test$
begin
  assert session_user <> 'authenticator',
    'direct administrative path must not impersonate the PostgREST authenticator session';
  assert current_user = 'authenticated',
    'test must prove current_user alone cannot establish request provenance';
  assert vault_auth.request_has_capability('test:scope','read') is false,
    'administrative path with authenticated current_user and forged claims must be denied';
  assert vault_auth.request_has_capability('test:scope','read') is not null,
    'administrative denial must be false, never null';
end;
$test$;
reset role;

rollback;

-- Expected: no assertion error and no persistent principals, bindings, grants,
-- or audit rows. A real PostgREST token-path test remains deployment-specific.
