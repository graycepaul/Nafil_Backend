-- `issues.photo_urls` has existed since 0001_init.sql, but nothing ever gave
-- residents a way to actually attach photos when reporting an issue — no
-- storage bucket existed for them. Same shape as listing-photos/avatars:
-- public bucket, path scoped to the uploader's own folder.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('issue-photos', 'issue-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy issue_photos_select_public on storage.objects for select
  using (bucket_id = 'issue-photos');

create policy issue_photos_insert_own on storage.objects for insert
  to authenticated
  with check (bucket_id = 'issue-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
