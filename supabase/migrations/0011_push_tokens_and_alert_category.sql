-- ══════════════════════════════════════════════════════════════════════════
-- Amber-alert style push notifications.
--
-- Push itself is sent server-side (the FastAPI service, via Expo's push
-- API) — Supabase/RLS only needs to know which device tokens belong to
-- which resident, and let security/admin tag an emergency announcement
-- with a category for the alert banner's wording.
-- ══════════════════════════════════════════════════════════════════════════

create table push_tokens (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  token text not null unique,
  platform text,
  created_at timestamptz not null default now()
);

create index push_tokens_profile_idx on push_tokens(profile_id);

alter table push_tokens enable row level security;

-- A device re-registering (app reinstall, token rotation) upserts on the
-- unique `token` column — one row per owner is enough, no update policy
-- needed beyond what insert/select/delete already covers via upsert.
create policy push_tokens_owner_all on push_tokens for all
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

-- Only meaningful when severity = 'emergency' — lets the alert banner show
-- a specific reason ("Missing child", "Security breach", ...) instead of
-- just "Emergency". Nullable/unchecked for ordinary info announcements.
alter table announcements add column category text
  check (category is null or category in ('missing_child', 'security_breach', 'epidemic', 'other'));
