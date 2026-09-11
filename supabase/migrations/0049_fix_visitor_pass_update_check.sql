-- ══════════════════════════════════════════════════════════════════════════
-- URGENT FIX: 0046 broke every real check-in, not just the race condition
--
-- 0046 added `status = 'pending'` to visitor_passes_update's USING clause to
-- close a real race condition/reuse gap - correct in intent, but it left no
-- explicit WITH CHECK, and Postgres defaults an omitted WITH CHECK to the
-- USING expression. That means the NEW row (after the update) was ALSO
-- required to satisfy status = 'pending' - but the entire point of a
-- check-in is to move status FROM 'pending' TO 'used'. Every real scan at
-- the gate started failing RLS ("new row violates row-level security
-- policy") from the moment 0046 went live.
--
-- USING (checked against the OLD row) is what actually enforces single-use -
-- keeping it. WITH CHECK (checked against the NEW row) drops the status
-- requirement entirely, since the new row is legitimately supposed to have
-- a different status than the old one.
-- ══════════════════════════════════════════════════════════════════════════

drop policy visitor_passes_update on visitor_passes;
create policy visitor_passes_update on visitor_passes for update
  using (
    status = 'pending'
    and (
      resident_id = (select auth.uid())
      or (
        estate_id = (select private.auth_estate_id())
        and (select private.auth_role()) = any (array['super_admin'::user_role, 'security'::user_role, 'admin'::user_role])
      )
    )
  )
  with check (
    resident_id = (select auth.uid())
    or (
      estate_id = (select private.auth_estate_id())
      and (select private.auth_role()) = any (array['super_admin'::user_role, 'security'::user_role, 'admin'::user_role])
    )
  );
