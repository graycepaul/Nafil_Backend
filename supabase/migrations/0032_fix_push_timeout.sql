-- 0028 shipped the push-notification trigger with pg_net's default 5s
-- timeout. net._http_response shows a real trigger firing that timed out
-- at exactly 5000ms while Render's (free-tier, cold-starting) backend was
-- still mid-response — this is very likely why push notifications have
-- been silently not arriving. Re-creating the function only (not
-- re-running 0028's vault.create_secret, which would duplicate the secret).

create or replace function private.push_notify_on_insert() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  v_secret text;
begin
  if new.type = 'emergency' then
    return new;
  end if;

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'internal_push_secret';

  perform net.http_post(
    url := 'https://api.nafilestates.com/push/notify-user',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Internal-Secret', v_secret),
    body := jsonb_build_object('profile_id', new.profile_id, 'title', new.title, 'body', new.body, 'data', new.data),
    -- 30s covers a Render cold start. This is a stopgap, not a fix for the
    -- cold start itself — see the infrastructure plan's guardrail #0
    -- (upgrade Render off the free tier) and the self-hosted VPS migration.
    timeout_milliseconds := 30000
  );

  return new;
end;
$$;
