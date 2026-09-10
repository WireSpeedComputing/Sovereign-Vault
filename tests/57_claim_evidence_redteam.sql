-- tests/57_claim_evidence_redteam.sql
--
-- WO-17 Task C. Proves the evidence auditor catches the four failure modes it
-- claims to, by seeding each one deliberately.
--
-- An auditor that has only ever passed is evidence of nothing. This project has
-- sixteen catalogued instances of a check reporting success without checking,
-- and an unverified auditor of unverified citations would be the seventeenth --
-- the same defect one level up.
--
-- The four seeded defects, each of which LOOKS like substantiation in a report
-- that only counts rows:
--   1  a dead DOI                      resolved and returned nothing
--   2  a retracted paper               resolves fine, and is withdrawn
--   3  a study at a tenth of our dose  real, indexed, and does not support us
--   4  a supplier PDF as a citation    a well-formed DOI pointing at marketing
--
-- All fixtures synthetic. The identifiers are shape-valid and deliberately
-- fictional; nothing here resolves to a real paper.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);
create temporary table t_ids(k text primary key, v uuid);
insert into t_ids(k,v) select k, gen_random_uuid() from unnest(array[
  'p','sup','doc','ing','prod','auth','ev_dead','ev_retracted','ev_underdosed',
  'ev_supplier','ev_good']) k;
create or replace function pg_temp.id(text) returns uuid language sql stable as
  $$ select v from t_ids where k=$1 $$;

insert into principals(id,kind,display_name,active) values (pg_temp.id('p'),'human','suite57',true);
insert into suppliers(id,company,status,source_kind,provenance_basis)
values (pg_temp.id('sup'),'Suite Supplier 57','current','manual','human_direct');
insert into supplier_documents(id,supplier_id,doc_type,title,file_path,status,source_kind,provenance_basis)
values (pg_temp.id('doc'),pg_temp.id('sup'),'ClaimsDoc','Suite 57 sheet',
        '/suite/57/sheet.pdf','current','manual','human_direct');
insert into ingredients(id,name,canonical_name,is_branded,status,source_kind,provenance_basis)
values (pg_temp.id('ing'),'Suite Compound 57','suite-compound-57',true,'current','manual','human_direct');
insert into products(id,code,name,formula_version,status,source_kind,provenance_basis)
values (pg_temp.id('prod'),'SUITE-57','Suite Product 57','v0-suite','current','manual','human_direct');
insert into product_ingredients(product_id,ingredient_id,dose_amount,dose_unit,status,source_kind,provenance_basis)
values (pg_temp.id('prod'),pg_temp.id('ing'),500,'mg','current','manual','human_direct');
insert into claim_authorization(id,ingredient_id,supplier_document_id,instrument_type,effect,
  authorized_text,dose_min_amount,dose_min_unit,status,source_kind,provenance_basis)
values (pg_temp.id('auth'),pg_temp.id('ing'),pg_temp.id('doc'),'claims_sheet','permit',
  'supports working memory',500,'mg','current','manual','human_direct');

-- ── THE FOUR SEEDED DEFECTS ───────────────────────────────────────────────
insert into claim_evidence(id,ingredient_id,claim_authorization_id,identifier_type,identifier,
  dose_studied_amount,dose_studied_unit,design,outcome_direction,independence_tier,
  resolution_status,retraction_status,last_verified_at,status,source_kind,provenance_basis)
values
  -- 1. dead DOI: fetched, returned nothing
  (pg_temp.id('ev_dead'),pg_temp.id('ing'),pg_temp.id('auth'),'doi','10.9999/suite-does-not-exist',
   500,'mg','rct','supports','peer_reviewed_indexed','not_found','none',now(),
   'current','manual','human_direct'),
  -- 2. retracted: resolves perfectly and is withdrawn
  (pg_temp.id('ev_retracted'),pg_temp.id('ing'),pg_temp.id('auth'),'pmid','29999991',
   500,'mg','rct','supports','peer_reviewed_indexed','resolved','retracted',now(),
   'current','manual','human_direct'),
  -- 3. underdosed: real, indexed, supportive -- at a tenth of what we formulate
  (pg_temp.id('ev_underdosed'),pg_temp.id('ing'),pg_temp.id('auth'),'pmid','29999992',
   50,'mg','rct','supports','peer_reviewed_indexed','resolved','none',now(),
   'current','manual','human_direct'),
  -- 4. supplier PDF wearing a DOI
  (pg_temp.id('ev_supplier'),pg_temp.id('ing'),pg_temp.id('auth'),'doi','10.5555/suite-supplier-white-paper',
   500,'mg','open_label','supports','supplier_published_unindexed','resolved','none',now(),
   'current','manual','human_direct'),
  -- CONTROL: everything right. Without this the auditor could flag all rows.
  (pg_temp.id('ev_good'),pg_temp.id('ing'),pg_temp.id('auth'),'pmid','29999993',
   500,'mg','rct','supports','peer_reviewed_indexed','resolved','none',now(),
   'current','manual','human_direct');

-- ══════════════════════════════════════════════════════════════════════════
-- Assertions
-- ══════════════════════════════════════════════════════════════════════════

insert into t_result
select 1, 'RED TEAM: the dead identifier is caught at critical',
  coalesce(count(*) >= 1, false), coalesce(string_agg(left(finding,50),' | '),'NOT CAUGHT')
from claim_evidence_audit()
where check_name='resolution' and severity='critical' and identifier like '%suite-does-not-exist%';

insert into t_result
select 2, 'RED TEAM: the retracted paper is caught at critical',
  coalesce(count(*) >= 1, false), coalesce(string_agg(left(finding,50),' | '),'NOT CAUGHT')
from claim_evidence_audit()
where check_name='retraction' and severity='critical' and identifier like '%29999991%';

insert into t_result
select 3, 'RED TEAM: the study at a tenth of our dose is caught',
  coalesce(count(*) >= 1, false), coalesce(string_agg(left(finding,60),' | '),'NOT CAUGHT')
from claim_evidence_audit()
where check_name='dose_adequacy' and identifier like '%29999992%';

insert into t_result
select 4, 'RED TEAM: the supplier PDF is not counted as independent evidence',
  coalesce(count(*) >= 1, false), coalesce(string_agg(left(finding,60),' | '),'NOT CAUGHT')
from claim_evidence_audit()
where check_name='independence' and identifier like '%supplier-white-paper%';

-- 5. THE CONTROL. If the auditor flags the clean row too, assertions 1-4 are
--    satisfied by something that flags everything, and prove nothing.
insert into t_result
select 5, 'control: the clean evidence row produces NO findings',
  coalesce(count(*) = 0, false),
  case when count(*) = 0 then 'clean row is silent'
       else 'FLAGGED: ' || string_agg(check_name,',') end
from claim_evidence_audit() where identifier like '%29999993%';

-- 6. Coverage numbers are reported, so a quiet auditor is distinguishable from
--    a clean one.
insert into t_result
select 6, 'coverage reports rows examined, not just findings',
  coalesce((select value::int from claim_evidence_audit_coverage()
            where metric='evidence_rows_examined') = 5, false),
  coalesce((select string_agg(metric||'='||value,' ') from claim_evidence_audit_coverage()),'-');

-- 7. never_attempted is CRITICAL, not neutral. An unverified citation is worse
--    than an empty field because it looks like substantiation.
insert into claim_evidence(ingredient_id,claim_authorization_id,identifier_type,identifier,
  outcome_direction,status,source_kind,provenance_basis)
values (pg_temp.id('ing'),pg_temp.id('auth'),'pmid','29999994','supports',
        'current','manual','human_direct');
insert into t_result
select 7, 'an unresolved citation is CRITICAL, not a neutral default',
  coalesce(count(*) >= 1, false), coalesce(string_agg(left(finding,50),' | '),'NOT CAUGHT')
from claim_evidence_audit()
where check_name='resolution' and severity='critical' and identifier like '%29999994%';

-- ── Task D: the tier must reflect all of this ─────────────────────────────
insert into claim_usage(ingredient_id,product_id,claim_authorization_id,our_wording,
  wording_strength,status,source_kind,provenance_basis)
values (pg_temp.id('ing'),pg_temp.id('prod'),pg_temp.id('auth'),'supports working memory',
        'hedged_support','proposed','manual','human_direct');

-- 8. A retracted paper in the evidence set forces DO_NOT_USE, automatically,
--    because the tier is derived. A stored tier would still say PACKAGE_SAFE.
insert into t_result
select 8, 'a retracted citation forces DO_NOT_USE via derivation',
  coalesce((select tier from claim_risk_tier(
             (select id from claim_usage where ingredient_id=pg_temp.id('ing') limit 1)))
           = 'DO_NOT_USE', false),
  coalesce((select tier from claim_risk_tier(
             (select id from claim_usage where ingredient_id=pg_temp.id('ing') limit 1))),'NULL');

-- 9. Verbatim wording is recognised as VERBATIM_AUTHORIZED.
insert into t_result
select 9, 'exact supplier wording reports VERBATIM_AUTHORIZED',
  coalesce((select shield from claim_risk_tier(
             (select id from claim_usage where ingredient_id=pg_temp.id('ing') limit 1)))
           = 'VERBATIM_AUTHORIZED', false),
  coalesce((select shield from claim_risk_tier(
             (select id from claim_usage where ingredient_id=pg_temp.id('ing') limit 1))),'NULL');

-- 10. A reworded claim that MEANS the same thing is still MODIFIED. Deciding two
--     phrasings are equivalent is the judgement that moves liability to us, and
--     the system must not make it.
update claim_usage set our_wording = 'helps support your working memory'
 where ingredient_id = pg_temp.id('ing');
insert into t_result
select 10, 'a reworded claim is MODIFIED even when it means the same thing',
  coalesce((select shield from claim_risk_tier(
             (select id from claim_usage where ingredient_id=pg_temp.id('ing') limit 1)))
           = 'MODIFIED_AUTHORIZED', false),
  coalesce((select shield from claim_risk_tier(
             (select id from claim_usage where ingredient_id=pg_temp.id('ing') limit 1))),'NULL');

-- 11. Evidence is immutable once recorded. Corrections append a successor;
--     verification fields are the deliberate exception.
do $c$ begin
  update claim_evidence set identifier = '11111111' where id = pg_temp.id('ev_good');
  insert into t_result values (11,'evidence identifiers are immutable once recorded',false,'ACCEPTED');
exception when others then
  insert into t_result values (11,'evidence identifiers are immutable once recorded',true,SQLERRM);
end $c$;

-- 12. ...but the auditor CAN write verification results back, or it could never
--     turn a never_attempted row green.
do $c$ begin
  update claim_evidence set resolution_status='resolved', last_verified_at=now()
   where id = pg_temp.id('ev_good');
  insert into t_result values (12,'verification fields remain writable by the auditor',true,'accepted');
exception when others then
  insert into t_result values (12,'verification fields remain writable by the auditor',false,SQLERRM);
end $c$;

insert into t_result
select 99,'GUARD_no_null_assertions', coalesce(count(*)=0,false),
  count(*)::text||' assertion(s) evaluated to NULL' from t_result where pass is null;

select n, name, coalesce(pass,false) as pass, left(detail,72) as detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
