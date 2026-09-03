-- Marketplace: residents list goods and services for sale within their own estate.
-- Payments are not wired yet (see the wallet/dues migration for that). This covers
-- browsing, posting, and photo storage only.

create type listing_type as enum ('good', 'service');
create type listing_status as enum ('active', 'sold', 'removed');

create table listings (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  seller_id uuid not null references profiles(id) on delete cascade,
  type listing_type not null,
  title text not null,
  description text not null,
  category text not null,
  price integer not null,
  -- Services only, for a "starting from" range. Null for goods and flat-rate services.
  price_max integer,
  photo_urls text[] not null default '{}',
  -- Goods only.
  pickup boolean not null default false,
  pickup_address text,
  home_delivery boolean not null default false,
  delivery_fee integer not null default 0,
  -- Services only.
  whatsapp text,
  status listing_status not null default 'active',
  created_at timestamptz not null default now()
);

create index listings_estate_idx on listings(estate_id);
create index listings_seller_idx on listings(seller_id);

alter table listings enable row level security;

-- Everyone in the estate can browse; sellers manage only their own listings.
create policy listings_select on listings for select
  using (
    (select private.auth_role()) = 'super_admin'
    or estate_id = (select private.auth_estate_id())
  );

create policy listings_insert on listings for insert
  with check (
    seller_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
  );

create policy listings_update on listings for update
  using (
    seller_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create policy listings_delete on listings for delete
  using (
    seller_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

-- ── Storage: listing photos ─────────────────────────────────────────────
-- Path convention: {user_id}/{timestamp}-{index}.<ext>, same shape as avatars.
-- The select policy is included from the start this time (see 0010's postmortem:
-- a public bucket still needs one, or upload's own INSERT ... RETURNING fails RLS).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-photos', 'listing-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy listing_photos_select_public on storage.objects for select
  using (bucket_id = 'listing-photos');

create policy listing_photos_insert_own on storage.objects for insert
  to authenticated
  with check (bucket_id = 'listing-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy listing_photos_delete_own on storage.objects for delete
  to authenticated
  using (bucket_id = 'listing-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
