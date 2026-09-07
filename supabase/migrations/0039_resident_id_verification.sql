-- Identity verification for join requests. A name and unit number alone
-- were never enough to actually verify someone belongs there - the estate
-- has both civilian and military-personnel residents, and this replaces
-- "take their word for it" with an actual document the admin reviews
-- before approving: a civilian's utility bill or NIN card, or a
-- personnel resident's service ID card plus service number.
--
-- The document is genuinely sensitive PII (government ID, service
-- credentials), unlike every other photo bucket in this app so far
-- (avatars, listing/issue/announcement photos), which are all public. This
-- one is private: only the resident who uploaded it and admin/super_admin
-- reviewing their specific request can read it, and only ever through a
-- short-lived signed URL, never a public one.

create type resident_category as enum ('civilian', 'personnel');

alter table estate_join_requests
  add column resident_category resident_category,
  add column id_document_path text,
  add column service_number text;

-- Nullable rather than not-null: existing rows predate this feature and
-- have neither. New submissions are validated client-side (the same trust
-- level as most other "required" fields in this app, e.g. issues.category),
-- not enforced by a check constraint here.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('resident-id-documents', 'resident-id-documents', false, 10485760, array['image/jpeg', 'image/png', 'image/webp']);

create policy id_documents_insert_own on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'resident-id-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy id_documents_select_own on storage.objects for select
  to authenticated
  using (
    bucket_id = 'resident-id-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- The reviewing admin/super_admin, scoped to requests actually in their
-- estate - matched by looking up which join request the uploader's folder
-- belongs to, since the object path itself only encodes the uploader's own
-- id, not their estate (unknown/unstable pre-approval).
create policy id_documents_select_reviewer on storage.objects for select
  to authenticated
  using (
    bucket_id = 'resident-id-documents'
    and exists (
      select 1 from estate_join_requests r
      where r.profile_id::text = (storage.foldername(name))[1]
        and (
          (select private.auth_role()) = 'super_admin'
          or (
            (select private.auth_role()) = 'admin'
            and r.estate_id = (select private.auth_estate_id())
          )
        )
    )
  );
