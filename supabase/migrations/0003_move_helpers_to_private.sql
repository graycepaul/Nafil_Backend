-- The RLS helper functions must be SECURITY DEFINER (they read `profiles`, which is
-- itself RLS-protected — without DEFINER the profiles policies would recurse infinitely).
-- But SECURITY DEFINER functions sitting in `public` are exposed as REST RPC endpoints,
-- which Supabase's security advisor flags. Moving them to a `private` schema keeps them
-- usable from RLS policies while removing them from the exposed API surface.

create schema if not exists private;

create or replace function private.auth_role() returns user_role
  language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid();
$$;

create or replace function private.auth_estate_id() returns uuid
  language sql stable security definer set search_path = public as $$
  select estate_id from profiles where id = auth.uid();
$$;

create or replace function private.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name', new.phone);
  return new;
end;
$$;

-- Policy evaluation runs as the querying role, so it needs to resolve the schema.
grant usage on schema private to anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

drop policy if exists estates_select on estates;
drop policy if exists estates_write_super_admin on estates;
drop policy if exists profiles_select on profiles;
drop policy if exists profiles_admin_write on profiles;
drop policy if exists visitor_passes_staff_select on visitor_passes;
drop policy if exists visitor_passes_staff_update on visitor_passes;
drop policy if exists visitor_logs_select on visitor_logs;
drop policy if exists visitor_logs_insert on visitor_logs;
drop policy if exists visitor_logs_update on visitor_logs;
drop policy if exists issues_admin_select on issues;
drop policy if exists issues_admin_update on issues;
drop policy if exists announcements_select on announcements;
drop policy if exists announcements_write on announcements;
drop policy if exists announcements_delete on announcements;

drop function if exists public.auth_role();
drop function if exists public.auth_estate_id();
drop function if exists public.handle_new_user();

create policy estates_select on estates for select
  using (private.auth_role() = 'super_admin' or id = private.auth_estate_id());

create policy estates_write_super_admin on estates for all
  using (private.auth_role() = 'super_admin')
  with check (private.auth_role() = 'super_admin');

create policy profiles_select on profiles for select
  using (
    id = auth.uid()
    or private.auth_role() = 'super_admin'
    or (estate_id = private.auth_estate_id() and private.auth_role() in ('admin', 'security'))
  );

create policy profiles_admin_write on profiles for update
  using (private.auth_role() in ('admin', 'super_admin') and (private.auth_role() = 'super_admin' or estate_id = private.auth_estate_id()))
  with check (private.auth_role() in ('admin', 'super_admin') and (private.auth_role() = 'super_admin' or estate_id = private.auth_estate_id()));

create policy visitor_passes_staff_select on visitor_passes for select
  using (private.auth_role() = 'super_admin' or (estate_id = private.auth_estate_id() and private.auth_role() in ('security', 'admin')));

create policy visitor_passes_staff_update on visitor_passes for update
  using (private.auth_role() = 'super_admin' or (estate_id = private.auth_estate_id() and private.auth_role() in ('security', 'admin')));

create policy visitor_logs_select on visitor_logs for select
  using (private.auth_role() = 'super_admin' or (estate_id = private.auth_estate_id() and private.auth_role() in ('security', 'admin')));

create policy visitor_logs_insert on visitor_logs for insert
  with check (private.auth_role() = 'security' and estate_id = private.auth_estate_id() and security_id = auth.uid());

create policy visitor_logs_update on visitor_logs for update
  using (private.auth_role() = 'security' and estate_id = private.auth_estate_id());

create policy issues_admin_select on issues for select
  using (private.auth_role() = 'super_admin' or (estate_id = private.auth_estate_id() and private.auth_role() = 'admin'));

create policy issues_admin_update on issues for update
  using (private.auth_role() = 'super_admin' or (estate_id = private.auth_estate_id() and private.auth_role() = 'admin'));

create policy announcements_select on announcements for select
  using (private.auth_role() = 'super_admin' or estate_id = private.auth_estate_id());

create policy announcements_write on announcements for insert
  with check (
    author_id = auth.uid()
    and (private.auth_role() = 'super_admin' or (estate_id = private.auth_estate_id() and private.auth_role() in ('admin', 'security')))
  );

create policy announcements_delete on announcements for delete
  using (private.auth_role() = 'super_admin' or (estate_id = private.auth_estate_id() and private.auth_role() in ('admin', 'security')));
