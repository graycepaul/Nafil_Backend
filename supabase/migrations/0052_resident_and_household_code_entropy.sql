-- resident_code (permanent e-ID) and household_members.code (permanent
-- frequent-visitor gate code) were 6 uppercase hex chars (0009) -
-- 16^6 ≈ 16.7 million possibilities. Both are long-lived (resident_code is
-- effectively permanent) physical-access credentials, same threat model as
-- staff_invites.code, which 0042 already bumped from 8 to 12 hex chars for
-- exactly this reasoning. Bringing these in line: 12 hex chars raises it to
-- 16^12 ≈ 281 trillion.
--
-- Only the defaults change, so already-issued codes/printed cards keep
-- working - nothing here touches existing rows, same as 0042.

alter table profiles
  alter column resident_code set default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

alter table household_members
  alter column code set default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

create or replace function public.regenerate_resident_code() returns text
  language plpgsql security definer set search_path = public as $$
declare
  new_code text;
begin
  new_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  update profiles set resident_code = new_code where id = auth.uid();
  return new_code;
end;
$$;
