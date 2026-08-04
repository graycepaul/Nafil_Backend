-- ══════════════════════════════════════════════════════════════════════════
-- Resident e-ID cards + household/frequent-visitor allow list
--
-- The problem this closes: a visitor pass is single-use and time-boxed,
-- which is wrong for a resident's own identity or for people who come
-- constantly (spouse, kids, a live-in nanny, a regular driver). Forcing
-- those through the visitor-pass flow means generating a fresh code every
-- day for the same person — not a workable trust model.
--
-- The fix is two standing, revocable credentials instead:
--   - profiles.resident_code — the resident's own permanent e-ID.
--   - household_members — the resident's allow list, each entry with its
--     own permanent code, until the resident revokes it.
--
-- The actual security property (why this isn't just a fancy photo ID
-- someone could forge): the card's QR encodes a random, unguessable code
-- that security looks up against these tables at the gate. The printed
-- name/photo on the card is not the source of truth — a match (or lack of
-- one) against the estate's live database is. A forged card with a made-up
-- or copied code fails the lookup, the same way a forged visitor pass code
-- already does today.
-- ══════════════════════════════════════════════════════════════════════════

-- ── Resident's own e-ID ───────────────────────────────────────────────────
-- Every profile gets one (not just residents) since it's a harmless,
-- unguessable identifier — but only the resident-facing UI ever surfaces it
-- as an "ID card". Volatile default means Postgres rewrites the table to
-- backfill existing rows, so already-seeded/approved profiles get one too.
alter table profiles
  add column resident_code text unique
  default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

create index profiles_resident_code_idx on profiles(resident_code);

-- Lets a resident invalidate a leaked/compromised card and get a fresh one
-- without an admin in the loop — same self-service spirit as revoking and
-- recreating a visitor pass. Routed through an RPC (rather than a plain
-- client-side update) purely so the random generation happens server-side.
create or replace function public.regenerate_resident_code() returns text
  language plpgsql security definer set search_path = public as $$
declare
  new_code text;
begin
  new_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  update profiles set resident_code = new_code where id = auth.uid();
  return new_code;
end;
$$;

-- ── Household members / frequent-visitor allow list ─────────────────────
create type household_member_status as enum ('active', 'revoked');

create table household_members (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  resident_id uuid not null references profiles(id) on delete cascade,
  full_name text not null,
  relationship text not null,
  phone text,
  avatar_url text,
  code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
  status household_member_status not null default 'active',
  created_at timestamptz not null default now()
);

create index household_members_estate_idx on household_members(estate_id);
create index household_members_resident_idx on household_members(resident_id);
create index household_members_code_idx on household_members(code);

alter table household_members enable row level security;

-- Residents manage their own list end-to-end (add, edit, revoke) — mirrors
-- visitor_passes_resident_all.
create policy household_members_resident_all on household_members for all
  using (resident_id = (select auth.uid()))
  with check (resident_id = (select auth.uid()));

-- Security/admin need read access to verify a scanned code at the gate —
-- mirrors visitor_passes_staff_select exactly.
create policy household_members_staff_select on household_members for select
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('security', 'admin'))
  );
