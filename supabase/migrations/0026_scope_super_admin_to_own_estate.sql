-- super_admin becomes an estate-scoped "owner" role instead of a
-- platform-wide overseer of every estate on the app. A resident creating a
-- new community via "Create Community" becomes that estate's super_admin —
-- its owner — not someone who can also see every other community's
-- residents, staff, dues, transfers, etc. (A future "manage multiple
-- estates" capability, if built, would be additive on top of this, not a
-- reason to keep the current unconditional global bypass around.)
--
-- estates_select stays open (qual = true): every user, including someone
-- mid-onboarding picking which estate to join, needs to browse estate
-- *names* — that was never the leak. estates_insert is untouched too: a new
-- estate is created via private.handle_new_user()'s trigger (SECURITY
-- DEFINER, bypasses RLS entirely), not a client-side insert, so that policy
-- is already inert.

-- ── announcements ──
drop policy announcements_delete on announcements;
create policy announcements_delete on announcements for delete
  using (
    estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role, 'security'::user_role])
  );

drop policy announcements_insert on announcements;
create policy announcements_insert on announcements for insert
  with check (
    author_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role, 'security'::user_role])
  );

drop policy announcements_select on announcements;
create policy announcements_select on announcements for select
  using (estate_id = (select private.auth_estate_id()));

-- ── dues ──
drop policy dues_delete on dues;
create policy dues_delete on dues for delete
  using (
    estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role])
  );

drop policy dues_insert on dues;
create policy dues_insert on dues for insert
  with check (
    estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role])
  );

drop policy dues_select on dues;
create policy dues_select on dues for select
  using (
    profile_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role]))
  );

drop policy dues_update on dues;
create policy dues_update on dues for update
  using (
    profile_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role]))
  );

-- ── estate_join_requests ──
drop policy join_requests_select on estate_join_requests;
create policy join_requests_select on estate_join_requests for select
  using (
    profile_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role]))
  );

-- ── estates: super_admin can only touch their own ──
drop policy estates_delete on estates;
create policy estates_delete on estates for delete
  using ((select private.auth_role()) = 'super_admin' and id = (select private.auth_estate_id()));

drop policy estates_update on estates;
create policy estates_update on estates for update
  using ((select private.auth_role()) = 'super_admin' and id = (select private.auth_estate_id()))
  with check ((select private.auth_role()) = 'super_admin' and id = (select private.auth_estate_id()));

-- ── household_members ──
drop policy household_members_staff_select on household_members;
create policy household_members_staff_select on household_members for select
  using (
    estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'security'::user_role, 'admin'::user_role])
  );

-- ── issues ──
drop policy issues_select on issues;
create policy issues_select on issues for select
  using (
    resident_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role]))
  );

drop policy issues_update on issues;
create policy issues_update on issues for update
  using (
    resident_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role]))
  );

-- ── listings ──
drop policy listings_delete on listings;
create policy listings_delete on listings for delete
  using (
    seller_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role]))
  );

drop policy listings_select on listings;
create policy listings_select on listings for select
  using (estate_id = (select private.auth_estate_id()));

drop policy listings_update on listings;
create policy listings_update on listings for update
  using (
    (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role]))
    or (seller_id = (select auth.uid()) and status <> 'suspended')
  );

-- ── orders (unchanged 'admin' reference here predates the finance role and is left as-is; only the super_admin bypass is scoped) ──
drop policy orders_select on orders;
create policy orders_select on orders for select
  using (
    buyer_id = (select auth.uid())
    or seller_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role]))
  );

drop policy orders_update on orders;
create policy orders_update on orders for update
  using (
    seller_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role]))
  );

-- ── profiles ──
drop policy profiles_select on profiles;
create policy profiles_select on profiles for select
  using (
    id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role, 'security'::user_role, 'finance'::user_role]))
    or ((select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role]) and exists (
      select 1 from estate_join_requests jr
      where jr.profile_id = profiles.id and jr.estate_id = (select private.auth_estate_id()) and jr.status = 'pending'
    ))
  );

drop policy profiles_update on profiles;
create policy profiles_update on profiles for update
  using (
    id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role]))
  )
  with check (
    id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role]))
  );

-- ── scheduled_visits ──
drop policy scheduled_visits_staff_select on scheduled_visits;
create policy scheduled_visits_staff_select on scheduled_visits for select
  using (
    estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'security'::user_role, 'admin'::user_role])
  );

-- ── staff_invites ──
drop policy staff_invites_insert on staff_invites;
create policy staff_invites_insert on staff_invites for insert
  with check (
    invited_by = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and (
      (select private.auth_role()) = 'super_admin'
      or ((select private.auth_role()) = 'admin' and role <> 'finance')
    )
  );

drop policy staff_invites_select on staff_invites;
create policy staff_invites_select on staff_invites for select
  using (
    estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role])
  );

-- ── transfers ──
drop policy transfers_select on transfers;
create policy transfers_select on transfers for select
  using (
    profile_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role]))
  );

-- ── visitor_logs / visitor_passes ──
drop policy visitor_logs_select on visitor_logs;
create policy visitor_logs_select on visitor_logs for select
  using (
    (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'security'::user_role, 'admin'::user_role]))
    or pass_id in (select id from visitor_passes where resident_id = (select auth.uid()))
  );

drop policy visitor_passes_select on visitor_passes;
create policy visitor_passes_select on visitor_passes for select
  using (
    resident_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'security'::user_role, 'admin'::user_role]))
  );

drop policy visitor_passes_update on visitor_passes;
create policy visitor_passes_update on visitor_passes for update
  using (
    resident_id = (select auth.uid())
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = any (array['super_admin'::user_role, 'security'::user_role, 'admin'::user_role]))
  );

-- ── wallets / wallet_transactions: no estate_id column, so scope via a join to profiles ──
drop policy wallets_select on wallets;
create policy wallets_select on wallets for select
  using (
    profile_id = (select auth.uid())
    or (
      (select private.auth_role()) = 'super_admin'
      and exists (select 1 from profiles p where p.id = wallets.profile_id and p.estate_id = (select private.auth_estate_id()))
    )
  );

drop policy wallet_transactions_select on wallet_transactions;
create policy wallet_transactions_select on wallet_transactions for select
  using (
    profile_id = (select auth.uid())
    or (
      (select private.auth_role()) = 'super_admin'
      and exists (select 1 from profiles p where p.id = wallet_transactions.profile_id and p.estate_id = (select private.auth_estate_id()))
    )
  );

-- ── RPC functions: drop the "role <> 'super_admin' and estate mismatch" bypass so super_admin is checked the same as everyone else ──
create or replace function approve_join_request(request_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  req estate_join_requests%rowtype;
begin
  if private.auth_role() not in ('admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into req from estate_join_requests where id = request_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;

  if req.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  update estate_join_requests
     set status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
   where id = request_id;

  update profiles
     set estate_id = req.estate_id, unit_no = req.unit_no, approved = true
   where id = req.profile_id;
end;
$$;

create or replace function reject_join_request(request_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  req estate_join_requests%rowtype;
begin
  if private.auth_role() not in ('admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into req from estate_join_requests where id = request_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;

  if req.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  update estate_join_requests
     set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
   where id = request_id;
end;
$$;

create or replace function revoke_staff_invite(invite_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  inv staff_invites%rowtype;
begin
  if private.auth_role() not in ('admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into inv from staff_invites where id = invite_id and status = 'pending';
  if not found then
    raise exception 'Invite not found or already resolved';
  end if;

  if inv.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  update staff_invites set status = 'revoked', reviewed_at = now() where id = invite_id;
end;
$$;

create or replace function check_in_scheduled_visit(visit_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  visit scheduled_visits%rowtype;
  officer_id uuid;
begin
  officer_id := auth.uid();
  if private.auth_role() not in ('security', 'admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into visit from scheduled_visits where id = visit_id;
  if not found then
    raise exception 'Scheduled visit not found';
  end if;

  if visit.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  if visit.status <> 'pending' then
    raise exception 'This visit is already "%"', visit.status;
  end if;

  update scheduled_visits set status = 'arrived' where id = visit_id;

  insert into visitor_logs (estate_id, security_id, visitor_name, method, checked_in_at)
  values (visit.estate_id, officer_id, visit.visitor_name, 'manual', now());
end;
$$;

create or replace function record_household_member_scan(member_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  member household_members%rowtype;
begin
  if private.auth_role() not in ('security', 'admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into member from household_members where id = member_id;
  if not found then
    raise exception 'Household member not found';
  end if;

  if member.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  update household_members set last_scanned_at = now() where id = member_id;
end;
$$;

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

  if t.estate_id <> (select private.auth_estate_id()) then
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

  if t.estate_id <> (select private.auth_estate_id()) then
    raise exception 'not authorized';
  end if;

  if t.purpose = 'marketplace_order' then
    update orders set status = 'cancelled' where id = t.reference_id returning * into o;
    update listings set status = 'active' where id = o.listing_id and type = 'good' and status = 'sold';
  end if;

  update transfers set status = 'rejected', confirmed_at = now(), confirmed_by = auth.uid() where id = p_transfer_id;
end;
$$;
