-- The invite card showed only a phone number, which is awkward for the
-- resident managing several people. The resident now names the person when
-- inviting. That name lives on the invite (`invitee_name`, what the resident
-- calls them), separate from first_name/last_name, which are what the
-- dependant themselves types at signup and what ends up on their profile.
-- The signup screen prefills from it, so it's a starting point, not a lock.

alter table household_invites add column invitee_name text;

drop function public.validate_household_invite_code(text);
create function public.validate_household_invite_code(invite_code text)
returns table (valid boolean, estate_name text, invite_access household_access_level, invite_phone text, inviter_name text, invitee_name text)
language plpgsql security definer set search_path = public as $$
declare
  inv household_invites%rowtype;
begin
  select * into inv from household_invites
   where code = upper(trim(invite_code)) and status = 'pending' and expires_at > now();

  if not found then
    return query select false, null::text, null::household_access_level, null::text, null::text, null::text;
    return;
  end if;

  return query
    select true, e.name, inv.access_level, inv.phone, p.full_name, inv.invitee_name
    from estates e
    join profiles p on p.id = inv.resident_id
    where e.id = inv.estate_id;
end;
$$;
