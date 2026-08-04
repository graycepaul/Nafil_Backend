-- profiles_select couldn't see an applicant's profile until AFTER approval —
-- chicken-and-egg, since estate_id (what the admin clause checks) is exactly
-- what's pending. Found live: the admin queue rendered every applicant as
-- "Unnamed" because the embedded profiles join returned nothing under RLS.
--
-- Fix: an admin may also read a profile that has a pending join request
-- targeting their own estate, regardless of that profile's estate_id.
drop policy if exists profiles_select on profiles;

create policy profiles_select on profiles for select
  using (
    id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('admin', 'security'))
    or (
      (select private.auth_role()) = 'admin'
      and exists (
        select 1 from estate_join_requests jr
        where jr.profile_id = profiles.id
          and jr.estate_id = (select private.auth_estate_id())
          and jr.status = 'pending'
      )
    )
  );
