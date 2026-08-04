-- Nafil Estates: core schema for multi-community estate management
-- Roles: resident, security, admin (estate-scoped), super_admin (client-wide)

create extension if not exists "pgcrypto";

create type user_role as enum ('resident', 'security', 'admin', 'super_admin');
create type visitor_pass_status as enum ('pending', 'used', 'expired', 'revoked');
create type visitor_log_method as enum ('qr', 'code', 'manual');
create type issue_status as enum ('open', 'in_progress', 'resolved');
create type announcement_severity as enum ('info', 'emergency');

-- ─────────────────────────────────────────────
-- Estates (communities managed by the one client)
-- ─────────────────────────────────────────────
create table estates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- Profiles (1:1 with auth.users)
-- ─────────────────────────────────────────────
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  estate_id uuid references estates(id) on delete set null,
  role user_role not null default 'resident',
  full_name text,
  phone text,
  unit_no text,
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

-- helper: role/estate of the calling user, used throughout RLS policies
create or replace function auth_role() returns user_role
  language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid();
$$;

create or replace function auth_estate_id() returns uuid
  language sql stable security definer set search_path = public as $$
  select estate_id from profiles where id = auth.uid();
$$;

-- ─────────────────────────────────────────────
-- Visitor passes (created by residents, ahead of a visit)
-- ─────────────────────────────────────────────
create table visitor_passes (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  resident_id uuid not null references profiles(id) on delete cascade,
  visitor_name text not null,
  visitor_phone text,
  vehicle_plate text,
  code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
  status visitor_pass_status not null default 'pending',
  valid_from timestamptz not null default now(),
  valid_until timestamptz not null default (now() + interval '24 hours'),
  created_at timestamptz not null default now()
);

create index visitor_passes_estate_idx on visitor_passes(estate_id);
create index visitor_passes_resident_idx on visitor_passes(resident_id);
create index visitor_passes_code_idx on visitor_passes(code);

-- ─────────────────────────────────────────────
-- Visitor logs (actual gate check-in/out events, written by security)
-- ─────────────────────────────────────────────
create table visitor_logs (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  pass_id uuid references visitor_passes(id) on delete set null,
  security_id uuid not null references profiles(id),
  visitor_name text not null,
  vehicle_plate text,
  method visitor_log_method not null default 'manual',
  checked_in_at timestamptz not null default now(),
  checked_out_at timestamptz,
  notes text
);

create index visitor_logs_estate_idx on visitor_logs(estate_id);
create index visitor_logs_pass_idx on visitor_logs(pass_id);

-- ─────────────────────────────────────────────
-- Issues (resident-reported, tracked by admin)
-- ─────────────────────────────────────────────
create table issues (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  resident_id uuid not null references profiles(id) on delete cascade,
  category text not null,
  description text not null,
  photo_urls text[] not null default '{}',
  status issue_status not null default 'open',
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index issues_estate_idx on issues(estate_id);
create index issues_resident_idx on issues(resident_id);

-- ─────────────────────────────────────────────
-- Announcements (posted by admin/security, read by everyone in the estate)
-- ─────────────────────────────────────────────
create table announcements (
  id uuid primary key default gen_random_uuid(),
  estate_id uuid not null references estates(id) on delete cascade,
  author_id uuid not null references profiles(id),
  title text not null,
  body text not null,
  severity announcement_severity not null default 'info',
  created_at timestamptz not null default now()
);

create index announcements_estate_idx on announcements(estate_id);

-- ─────────────────────────────────────────────
-- Row Level Security
-- ─────────────────────────────────────────────
alter table estates enable row level security;
alter table profiles enable row level security;
alter table visitor_passes enable row level security;
alter table visitor_logs enable row level security;
alter table issues enable row level security;
alter table announcements enable row level security;

-- estates: any authenticated user can see their own estate; super_admin sees all
create policy estates_select on estates for select
  using (auth_role() = 'super_admin' or id = auth_estate_id());

create policy estates_write_super_admin on estates for all
  using (auth_role() = 'super_admin')
  with check (auth_role() = 'super_admin');

-- profiles: self, or anyone in the same estate with admin/security role, or super_admin
create policy profiles_select on profiles for select
  using (
    id = auth.uid()
    or auth_role() = 'super_admin'
    or (estate_id = auth_estate_id() and auth_role() in ('admin', 'security'))
  );

create policy profiles_update_self on profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy profiles_admin_write on profiles for update
  using (auth_role() in ('admin', 'super_admin') and (auth_role() = 'super_admin' or estate_id = auth_estate_id()))
  with check (auth_role() in ('admin', 'super_admin') and (auth_role() = 'super_admin' or estate_id = auth_estate_id()));

create policy profiles_insert_self on profiles for insert
  with check (id = auth.uid());

-- visitor_passes: residents manage their own; security/admin can view all in their estate
create policy visitor_passes_resident_all on visitor_passes for all
  using (resident_id = auth.uid())
  with check (resident_id = auth.uid());

create policy visitor_passes_staff_select on visitor_passes for select
  using (auth_role() = 'super_admin' or (estate_id = auth_estate_id() and auth_role() in ('security', 'admin')));

create policy visitor_passes_staff_update on visitor_passes for update
  using (auth_role() = 'super_admin' or (estate_id = auth_estate_id() and auth_role() in ('security', 'admin')));

-- visitor_logs: security writes, security/admin/super_admin read within estate
create policy visitor_logs_select on visitor_logs for select
  using (auth_role() = 'super_admin' or (estate_id = auth_estate_id() and auth_role() in ('security', 'admin')));

create policy visitor_logs_insert on visitor_logs for insert
  with check (auth_role() = 'security' and estate_id = auth_estate_id() and security_id = auth.uid());

create policy visitor_logs_update on visitor_logs for update
  using (auth_role() = 'security' and estate_id = auth_estate_id());

-- issues: residents manage their own; admin/super_admin manage all within estate
create policy issues_resident_all on issues for all
  using (resident_id = auth.uid())
  with check (resident_id = auth.uid());

create policy issues_admin_select on issues for select
  using (auth_role() = 'super_admin' or (estate_id = auth_estate_id() and auth_role() = 'admin'));

create policy issues_admin_update on issues for update
  using (auth_role() = 'super_admin' or (estate_id = auth_estate_id() and auth_role() = 'admin'));

-- announcements: everyone in the estate reads; admin/security/super_admin write
create policy announcements_select on announcements for select
  using (auth_role() = 'super_admin' or estate_id = auth_estate_id());

create policy announcements_write on announcements for insert
  with check (
    author_id = auth.uid()
    and (auth_role() = 'super_admin' or (estate_id = auth_estate_id() and auth_role() in ('admin', 'security')))
  );

create policy announcements_delete on announcements for delete
  using (auth_role() = 'super_admin' or (estate_id = auth_estate_id() and auth_role() in ('admin', 'security')));
