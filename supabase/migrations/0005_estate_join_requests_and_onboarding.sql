-- ══════════════════════════════════════════════════════════════════════════
-- Resident onboarding: profile completion → estate join request → approval
--
-- Closes a real hole surfaced by this feature: profiles_update's WITH CHECK
-- only verified `id = auth.uid()`, so a resident could self-UPDATE their own
-- `role`, `approved`, or `estate_id` directly via the REST API. Adding
-- self-service profile editing (phone, avatar) without fixing this first
-- would have been irresponsible.
-- ══════════════════════════════════════════════════════════════════════════

-- ── profiles: add avatar_url ────────────────────────────────────────────
alter table profiles add column avatar_url text;

-- ── Lock privilege-sensitive columns from self-escalation ──────────────
-- A resident can still update their own full_name/phone/avatar_url/unit_no
-- freely (profiles_update's USING/CHECK already allows id = auth.uid()).
-- This trigger silently preserves role/approved/estate_id on any UPDATE not
-- performed by an admin/super_admin, regardless of what the client sent —
-- the only sanctioned way to change them is approve_join_request() below.
create or replace function private.protect_profile_privileged_columns() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if private.auth_role() not in ('admin', 'super_admin') then
    new.role := old.role;
    new.approved := old.approved;
    new.estate_id := old.estate_id;
  end if;
  return new;
end;
$$;

create trigger protect_profile_privileged_columns
  before update on profiles
  for each row execute function private.protect_profile_privileged_columns();

-- ── estates: any signed-in user can browse the directory ───────────────
-- Needed so an unassigned resident can search for their estate to join.
-- Not a confidentiality concern: every user of this app belongs to the same
-- client, so estate name/address isn't cross-tenant data the way it would be
-- on a multi-customer SaaS platform.
drop policy if exists estates_select on estates;
create policy estates_select on estates for select
  to authenticated
  using (true);

-- ── estate_join_requests ────────────────────────────────────────────────
create type join_request_status as enum ('pending', 'approved', 'rejected');

create table estate_join_requests (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  estate_id uuid not null references estates(id) on delete cascade,
  unit_no text not null,
  status join_request_status not null default 'pending',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references profiles(id)
);

create index join_requests_profile_idx on estate_join_requests(profile_id);
create index join_requests_estate_idx on estate_join_requests(estate_id);

-- One pending request per resident at a time — cheap DB-level guard against
-- double submission; a rejected request doesn't block a fresh attempt since
-- the index only covers status = 'pending'.
create unique index one_pending_request_per_profile
  on estate_join_requests(profile_id)
  where status = 'pending';

alter table estate_join_requests enable row level security;

create policy join_requests_insert_self on estate_join_requests for insert
  with check (profile_id = (select auth.uid()));

create policy join_requests_select on estate_join_requests for select
  using (
    profile_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

-- Deliberately no UPDATE/DELETE policy for anyone, including admins. Status
-- changes only happen through approve_join_request/reject_join_request below
-- (SECURITY DEFINER, bypasses RLS, but re-checks authorization internally) —
-- so even a compromised or buggy client can never flip status directly.

-- ── Approval actions ─────────────────────────────────────────────────────
-- Unlike auth_role()/auth_estate_id(), these stay in `public` on purpose:
-- they're meant to be called via supabase.rpc() from the admin app, and they
-- perform their own authorization check internally (raise an exception for
-- non-admins) rather than relying on RLS to gate access.
create or replace function public.approve_join_request(request_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  req estate_join_requests%rowtype;
begin
  if private.auth_role() not in ('admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into req from estate_join_requests where id = request_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;

  if private.auth_role() = 'admin' and req.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  update estate_join_requests
     set status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
   where id = request_id;

  update profiles
     set estate_id = req.estate_id, unit_no = req.unit_no, approved = true
   where id = req.profile_id;
end;
$$;

create or replace function public.reject_join_request(request_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  req estate_join_requests%rowtype;
begin
  if private.auth_role() not in ('admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into req from estate_join_requests where id = request_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;

  if private.auth_role() = 'admin' and req.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  update estate_join_requests
     set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
   where id = request_id;
end;
$$;

-- ── Storage: avatars ─────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

-- Path convention: {user_id}/avatar.<ext> — each user may only write inside
-- their own folder. Bucket is public, so reads need no policy.
create policy avatar_insert_own on storage.objects for insert
  to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy avatar_update_own on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy avatar_delete_own on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
