/**
 * Generate synthetic PostgreSQL 17 acceptance scripts from the exact candidate
 * and checked-in identity/RLS bodies. Not a complete-schema replay or hosted
 * migration. Supply an explicit temporary output directory, then run these
 * scripts only against an isolated empty cluster. No deployment seed is used.
 */
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { SYNTHETIC as f } from './64_business_user_tools.mjs';
const root=new URL('../',import.meta.url);
if (!process.argv[2]) throw Error('Supply an explicit temporary output directory.');
const outputDirectory = resolve(process.argv[2]);
await mkdir(outputDirectory, { recursive: true });
const read=p=>readFile(new URL(p,root),'utf8');
const literal=s=>"'"+String(s).replaceAll("'","''")+"'";
const extract=(s,a,b)=>{const i=s.indexOf(a),j=s.indexOf(b,i);if(i<0||j<i)throw Error('missing source boundary');return s.slice(i,j);};
const sql=[await read('tests/64_business_user_tools_fixture.sql'),await read('sql/23_identity_capability_enforcement.sql'),await read('sql/25_public_request_has_capability.sql'),await read('sql/28_perimeter_assert_signal.sql')];
const predicates=await read('sql/36_rls_policies.sql');
sql.push(extract(predicates,'create or replace function public.row_scope(','comment on function public.row_scope'));
sql.push(extract(predicates,'create or replace function public.can_read_row_as_request(','-- coalesce('));
sql.push(extract(predicates,'insert into perimeter_exception (object_kind','drop policy if exists memories_read'));
sql.push(`revoke all on function public.can_read_row_as_request(uuid,public.visibility_level,text) from public,anon;
grant execute on function public.can_read_row_as_request(uuid,public.visibility_level,text),public.row_scope(text) to authenticated;
grant select on public.memories,public.wiki_pages to authenticated;
create policy memories_read on public.memories for select to authenticated using(status='current' and public.can_read_row_as_request(owner,visibility,workstream));
create policy wiki_pages_read on public.wiki_pages for select to authenticated using(status='current' and public.can_read_row_as_request(owner,visibility,workstream));`);
sql.push(await read('pending/E_business_user_tools.sql'),await read('pending/F_business_live_session.sql'));
for(const name of ['alice','bob','clientA','clientB']) {
  const p=f[name],human=!!p.userId;
  sql.push(`insert into public.principals(id,kind,display_name) values(${literal(p.principalId)},${literal(human?'human':'agent')},${literal('Synthetic '+name)});
insert into vault_auth.principal_identity_bindings(identity_kind,issuer,identity_value,principal_id,binding_status,review_status,created_by,reviewed_by,reviewed_at,reason,citation,provenance_basis,workstream,source_agent)
values(${literal(human?'auth_subject':'oauth_client')},${literal(f.issuer)},${literal(human?p.userId:p.clientId)},${literal(p.principalId)},'active','approved',${literal(f.alice.principalId)},${literal(f.alice.principalId)},now(),'Synthetic reviewed mapping','fixture','decision_record','operations','fixture');`);
}
for(const name of ['alice','bob','clientA'])sql.push(`insert into public.capability_grants(principal_id,resource_scope,permissions) values(${literal(f[name].principalId)},${literal(f.scope)},'{read,propose}');`);
sql.push(`insert into auth.sessions(id,user_id,oauth_client_id) values(${literal(f.alice.sessionId)},${literal(f.alice.userId)},${literal(f.clientA.clientId)});
insert into public.memories(id,content,workstream,owner,visibility,provenance_basis,citation,tags) values(${literal(f.currentId)},${literal(f.content)},'operations',${literal(f.alice.principalId)},'shared','source_document','synthetic citation','{address,NULL,office}');
reset session authorization;`);
const claims={iss:f.issuer,sub:f.alice.userId,role:'authenticated',client_id:f.clientA.clientId,session_id:f.alice.sessionId,is_anonymous:false,exp:Math.floor(Date.now()/1000)+3600};
const get={memoryId:f.currentId};
const append={idempotencyKey:'synthetic_pg17_observation',content:'Synthetic staged evidence.',workstream:f.workstream,citation:'fixture:source-v1',visibility:'private'};
sql.push(`set session authorization authenticator;
begin; set local role authenticated;
select set_config('request.jwt.claims',${literal(JSON.stringify(claims))},true);
do $check$
declare first jsonb; second jsonb; result jsonb; n integer;
begin
  result:=public.authorized_business_memory_get_v1(${literal(JSON.stringify(get))}::jsonb);
  if result#>'{record,tags}' is distinct from '["address","office"]'::jsonb then raise exception 'PG17 NULL tags were not normalized'; end if;
  if result#>>'{record,id}' is distinct from ${literal(f.currentId)} then raise exception 'PG17 positive read failed'; end if;
  result:=public.authorized_business_memory_search_v1('{"query":"What is our business address?"}'::jsonb);
  if jsonb_array_length(result->'records')<>1 then raise exception 'PG17 ordinary-question search failed'; end if;
  select count(*) into n from public.memories;
  if n<>1 then raise exception 'PG17 direct positive read failed'; end if;
  first:=public.authorized_business_memory_append_observation_v1(${literal(JSON.stringify(append))}::jsonb);
  second:=public.authorized_business_memory_append_observation_v1(${literal(JSON.stringify(append))}::jsonb);
  if first->>'observationId' is distinct from second->>'observationId' or second->>'replayed' is distinct from 'true' then raise exception 'PG17 replay failed'; end if;
  select count(*) into n from public.memories;
  if n<>1 then raise exception 'PG17 staged write polluted canonical data'; end if;
end $check$;
commit; reset session authorization;
set session authorization fixture_migration_admin;
delete from auth.sessions where id=${literal(f.alice.sessionId)};
reset session authorization;
set session authorization authenticator;
begin; set local role authenticated;
select set_config('request.jwt.claims',${literal(JSON.stringify(claims))},true);
do $check$
declare n integer; denied boolean:=false;
begin
  select count(*) into n from public.memories;
  if n<>0 then raise exception 'PG17 revoked direct API session remained readable'; end if;
  begin perform public.authorized_business_memory_get_v1(${literal(JSON.stringify(get))}::jsonb);
  exception when sqlstate 'PT403' then denied:=true; end;
  if not denied then raise exception 'PG17 revoked RPC session remained usable'; end if;
end $check$;
commit; reset session authorization;
set session authorization fixture_migration_admin;
insert into auth.sessions(id,user_id,oauth_client_id) values(${literal(f.alice.sessionId)},${literal(f.alice.userId)},${literal(f.clientA.clientId)});
reset session authorization;
select version();
select 'PG17_BUSINESS_SLICE_PASS' as result;`);
await writeFile(join(outputDirectory,'pg17-acceptance.sql'),sql.join('\n'),'utf8');
const write=(name,body)=>writeFile(join(outputDirectory,name),body,'utf8');
const auth=`set session authorization authenticator;\nbegin; set local role authenticated;\nselect set_config('request.jwt.claims',${literal(JSON.stringify(claims))},true);\n`;
const hash=createHash('sha256').update(f.content,'utf8').digest('hex');
const proposal={idempotencyKey:'synthetic_pg17_proposal',memoryId:f.currentId,expectedContentHash:hash,proposedContent:'Synthetic corrected office reference',reason:'Synthetic race control',citation:'fixture:source-v1'};
const busyCheck=input=>`do $check$ declare denied boolean:=false; begin\n begin perform ${input}; exception when sqlstate 'PT429' then denied:=true; end;\n if not denied then raise exception 'PG17 expected bounded contention rejection'; end if; end $check$;\nrollback; select 'PG17_CONTENTION_PASS';\n`;
await write('./pg17-target-hold.sql',`set session authorization fixture_migration_admin;\nbegin; select id from public.memories where id=${literal(f.currentId)} for update;\n\\echo TARGET_HELD\nselect pg_sleep(5); rollback;\n`);
await write('./pg17-target-busy.sql',auth+busyCheck(`public.authorized_business_memory_propose_change_v1(${literal(JSON.stringify(proposal))}::jsonb)`));
const overlap={...append,idempotencyKey:'synthetic_pg17_overlap'};
await write('./pg17-advisory-hold.sql',auth+`select public.authorized_business_memory_append_observation_v1(${literal(JSON.stringify(overlap))}::jsonb);\n\\echo ADVISORY_HELD\nselect pg_sleep(5); rollback;\n`);
await write('./pg17-advisory-busy.sql',auth+busyCheck(`public.authorized_business_memory_append_observation_v1(${literal(JSON.stringify(overlap))}::jsonb)`));
await write('./pg17-share-hold.sql',auth+`select public.authorized_business_memory_propose_change_v1(${literal(JSON.stringify(proposal))}::jsonb);\n\\echo SHARE_HELD\nselect pg_sleep(5); rollback;\n`);
await write('./pg17-share-control.sql',`set session authorization fixture_migration_admin;\nbegin; set local lock_timeout='1500ms';\ndo $check$ declare denied boolean:=false; begin\n begin update public.memories set content='Synthetic competing correction' where id=${literal(f.currentId)}; exception when lock_not_available then denied:=true; end;\n if not denied then raise exception 'PG17 proposal did not hold target SHARE lock'; end if; end $check$;\nrollback; select 'PG17_SHARE_LOCK_PASS';\n`);
