-- Generic push notification delivery.
--
-- Until now, only emergency alerts resulted in an actual push to a
-- resident's phone — the client calls /alerts/broadcast explicitly, at the
-- same time it posts the announcement. Every OTHER notification type
-- (regular announcements, issue status changes, visitor pass scans, join
-- request approvals, staff invite acceptances) only ever inserted a row
-- into `notifications` for the bell icon to read later — nothing reached
-- the device unless the resident happened to open the app and look.
--
-- This closes that gap once, generically, at the one place every
-- notification type already goes through (an insert into `notifications`
-- itself) rather than teaching every call site to separately remember to
-- also request a push. pg_net's http_post is fire-and-forget (queues the
-- request and returns immediately, doesn't block the insert waiting on a
-- response), so this doesn't slow down whatever action triggered it.

create extension if not exists pg_net;

-- Shared secret the trigger below sends back to the backend (as
-- X-Internal-Secret) so /push/notify-user can tell "this is really our own
-- trigger" apart from an arbitrary request — there's no signed-in user here
-- for a normal Supabase JWT to authenticate. Set INTERNAL_PUSH_SECRET to
-- this exact value in the backend's environment (Render dashboard).
select vault.create_secret(
  '955f6279eca4af84c2dcd8e1d9cfb05ac0b77a1cba3890028083b81ac6896940',
  'internal_push_secret',
  'Shared secret for the notifications push trigger to authenticate to POST /push/notify-user'
);

create or replace function private.push_notify_on_insert() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  v_secret text;
begin
  -- Emergency announcements are already pushed by /alerts/broadcast, called
  -- explicitly by the client in the same action that posts the announcement
  -- — pushing again here would double-notify every recipient.
  if new.type = 'emergency' then
    return new;
  end if;

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'internal_push_secret';

  perform net.http_post(
    url := 'https://api.nafilestates.com/push/notify-user',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Internal-Secret', v_secret),
    body := jsonb_build_object('profile_id', new.profile_id, 'title', new.title, 'body', new.body, 'data', new.data)
  );

  return new;
end;
$$;

create trigger push_notify_on_insert
  after insert on notifications
  for each row execute function private.push_notify_on_insert();
