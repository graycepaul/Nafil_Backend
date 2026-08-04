-- Performance pass, done while the database is still empty.
--
-- 1. Wrap auth.uid() / helper calls in (select ...) so Postgres evaluates them once
--    per query (InitPlan) rather than once per row. Without this, a 10k-row scan calls
--    auth.uid() 10k times.
-- 2. Consolidate overlapping permissive policies. A FOR ALL policy plus a separate
--    SELECT policy means both get evaluated on every read; one policy per action is
--    both faster and easier to reason about.
-- 3. Index the foreign keys that RLS filters on — profiles.estate_id especially, since
--    almost every policy compares against it.

create index if not exists profiles_estate_idx on profiles(estate_id);
create index if not exists visitor_logs_security_idx on visitor_logs(security_id);
create index if not exists announcements_author_idx on announcements(author_id);

-- ── estates ─────────────────────────────────────────────
drop policy if exists estates_select on estates;
drop policy if exists estates_write_super_admin on estates;

create policy estates_select on estates for select
  using ((select private.auth_role()) = 'super_admin' or id = (select private.auth_estate_id()));

create policy estates_insert on estates for insert
  with check ((select private.auth_role()) = 'super_admin');

create policy estates_update on estates for update
  using ((select private.auth_role()) = 'super_admin')
  with check ((select private.auth_role()) = 'super_admin');

create policy estates_delete on estates for delete
  using ((select private.auth_role()) = 'super_admin');

-- ── profiles ────────────────────────────────────────────
drop policy if exists profiles_select on profiles;
drop policy if exists profiles_insert_self on profiles;
drop policy if exists profiles_update_self on profiles;
drop policy if exists profiles_admin_write on profiles;

create policy profiles_select on profiles for select
  using (
    id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('admin', 'security'))
  );

create policy profiles_insert on profiles for insert
  with check (id = (select auth.uid()));

create policy profiles_update on profiles for update
  using (
    id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  )
  with check (
    id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

-- ── visitor_passes ──────────────────────────────────────
drop policy if exists visitor_passes_resident_all on visitor_passes;
drop policy if exists visitor_passes_staff_select on visitor_passes;
drop policy if exists visitor_passes_staff_update on visitor_passes;

create policy visitor_passes_select on visitor_passes for select
  using (
    resident_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('security', 'admin'))
  );

create policy visitor_passes_insert on visitor_passes for insert
  with check (resident_id = (select auth.uid()));

create policy visitor_passes_update on visitor_passes for update
  using (
    resident_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('security', 'admin'))
  );

create policy visitor_passes_delete on visitor_passes for delete
  using (resident_id = (select auth.uid()));

-- ── visitor_logs ────────────────────────────────────────
drop policy if exists visitor_logs_select on visitor_logs;
drop policy if exists visitor_logs_insert on visitor_logs;
drop policy if exists visitor_logs_update on visitor_logs;

create policy visitor_logs_select on visitor_logs for select
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('security', 'admin'))
  );

create policy visitor_logs_insert on visitor_logs for insert
  with check (
    (select private.auth_role()) = 'security'
    and estate_id = (select private.auth_estate_id())
    and security_id = (select auth.uid())
  );

create policy visitor_logs_update on visitor_logs for update
  using ((select private.auth_role()) = 'security' and estate_id = (select private.auth_estate_id()));

-- ── issues ──────────────────────────────────────────────
drop policy if exists issues_resident_all on issues;
drop policy if exists issues_admin_select on issues;
drop policy if exists issues_admin_update on issues;

create policy issues_select on issues for select
  using (
    resident_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create policy issues_insert on issues for insert
  with check (resident_id = (select auth.uid()));

create policy issues_update on issues for update
  using (
    resident_id = (select auth.uid())
    or (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) = 'admin')
  );

create policy issues_delete on issues for delete
  using (resident_id = (select auth.uid()));

-- ── announcements ───────────────────────────────────────
drop policy if exists announcements_select on announcements;
drop policy if exists announcements_write on announcements;
drop policy if exists announcements_delete on announcements;

create policy announcements_select on announcements for select
  using ((select private.auth_role()) = 'super_admin' or estate_id = (select private.auth_estate_id()));

create policy announcements_insert on announcements for insert
  with check (
    author_id = (select auth.uid())
    and (
      (select private.auth_role()) = 'super_admin'
      or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('admin', 'security'))
    )
  );

create policy announcements_delete on announcements for delete
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('admin', 'security'))
  );
