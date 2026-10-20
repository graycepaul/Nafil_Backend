-- Accounts and estates flagged as test data from the devControl dashboard.
-- Additive to the built-in rules in app/routers/devcontrol.py (email patterns,
-- the Demo Gardens estate): a row here moves one user or estate into the
-- "test" view. Only the backend (service connection) touches this table:
-- RLS is on with no policies, and the app roles get no grants at all.
create table if not exists devcontrol_test_flags (
  kind text not null check (kind in ('user', 'estate')),
  ref_id uuid not null,
  flagged_by uuid,
  created_at timestamptz not null default now(),
  primary key (kind, ref_id)
);

alter table devcontrol_test_flags enable row level security;
revoke all on devcontrol_test_flags from anon, authenticated;
