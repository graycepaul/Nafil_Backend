-- Wallet and estate dues. Payments are still simulated: nothing here talks to a
-- real payment gateway. "Card" and "wallet" methods settle immediately (the
-- client calls adjust_wallet_balance / updates dues directly); "transfer" just
-- records a pending transaction for a human to reconcile later. Wiring an
-- actual gateway (Paystack/Flutterwave) is a separate follow-up.

create type wallet_transaction_status as enum ('completed', 'pending');
create type due_status as enum ('due', 'overdue', 'paid');

create table wallets (
  profile_id uuid primary key references profiles(id) on delete cascade,
  balance integer not null default 0,
  updated_at timestamptz not null default now()
);

create table wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  label text not null,
  amount integer not null,
  status wallet_transaction_status not null default 'completed',
  created_at timestamptz not null default now()
);

create index wallet_transactions_profile_idx on wallet_transactions(profile_id);

create table dues (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  label text not null,
  amount integer not null,
  due_date timestamptz not null,
  status due_status not null default 'due',
  created_at timestamptz not null default now()
);

create index dues_estate_idx on dues(estate_id);
create index dues_profile_idx on dues(profile_id);

alter table wallets enable row level security;
alter table wallet_transactions enable row level security;
alter table dues enable row level security;

-- ── wallets: resident owns their own balance row ───────────────────────
create policy wallets_select on wallets for select
  using (profile_id = (select auth.uid()) or (select private.auth_role()) = 'super_admin');

create policy wallets_update on wallets for update
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

-- ── wallet_transactions: resident's own ledger, append-only from the client ──
create policy wallet_transactions_select on wallet_transactions for select
  using (profile_id = (select auth.uid()) or (select private.auth_role()) = 'super_admin');

create policy wallet_transactions_insert on wallet_transactions for insert
  with check (profile_id = (select auth.uid()));

-- ── dues: resident reads/pays their own; admin assigns and manages their estate's ──
create policy dues_select on dues for select
  using (
    profile_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create policy dues_update on dues for update
  using (
    profile_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create policy dues_insert on dues for insert
  with check (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create policy dues_delete on dues for delete
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

-- Every resident needs a wallet the moment their profile exists.
create or replace function private.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name', new.phone);
  insert into public.wallets (profile_id) values (new.id);
  return new;
end;
$$;

-- Backfill wallets for profiles created before this migration existed.
insert into wallets (profile_id)
select id from profiles
on conflict (profile_id) do nothing;

-- Atomic balance change, callable by the owning resident only. RLS on wallets
-- still applies underneath (security invoker, not definer): the WHERE clause
-- narrows to the caller's own row, and wallets_update requires the same.
create or replace function adjust_wallet_balance(delta integer) returns void
  language sql security invoker set search_path = public as $$
  update wallets set balance = balance + delta, updated_at = now() where profile_id = auth.uid();
$$;
