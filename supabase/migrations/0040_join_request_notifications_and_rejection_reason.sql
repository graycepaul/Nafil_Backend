-- ══════════════════════════════════════════════════════════════════════════
-- Join request notifications + required rejection reason
--
-- Two gaps found in a pre-launch audit: admins only found out about a new
-- pending join request by opening Residents → Pending themselves - nothing
-- pushed it to them, so a resident could sit in the queue for days
-- unnoticed. And rejecting gave the resident no explanation beyond "wasn't
-- approved" (see 0012's notify_join_request_approved, which never had a
-- rejected counterpart at all). This closes both: notify the estate's
-- admins + every super_admin the instant a request comes in, and require a
-- reason on rejection that the resident then sees.
-- ══════════════════════════════════════════════════════════════════════════

alter table estate_join_requests add column rejection_reason text;

alter table notifications drop constraint notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned', 'issue_reported',
  'order_placed', 'order_completed', 'transfer_confirmed', 'transfer_rejected',
  'listing_suspended', 'listing_reinstated', 'transfer_contested', 'issue_feedback',
  'due_assigned', 'join_request_submitted', 'join_request_rejected'
));

-- ── New join request → the estate's admins + every super_admin ─────────
-- Same reach as 0017's notify_issue_reported: admins scoped to their own
-- estate, super_admin unconditionally (it's an estate-owner role since
-- 0026, but a request for estate X should still be able to reach the
-- super_admin who happens to be signed into estate Y today - there's no
-- narrower "which estate is this super_admin watching right now" signal to
-- scope by).
create or replace function private.notify_join_request_submitted() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  applicant_name text;
begin
  select coalesce(full_name, 'A resident') into applicant_name from profiles where id = new.profile_id;

  insert into notifications (profile_id, type, title, body, data)
  select p.id,
         'join_request_submitted',
         'New join request',
         applicant_name || ' wants to join - unit ' || new.unit_no || '.',
         jsonb_build_object('join_request_id', new.id)
  from profiles p
  where p.approved = true
    and (
      (p.role = 'admin' and p.estate_id = new.estate_id)
      or p.role = 'super_admin'
    );
  return new;
end;
$$;

create trigger notify_join_request_submitted
  after insert on estate_join_requests
  for each row execute function private.notify_join_request_submitted();

-- ── Reviewed (approved or rejected) → the applicant ─────────────────────
-- Replaces 0012's approval-only notify_join_request_approved with a version
-- that also fires on rejection, reason included, so the resident actually
-- learns why instead of just seeing the door close.
drop trigger if exists notify_join_request_approved on estate_join_requests;
drop function if exists private.notify_join_request_approved();

create or replace function private.notify_join_request_reviewed() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.profile_id,
      'join_request_approved',
      'Request approved',
      'Your request to join the estate was approved.',
      jsonb_build_object('join_request_id', new.id)
    );
  elsif new.status = 'rejected' and old.status is distinct from 'rejected' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.profile_id,
      'join_request_rejected',
      'Request not approved',
      coalesce(nullif(trim(new.rejection_reason), ''), 'Your request to join the estate was not approved.'),
      jsonb_build_object('join_request_id', new.id, 'reason', new.rejection_reason)
    );
  end if;
  return new;
end;
$$;

create trigger notify_join_request_reviewed
  after update on estate_join_requests
  for each row execute function private.notify_join_request_reviewed();

-- ── reject_join_request now requires a reason ───────────────────────────
-- Signature changes (uuid) → (uuid, text), so the old overload is dropped
-- rather than left dangling as dead, callable-but-wrong API surface.
drop function if exists public.reject_join_request(uuid);

create or replace function public.reject_join_request(request_id uuid, reason text) returns void
  language plpgsql security definer set search_path = public as $$
declare
  req estate_join_requests%rowtype;
begin
  if private.auth_role() not in ('admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  if reason is null or trim(reason) = '' then
    raise exception 'A rejection reason is required';
  end if;

  select * into req from estate_join_requests where id = request_id and status = 'pending';
  if not found then
    raise exception 'Request not found or already reviewed';
  end if;

  if req.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  update estate_join_requests
     set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(), rejection_reason = trim(reason)
   where id = request_id;
end;
$$;
