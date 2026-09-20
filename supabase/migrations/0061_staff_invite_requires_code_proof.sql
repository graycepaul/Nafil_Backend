-- accept_staff_invite_by_email() matched a pending invite on the session's
-- email alone. The auth server auto-confirms sign-ups, so that email is
-- unverified: anyone who knew or guessed an invited address could sign up
-- with it and be promoted to the invited role, no invite code needed.
--
-- Backend-only fix that works with already-released app builds: the client
-- calls save_staff_invite_profile(code, ...) BEFORE creating the account, and
-- that RPC needs the invite code. It now stamps profile_saved_at, and
-- acceptance requires that stamp to be recent. Someone who only knows the
-- email can't produce it. Residual window: an attacker who knows the email
-- could sign up between the real invitee saving their profile and creating
-- their account, bounded to 24 hours by this check. Binding acceptance to the
-- code itself (as household invites do) would close that fully and needs a
-- client release.

alter table staff_invites add column profile_saved_at timestamptz;

create or replace function public.save_staff_invite_profile(
  invite_code text, p_first_name text, p_last_name text, p_phone text, p_avatar_url text default null
) returns boolean
  language plpgsql security definer set search_path = public as $$
begin
  update staff_invites
     set first_name = p_first_name, last_name = p_last_name, phone = p_phone,
         avatar_url = coalesce(p_avatar_url, avatar_url),
         profile_saved_at = now()
   where code = upper(trim(invite_code)) and status = 'pending' and expires_at > now();
  return found;
end;
$$;

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
     and profile_saved_at > now() - interval '24 hours'
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
