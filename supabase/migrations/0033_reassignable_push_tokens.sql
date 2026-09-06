-- A push token identifies a device, not a person - when a different
-- resident signs in on a device that already has a token row from
-- whoever used it last (shared device, reused test simulator, a phone
-- passed to a new resident), push_tokens_owner_all's `using` clause
-- correctly refuses to let the new user's upsert touch the old owner's
-- row, since the row doesn't belong to them. That's RLS working as
-- designed, but it means the token can never be reassigned via a plain
-- client-side upsert.
--
-- This function is the sanctioned way to reassign it: it runs as the
-- table owner (bypassing that RLS check internally) but only after
-- confirming the caller is a genuinely authenticated user via auth.uid()
-- - never client-supplied - so it can't be used to steal someone else's
-- token, only to say "this token is mine now."

create or replace function public.register_push_token(p_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from push_tokens where token = p_token and profile_id <> auth.uid();

  insert into push_tokens (profile_id, token, platform)
  values (auth.uid(), p_token, p_platform)
  on conflict (token) do update set platform = excluded.platform;
end;
$$;

grant execute on function public.register_push_token(text, text) to authenticated;
