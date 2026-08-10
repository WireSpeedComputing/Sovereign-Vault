-- 63_domain_owner_visibility_parity.sql
--
-- Turns an instruction into a mechanism.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE DEFECT
-- ══════════════════════════════════════════════════════════════════════════
-- sql/14 adds owner and visibility to memories and wiki_pages, then says:
--
--   "Any additional domain-specific tables (e.g. the example module in
--    sql/10-12) should get the same two columns and index, following the
--    pattern above."
--
-- That is an instruction to a human placed where code belongs. Someone
-- followed it on the deployment; a fresh install does not, because a comment
-- cannot run. Measured: 11 tables carry the columns live, 2 in a fresh build.
--
-- Nothing detected it. The drift checker compares MIGRATION INVENTORIES and
-- says so plainly in its own header -- it asks whether every applied migration
-- has a stored body, never whether the resulting SCHEMA SHAPES match. So an
-- entire class of divergence is structurally invisible to it: a deployment can
-- carry columns, indexes, constraints or defaults that no repo file creates,
-- and every gate reports clean.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY IT MATTERS MORE THAN IT LOOKS
-- ══════════════════════════════════════════════════════════════════════════
-- owner and visibility are AUTHORIZATION INPUTS. can_read_row() and the RLS
-- policies compose over them. A restored deployment missing them on the domain
-- tables cannot express row-level access on that data at all -- and would not
-- fail loudly, because no policy references those tables yet. It would simply
-- be unable to, silently, on the day someone tried.
--
-- Same shape as the two findings that preceded it: the compliance ruleset that
-- existed only as deployment data so a fresh install had no detection, and the
-- scope registry that was empty so the authority report returned zero rows and
-- read as clean. Three variants of one thing -- a control whose PREREQUISITE
-- lives outside the artifact.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE GENERALISABLE RULE
-- ══════════════════════════════════════════════════════════════════════════
-- A repository comment saying a future migration "should" do something is not
-- a mechanism. It is a hope with syntax highlighting. If a rule must hold
-- across tables, express it as code that fails when violated -- or accept that
-- it will hold only where someone happened to read the comment.
--
-- ══════════════════════════════════════════════════════════════════════════
-- IDEMPOTENT BY CONSTRUCTION
-- ══════════════════════════════════════════════════════════════════════════
-- The deployment already carries these columns; this file exists so a FRESH
-- INSTALL matches it. IF NOT EXISTS throughout, so it is safe to apply to
-- either shape and safe to re-apply. No data is touched: owner stays NULL and
-- visibility defaults to the permissive value, exactly as sql/14 establishes,
-- because which principal bootstraps as owner is deployment data and does not
-- belong here.

-- Example domain module (sql/10-12). Present in this repo, so its access
-- columns belong here too rather than being left to a comment.
alter table if exists public.suppliers            add column if not exists owner uuid references public.principals(id);
alter table if exists public.suppliers            add column if not exists visibility public.visibility_level not null default 'shared';
alter table if exists public.supplier_orders      add column if not exists owner uuid references public.principals(id);
alter table if exists public.supplier_orders      add column if not exists visibility public.visibility_level not null default 'shared';
alter table if exists public.supplier_documents   add column if not exists owner uuid references public.principals(id);
alter table if exists public.supplier_documents   add column if not exists visibility public.visibility_level not null default 'shared';
alter table if exists public.products             add column if not exists owner uuid references public.principals(id);
alter table if exists public.products             add column if not exists visibility public.visibility_level not null default 'shared';
alter table if exists public.ingredients          add column if not exists owner uuid references public.principals(id);
alter table if exists public.ingredients          add column if not exists visibility public.visibility_level not null default 'shared';
alter table if exists public.product_ingredients  add column if not exists owner uuid references public.principals(id);
alter table if exists public.product_ingredients  add column if not exists visibility public.visibility_level not null default 'shared';
alter table if exists public.ingredient_claims    add column if not exists owner uuid references public.principals(id);
alter table if exists public.ingredient_claims    add column if not exists visibility public.visibility_level not null default 'shared';
alter table if exists public.language_rules       add column if not exists owner uuid references public.principals(id);
alter table if exists public.language_rules       add column if not exists visibility public.visibility_level not null default 'shared';

create index if not exists idx_suppliers_owner           on public.suppliers(owner);
create index if not exists idx_supplier_orders_owner     on public.supplier_orders(owner);
create index if not exists idx_supplier_documents_owner  on public.supplier_documents(owner);
create index if not exists idx_products_owner            on public.products(owner);
create index if not exists idx_ingredients_owner         on public.ingredients(owner);
create index if not exists idx_product_ingredients_owner on public.product_ingredients(owner);
create index if not exists idx_ingredient_claims_owner   on public.ingredient_claims(owner);
create index if not exists idx_language_rules_owner      on public.language_rules(owner);

comment on column public.suppliers.visibility is
  'Access input consumed by can_read_row(). Present here rather than left to a comment, because a repository comment saying a future migration "should" add a column is not a mechanism.';
