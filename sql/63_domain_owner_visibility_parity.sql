-- 63_domain_owner_visibility_parity.sql
-- Optional reference-domain owner/visibility columns and indexes.
-- Authorization inputs need executable DDL; a comment recommending columns
-- cannot establish schema compatibility. Inventory comparison alone does not
-- prove object-definition parity.
--
-- No customer owners are seeded. These columns do not supply complete domain
-- RLS or source-to-scope mapping; adapters must qualify those separately.

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
