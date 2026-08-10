-- 62_retrieve_context_serialized_budget.sql
--
-- MIGRATION: 70_retrieve_context_serialized_budget
-- MIGRATION: 71_retrieve_context_envelope_floor
-- MIGRATION: 72_retrieve_context_budget_self_check
--
-- Three applied migrations, one file. 70 and 71 were partial fixes that each
-- left a boundary violating; only the body below is correct and a fresh install
-- should apply only this. The intermediate states are recorded in prose because
-- the sequence is the instructive part.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE DEFECT
-- ══════════════════════════════════════════════════════════════════════════
-- The allocator summed length(rendered_text) while the caller receives the whole
-- JSON envelope. Every locator, citation, provenance basis, score, timestamp and
-- coverage field is per-result overhead the budget never counted:
--
--   declared   actual serialized   over by
--     2000          3454            73%
--     4000          4470            12%
--     8000         10214            28%
--    16000         19330            21%
--
-- The overshoot SCALES WITH RESULT COUNT, so it is worst exactly when the
-- context window is tightest. budget_used reported a number that was not the
-- number that arrived -- a field reporting success about something it did not
-- measure.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THREE ITERATIONS, AND WHY THE THIRD IS DIFFERENT
-- ══════════════════════════════════════════════════════════════════════════
-- 70 budgeted on the real serialized length of shell-plus-results. Correct for
-- the common case; still breached below ~1500 because the shell alone costs
-- ~940 characters before any result exists.
--
-- 71 predicted an envelope floor from the shell and flagged budgets beneath it.
-- Still breached at the boundary: the mandatory top-match result carries ~600
-- characters of METADATA regardless of how short its text is trimmed, so a
-- 1000-char budget against a 943-char shell looked feasible and produced 1555.
--
-- 72 stopped predicting. It MEASURES the finished output and declares the
-- condition if it exceeds. The general lesson, worth more than the fix:
-- predicting a limit is a model of the output and a model can be wrong;
-- measuring the output cannot be. The check is post-hoc against the serialized
-- result, so it holds if the shell changes, if the per-result shape changes, or
-- if someone later adds a field and forgets to account for it.
--
-- ══════════════════════════════════════════════════════════════════════════
-- BEHAVIOUR
-- ══════════════════════════════════════════════════════════════════════════
--   * Conforming requests: output never exceeds the declared budget.
--   * Infeasible requests: status becomes budget_exceeded_minimum, the reason
--     names the true minimum, and the response is returned OVERSIZED rather than
--     withheld. A caller with too small a budget is better served by an answer
--     they can see is oversized than by silence they must diagnose.
--   * envelope_floor_chars is always emitted, so a caller can size correctly
--     instead of discovering the floor by overrunning it.
--
-- Same principle as reporting not_evaluated rather than zero findings: an
-- unsatisfiable request must be distinguishable from a satisfied one, and the
-- distinction must come from what happened rather than what was expected.
--
-- MONOTONICITY PRESERVED, verified rather than assumed. The constraint has two
-- halves and a naive budget fix could trade one violation for the other. Across
-- all six budget pairs after the change: zero units lost at any larger budget.
--
-- NO TEMP TABLES, deliberately. A first attempt used them and failed with
-- "relation already exists" when called twice in one transaction, reintroducing
-- the exact defect an earlier migration exists to fix. Third time in one session
-- that a rewrite undid an earlier correction, in every case because the existing
-- fix was not read first.
--
-- KNOWN LIMIT, stated rather than left to be discovered: the budget is in
-- CHARACTERS and a model's context window is in TOKENS. They diverge for
-- multibyte content and no test covers it. Closing that means deciding which
-- unit the budget is denominated in, which is a contract change rather than a
-- bug fix.

create or replace function retrieve_context(
  p_principal_id uuid, p_query text, p_query_embedding vector default null::vector,
  p_budget_chars integer default 8000, p_max_units integer default 20
) returns jsonb language plpgsql security definer
set search_path to 'public','extensions' as $function$
declare
  v_out jsonb; v_shell jsonb; v_results jsonb := '[]'::jsonb; v_row record;
  v_cand jsonb; v_trial jsonb; v_overhead int; v_used int := 0;
  v_kept int := 0; v_visible int; v_matched int := 0; v_first boolean := true;
  v_evaluated boolean; v_complete boolean; v_emb boolean; v_tsq tsquery;
  v_actual int; v_min_result int := 0;
begin
  if p_principal_id is null then raise exception 'retrieve_context requires a principal'; end if;
  if not exists (select 1 from principals where id=p_principal_id and active) then
    raise exception 'principal % is not active', p_principal_id; end if;

  v_tsq := case when p_query is null or length(trim(p_query))=0 then null
                else websearch_to_tsquery('english', p_query) end;

  select count(*) into v_visible from retrieval_units ru
   where ru.invalidated_at is null and ru.record_status='current'
     and can_read_row(ru.owner, ru.visibility, ru.workstream, p_principal_id);

  select exists (select 1 from retrieval_embeddings e
                 join retrieval_units ru on ru.id=e.retrieval_unit_id
                 where ru.invalidated_at is null and ru.record_status='current'
                   and can_read_row(ru.owner,ru.visibility,ru.workstream,p_principal_id)
                   and e.stale_at is null and e.embedding is not null) into v_emb;

  select coalesce(bool_and(t.queryable_by_this_runtime), true) into v_complete
    from retrieval_topology t where t.status='current';

  v_evaluated := (v_visible > 0 and v_tsq is not null);

  v_shell := jsonb_build_object(
    'retrieval_status', case when not v_evaluated then 'not_evaluated'
                             when v_complete then 'evaluated'
                             else 'evaluated_partial_coverage' end,
    'reason', case when v_visible=0 then 'no_retrieval_units_visible_to_principal'
                   when v_tsq is null then 'empty_query'
                   when not v_complete then 'one_or_more_advertised_stores_not_queried'
                   else null end,
    'mode', case when not v_evaluated then null
                 when p_query_embedding is not null and v_emb then 'hybrid'
                 else 'fts_only' end,
    'principal_id', p_principal_id, 'units_visible', v_visible,
    'units_matched', 0, 'units_returned', 0, 'embeddings_available', v_emb,
    'budget_chars', p_budget_chars, 'budget_used', 0,
    'envelope_floor_chars', 0, 'truncated', false,
    'global_completeness', v_complete,
    'topology', jsonb_build_object('schema_version','1','stores', coalesce((
        select jsonb_agg(jsonb_build_object('store_key',t.store_key,'store_role',t.store_role,
                 'coverage_state', case when t.queryable_by_this_runtime
                    then case when v_evaluated then 'queried' else 'not_queried' end
                    else t.default_coverage_state end) order by t.store_key)
        from retrieval_topology t where t.status='current'), '[]'::jsonb)),
    'unqueried_stores', coalesce((select jsonb_agg(t.store_key order by t.store_key)
        from retrieval_topology t where t.status='current'
         and not t.queryable_by_this_runtime), '[]'::jsonb),
    'results', '[]'::jsonb);
  v_overhead := length(v_shell::text);

  for v_row in
    with vis as (select ru.* from retrieval_units ru
      where ru.invalidated_at is null and ru.record_status='current'
        and can_read_row(ru.owner,ru.visibility,ru.workstream,p_principal_id)),
    fts as (select v.id, ts_rank(v.fts,v_tsq) s,
                   row_number() over (order by ts_rank(v.fts,v_tsq) desc, v.id) r
            from vis v where v_tsq is not null and v.fts @@ v_tsq),
    vec as (select v.id, 1-(e.embedding <=> p_query_embedding) s,
                   row_number() over (order by (e.embedding <=> p_query_embedding) asc, v.id) r
            from vis v join retrieval_embeddings e on e.retrieval_unit_id=v.id
            where p_query_embedding is not null and e.stale_at is null
              and e.embedding is not null),
    ranked as (select coalesce(f.id,x.id) id,
                      coalesce(1.0/(60+f.r),0)+coalesce(1.0/(60+x.r),0) rrf,
                      f.s fts_score, x.s vec_score
               from fts f full outer join vec x on x.id=f.id)
    select r.rrf, r.fts_score, r.vec_score, count(*) over () as total_matched,
           v.exact_locator, v.source_relation, v.source_id, v.unit_kind, v.ordinal,
           v.workstream, v.provenance_basis, v.citation, v.effective_from, v.rendered_text
    from ranked r join vis v on v.id=r.id
    order by r.rrf desc, r.id limit greatest(p_max_units,0)
  loop
    v_matched := v_row.total_matched;
    v_cand := (to_jsonb(v_row) - 'total_matched') || jsonb_build_object('text_truncated', false);
    v_trial := v_results || jsonb_build_array(v_cand);

    if v_overhead + length(v_trial::text) > p_budget_chars then
      if v_first then
        v_cand := (to_jsonb(v_row) - 'total_matched') || jsonb_build_object(
          'rendered_text', left(v_row.rendered_text,
             greatest(p_budget_chars - v_overhead - 600, 80)),
          'text_truncated', true);
        v_results := jsonb_build_array(v_cand); v_kept := 1;
        v_min_result := length(jsonb_build_array(v_cand)::text);
      end if;
      exit;
    end if;
    v_results := v_trial; v_kept := v_kept + 1; v_first := false;
  end loop;

  select coalesce(sum(length(x->>'rendered_text')),0) into v_used
    from jsonb_array_elements(v_results) x;

  v_out := v_shell || jsonb_build_object(
    'units_matched', v_matched, 'units_returned', v_kept, 'budget_used', v_used,
    'envelope_floor_chars', v_overhead + v_min_result,
    'truncated', v_matched > v_kept, 'results', v_results);

  v_actual := length(v_out::text);
  if v_actual > p_budget_chars then
    v_out := v_out || jsonb_build_object(
      'retrieval_status', 'budget_exceeded_minimum',
      'reason', 'the smallest possible response for this query is ' || v_actual
             || ' chars, which exceeds the requested budget of ' || p_budget_chars
             || '. Response returned oversized rather than withheld; raise the '
             || 'budget above envelope_floor_chars to receive a conforming one.');
  end if;

  return v_out;
end; $function$;
