-- Owner/visibility columns (generic pattern): separate owner (orientation axis) from
-- visibility (privacy layer). owner identifies whose working set a row belongs to for
-- session-boot orientation purposes; visibility is a future privacy control, defaulting
-- to a permissive value until a real access model is needed. Do not conflate the two --
-- a row can be owned by one principal yet still be broadly visible, and vice versa later.

CREATE TYPE public.visibility_level AS ENUM ('private', 'shared');

-- Repeat per knowledge/domain table:
-- ALTER TABLE public.<table> ADD COLUMN owner uuid REFERENCES public.principals(id) DEFAULT <bootstrap_owner_id>;
-- ALTER TABLE public.<table> ADD COLUMN visibility public.visibility_level NOT NULL DEFAULT 'shared';
-- CREATE INDEX idx_<table>_owner ON public.<table>(owner);

-- Owner-scoped boot surfaces (a view cannot take a parameter, so these are functions):

CREATE OR REPLACE FUNCTION public.is_owner_or_shared(p_row_owner uuid, p_row_visibility public.visibility_level, p_principal_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT p_row_owner = p_principal_id OR p_row_visibility = 'shared';
$function$;

-- Example: owner-scoped ranked-topic surface, wrapping an existing unscoped ranking view.
-- CREATE OR REPLACE FUNCTION public.hot_ranked_for(p_principal_id uuid)
--  RETURNS TABLE(...)
--  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
-- AS $function$
--   SELECT hr.* FROM hot_ranked hr
--   JOIN <owning_table> t ON t.id = hr.<fk_to_owning_table>
--   WHERE public.is_owner_or_shared(t.owner, t.visibility, p_principal_id)
--   ORDER BY hr.score DESC LIMIT 15;
-- $function$;
--
-- REVOKE ALL ON FUNCTION public.hot_ranked_for(uuid) FROM PUBLIC, anon, authenticated;

-- The unscoped underlying view/ranking mechanism remains as a global/admin reference
-- surface; the *_for(p_principal_id) function is the one session-boot logic should call.
