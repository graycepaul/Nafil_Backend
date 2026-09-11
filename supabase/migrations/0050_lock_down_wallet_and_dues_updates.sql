-- wallets_update and dues_update (resident branch) only check row ownership,
-- not which column or value is being written. Over PostgREST that means a
-- resident can PATCH their own wallets.balance to any number directly, or
-- PATCH their own dues.status to 'paid' with no wallet debit and no transfer
-- ever confirmed. Both bypass the app's actual money-movement logic entirely.
--
-- Fix: remove direct client UPDATE on both tables (same "no update policy,
-- state changes only through a SECURITY DEFINER function" pattern already
-- used for transfers/orders below), and route the one legitimate resident
-- flow that needs both — paying dues out of the wallet — through a single
-- atomic RPC that validates ownership and balance before touching either row.

drop policy wallets_update on wallets;

drop policy dues_update on dues;
create policy dues_update on dues for update
  using (
    estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role])
  );

-- Re-declared security definer (was invoker): now that wallets has no client
-- update policy, this is the only way balance changes. Still self-only.
create or replace function adjust_wallet_balance(delta integer) returns void
  language sql security definer set search_path = public as $$
  update wallets set balance = balance + delta, updated_at = now() where profile_id = auth.uid();
$$;

-- Atomically pays one or more of the caller's own unpaid dues out of their
-- own wallet: validates every id belongs to auth.uid() and isn't already
-- paid, checks the balance covers the total, then debits the wallet, flips
-- the dues to paid, and logs the ledger entry all in one transaction.
create or replace function pay_dues_from_wallet(p_due_ids uuid[]) returns void
  language plpgsql security definer set search_path = public as $$
declare
  v_total integer;
  v_count integer;
  v_balance integer;
  v_label text;
begin
  if p_due_ids is null or array_length(p_due_ids, 1) is null then
    raise exception 'no dues specified';
  end if;

  -- Lock the matching rows before aggregating so a concurrent call for the
  -- same dues blocks here instead of also passing this check.
  perform 1 from dues
    where id = any(p_due_ids) and profile_id = auth.uid() and status <> 'paid'
    for update;

  select count(*), coalesce(sum(amount), 0)
    into v_count, v_total
    from dues
    where id = any(p_due_ids) and profile_id = auth.uid() and status <> 'paid';

  if v_count <> array_length(p_due_ids, 1) then
    raise exception 'one or more dues were not found, already paid, or not yours';
  end if;

  select balance into v_balance from wallets where profile_id = auth.uid() for update;
  if v_balance is null or v_balance < v_total then
    raise exception 'insufficient wallet balance';
  end if;

  select case when count(*) = 1 then max('Estate dues · ' || label) else 'Estate dues · ' || count(*) || ' items' end
    into v_label
    from dues where id = any(p_due_ids);

  update wallets set balance = balance - v_total, updated_at = now() where profile_id = auth.uid();
  update dues set status = 'paid' where id = any(p_due_ids);
  insert into wallet_transactions (profile_id, label, amount, status)
    values (auth.uid(), v_label, -v_total, 'completed');
end;
$$;
