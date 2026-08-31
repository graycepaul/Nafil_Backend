-- ══════════════════════════════════════════════════════════════════════════
-- Admin/super_admin never got notified of anything — new issues residents
-- reported, or emergency alerts posted by someone else (e.g. security) went
-- unnoticed unless they happened to open the relevant tab. This adds:
-- 1. A new issue_reported notification, fired to every admin (same estate)
--    and super_admin (any estate) when a resident files an issue.
-- 2. Broadens the existing emergency-announcement notification to also reach
--    admin/security (same estate) and super_admin (any estate), not just
--    residents — excluding whoever posted it, since they already know.
-- ══════════════════════════════════════════════════════════════════════════

alter table notifications drop constraint notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned',
  'issue_reported'
));

create or replace function private.notify_issue_reported() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  reporter_name text;
begin
  select coalesce(full_name, 'A resident') into reporter_name from profiles where id = new.resident_id;

  insert into notifications (profile_id, type, title, body, data)
  select p.id,
         'issue_reported',
         new.category,
         reporter_name || ' reported an issue: ' || new.description,
         jsonb_build_object('issue_id', new.id)
  from profiles p
  where p.approved = true
    and (
      (p.role = 'admin' and p.estate_id = new.estate_id)
      or p.role = 'super_admin'
    );
  return new;
end;
$$;

create trigger notify_issue_reported
  after insert on issues
  for each row execute function private.notify_issue_reported();

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

  -- Emergency alerts also need to reach the people who can act on them —
  -- the rest of the estate's staff, and every super_admin regardless of
  -- estate — not just the residents being warned. The author already knows
  -- (they just posted it), so they're excluded.
  if new.severity = 'emergency' then
    insert into notifications (profile_id, type, title, body, data)
    select p.id,
           'emergency',
           new.title,
           new.body,
           jsonb_build_object('announcement_id', new.id)
    from profiles p
    where p.approved = true
      and p.id is distinct from new.author_id
      and (
        (p.role in ('admin', 'security') and p.estate_id = new.estate_id)
        or p.role = 'super_admin'
      );
  end if;

  return new;
end;
$$;
