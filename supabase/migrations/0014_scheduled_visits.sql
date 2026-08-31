-- ══════════════════════════════════════════════════════════════════════════
-- Scheduled visits: "I'm expecting someone at 6pm, no code needed"
--
-- Different trust model from a visitor pass: instead of a code the resident
-- shares with the visitor ahead of time, the resident just tells the app
-- who to expect and when. At the gate, security looks the visitor up by the
-- name they give (which must match), not a code the visitor carries. Lookup
-- and check-in go through a SECURITY DEFINER RPC rather than a broad UPDATE
-- policy for staff, same reasoning as record_household_member_scan in 0013.
-- Security can resolve a name to "let this person in" without also being
-- able to edit a resident's schedule.
-- ══════════════════════════════════════════════════════════════════════════

create table scheduled_visits (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  resident_id uuid not null references profiles(id) on delete cascade,
  visitor_name text not null,
  description text,
  scheduled_for timestamptz not null,
  status text not null default 'pending' check (status in ('pending', 'arrived', 'expired', 'cancelled')),
  created_at timestamptz not null default now()
);

create index scheduled_visits_estate_idx on scheduled_visits(estate_id);
create index scheduled_visits_resident_idx on scheduled_visits(resident_id);
-- Case-insensitive name lookup is the whole point of this feature.
create index scheduled_visits_name_idx on scheduled_visits(estate_id, lower(visitor_name));

alter table scheduled_visits enable row level security;

-- Residents manage their own end-to-end (create, view, cancel), mirrors
-- visitor_passes_resident_all / household_members_resident_all.
create policy scheduled_visits_resident_all on scheduled_visits for all
  using (resident_id = (select auth.uid()))
  with check (resident_id = (select auth.uid()));

-- Security/admin need read access to search by name at the gate, mirrors
-- household_members_staff_select.
create policy scheduled_visits_staff_select on scheduled_visits for select
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('security', 'admin'))
  );

create or replace function public.check_in_scheduled_visit(visit_id uuid) returns void
  language plpgsql security definer set search_path = public as $$
declare
  visit scheduled_visits%rowtype;
  officer_id uuid;
begin
  officer_id := auth.uid();
  if private.auth_role() not in ('security', 'admin', 'super_admin') then
    raise exception 'Not authorized';
  end if;

  select * into visit from scheduled_visits where id = visit_id;
  if not found then
    raise exception 'Scheduled visit not found';
  end if;

  if private.auth_role() <> 'super_admin' and visit.estate_id <> private.auth_estate_id() then
    raise exception 'Not authorized for this estate';
  end if;

  if visit.status <> 'pending' then
    raise exception 'This visit is already "%"', visit.status;
  end if;

  update scheduled_visits set status = 'arrived' where id = visit_id;

  insert into visitor_logs (estate_id, security_id, visitor_name, method, checked_in_at)
  values (visit.estate_id, officer_id, visit.visitor_name, 'manual', now());
end;
$$;
