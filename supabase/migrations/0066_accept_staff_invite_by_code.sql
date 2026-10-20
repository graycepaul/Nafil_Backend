-- Accepting a staff invite by email alone (accept_staff_invite_by_email) lets
-- anyone who knows or guesses the invited address sign up with it and be
-- promoted: sign-ups are auto-confirmed, so the email proves nothing. 0061 only
-- narrowed the window to 24 hours after the real invitee saves their profile.
--
-- This binds acceptance to the invite code as well, the same way household
-- invites already work: the caller must hold the secret code AND be signed in
-- with the invited email. The old function stays for released app builds that
-- still call it; it can be dropped in a later migration once they have updated.
--
-- A signed-in super_admin or dev_admin is never changed by an invite.
create or replace function public.accept_staff_invite(p_code text)
returns table (accepted boolean, granted_role user_role)
  language plpgsql security definer set search_path = public as $$
declare
  inv staff_invites%rowtype;
  caller_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  caller_role user_role;
begin
  if auth.uid() is null or caller_email = '' then
    return query select false, null::user_role;
    return;
  end if;

  select role into caller_role from profiles where id = auth.uid();
  if not found or caller_role in ('super_admin', 'dev_admin') then
    return query select false, null::user_role;
    return;
  end if;

  select * into inv from staff_invites
   where code = upper(trim(p_code))
     and lower(email) = caller_email
     and status = 'pending'
     and expires_at > now();

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

revoke execute on function public.accept_staff_invite(text) from public, anon;
grant execute on function public.accept_staff_invite(text) to authenticated;
