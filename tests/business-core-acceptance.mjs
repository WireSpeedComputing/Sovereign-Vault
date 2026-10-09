import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { SYNTHETIC, executeAs, invokeRpcAs, expectedContentHash } from './64_business_user_tools.mjs';

const repo = new URL('../', import.meta.url);
const digest = value => createHash('sha256').update(value, 'utf8').digest('hex');
const read = path => readFile(new URL(path, repo), 'utf8');

/** Full source replay, never source extraction or substitute physical tables.
 * Loads real vector and pgcrypto archives from the selected PGlite distribution.
 */
export async function createBusinessCoreDatabase(options = {}) {
  const runtime = options.pgliteModule ?? process.env.BUSINESS_PGLITE_MODULE ?? '@electric-sql/pglite';
  const entry = import.meta.resolve(runtime);
  const { PGlite } = await import(runtime);
  const { vector } = await import(new URL('./vector/index.js', entry).href);
  const pgcrypto = { name: 'pgcrypto', setup: async (_db, emscriptenOpts) => ({
    emscriptenOpts, bundlePath: new URL('./pgcrypto.tar.gz', entry),
  }) };
  const db = new PGlite({ extensions: { vector, pgcrypto } });
  const manifestText = await read('profiles/business-core.manifest');
  const paths = manifestText.split(/\r?\n/).map(line => line.trim()).filter(line => line && !line.startsWith('#'));
  assert.equal(new Set(paths).size, paths.length, 'duplicate manifest file');
  assert.ok(paths.every(path => /^sql\/[0-9]+_[a-z0-9_]+\.sql$/.test(path)), 'finite historical core source paths only');
  const applied = [];
  try {
    for (const path of paths) {
      const source = await read(path);
      try { await db.exec(source); }
      catch (error) { error.profileFile = path; error.appliedFiles = applied.length; throw error; }
      applied.push({ path, sha256: digest(source) });
    }
    return { db, applied, manifestSha256: digest(manifestText) };
  } catch (error) { await db.close(); throw error; }
}

/** Synthetic Auth metadata is added only for the explicit F-seam acceptance.
 * It does not stand in for a hosted Auth provider or qualify a deployment.
 */
export async function installSyntheticBusinessCoreSessionGate(db, options = {}) {
  await db.exec(`CREATE ROLE authenticator LOGIN NOSUPERUSER NOINHERIT NOBYPASSRLS;
    GRANT authenticated,anon TO authenticator;
    CREATE SCHEMA auth;
    CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,oauth_client_id uuid,not_after timestamptz);
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE SET search_path=pg_catalog AS
      $$ SELECT nullif(current_setting('request.jwt.claims',true)::jsonb->>'sub','')::uuid $$;
    REVOKE ALL ON SCHEMA auth FROM public,anon,authenticated;
    REVOKE ALL ON auth.sessions FROM public,anon,authenticated;`);
  if (options.installGate !== false) await db.exec(await read('pending/F_business_live_session.sql'));
}

export async function seedSyntheticBusinessCore(db) {
  for (const [name,kind] of [['alice','human'],['bob','human'],['clientA','agent'],['clientB','agent']])
    await db.query('INSERT INTO public.principals(id,kind,display_name) VALUES($1,$2,$3)',
      [SYNTHETIC[name].principalId,kind,`Synthetic ${name}`]);
  await db.query(`INSERT INTO public.scope_registry(scope,kind,identifier,description)
    VALUES($1,'workstream','operations','Synthetic business core fixture')`,[SYNTHETIC.scope]);
  for (const name of ['alice','bob','clientA','clientB']) {
    const p=SYNTHETIC[name], human=!!p.userId;
    await db.query(`INSERT INTO vault_auth.principal_identity_bindings(identity_kind,issuer,identity_value,principal_id,binding_status,review_status,
      created_by,reviewed_by,reviewed_at,reason,citation,provenance_basis,workstream,source_agent)
      VALUES($1,$2,$3,$4,'active','approved',$5,$5,now(),'Synthetic reviewed mapping','synthetic fixture','decision_record','operations','fixture')`,
      [human?'auth_subject':'oauth_client',SYNTHETIC.issuer,human?p.userId:p.clientId,p.principalId,SYNTHETIC.alice.principalId]);
  }
  for (const name of ['alice','bob','clientA']) await db.query(
    'INSERT INTO public.capability_grants(principal_id,resource_scope,permissions) VALUES($1,$2,$3)',
    [SYNTHETIC[name].principalId,SYNTHETIC.scope,'{read,propose}']);
  for (const name of ['alice','bob']) await db.query('INSERT INTO auth.sessions(id,user_id,oauth_client_id) VALUES($1,$2,$3)',
    [SYNTHETIC[name].sessionId,SYNTHETIC[name].userId,SYNTHETIC.clientA.clientId]);
  await db.query('INSERT INTO auth.sessions(id,user_id,oauth_client_id) VALUES($1,$2,$3)',
    [SYNTHETIC.alternateSessionId,SYNTHETIC.alice.userId,SYNTHETIC.clientB.clientId]);
  await db.transaction(async tx => {
    // Controller-only fixture initialization follows the actual canonical guard.
    await tx.exec("SET LOCAL app.promoting='on'");
    for (const [id,content,scope,status,visibility] of [
      [SYNTHETIC.currentId,SYNTHETIC.content,'operations','current','shared'],
      [SYNTHETIC.privateId,'Synthetic private office record','operations','current','private'],
      [SYNTHETIC.otherScopeId,'Synthetic out-of-scope office record','finance','current','shared'],
      [SYNTHETIC.proposedId,'Synthetic proposed office record','operations','proposed','shared'],
    ]) await tx.query(`INSERT INTO public.memories(id,content,workstream,status,owner,visibility,provenance_basis,citation)
      VALUES($1,$2,$3,$4,$5,$6,'source_document','synthetic core source')`,
      [id,content,scope,status,SYNTHETIC.alice.principalId,visibility]);
    await tx.query(`INSERT INTO public.wiki_pages(id,path,title,content,workstream,owner,visibility,provenance_basis,citation)
      VALUES($1,'synthetic/office','Synthetic office','Synthetic business office reference','operations',$2,'shared','source_document','synthetic core source')`,
      [SYNTHETIC.wikiId,SYNTHETIC.alice.principalId]);
    await tx.exec("SET LOCAL app.promoting='off'");
  });
}

export async function runBusinessCoreAcceptance() {
  const { db, applied, manifestSha256 } = await createBusinessCoreDatabase();
  let checks=0;
  const check=(actual,expected,message)=>{assert.deepEqual(actual,expected,message);checks++;};
  const reject=async(action,code,message)=>{await assert.rejects(action,error=>error.code===code,message);checks++;};
  const invoke=(name,input,options={})=>invokeRpcAs(db,options,`authorized_business_memory_${name}_v1`,input);
  try {
    const postgres=(await db.query('SELECT version() AS version')).rows[0].version;
    check((await db.query("SELECT extname FROM pg_extension WHERE extname IN ('vector','pgcrypto') ORDER BY extname")).rows.map(row=>row.extname),
      ['pgcrypto','vector'],'real required extensions installed');
    check((await db.query("SELECT '[1,0,0]'::vector <=> '[1,0,0]'::vector AS distance")).rows[0].distance,0,'real vector operator executes');
    check((await db.query("SELECT encode(digest('synthetic','sha256'),'hex') AS hash")).rows[0].hash,digest('synthetic'),'real pgcrypto digest executes');
    check((await db.query(`SELECT count(*)::int AS n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
      AND c.relkind='r' AND NOT c.relrowsecurity`)).rows[0].n,0,'all canonical profile tables retain RLS');
    check((await db.query(`SELECT count(*)::int AS n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname ~ '^(supplier|product|ingredient|claim_|language_rules|lots|batches)'`)).rows[0].n,
      0,'no industry-specific domain relations installed');
    check((await db.query("SELECT count(*)::int AS n FROM provenance_registry WHERE table_name NOT IN ('memories','wiki_pages')")).rows[0].n,
      0,'no domain provenance registration installed');
    check((await db.query('SELECT count(*)::int AS n FROM public.principals')).rows[0].n,0,'no deployment principals seeded');
    check((await db.query('SELECT count(*)::int AS n FROM public.capability_grants')).rows[0].n,0,'no deployment grants seeded');
    check((await db.query('SELECT count(*)::int AS n FROM public.perimeter_assert()')).rows[0].n,0,'actual complete profile perimeter clean');
    check((await db.query('SELECT evaluation_status,violation_count FROM public.perimeter_report()')).rows[0],
      {evaluation_status:'evaluated',violation_count:0},'actual perimeter evaluated rather than empty unchecked');
    check((await db.query("SELECT to_regprocedure('public.authorized_business_memory_get_v1(jsonb)') AS rpc")).rows[0].rpc,
      null,'default core excludes pending candidates');
    await db.exec(await read('pending/E_business_user_tools.sql'));
    check((await db.query("SELECT rolsuper,rolbypassrls,rolcanlogin FROM pg_roles WHERE rolname='business_user_tools_v1'")).rows[0],
      {rolsuper:false,rolbypassrls:false,rolcanlogin:false},'explicitly opted-in finite candidate owner remains non-bypass');
    await installSyntheticBusinessCoreSessionGate(db,{installGate:false});
    await seedSyntheticBusinessCore(db);
    await reject(()=>invoke('get',{memoryId:SYNTHETIC.currentId}),'PT403','E alone denies RPC despite valid synthetic mappings');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,0,'E alone denies direct canonical reads');
    await db.exec(await read('pending/F_business_live_session.sql'));
    const exact=await invoke('get',{memoryId:SYNTHETIC.currentId});
    check(exact.record.content,SYNTHETIC.content,'exact actual canonical memory');
    check(exact.record.version,expectedContentHash,'exact actual canonical version');
    check((await invoke('get',{memoryId:SYNTHETIC.wikiId,relation:'wiki_pages'})).record.id,SYNTHETIC.wikiId,'real wiki schema read');
    check((await invoke('search',{query:'What is our business address?'})).records.some(row=>row.id===SYNTHETIC.currentId),true,'ordinary question works on real profile');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,2,'direct current scoped read positive control');
    check((await invoke('get',{memoryId:SYNTHETIC.privateId},{actor:'bob'})).record,null,'cross-user private denied');
    check((await invoke('get',{memoryId:SYNTHETIC.otherScopeId})).record,null,'cross-scope denied');
    check((await invoke('get',{memoryId:SYNTHETIC.proposedId})).record,null,'proposal is not current');
    const alternate={client:'clientB',claims:{session_id:SYNTHETIC.alternateSessionId}};
    check((await invoke('get',{memoryId:SYNTHETIC.currentId},alternate)).record,null,'missing intersected client grant denied');
    const append={idempotencyKey:'core_observation_0001',content:'Synthetic core observation',workstream:'operations',citation:'synthetic receipt',visibility:'private'};
    const first=await invoke('append_observation',append);
    check(first.status,'proposed','core observation staged');
    check((await invoke('append_observation',append)).observationId,first.observationId,'core observation exact replay');
    await reject(()=>invoke('append_observation',{...append,content:'changed'}),'PT412','core idempotency conflict');
    const proposal={idempotencyKey:'core_proposal_0001',memoryId:SYNTHETIC.currentId,expectedContentHash,
      proposedContent:'Synthetic proposed changed business address',reason:'Synthetic reason',citation:'synthetic evidence'};
    const staged=await invoke('propose_change',proposal);
    check(staged.targetId,SYNTHETIC.currentId,'core change staged against exact target');
    check((await invoke('propose_change',proposal)).proposalId,staged.proposalId,'core proposal exact replay');
    check((await invoke('get',{memoryId:SYNTHETIC.currentId})).record.version,expectedContentHash,'core staging cannot change canonical');
    await reject(()=>invoke('propose_change',{...proposal,idempotencyKey:'core_noop_0001',proposedContent:SYNTHETIC.content}),'PT422','core no-op denied');
    await reject(()=>executeAs(db,{},'UPDATE public.memories SET content=\'forbidden\''),'42501','core authenticated canonical DML denied');
    await reject(()=>invoke('get',{memoryId:SYNTHETIC.currentId},{role:'anon'}),'42501','core anonymous RPC denied');
    await db.query('DELETE FROM auth.sessions WHERE id=$1',[SYNTHETIC.alice.sessionId]);
    await reject(()=>invoke('get',{memoryId:SYNTHETIC.currentId}),'PT403','core revoked session RPC denied');
    check((await executeAs(db,{},'SELECT count(*)::int AS n FROM public.memories')).rows[0].n,0,'core revoked session direct read denied');
    console.log(JSON.stringify({status:'PASS',checks,postgres,appliedFiles:applied.length,manifestSha256,
      optionalCandidates:['pending/E_business_user_tools.sql','pending/F_business_live_session.sql'],
      extensions:['vector','pgcrypto'],sourceMode:'whole checked-in SQL files',authority:'synthetic only',hostedMutation:false}));
    return {checks,postgres,applied,manifestSha256};
  } finally {await db.close();}
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await runBusinessCoreAcceptance(); }
  catch (error) { console.error(JSON.stringify({status:'FAIL',code:error.code,message:error.message,where:error.where,
    profileFile:error.profileFile,appliedFiles:error.appliedFiles}));process.exitCode=1; }
}
