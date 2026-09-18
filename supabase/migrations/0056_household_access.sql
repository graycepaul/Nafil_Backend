-- ══════════════════════════════════════════════════════════════════════════
-- Household access: let a unit's registered resident vouch for other people
-- (spouse, adult child, dependant) to get their own login on the same unit.
--
-- Until now visitor_passes could only be created by the one resident profile
-- registered against a unit, so if that person was away nobody else in the
-- household could issue a pass. household_members (0013) is a different
-- thing - a standing gate card for a recurring visitor (nanny, driver) who
-- never logs in. This adds real logins at two access levels:
--
--   'full'          an independent resident account (own wallet, own
--                   listings, own passes under their own name) that can also
--                   see/pay dues for anyone else sharing the unit.
--   'visitors_only' Visitors + Market (buy only) + Profile (ID card). No
--                   wallet, dues, listings, or household-card management.
--
-- No admin approval: the primary resident's invite *is* the approval, same
-- trust bar as adding a household_member today. Mirrors the staff-invite
-- flow (0007) closely - code-based, anonymous pre-account steps, then a
-- SECURITY DEFINER finalizer matched by verified JWT email.
--
-- Revocation leaves `approved = true` alone and instead sets
-- profiles.household_access_level = 'revoked'. Reusing `approved = false`
-- would drop the member into the onboarding wizard, which decides its
-- destination by querying estate_join_requests - a revoked member has no
-- row there and would be told to search for an estate all over again.
--
-- Deferred on purpose: keeping a member's unit_no in sync if the primary's
-- unit changes later.
-- ══════════════════════════════════════════════════════════════════════════

create type household_access_level as enum ('full', 'visitors_only');

-- Denormalized onto profiles (like `role`) so RLS and the client both read
-- one column instead of joining household_links everywhere. null = not a
-- household member (a normal admin-approved resident, or staff).
alter table profiles
  add column household_access_level text
    check (household_access_level is null or household_access_level in ('full', 'visitors_only', 'revoked'));

create or replace function private.auth_household_access_level() returns text
  language sql stable security definer set search_path = public as $$
  select household_access_level from profiles where id = auth.uid();
$$;

-- A member must not be able to clear their own 'revoked' (or grant
-- themselves 'full') with a plain profile update - same protection as role/
-- approved/estate_id. The sync trigger below flips the bypass GUC itself.
create or replace function private.protect_profile_privileged_columns() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if private.auth_role() not in ('admin', 'super_admin')
     and coalesce(current_setting('nafil.bypass_profile_protection', true), 'off') <> 'on' then
    new.role := old.role;
    new.approved := old.approved;
    new.estate_id := old.estate_id;
    new.household_access_level := old.household_access_level;
  end if;
  return new;
end;
$$;

-- ── Invites ─────────────────────────────────────────────────────────────
create table household_invites (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  resident_id uuid not null references profiles(id) on delete cascade,
  access_level household_access_level not null,
  email text not null,
  code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  -- Collected during the pre-account (anonymous) steps, copied onto the
  -- profile once accept_household_invite_by_email() runs post-confirmation.
  first_name text,
  last_name text,
  phone text,
  reviewed_at timestamptz,
  accepted_profile_id uuid references profiles(id)
);

create index household_invites_estate_idx on household_invites(estate_id);
create index household_invites_resident_idx on household_invites(resident_id);
create index household_invites_email_idx on household_invites(lower(email));

create unique index one_pending_household_invite_per_email
  on household_invites(lower(email))
  where status = 'pending';

alter table household_invites enable row level security;

-- Only a real (admin-approved) resident can invite - a household member
-- (any level, revoked included) can never invite a second layer.
create policy household_invites_insert on household_invites for insert
  with check (
    resident_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = 'resident'
    and (select private.auth_household_access_level()) is null
  );

create policy household_invites_select on household_invites for select
  using (
    resident_id = (select auth.uid())
    or (
      estate_id = (select private.auth_estate_id())
      and (select private.auth_role()) = any (array['admin'::user_role, 'super_admin'::user_role])
    )
  );

-- ── Links (the actual relationship, after an invite is accepted) ────────
create table household_links (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  primary_resident_id uuid not null references profiles(id) on delete cascade,
  member_id uuid not null references profiles(id) on delete cascade,
  access_level household_access_level not null,
  status text not null default 'active' check (status in ('active', 'revoked')),
  created_at timestamptz not null default now(),
  -- One household relationship per member (MVP simplification). A revoked
  -- member who's re-invited updates this same row back to active.
  unique (member_id)
);

create index household_links_primary_idx on household_links(primary_resident_id);

alter table household_links enable row level security;

create policy household_links_select on household_links for select
  using (
    primary_resident_id = (select auth.uid())
    or member_id = (select auth.uid())
    or (
      estate_id = (select private.auth_estate_id())
      and (select private.auth_role()) = any (array['admin'::user_role, 'super_admin'::user_role])
    )
  );

-- No insert/update/delete policy for anyone: rows only change through the
-- SECURITY DEFINER functions below.

create or replace function private.sync_household_access_level() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  perform set_config('nafil.bypass_profile_protection', 'on', true);
  update profiles
     set household_access_level = case when new.status = 'active' then new.access_level::text else 'revoked' end
   where id = new.member_id;
  perform set_config('nafil.bypass_profile_protection', 'off', true);
  return new;
end;
$$;

create trigger sync_household_access_level
  after insert or update on household_links
  for each row execute function private.sync_household_access_level();

-- Everyone whose dues a caller may see/pay as "their unit's": themselves,
-- plus - only for 'full' relationships - the primary, that primary's other
-- full members, and (for a primary) their own full members.
create or replace function private.auth_household_profile_ids() returns setof uuid
  language sql stable security definer set search_path = public as $$
  select auth.uid()
  union
  select primary_resident_id from household_links
   where member_id = auth.uid() and access_level = 'full' and status = 'active'
  union
  select member_id from household_links
   where primary_resident_id = auth.uid() and access_level = 'full' and status = 'active'
  union
  select l2.member_id
    from household_links l1
    join household_links l2 on l2.primary_resident_id = l1.primary_resident_id
   where l1.member_id = auth.uid() and l1.access_level = 'full' and l1.status = 'active'
     and l2.access_level = 'full' and l2.status = 'active';
$$;

-- ── Anonymous-callable: peek at a code before creating an account ───────
create or replace function public.validate_household_invite_code(invite_code text)
returns table (valid boolean, estate_name text, invite_access household_access_level, invite_email text, inviter_name text)
language plpgsql security definer set search_path = public as $$
declare
  inv household_invites%rowtype;
begin
  select * into inv from household_invites
   where code = upper(trim(invite_code)) and status = 'pending' and expires_at > now();

  if not found then
    return query select false, null::text, null::household_access_level, null::text, null::text;
    return;
  end if;

  return query
    select true, e.name, inv.access_level, inv.email, p.full_name
    from estates e
    join profiles p on p.id = inv.resident_id
    where e.id = inv.estate_id;
end;
$$;

create or replace function public.save_household_invite_profile(
  invite_code text, p_first_name text, p_last_name text, p_phone text
) returns boolean
  language plpgsql security definer set search_path = public as $$
begin
  update household_invites
     set first_name = p_first_name, last_name = p_last_name, phone = p_phone
   where code = upper(trim(invite_code)) and status = 'pending' and expires_at > now();
  return found;
end;
$$;

-- ── Authenticated: finalize on first real login post-confirmation ──────
create or replace function public.accept_household_invite_by_email()
returns table (accepted boolean, granted_access household_access_level)
language plpgsql security definer set search_path = public as $$
declare
  inv household_invites%rowtype;
  caller_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  caller profiles%rowtype;
  v_unit text;
begin
  if caller_email = '' then
    return query select false, null::household_access_level;
    return;
  end if;

  select * into caller from profiles where id = auth.uid();
  -- Only a fresh resident-shaped signup (or someone already linked, e.g.
  -- being re-invited after a revoke) can be converted. Never overwrite an
  -- already-approved independent resident or a staff account.
  if not found or caller.role <> 'resident'
     or (caller.approved and not exists (select 1 from household_links where member_id = auth.uid())) then
    return query select false, null::household_access_level;
    return;
  end if;

  select * into inv from household_invites
   where lower(email) = caller_email and status = 'pending' and expires_at > now()
   order by created_at desc
   limit 1;

  if not found then
    return query select false, null::household_access_level;
    return;
  end if;

  -- The inviter must still be a genuine, active primary resident.
  select unit_no into v_unit from profiles
   where id = inv.resident_id and role = 'resident' and approved and household_access_level is null;
  if not found then
    update household_invites set status = 'revoked', reviewed_at = now() where id = inv.id;
    return query select false, null::household_access_level;
    return;
  end if;

  perform set_config('nafil.bypass_profile_protection', 'on', true);

  update profiles
     set estate_id = inv.estate_id,
         unit_no = v_unit,
         approved = true,
         full_name = coalesce(nullif(trim(coalesce(inv.first_name, '') || ' ' || coalesce(inv.last_name, '')), ''), full_name),
         phone = coalesce(inv.phone, phone)
   where id = auth.uid();

  perform set_config('nafil.bypass_profile_protection', 'off', true);

  update household_invites
     set status = 'accepted', reviewed_at = now(), accepted_profile_id = auth.uid()
   where id = inv.id;

  insert into household_links (estate_id, primary_resident_id, member_id, access_level)
  values (inv.estate_id, inv.resident_id, auth.uid(), inv.access_level)
  on conflict (member_id) do update
    set primary_resident_id = excluded.primary_resident_id,
        access_level = excluded.access_level,
        status = 'active',
        estate_id = excluded.estate_id;

  return query select true, inv.access_level;
end;
$$;

create or replace function public.revoke_household_invite(invite_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  inv household_invites%rowtype;
begin
  select * into inv from household_invites where id = invite_id and status = 'pending';
  if not found then
    raise exception 'Invite not found or already resolved';
  end if;

  if inv.resident_id <> auth.uid()
     and not (
       private.auth_role() in ('admin', 'super_admin') and inv.estate_id = private.auth_estate_id()
     ) then
    raise exception 'Not authorized';
  end if;

  update household_invites set status = 'revoked', reviewed_at = now() where id = invite_id;
end;
$$;

create or replace function public.revoke_household_link(link_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  link household_links%rowtype;
begin
  select * into link from household_links where id = link_id and status = 'active';
  if not found then
    raise exception 'Household member not found or already revoked';
  end if;

  if link.primary_resident_id <> auth.uid()
     and not (
       private.auth_role() in ('admin', 'super_admin') and link.estate_id = private.auth_estate_id()
     ) then
    raise exception 'Not authorized';
  end if;

  update household_links set status = 'revoked' where id = link_id;
end;
$$;

-- ── Dues: a 'full' member sees/pays dues for the whole shared unit ──────
drop policy dues_select on dues;
create policy dues_select on dues for select
  using (
    profile_id in (select private.auth_household_profile_ids())
    or (
      estate_id = (select private.auth_estate_id())
      and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role])
    )
  );

-- Same body as 0050, except (a) ownership widens from profile_id =
-- auth.uid() to the caller's household, and (b) visitors_only/revoked
-- members can't move money at all. The wallet debited and the ledger entry
-- written are still the caller's own - a member pays with their own balance.
create or replace function pay_dues_from_wallet(p_due_ids uuid[]) returns void
  language plpgsql security definer set search_path = public as $$
declare
  v_total integer;
  v_count integer;
  v_balance integer;
  v_label text;
begin
  if coalesce(private.auth_household_access_level(), 'none') not in ('none', 'full') then
    raise exception 'not authorized to pay dues';
  end if;

  if p_due_ids is null or array_length(p_due_ids, 1) is null then
    raise exception 'no dues specified';
  end if;

  perform 1 from dues
    where id = any(p_due_ids)
      and profile_id in (select private.auth_household_profile_ids())
      and status <> 'paid'
    for update;

  select count(*), coalesce(sum(amount), 0)
    into v_count, v_total
    from dues
    where id = any(p_due_ids)
      and profile_id in (select private.auth_household_profile_ids())
      and status <> 'paid';

  if v_count <> array_length(p_due_ids, 1) then
    raise exception 'one or more dues were not found, already paid, or not yours';
  end if;

  select balance into v_balance from wallets where profile_id = auth.uid() for update;
  if v_balance is null or v_balance < v_total then
    raise exception 'insufficient wallet balance';
  end if;

  select case when count(*) = 1 then max('Estate dues · ' || label) else 'Estate dues · ' || count(*) || ' items' end
    into v_label
    from dues where id = any(p_due_ids);

  update wallets set balance = balance - v_total, updated_at = now() where profile_id = auth.uid();
  update dues set status = 'paid' where id = any(p_due_ids);
  insert into wallet_transactions (profile_id, label, amount, status)
    values (auth.uid(), v_label, -v_total, 'completed');
end;
$$;

-- ── Restrictions by access level ────────────────────────────────────────
-- A revoked member must stop being able to act on the unit at all; a
-- visitors_only member additionally can't sell, hold dues, or manage
-- standing household cards. UI hides all of this too - these are the real
-- backstop for anyone calling the API directly.
--
-- Note: transfers_insert has never checked that a `dues` transfer's
-- reference_id belongs to the submitter (pre-existing; the client only ever
-- offers the caller's own dues). Left as-is here - out of scope.
drop policy visitor_passes_insert on visitor_passes;
create policy visitor_passes_insert on visitor_passes for insert
  with check (
    resident_id = (select auth.uid())
    and coalesce((select private.auth_household_access_level()), 'none') <> 'revoked'
  );

drop policy scheduled_visits_resident_all on scheduled_visits;
create policy scheduled_visits_resident_all on scheduled_visits for all
  using (
    resident_id = (select auth.uid())
    and coalesce((select private.auth_household_access_level()), 'none') <> 'revoked'
  )
  with check (
    resident_id = (select auth.uid())
    and coalesce((select private.auth_household_access_level()), 'none') <> 'revoked'
  );

drop policy household_members_resident_all on household_members;
create policy household_members_resident_all on household_members for all
  using (
    resident_id = (select auth.uid())
    and coalesce((select private.auth_household_access_level()), 'none') in ('none', 'full')
  )
  with check (
    resident_id = (select auth.uid())
    and coalesce((select private.auth_household_access_level()), 'none') in ('none', 'full')
  );

drop policy listings_insert on listings;
create policy listings_insert on listings for insert
  with check (
    seller_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and coalesce((select private.auth_household_access_level()), 'none') in ('none', 'full')
  );

drop policy orders_insert on orders;
create policy orders_insert on orders for insert
  with check (
    buyer_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and coalesce((select private.auth_household_access_level()), 'none') <> 'revoked'
  );

drop policy transfers_insert on transfers;
create policy transfers_insert on transfers for insert
  with check (
    profile_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and coalesce((select private.auth_household_access_level()), 'none') in ('none', 'full')
  );
