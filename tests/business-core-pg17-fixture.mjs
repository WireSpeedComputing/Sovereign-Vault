/**
 * Whole-source neutral-core PostgreSQL 17 acceptance generator.
 * Copies every ordered manifest SQL file byte-for-byte; extracts no functions,
 * substitutes no canonical tables, and seeds no deployment data. The separate
 * synthetic auth seam qualifies F for testing, not a production OAuth bootstrap.
 */
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, join, relative, sep, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
if (!process.argv[2]) throw Error('Supply an explicit empty temporary output directory.');
const output = resolve(process.argv[2]);
const relativeOutput = relative(root, output);
if (!relativeOutput || (!isAbsolute(relativeOutput) && relativeOutput !== '..' && !relativeOutput.startsWith('..' + sep))) {
  throw Error('Generated fixtures must remain outside the source checkout.');
}
await mkdir(output, { recursive: true });
if ((await readdir(output)).length) throw Error('Refusing to overwrite a nonempty output directory.');
const digest = value => createHash('sha256').update(value).digest('hex');
const literal = value => "'" + String(value).replaceAll("'", "''") + "'";
const manifest = await readFile(join(root, 'profiles/business-core.manifest'));
const paths = manifest.toString('utf8').split(/\r?\n/).map(line => line.split('#')[0].trim()).filter(Boolean);
if (paths.length < 15 || paths.length > 64 || new Set(paths).size !== paths.length
  || paths.some(path => !/^sql\/\d{2}_[a-z0-9_]+\.sql$/.test(path))
  || paths[0] !== 'sql/00_extensions.sql') throw Error('Invalid ordered whole-core manifest.');
const candidates = ['pending/E_business_user_tools.sql', 'pending/F_business_live_session.sql'];
const sources = [];
for (const path of [...paths, ...candidates]) {
  const content = await readFile(join(root, path));
  const destination = join(output, 'source', path);
  await mkdir(resolve(destination, '..'), { recursive: true });
  await writeFile(destination, content);
  sources.push({ path, sha256: digest(content) });
}
await writeFile(join(output, 'core-source-hashes.json'), JSON.stringify({
  manifestSha256: digest(manifest), wholeCoreFiles: paths.length, sources,
}, null, 2) + '\n');
const write = (name, sql) => writeFile(join(output, name), sql + '\n', 'utf8');
await write('core-bootstrap.sql', paths.map(path => '\\echo APPLY_WHOLE_FILE ' + path + '\n\\ir source/' + path).join('\n'));

const baseTables = ['memories', 'wiki_pages', 'memory_hot_index', 'memory_hot_staging', 'doc_integrity',
  'schema_changelog', 'principals', 'capability_grants', 'capability_grant_audit', 'provenance_registry',
  'source_freeze', 'import_batches', 'raw_artifacts', 'review_queue', 'retrieval_units', 'retrieval_embeddings',
  'promoted_record_audit', 'perimeter_exception', 'scope_registry', 'scope_cutover', 'hard_delete_audit',
  'retrieval_topology', 'record_authorization_audit'].sort();
await write('core-base-check.sql', `
do $check$
declare report record; names text[]; n integer;
begin
  if current_setting('server_version_num')::integer not between 170000 and 179999 then raise exception 'PostgreSQL 17 required'; end if;
  if (select count(*) from pg_extension where extname in ('vector','pgcrypto'))<>2 then raise exception 'Real extensions missing'; end if;
  if encode(public.digest('synthetic-core','sha256'),'hex')<> ${literal(digest('synthetic-core'))} then raise exception 'Real pgcrypto digest failed'; end if;
  if abs(('[1,0,0]'::public.vector <=> '[1,0,0]'::public.vector))>0.000001 then raise exception 'Real vector operator failed'; end if;
  if (select count(*) from pg_attribute where attrelid in ('public.memories'::regclass,'public.wiki_pages'::regclass)
    and attname='embedding' and format_type(atttypid,atttypmod)='vector(384)')<>2 then raise exception 'Canonical vector columns differ'; end if;
  select array_agg(c.relname::text order by c.relname) into names from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('r','p') and not exists(select 1 from pg_depend d where d.objid=c.oid and d.deptype='e');
  if names is distinct from ${literal('{' + baseTables.join(',') + '}')}::text[] then raise exception 'Whole-core relation inventory differs: %',names; end if;
  if exists(select 1 from public.principals) or exists(select 1 from public.capability_grants)
    or exists(select 1 from vault_auth.principal_identity_bindings) then raise exception 'Base profile unexpectedly seeded identities or grants'; end if;
  if exists(select 1 from public.memories) or exists(select 1 from public.wiki_pages) then raise exception 'Base profile unexpectedly seeded canonical records'; end if;
  if to_regnamespace('auth') is not null or to_regnamespace('business_user_tools_private') is not null then raise exception 'Optional test seams present in base profile'; end if;
  select count(*) into n from public.perimeter_report();
  if n<>1 then raise exception 'Perimeter report must return exactly one evaluated result'; end if;
  select * into report from public.perimeter_report();
  if report.evaluation_status is distinct from 'evaluated' or report.violation_count is distinct from 0
    or coalesce(cardinality(report.roles_missing),-1)<>0 or coalesce(report.objects_examined,0)<=0
    or report.violations is distinct from '[]'::jsonb then
    raise exception 'Whole-core perimeter is not evaluated clean: %',to_jsonb(report);
  end if;
end $check$;
select version();
select extname,extversion from pg_extension where extname in ('vector','pgcrypto') order by extname;
select to_jsonb(r) as whole_core_perimeter from public.perimeter_report() r;
\\echo CORE_BASE_ACCEPTANCE_PASS
`);

const f = {
  issuer: 'https://synthetic.invalid/auth/v1',
  user: '10000000-0000-4000-8000-000000000001',
  session: '20000000-0000-4000-8000-000000000001',
  human: '30000000-0000-4000-8000-000000000001',
  otherHuman: '30000000-0000-4000-8000-000000000002',
  client: '40000000-0000-4000-8000-000000000001',
  agent: '50000000-0000-4000-8000-000000000001',
  current: '60000000-0000-4000-8000-000000000001',
  private: '60000000-0000-4000-8000-000000000002',
  outside: '60000000-0000-4000-8000-000000000003',
  proposed: '60000000-0000-4000-8000-000000000004',
  wiki: '70000000-0000-4000-8000-000000000001',
  content: 'Business address\nSynthetic office reference at 100 Example Avenue.',
};
const claims = { iss: f.issuer, sub: f.user, role: 'authenticated', client_id: f.client, session_id: f.session,
  is_anonymous: false, exp: Math.floor(Date.now() / 1000) + 3600 };
const auth = `set session authorization authenticator;
begin; set local role authenticated;
select set_config('request.jwt.claims',${literal(JSON.stringify(claims))},true);
`;
const get = { memoryId: f.current };
const append = { idempotencyKey: 'synthetic_core_observation', content: 'Synthetic evidence pending human review.',
  workstream: 'operations', citation: 'synthetic:source-v1', visibility: 'private' };
const proposal = { idempotencyKey: 'synthetic_core_proposal', memoryId: f.current, expectedContentHash: digest(f.content),
  proposedContent: 'Synthetic corrected office reference.', reason: 'Synthetic correction control.', citation: 'synthetic:source-v2' };

await write('core-test-seam.sql', `
-- Synthetic-only platform seam, separate from the exact whole-core bootstrap.
create role authenticator nologin nosuperuser nocreatedb nocreaterole noinherit nobypassrls;
grant authenticated to authenticator with inherit false, set true;
create schema auth;
revoke all on schema auth from public,anon,authenticated,service_role;
create table auth.sessions(id uuid primary key,user_id uuid not null,oauth_client_id uuid,not_after timestamptz);
alter table auth.sessions enable row level security;
alter table auth.sessions force row level security;
revoke all on auth.sessions from public,anon,authenticated,service_role;
create function auth.uid() returns uuid language sql stable set search_path=pg_catalog as $uid$
  select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid
$uid$;
revoke all on function auth.uid() from public,anon,authenticated,service_role;
insert into public.principals(id,kind,display_name) values
  (${literal(f.human)},'human','Synthetic operator A'),(${literal(f.otherHuman)},'human','Synthetic operator B'),
  (${literal(f.agent)},'agent','Synthetic client A');
insert into public.scope_registry(scope,kind,identifier,description,declared_by) values
  ('workstream:operations','workstream','operations','Synthetic acceptance scope',${literal(f.human)});
insert into public.capability_grants(principal_id,resource_scope,permissions,granted_by,reason) values
  (${literal(f.human)},'workstream:operations','{read,propose}',${literal(f.human)},'Synthetic acceptance'),
  (${literal(f.agent)},'workstream:operations','{read,propose}',${literal(f.human)},'Synthetic acceptance');
insert into vault_auth.principal_identity_bindings(identity_kind,issuer,identity_value,principal_id,binding_status,review_status,
  created_by,reviewed_by,reviewed_at,reason,citation,provenance_basis,workstream,source_agent) values
  ('auth_subject',${literal(f.issuer)},${literal(f.user)},${literal(f.human)},'active','approved',
    ${literal(f.human)},${literal(f.human)},now(),'Synthetic mapping','synthetic:identity','decision_record','operations','synthetic'),
  ('oauth_client',${literal(f.issuer)},${literal(f.client)},${literal(f.agent)},'active','approved',
    ${literal(f.human)},${literal(f.human)},now(),'Synthetic mapping','synthetic:identity','decision_record','operations','synthetic');
insert into auth.sessions(id,user_id,oauth_client_id) values(${literal(f.session)},${literal(f.user)},${literal(f.client)});
insert into public.memories(id,content,workstream,status,owner,visibility,provenance_basis,citation,tags) values
  (${literal(f.current)},${literal(f.content)},'operations','proposed',${literal(f.human)},'shared','source_document','synthetic:record','{address,NULL,office}'),
  (${literal(f.private)},'Business address private synthetic reference','operations','proposed',${literal(f.otherHuman)},'private','source_document','synthetic:record','{}'),
  (${literal(f.outside)},'Business address outside synthetic scope','finance','proposed',${literal(f.human)},'shared','source_document','synthetic:record','{}'),
  (${literal(f.proposed)},'Business address proposed synthetic reference','operations','proposed',${literal(f.human)},'shared','source_document','synthetic:record','{}');
select public.promote_memory(${literal(f.current)},${literal(f.human)});
select public.promote_memory(${literal(f.private)},${literal(f.human)});
select public.promote_memory(${literal(f.outside)},${literal(f.human)});
insert into public.wiki_pages(id,path,title,content,workstream,status,owner,visibility,provenance_basis,citation) values
  (${literal(f.wiki)},'/synthetic/office','Synthetic office reference','Office location synthetic reference','operations','current',
    ${literal(f.human)},'shared','source_document','synthetic:wiki');
-- Test-only broad policies must not widen the finite E role or authenticated rows.
create policy synthetic_core_public_read on public.memories for select to public using(true);
create policy synthetic_core_public_read on public.wiki_pages for select to public using(true);
create temporary table synthetic_canonical_before as select
  (select jsonb_agg(to_jsonb(m) order by id) from public.memories m) as memories,
  (select jsonb_agg(to_jsonb(w) order by id) from public.wiki_pages w) as wiki_pages;
`);

await write('core-before-session-gate.sql', auth + `
do $check$ declare denied boolean:=false; n integer;
begin
  begin perform public.authorized_business_memory_get_v1(${literal(JSON.stringify(get))}::jsonb);
  exception when sqlstate 'PT403' then denied:=true; end;
  if not denied then raise exception 'E must deny tool access before F'; end if;
  select count(*) into n from public.memories;
  if n<>0 then raise exception 'E must deny direct canonical access before F'; end if;
end $check$;
commit; reset session authorization;
\\echo CORE_E_BEFORE_F_DENIAL_PASS
`);

await write('core-user-acceptance.sql', auth + `
do $check$
declare result jsonb; first jsonb; replay jsonb; staged jsonb; n integer; denied boolean;
begin
  if session_user<>'authenticator' or current_user<>'authenticated' then raise exception 'Actual authenticated custody missing'; end if;
  result:=public.authorized_business_memory_get_v1(${literal(JSON.stringify(get))}::jsonb);
  if result#>>'{record,id}' is distinct from ${literal(f.current)}
    or result#>>'{record,content}' is distinct from ${literal(f.content)}
    or result#>>'{record,version}' is distinct from ${literal(digest(f.content))}
    or result#>'{record,tags}' is distinct from '["address","office"]'::jsonb then raise exception 'Whole-source exact get failed'; end if;
  result:=public.authorized_business_memory_search_v1('{"query":"What is our business address?"}'::jsonb);
  if jsonb_array_length(result->'records')<>1 or result#>>'{records,0,id}' is distinct from ${literal(f.current)} then raise exception 'Whole-source scoped search failed'; end if;
  result:=public.authorized_business_memory_get_v1(jsonb_build_object('memoryId',${literal(f.wiki)},'relation','wiki_pages'));
  if result#>>'{record,id}' is distinct from ${literal(f.wiki)} then raise exception 'Whole-source exact wiki get failed'; end if;
  foreach result in array array[
    public.authorized_business_memory_get_v1(jsonb_build_object('memoryId',${literal(f.private)})),
    public.authorized_business_memory_get_v1(jsonb_build_object('memoryId',${literal(f.outside)})),
    public.authorized_business_memory_get_v1(jsonb_build_object('memoryId',${literal(f.proposed)}))]
  loop if result->'record' is distinct from 'null'::jsonb then raise exception 'Whole-source hidden get widened'; end if; end loop;
  select count(*) into n from public.memories;
  if n<>1 then raise exception 'Whole-source direct memory read widened'; end if;
  select count(*) into n from public.wiki_pages;
  if n<>1 then raise exception 'Whole-source direct wiki read failed'; end if;
  first:=public.authorized_business_memory_append_observation_v1(${literal(JSON.stringify(append))}::jsonb);
  replay:=public.authorized_business_memory_append_observation_v1(${literal(JSON.stringify(append))}::jsonb);
  if first->>'status' is distinct from 'proposed' or first->>'replayed' is distinct from 'false'
    or replay->>'observationId' is distinct from first->>'observationId' or replay->>'requestId' is distinct from first->>'requestId'
    or replay->>'replayed' is distinct from 'true' then raise exception 'Whole-source observation replay failed'; end if;
  denied:=false;
  begin perform public.authorized_business_memory_append_observation_v1(${literal(JSON.stringify({ ...append, content: 'Synthetic different evidence.' }))}::jsonb);
  exception when sqlstate 'PT412' then denied:=true; end;
  if not denied then raise exception 'Changed observation key must conflict'; end if;
  staged:=public.authorized_business_memory_propose_change_v1(${literal(JSON.stringify(proposal))}::jsonb);
  replay:=public.authorized_business_memory_propose_change_v1(${literal(JSON.stringify(proposal))}::jsonb);
  if staged->>'status' is distinct from 'proposed' or staged->>'targetId' is distinct from ${literal(f.current)}
    or replay->>'proposalId' is distinct from staged->>'proposalId' or replay->>'requestId' is distinct from staged->>'requestId'
    or replay->>'replayed' is distinct from 'true' then raise exception 'Whole-source proposal replay failed'; end if;
  denied:=false;
  begin perform public.authorized_business_memory_propose_change_v1(${literal(JSON.stringify({ ...proposal, reason: 'Synthetic changed payload.' }))}::jsonb);
  exception when sqlstate 'PT412' then denied:=true; end;
  if not denied then raise exception 'Changed proposal key must conflict'; end if;
  denied:=false;
  begin insert into public.memories(content,provenance_basis,citation) values('Synthetic forbidden insert','source_document','synthetic');
  exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Authenticated canonical INSERT accepted'; end if;
  denied:=false;
  begin update public.memories set content='Synthetic forbidden update' where id=${literal(f.current)};
  exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Authenticated canonical UPDATE accepted'; end if;
  denied:=false;
  begin delete from public.memories where id=${literal(f.current)};
  exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Authenticated canonical DELETE accepted'; end if;
  denied:=false;
  begin perform count(*) from vault_auth.principal_identity_bindings;
  exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Authenticated identity rows exposed'; end if;
end $check$;
commit; reset session authorization;
do $check$ declare report record; before_row record; after_memories jsonb; after_wiki jsonb;
begin
  if (select rolsuper or rolbypassrls or rolcanlogin from pg_roles where rolname='business_user_tools_v1') is distinct from false then raise exception 'Runtime role has elevated authority'; end if;
  if (select count(*) from pg_proc where proname like 'authorized_business_memory_%_v1'
    and proowner=(select oid from pg_roles where rolname='business_user_tools_v1'))<>4 then raise exception 'RPC owner binding differs'; end if;
  select * into before_row from synthetic_canonical_before;
  select jsonb_agg(to_jsonb(m) order by id) into after_memories from public.memories m;
  select jsonb_agg(to_jsonb(w) order by id) into after_wiki from public.wiki_pages w;
  if after_memories is distinct from before_row.memories or after_wiki is distinct from before_row.wiki_pages then raise exception 'Staged writes changed canonical rows'; end if;
  if (select count(*) from business_user_tools_private.submissions_v1)<>2 then raise exception 'Immutable sidecar count differs'; end if;
  select * into report from public.perimeter_report();
  if report.evaluation_status is distinct from 'evaluated' or report.violation_count is distinct from 0 then
    raise exception 'Whole-core opted-in perimeter not evaluated clean: %',to_jsonb(report);
  end if;
end $check$;
select to_jsonb(r) as opted_in_perimeter from public.perimeter_report() r;
delete from auth.sessions where id=${literal(f.session)};
` + auth + `
do $check$ declare n integer; denied boolean:=false;
begin
  select count(*) into n from public.memories;
  if n<>0 then raise exception 'Revoked session direct memory read survived'; end if;
  select count(*) into n from public.wiki_pages;
  if n<>0 then raise exception 'Revoked session direct wiki read survived'; end if;
  begin perform public.authorized_business_memory_get_v1(${literal(JSON.stringify(get))}::jsonb);
  exception when sqlstate 'PT403' then denied:=true; end;
  if not denied then raise exception 'Revoked session RPC survived'; end if;
end $check$;
commit; reset session authorization;
\\echo CORE_AUTHENTICATED_ACCEPTANCE_PASS
`);
await write('core-acceptance.sql', `\\set ON_ERROR_STOP on
\\ir core-bootstrap.sql
\\ir core-base-check.sql
\\ir source/pending/E_business_user_tools.sql
\\ir core-test-seam.sql
\\ir core-before-session-gate.sql
\\ir source/pending/F_business_live_session.sql
\\ir core-user-acceptance.sql
\\echo CORE_WHOLE_PROFILE_ACCEPTANCE_PASS`);
