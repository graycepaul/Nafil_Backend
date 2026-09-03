-- The community signup form now collects country/state as structured fields
-- (not folded into the free-text address) and the admin's phone number up
-- front rather than deferring it to the resident-only profile-setup step.
alter table estates add column if not exists country text;
alter table estates add column if not exists state text;

create or replace function private.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  community_name text := nullif(trim(new.raw_user_meta_data->>'community_name'), '');
  community_address text := nullif(trim(new.raw_user_meta_data->>'community_address'), '');
  community_country text := nullif(trim(new.raw_user_meta_data->>'community_country'), '');
  community_state text := nullif(trim(new.raw_user_meta_data->>'community_state'), '');
  admin_phone text := nullif(trim(new.raw_user_meta_data->>'community_admin_phone'), '');
  new_estate_id uuid;
begin
  if community_name is not null then
    insert into public.estates (name, address, country, state)
    values (community_name, community_address, community_country, community_state)
    returning id into new_estate_id;

    insert into public.profiles (id, full_name, phone, estate_id, role, approved)
    values (new.id, new.raw_user_meta_data->>'full_name', coalesce(admin_phone, new.phone), new_estate_id, 'admin', true);
  else
    insert into public.profiles (id, full_name, phone)
    values (new.id, new.raw_user_meta_data->>'full_name', new.phone);
  end if;

  insert into public.wallets (profile_id) values (new.id);
  return new;
end;
$$;
