-- Residents and household members live in the estate, so scanning their
-- e-ID or household card at the gate is an *entry*, not a visit: there is no
-- checkout step for them. Until now those scans wrote a visitor_logs row with
-- checked_out_at = null, indistinguishable from a visitor who is still inside,
-- so they sat in the security "On-site" list forever.
--
-- entry_type separates them. Visitors (passes and scheduled visits) keep the
-- default and still check out; residents and household members are recorded
-- for the register but never count as on-site.
alter table visitor_logs
  add column entry_type text not null default 'visitor'
    check (entry_type in ('visitor', 'resident', 'household'));

-- Existing rows: a visitor's QR scan always carries a pass (pass_id is set), so
-- a QR entry with no pass can only be a resident or household credential.
-- Household cards are told apart from resident e-IDs by name within the estate.
update visitor_logs vl
   set entry_type = case
     when exists (
       select 1 from household_members h
        where h.estate_id = vl.estate_id and h.full_name = vl.visitor_name
     ) then 'household'
     else 'resident'
   end
 where vl.pass_id is null and vl.method = 'qr';

-- Released app builds do not send entry_type, so classify their QR scans here
-- too. Only QR: a manually typed resident code is indistinguishable from a
-- scheduled-visit check-in (both are method 'manual' with no pass), which must
-- keep its checkout. New builds send entry_type explicitly for every path.
create or replace function private.classify_visitor_log_entry() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.entry_type = 'visitor' and new.pass_id is null and new.method = 'qr' then
    new.entry_type := case
      when exists (
        select 1 from household_members h
         where h.estate_id = new.estate_id and h.full_name = new.visitor_name
      ) then 'household'
      else 'resident'
    end;
  end if;
  return new;
end;
$$;

create trigger classify_visitor_log_entry
  before insert on visitor_logs
  for each row execute function private.classify_visitor_log_entry();
