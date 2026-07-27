-- Hot-index eviction defect: hot_touch()'s promote-from-staging step deleted the
-- lowest-scoring memory_hot_index row whenever a fixed row cap (15) was reached, silently
-- losing history. A hot/attention index must never delete a ranked row merely because a
-- presentation-time cap was reached -- deleting to stay under a cap destroys history a
-- future model or a returning user might need.
--
-- Fix: remove the cap-check-and-delete step from the write path entirely. The index table
-- grows unbounded; the cap is enforced only in the read-side ranking view (memory_hot_ranked
-- already applies LIMIT 15). The view is the cap; the table never deletes.
--
-- No backfill/migration recovers rows already evicted before this fix -- that history is
-- genuinely gone. Note any such loss window honestly in STATUS.md rather than proceeding as
-- if history were intact.

CREATE OR REPLACE FUNCTION public.hot_touch(p_topic_key text, p_memory_id uuid, p_summary text, p_workstream text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update memories set hot_touched = true where id = p_memory_id;

  update memory_hot_index set touch_count = touch_count + 1, last_touched = now()
   where topic_key = p_topic_key;
  if found then return 'bumped'; end if;

  if exists (select 1 from memory_hot_staging where topic_key = p_topic_key) then
    insert into memory_hot_index (memory_id, topic_key, summary, workstream, touch_count, last_touched)
    values (p_memory_id, p_topic_key, left(p_summary,200), p_workstream, 2, now());
    delete from memory_hot_staging where topic_key = p_topic_key;
    return 'promoted';
  end if;

  insert into memory_hot_staging (topic_key, memory_id, summary, workstream)
  values (p_topic_key, p_memory_id, left(p_summary,200), p_workstream)
  on conflict (topic_key) do nothing;
  return 'staged';
end; $function$;
