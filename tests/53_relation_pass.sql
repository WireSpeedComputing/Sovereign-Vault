-- tests/53_relation_pass.sql
--
-- A1. Proves the relation pass finds the contradiction SHAPES it claims to, and
-- proves it is capable of finding nothing when nothing is there.
--
-- ── FIXTURES ARE SYNTHETIC ANALOGUES, NOT THE CORPUS ──────────────────────
-- The pass was validated against a real 16-statement extraction from six real
-- records, with predictions committed before it was written. Those records are
-- business data and none of them appears here, in any form. What is reproduced
-- is the SHAPE of each contradiction:
--
--   shape 1  one record assigns the same item to two mutually exclusive
--            categories AND to a third that denies both -- the intra-record
--            composition contradiction
--   shape 2  two records give different values for the same derived quantity,
--            with no number in common
--   shape 3  two records disagree about a figure while SHARING one number --
--            the partially-updated document. This is the shape that a
--            disjoint-number rule cannot see, and it is why the rule requires
--            the number sets to be unequal rather than disjoint.
--
-- Shape 3 is the assertion worth keeping. It is the one the first version of
-- the pass missed on real data.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);
create temporary table t_ids(k text primary key, v uuid);
insert into t_ids(k,v) select k, gen_random_uuid() from unnest(array[
  'p','ext','r_compose','r_figs_a','r_figs_b','r_quiet_a','r_quiet_b','r_quiet_c']) k;
create or replace function pg_temp.id(text) returns uuid language sql stable as
  $$ select v from t_ids where k=$1 $$;

insert into principals(id,kind,display_name,active) values (pg_temp.id('p'),'human','suite53',true);
insert into scope_registry(scope,kind,identifier,description)
values ('workstream:suite53','workstream','suite53','synthetic') on conflict do nothing;

create or replace function pg_temp.mkrec(k text, body text) returns void language plpgsql as $$
begin
  insert into memories(id,content,workstream,tags,source_kind,status,owner,visibility,provenance_basis)
  values (pg_temp.id(k), body, 'suite53','{}','manual','proposed', pg_temp.id('p'),'shared','human_direct');
  perform promote_memory(pg_temp.id(k), pg_temp.id('p'));
end $$;

select pg_temp.mkrec('r_compose',
  'WIDGET ASSIGNMENT: ALPHA-ONLY list includes Sprocket 200mm. BETA-ONLY list includes Sprocket 200mm. SHARED: Sprocket only, 200mm in both units.');
select pg_temp.mkrec('r_figs_a',
  'Analysis one. The crossover point where the second option becomes cheaper is 75-100 units.');
select pg_temp.mkrec('r_figs_b',
  'Analysis two. The crossover point where the second option becomes cheaper is 117 units.');
select pg_temp.mkrec('r_quiet_a',
  'The reference sheet still shows 98 per unit and should show 79 and 99.');
select pg_temp.mkrec('r_quiet_b',
  'The reference sheet was updated from 98 per unit to a blended 85.');

insert into statement_extractions(id,method,actor_principal,ruleset_version,source_selector,notes)
values (pg_temp.id('ext'),'human',pg_temp.id('p'),'suite53','synthetic fixtures','relation pass suite');

create or replace function pg_temp.mk(p_rec text, p_claim text, p_quote text) returns void
language plpgsql as $$
declare v_content text; v_pos int; v_occ int;
begin
  select content into v_content from memories where id = pg_temp.id(p_rec);
  v_pos := strpos(v_content, p_quote);
  if v_pos = 0 then raise exception 'quote absent from %', p_rec; end if;
  v_occ := (length(v_content) - length(replace(v_content, p_quote, ''))) / length(p_quote);
  if v_occ > 1 then raise exception 'quote ambiguous in %', p_rec; end if;
  insert into statements(claim, modality, derived_from, source_content_hash, span_start, span_end,
                         quote_hash, extraction_id, inherited_basis)
  values (p_claim,'asserted', pg_temp.id(p_rec), encode(digest(v_content,'sha256'),'hex'),
          v_pos, v_pos + length(p_quote) - 1,
          encode(digest(p_quote,'sha256'),'hex'), pg_temp.id('ext'),'human_direct');
end $$;

-- shape 1: the three-way composition contradiction, all inside one record
select pg_temp.mk('r_compose','Sprocket 200mm is an ALPHA-ONLY component','ALPHA-ONLY list includes Sprocket 200mm');
select pg_temp.mk('r_compose','Sprocket 200mm is a BETA-ONLY component','BETA-ONLY list includes Sprocket 200mm');
select pg_temp.mk('r_compose','Sprocket 200mm is SHARED between both units','SHARED: Sprocket only, 200mm in both units');
-- shape 2: disjoint figures for the same derived quantity
select pg_temp.mk('r_figs_a','The crossover point where the second option becomes cheaper is 75-100 units',
  'The crossover point where the second option becomes cheaper is 75-100 units');
select pg_temp.mk('r_figs_b','The crossover point where the second option becomes cheaper is 117 units',
  'The crossover point where the second option becomes cheaper is 117 units');
-- shape 3: overlapping figures -- shares 98, disagrees on everything else
select pg_temp.mk('r_quiet_a','The reference sheet still shows 98 and should show 79 and 99',
  'The reference sheet still shows 98 per unit and should show 79 and 99');
select pg_temp.mk('r_quiet_b','The reference sheet was updated from 98 to a blended 85',
  'The reference sheet was updated from 98 per unit to a blended 85');

-- ══════════════════════════════════════════════════════════════════════════
-- Assertions
-- ══════════════════════════════════════════════════════════════════════════

-- 1. Shape 1 surfaces, and is classified intra_record without anything storing
--    that classification.
insert into t_result
select 1, 'the intra-record composition contradiction surfaces, all three pairs',
  coalesce(count(*) = 3, false),
  count(*)::text || ' intra_record exclusivity pairs (expected 3: alpha/beta, alpha/shared, beta/shared)'
from statement_contradiction_candidates(2)
where locality='intra_record' and reason='exclusivity_conflict';

-- 2. Shape 2 surfaces as a cross-record numeric divergence.
insert into t_result
select 2, 'disjoint figures for the same quantity surface as cross_record',
  coalesce(count(*) >= 1, false), count(*)::text || ' pair(s)'
from statement_contradiction_candidates(2)
where locality='cross_record' and reason='numeric_divergence'
  and a_numbers like '%117%' or b_numbers like '%117%';

-- 3. THE ONE THAT MATTERS. Shape 3 shares the number 98. A disjoint-number rule
--    cannot see it; this is the assertion that pins the rule to set-inequality.
insert into t_result
select 3, 'a partially-updated figure surfaces even though the pair shares a number',
  coalesce(count(*) = 1, false),
  case when count(*) = 1 then 'found: ' || min(a_numbers) || ' vs ' || min(b_numbers)
       else 'NOT FOUND -- the rule has regressed to requiring disjoint numbers' end
from statement_contradiction_candidates(2)
where locality='cross_record'
  and ((a_numbers like '%98%' and b_numbers like '%98%'));

-- 4. NEGATIVE CONTROL. Two statements that agree exactly must not be flagged.
--    Without this the pass could return every pair and score full recall.
select pg_temp.mkrec('r_quiet_c','The reference sheet was updated from 98 per unit to a blended 85 exactly.');
select pg_temp.mk('r_quiet_c','The reference sheet was updated from 98 to a blended 85',
  'The reference sheet was updated from 98 per unit to a blended 85');
insert into t_result
select 4, 'two statements asserting the same figures are NOT flagged',
  coalesce(not exists (
    select 1 from statement_contradiction_candidates(2) c
    join statements sa on sa.id=c.a join statements sb on sb.id=c.b
    where sa.derived_from = pg_temp.id('r_quiet_b') and sb.derived_from = pg_temp.id('r_quiet_c')
       or sb.derived_from = pg_temp.id('r_quiet_b') and sa.derived_from = pg_temp.id('r_quiet_c')), false),
  'identical figures across two records must be silent';

-- 5. The pass proposes only. It must not write relations by itself -- asserting
--    a contradiction carries custody and needs an asserter.
insert into t_result
select 5, 'the pass writes no relations of its own',
  coalesce((select count(*) from statement_relations) = 0, false),
  (select count(*)::text from statement_relations) || ' relation rows exist after running the pass';

insert into t_result
select 99,'GUARD_no_null_assertions', coalesce(count(*)=0,false),
  count(*)::text||' assertion(s) evaluated to NULL' from t_result where pass is null;

select n, name, coalesce(pass,false) as pass, left(detail,80) as detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
