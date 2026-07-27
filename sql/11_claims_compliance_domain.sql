-- Claims/compliance module: products, ingredients, product_ingredients,
-- ingredient_claims, language_rules. Generic pattern for tracking locked
-- formula versions, ingredient dosing, per-ingredient authorized/prohibited
-- claims, and a language-rule set that drives compliance_check().

CREATE TYPE public.ingredient_claim_status AS ENUM ('authorized', 'conditional', 'prohibited', 'retired');
CREATE TYPE public.language_rule_type AS ENUM ('banned_phrase', 'required_phrase', 'approved_phrase', 'positioning_rule');
CREATE TYPE public.language_rule_scope AS ENUM ('global', 'product', 'ingredient');
CREATE TYPE public.compliance_finding_kind AS ENUM ('banned_language', 'unauthorized_claim', 'dose_mismatch', 'stale_figure', 'missing_disclaimer');
CREATE TYPE public.compliance_severity AS ENUM ('low', 'medium', 'high', 'critical');

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  formula_version text NOT NULL,
  locked_on date,
  product_status text,
  -- vault standard columns
  status record_status NOT NULL DEFAULT 'proposed',
  supersedes uuid REFERENCES public.products(id),
  source_kind source_kind NOT NULL DEFAULT 'manual',
  source_agent text,
  source_ref text,
  confidence numeric,
  provenance_basis provenance_basis,
  citation text,
  observed_at timestamptz,
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to timestamptz,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  source_artifact_id uuid REFERENCES public.raw_artifacts(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.products IS 'One row per product per locked formula version.';
COMMENT ON COLUMN public.products.product_status IS 'Free-text lifecycle status (active/draft/discontinued). Not to be confused with status (record_status).';

CREATE TABLE public.ingredients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  canonical_name text NOT NULL UNIQUE,
  is_branded boolean NOT NULL DEFAULT false,
  brand_name text,
  supplier_id uuid REFERENCES public.suppliers(id),
  form text,
  notes text,
  -- vault standard columns
  status record_status NOT NULL DEFAULT 'proposed',
  supersedes uuid REFERENCES public.ingredients(id),
  source_kind source_kind NOT NULL DEFAULT 'manual',
  source_agent text,
  source_ref text,
  confidence numeric,
  provenance_basis provenance_basis,
  citation text,
  observed_at timestamptz,
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to timestamptz,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  source_artifact_id uuid REFERENCES public.raw_artifacts(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.ingredients IS 'One row per distinct ingredient.';

CREATE TABLE public.product_ingredients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id),
  ingredient_id uuid NOT NULL REFERENCES public.ingredients(id),
  dose_amount numeric,
  dose_unit text,
  dose_detail text,
  per_serving int,
  position int,
  -- vault standard columns
  status record_status NOT NULL DEFAULT 'proposed',
  supersedes uuid REFERENCES public.product_ingredients(id),
  source_kind source_kind NOT NULL DEFAULT 'manual',
  source_agent text,
  source_ref text,
  confidence numeric,
  provenance_basis provenance_basis,
  citation text,
  observed_at timestamptz,
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to timestamptz,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  source_artifact_id uuid REFERENCES public.raw_artifacts(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_id, ingredient_id)
);
COMMENT ON TABLE public.product_ingredients IS 'The composition table: one row per ingredient in a product formula, with dose. dose_detail holds elemental equivalents / standardization notes (e.g. "3% rosavins").';

CREATE TABLE public.ingredient_claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ingredient_id uuid NOT NULL REFERENCES public.ingredients(id),
  product_id uuid REFERENCES public.products(id),
  claim_text text NOT NULL,
  claim_status public.ingredient_claim_status NOT NULL,
  condition text,
  min_dose_amount numeric,
  min_dose_unit text,
  authority text,
  substantiation_doc_id uuid REFERENCES public.supplier_documents(id),
  -- vault standard columns
  status record_status NOT NULL DEFAULT 'proposed',
  supersedes uuid REFERENCES public.ingredient_claims(id),
  source_kind source_kind NOT NULL DEFAULT 'manual',
  source_agent text,
  source_ref text,
  confidence numeric,
  provenance_basis provenance_basis,
  citation text,
  observed_at timestamptz,
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to timestamptz,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  source_artifact_id uuid REFERENCES public.raw_artifacts(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.ingredient_claims IS 'Per-ingredient (optionally per-product) claim authorization. product_id NULL = applies to the ingredient generally. Every row requires a citation (provenance_registry: requires_citation_unless = {}).';

CREATE TABLE public.language_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_type public.language_rule_type NOT NULL,
  pattern text NOT NULL,
  scope public.language_rule_scope NOT NULL,
  scope_ref uuid,
  rationale text NOT NULL,
  replacement text,
  authority text,
  finding_kind public.compliance_finding_kind NOT NULL DEFAULT 'banned_language'
    CHECK (finding_kind IN ('banned_language', 'stale_figure', 'missing_disclaimer')),
  severity public.compliance_severity NOT NULL DEFAULT 'medium',
  -- vault standard columns
  status record_status NOT NULL DEFAULT 'proposed',
  supersedes uuid REFERENCES public.language_rules(id),
  source_kind source_kind NOT NULL DEFAULT 'manual',
  source_agent text,
  source_ref text,
  confidence numeric,
  provenance_basis provenance_basis,
  citation text,
  observed_at timestamptz,
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to timestamptz,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  source_artifact_id uuid REFERENCES public.raw_artifacts(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.language_rules IS 'pattern is a POSIX regex (case-insensitive match). rule_type is the authoring taxonomy; finding_kind is what compliance_check() emits (decoupled so positioning/banned-phrase rules can drive banned_language or stale_figure). Every row requires a citation.';
COMMENT ON COLUMN public.language_rules.pattern IS 'For required_phrase rules, a finding is raised when the pattern is ABSENT from input; for banned_phrase/positioning_rule, when PRESENT.';

CREATE INDEX idx_product_ingredients_product ON public.product_ingredients(product_id);
CREATE INDEX idx_product_ingredients_ingredient ON public.product_ingredients(ingredient_id);
CREATE INDEX idx_ingredient_claims_ingredient ON public.ingredient_claims(ingredient_id);
CREATE INDEX idx_ingredient_claims_product ON public.ingredient_claims(product_id);
CREATE INDEX idx_ingredient_claims_substantiation ON public.ingredient_claims(substantiation_doc_id);
CREATE INDEX idx_ingredients_supplier ON public.ingredients(supplier_id);
CREATE INDEX idx_language_rules_scope_ref ON public.language_rules(scope_ref);

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ingredient_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.language_rules ENABLE ROW LEVEL SECURITY;

INSERT INTO public.provenance_registry (table_name, requires_citation_unless) VALUES
  ('products', ARRAY['human_direct']),
  ('ingredients', ARRAY['human_direct']),
  ('product_ingredients', ARRAY['human_direct']),
  ('ingredient_claims', ARRAY[]::text[]),
  ('language_rules', ARRAY[]::text[]);

CREATE TRIGGER trg_enforce_provenance_products BEFORE INSERT OR UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance();
CREATE TRIGGER trg_agent_no_self_attest_products BEFORE INSERT OR UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_cannot_self_attest();

CREATE TRIGGER trg_enforce_provenance_ingredients BEFORE INSERT OR UPDATE ON public.ingredients FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance();
CREATE TRIGGER trg_agent_no_self_attest_ingredients BEFORE INSERT OR UPDATE ON public.ingredients FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_cannot_self_attest();

CREATE TRIGGER trg_enforce_provenance_product_ingredients BEFORE INSERT OR UPDATE ON public.product_ingredients FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance();
CREATE TRIGGER trg_agent_no_self_attest_product_ingredients BEFORE INSERT OR UPDATE ON public.product_ingredients FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_cannot_self_attest();

CREATE TRIGGER trg_enforce_provenance_ingredient_claims BEFORE INSERT OR UPDATE ON public.ingredient_claims FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance();
CREATE TRIGGER trg_agent_no_self_attest_ingredient_claims BEFORE INSERT OR UPDATE ON public.ingredient_claims FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_cannot_self_attest();

CREATE TRIGGER trg_enforce_provenance_language_rules BEFORE INSERT OR UPDATE ON public.language_rules FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance();
CREATE TRIGGER trg_agent_no_self_attest_language_rules BEFORE INSERT OR UPDATE ON public.language_rules FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_cannot_self_attest();
