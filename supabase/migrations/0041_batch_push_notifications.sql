-- ══════════════════════════════════════════════════════════════════════════
-- Batch the notification → push fan-out, and rotate the internal secret
--
-- Two issues found in a pre-launch security/scale audit:
--
-- 1. 0028's push_notify_on_insert fires per ROW - a single estate-wide
--    announcement inserts one `notifications` row per resident
--    (private.notify_announcement), and each of those independently POSTs
--    to /push/notify-user. A 500-resident announcement was therefore 500
--    near-simultaneous HTTP round trips to the backend and ~500 separate
--    calls to Expo's push API, instead of the ~5 a properly batched request
--    would need (Expo takes up to 100 messages per call). This replaces the
--    per-row trigger with a per-STATEMENT trigger using a transition table
--    (`referencing new table as new_rows`), so the one bulk insert behind an
--    announcement stays one bulk push request to /push/notify-batch
--    (app/routers/push.py) - see that file for the batched delivery side.
--
-- 2. 0028's real internal secret was committed in plaintext in that
--    migration file (`vault.create_secret('955f...', ...)`), readable by
--    anyone with repo access. Rotating it here rather than just changing it
--    going forward - the old value must be treated as burned regardless of
--    whether it's ever been misused.
-- ══════════════════════════════════════════════════════════════════════════

-- ── Rotate the leaked secret ─────────────────────────────────────────────
-- Generated here, inside Postgres, with gen_random_bytes - not typed into
-- this file - so this migration doesn't recommit a new secret in plaintext
-- the same way 0028 did. `raise notice` prints it once, to this run's own
-- psql output only (not stored anywhere else): copy it from there into
-- INTERNAL_PUSH_SECRET in the backend's environment
-- (deploy/self-hosted/.env.backend on the VPS) and restart the api
-- container, or every push notification starts failing 401 until it is.
do $$
declare
  v_secret_id uuid;
  v_new_secret text := encode(gen_random_bytes(32), 'hex');
begin
  select id into v_secret_id from vault.secrets where name = 'internal_push_secret';
  if v_secret_id is not null then
    perform vault.update_secret(v_secret_id, v_new_secret);
  else
    perform vault.create_secret(
      v_new_secret,
      'internal_push_secret',
      'Shared secret for the notifications push trigger to authenticate to POST /push/notify-user and /push/notify-batch'
    );
  end if;
  raise notice 'NEW INTERNAL_PUSH_SECRET (copy into .env.backend now): %', v_new_secret;
end $$;

-- ── Statement-level batch trigger ────────────────────────────────────────
drop trigger if exists push_notify_on_insert on notifications;
drop function if exists private.push_notify_on_insert();

create or replace function private.push_notify_on_insert_batch() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  v_secret text;
  v_payload jsonb;
begin
  -- Emergency announcements are already pushed by /alerts/broadcast,
  -- called explicitly by the client in the same action that posts the
  -- announcement - pushing again here would double-notify every recipient.
  select jsonb_agg(jsonb_build_object(
           'profile_id', profile_id, 'title', title, 'body', body, 'data', data
         ))
    into v_payload
  from new_rows
  where type <> 'emergency';

  if v_payload is null then
    return null;
  end if;

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'internal_push_secret';

  perform net.http_post(
    url := 'https://api.nafilestates.com/push/notify-batch',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Internal-Secret', v_secret),
    body := jsonb_build_object('items', v_payload),
    -- Generous, not a cold-start workaround (0032/0034's stated reason -
    -- Render free tier - no longer applies now that this runs on the VPS
    -- directly): a batch of up to a few hundred items making several
    -- chunked Expo calls just needs enough headroom not to time out under
    -- ordinary load.
    timeout_milliseconds := 60000
  );

  return null;
end;
$$;

create trigger push_notify_on_insert_batch
  after insert on notifications
  referencing new table as new_rows
  for each statement execute function private.push_notify_on_insert_batch();
