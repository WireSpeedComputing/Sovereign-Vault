-- 29_retrieval_embedding_backlog.sql
--
-- MIGRATION: 36_retrieval_embedding_backlog
--
-- APPLIED as deployment migration 36_retrieval_embedding_backlog
-- (20260807145802). Transcribed from the applied definitions read back with
-- pg_get_functiondef(), not retyped from a description.
--
-- ── WHY THIS IS sql/29 AND NOT sql/2x-something-36-ish ─────────────────────
-- There are TWO deployment migrations named 36. Distinct version timestamps, so
-- Supabase is unbothered, but the names collide:
--
--   20260803165505  36_vault_auth_binding_fk_indexes   -> filed inside sql/23
--   20260807145802  36_retrieval_embedding_backlog     -> this file
--
-- The first is already folded into sql/23_identity_capability_enforcement.sql.
-- Repo file numbers track apply order in this repo, not the deployment's
-- migration names, so this one takes the next free number rather than fighting
-- for 36. The mapping above is the thing to trust.
--
-- ── THIS FILE IS LOAD-BEARING ──────────────────────────────────────────────
-- retrieval_embedding_backlog() is the RPC the deployed `embed-retrieval-units`
-- edge function calls to find work. As of 2026-08-07 that function has embedded
-- 75 of 129 live units.
--
-- Until this file existed, a fresh install from this repo produced a database
-- where that edge function returns 500 on a missing RPC. The schema would look
-- complete and replay clean; the embedding pipeline would simply be broken, and
-- nothing in the repo said so. That is the precise failure mode `pending/` and
-- the drift check in tests/migration_drift.sh exist to prevent -- this file was
-- the third instance of applied-without-a-file, after Migrations A and B.
--
-- ── RELATIONSHIP TO sql/27 ─────────────────────────────────────────────────
-- sql/27 marks an embedding stale when its retrieval unit is invalidated.
-- coverage counts only `stale_at is null` rows as embedded, and backlog re-emits
-- any unit whose embedding is missing, null, or whose text hash drifted. The two
-- agree: an invalidated-then-reprojected unit reappears as backlog rather than
-- silently counting as covered.
--
-- ── ON EMBEDDINGS AND SQL ──────────────────────────────────────────────────
-- Note what these functions do NOT do: they never compute an embedding. They
-- report what needs embedding and what has been embedded. Vectors are produced
-- client-side by the edge function and written back. That is upstream #70's
-- guidance ("never compute embeddings in SQL") and this deployment complies.

-- Work queue for the embedding pipeline. Emits units that have no embedding for
-- the given model, have a null vector, or whose rendered text has drifted from
-- the hash the vector was computed over.
CREATE OR REPLACE FUNCTION public.retrieval_embedding_backlog(
  p_model_provider text DEFAULT 'supabase'::text,
  p_model_name text DEFAULT 'gte-small'::text,
  p_model_version text DEFAULT '1'::text,
  p_limit integer DEFAULT 50
)
 RETURNS TABLE(unit_id uuid, rendered_text text, text_hash text, reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select ru.id,
         ru.rendered_text,
         encode(digest(ru.rendered_text,'sha256'),'hex') as text_hash,
         case when e.id is null then 'missing' else 'hash_drift' end as reason
  from retrieval_units ru
  left join retrieval_embeddings e
    on e.retrieval_unit_id = ru.id
   and e.model_provider = p_model_provider
   and e.model_name     = p_model_name
   and e.model_version  = p_model_version
  where ru.invalidated_at is null
    and ru.record_status = 'current'
    and (
      e.id is null
      or e.embedding is null
      or e.rendered_text_hash is distinct from encode(digest(ru.rendered_text,'sha256'),'hex')
    )
  order by ru.generated_at
  limit greatest(p_limit, 0);
$function$;

-- Coverage receipt. semantic_recall_available is the field that matters: it is
-- what distinguishes "hybrid retrieval is genuinely available" from "we have an
-- embeddings table", which is the same evaluated/not_evaluated distinction
-- retrieve_context() draws in its own envelope.
CREATE OR REPLACE FUNCTION public.retrieval_embedding_coverage(
  p_model_provider text DEFAULT 'supabase'::text,
  p_model_name text DEFAULT 'gte-small'::text,
  p_model_version text DEFAULT '1'::text
)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select jsonb_build_object(
    'model', p_model_provider||'/'||p_model_name||'/'||p_model_version,
    'live_units', (select count(*) from retrieval_units
                    where invalidated_at is null and record_status='current'),
    'embedded_current', (
      select count(*) from retrieval_units ru
      join retrieval_embeddings e on e.retrieval_unit_id = ru.id
       and e.model_provider=p_model_provider and e.model_name=p_model_name
       and e.model_version=p_model_version
      where ru.invalidated_at is null and ru.record_status='current'
        and e.embedding is not null and e.stale_at is null
        and e.rendered_text_hash = encode(digest(ru.rendered_text,'sha256'),'hex')),
    'backlog', (select count(*) from retrieval_embedding_backlog(
                  p_model_provider, p_model_name, p_model_version, 1000000)),
    'semantic_recall_available', (
      select exists (select 1 from retrieval_embeddings
                     where embedding is not null and stale_at is null
                       and model_provider=p_model_provider and model_name=p_model_name
                       and model_version=p_model_version))
  );
$function$;

-- Matches the deployed ACL exactly: postgres and service_role only. The edge
-- function calls these with the service-role key; no end-user role reaches them.
REVOKE ALL ON FUNCTION public.retrieval_embedding_backlog(text, text, text, integer)
  FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.retrieval_embedding_coverage(text, text, text)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.retrieval_embedding_backlog(text, text, text, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.retrieval_embedding_coverage(text, text, text)
  TO service_role;
