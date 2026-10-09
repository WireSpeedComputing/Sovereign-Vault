-- UNAPPLIED candidate. Generic business tools; no deployment or identity seed.
-- Requires sql/23, sql/25, sql/28, sql/36 and sql/37 identity/RLS/perimeter contracts.
-- Apply pending/F_business_live_session.sql after this on Supabase. The default
-- session seam DENIES ALL, deliberately: a JWT binding is not a live session.
-- No existing signatures are changed. No elevated retrieve_context/promote path
-- is exposed. The RPC owner is neither a table owner nor a BYPASSRLS role.
-- Rollback: revoke the four authenticated EXECUTE grants, retain immutable
-- sidecar receipts; do not delete submitted evidence or canonical user records.
begin;
do $setup$
begin
  if to_regprocedure('vault_auth.current_human_principal_id()') is null
     or to_regprocedure('vault_auth.current_agent_principal_id()') is null
     or to_regprocedure('public.can_read_row_as_request(uuid,public.visibility_level,text)') is null
     or to_regprocedure('public.request_has_capability(text,public.capability_permission)') is null
     or to_regclass('public.perimeter_exception') is null then
    raise exception 'business tools require the canonical identity and RLS contracts';
  end if;
  if exists(select 1 from pg_roles where rolname='business_user_tools_v1')
     or to_regnamespace('business_user_tools_private') is not null then
    raise exception 'business tools candidate already exists; review drift before applying';
  end if;
  if not exists(select 1 from pg_class where oid='public.memories'::regclass and relrowsecurity)
     or not exists(select 1 from pg_class where oid='public.wiki_pages'::regclass and relrowsecurity) then
    raise exception 'business tools require enabled canonical row policies';
  end if;
end $setup$;
create role business_user_tools_v1 nologin nosuperuser nocreatedb nocreaterole noinherit nobypassrls;
-- Needed only to transfer function ownership as a non-superuser controller.
grant business_user_tools_v1 to current_user with inherit true, set true;
create schema business_user_tools_private;
revoke all on schema business_user_tools_private from public, anon, authenticated;
grant usage on schema public, vault_auth, business_user_tools_private to business_user_tools_v1;
grant create on schema public to business_user_tools_v1;
grant execute on function vault_auth._trusted_request_claims(),
  vault_auth.current_human_principal_id(), vault_auth.current_agent_principal_id(),
  vault_auth.request_has_capability(text,public.capability_permission),
  public.can_read_row_as_request(uuid,public.visibility_level,text),
  public.request_has_capability(text,public.capability_permission), public.row_scope(text)
  to business_user_tools_v1;

create function business_user_tools_private.live_session_is_active_v1()
returns boolean language sql stable security invoker set search_path=pg_catalog
as $$ select false $$;
revoke all on function business_user_tools_private.live_session_is_active_v1() from public, anon, authenticated;
grant execute on function business_user_tools_private.live_session_is_active_v1() to business_user_tools_v1;

create function business_user_tools_private.request_actor_v1()
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $fn$
declare c jsonb; h uuid; a uuid; client text;
begin
  c := vault_auth._trusted_request_claims();
  client := c->>'client_id';
  if c is null or c->>'role' is distinct from 'authenticated'
     or client is null or length(client) not between 1 and 128
     or (c#>>'{app_metadata,client_id}' is not null and c#>>'{app_metadata,client_id}' is distinct from client)
     or not business_user_tools_private.live_session_is_active_v1() then
    raise sqlstate 'PT403' using message='BUSINESS_AUTHORITY_REQUIRED';
  end if;
  h := vault_auth.current_human_principal_id();
  a := vault_auth.current_agent_principal_id();
  if h is null or a is null then raise sqlstate 'PT403' using message='BUSINESS_AUTHORITY_REQUIRED'; end if;
  return jsonb_build_object('principalId',h,'agentPrincipalId',a,'clientId',client);
end $fn$;
revoke all on function business_user_tools_private.request_actor_v1() from public, anon, authenticated;
grant execute on function business_user_tools_private.request_actor_v1() to business_user_tools_v1;

-- Narrow scalar exposure permits a restrictive policy without granting clients
-- access to any private schema or auth row. F replaces only the inner seam.
create function public.authorized_business_session_active_v1()
returns boolean language sql stable security definer set search_path=pg_catalog as $$
  select business_user_tools_private.live_session_is_active_v1()
    and vault_auth.current_human_principal_id() is not null
    and vault_auth.current_agent_principal_id() is not null $$;
revoke all on function public.authorized_business_session_active_v1() from public,anon,authenticated;
grant execute on function public.authorized_business_session_active_v1() to authenticated;
-- This intentionally narrows the existing direct Data API SELECT path as well:
-- current scope/visibility policies remain, AND a qualified live mapped-client
-- session is required. Native clients need qualified business-client mappings.
create policy business_session_memories_read on public.memories as restrictive for select to authenticated
  using(public.authorized_business_session_active_v1());
create policy business_session_wiki_read on public.wiki_pages as restrictive for select to authenticated
  using(public.authorized_business_session_active_v1());

-- These predicates do not widen the authenticated policy. New role receives
-- only the columns used by these RPCs, SELECT only, with actual RLS filtering.
grant select(id,content,workstream,tags,source_kind,source_ref,status,provenance_basis,citation,created_at,updated_at,owner,visibility)
  on public.memories to business_user_tools_v1;
grant select(id,title,content,workstream,tags,source_kind,source_ref,status,provenance_basis,citation,created_at,updated_at,owner,visibility)
  on public.wiki_pages to business_user_tools_v1;
create policy business_tools_memories_read on public.memories for select to business_user_tools_v1
  using(status='current' and public.can_read_row_as_request(owner,visibility,workstream));
create policy business_tools_wiki_read on public.wiki_pages for select to business_user_tools_v1
  using(status='current' and public.can_read_row_as_request(owner,visibility,workstream));

create view business_user_tools_private.current_records_v1 with(security_invoker=true) as
  select m.id,'memories'::text as relation,left(split_part(m.content,E'\n',1),256) as title,
    m.content,case when btrim(m.workstream)='' then null else m.workstream end as workstream,
    array_remove(m.tags,null::text) as tags,m.provenance_basis::text as basis,m.citation,
    m.source_kind::text as source_kind,m.source_ref,m.created_at,m.updated_at
  from public.memories m where m.status='current'
  union all
  select w.id,'wiki_pages',left(coalesce(nullif(w.title,''),split_part(w.content,E'\n',1)),256),
    w.content,case when btrim(w.workstream)='' then null else w.workstream end,
    array_remove(w.tags,null::text),w.provenance_basis::text,w.citation,
    w.source_kind::text,w.source_ref,w.created_at,w.updated_at
  from public.wiki_pages w where w.status='current';
revoke all on business_user_tools_private.current_records_v1 from public,anon,authenticated;
grant select on business_user_tools_private.current_records_v1 to business_user_tools_v1;

create table business_user_tools_private.submissions_v1(
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  principal_id uuid not null references public.principals(id),
  agent_principal_id uuid not null references public.principals(id),
  client_id text not null check(length(client_id) between 1 and 128),
  idempotency_key text not null check(idempotency_key ~ '^[A-Za-z0-9_-]{8,128}$'),
  kind text not null check(kind in ('observation','change_proposal')),
  workstream text not null check(length(workstream) between 1 and 128 and btrim(workstream)<>'' and workstream=btrim(workstream)),
  visibility public.visibility_level not null,
  target_id uuid,
  expected_content_hash text,
  content text not null check(length(btrim(content))>0 and length(content)<=8192),
  reason text,
  citation text not null check(length(btrim(citation))>0 and length(citation)<=2048),
  source_ref text check(length(source_ref)<=1024),
  payload_hash text not null check(payload_hash ~ '^[0-9a-f]{64}$'),
  receipt jsonb not null,
  status text not null default 'proposed' check(status='proposed'),
  created_at timestamptz not null default now(),
  unique(principal_id,client_id,idempotency_key),
  check((kind='observation' and target_id is null and expected_content_hash is null and reason is null)
     or (kind='change_proposal' and target_id is not null and expected_content_hash is not null
         and expected_content_hash ~ '^[0-9a-f]{64}$' and reason is not null
         and length(btrim(reason))>0 and length(reason)<=2048))
);
alter table business_user_tools_private.submissions_v1 enable row level security;
alter table business_user_tools_private.submissions_v1 force row level security;
revoke all on business_user_tools_private.submissions_v1 from public,anon,authenticated;
grant select,insert on business_user_tools_private.submissions_v1 to business_user_tools_v1;
create policy submission_read on business_user_tools_private.submissions_v1 for select to business_user_tools_v1 using(
  principal_id=(business_user_tools_private.request_actor_v1()->>'principalId')::uuid
  and agent_principal_id=(business_user_tools_private.request_actor_v1()->>'agentPrincipalId')::uuid
  and client_id=business_user_tools_private.request_actor_v1()->>'clientId'
  and public.request_has_capability(public.row_scope(workstream),'read')
  and public.request_has_capability(public.row_scope(workstream),'propose')
  and (target_id is null or exists(select 1 from public.memories m where m.id=target_id))
);
create policy submission_insert on business_user_tools_private.submissions_v1 for insert to business_user_tools_v1 with check(
  principal_id=(business_user_tools_private.request_actor_v1()->>'principalId')::uuid
  and agent_principal_id=(business_user_tools_private.request_actor_v1()->>'agentPrincipalId')::uuid
  and client_id=business_user_tools_private.request_actor_v1()->>'clientId'
  and public.request_has_capability(public.row_scope(workstream),'read')
  and public.request_has_capability(public.row_scope(workstream),'propose')
  and (target_id is null or exists(select 1 from public.memories m where m.id=target_id
    and public.row_scope(m.workstream)=public.row_scope(submissions_v1.workstream)))
);
create function business_user_tools_private.forbid_submission_mutation_v1()
returns trigger language plpgsql security invoker set search_path=pg_catalog as $$
begin raise sqlstate '42501' using message='BUSINESS_SUBMISSION_IMMUTABLE'; end $$;
revoke all on function business_user_tools_private.forbid_submission_mutation_v1() from public,anon,authenticated;
create trigger immutable_submission before update or delete on business_user_tools_private.submissions_v1
  for each row execute function business_user_tools_private.forbid_submission_mutation_v1();

-- Sole elevated canonical operation: an authorized exact-row SHARE lock, never
-- a read result or mutation. A concurrent canonical UPDATE/DELETE waits until
-- digest verification + sidecar INSERT commit. Runtime gains no UPDATE grant.
create function business_user_tools_private.lock_current_memory_v1(p_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog set lock_timeout='1500ms' as $fn$
begin
  perform business_user_tools_private.request_actor_v1();
  perform 1 from public.memories m where m.id=p_id and m.status='current'
    and public.can_read_row_as_request(m.owner,m.visibility,m.workstream)
    and public.request_has_capability(public.row_scope(m.workstream),'propose') for share;
  if not found then raise sqlstate 'PT404' using message='BUSINESS_TARGET_UNAVAILABLE'; end if;
exception when lock_not_available then raise sqlstate 'PT429' using message='BUSINESS_PROVIDER_BUSY';
end $fn$;
revoke all on function business_user_tools_private.lock_current_memory_v1(uuid) from public,anon,authenticated;
grant execute on function business_user_tools_private.lock_current_memory_v1(uuid) to business_user_tools_v1;

create function business_user_tools_private.validate_input_v1(p_input jsonb,p_keys text[])
returns void language plpgsql immutable security invoker set search_path=pg_catalog as $$
begin
  if p_input is null or jsonb_typeof(p_input)<>'object' or octet_length(p_input::text)>60000
     or exists(select 1 from jsonb_object_keys(p_input) k where not k=any(p_keys)) then
    raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST';
  end if;
end $$;
-- JSON/JavaScript limits count UTF-16 units. Match those limits for non-BMP
-- text as well; prefix processing inspects at most the bounded character cap.
create function business_user_tools_private.utf16_length_v1(p_text text)
returns integer language sql immutable strict security invoker set search_path=pg_catalog as $$
  select length(p_text)+(select count(*)::integer from regexp_split_to_table(p_text,'') c where c<>'' and ascii(c)>65535) $$;
create function business_user_tools_private.utf16_prefix_v1(p_text text,p_max integer)
returns text language sql immutable strict security invoker set search_path=pg_catalog as $$
  select coalesce(string_agg(c,'' order by ordinal),'') from (
    select c,ordinal,sum(case when ascii(c)>65535 then 2 else 1 end) over(order by ordinal) as units
    from regexp_split_to_table(left(p_text,p_max),'') with ordinality as chars(c,ordinal)
  ) bounded where units<=p_max $$;
create function business_user_tools_private.render_record_v1(p_row jsonb,p_budget integer)
returns jsonb language plpgsql immutable security invoker set search_path=pg_catalog as $fn$
declare v_content text := p_row->>'content'; snippet text;
begin
  if business_user_tools_private.utf16_length_v1(p_row->>'workstream')>128
     or business_user_tools_private.utf16_length_v1(p_row->>'citation')>2048
     or business_user_tools_private.utf16_length_v1(p_row->>'source_ref')>1024 or jsonb_array_length(p_row->'tags')>20
     or exists(select 1 from jsonb_array_elements_text(p_row->'tags') t where business_user_tools_private.utf16_length_v1(t)>64 or btrim(t)='') then
    raise sqlstate 'PT413' using message='BUSINESS_RECORD_CAPACITY';
  end if;
  snippet:=business_user_tools_private.utf16_prefix_v1(v_content,p_budget);
  return jsonb_build_object('id',p_row->>'id','relation',p_row->>'relation',
    'version',encode(sha256(convert_to(v_content,'UTF8')),'hex'),'status','current',
    'title',business_user_tools_private.utf16_prefix_v1(p_row->>'title',256),'content',snippet,'contentTruncated',v_content<>snippet,
    'workstream',p_row->'workstream','tags',p_row->'tags',
    'provenance',jsonb_build_object('basis',p_row->'basis','citation',p_row->'citation',
      'sourceKind',p_row->>'source_kind','sourceRef',p_row->'source_ref'),
    'createdAt',p_row->'created_at','updatedAt',p_row->'updated_at');
end $fn$;
revoke all on function business_user_tools_private.validate_input_v1(jsonb,text[]),
  business_user_tools_private.utf16_length_v1(text),business_user_tools_private.utf16_prefix_v1(text,integer),
  business_user_tools_private.render_record_v1(jsonb,integer) from public,anon,authenticated;
grant execute on function business_user_tools_private.validate_input_v1(jsonb,text[]),
  business_user_tools_private.utf16_length_v1(text),business_user_tools_private.utf16_prefix_v1(text,integer),
  business_user_tools_private.render_record_v1(jsonb,integer) to business_user_tools_v1;

create function public.authorized_business_memory_search_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $fn$
declare q text; terms tsquery; lim integer; budget integer; remaining integer; item record;
  records jsonb:='[]'; rendered jsonb; more boolean:=false; truncated boolean:=false; output jsonb;
begin
  perform business_user_tools_private.request_actor_v1();
  perform business_user_tools_private.validate_input_v1(p_input,array['query','limit','budgetChars']);
  if jsonb_typeof(p_input->'query') is distinct from 'string'
     or btrim(p_input->>'query')='' or business_user_tools_private.utf16_length_v1(p_input->>'query')>1024
     or (p_input?'limit' and (jsonb_typeof(p_input->'limit')<>'number' or (p_input->>'limit')!~'^[0-9]+$'))
     or (p_input?'budgetChars' and (jsonb_typeof(p_input->'budgetChars')<>'number' or (p_input->>'budgetChars')!~'^[0-9]+$')) then
    raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST';
  end if;
  q:=btrim(p_input->>'query'); lim:=coalesce((p_input->>'limit')::integer,10);
  budget:=coalesce((p_input->>'budgetChars')::integer,8000); remaining:=budget;
  if lim not between 1 and 20 or budget not between 256 and 16000 then
    raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST'; end if;
  terms:=plainto_tsquery('english',q);
  -- Ordinary questions lose English stop words. Only when that exact AND has
  -- no authorized hits, try a deterministic OR of the same normalized tokens.
  -- This decision also consumes RLS: an inaccessible hit cannot suppress the
  -- fallback, affect ranking or influence a visible result count.
  if not exists(select 1 from business_user_tools_private.current_records_v1 r
    where to_tsvector('english',coalesce(r.title,'')||' '||array_to_string(r.tags,' ')||' '||r.content) @@ terms) then
    select coalesce(string_agg(quote_literal(t),' | '),'')::tsquery into terms
      from unnest(tsvector_to_array(to_tsvector('english',q))) t;
  end if;
  for item in
    select r.*,ts_rank_cd(setweight(to_tsvector('english',coalesce(r.title,'')),'A')
      ||setweight(to_tsvector('english',array_to_string(r.tags,' ')),'B')
      ||to_tsvector('english',r.content),terms,32) as rank
    from business_user_tools_private.current_records_v1 r
    where to_tsvector('english',coalesce(r.title,'')||' '||array_to_string(r.tags,' ')||' '||r.content) @@ terms
    order by rank desc,r.updated_at desc,r.relation,r.id limit lim+1
  loop
    if jsonb_array_length(records)>=lim or remaining<=0 then more:=true; exit; end if;
    rendered:=business_user_tools_private.render_record_v1(to_jsonb(item),remaining);
    remaining:=remaining-business_user_tools_private.utf16_length_v1(rendered->>'content');
    truncated:=truncated or (rendered->>'contentTruncated')::boolean;
    records:=records||jsonb_build_array(rendered);
  end loop;
  output:=jsonb_build_object('schemaVersion',1,'requestId',gen_random_uuid(),'records',records,
    'completeness',jsonb_build_object('status',case when more or truncated then 'partial' else 'complete' end,
      'coverage','authorized_current_canonical','returned',jsonb_array_length(records),'hasMore',more,
      'contentTruncated',truncated,'budgetChars',budget));
  if octet_length(output::text)>60000 then raise sqlstate 'PT413' using message='BUSINESS_RESULT_CAPACITY'; end if;
  return output;
exception when numeric_value_out_of_range or invalid_text_representation then
  raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST';
end $fn$;

create function public.authorized_business_memory_get_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $fn$
declare v_id uuid; v_relation text; budget integer; row_json jsonb; rendered jsonb; output jsonb;
begin
  perform business_user_tools_private.request_actor_v1();
  perform business_user_tools_private.validate_input_v1(p_input,array['memoryId','relation','budgetChars']);
  if jsonb_typeof(p_input->'memoryId') is distinct from 'string' or (p_input->>'memoryId')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or (p_input?'relation' and (jsonb_typeof(p_input->'relation')<>'string' or p_input->>'relation' not in ('memories','wiki_pages')))
     or (p_input?'budgetChars' and (jsonb_typeof(p_input->'budgetChars')<>'number' or (p_input->>'budgetChars')!~'^[0-9]+$')) then
    raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST'; end if;
  v_id:=(p_input->>'memoryId')::uuid; v_relation:=coalesce(p_input->>'relation','memories');
  budget:=coalesce((p_input->>'budgetChars')::integer,8000);
  if budget not between 256 and 16000 then raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST'; end if;
  select to_jsonb(r) into row_json from business_user_tools_private.current_records_v1 r where r.id=v_id and r.relation=v_relation;
  if row_json is not null then rendered:=business_user_tools_private.render_record_v1(row_json,budget); end if;
  output:=jsonb_build_object('schemaVersion',1,'requestId',gen_random_uuid(),'record',rendered,
    'completeness',jsonb_build_object('status',case when coalesce((rendered->>'contentTruncated')::boolean,false) then 'partial' else 'complete' end,
      'coverage','authorized_current_canonical','returned',case when rendered is null then 0 else 1 end,
      'hasMore',false,'contentTruncated',coalesce((rendered->>'contentTruncated')::boolean,false),'budgetChars',budget));
  if octet_length(output::text)>60000 then raise sqlstate 'PT413' using message='BUSINESS_RESULT_CAPACITY'; end if;
  return output;
exception when numeric_value_out_of_range or invalid_text_representation then
  raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST';
end $fn$;

create function business_user_tools_private.submit_v1(p_input jsonb,p_kind text)
returns jsonb language plpgsql security invoker set search_path=pg_catalog as $fn$
declare actor jsonb; key text; hash text; existing business_user_tools_private.submissions_v1%rowtype;
  row_id uuid:=gen_random_uuid(); request_id uuid:=gen_random_uuid(); created timestamptz:=now();
  target record; content text; stream text; visibility public.visibility_level;
  receipt jsonb; target_id uuid;
begin
  actor:=business_user_tools_private.request_actor_v1();
  if p_kind='observation' then
    perform business_user_tools_private.validate_input_v1(p_input,array['idempotencyKey','content','workstream','citation','sourceRef','visibility']);
    content:=p_input->>'content';
    if jsonb_typeof(p_input->'content') is distinct from 'string'
       or jsonb_typeof(p_input->'workstream') is distinct from 'string' or (p_input->>'workstream')!~'^[a-z0-9][a-z0-9_./-]{0,127}$'
       or jsonb_typeof(p_input->'visibility') is distinct from 'string' or (p_input->>'visibility') not in ('private','shared') then
      raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST'; end if;
    stream:=p_input->>'workstream'; visibility:=(p_input->>'visibility')::public.visibility_level;
  elsif p_kind='change_proposal' then
    perform business_user_tools_private.validate_input_v1(p_input,array['idempotencyKey','memoryId','expectedContentHash','proposedContent','reason','citation','sourceRef']);
    content:=p_input->>'proposedContent';
    if jsonb_typeof(p_input->'proposedContent') is distinct from 'string'
       or jsonb_typeof(p_input->'memoryId') is distinct from 'string' or (p_input->>'memoryId')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
       or jsonb_typeof(p_input->'expectedContentHash') is distinct from 'string' or (p_input->>'expectedContentHash')!~'^[0-9a-f]{64}$'
       or jsonb_typeof(p_input->'reason') is distinct from 'string' or btrim(p_input->>'reason')=''
       or business_user_tools_private.utf16_length_v1(p_input->>'reason')>2048 then
      raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST'; end if;
    target_id:=(p_input->>'memoryId')::uuid;
    perform business_user_tools_private.lock_current_memory_v1(target_id);
    select m.content,m.workstream,m.visibility into target from public.memories m where m.id=target_id;
    if not found then raise sqlstate 'PT404' using message='BUSINESS_TARGET_UNAVAILABLE'; end if;
    -- Inherited canonical text follows the existing scope helper, never the
    -- observation input grammar. No client supplies a proposal workstream.
    stream:=substring(public.row_scope(target.workstream) from 12); visibility:=target.visibility;
    if stream is null or btrim(stream)='' then
      raise sqlstate 'PT403' using message='BUSINESS_SCOPE_UNAVAILABLE'; end if;
    if business_user_tools_private.utf16_length_v1(stream)>128 then
      raise sqlstate 'PT413' using message='BUSINESS_RECORD_CAPACITY'; end if;
  else raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST'; end if;
  key:=p_input->>'idempotencyKey';
  if jsonb_typeof(p_input->'idempotencyKey') is distinct from 'string' or key!~'^[A-Za-z0-9_-]{8,128}$'
     or btrim(content)='' or business_user_tools_private.utf16_length_v1(content)>8192
     or jsonb_typeof(p_input->'citation') is distinct from 'string' or btrim(p_input->>'citation')=''
     or business_user_tools_private.utf16_length_v1(p_input->>'citation')>2048
     or (p_input?'sourceRef' and (jsonb_typeof(p_input->'sourceRef')<>'string' or business_user_tools_private.utf16_length_v1(p_input->>'sourceRef')>1024)) then
    raise sqlstate '22023' using message='BUSINESS_INVALID_REQUEST'; end if;
  if not public.request_has_capability(public.row_scope(stream),'read')
     or not public.request_has_capability(public.row_scope(stream),'propose') then
    raise sqlstate 'PT403' using message='BUSINESS_AUTHORITY_REQUIRED'; end if;
  hash:=encode(sha256(convert_to(jsonb_build_object('kind',p_kind,'input',p_input)::text,'UTF8')),'hex');
  -- Same principal/client/key serializes atomically. Hash collisions only
  -- serialize unrelated requests and cannot expand access or overwrite rows.
  if not pg_try_advisory_xact_lock(hashtextextended((actor->>'principalId')||':'||(actor->>'clientId')||':'||key,0)) then
    raise sqlstate 'PT429' using message='BUSINESS_PROVIDER_BUSY'; end if;
  select s.* into existing from business_user_tools_private.submissions_v1 s
    where s.principal_id=(actor->>'principalId')::uuid and s.client_id=actor->>'clientId' and s.idempotency_key=key;
  if found then
    if existing.payload_hash<>hash then raise sqlstate 'PT412' using message='BUSINESS_IDEMPOTENCY_CONFLICT'; end if;
    return existing.receipt||jsonb_build_object('replayed',true);
  end if;
  if p_kind='change_proposal' then
    -- The private authorized SHARE lock now holds the target through commit.
    -- This is a staged request against the visible snapshot, never an apply.
    -- A future human-reviewed apply MUST recheck the saved expected digest.
    -- Runtime has no canonical UPDATE privilege.
    if encode(sha256(convert_to(target.content,'UTF8')),'hex')<>p_input->>'expectedContentHash' then
      raise sqlstate 'PT409' using message='BUSINESS_STALE_TARGET'; end if;
    if target.content=content then raise sqlstate 'PT422' using message='BUSINESS_NO_OP'; end if;
  end if;
  receipt:=jsonb_build_object('schemaVersion',1,'requestId',request_id,'status','proposed','createdAt',created,'replayed',false)
    || case when p_kind='observation' then jsonb_build_object('observationId',row_id)
       else jsonb_build_object('proposalId',row_id,'targetId',target_id,'expectedContentHash',p_input->>'expectedContentHash') end;
  insert into business_user_tools_private.submissions_v1(id,request_id,principal_id,agent_principal_id,client_id,idempotency_key,
    kind,workstream,visibility,target_id,expected_content_hash,content,reason,citation,source_ref,payload_hash,receipt,created_at)
  values(row_id,request_id,(actor->>'principalId')::uuid,(actor->>'agentPrincipalId')::uuid,actor->>'clientId',key,
    p_kind,stream,visibility,target_id,p_input->>'expectedContentHash',content,p_input->>'reason',p_input->>'citation',p_input->>'sourceRef',hash,receipt,created);
  return receipt;
end $fn$;
revoke all on function business_user_tools_private.submit_v1(jsonb,text) from public,anon,authenticated;
grant execute on function business_user_tools_private.submit_v1(jsonb,text) to business_user_tools_v1;
create function public.authorized_business_memory_append_observation_v1(p_input jsonb)
returns jsonb language sql security definer set search_path=pg_catalog as $$
  select business_user_tools_private.submit_v1(p_input,'observation') $$;
create function public.authorized_business_memory_propose_change_v1(p_input jsonb)
returns jsonb language sql security definer set search_path=pg_catalog as $$
  select business_user_tools_private.submit_v1(p_input,'change_proposal') $$;

alter function public.authorized_business_memory_search_v1(jsonb) owner to business_user_tools_v1;
alter function public.authorized_business_memory_get_v1(jsonb) owner to business_user_tools_v1;
alter function public.authorized_business_memory_append_observation_v1(jsonb) owner to business_user_tools_v1;
alter function public.authorized_business_memory_propose_change_v1(jsonb) owner to business_user_tools_v1;
revoke all on function public.authorized_business_memory_search_v1(jsonb),public.authorized_business_memory_get_v1(jsonb),
  public.authorized_business_memory_append_observation_v1(jsonb),public.authorized_business_memory_propose_change_v1(jsonb)
  from public,anon,authenticated;
grant execute on function public.authorized_business_memory_search_v1(jsonb),public.authorized_business_memory_get_v1(jsonb),
  public.authorized_business_memory_append_observation_v1(jsonb),public.authorized_business_memory_propose_change_v1(jsonb)
  to authenticated;
revoke create on schema public from business_user_tools_v1;
do $$ begin
  if has_schema_privilege('business_user_tools_v1','public','CREATE') then
    raise exception 'business runtime inherits public CREATE; review schema perimeter before applying';
  end if;
end $$;
insert into public.perimeter_exception(object_kind,object_identity,grantee,reason)
select 'function',n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',
  'authenticated',case when p.proname='authorized_business_session_active_v1'
    then 'Reviewed no-argument scalar session gate for restrictive authenticated canonical SELECT policies. Returns only a boolean; private identity/session rows remain inaccessible.'
    else 'Reviewed fixed business RPC. Owner is a non-login, nonowner, non-bypass role; current canonical reads consume RLS, writes append immutable actor/client-scoped sidecar submissions only. Trusted mapped human and OAuth client plus active live session required.' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where p.oid in ('public.authorized_business_session_active_v1()'::regprocedure,
  'public.authorized_business_memory_search_v1(jsonb)'::regprocedure,
  'public.authorized_business_memory_get_v1(jsonb)'::regprocedure,
  'public.authorized_business_memory_append_observation_v1(jsonb)'::regprocedure,
  'public.authorized_business_memory_propose_change_v1(jsonb)'::regprocedure);
revoke business_user_tools_v1 from current_user;
commit;
