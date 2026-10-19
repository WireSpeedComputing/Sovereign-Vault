-- UNAPPLIED Supabase-specific session gate for pending/E_business_user_tools.sql.
-- Contains no hosted identity/client/session seed. Returns only a boolean.
-- Requires reviewed auth.sessions SELECT for the migration controller. The
-- caller cannot select a session, actor or client argument; trusted claims bind
-- all three. No existing vault_auth helper is replaced.
-- Revoke business_user_tools_v1 EXECUTE to disable this gate without deleting
-- any canonical or staged records. E without this gate remains deny-all.
-- Also governs E's restrictive authenticated memories/wiki SELECT policies.
-- This business-client session profile narrows direct Data API reads too;
-- native callers require reviewed mappings and client-bound OAuth sessions.
begin;
do $preflight$
begin
  if to_regprocedure('business_user_tools_private.live_session_is_active_v1()') is null
     or to_regprocedure('auth.uid()') is null or to_regclass('auth.sessions') is null then
    raise exception 'business live-session gate requires E and Supabase auth schema';
  end if;
  if not exists(select 1 from pg_attribute where attrelid='auth.sessions'::regclass and attname='id' and atttypid='uuid'::regtype and not attisdropped)
     or not exists(select 1 from pg_attribute where attrelid='auth.sessions'::regclass and attname='user_id' and atttypid='uuid'::regtype and not attisdropped)
     or not exists(select 1 from pg_attribute where attrelid='auth.sessions'::regclass and attname='oauth_client_id' and atttypid='uuid'::regtype and not attisdropped)
     or not exists(select 1 from pg_attribute where attrelid='auth.sessions'::regclass and attname='not_after' and atttypid='timestamptz'::regtype and not attisdropped)
     or not has_table_privilege(current_user,'auth.sessions','SELECT') then
    raise exception 'business live-session gate requires reviewed auth.sessions shape and SELECT';
  end if;
end $preflight$;
create or replace function business_user_tools_private.live_session_is_active_v1()
returns boolean language plpgsql stable security definer set search_path=pg_catalog as $fn$
declare c jsonb; u uuid; sid uuid; client uuid;
begin
  c:=vault_auth._trusted_request_claims();
  if session_user<>'authenticator' or c is null or c->>'role' is distinct from 'authenticated'
     or c->>'is_anonymous' is distinct from 'false'
     or jsonb_typeof(c->'is_anonymous') is distinct from 'boolean'
     or (c?'app_metadata' and jsonb_typeof(c->'app_metadata') is distinct from 'object')
     or (c#>'{app_metadata,client_id}' is not null and jsonb_typeof(c#>'{app_metadata,client_id}') is distinct from 'string')
     or jsonb_typeof(c->'exp') is distinct from 'number' or (c->>'exp')!~'^[0-9]{1,12}$'
     or (c->>'exp')::numeric<=extract(epoch from now())
     or (c->>'sub') is null or (c->>'sub')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or (c->>'session_id') is null or (c->>'session_id')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or (c->>'client_id') is null or (c->>'client_id')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or (c#>>'{app_metadata,client_id}' is not null and c#>>'{app_metadata,client_id}'<>c->>'client_id') then
    return false;
  end if;
  u:=(c->>'sub')::uuid; sid:=(c->>'session_id')::uuid; client:=(c->>'client_id')::uuid;
  if auth.uid() is distinct from u then return false; end if;
  return exists(select 1 from auth.sessions s where s.id=sid and s.user_id=u
    and s.oauth_client_id=client and (s.not_after is null or s.not_after>now()));
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end $fn$;
revoke all on function business_user_tools_private.live_session_is_active_v1() from public,anon,authenticated;
grant execute on function business_user_tools_private.live_session_is_active_v1() to business_user_tools_v1;
commit;
