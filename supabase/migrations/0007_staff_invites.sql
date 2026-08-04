-- ══════════════════════════════════════════════════════════════════════════
-- Staff (security) invite flow — access code instead of a magic link
--
-- Why a code, not just Supabase's inviteUserByEmail: that requires the
-- service-role key server-side (which the mobile app must never hold) and
-- ties acceptance to clicking a link at exactly the right moment. A code the
-- admin can share through any channel (WhatsApp, SMS, in person) works the
-- same way visitor pass codes already do, and needs no backend to send.
--
-- Confirmed empirically: this project requires email confirmation before a
-- session exists, so `signUp` never returns a session immediately. That
-- forces profile details (name/phone/photo) to be saved on the invite row
-- itself during the anonymous phase — there's no profile to attach them to
-- yet — and finalized only once the confirmation click produces a real
-- session, days later if that's how long it takes.
-- ══════════════════════════════════════════════════════════════════════════

create type staff_invite_status as enum ('pending', 'accepted', 'revoked', 'expired');

create table staff_invites (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  role user_role not null,
  email text not null,
  code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  status staff_invite_status not null default 'pending',
  invited_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  -- Collected during the pre-account (anonymous) steps; copied into profiles
  -- only once accept_staff_invite_by_email() runs post-confirmation.
  first_name text,
  last_name text,
  phone text,
  avatar_url text,
  reviewed_at timestamptz,
  accepted_profile_id uuid references profiles(id),
  constraint staff_invites_role_check check (role in ('security', 'admin'))
);

create index staff_invites_estate_idx on staff_invites(estate_id);
create index staff_invites_email_idx on staff_invites(lower(email));

-- One live invite per email at a time — a re-invite should revoke the old one
-- first rather than create a second pending row for the same address.
create unique index one_pending_invite_per_email
  on staff_invites(lower(email))
  where status = 'pending';

alter table staff_invites enable row level security;

create policy staff_invites_insert on staff_invites for insert
  with check (
    invited_by = (select auth.uid())
    and (
      (select private.auth_role()) = 'super_admin'
      or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
    )
  );

create policy staff_invites_select on staff_invites for select
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

-- No UPDATE/DELETE policy for anyone. Status changes (accepted/revoked) only
-- happen through the SECURITY DEFINER functions below.

-- ── Trigger bypass for legitimate self-elevation ────────────────────────
-- accept_staff_invite_by_email() is called by the invitee themselves, whose
-- own role is still 'resident' at that moment (the signup trigger's default).
-- protect_profile_privileged_columns would otherwise block them from setting
-- their own role/estate_id/approved — correctly, for a normal client update,
-- but this is the one sanctioned exception. A transaction-local GUC flag
-- lets a specific SECURITY DEFINER function announce "this update is mine,
-- let it through" without weakening the trigger for every other caller.
create or replace function private.protect_profile_privileged_columns() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if private.auth_role() not in ('admin', 'super_admin')
     and coalesce(current_setting('nafil.bypass_profile_protection', true), 'off') <> 'on' then
    new.role := old.role;
    new.approved := old.approved;
    new.estate_id := old.estate_id;
  end if;
  return new;
end;
$$;

-- ── Anonymous-callable: peek at a code before creating an account ───────
create or replace function public.validate_staff_invite_code(invite_code text)
returns table (valid boolean, estate_name text, invite_role user_role, invite_email text)
language plpgsql security definer set search_path = public as $$
declare
  inv staff_invites%rowtype;
begin
  select * into inv from staff_invites
   where code = upper(trim(invite_code)) and status = 'pending' and expires_at > now();

  if not found then
    return query select false, null::text, null::user_role, null::text;
    return;
  end if;

  return query
    select true, e.name, inv.role, inv.email
    from estates e where e.id = inv.estate_id;
end;
$$;

-- ── Anonymous-callable: save profile details ahead of account creation ──
create or replace function public.save_staff_invite_profile(
  invite_code text, p_first_name text, p_last_name text, p_phone text, p_avatar_url text default null
) returns boolean
  language plpgsql security definer set search_path = public as $$
begin
  update staff_invites
     set first_name = p_first_name, last_name = p_last_name, phone = p_phone,
         avatar_url = coalesce(p_avatar_url, avatar_url)
   where code = upper(trim(invite_code)) and status = 'pending' and expires_at > now();
  return found;
end;
$$;

-- ── Authenticated: finalize on first real login post-confirmation ──────
-- Matches by the caller's own verified email, not a code — the code's job
-- ended once save_staff_invite_profile ran; threading it through the
-- email-confirmation redirect afterward would be one more fragile hop.
--
-- The bypass GUC is transaction-local (safe under PostgREST's one-transaction-
-- per-request model), but it's also turned back off explicitly right after
-- the one UPDATE it's meant to guard — defense in depth rather than relying
-- solely on transaction boundaries. Verified in testing: without the explicit
-- reset, a second, unrelated UPDATE later in the *same* transaction could ride
-- the still-open bypass window.
create or replace function public.accept_staff_invite_by_email()
returns table (accepted boolean, granted_role user_role)
language plpgsql security definer set search_path = public as $$
declare
  inv staff_invites%rowtype;
  caller_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if caller_email = '' then
    return query select false, null::user_role;
    return;
  end if;

  select * into inv from staff_invites
   where lower(email) = caller_email and status = 'pending' and expires_at > now()
   order by created_at desc
   limit 1;

  if not found then
    return query select false, null::user_role;
    return;
  end if;

  perform set_config('nafil.bypass_profile_protection', 'on', true);

  update profiles
     set role = inv.role,
         estate_id = inv.estate_id,
         approved = true,
         full_name = coalesce(nullif(trim(coalesce(inv.first_name, '') || ' ' || coalesce(inv.last_name, '')), ''), full_name),
         phone = coalesce(inv.phone, phone),
         avatar_url = coalesce(inv.avatar_url, avatar_url)
   where id = auth.uid();

  perform set_config('nafil.bypass_profile_protection', 'off', true);

  update staff_invites
     set status = 'accepted', reviewed_at = now(), accepted_profile_id = auth.uid()
   where id = inv.id;

  return query select true, inv.role;
end;
$$;

create or replace function public.revoke_staff_invite(invite_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  inv staff_invites%rowtype;
begin
  if private.auth_role() not in ('admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into inv from staff_invites where id = invite_id and status = 'pending';
  if not found then
    raise exception 'Invite not found or already resolved';
  end if;

  if private.auth_role() = 'admin' and inv.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  update staff_invites set status = 'revoked', reviewed_at = now() where id = invite_id;
end;
$$;

-- ── Storage: anon upload for a photo picked before the account exists ───
-- Path convention: pending/{code}/avatar.<ext>. Scoped narrowly: only
-- writable while that exact code has a live pending invite, checked via a
-- SECURITY DEFINER helper since anon has no SELECT policy on staff_invites
-- for this subquery to see rows through otherwise.
create or replace function private.staff_invite_code_is_pending(check_code text) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from staff_invites
    where code = check_code and status = 'pending' and expires_at > now()
  );
$$;

create policy avatar_insert_pending_invite on storage.objects for insert
  to anon
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = 'pending'
    and private.staff_invite_code_is_pending((storage.foldername(name))[2])
  );
