-- Marketplace orders, bank-transfer reconciliation, and the admin/vendor
-- tracking that were missing from 0018/0019: sellers had no record of who
-- bought their listing, and "bank transfer" (wallet top-up, dues, or a
-- purchase) just showed the resident a toast with nothing durable behind it
-- for anyone to confirm.
--
-- `orders` gives every marketplace purchase a real row, regardless of
-- payment method, so sellers can see and track what sold.
--
-- `transfers` is a single queue for all three "I sent a bank transfer,
-- please confirm" cases (wallet top-up, dues, marketplace order), so admins
-- have one place to review and settle them instead of three. `reference_id`
-- points at the dues/orders row being settled, and is null for a wallet
-- top-up (nothing else to update besides the wallet itself).

create type order_status as enum ('pending_transfer', 'paid', 'completed', 'cancelled');

create table orders (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  listing_id uuid not null references listings(id) on delete cascade,
  seller_id uuid not null references profiles(id) on delete cascade,
  buyer_id uuid not null references profiles(id) on delete cascade,
  amount integer not null,
  payment_method text not null,
  status order_status not null default 'paid',
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index orders_seller_idx on orders(seller_id);
create index orders_buyer_idx on orders(buyer_id);
create index orders_estate_idx on orders(estate_id);

alter table orders enable row level security;

create policy orders_select on orders for select
  using (
    buyer_id = (select auth.uid())
    or seller_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create policy orders_insert on orders for insert
  with check (
    buyer_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
  );

-- Sellers move their own orders forward (paid -> completed); admins can also
-- intervene. The state machine itself is enforced client-side, same as
-- issues' NEXT_STATUS map.
create policy orders_update on orders for update
  using (
    seller_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create type transfer_purpose as enum ('wallet_topup', 'dues', 'marketplace_order');
create type transfer_status as enum ('pending', 'confirmed', 'rejected');

create table transfers (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  purpose transfer_purpose not null,
  reference_id uuid,
  amount integer not null,
  label text not null,
  status transfer_status not null default 'pending',
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  confirmed_by uuid references profiles(id)
);

create index transfers_profile_idx on transfers(profile_id);
create index transfers_estate_status_idx on transfers(estate_id, status);

alter table transfers enable row level security;

create policy transfers_select on transfers for select
  using (
    profile_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create policy transfers_insert on transfers for insert
  with check (
    profile_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
  );

-- Deliberately no update/delete policy, same reasoning as notifications:
-- a transfer only ever changes status through confirm_transfer/reject_transfer
-- below, which run SECURITY DEFINER after checking the caller is estate staff.

create or replace function confirm_transfer(p_transfer_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  t transfers;
begin
  if (select private.auth_role()) not in ('admin', 'super_admin') then
    raise exception 'not authorized';
  end if;

  select * into t from transfers where id = p_transfer_id and status = 'pending';
  if not found then
    raise exception 'transfer not found or already resolved';
  end if;

  if (select private.auth_role()) = 'admin' and t.estate_id <> (select private.auth_estate_id()) then
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
begin
  if (select private.auth_role()) not in ('admin', 'super_admin') then
    raise exception 'not authorized';
  end if;

  select * into t from transfers where id = p_transfer_id and status = 'pending';
  if not found then
    raise exception 'transfer not found or already resolved';
  end if;

  if (select private.auth_role()) = 'admin' and t.estate_id <> (select private.auth_estate_id()) then
    raise exception 'not authorized';
  end if;

  if t.purpose = 'marketplace_order' then
    update orders set status = 'cancelled' where id = t.reference_id;
  end if;

  update transfers set status = 'rejected', confirmed_at = now(), confirmed_by = auth.uid() where id = p_transfer_id;
end;
$$;

-- ── Notifications: new types for sellers/buyers/transfer submitters ─────
alter table notifications drop constraint if exists notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned', 'issue_reported',
  'order_placed', 'order_completed', 'transfer_confirmed', 'transfer_rejected'
));

create or replace function private.notify_order_placed() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  listing_title text;
begin
  select title into listing_title from listings where id = new.listing_id;
  insert into notifications (profile_id, type, title, body, data)
  values (
    new.seller_id,
    'order_placed',
    'New order',
    case new.status
      when 'pending_transfer' then coalesce(listing_title, 'Your listing') || ' was ordered, awaiting transfer confirmation.'
      else coalesce(listing_title, 'Your listing') || ' was just purchased.'
    end,
    jsonb_build_object('order_id', new.id, 'listing_id', new.listing_id)
  );
  return new;
end;
$$;

create trigger notify_order_placed
  after insert on orders
  for each row execute function private.notify_order_placed();

create or replace function private.notify_order_completed() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.buyer_id,
      'order_completed',
      'Order completed',
      'Your order was marked as fulfilled by the seller.',
      jsonb_build_object('order_id', new.id)
    );
  end if;
  return new;
end;
$$;

create trigger notify_order_completed
  after update on orders
  for each row execute function private.notify_order_completed();

create or replace function private.notify_transfer_resolved() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    insert into notifications (profile_id, type, title, body, data)
    values (new.profile_id, 'transfer_confirmed', 'Transfer confirmed', new.label || ' was confirmed.', jsonb_build_object('transfer_id', new.id));
  elsif new.status = 'rejected' and old.status is distinct from 'rejected' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.profile_id,
      'transfer_rejected',
      'Transfer not confirmed',
      new.label || ' could not be confirmed. Please contact estate management.',
      jsonb_build_object('transfer_id', new.id)
    );
  end if;
  return new;
end;
$$;

create trigger notify_transfer_resolved
  after update on transfers
  for each row execute function private.notify_transfer_resolved();
