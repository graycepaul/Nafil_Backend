-- Assigning a due (0019_wallet_and_dues.sql) never notified the resident it
-- was charged to — no in-app notification, no push. They'd only find out by
-- opening the Wallet screen themselves. Found during the same pre-launch
-- notification audit that caught the missing issue-feedback notifications
-- (0036) — same trigger-on-insert pattern, so it also gets a push for free
-- via 0028's generic push-on-insert trigger.

alter table notifications drop constraint notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned', 'issue_reported',
  'order_placed', 'order_completed', 'transfer_confirmed', 'transfer_rejected',
  'listing_suspended', 'listing_reinstated', 'transfer_contested', 'issue_feedback',
  'due_assigned'
));

create or replace function private.notify_due_assigned() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (profile_id, type, title, body, data)
  values (
    new.profile_id,
    'due_assigned',
    new.label,
    'A new charge of ₦' || to_char(new.amount, 'FM999,999,999') || ' was added to your account: ' || new.label || '.',
    jsonb_build_object('due_id', new.id)
  );
  return new;
end;
$$;

create trigger notify_due_assigned
  after insert on dues
  for each row execute function private.notify_due_assigned();
