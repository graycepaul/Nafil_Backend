-- ══════════════════════════════════════════════════════════════════════════
-- Fix household-scan notification title
--
-- notify_household_member_scanned (0013) used the household member's own
-- name as the notification title, which read like the notification was
-- *about* that person in the abstract rather than a live gate event. "Gate
-- Access" as the title with the name in the body reads correctly in a push
-- banner and in the notifications list alike.
-- ══════════════════════════════════════════════════════════════════════════

create or replace function private.notify_household_member_scanned() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.last_scanned_at is distinct from old.last_scanned_at and new.status = 'active' then
    insert into notifications (profile_id, type, title, body, data)
    values (
      new.resident_id,
      'household_member_scanned',
      'Gate Access',
      new.full_name || ' was just granted access and is on their way.',
      jsonb_build_object('household_member_id', new.id)
    );
  end if;
  return new;
end;
$$;
