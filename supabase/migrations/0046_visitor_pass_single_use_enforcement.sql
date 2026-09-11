-- ══════════════════════════════════════════════════════════════════════════
-- Visitor passes are single-use at the database level, not just the client
--
-- The gate-scan flow (app/security/index.tsx) already checks
-- `pass.status !== 'pending'` before letting a check-in through, then flips
-- it to 'used' - but visitor_passes_update's RLS had no matching guard, so
-- that was convenience, not enforcement. Two officers scanning the same QR
-- within the same read-then-write window could both pass the client-side
-- check (both read status='pending' before either write lands) and both
-- successfully flip it to 'used', writing two visitor_logs entries for one
-- pass. A resident could likewise update their own already-used/revoked
-- pass back to 'pending', making a single-use credential reusable - exactly
-- the "behaving like the frequent visitor pass" failure mode this closes.
--
-- Requiring status='pending' in the USING clause means Postgres re-checks
-- it against the row as it exists on disk at update time, not the value the
-- client read earlier - the second of two concurrent scans sees the first
-- one's already-committed 'used' status and is correctly rejected, and any
-- action on an already-used/revoked/expired row is rejected the same way.
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
  );
