-- ══════════════════════════════════════════════════════════════════════════
-- Round 2 follow-ups:
-- 1. Scheduled visits need a visitor phone column (the app now requires one,
--    same as visitor_passes.visitor_phone already does).
-- 2. Residents can now see the check-in time for their own passes on the
--    visit history screen, which means they need read access to the
--    visitor_logs rows for passes they own (previously security/admin only).
-- ══════════════════════════════════════════════════════════════════════════

alter table scheduled_visits add column visitor_phone text;

drop policy if exists visitor_logs_select on visitor_logs;

create policy visitor_logs_select on visitor_logs for select
  using (
    (select private.auth_role()) = 'super_admin'
    or (estate_id = (select private.auth_estate_id()) and (select private.auth_role()) in ('security', 'admin'))
    or pass_id in (select id from visitor_passes where resident_id = (select auth.uid()))
  );
