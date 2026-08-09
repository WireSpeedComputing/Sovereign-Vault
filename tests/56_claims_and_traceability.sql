-- tests/56_claims_and_traceability.sql
--
-- WO-16 Tasks B, D and E. All fixtures synthetic; no real supplier, product,
-- ingredient or lot appears here.
--
-- The assertions that matter are 4 (a dose mismatch is caught), 5 (a dose that
-- CANNOT be compared is not reported as fine), and 12 (a recalled lot with no
-- shipment recorded still appears in the forward trace). Each of those is a
-- place where the natural implementation reports "clean" for the wrong reason.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);
create temporary table t_ids(k text primary key, v uuid);
insert into t_ids(k,v) select k, gen_random_uuid() from unnest(array[
  'p','sup','doc','ing','ing2','prod','auth_ok','auth_high','auth_iu','auth_pro',
  'ilot','ilot2','flot','flot_unshipped']) k;
create or replace function pg_temp.id(text) returns uuid language sql stable as
  $$ select v from t_ids where k=$1 $$;

insert into principals(id,kind,display_name,active) values (pg_temp.id('p'),'human','suite56',true);
insert into suppliers(id,company,status,source_kind,provenance_basis)
values (pg_temp.id('sup'),'Suite Supplier','current','manual','human_direct');
insert into supplier_documents(id,supplier_id,doc_type,title,file_path,status,source_kind,provenance_basis)
values (pg_temp.id('doc'),pg_temp.id('sup'),'ClaimsDoc','Suite claims sheet',
        '/suite/fixtures/claims-sheet.pdf','current','manual','human_direct');
insert into ingredients(id,name,canonical_name,is_branded,status,source_kind,provenance_basis)
values (pg_temp.id('ing'),'Suite Compound','suite-compound',true,'current','manual','human_direct'),
       (pg_temp.id('ing2'),'Suite Compound Two','suite-compound-2',false,'current','manual','human_direct');
insert into products(id,code,name,formula_version,status,source_kind,provenance_basis)
values (pg_temp.id('prod'),'SUITE-56','Suite Product','v0.0-suite','current','manual','human_direct');
insert into product_ingredients(product_id,ingredient_id,dose_amount,dose_unit,status,source_kind,provenance_basis)
values (pg_temp.id('prod'),pg_temp.id('ing'),1000,'mg','current','manual','human_direct'),
       (pg_temp.id('prod'),pg_temp.id('ing2'),400,'IU','current','manual','human_direct');

-- ── Task B: authorization rows ────────────────────────────────────────────
insert into claim_authorization
  (id,ingredient_id,supplier_document_id,instrument_type,effect,authorized_text,
   dose_min_amount,dose_min_unit,status,source_kind,provenance_basis)
values
  (pg_temp.id('auth_ok'),pg_temp.id('ing'),pg_temp.id('doc'),'claims_sheet','permit',
   'supports steady daytime focus',1000,'mg','current','manual','human_direct'),
  (pg_temp.id('auth_high'),pg_temp.id('ing'),pg_temp.id('doc'),'tmla','permit',
   'supports memory and general brain health',2,'g','current','manual','human_direct'),
  (pg_temp.id('auth_iu'),pg_temp.id('ing2'),pg_temp.id('doc'),'claims_sheet','permit',
   'supports normal immune function',200,'IU','current','manual','human_direct'),
  (pg_temp.id('auth_pro'),pg_temp.id('ing'),pg_temp.id('doc'),'tmla','prohibit',
   'no anti-aging claims of any kind',null,null,'current','manual','human_direct');

-- 1. NEVER INFER: an empty authorized_text is refused at write.
do $c$ begin
  insert into claim_authorization (ingredient_id,supplier_document_id,instrument_type,effect,
    authorized_text,status,source_kind,provenance_basis)
  values (pg_temp.id('ing'),pg_temp.id('doc'),'claims_sheet','permit','   ','current','manual','human_direct');
  insert into t_result values (1,'an empty authorized_text is refused',false,'ACCEPTED');
exception when others then
  insert into t_result values (1,'an empty authorized_text is refused',true,SQLERRM);
end $c$;

-- 2. EVIDENCE NEEDS A RESOLVABLE IDENTIFIER: a free-text citation cannot be
--    expressed at all, and a malformed identifier is refused.
do $c$ begin
  insert into claim_evidence (ingredient_id,identifier_type,identifier,outcome_direction,
    status,source_kind,provenance_basis)
  values (pg_temp.id('ing'),'pmid','see the attached PDF','supports','current','manual','human_direct');
  insert into t_result values (2,'a non-resolvable evidence identifier is refused',false,'ACCEPTED');
exception when others then
  insert into t_result values (2,'a non-resolvable evidence identifier is refused',true,SQLERRM);
end $c$;

-- 3. POSITIVE CONTROL: a well-formed identifier IS accepted. Without this,
--    assertion 2 is satisfied by a table that rejects everything.
do $c$ begin
  insert into claim_evidence (ingredient_id,claim_authorization_id,identifier_type,identifier,
    dose_studied_amount,dose_studied_unit,design,outcome_direction,status,source_kind,provenance_basis)
  values (pg_temp.id('ing'),pg_temp.id('auth_ok'),'pmid','12345678',1000,'mg','rct','supports',
          'current','manual','human_direct');
  insert into t_result values (3,'positive_control: a well-formed PMID is accepted',true,'accepted');
exception when others then
  insert into t_result values (3,'positive_control: a well-formed PMID is accepted',false,SQLERRM);
end $c$;

-- ── Task E: the dose check ────────────────────────────────────────────────
-- 4. THE FINDING. Words permitted at 2 g, product formulates 1000 mg.
insert into t_result
select 4, 'a claim authorized at a higher dose than we formulate is caught',
  coalesce(count(*) = 1, false),
  coalesce(string_agg(formulated||' vs required '||required,'; '),'NOT CAUGHT')
from claim_dose_audit(pg_temp.id('prod'))
where verdict = 'DOSE_MISMATCH' and claim = 'supports memory and general brain health';

-- 5. A DOSE THAT CANNOT BE COMPARED IS NOT "FINE". IU is compound-specific and
--    claim_dose_mg refuses it, so this must report dose_uncomparable rather
--    than falling through to dose_ok.
insert into t_result
select 5, 'an unconvertible unit reports dose_uncomparable, never dose_ok',
  coalesce(bool_and(verdict = 'dose_uncomparable'), false),
  coalesce(string_agg(distinct verdict,','),'NO ROWS')
from claim_dose_audit(pg_temp.id('prod'))
where claim = 'supports normal immune function';

-- 6. The compliant claim passes, so 4 and 5 are not passing because everything
--    fails.
insert into t_result
select 6, 'positive_control: a claim we meet the dose for reports dose_ok',
  coalesce(count(*) = 1, false), coalesce(string_agg(verdict,','),'NO ROWS')
from claim_dose_audit(pg_temp.id('prod'))
where verdict = 'dose_ok' and claim = 'supports steady daytime focus';

-- 7. Prohibitions are a distinct verdict, not an absence.
insert into t_result
select 7, 'a prohibition reports as a prohibition, not as a missing permission',
  coalesce(count(*) = 1, false), coalesce(string_agg(verdict,','),'NO ROWS')
from claim_dose_audit(pg_temp.id('prod')) where verdict = 'prohibition';

-- 8. Copy check surfaces the dose mismatch at critical severity.
insert into t_result
select 8, 'proposed copy matching the over-dosed claim is flagged critical',
  coalesce(count(*) >= 1, false),
  coalesce(string_agg(left(detail,60),' | '),'NOT FLAGGED')
from claim_check_copy('Suite Compound supports memory and general brain health.', pg_temp.id('prod'))
where finding_type = 'candidate_claim' and severity = 'critical';

-- 9. Copy touching a prohibition is flagged.
insert into t_result
select 9, 'copy sharing vocabulary with a prohibition is flagged',
  coalesce(count(*) >= 1, false), coalesce(count(*)::text,'0')||' finding(s)'
from claim_check_copy('Our anti-aging formula works.', pg_temp.id('prod'))
where finding_type = 'prohibition_implicated';

-- 10. NEGATIVE CONTROL: unrelated copy produces no candidate claim. Without
--     this the matcher could return every claim for every string.
insert into t_result
select 10, 'negative_control: unrelated copy matches no claim',
  coalesce(count(*) = 0, false), count(*)::text||' spurious candidate(s)'
from claim_check_copy('Our shipping policy changed in March.', pg_temp.id('prod'))
where finding_type = 'candidate_claim';

-- 11. Status is DERIVED. Nothing stores it; the report must reflect a fact
--     changed underneath it. Retract the supporting study and the status moves.
insert into t_result
select 11, 'claim status is derived: removing the evidence changes the status',
  coalesce((select status from claim_status_report(pg_temp.id('prod'))
            where claim='supports steady daytime focus') = 'authorized_and_substantiated', false),
  'with evidence present: ' || coalesce((select status from claim_status_report(pg_temp.id('prod'))
                                         where claim='supports steady daytime focus'),'NULL');
update claim_evidence set status='superseded' where claim_authorization_id = pg_temp.id('auth_ok');
insert into t_result
select 11 + 100, 'derived status follows the evidence being withdrawn',
  coalesce((select status from claim_status_report(pg_temp.id('prod'))
            where claim='supports steady daytime focus') = 'authorized_but_unsubstantiated', false),
  'after withdrawal: ' || coalesce((select status from claim_status_report(pg_temp.id('prod'))
                                    where claim='supports steady daytime focus'),'NULL');

-- ── Task D: traceability ──────────────────────────────────────────────────
insert into ingredient_lot(id,ingredient_id,supplier_id,supplier_lot_code,coa_document_id,
                           status,source_kind,provenance_basis)
values (pg_temp.id('ilot'),pg_temp.id('ing'),pg_temp.id('sup'),'SL-001',pg_temp.id('doc'),
        'current','manual','human_direct'),
       (pg_temp.id('ilot2'),pg_temp.id('ing'),pg_temp.id('sup'),'SL-002',null,
        'current','manual','human_direct');
insert into finished_lot(id,product_id,lot_code,status,source_kind,provenance_basis)
values (pg_temp.id('flot'),pg_temp.id('prod'),'FL-100','current','manual','human_direct'),
       (pg_temp.id('flot_unshipped'),pg_temp.id('prod'),'FL-101','current','manual','human_direct');
insert into finished_lot_component(finished_lot_id,ingredient_lot_id)
values (pg_temp.id('flot'),pg_temp.id('ilot')),
       (pg_temp.id('flot_unshipped'),pg_temp.id('ilot'));
insert into lot_shipment(finished_lot_id,recipient_ref,recipient_kind)
values (pg_temp.id('flot'),'CUST-9','customer');

-- 12. THE ONE THAT MATTERS. A finished lot containing the recalled material but
--     with NO shipment recorded must still appear. An INNER JOIN would drop
--     exactly the lots whose whereabouts are unknown -- the ones a recall most
--     needs.
insert into t_result
select 12, 'forward trace includes a lot with no shipment recorded',
  coalesce(count(*) = 2, false),
  count(*)::text||' finished lot row(s): '||coalesce(string_agg(finished_lot_code||'/'||recipient_ref,', '),'-')
from recall_trace_forward(pg_temp.id('ilot'));

-- 13. Inverse trace: from a bottle back to ingredient lots, with COA presence.
insert into t_result
select 13, 'inverse trace resolves a bottle to its ingredient lots',
  coalesce(count(*) = 1 and bool_and(coa_on_file), false),
  coalesce(string_agg(supplier_lot_code||' coa='||coa_on_file::text,', '),'NO ROWS')
from recall_trace_inverse(pg_temp.id('prod'),'FL-100');

-- 14. Gaps are reported: a lot with no COA, and a finished lot never shipped.
insert into t_result
select 14, 'traceability gaps are reported rather than assumed clean',
  coalesce(count(*) filter (where gap_kind='ingredient_lot_without_coa') = 1
       and count(*) filter (where gap_kind='finished_lot_without_shipments') = 1, false),
  coalesce(string_agg(distinct gap_kind,', '),'NO GAPS REPORTED')
from lot_traceability_gaps();

insert into t_result
select 99,'GUARD_no_null_assertions', coalesce(count(*)=0,false),
  count(*)::text||' assertion(s) evaluated to NULL' from t_result where pass is null;

select n, name, coalesce(pass,false) as pass, left(detail,74) as detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
