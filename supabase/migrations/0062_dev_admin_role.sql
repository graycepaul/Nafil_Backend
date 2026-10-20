-- A platform-developer role, separate from `super_admin` (the estate owner).
-- It is only checked by the backend's /devcontrol endpoints; no RLS policy
-- mentions it, so an account holding it has no access to estate data through
-- the app. Its own migration for the same reason as 0023: a newly added enum
-- value can't be referenced until it's committed.
alter type user_role add value if not exists 'dev_admin';
