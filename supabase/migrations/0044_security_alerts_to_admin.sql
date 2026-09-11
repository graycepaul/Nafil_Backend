-- ══════════════════════════════════════════════════════════════════════════
-- Security reports to admin, not to every resident
--
-- Security's "Alert" screen used to insert straight into `announcements`
-- with severity='emergency' and push every resident's phone directly - the
-- only tool available for anything security noticed, however minor, was a
-- full estate-wide siren-priority broadcast. This replaces that with a
-- dedicated security_alerts table that reaches admin/super_admin only (same
-- reach as notify_issue_reported): admin reviews it and decides whether it
-- actually warrants a public announcement, rather than security deciding
-- that unilaterally for the whole estate every time.
--
-- Genuine estate-wide emergency broadcasting isn't removed - admin/
-- super_admin still post those exactly as before, via the existing
-- announcements composer's "Emergency alert" toggle. This only changes who
-- can post an announcement/emergency directly: security no longer can.
-- ══════════════════════════════════════════════════════════════════════════

create table security_alerts (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  author_id uuid not null references profiles(id),
  category text not null default 'other'
    check (category in ('missing_child', 'security_breach', 'epidemic', 'other')),
  title text not null,
  body text not null,
  status text not null default 'open' check (status in ('open', 'addressed')),
  created_at timestamptz not null default now()
);

create index security_alerts_estate_idx on security_alerts(estate_id);

alter table security_alerts enable row level security;

-- Same estate-scoped shape as issues_insert/announcements_insert - a
-- security officer can only file against their own estate, as themselves.
create policy security_alerts_insert on security_alerts for insert
  with check (
    author_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = 'security'
  );

-- A security officer sees their own reports (so they know what they've
-- already flagged); admin/super_admin see every report for their estate -
-- same visibility split as issues_select.
create policy security_alerts_select on security_alerts for select
  using (
    author_id = (select auth.uid())
    or (
      estate_id = (select private.auth_estate_id())
      and (select private.auth_role()) = any (array['admin'::user_role, 'super_admin'::user_role])
    )
  );

-- Only admin/super_admin mark one addressed - matches issues_update's own
-- admin-only status-change gating.
create policy security_alerts_update on security_alerts for update
  using (
    estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['admin'::user_role, 'super_admin'::user_role])
  );

-- ── security no longer posts announcements directly ─────────────────────
drop policy announcements_insert on announcements;
create policy announcements_insert on announcements for insert
  with check (
    author_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role])
  );

-- ── New security alert → the estate's admins + every super_admin ───────
-- Same reach/shape as notify_issue_reported (0017) - the alert itself
-- reaches admin/super_admin only; residents never see it unless admin
-- separately chooses to post an announcement about it.
alter table notifications drop constraint notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned', 'issue_reported',
  'order_placed', 'order_completed', 'transfer_confirmed', 'transfer_rejected',
  'listing_suspended', 'listing_reinstated', 'transfer_contested', 'issue_feedback',
  'due_assigned', 'join_request_submitted', 'join_request_rejected', 'security_alert_reported'
));

create or replace function private.notify_security_alert_reported() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  reporter_name text;
begin
  select coalesce(full_name, 'Security') into reporter_name from profiles where id = new.author_id;

  insert into notifications (profile_id, type, title, body, data)
  select p.id,
         'security_alert_reported',
         new.title,
         reporter_name || ' reported: ' || new.body,
         jsonb_build_object('security_alert_id', new.id)
  from profiles p
  where p.approved = true
    and (
      (p.role = 'admin' and p.estate_id = new.estate_id)
      or p.role = 'super_admin'
    );
  return new;
end;
$$;

create trigger notify_security_alert_reported
  after insert on security_alerts
  for each row execute function private.notify_security_alert_reported();
