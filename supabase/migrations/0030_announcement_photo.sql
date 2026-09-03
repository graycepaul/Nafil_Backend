-- Announcements had no image field at all — unlike issues.photo_urls, this
-- isn't "existed but unused", it genuinely didn't exist. Adding a single
-- optional photo (not an array, unlike issues): an announcement is one
-- notice with at most one illustrative image (a poster, a photo of the
-- thing being described), not a multi-angle report.

alter table announcements add column photo_url text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('announcement-photos', 'announcement-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy announcement_photos_select_public on storage.objects for select
  using (bucket_id = 'announcement-photos');

-- Same author/estate-scoped roles as `announcements_insert` (0001_init.sql):
-- super_admin, admin, or security, each restricted to their own estate.
-- Path convention `{estate_id}/...` rather than `{uploader_id}/...` since
-- more than one staff member's role can post announcements for the same
-- estate and none of them need a private folder here — the bucket is
-- already public read, so there's no privacy boundary to enforce beyond
-- "you can only write into your own estate's folder".
create policy announcement_photos_insert_own_estate on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'announcement-photos'
    and (storage.foldername(name))[1] = (select private.auth_estate_id())::text
    and (select private.auth_role()) = any (array['super_admin'::user_role, 'admin'::user_role, 'security'::user_role])
  );
