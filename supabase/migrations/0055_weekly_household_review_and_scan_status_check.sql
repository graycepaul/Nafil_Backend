-- Two things, both about household/frequent-visitor cards (0013):
--
-- 1. Add 'weekly' as a review cadence, alongside monthly/quarterly/
--    semiannual/yearly.
--
-- 2. record_household_member_scan() never checked the card's own status
--    before recording a scan - it trusted the caller (security/index.tsx)
--    to have already branched on status client-side and only call this RPC
--    for an 'active' card. That's true of the shipped app today, but the
--    RPC itself is what should be the actual enforcement point, the same
--    way pay_dues_from_wallet validates ownership/balance server-side
--    rather than trusting the client's math. Without this, a revoked or
--    pending_review card's last_scanned_at could still be recorded by
--    anything that called this RPC directly - it wouldn't notify the
--    resident (notify_household_member_scanned already gates on
--    new.status = 'active'), but it's a real gap between "the UI denies
--    this" and "the database enforces it".

alter table household_members drop constraint household_members_review_frequency_check;
alter table household_members add constraint household_members_review_frequency_check
  check (review_frequency is null or review_frequency in ('weekly', 'monthly', 'quarterly', 'semiannual', 'yearly'));

create or replace function private.set_household_next_review() returns trigger
  language plpgsql as $$
begin
  if new.review_frequency is not null and (
    tg_op = 'INSERT'
    or new.review_frequency is distinct from old.review_frequency
    or (new.status = 'active' and old.status is distinct from 'active')
  ) then
    new.next_review_at := now() + case new.review_frequency
      when 'weekly' then interval '1 week'
      when 'monthly' then interval '1 month'
      when 'quarterly' then interval '3 months'
      when 'semiannual' then interval '6 months'
      when 'yearly' then interval '1 year'
    end;
  end if;
  return new;
end;
$$;

create or replace function public.record_household_member_scan(member_id uuid) returns void
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

  if private.auth_role() <> 'super_admin' and member.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  if member.status <> 'active' then
    raise exception 'This card is % and cannot be scanned in', member.status;
  end if;

  update household_members set last_scanned_at = now() where id = member_id;
end;
$$;
