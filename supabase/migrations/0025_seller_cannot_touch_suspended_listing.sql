-- A suspended listing must stay frozen for its seller until finance/
-- super_admin lifts it — otherwise the seller could just set it back to
-- 'active' themselves (or edit it) via the same seller_id = me clause that
-- lets them manage their own listings normally. The USING clause on an
-- UPDATE policy evaluates against the row as it exists *before* the
-- update, so referencing status here checks the current (old) value.
drop policy listings_update on listings;
create policy listings_update on listings for update
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'finance')
    or (seller_id = (select auth.uid()) and status <> 'suspended')
  );
