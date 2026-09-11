-- ══════════════════════════════════════════════════════════════════════════
-- Hide the internal test estate from new-resident search
--
-- There's no separate dev/prod environment - Nafil Gardens has been the
-- team's own test estate since before launch, seeded with the standing
-- @nafil.test demo accounts (superadmin/admin/security/resident) kept
-- around deliberately for ongoing internal testing. With real onboarding
-- starting, a new resident searching for their estate must never see it -
-- but the existing test accounts still need to see their own estate
-- everywhere else in the app (dashboard, headers, admin screens), so this
-- can't just be a delete.
--
-- `hidden` excludes a row from the general "browse all estates" directory
-- (join-estate's search) while still allowing it through for anyone
-- already assigned to it via profile.estate_id - the exact same scoping
-- shape as everywhere else in this schema.
-- ══════════════════════════════════════════════════════════════════════════

alter table estates add column hidden boolean not null default false;

drop policy estates_select on estates;
create policy estates_select on estates for select
  using (
    not hidden
    or id = (select private.auth_estate_id())
  );

update estates set hidden = true where id = '11111111-1111-1111-1111-111111111111';
