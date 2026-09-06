-- Confirmed live: with a warm backend, a real push request completes in
-- well under a second. But a genuine Render free-tier cold start can take
-- "50 seconds or more" (Render's own dashboard wording), which is longer
-- than 0032's 30s allowance — net._http_response showed exactly that: three
-- real trigger firings all timing out at the full 30000ms. This was applied
-- directly to production ahead of this file; recorded here so the self-
-- hosted VPS (and any future fresh database) gets the same value.
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
    timeout_milliseconds := 60000
  );

  return new;
end;
$$;
