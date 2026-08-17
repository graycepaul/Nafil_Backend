-- ══════════════════════════════════════════════════════════════════════════
-- Household/frequent-visitor cards: periodic review + scan notifications
--
-- Two problems with a standing household card that's only ever revoked
-- manually: a resident forgets they gave a driver or an ex-nanny standing
-- access and it just sits there valid forever, and a resident has no way of
-- knowing their own card is actually being used day to day.
--
-- This adds:
--   - A review cadence per card (monthly/quarterly/semiannual/yearly). A
--     scheduled job (see Nafil Backend/app/services/scheduler.py) flips the
--     card to 'pending_review' once its cadence lapses. A distinct state
--     from 'revoked', since the resident didn't choose to cut this person
--     off, the card just needs a fresh look. Reactivating (a plain client
--     update back to 'active', same as the existing revoke flow) resets the
--     next review date via trigger rather than trusting the client to
--     compute it.
--   - A notification to the resident every time their household member's
--     card is actually used at the gate, so "someone I gave a standing card
--     to is on their way in" is never a surprise.
-- ══════════════════════════════════════════════════════════════════════════

alter table household_members
  add column review_frequency text
    check (review_frequency is null or review_frequency in ('monthly', 'quarterly', 'semiannual', 'yearly')),
  add column next_review_at timestamptz,
  add column last_scanned_at timestamptz;

-- Existing rows predate this feature. Default them to the least demanding
-- cadence rather than leaving them with no review date at all (which the
-- scheduled job below would otherwise never touch).
update household_members
  set review_frequency = 'yearly', next_review_at = now() + interval '1 year'
  where review_frequency is null and status = 'active';

-- 'pending_review' is a third status distinct from 'revoked': the resident
-- didn't choose to cut this person off, the review cadence just lapsed.
alter type household_member_status add value if not exists 'pending_review';

-- ── Auto-compute the next review date ────────────────────────────────────
-- Fires whenever review_frequency is set/changed, or a card moves back to
-- 'active' (covers both first creation and a resident reactivating a
-- pending-review card). A DB-level guarantee so a future client code path
-- can't forget to advance the date, the same reasoning as
-- protect_profile_privileged_columns in 0005.
create or replace function private.set_household_next_review() returns trigger
  language plpgsql as $$
begin
  if new.review_frequency is not null and (
    tg_op = 'INSERT'
    or new.review_frequency is distinct from old.review_frequency
    or (new.status = 'active' and old.status is distinct from 'active')
  ) then
    new.next_review_at := now() + case new.review_frequency
      when 'monthly' then interval '1 month'
      when 'quarterly' then interval '3 months'
      when 'semiannual' then interval '6 months'
      when 'yearly' then interval '1 year'
    end;
  end if;
  return new;
end;
$$;

create trigger set_household_next_review
  before insert or update on household_members
  for each row execute function private.set_household_next_review();

-- ── Gate scan → notify the resident ──────────────────────────────────────
-- Security can't otherwise write to household_members (only
-- household_members_staff_select exists for them). This is the one
-- sanctioned write, scoped to touching last_scanned_at alone, which the
-- trigger below turns into a notification.
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

  update household_members set last_scanned_at = now() where id = member_id;
end;
$$;

alter table notifications drop constraint notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned'
));

create or replace function private.notify_household_member_scanned() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.last_scanned_at is distinct from old.last_scanned_at and new.status = 'active' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.resident_id,
      'household_member_scanned',
      new.full_name,
      new.full_name || ' was just granted access and is on their way.',
      jsonb_build_object('household_member_id', new.id)
    );
  end if;
  return new;
end;
$$;

create trigger notify_household_member_scanned
  after update on household_members
  for each row execute function private.notify_household_member_scanned();
