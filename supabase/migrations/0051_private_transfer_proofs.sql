-- transfer-proofs was created public (0027), unlike every other genuinely
-- sensitive bucket (resident-id-documents is private + signed URLs). A bank
-- transfer proof is a photo of someone's transfer receipt/bank app screen -
-- account numbers, names, references - and the object path
-- (`${userId}/${timestamp}.ext`) is guessable/enumerable, so anyone with a
-- URL, signed in or not, could view another resident's payment proof.
--
-- Fix: make the bucket private and replace the public-read policy with the
-- same "uploader, or the estate's finance/super_admin reviewing it" pattern
-- already used for resident-id-documents.

update storage.buckets set public = false where id = 'transfer-proofs';

drop policy transfer_proofs_select_public on storage.objects;

create policy transfer_proofs_select_own on storage.objects for select
  to authenticated
  using (
    bucket_id = 'transfer-proofs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Finance/super_admin reviewing transfers for their own estate. Matched via
-- the transfers table (any transfer submitted by this uploader in their
-- estate), same join shape as id_documents_select_reviewer.
create policy transfer_proofs_select_reviewer on storage.objects for select
  to authenticated
  using (
    bucket_id = 'transfer-proofs'
    and exists (
      select 1 from transfers t
      where t.profile_id::text = (storage.foldername(name))[1]
        and t.estate_id = (select private.auth_estate_id())
        and (select private.auth_role()) = any (array['super_admin'::user_role, 'finance'::user_role])
    )
  );
