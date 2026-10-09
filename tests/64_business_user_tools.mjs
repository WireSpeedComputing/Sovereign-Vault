import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const repo = new URL('../', import.meta.url);
const sha256 = (text) => createHash('sha256').update(text, 'utf8').digest('hex');
export const SYNTHETIC = Object.freeze({
  issuer: 'https://synthetic.invalid/auth/v1',
  alice: { userId:'10000000-0000-4000-8000-000000000001',principalId:'30000000-0000-4000-8000-000000000001',sessionId:'20000000-0000-4000-8000-000000000001' },
  bob: { userId:'10000000-0000-4000-8000-000000000002',principalId:'30000000-0000-4000-8000-000000000002',sessionId:'20000000-0000-4000-8000-000000000002' },
  alternateSessionId:'20000000-0000-4000-8000-000000000003',
  clientA: { clientId:'40000000-0000-4000-8000-000000000001',principalId:'50000000-0000-4000-8000-000000000001' },
  clientB: { clientId:'40000000-0000-4000-8000-000000000002',principalId:'50000000-0000-4000-8000-000000000002' },
  currentId:'60000000-0000-4000-8000-000000000001',
  privateId:'60000000-0000-4000-8000-000000000002',
  otherScopeId:'60000000-0000-4000-8000-000000000003',
  proposedId:'60000000-0000-4000-8000-000000000004',
  supersededId:'60000000-0000-4000-8000-000000000005',
  unclassifiedId:'60000000-0000-4000-8000-000000000006',
  blankScopeId:'60000000-0000-4000-8000-000000000007',
  mixedScopeId:'60000000-0000-4000-8000-000000000008',
  wikiId:'70000000-0000-4000-8000-000000000001',
  content:'Business address\nSynthetic office location: 100 Example Avenue. This is a fixture, not a real address.',
  scope:'workstream:operations',workstream:'operations',
});
export const expectedContentHash = sha256(SYNTHETIC.content);
const readSql = (name) => readFile(new URL(name, repo),'utf8');
const extract = (source,start,end) => {
  const first=source.indexOf(start); const last=source.indexOf(end,first);
  assert.ok(first>=0 && last>first,`exact fixture source boundary missing: ${start}`);
  return source.slice(first,last);
};

/** Real checked-in identity/predicate bodies; synthetic physical rows only.
 * The candidate is installed as a NOSUPERUSER CREATEROLE/BYPASSRLS controller.
 * RPCs execute with session_user authenticator and SET LOCAL ROLE authenticated.
 */
export async function createBusinessFixtureDatabase(options={}) {
  const runtime = options.pgliteModule ?? process.env.BUSINESS_PGLITE_MODULE ?? '@electric-sql/pglite';
  const {PGlite}=await import(runtime);
  const db=new PGlite();
  try {
    await db.exec(await readSql('tests/64_business_user_tools_fixture.sql'));
    await db.exec(await readSql('sql/23_identity_capability_enforcement.sql'));
    await db.exec(await readSql('sql/25_public_request_has_capability.sql'));
    await db.exec(await readSql('sql/28_perimeter_assert_signal.sql'));
    const source=await readSql('sql/36_rls_policies.sql');
    await db.exec(extract(source,'create or replace function public.row_scope(','comment on function public.row_scope'));
    await db.exec(extract(source,'create or replace function public.can_read_row_as_request(','-- coalesce('));
    await db.exec(extract(source,'insert into perimeter_exception (object_kind','drop policy if exists memories_read'));
    await db.exec(`REVOKE ALL ON FUNCTION public.can_read_row_as_request(uuid,public.visibility_level,text) FROM public,anon;
      GRANT EXECUTE ON FUNCTION public.can_read_row_as_request(uuid,public.visibility_level,text) TO authenticated;
      GRANT EXECUTE ON FUNCTION public.row_scope(text) TO authenticated;
      GRANT SELECT ON public.memories,public.wiki_pages TO authenticated;
      CREATE POLICY memories_read ON public.memories FOR SELECT TO authenticated USING(status='current' AND public.can_read_row_as_request(owner,visibility,workstream));
      CREATE POLICY wiki_pages_read ON public.wiki_pages FOR SELECT TO authenticated USING(status='current' AND public.can_read_row_as_request(owner,visibility,workstream));`);
    if(options.disableCanonicalRls) await db.exec('ALTER TABLE public.memories DISABLE ROW LEVEL SECURITY');
    if(options.preexistingOverload) await db.exec(`
      CREATE FUNCTION public.authorized_business_memory_get_v1(p_input text) RETURNS jsonb
        LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT '{"syntheticUngatedOverload":true}'::jsonb $$;
      REVOKE ALL ON FUNCTION public.authorized_business_memory_get_v1(text) FROM public,anon;
      GRANT EXECUTE ON FUNCTION public.authorized_business_memory_get_v1(text) TO authenticated;`);
    await db.exec(await readSql('pending/E_business_user_tools.sql'));
    if(options.unqualifiedAuthShape) await db.exec('ALTER TABLE auth.sessions DROP COLUMN oauth_client_id');
    if(options.installSessionGate!==false) await db.exec(await readSql('pending/F_business_live_session.sql'));
    await seed(db);
    await db.exec('SET SESSION AUTHORIZATION postgres');
    return db;
  } catch(error) { await db.close(); throw error; }
}

async function seed(db) {
  for (const [name,kind] of [['alice','human'],['bob','human'],['clientA','agent'],['clientB','agent']]) {
    const p=SYNTHETIC[name];
    await db.query('INSERT INTO public.principals(id,kind,display_name) VALUES($1,$2,$3)',[p.principalId,kind,`Synthetic ${name}`]);
  }
  for(const name of ['alice','bob','clientA','clientB']) {
    const p=SYNTHETIC[name]; const human=!!p.userId;
    await db.query(`INSERT INTO vault_auth.principal_identity_bindings(identity_kind,issuer,identity_value,principal_id,binding_status,review_status,created_by,reviewed_by,reviewed_at,reason,citation,provenance_basis,workstream,source_agent)
      VALUES($1,$2,$3,$4,'active','approved',$5,$5,now(),'Synthetic reviewed mapping','fixture','decision_record','operations','fixture')`,
      [human?'auth_subject':'oauth_client',SYNTHETIC.issuer,human?p.userId:p.clientId,p.principalId,SYNTHETIC.alice.principalId]);
  }
  for(const name of ['alice','bob','clientA']) await db.query('INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,$2,$3)',
    [SYNTHETIC[name].principalId,SYNTHETIC.scope,'{read,propose}']);
  for(const name of ['alice','bob']) await db.query('INSERT INTO auth.sessions(id,user_id,oauth_client_id) VALUES($1,$2,$3)',
    [SYNTHETIC[name].sessionId,SYNTHETIC[name].userId,SYNTHETIC.clientA.clientId]);
  await db.query('INSERT INTO auth.sessions(id,user_id,oauth_client_id) VALUES($1,$2,$3)',
    [SYNTHETIC.alternateSessionId,SYNTHETIC.alice.userId,SYNTHETIC.clientB.clientId]);
  for(const [id,content,scope,status,owner,visibility,tags] of [
    [SYNTHETIC.currentId,SYNTHETIC.content,'operations','current',SYNTHETIC.alice.principalId,'shared',['address',null,'office']],
    [SYNTHETIC.privateId,'Private business address synthetic','operations','current',SYNTHETIC.alice.principalId,'private',['address']],
    [SYNTHETIC.otherScopeId,'Finance business address synthetic','finance','current',SYNTHETIC.alice.principalId,'shared',['address']],
    [SYNTHETIC.proposedId,'Proposed business address synthetic','operations','proposed',SYNTHETIC.alice.principalId,'shared',['address']],
    [SYNTHETIC.supersededId,'Old business address synthetic','operations','superseded',SYNTHETIC.alice.principalId,'shared',['address']],
    [SYNTHETIC.unclassifiedId,'Synthetic unclassified reference',null,'current',SYNTHETIC.alice.principalId,'shared',['unclassified']],
    [SYNTHETIC.blankScopeId,'Synthetic blank scope reference','   ','current',SYNTHETIC.alice.principalId,'shared',['unclassified']],
    [SYNTHETIC.mixedScopeId,'Synthetic mixed scope reference','  Brand Ops  ','current',SYNTHETIC.alice.principalId,'shared',['brand']],
  ]) await db.query(`INSERT INTO public.memories(id,content,workstream,status,owner,visibility,tags,provenance_basis,citation,source_ref)
    VALUES($1,$2,$3,$4,$5,$6,$7,'source_document','synthetic citation','synthetic:business-reference')`,[id,content,scope,status,owner,visibility,`{${tags.map(t=>t===null?'NULL':t).join(',')}}`]);
  await db.query(`INSERT INTO public.wiki_pages(id,title,content,workstream,status,owner,visibility,provenance_basis,citation)
    VALUES($1,'Synthetic office reference','Office location and business address reference','operations','current',$2,'shared','source_document','synthetic wiki citation')`,[SYNTHETIC.wikiId,SYNTHETIC.alice.principalId]);
}

export async function executeAs(db,options,sql,params=[]) {
  const actor=options?.actor??'alice'; const client=options?.client??'clientA';
  const person=SYNTHETIC[actor]; const agent=SYNTHETIC[client];
  const claims={iss:SYNTHETIC.issuer,sub:person.userId,role:'authenticated',client_id:agent.clientId,
    session_id:person.sessionId,is_anonymous:false,exp:Math.floor(Date.now()/1000)+3600,...options?.claims};
  const sessionUser=options?.sessionUser??'authenticator'; const role=options?.role??'authenticated';
  if(!['authenticator','fixture_migration_admin'].includes(sessionUser)||!['authenticated','anon','fixture_migration_admin','business_user_tools_v1'].includes(role)) throw new Error('fixture role not allowlisted');
  await db.exec(`SET SESSION AUTHORIZATION ${sessionUser}`);
  try {
    return await db.transaction(async tx=>{
      await tx.exec(`SET LOCAL ROLE ${role}`);
      await tx.query("SELECT set_config('request.jwt.claims',$1,true)",[JSON.stringify(claims)]);
      return tx.query(sql,params);
    });
  } finally { await db.exec('SET SESSION AUTHORIZATION postgres'); }
}
const RPCS=new Set(['authorized_business_memory_search_v1','authorized_business_memory_get_v1','authorized_business_memory_append_observation_v1','authorized_business_memory_propose_change_v1']);
export async function invokeRpcAs(db,options,name,input) {
  if(!RPCS.has(name)) throw new Error('fixture RPC not allowlisted');
  const result=await executeAs(db,options,`SELECT public.${name}($1::jsonb) AS result`,[JSON.stringify(input)]);
  return result.rows[0].result;
}
export async function adminSql(db,sql,params=[]) {
  await db.exec('SET SESSION AUTHORIZATION fixture_migration_admin');
  try { return await db.query(sql,params); } finally { await db.exec('SET SESSION AUTHORIZATION postgres'); }
}

export async function runAcceptance() {
  const db=await createBusinessFixtureDatabase(); let checks=0; let phase='role and read checks';
  const check=(value,expected,label)=>{ assert.deepEqual(value,expected,label); checks++; };
  const reject=async(fn,code,label)=>{ await assert.rejects(fn,error=>error.code===code,label);checks++; };
  const invoke=(name,input,options={})=>invokeRpcAs(db,options,`authorized_business_memory_${name}_v1`,input);
  const getInput={memoryId:SYNTHETIC.currentId};
  const append={idempotencyKey:'observation_0001',content:'Synthetic observation awaiting review',workstream:'operations',citation:'synthetic evidence',visibility:'private'};
  const proposal={idempotencyKey:'proposal_0001',memoryId:SYNTHETIC.currentId,expectedContentHash,proposedContent:'Synthetic proposed changed office reference',reason:'Synthetic correction',citation:'synthetic evidence'};
  try {
    const version=(await db.query('SELECT version() AS version')).rows[0].version;
    const role=(await db.query("SELECT rolsuper,rolbypassrls,rolcanlogin FROM pg_roles WHERE rolname='business_user_tools_v1'")).rows[0];
    check(role,{rolsuper:false,rolbypassrls:false,rolcanlogin:false},'runtime is limited');
    check((await db.query("SELECT rolsuper,rolcreaterole,rolbypassrls FROM pg_roles WHERE rolname='fixture_migration_admin'")).rows[0],{rolsuper:false,rolcreaterole:true,rolbypassrls:true},'limited migration controller');
    check((await db.query("SELECT count(*)::int AS n FROM pg_class WHERE oid IN ('public.memories'::regclass,'public.wiki_pages'::regclass,'business_user_tools_private.submissions_v1'::regclass) AND relowner=(SELECT oid FROM pg_roles WHERE rolname='business_user_tools_v1')")).rows[0].n,0,'runtime owns no tables');
    check((await db.query("SELECT count(*)::int AS n FROM pg_proc WHERE proname LIKE 'authorized_business_memory_%_v1' AND proowner=(SELECT oid FROM pg_roles WHERE rolname='business_user_tools_v1')")).rows[0].n,4,'four RPCs owned by limited role');
    check((await db.query("SELECT pg_has_role('fixture_migration_admin','business_user_tools_v1','USAGE') AS inherited,pg_has_role('fixture_migration_admin','business_user_tools_v1','SET') AS can_set")).rows[0],{inherited:false,can_set:false},'temporary membership authority revoked');
    check((await db.query("SELECT has_schema_privilege('business_user_tools_v1','public','CREATE') AS allowed")).rows[0].allowed,false,'temporary CREATE revoked');
    const exact=await invoke('get',getInput);check(exact.record.content,SYNTHETIC.content,'exact canonical content');check(exact.record.version,expectedContentHash,'exact raw UTF8 digest');
    check((await db.query('SELECT array_position(tags,NULL) IS NOT NULL AS present FROM public.memories WHERE id=$1',[SYNTHETIC.currentId])).rows[0].present,true,'schema-valid raw NULL tag fixture control');
    check(exact.record.tags,['address','office'],'exact get removes NULL tag and preserves remaining order');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,2,'positive direct SELECT current authorized memories count pinned');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.wiki_pages')).rows[0].n,1,'positive direct SELECT current authorized wiki count pinned');
    check((await db.query('SELECT count(*)::int AS n FROM public.perimeter_assert()')).rows[0].n,0,'reviewed API perimeter declarations complete');
    check(exact.record.status,'current','current accepted facts only');check(exact.record.provenance.citation,'synthetic citation','citation retained');check(exact.completeness.status,'complete','completeness explicit');
    const search=await invoke('search',{query:'business address'});check(search.records.some(r=>r.id===SYNTHETIC.currentId),true,'paraphrase lexical read');
    check(search.records.find(r=>r.id===SYNTHETIC.currentId).tags,['address','office'],'search removes NULL tag and preserves remaining order');
    check(search.records.some(r=>[SYNTHETIC.proposedId,SYNTHETIC.supersededId,SYNTHETIC.otherScopeId].includes(r.id)),false,'proposed, old and out-of-scope excluded');
    for(const query of ['What is our business address?','Where is our office located?','Locate our business address','Locate office directions']) {
      const ordinary=await invoke('search',{query});
      check(ordinary.records.some(r=>r.id===SYNTHETIC.currentId),true,`ordinary question finds current source: ${query}`);
      check(ordinary.records.some(r=>r.id===SYNTHETIC.otherScopeId),false,'ordinary question cannot cross scope');
    }
    check((await invoke('get',{memoryId:SYNTHETIC.wikiId,relation:'wiki_pages'})).record.relation,'wiki_pages','exact wiki read');
    check((await invoke('get',{memoryId:SYNTHETIC.privateId},{actor:'bob'})).record,null,'cross user private denied by RLS');
    check((await invoke('get',{memoryId:SYNTHETIC.otherScopeId})).record,null,'cross scope hidden');
    for(const id of [SYNTHETIC.proposedId,SYNTHETIC.supersededId]) check((await invoke('get',{memoryId:id})).record,null,'noncurrent exact get denied');
    check((await invoke('search',{query:'quasar zebrafish'})).records,[],'authorized absence distinct');
    const first=await invoke('append_observation',append);check(first.status,'proposed','observation staged');check(first.replayed,false,'new observation receipt');
    const replay=await invoke('append_observation',append);check(replay.requestId,first.requestId,'stable replay request');check(replay.observationId,first.observationId,'stable replay observation');check(replay.replayed,true,'replay explicit');
    await reject(()=>invoke('append_observation',{...append,content:'different'}),'PT412','changed idempotency payload');
    const staged=await invoke('propose_change',proposal);check(staged.targetId,SYNTHETIC.currentId,'proposal exact target');
    check((await invoke('propose_change',proposal)).proposalId,staged.proposalId,'proposal replay');
    await reject(()=>invoke('propose_change',{...proposal,reason:'changed'}),'PT412','proposal changed idempotency payload');
    check((await invoke('get',getInput)).record.content,SYNTHETIC.content,'staging cannot alter canonical');
    check((await invoke('search',{query:'observation awaiting review'})).records,[],'sidecar never accepted current fact');
    const unclassified={...proposal,idempotencyKey:'unclassified_0001',memoryId:SYNTHETIC.unclassifiedId,
      expectedContentHash:sha256('Synthetic unclassified reference'),proposedContent:'Synthetic changed unclassified reference'};
    await reject(()=>invoke('propose_change',unclassified),'PT404','NULL workstream requires unclassified grants');
    await adminSql(db,'INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,$2,$3)',
      [SYNTHETIC.alice.principalId,'workstream:unclassified','{read,propose}']);
    await reject(()=>invoke('propose_change',unclassified),'PT404','NULL workstream human grant cannot replace missing client grant');
    await adminSql(db,'INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,$2,$3)',
      [SYNTHETIC.clientA.principalId,'workstream:unclassified','{read,propose}']);
    check((await invoke('get',{memoryId:SYNTHETIC.unclassifiedId})).record.workstream,null,'NULL canonical workstream preserved on read');
    const unclassifiedReceipt=await invoke('propose_change',unclassified);
    check(unclassifiedReceipt.targetId,SYNTHETIC.unclassifiedId,'authorized NULL workstream proposal accepted');
    check((await invoke('propose_change',unclassified)).proposalId,unclassifiedReceipt.proposalId,'NULL workstream proposal replays');
    check((await db.query('SELECT workstream FROM business_user_tools_private.submissions_v1 WHERE id=$1',[unclassifiedReceipt.proposalId])).rows[0].workstream,
      'unclassified','sidecar stores reserved derived scope identifier');
    await adminSql(db,"UPDATE public.capability_grants SET revoked_at=now() WHERE principal_id=$1 AND resource_scope='workstream:unclassified'",[SYNTHETIC.alice.principalId]);
    await reject(()=>invoke('propose_change',unclassified),'PT404','NULL workstream client grant cannot replace revoked human grant');
    await adminSql(db,"UPDATE public.capability_grants SET revoked_at=null WHERE principal_id=$1 AND resource_scope='workstream:unclassified'",[SYNTHETIC.alice.principalId]);
    check((await invoke('get',{memoryId:SYNTHETIC.unclassifiedId})).record.content,'Synthetic unclassified reference','NULL workstream staging leaves canonical unchanged');
    check((await invoke('get',{memoryId:SYNTHETIC.blankScopeId})).record.workstream,null,'blank scope read normalizes metadata to nullable shape');
    const blank={...proposal,idempotencyKey:'blank_scope_0001',memoryId:SYNTHETIC.blankScopeId,
      expectedContentHash:sha256('Synthetic blank scope reference'),proposedContent:'Synthetic changed blank scope reference'};
    const blankReceipt=await invoke('propose_change',blank);
    check(blankReceipt.targetId,SYNTHETIC.blankScopeId,'blank canonical scope proposal uses reserved unclassified grants');
    check((await invoke('propose_change',blank)).proposalId,blankReceipt.proposalId,'blank canonical scope proposal replay');
    check((await db.query('SELECT workstream FROM business_user_tools_private.submissions_v1 WHERE id=$1',[blankReceipt.proposalId])).rows[0].workstream,
      'unclassified','blank canonical scope sidecar uses normalized helper');
    const mixed={...proposal,idempotencyKey:'mixed_scope_0001',memoryId:SYNTHETIC.mixedScopeId,
      expectedContentHash:sha256('Synthetic mixed scope reference'),proposedContent:'Synthetic changed mixed scope reference'};
    await reject(()=>invoke('propose_change',mixed),'PT404','mixed canonical scope remains denied without exact scope grants');
    await adminSql(db,'INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,$2,$3)',
      [SYNTHETIC.alice.principalId,'workstream:Brand Ops','{read,propose}']);
    await reject(()=>invoke('propose_change',mixed),'PT404','mixed scope human grant does not replace missing exact client grant');
    await adminSql(db,'INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,$2,$3)',
      [SYNTHETIC.clientA.principalId,'workstream:Brand Ops','{read,propose}']);
    const mixedReceipt=await invoke('propose_change',mixed);
    check(mixedReceipt.targetId,SYNTHETIC.mixedScopeId,'mixed canonical scope accepted with existing exact capability mapping');
    check((await invoke('propose_change',mixed)).proposalId,mixedReceipt.proposalId,'mixed canonical scope replay');
    check((await db.query('SELECT workstream FROM business_user_tools_private.submissions_v1 WHERE id=$1',[mixedReceipt.proposalId])).rows[0].workstream,
      'Brand Ops','mixed canonical scope sidecar derives trimmed case-preserving helper suffix');
    check((await invoke('get',{memoryId:SYNTHETIC.mixedScopeId})).record.workstream,'  Brand Ops  ','nonblank canonical scope text remains exact in read projection');
    await adminSql(db,'UPDATE public.memories SET workstream=$2 WHERE id=$1',[SYNTHETIC.mixedScopeId,'Z'.repeat(129)]);
    for(const name of ['alice','clientA']) await adminSql(db,'INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,$2,$3)',
      [SYNTHETIC[name].principalId,'workstream:'+'Z'.repeat(129),'{read,propose}']);
    await reject(()=>invoke('propose_change',{...mixed,idempotencyKey:'scope_capacity_0001'}),'PT413','inherited authorized scope outside output bound fails capacity explicitly');
    phase='caller and session denials';
    await reject(()=>invoke('propose_change',{...proposal,idempotencyKey:'no_op_0001',proposedContent:SYNTHETIC.content}),'PT422','no-op rejected');
    await reject(()=>invoke('propose_change',{...proposal,idempotencyKey:'stale_0001',expectedContentHash:'0'.repeat(64)}),'PT409','stale digest rejected');
    await reject(()=>invoke('propose_change',{...proposal,idempotencyKey:'hidden_0001',memoryId:SYNTHETIC.privateId},{actor:'bob'}),'PT404','private proposal hidden');
    await reject(()=>invoke('propose_change',{...proposal,idempotencyKey:'proposed_0001',memoryId:SYNTHETIC.proposedId}),'PT404','proposed target unavailable');
    for(const role of ['anon']) for(const name of ['get','search','append_observation','propose_change'])
      await reject(()=>invoke(name,name==='get'?getInput:name==='search'?{query:'address'}:name==='append_observation'?append:proposal,{role}),'42501','anon execute denied');
    await reject(()=>executeAs(db,{},'INSERT INTO public.memories(id,content) VALUES(gen_random_uuid(),\'forbidden\')'),'42501','authenticated canonical DML denied');
    await reject(()=>executeAs(db,{},'INSERT INTO business_user_tools_private.submissions_v1 DEFAULT VALUES'),'42501','authenticated private DML denied');
    await reject(()=>executeAs(db,{sessionUser:'fixture_migration_admin',role:'fixture_migration_admin'},'SELECT business_user_tools_private.request_actor_v1()'),'PT403','forged admin request not accepted');
    for(const claims of [
      {client_id:SYNTHETIC.clientB.clientId},{client_id:undefined},{session_id:undefined},{sub:undefined},
      {role:'service_role'},{is_anonymous:true},{is_anonymous:undefined},{exp:0},{exp:undefined},
      {session_id:SYNTHETIC.bob.sessionId},{client_id:'not-a-client'},
      {app_metadata:{client_id:SYNTHETIC.clientB.clientId}},{app_metadata:{client_id:42}},
      {app_metadata:'malformed'},{sub:'not-a-user'},{session_id:'not-a-session'}
    ]) await reject(()=>invoke('get',getInput,{claims}),'PT403','malformed or unbound session denied');
    await adminSql(db,'UPDATE auth.sessions SET not_after=now()-interval \'1 second\' WHERE id=$1',[SYNTHETIC.alice.sessionId]);
    await reject(()=>invoke('get',getInput),'PT403','expired session denied');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,0,'expired session direct SELECT denied');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.wiki_pages')).rows[0].n,0,'expired session direct wiki SELECT denied');
    await adminSql(db,'UPDATE auth.sessions SET not_after=null,oauth_client_id=null WHERE id=$1',[SYNTHETIC.alice.sessionId]);
    await reject(()=>invoke('get',getInput),'PT403','unbound password session denied');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,0,'unbound direct SELECT denied');
    await adminSql(db,'UPDATE auth.sessions SET oauth_client_id=$2 WHERE id=$1',[SYNTHETIC.alice.sessionId,SYNTHETIC.clientA.clientId]);
    check((await executeAs(db,{claims:{session_id:SYNTHETIC.bob.sessionId}},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,0,'cross-user session direct SELECT denied');
    await adminSql(db,'DELETE FROM auth.sessions WHERE id=$1',[SYNTHETIC.alice.sessionId]);
    await reject(()=>invoke('get',getInput),'PT403','revoked deleted session denied');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,0,'deleted session direct SELECT denied');
    await adminSql(db,'INSERT INTO auth.sessions(id,user_id,oauth_client_id) VALUES($1,$2,$3)',[SYNTHETIC.alice.sessionId,SYNTHETIC.alice.userId,SYNTHETIC.clientA.clientId]);
    await adminSql(db,'UPDATE public.principals SET active=false WHERE id=$1',[SYNTHETIC.clientA.principalId]);
    await reject(()=>invoke('get',getInput),'PT403','inactive mapped client principal denied');
    await adminSql(db,'UPDATE public.principals SET active=true WHERE id=$1',[SYNTHETIC.clientA.principalId]);
    await adminSql(db,'UPDATE public.principals SET active=false WHERE id=$1',[SYNTHETIC.alice.principalId]);
    await reject(()=>invoke('get',getInput),'PT403','inactive human denied');
    await adminSql(db,'UPDATE public.principals SET active=true WHERE id=$1',[SYNTHETIC.alice.principalId]);
    await adminSql(db,"UPDATE public.capability_grants SET revoked_at=now() WHERE principal_id=$1",[SYNTHETIC.clientA.principalId]);
    check((await invoke('get',getInput)).record,null,'revoked client capability filters exact read');
    await reject(()=>invoke('append_observation',append),'PT403','revoked client cannot replay write');
    await adminSql(db,'UPDATE public.capability_grants SET revoked_at=null WHERE principal_id=$1',[SYNTHETIC.clientA.principalId]);
    const alternate={client:'clientB',claims:{session_id:SYNTHETIC.alternateSessionId}};
    check((await invoke('get',getInput,alternate)).record,null,'mapped valid other client without scope cannot read');
    await reject(()=>invoke('append_observation',append,alternate),'PT403','mapped valid other client cannot replay actor receipt');
    await adminSql(db,'INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,$2,$3)',[SYNTHETIC.clientB.principalId,SYNTHETIC.scope,'{read,propose}']);
    check((await invoke('get',getInput,alternate)).record.id,SYNTHETIC.currentId,'positive intersecting second client grant control');
    await adminSql(db,"UPDATE public.capability_grants SET expires_at=now()-interval '1 second' WHERE principal_id=$1",[SYNTHETIC.alice.principalId]);
    check((await invoke('get',getInput,alternate)).record,null,'client grant cannot replace expired human capability');
    await reject(()=>invoke('append_observation',append,alternate),'PT403','expired human capability blocks write');
    await adminSql(db,'UPDATE public.capability_grants SET expires_at=null WHERE principal_id=$1',[SYNTHETIC.alice.principalId]);
    await adminSql(db,"UPDATE public.capability_grants SET permissions='{read}' WHERE principal_id=$1",[SYNTHETIC.clientB.principalId]);
    check((await invoke('get',getInput,alternate)).record.id,SYNTHETIC.currentId,'read-only client positive read');
    await reject(()=>invoke('propose_change',{...proposal,idempotencyKey:'read_only_0001'},alternate),'PT404','read-only client cannot acquire target proposal lock');
    await adminSql(db,"UPDATE vault_auth.principal_identity_bindings SET binding_status='revoked' WHERE principal_id=$1",[SYNTHETIC.alice.principalId]);
    await reject(()=>invoke('get',getInput),'PT403','revoked identity binding denied');
    await adminSql(db,"UPDATE vault_auth.principal_identity_bindings SET binding_status='active' WHERE principal_id=$1",[SYNTHETIC.alice.principalId]);
    phase='input capacity and immutability';
    for(const input of [{...getInput,principalId:SYNTHETIC.bob.principalId},{...getInput,relation:'auth.sessions'},{memoryId:42},{...getInput,budgetChars:1}])
      await reject(()=>invoke('get',input),'22023','finite get input enforced');
    for(const input of [{query:''},{query:'address',limit:21},{query:'address',limit:1.5},{query:'address',sql:'select secrets'}])
      await reject(()=>invoke('search',input),'22023','finite search input enforced');
    await reject(()=>invoke('append_observation',{...append,idempotencyKey:'bad',workstream:'operations:*'}),'22023','finite append input enforced');
    await reject(()=>invoke('append_observation',{...append,idempotencyKey:'spaces_bound_0001',content:' '.repeat(8192)+'x'}),'22023','whitespace cannot exceed full input bound');
    await adminSql(db,'UPDATE public.memories SET content=$2 WHERE id=$1',[SYNTHETIC.currentId,'x'.repeat(1000)]);
    const partial=await invoke('get',{memoryId:SYNTHETIC.currentId,budgetChars:256});
    check(partial.record.content.length,256,'bounded exact fragment');check(partial.record.contentTruncated,true,'fragment explicitly truncated');check(partial.completeness.status,'partial','fragment incomplete');
    await adminSql(db,'UPDATE public.memories SET citation=$2 WHERE id=$1',[SYNTHETIC.currentId,'x'.repeat(2049)]);
    await reject(()=>invoke('get',getInput),'PT413','citation not silently clipped');
    await adminSql(db,'UPDATE public.memories SET content=$2,citation=\'synthetic citation\' WHERE id=$1',[SYNTHETIC.currentId,'🧪'.repeat(300)]);
    const unicode=await invoke('get',{memoryId:SYNTHETIC.currentId,budgetChars:256});
    check(unicode.record.content.length,256,'non-BMP content respects JavaScript field bound');
    check(unicode.record.title.length,256,'non-BMP title respects JavaScript field bound');
    check(unicode.record.version,sha256('🧪'.repeat(300)),'non-BMP exact raw UTF8 version preserved');
    check(unicode.record.contentTruncated,true,'non-BMP fragment reports incomplete');
    await reject(()=>invoke('append_observation',{...append,idempotencyKey:'unicode_bound_0001',content:'🧪'.repeat(4097)}),'22023','non-BMP input matches adapter bound');
    check((await db.query('SELECT count(*)::int AS n FROM business_user_tools_private.submissions_v1')).rows[0].n,5,'failed requests atomic');
    await reject(()=>adminSql(db,'UPDATE business_user_tools_private.submissions_v1 SET content=\'altered\''),'42501','immutable sidecar even privileged accidental update');
    await reject(()=>adminSql(db,'DELETE FROM business_user_tools_private.submissions_v1'),'42501','immutable sidecar delete');
    for(const field of ['expected_content_hash','reason']) {
      await reject(()=>adminSql(db,`INSERT INTO business_user_tools_private.submissions_v1(id,request_id,principal_id,agent_principal_id,client_id,idempotency_key,kind,workstream,visibility,target_id,expected_content_hash,content,reason,citation,payload_hash,receipt)
        VALUES(gen_random_uuid(),gen_random_uuid(),$1,$2,$3,$4,'change_proposal','operations','shared',$5,${field==='expected_content_hash'?'NULL':'$6'},'synthetic content',${field==='reason'?'NULL':"'synthetic reason'"},'synthetic citation',$6,'{}')`,
        [SYNTHETIC.alice.principalId,SYNTHETIC.clientA.principalId,SYNTHETIC.clientA.clientId,`null_${field}_0001`,SYNTHETIC.currentId,expectedContentHash]),'23514','NULL cannot bypass sidecar CHECK');
    }
    const gate=await createBusinessFixtureDatabase({installSessionGate:false});
    try {
      await reject(()=>invokeRpcAs(gate,{},'authorized_business_memory_get_v1',getInput),'PT403','E without live gate fails closed');
      check((await executeAs(gate,{},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,0,'E alone direct Data API fails closed');
    } finally {await gate.close();}
    await reject(()=>createBusinessFixtureDatabase({disableCanonicalRls:true}), 'P0001','disabled RLS preflight rejected');
    await reject(()=>createBusinessFixtureDatabase({unqualifiedAuthShape:true}), 'P0001','unqualified Supabase session catalog refused');
    const overload=await createBusinessFixtureDatabase({preexistingOverload:true});
    try {
      check((await overload.query(`SELECT count(*)::int AS n FROM public.perimeter_exception
        WHERE object_identity='public.authorized_business_memory_get_v1(p_input text)' AND grantee='authenticated'`)).rows[0].n,0,'unreviewed overload is never an exception');
      check((await overload.query('SELECT category,object_schema,object_name,grantee,privilege FROM public.perimeter_assert()')).rows,
        [{category:'function_grant',object_schema:'public',object_name:'authorized_business_memory_get_v1(p_input text)',grantee:'authenticated',privilege:'EXECUTE'}],
        'real perimeter checker retains unreviewed overload finding');
      check((await executeAs(overload,{claims:{exp:0}},'SELECT public.authorized_business_memory_get_v1($1::text) AS result',['synthetic'])).rows[0].result,
        {syntheticUngatedOverload:true},'preexisting overload remains ungated; candidate does not conceal or modify it');
      await adminSql(overload,'DROP FUNCTION public.authorized_business_memory_get_v1(text)');
      check((await overload.query('SELECT count(*)::int AS n FROM public.perimeter_assert()')).rows[0].n,0,'baseline checker clean after explicit fixture overload cleanup');
    } finally {await overload.close();}
    console.log(JSON.stringify({checks,postgres:version,status:'PASS',scope:'synthetic E/F slice, no hosted mutation'}));
  } catch(error) {error.testPhase=phase;error.completedChecks=checks;throw error;} finally { await db.close(); }
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try { await runAcceptance(); }
  catch(error) { console.error(JSON.stringify({status:'FAIL',code:error.code,message:error.message,where:error.where,phase:error.testPhase,completedChecks:error.completedChecks})); process.exitCode=1; }
}
