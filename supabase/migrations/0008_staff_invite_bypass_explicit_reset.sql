-- accept_staff_invite_by_email's bypass GUC is transaction-local, which is
-- safe under PostgREST (one transaction per request) but was only proven so
-- by assumption. Testing it inside one long SQL-editor transaction showed the
-- flag staying "on" for every later statement in that same transaction, which
-- would be a real problem if anything ever executes multiple statements in a
-- shared transaction (a future RPC, a script, anything). Turning it back off
-- explicitly right after the one UPDATE it's meant to guard removes the
-- reliance on transaction boundaries entirely — belt and suspenders.
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
