-- Optional candidate: requeue stale embedding cache rows.
-- Baseline: public sql/29 at db529cd239c708d40df0005184e734bf4feda074.
-- No applied-migration claim, automatic deployment or embedding inference.
-- Existing function identity, owner and ACL are retained; no GRANT is added.
-- Refuse unknown bodies/security modes instead of overwriting deployment adapters.
BEGIN;
DO $guard$
DECLARE p record;
BEGIN
  SELECT f.prosrc,f.prosecdef,f.provolatile,f.proconfig,l.lanname INTO p
  FROM pg_proc f JOIN pg_language l ON l.oid=f.prolang
  WHERE f.oid=to_regprocedure('public.retrieval_embedding_backlog(text,text,text,integer)');
  IF NOT FOUND OR NOT p.prosecdef OR p.provolatile<>'s' OR p.lanname<>'sql'
     OR p.proconfig IS DISTINCT FROM ARRAY['search_path=public, extensions']::text[]
     OR pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(replace(p.prosrc,E'\r\n',E'\n'),'UTF8')),'hex') NOT IN ('fe2708ac8fb6db450dff655db92a6db2ecdcf05411111023eec88afe1c0e74f2','925a0479791aafd5c8d92252a253c3e4acc43159fa077765694a271079a748bf') THEN
    RAISE EXCEPTION 'Unknown embedding backlog baseline; compare definitions before applying.';
  END IF;
END
$guard$;

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
         case when e.id is null then 'missing'
              when e.stale_at is not null then 'stale'
              else 'hash_drift' end as reason
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
      or e.stale_at is not null
      or e.rendered_text_hash is distinct from encode(digest(ru.rendered_text,'sha256'),'hex')
    )
  order by ru.generated_at
  limit greatest(p_limit, 0);
$function$;
COMMIT;
