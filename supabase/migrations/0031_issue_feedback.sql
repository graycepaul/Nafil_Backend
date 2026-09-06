-- Issue feedback loop: once an issue is marked resolved, resident and admin
-- can go back and forth on whether the fix actually holds before the admin
-- explicitly closes it. Comments are only insertable while status = 'resolved'
-- — that's what "the feedback loop ends at closed" means at the data layer.
alter type issue_status add value 'closed';

create table issue_comments (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references issues(id) on delete cascade,
  author_id uuid not null references profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);

create index issue_comments_issue_idx on issue_comments(issue_id);

alter table issue_comments enable row level security;

-- Resident: read/write comments on their own issue, only while it's in the
-- resolved-but-not-yet-closed window.
create policy issue_comments_resident_select on issue_comments for select
  using (
    exists (
      select 1 from issues i
      where i.id = issue_comments.issue_id
        and i.resident_id = auth.uid()
    )
  );

create policy issue_comments_resident_insert on issue_comments for insert
  with check (
    author_id = auth.uid()
    and exists (
      select 1 from issues i
      where i.id = issue_comments.issue_id
        and i.resident_id = auth.uid()
        and i.status = 'resolved'
    )
  );

-- Admin/super_admin: read/write comments on any issue in their estate, same
-- resolved-only window for posting.
create policy issue_comments_admin_select on issue_comments for select
  using (
    exists (
      select 1 from issues i
      where i.id = issue_comments.issue_id
        and (
          private.auth_role() = 'super_admin'
          or (i.estate_id = private.auth_estate_id() and private.auth_role() = 'admin')
        )
    )
  );

create policy issue_comments_admin_insert on issue_comments for insert
  with check (
    author_id = auth.uid()
    and exists (
      select 1 from issues i
      where i.id = issue_comments.issue_id
        and i.status = 'resolved'
        and (
          private.auth_role() = 'super_admin'
          or (i.estate_id = private.auth_estate_id() and private.auth_role() = 'admin')
        )
    )
  );

-- profiles_select already lets admin/security/finance see everyone in their
-- estate (residents included), but a resident can only see their own row —
-- so without this, the feedback thread's author name resolves to nothing for
-- whichever admin/staff member replies. Scoped tightly: only the profile of
-- someone who has actually commented on an issue this resident reported.
create policy profiles_select_issue_commenters on profiles for select
  using (
    exists (
      select 1 from issue_comments c
      join issues i on i.id = c.issue_id
      where c.author_id = profiles.id
        and i.resident_id = auth.uid()
    )
  );
