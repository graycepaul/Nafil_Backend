-- Money integrity: the database now enforces what the app only assumed.
--
-- Until now the only rules on money columns were row-level security checks on
-- *who* may insert, not *what*:
--   * transfers_insert let a resident insert any amount, any status (including
--     'confirmed') and a 'dues' transfer pointing at any due id; confirm_transfer
--     then marks that due paid without checking the amount or the owner.
--   * orders.status defaults to 'paid' and orders_insert never constrained it, so
--     a buyer could create an order already marked paid.
--   * Nothing stopped a zero or negative amount. A negative due is the worst
--     case: pay_dues_from_wallet does `balance - total`, so paying it credits the
--     wallet.
-- All existing rows satisfy every rule below (checked before writing this).

-- ── Amount constraints ────────────────────────────────────────────────────
alter table transfers add constraint transfers_amount_positive check (amount > 0);
alter table dues add constraint dues_amount_positive check (amount > 0);
alter table orders add constraint orders_amount_positive check (amount > 0);
alter table listings add constraint listings_price_positive check (price > 0);
alter table listings add constraint listings_price_range check (price_max is null or price_max >= price);
alter table listings add constraint listings_delivery_fee_non_negative check (delivery_fee >= 0);
alter table wallets add constraint wallets_balance_non_negative check (balance >= 0);

-- ── Transfers: always created pending, and only for a real, matching charge ──
-- Skipped when there is no signed-in user (migrations, backups, the service
-- role): row-level security already guarantees profile_id = auth.uid() for
-- every client insert, so clients always take this path.
create or replace function private.enforce_transfer_insert() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  due dues%rowtype;
  ord orders%rowtype;
begin
  if auth.uid() is null then
    return new;
  end if;

  -- Only confirm_transfer / reject_transfer may move a transfer out of pending.
  new.status := 'pending';
  new.confirmed_at := null;
  new.confirmed_by := null;

  if new.purpose = 'wallet_topup' then
    if new.reference_id is not null then
      raise exception 'a wallet top-up does not reference anything';
    end if;

  elsif new.purpose = 'dues' then
    select * into due from dues where id = new.reference_id;
    -- Same visibility rule pay_dues_from_wallet uses: the submitter's own dues,
    -- plus the unit's dues for a household member with full access.
    if not found
       or due.profile_id not in (select private.auth_household_profile_ids())
       or due.estate_id <> new.estate_id
       or due.status = 'paid' then
      raise exception 'that due was not found, is already paid, or is not yours';
    end if;
    if due.amount <> new.amount then
      raise exception 'the transfer amount must match the due';
    end if;

  elsif new.purpose = 'marketplace_order' then
    select * into ord from orders where id = new.reference_id;
    if not found or ord.buyer_id <> auth.uid() or ord.estate_id <> new.estate_id then
      raise exception 'that order was not found or is not yours';
    end if;
    if ord.amount <> new.amount then
      raise exception 'the transfer amount must match the order';
    end if;
  end if;

  -- One open transfer per charge: a double tap must not create a duplicate.
  if new.reference_id is not null and exists (
    select 1 from transfers
     where purpose = new.purpose and reference_id = new.reference_id and status = 'pending'
  ) then
    raise exception 'a transfer for this charge is already awaiting confirmation';
  end if;

  return new;
end;
$$;

create trigger enforce_transfer_insert
  before insert on transfers
  for each row execute function private.enforce_transfer_insert();

-- ── Orders: always created awaiting transfer, for an available listing ──────
create or replace function private.enforce_order_insert() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  l listings%rowtype;
begin
  if auth.uid() is null then
    return new;
  end if;

  select * into l from listings where id = new.listing_id;
  if not found or l.estate_id <> new.estate_id then
    raise exception 'listing not found';
  end if;
  if l.status <> 'active' then
    raise exception 'this listing is no longer available';
  end if;
  if new.seller_id <> l.seller_id then
    raise exception 'seller does not match the listing';
  end if;
  if new.buyer_id = l.seller_id then
    raise exception 'you cannot buy your own listing';
  end if;

  -- Only the seller (confirming receipt) or an admin may move it forward.
  new.status := 'pending_transfer';
  new.completed_at := null;
  return new;
end;
$$;

create trigger enforce_order_insert
  before insert on orders
  for each row execute function private.enforce_order_insert();

-- ── Cancelling an order ───────────────────────────────────────────────────
-- Placing an order for a good reserves it immediately (0022). Nothing could
-- undo that, so a buyer who never paid kept the item locked until the seller
-- relisted it by hand. The buyer or the seller may cancel an order that is
-- still awaiting transfer; once it is paid it can no longer be cancelled here.
-- A good that was reserved by this order goes back on sale unless another live
-- order still holds it.
create or replace function public.cancel_order(p_order_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  ord orders%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not authorized';
  end if;

  select * into ord from orders where id = p_order_id for update;
  if not found or auth.uid() not in (ord.buyer_id, ord.seller_id) then
    raise exception 'order not found';
  end if;
  if ord.status <> 'pending_transfer' then
    raise exception 'only an order that is still awaiting transfer can be cancelled';
  end if;

  update orders set status = 'cancelled' where id = ord.id;

  update listings
     set status = 'active'
   where id = ord.listing_id
     and type = 'good'
     and status = 'sold'
     and not exists (
       select 1 from orders o
        where o.listing_id = ord.listing_id
          and o.id <> ord.id
          and o.status in ('pending_transfer', 'paid', 'completed')
     );
end;
$$;

revoke execute on function public.cancel_order(uuid) from public, anon;
grant execute on function public.cancel_order(uuid) to authenticated;
