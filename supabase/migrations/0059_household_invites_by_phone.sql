-- Household invites move from email to phone number (0056 keyed them by
-- email). Residents know each other's phone numbers, not necessarily emails,
-- and the auth server (GoTrue) runs with GOTRUE_MAILER_AUTOCONFIRM and
-- GOTRUE_SMS_AUTOCONFIRM both on: phone + password sign-up works natively,
-- with a session straight away and no message sent.
--
-- The same setting is why acceptance can't rely on the account's own
-- identifier any more. With autoconfirm, an email or phone number on a
-- session is unverified - anyone can sign up with any number they like - so
-- "the session's phone matches the invite" proves nothing on its own. The
-- invite CODE is the credential (single-use, 7 days, cancellable); the phone
-- match is only a second check that the account was created with the number
-- the resident actually invited. accept_household_invite_by_email() (which
-- trusted the email alone) is removed rather than kept as a fallback.

create or replace function private.normalize_phone(p text) returns text
  language sql immutable as $$
  select regexp_replace(coalesce(p, ''), '\D', '', 'g');
$$;

-- `phone` already exists (0056 staged the invitee's number there); it now holds
-- the number the resident invited, set at invite time instead of signup time.
alter table household_invites alter column email drop not null;

drop index one_pending_household_invite_per_email;

-- The app always sends an international number, but this is the real
-- guarantee: a direct API call with a national-format Nigerian number
-- (0801...) is stored as 234801... so it can neither slip past the
-- one-pending-invite-per-phone index nor create an invite that could never
-- match the phone GoTrue records for the account.
create or replace function private.normalize_household_invite_phone() returns trigger
  language plpgsql as $$
begin
  new.phone := private.normalize_phone(new.phone);
  if new.phone ~ '^0[0-9]{10}$' then
    new.phone := '234' || substr(new.phone, 2);
  end if;
  if length(new.phone) < 8 or length(new.phone) > 15 then
    raise exception 'A valid phone number is required';
  end if;
  return new;
end;
$$;

create trigger normalize_household_invite_phone
  before insert on household_invites
  for each row execute function private.normalize_household_invite_phone();

create unique index one_pending_household_invite_per_phone
  on household_invites(phone)
  where status = 'pending';

-- ── Anonymous-callable: peek at a code before creating an account ───────
drop function public.validate_household_invite_code(text);
create function public.validate_household_invite_code(invite_code text)
returns table (valid boolean, estate_name text, invite_access household_access_level, invite_phone text, inviter_name text)
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
    select true, e.name, inv.access_level, inv.phone, p.full_name
    from estates e
    join profiles p on p.id = inv.resident_id
    where e.id = inv.estate_id;
end;
$$;

-- The phone is fixed by the invite now, so only the name is collected.
drop function public.save_household_invite_profile(text, text, text, text);
create function public.save_household_invite_profile(
  invite_code text, p_first_name text, p_last_name text
) returns boolean
  language plpgsql security definer set search_path = public as $$
begin
  update household_invites
     set first_name = p_first_name, last_name = p_last_name
   where code = upper(trim(invite_code)) and status = 'pending' and expires_at > now();
  return found;
end;
$$;

drop function public.accept_household_invite_by_email();

-- ── Authenticated: finalize right after sign-up, bound to the code ──────
create function public.accept_household_invite(p_code text)
returns table (accepted boolean, granted_access household_access_level)
language plpgsql security definer set search_path = public as $$
declare
  inv household_invites%rowtype;
  caller profiles%rowtype;
  caller_phone text := private.normalize_phone(auth.jwt() ->> 'phone');
  v_unit text;
begin
  if auth.uid() is null or caller_phone = '' then
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
   where code = upper(trim(p_code)) and status = 'pending' and expires_at > now();

  if not found or inv.phone <> caller_phone then
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
         phone = coalesce(phone, inv.phone)
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
