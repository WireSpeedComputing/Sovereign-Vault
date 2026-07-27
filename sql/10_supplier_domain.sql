-- Supplier domain module: suppliers, supplier_orders, supplier_documents.
-- Generic vault-standard pattern: temporal columns, record_status, supersedes
-- self-FK, provenance_basis + citation, provenance_registry registration,
-- RLS default-deny (enabled, no policies; relies on default-privilege revocation
-- for anon/authenticated).
--
-- Business "status" columns are renamed (order_status / doc_status) to avoid
-- colliding with the vault-standard "status" (record_status) column.

CREATE TABLE public.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company text NOT NULL UNIQUE,
  contact_name text,
  ingredient text,
  tmla_status text,
  moq text,
  lead_time text,
  notes text,
  address text,
  email text,
  phone text,
  role text,
  parent_company text,
  agreement_type text,
  agreement_status text,
  agreement_doc_path text,
  verified boolean NOT NULL DEFAULT false,
  source_email_id text,
  source_email_date date,
  -- vault standard columns
  status record_status NOT NULL DEFAULT 'proposed',
  supersedes uuid REFERENCES public.suppliers(id),
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
COMMENT ON COLUMN public.suppliers.verified IS 'false = sourced from filesystem/filename, not yet confirmed against ground-truth email. true = confirmed against email (source_email_id/date populated).';

CREATE TABLE public.supplier_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  po_number text,
  vendor_id uuid REFERENCES public.suppliers(id),
  brand_id uuid REFERENCES public.suppliers(id),
  ingredient text,
  order_date date,
  qty text,
  unit_price numeric,
  total numeric,
  currency text DEFAULT 'USD',
  incoterms text,
  ship_to text,
  payment_date date,
  payment_ref text,
  order_status text,
  doc_path text,
  verified boolean NOT NULL DEFAULT false,
  source_email_id text,
  source_email_date date,
  -- vault standard columns
  status record_status NOT NULL DEFAULT 'proposed',
  supersedes uuid REFERENCES public.supplier_orders(id),
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
COMMENT ON TABLE public.supplier_orders IS 'Procurement trail. vendor_id = supplier the order was placed with/paid. brand_id = brand/IP owner of the ingredient when different from vendor_id.';
COMMENT ON COLUMN public.supplier_orders.order_status IS 'Free-text procurement status (ordered/paid/shipped/etc). Not to be confused with status (record_status).';

CREATE TABLE public.supplier_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id),
  doc_type text NOT NULL,
  title text NOT NULL,
  file_path text NOT NULL,
  doc_date date,
  doc_status text,
  verified boolean NOT NULL DEFAULT false,
  source_email_id text,
  source_email_date date,
  notes text,
  -- vault standard columns
  status record_status NOT NULL DEFAULT 'proposed',
  supersedes uuid REFERENCES public.supplier_documents(id),
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
COMMENT ON TABLE public.supplier_documents IS 'Reference/agreement/asset document index (license agreement, NDA, claims doc, certificate of analysis, studies, brand assets). Transactional docs live in supplier_orders instead.';

CREATE INDEX idx_supplier_orders_vendor ON public.supplier_orders(vendor_id);
CREATE INDEX idx_supplier_orders_brand ON public.supplier_orders(brand_id);
CREATE INDEX idx_supplier_documents_supplier ON public.supplier_documents(supplier_id);

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_documents ENABLE ROW LEVEL SECURITY;

INSERT INTO public.provenance_registry (table_name, requires_citation_unless) VALUES
  ('suppliers', ARRAY['human_direct']),
  ('supplier_orders', ARRAY['human_direct']),
  ('supplier_documents', ARRAY['human_direct']);

CREATE TRIGGER trg_enforce_provenance_suppliers BEFORE INSERT OR UPDATE ON public.suppliers FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance();
CREATE TRIGGER trg_agent_no_self_attest_suppliers BEFORE INSERT OR UPDATE ON public.suppliers FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_cannot_self_attest();

CREATE TRIGGER trg_enforce_provenance_supplier_orders BEFORE INSERT OR UPDATE ON public.supplier_orders FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance();
CREATE TRIGGER trg_agent_no_self_attest_supplier_orders BEFORE INSERT OR UPDATE ON public.supplier_orders FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_cannot_self_attest();

CREATE TRIGGER trg_enforce_provenance_supplier_documents BEFORE INSERT OR UPDATE ON public.supplier_documents FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance();
CREATE TRIGGER trg_agent_no_self_attest_supplier_documents BEFORE INSERT OR UPDATE ON public.supplier_documents FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_cannot_self_attest();
