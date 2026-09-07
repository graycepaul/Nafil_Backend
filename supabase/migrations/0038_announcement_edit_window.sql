-- Lets whoever posted an announcement fix a mistake (typo, wrong photo)
-- shortly after posting, without giving them free rein to rewrite it
-- indefinitely or reassign it to someone else's authorship. There was no
-- update policy on this table at all before this - RLS defaults to deny,
-- so editing was flatly impossible.
--
-- Enforced at the DB layer, not just hidden in the client after 15 minutes:
-- the same reasoning as protect_profile_privileged_columns (0005) - a
-- guarantee here survives whatever the client does or doesn't check.

create or replace function private.protect_announcement_immutable_columns() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  new.author_id := old.author_id;
  new.estate_id := old.estate_id;
  new.severity := old.severity;
  new.created_at := old.created_at;
  return new;
end;
$$;

create trigger protect_announcement_immutable_columns
  before update on announcements
  for each row execute function private.protect_announcement_immutable_columns();

create policy announcements_update on announcements for update
  using (
    author_id = (select auth.uid())
    and created_at > now() - interval '15 minutes'
  )
  with check (
    author_id = (select auth.uid())
    and estate_id = (select private.auth_estate_id())
  );
