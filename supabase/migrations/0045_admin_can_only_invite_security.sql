-- Admin could invite security or another admin (anything but finance,
-- 0024's own restriction) - narrowing further: admin can only invite
-- security now. Handing out admin access is an estate-owner decision, same
-- footing as finance already had; only super_admin grants either.
drop policy staff_invites_insert on staff_invites;
create policy staff_invites_insert on staff_invites for insert
  with check (
    invited_by = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and (
      (select private.auth_role()) = 'super_admin'
      or ((select private.auth_role()) = 'admin' and role = 'security')
    )
  );
