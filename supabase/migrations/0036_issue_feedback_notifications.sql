-- The issue feedback thread (0031_issue_feedback.sql) never actually
-- notified anyone when a message was posted - neither the resident nor the
-- admin/staff side got so much as an in-app notification, let alone a push,
-- when the other party replied. Found during a pre-launch admin/super_admin
-- UI pass: posting feedback as admin produced no notification for the
-- resident at all. Same trigger-on-insert pattern as every other
-- notification type (see 0012/0017), so it also gets a push for free via
-- 0028's generic push-on-insert trigger.

alter table notifications drop constraint notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned', 'issue_reported',
  'order_placed', 'order_completed', 'transfer_confirmed', 'transfer_rejected',
  'listing_suspended', 'listing_reinstated', 'transfer_contested', 'issue_feedback'
));

create or replace function private.notify_issue_feedback() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  v_issue issues%rowtype;
  v_author_name text;
begin
  select * into v_issue from issues where id = new.issue_id;
  select coalesce(full_name, 'Someone') into v_author_name from profiles where id = new.author_id;

  if new.author_id = v_issue.resident_id then
    -- Resident replied → notify the estate's admins and every super_admin,
    -- same audience as notify_issue_reported.
    insert into notifications (profile_id, type, title, body, data)
    select p.id, 'issue_feedback', v_issue.category,
           v_author_name || ' replied: ' || new.body,
           jsonb_build_object('issue_id', v_issue.id)
    from profiles p
    where p.approved = true
      and (
        (p.role = 'admin' and p.estate_id = v_issue.estate_id)
        or p.role = 'super_admin'
      );
  else
    -- Admin/staff replied → notify the resident who reported it.
    insert into notifications (profile_id, type, title, body, data)
    values (
      v_issue.resident_id,
      'issue_feedback',
      v_issue.category,
      v_author_name || ' replied: ' || new.body,
      jsonb_build_object('issue_id', v_issue.id)
    );
  end if;
  return new;
end;
$$;

create trigger notify_issue_feedback
  after insert on issue_comments
  for each row execute function private.notify_issue_feedback();
