-- Owner/visibility columns: separate owner (orientation axis) from visibility (privacy
-- layer). owner identifies whose working set a row belongs to for session-boot
-- orientation purposes; visibility is a future privacy control, defaulting to a
-- permissive value until a real access model is needed. Do not conflate the two -- a row
-- can be owned by one principal yet still be broadly visible, and vice versa later.
--
-- owner is left with no default here deliberately: which principal bootstraps as the
-- default owner for pre-existing rows is deployment-specific data, not schema, and does
-- not belong in this repo (see README "Rule 0"). After applying this file, a deployment
-- should run its own one-time backfill, e.g.:
--   ALTER TABLE public.memories ALTER COLUMN owner SET DEFAULT '<your bootstrap principal id>';
--   UPDATE public.memories SET owner = '<your bootstrap principal id>' WHERE owner IS NULL;
-- (repeat per table). A constant DEFAULT set via ALTER TABLE backfills all existing rows
-- in one fast metadata-only operation on modern Postgres -- no need for a separate UPDATE
-- if the DEFAULT is set before or via the same ALTER TABLE that adds the column.

CREATE TYPE public.visibility_level AS ENUM ('private', 'shared');

ALTER TABLE public.memories ADD COLUMN owner uuid REFERENCES public.principals(id);
ALTER TABLE public.memories ADD COLUMN visibility public.visibility_level NOT NULL DEFAULT 'shared';
CREATE INDEX idx_memories_owner ON public.memories(owner);

ALTER TABLE public.wiki_pages ADD COLUMN owner uuid REFERENCES public.principals(id);
ALTER TABLE public.wiki_pages ADD COLUMN visibility public.visibility_level NOT NULL DEFAULT 'shared';
CREATE INDEX idx_wiki_pages_owner ON public.wiki_pages(owner);

-- Any additional domain-specific tables (e.g. the example module in sql/10-12) should get
-- the same two columns and index, following the pattern above.

-- Owner-scoped boot surfaces (a view cannot take a parameter, so these are functions):

CREATE OR REPLACE FUNCTION public.is_owner_or_shared(p_row_owner uuid, p_row_visibility public.visibility_level, p_principal_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT p_row_owner = p_principal_id OR p_row_visibility = 'shared';
$function$;

REVOKE ALL ON FUNCTION public.is_owner_or_shared(uuid, public.visibility_level, uuid) FROM PUBLIC, anon, authenticated;

-- Owner-scoped wrapper around the existing hot-topic ranking view (05/06-era memory_hot_ranked).
-- The unscoped view remains as a global/admin reference surface; this function is what
-- session-boot logic should call.
CREATE OR REPLACE FUNCTION public.memory_hot_ranked_for(p_principal_id uuid)
 RETURNS TABLE(
  id uuid, memory_id uuid, topic_key text, summary text, workstream text,
  touch_count integer, last_touched timestamptz, created_at timestamptz, score numeric
 )
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT mhr.id, mhr.memory_id, mhr.topic_key, mhr.summary, mhr.workstream,
         mhr.touch_count, mhr.last_touched, mhr.created_at, mhr.score
  FROM memory_hot_ranked mhr
  JOIN memories m ON m.id = mhr.memory_id
  WHERE public.is_owner_or_shared(m.owner, m.visibility, p_principal_id)
  ORDER BY mhr.score DESC
  LIMIT 15;
$function$;

REVOKE ALL ON FUNCTION public.memory_hot_ranked_for(uuid) FROM PUBLIC, anon, authenticated;

-- Owner-scoped wrapper around the existing upcoming-deadlines view (see docs/01-architecture.md).
CREATE OR REPLACE FUNCTION public.deadlines_upcoming_for(p_principal_id uuid)
 RETURNS TABLE(
  id uuid, content text, workstream text, due_date timestamptz, source_agent text,
  overdue boolean, days_until integer
 )
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT m.id, m.content, m.workstream, m.due_date, m.source_agent,
         m.due_date < now() AS overdue,
         EXTRACT(day FROM m.due_date - now())::integer AS days_until
  FROM memories m
  WHERE m.due_date IS NOT NULL AND m.due_status = 'pending' AND m.status = 'current'
    AND m.due_date < (now() + interval '14 days')
    AND public.is_owner_or_shared(m.owner, m.visibility, p_principal_id)
  ORDER BY m.due_date;
$function$;

REVOKE ALL ON FUNCTION public.deadlines_upcoming_for(uuid) FROM PUBLIC, anon, authenticated;
