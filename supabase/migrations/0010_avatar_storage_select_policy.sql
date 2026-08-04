-- ══════════════════════════════════════════════════════════════════════════
-- Fixes every avatar upload failing with "new row violates row-level
-- security policy", even though the underlying INSERT was allowed.
--
-- 0005 assumed a public bucket needs no SELECT policy, since reads work
-- unauthenticated via the dedicated /object/public/... download URL. True for
-- reads — but Storage's own upload endpoint does an INSERT ... RETURNING * to
-- hand the object's metadata back to the client, and that RETURNING is
-- itself subject to RLS. With no SELECT policy on storage.objects at all,
-- that lookup returns nothing, and Storage reports the whole upload as an
-- RLS violation — regardless of path, regardless of user. (See Supabase's
-- own troubleshooting doc: "Storage error: 403 Forbidden: 'new row violates
-- row-level security policy' on upload".)
-- ══════════════════════════════════════════════════════════════════════════

create policy avatar_select_public on storage.objects for select
  using (bucket_id = 'avatars');
