-- Two gaps in the dues/transfer flow:
--
-- 1. Dues have no category, so the wallet's "More services" screen can't
--    show real service-fee/security-charge totals and just says "coming
--    soon". Adding `category` lets an admin tag a due at creation time and
--    the wallet screen query by it instead.
--
-- 2. A rejected transfer is a dead end for the resident today — it just
--    disappears from their "pending transfers" list with a notification to
--    "contact estate management". `proof_url` + `contest_transfer()` let
--    them attach a fresh proof of payment and put it back in the finance
--    queue as 'pending' for another look, instead of requiring an
--    out-of-band conversation.

create type due_category as enum ('general', 'service_fee', 'security');

alter table dues add column category due_category not null default 'general';

alter table transfers add column proof_url text;

-- ── transfer-proofs storage bucket, same shape as listing-photos ──
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('transfer-proofs', 'transfer-proofs', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy transfer_proofs_select_public on storage.objects for select
  using (bucket_id = 'transfer-proofs');

create policy transfer_proofs_insert_own on storage.objects for insert
  with check (bucket_id = 'transfer-proofs' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Resident contests a rejected transfer of their own: attach a proof and put
-- it back in the pending queue. Security definer since transfers deliberately
-- has no update RLS policy (same reasoning as confirm_transfer/reject_transfer
-- — status changes only happen through a checked function, never a raw update).
create or replace function contest_transfer(p_transfer_id uuid, p_proof_url text) returns void
  language plpgsql security definer set search_path = public as $$
declare
  t transfers;
begin
  select * into t from transfers where id = p_transfer_id and profile_id = (select auth.uid()) and status = 'rejected';
  if not found then
    raise exception 'transfer not found or not eligible to contest';
  end if;

  update transfers
     set status = 'pending', proof_url = p_proof_url, confirmed_at = null, confirmed_by = null
   where id = p_transfer_id;
end;
$$;

alter table notifications drop constraint if exists notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'announcement', 'emergency', 'issue_status', 'visitor_pass_used',
  'join_request_approved', 'staff_invite_accepted', 'household_member_scanned', 'issue_reported',
  'order_placed', 'order_completed', 'transfer_confirmed', 'transfer_rejected',
  'listing_suspended', 'listing_reinstated', 'transfer_contested'
));

-- Tell an estate's finance/super_admin staff when a resident resubmits a
-- rejected transfer — fans out to every profile in that role/estate, since
-- notifications are per-profile and there's no single "estate finance inbox".
create or replace function private.notify_transfer_contested() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' and old.status = 'rejected' then
    insert into notifications (profile_id, type, title, body, data)
    select p.id, 'transfer_contested', 'Transfer resubmitted',
           new.label || ' was resubmitted with a new proof of payment for review.',
           jsonb_build_object('transfer_id', new.id)
    from profiles p
    where p.estate_id = new.estate_id and p.role in ('finance', 'super_admin');
  end if;
  return new;
end;
$$;

create trigger notify_transfer_contested
  after update on transfers
  for each row execute function private.notify_transfer_contested();
