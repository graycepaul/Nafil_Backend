-- Market/finance access (marketplace moderation, transfer confirmation,
-- dues) moves from "any admin" to "only super_admin and the new finance
-- role" — a regular estate admin handles residents/issues/staff/
-- announcements, not money. profiles_select keeps 'admin' (that's the
-- Residents/Staff screens, unrelated) and additionally grants 'finance' the
-- same staff-wide read, since the market/dues/transfers screens need to
-- show resident names too.

drop policy profiles_select on profiles;
create policy profiles_select on profiles for select
  using (
    id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['admin'::user_role, 'security'::user_role, 'finance'::user_role]))
    or ((select private.auth_role()) = 'admin' and exists (
      select 1 from estate_join_requests jr
      where jr.profile_id = profiles.id and jr.estate_id = (select private.auth_estate_id()) and jr.status = 'pending'
    ))
  );

-- ── listings: suspend/lift-suspension replaces admin's old remove-listing power ──
drop policy listings_update on listings;
create policy listings_update on listings for update
  using (
    seller_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'finance')
  );

drop policy listings_delete on listings;
create policy listings_delete on listings for delete
  using (
    seller_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'finance')
  );

-- ── dues: finance replaces admin ──
drop policy dues_select on dues;
create policy dues_select on dues for select
  using (
    profile_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'finance')
  );

drop policy dues_update on dues;
create policy dues_update on dues for update
  using (
    profile_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'finance')
  );

drop policy dues_insert on dues;
create policy dues_insert on dues for insert
  with check (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'finance')
  );

drop policy dues_delete on dues;
create policy dues_delete on dues for delete
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'finance')
  );

-- ── transfers: finance replaces admin ──
drop policy transfers_select on transfers;
create policy transfers_select on transfers for select
  using (
    profile_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'finance')
  );

-- ── staff_invites: only super_admin may create a finance-role invite ──
drop policy staff_invites_insert on staff_invites;
create policy staff_invites_insert on staff_invites for insert
  with check (
    invited_by = (select auth.uid())
    and (
      (select private.auth_role()) = 'super_admin'
      or (
        estate_id = (select private.auth_estate_id())
        and (select private.auth_role()) = 'admin'
        and role <> 'finance'
      )
    )
  );

-- ── confirm_transfer / reject_transfer: finance replaces admin ──
create or replace function confirm_transfer(p_transfer_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  t transfers;
begin
  if (select private.auth_role()) not in ('finance', 'super_admin') then
    raise exception 'not authorized';
  end if;

  select * into t from transfers where id = p_transfer_id and status = 'pending';
  if not found then
    raise exception 'transfer not found or already resolved';
  end if;

  if (select private.auth_role()) = 'finance' and t.estate_id <> (select private.auth_estate_id()) then
    raise exception 'not authorized';
  end if;

  if t.purpose = 'wallet_topup' then
    update wallets set balance = balance + t.amount, updated_at = now() where profile_id = t.profile_id;
    insert into wallet_transactions (profile_id, label, amount, status) values (t.profile_id, t.label, t.amount, 'completed');
  elsif t.purpose = 'dues' then
    update dues set status = 'paid' where id = t.reference_id;
    insert into wallet_transactions (profile_id, label, amount, status) values (t.profile_id, t.label, -t.amount, 'completed');
  elsif t.purpose = 'marketplace_order' then
    update orders set status = 'paid' where id = t.reference_id;
    insert into wallet_transactions (profile_id, label, amount, status) values (t.profile_id, t.label, -t.amount, 'completed');
  end if;

  update transfers set status = 'confirmed', confirmed_at = now(), confirmed_by = auth.uid() where id = p_transfer_id;
end;
$$;

create or replace function reject_transfer(p_transfer_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  t transfers;
  o orders;
begin
  if (select private.auth_role()) not in ('finance', 'super_admin') then
    raise exception 'not authorized';
  end if;

  select * into t from transfers where id = p_transfer_id and status = 'pending';
  if not found then
    raise exception 'transfer not found or already resolved';
  end if;

  if (select private.auth_role()) = 'finance' and t.estate_id <> (select private.auth_estate_id()) then
    raise exception 'not authorized';
  end if;

  if t.purpose = 'marketplace_order' then
    update orders set status = 'cancelled' where id = t.reference_id returning * into o;
    update listings set status = 'active' where id = o.listing_id and type = 'good' and status = 'sold';
  end if;

  update transfers set status = 'rejected', confirmed_at = now(), confirmed_by = auth.uid() where id = p_transfer_id;
end;
$$;

-- ── notifications: suspension / reinstatement ──
alter table notifications drop constraint if exists notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned', 'issue_reported',
  'order_placed', 'order_completed', 'transfer_confirmed', 'transfer_rejected',
  'listing_suspended', 'listing_reinstated'
));

create or replace function private.notify_listing_suspension() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'suspended' and old.status is distinct from 'suspended' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.seller_id,
      'listing_suspended',
      'Listing suspended',
      '"' || new.title || '" was suspended by an admin and will no longer be shown in the marketplace. Contact estate management if you''d like to contest this.',
      jsonb_build_object('listing_id', new.id)
    );
  elsif old.status = 'suspended' and new.status = 'active' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.seller_id,
      'listing_reinstated',
      'Listing reinstated',
      '"' || new.title || '" is visible in the marketplace again.',
      jsonb_build_object('listing_id', new.id)
    );
  end if;
  return new;
end;
$$;

create trigger notify_listing_suspension
  after update on listings
  for each row execute function private.notify_listing_suspension();
