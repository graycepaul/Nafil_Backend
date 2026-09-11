-- ══════════════════════════════════════════════════════════════════════════
-- Block new community/estate creation at signup
--
-- This was never a multi-tenant SaaS in practice - one client, one estate.
-- handle_new_user() still had a live branch that creates a brand new estate
-- (and makes the signer its admin) whenever signup metadata carries a
-- community_name, which the mobile app's "Register a new community" screen
-- used. Removing that screen alone only blocks the in-app path - a direct
-- signUp() API call with the same metadata shape would still work. This
-- closes it at the actual point of creation instead.
--
-- Raises rather than silently ignoring community_name: the whole signup
-- transaction (including the auth.users row GoTrue was about to create)
-- rolls back cleanly, so no orphaned account is left behind either.
--
-- Does NOT touch any existing estate, profile, or account - this only
-- changes what happens on the next signup, nothing already in the
-- database is read, written, or removed.
-- ══════════════════════════════════════════════════════════════════════════

create or replace function private.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  community_name text := nullif(trim(new.raw_user_meta_data->>'community_name'), '');
  admin_phone text := nullif(trim(new.raw_user_meta_data->>'community_admin_phone'), '');
begin
  if community_name is not null then
    raise exception 'Creating a new community is not available.';
  end if;

  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name', coalesce(admin_phone, new.phone));

  insert into public.wallets (profile_id) values (new.id);
  return new;
end;
$$;
