-- Marketplace/orders need to show a seller's or buyer's name to a plain
-- resident who isn't them (e.g. a buyer viewing who they're purchasing
-- from), but profiles_select only allows self, security/admin, or
-- super_admin. Opening that policy up to "anyone in the same estate" would
-- also expose resident_code (the gate QR code) to any curious resident,
-- since RLS is row-level, not column-level, and PostgREST lets a client
-- query any column once a row is visible at all.
--
-- Instead this is a SECURITY DEFINER function returning only the four
-- harmless display columns, scoped to the caller's own estate, following
-- the same bypass-RLS-narrowly pattern as private.auth_role() and the
-- confirm_transfer/reject_transfer functions.
create or replace function get_public_profiles(profile_ids uuid[])
returns table(id uuid, full_name text, unit_no text, avatar_url text)
language sql security definer set search_path = public as $$
  select p.id, p.full_name, p.unit_no, p.avatar_url
  from profiles p
  where p.id = any(profile_ids)
    and p.estate_id = (select private.auth_estate_id());
$$;
