-- Placing an order for a good previously did nothing to the listing itself —
-- it stayed 'active' and buyable by anyone else, since the buyer has no
-- update permission on someone else's listing (listings_update only allows
-- the seller or estate staff). A resident could buy the same sofa twice.
--
-- Goods are one-off items, so reserve them the moment an order lands,
-- regardless of payment method (a pending bank transfer still means someone
-- has committed to buying it). Services aren't one-off, so they're left
-- alone. If a transfer later gets rejected, the listing goes back to
-- 'active' so it can be sold again.
create or replace function private.reserve_good_listing() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  update listings
  set status = 'sold'
  where id = new.listing_id and type = 'good' and status = 'active';
  return new;
end;
$$;

create trigger reserve_good_listing
  after insert on orders
  for each row execute function private.reserve_good_listing();

create or replace function reject_transfer(p_transfer_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  t transfers;
  o orders;
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
    update orders set status = 'cancelled' where id = t.reference_id returning * into o;
    update listings set status = 'active' where id = o.listing_id and type = 'good' and status = 'sold';
  end if;

  update transfers set status = 'rejected', confirmed_at = now(), confirmed_by = auth.uid() where id = p_transfer_id;
end;
$$;
