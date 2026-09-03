-- Self-serve estate onboarding ("sign up as a community"), the missing piece
-- next to resident signup and staff invites. Until now every estate was
-- created by hand (see Nafil Backend/README's bootstrap instructions) and
-- every admin was provisioned by an existing admin — there was no way for a
-- brand-new estate to get itself onto the platform at all.
--
-- This doesn't add a new signup endpoint or table. It extends the same
-- handle_new_user() trigger that already reads `full_name` out of
-- raw_user_meta_data at signup time: if the signup also carries a
-- `community_name`, the trigger creates that estate and makes the signing-up
-- user its first admin (approved immediately — there's no existing admin to
-- approve them against, since they ARE the first one). An ordinary resident
-- or staff signup has no such key and falls through to the unchanged
-- existing behavior.
create or replace function private.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  community_name text := nullif(trim(new.raw_user_meta_data->>'community_name'), '');
  community_address text := nullif(trim(new.raw_user_meta_data->>'community_address'), '');
  new_estate_id uuid;
begin
  if community_name is not null then
    insert into public.estates (name, address)
    values (community_name, community_address)
    returning id into new_estate_id;

    insert into public.profiles (id, full_name, phone, estate_id, role, approved)
    values (new.id, new.raw_user_meta_data->>'full_name', new.phone, new_estate_id, 'admin', true);
  else
    insert into public.profiles (id, full_name, phone)
    values (new.id, new.raw_user_meta_data->>'full_name', new.phone);
  end if;

  insert into public.wallets (profile_id) values (new.id);
  return new;
end;
$$;
