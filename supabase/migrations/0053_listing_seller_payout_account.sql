-- Marketplace purchases paid by transfer were routed to the estate's own
-- collection account and reconciled by admin/finance (0020/0022) - as if
-- the estate were collecting payment for a private sale between two
-- residents. That never made sense: the estate never receives this money,
-- so admin/finance had nothing real to confirm, and buyers were being told
-- to pay into an account that had nothing to do with the actual seller.
-- "Pay from wallet" was worse - adjust_wallet_balance only ever debits the
-- caller's own wallet (0050), so a wallet-paid marketplace order silently
-- destroyed the buyer's balance with no seller ever credited anything.
--
-- Fix: every listing now carries the seller's own payout account, shown to
-- the buyer at checkout instead of the estate's (see
-- MarketplaceCheckoutFlow.tsx). The seller - who's the only one who
-- actually knows whether the transfer landed in their account - confirms
-- receipt themselves through the orders_update policy they already have
-- (0020), the same way they already move an order from 'paid' to
-- 'completed' (see store.tsx's markCompleted). New marketplace orders no
-- longer create a `transfers` row at all; that queue is admin/finance-only
-- and never had visibility into a personal bank transfer between two
-- residents anyway. "wallet" is dropped as a marketplace payment method
-- client-side - no schema change needed for that half.

alter table listings add column seller_account_name text;
alter table listings add column seller_account_number text;
alter table listings add column seller_bank_name text;

-- Previously, the buyer found out their transfer was confirmed via
-- notify_transfer_resolved (0020) firing on the `transfers` row's
-- pending -> confirmed flip. A marketplace order no longer creates one of
-- those, so without a replacement, a buyer whose seller just confirmed
-- payment received would hear nothing until the order later hits
-- 'completed' (notify_order_completed, also 0020).
alter table notifications drop constraint notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned', 'issue_reported',
  'order_placed', 'order_completed', 'transfer_confirmed', 'transfer_rejected',
  'listing_suspended', 'listing_reinstated', 'transfer_contested', 'issue_feedback',
  'due_assigned', 'join_request_submitted', 'join_request_rejected', 'security_alert_reported',
  'order_payment_confirmed'
));

create or replace function private.notify_order_payment_confirmed() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  listing_title text;
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    select title into listing_title from listings where id = new.listing_id;
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.buyer_id,
      'order_payment_confirmed',
      'Payment confirmed',
      'The seller confirmed your payment for ' || coalesce(listing_title, 'your order') || '.',
      jsonb_build_object('order_id', new.id)
    );
  end if;
  return new;
end;
$$;

create trigger notify_order_payment_confirmed
  after update on orders
  for each row execute function private.notify_order_payment_confirmed();
