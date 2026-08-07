-- 25_public_request_has_capability.sql
--
-- MIGRATION: 38_public_request_has_capability_wrapper
--
-- APPLIED as deployment migration 38, 2026-08-07
-- (20260807164705_38_public_request_has_capability_wrapper).
--
-- Transcribed from the applied definition read back out of the deployment with
-- pg_get_functiondef(), not retyped from a description. The body, volatility,
-- search_path and grants below are what is actually running.
--
-- ── WHY THIS EXISTS ────────────────────────────────────────────────────────
-- Grants and PostgREST reachability are independent. sql/23 grants EXECUTE on
-- vault_auth.request_has_capability to `authenticated` and USAGE on the schema,
-- which makes it callable — but PostgREST only exposes functions in the schemas
-- configured as the Data API, and vault_auth is deliberately not one of them.
-- The inner function was therefore granted and unreachable at the same time.
-- This wrapper puts a reachable entry point in `public` without exposing the
-- schema behind it.
--
-- ── WHY SECURITY INVOKER, DELIBERATELY ─────────────────────────────────────
-- The absence of SECURITY DEFINER here is load-bearing, not an oversight.
--
--   1. It adds no privilege. The caller already holds USAGE on vault_auth and
--      EXECUTE on the inner function, so a definer wrapper would grant nothing
--      that is not already held.
--   2. It preserves session_user. vault_auth._trusted_request_claims() returns
--      claims ONLY when session_user is `authenticator`, which is how a genuine
--      PostgREST request is distinguished from an administrative session that
--      has fabricated request.jwt.claims. SECURITY DEFINER rewrites current_user
--      and would break that discrimination.
--
-- Anyone tempted to "harden" this by adding SECURITY DEFINER would invert the
-- property it exists to protect. Do not.
--
-- search_path is pinned to 'public', 'vault_auth' rather than left empty
-- because the body calls a vault_auth function by qualified name and takes a
-- public type; pinning it closes the search_path-injection path that
-- sql/08_advisor_fixes.sql addressed elsewhere.

CREATE OR REPLACE FUNCTION public.request_has_capability(
  p_resource_scope text,
  p_permission capability_permission
)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'vault_auth'
AS $function$
  SELECT vault_auth.request_has_capability(p_resource_scope, p_permission);
$function$;

COMMENT ON FUNCTION public.request_has_capability(text, capability_permission) IS
  'API-reachable entry point for capability checks. Thin SECURITY INVOKER wrapper over vault_auth.request_has_capability so vault_auth stays unexposed to PostgREST. Returns false, never null, for unresolved identity.';

-- Matches the deployed ACL exactly: postgres, service_role and authenticated
-- hold EXECUTE; PUBLIC and anon do not.
REVOKE ALL ON FUNCTION public.request_has_capability(text, capability_permission)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.request_has_capability(text, capability_permission)
  TO authenticated, service_role;
