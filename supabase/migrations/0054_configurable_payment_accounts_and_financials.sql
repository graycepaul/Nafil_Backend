-- Two gaps found while building marketplace payout accounts (0053):
--
-- 1. The wallet top-up / estate dues collection account was a literal
--    hardcoded string in PaymentMethodSheet.tsx ("Nafil Estates
--    Collections", 0123456789 · Providus Bank) - the same fake account for
--    every estate on the platform, with no way for super_admin to set a
--    real one.
--
-- 2. No aggregate financial view existed anywhere - super_admin had to
--    infer wallet/dues/transfer totals by reading individual list screens.
--
-- Fix: every estate gets its own payout account per purpose (wallet
-- top-up, and each of the three due categories), configurable by
-- super_admin, plus a shared pool of previously-entered accounts they can
-- reuse instead of retyping the same details for a second purpose - e.g.
-- "service fee" and "security" often land in the same estate account.

create type payment_purpose as enum ('wallet_topup', 'general', 'service_fee', 'security');

-- The reusable pool: every account super_admin has ever entered for this
-- estate, independent of which purpose(s) it's currently assigned to.
create table estate_payout_accounts (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  account_name text not null,
  account_number text not null,
  bank_name text not null,
  created_at timestamptz not null default now(),
  unique (estate_id, account_number, bank_name)
);

create index estate_payout_accounts_estate_idx on estate_payout_accounts(estate_id);

alter table estate_payout_accounts enable row level security;

create policy estate_payout_accounts_select on estate_payout_accounts for select
  using (
    (select private.auth_role()) = 'super_admin'
    and estate_id = (select private.auth_estate_id())
  );

create policy estate_payout_accounts_insert on estate_payout_accounts for insert
  with check (
    (select private.auth_role()) = 'super_admin'
    and estate_id = (select private.auth_estate_id())
  );

-- Which account (from the pool above) is currently assigned to each
-- purpose - at most one per purpose per estate.
create table estate_payment_settings (
  estate_id uuid not null references estates(id) on delete cascade,
  purpose payment_purpose not null,
  account_id uuid not null references estate_payout_accounts(id) on delete restrict,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id) on delete set null,
  primary key (estate_id, purpose)
);

alter table estate_payment_settings enable row level security;

create policy estate_payment_settings_select on estate_payment_settings for select
  using (
    (select private.auth_role()) = 'super_admin'
    and estate_id = (select private.auth_estate_id())
  );

create policy estate_payment_settings_insert on estate_payment_settings for insert
  with check (
    (select private.auth_role()) = 'super_admin'
    and estate_id = (select private.auth_estate_id())
  );

create policy estate_payment_settings_update on estate_payment_settings for update
  using (
    (select private.auth_role()) = 'super_admin'
    and estate_id = (select private.auth_estate_id())
  )
  with check (
    (select private.auth_role()) = 'super_admin'
    and estate_id = (select private.auth_estate_id())
  );

-- Resolves every purpose the caller's own estate has configured, for the
-- checkout screens (wallet top-up, dues payment) - security definer so a
-- resident/admin can read the resolved account without needing direct
-- table access to estate_payout_accounts (super_admin-only above).
create or replace function get_payment_accounts()
returns table(purpose payment_purpose, account_name text, account_number text, bank_name text)
language sql stable security definer set search_path = public as $$
  select s.purpose, a.account_name, a.account_number, a.bank_name
  from estate_payment_settings s
  join estate_payout_accounts a on a.id = s.account_id
  where s.estate_id = private.auth_estate_id();
$$;

-- Client-wide financial snapshot for super_admin's dashboard. Marketplace
-- volume is reported separately from the estate-revenue totals above it -
-- since 0053, that money goes straight to the seller's own account and
-- never touches the estate, so it isn't estate revenue, just useful
-- context on how much marketplace activity is happening.
create or replace function get_financials_overview()
returns table (
  total_wallet_balance bigint,
  total_topup_confirmed bigint,
  total_dues_paid bigint,
  total_dues_outstanding bigint,
  dues_paid_general bigint,
  dues_paid_service_fee bigint,
  dues_paid_security bigint,
  transfers_pending_count bigint,
  transfers_pending_amount bigint,
  transfers_confirmed_count bigint,
  transfers_confirmed_amount bigint,
  transfers_rejected_count bigint,
  marketplace_volume bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select private.auth_role()) <> 'super_admin' then
    raise exception 'not authorized';
  end if;

  return query
  select
    (select coalesce(sum(balance), 0)::bigint from wallets),
    (select coalesce(sum(amount), 0)::bigint from wallet_transactions where amount > 0 and label ilike 'Wallet top-up%'),
    (select coalesce(sum(amount), 0)::bigint from dues where status = 'paid'),
    (select coalesce(sum(amount), 0)::bigint from dues where status in ('due', 'overdue')),
    (select coalesce(sum(amount), 0)::bigint from dues where status = 'paid' and category = 'general'),
    (select coalesce(sum(amount), 0)::bigint from dues where status = 'paid' and category = 'service_fee'),
    (select coalesce(sum(amount), 0)::bigint from dues where status = 'paid' and category = 'security'),
    (select count(*) from transfers where status = 'pending'),
    (select coalesce(sum(amount), 0)::bigint from transfers where status = 'pending'),
    (select count(*) from transfers where status = 'confirmed'),
    (select coalesce(sum(amount), 0)::bigint from transfers where status = 'confirmed'),
    (select count(*) from transfers where status = 'rejected'),
    (select coalesce(sum(amount), 0)::bigint from orders where status in ('paid', 'completed'));
end;
$$;
