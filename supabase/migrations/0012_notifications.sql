-- ══════════════════════════════════════════════════════════════════════════
-- Per-user notifications inbox
--
-- Until now the resident Home tab's bell icon just deep-linked into the
-- shared announcements feed — there was no notion of a notification actually
-- belonging to a specific person, so nothing else in the app (an issue you
-- reported changing status, your visitor's pass being used at the gate, your
-- join request getting approved, an invite you sent being accepted) ever
-- reached it. This adds a real table for that and populates it via triggers
-- on the events themselves, rather than relying on every call site to
-- remember to insert a notification — the same reasoning as
-- protect_profile_privileged_columns in 0005: a DB-level guarantee survives
-- new client code paths that a client-side insert would not.
-- ══════════════════════════════════════════════════════════════════════════

create table notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  type text not null check (type in (
    'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
    'join_request_approved', 'staff_invite_accepted'
  )),
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_profile_feed_idx on notifications(profile_id, created_at desc);
create index notifications_unread_idx on notifications(profile_id) where read_at is null;

alter table notifications enable row level security;

-- Read-only from the client's side beyond marking your own read — inserts
-- only ever happen through the SECURITY DEFINER trigger functions below, so
-- there's deliberately no insert/delete policy for anyone.
create policy notifications_owner_select on notifications for select
  using (profile_id = (select auth.uid()));

create policy notifications_owner_update on notifications for update
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

-- ── Announcements & emergency alerts → every approved resident in estate ──
create or replace function private.notify_announcement() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (profile_id, type, title, body, data)
  select p.id,
         case when new.severity = 'emergency' then 'emergency' else 'announcement' end,
         new.title,
         new.body,
         jsonb_build_object('announcement_id', new.id)
  from profiles p
  where p.estate_id = new.estate_id and p.role = 'resident' and p.approved = true;
  return new;
end;
$$;

create trigger notify_announcement
  after insert on announcements
  for each row execute function private.notify_announcement();

-- ── Issue status changes → the resident who reported it ────────────────
create or replace function private.notify_issue_status() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.resident_id,
      'issue_status',
      new.category,
      case new.status
        when 'in_progress' then 'Your report was marked in progress.'
        when 'resolved' then 'Your report was marked resolved.'
        else 'Your report status changed to ' || replace(new.status::text, '_', ' ') || '.'
      end,
      jsonb_build_object('issue_id', new.id, 'status', new.status)
    );
  end if;
  return new;
end;
$$;

create trigger notify_issue_status
  after update on issues
  for each row execute function private.notify_issue_status();

-- ── Visitor pass used at the gate → the resident who issued it ─────────
create or replace function private.notify_visitor_pass_used() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'used' and old.status is distinct from 'used' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.resident_id,
      'visitor_pass_used',
      new.visitor_name,
      new.visitor_name || '''s pass was used at the gate.',
      jsonb_build_object('visitor_pass_id', new.id)
    );
  end if;
  return new;
end;
$$;

create trigger notify_visitor_pass_used
  after update on visitor_passes
  for each row execute function private.notify_visitor_pass_used();

-- ── Join request approved → the applicant ───────────────────────────────
create or replace function private.notify_join_request_approved() returns trigger
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
  end if;
  return new;
end;
$$;

create trigger notify_join_request_approved
  after update on estate_join_requests
  for each row execute function private.notify_join_request_approved();

-- ── Staff invite accepted → whoever sent it ─────────────────────────────
-- No admin-facing inbox screen exists yet to surface these — the resident
-- Home tab's bell is the only notification UI in the app today — but the
-- row lands correctly regardless, ready for whenever that screen exists.
create or replace function private.notify_staff_invite_accepted() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.invited_by,
      'staff_invite_accepted',
      'Invite accepted',
      coalesce(nullif(trim(coalesce(new.first_name, '') || ' ' || coalesce(new.last_name, '')), ''), new.email)
        || ' accepted your staff invite.',
      jsonb_build_object('staff_invite_id', new.id)
    );
  end if;
  return new;
end;
$$;

create trigger notify_staff_invite_accepted
  after update on staff_invites
  for each row execute function private.notify_staff_invite_accepted();
