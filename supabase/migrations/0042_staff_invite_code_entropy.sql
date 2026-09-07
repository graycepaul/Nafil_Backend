-- Staff invite codes were 8 uppercase hex chars (0007_staff_invites.sql) -
-- 16^8 ≈ 4.3 billion possibilities. Valid for 7 days, and the RPCs that
-- consume them (validate_staff_invite_code, save_staff_invite_profile) are
-- anonymous-callable with only nginx's general rate limit standing between
-- an attacker and brute-forcing a live code (which would leak the target
-- estate/role/email, and let them overwrite the pending invite's profile
-- fields before the real invitee does). 12 hex chars raises that to
-- 16^12 ≈ 281 trillion - the column default only affects new invites, not
-- outstanding ones, so nothing currently pending is touched.
alter table staff_invites
  alter column code set default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
