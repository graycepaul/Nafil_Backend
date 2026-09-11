-- ══════════════════════════════════════════════════════════════════════════
-- Issue status changes: visible activity log, DB-guaranteed
--
-- Multiple admins/super_admin can all act on the same issue in the same
-- estate, but there was no way to tell one action from another after the
-- fact - just the issue's current status, with no record of who moved it
-- there or when. Same problem GitHub's own issue timeline solves. Logged
-- via a trigger on `issues` itself (not a client-side insert) so it can
-- never be missed or spoofed regardless of which screen/client made the
-- change - same reasoning as the notifications table's own triggers.
-- ══════════════════════════════════════════════════════════════════════════

create table issue_activity (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references issues(id) on delete cascade,
  actor_id uuid not null references profiles(id),
  from_status issue_status not null,
  to_status issue_status not null,
  created_at timestamptz not null default now()
);

create index issue_activity_issue_idx on issue_activity(issue_id);

alter table issue_activity enable row level security;

-- Same visibility as the issue itself - the reporting resident, or
-- admin/super_admin scoped to the estate.
create policy issue_activity_select on issue_activity for select
  using (
    exists (
      select 1 from issues i
      where i.id = issue_activity.issue_id
        and (
          i.resident_id = (select auth.uid())
          or (
            i.estate_id = (select private.auth_estate_id())
            and (select private.auth_role()) = any (array['admin'::user_role, 'super_admin'::user_role])
          )
        )
    )
  );

-- No insert/update/delete policy for anyone - only this trigger
-- (SECURITY DEFINER) ever writes here, so the log can't be edited or
-- backfilled with a false actor after the fact.
create or replace function private.log_issue_status_change() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    insert into issue_activity (issue_id, actor_id, from_status, to_status)
    values (new.id, auth.uid(), old.status, new.status);
  end if;
  return new;
end;
$$;

create trigger log_issue_status_change
  after update on issues
  for each row execute function private.log_issue_status_change();
