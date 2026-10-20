#!/usr/bin/env bash
# Applies unapplied files from supabase/migrations to the self-hosted database,
# in order, each in its own transaction together with its tracking row. A failed
# migration rolls back cleanly and stops the run (and so the deploy).
#
#   migrate.sh                      apply pending migrations
#   DRY_RUN=1 migrate.sh            list pending migrations, change nothing
#   migrate.sh --baseline 0061      one time: record 0001..0061 as already
#                                   applied (does NOT run them)
#
# Applied migrations are tracked in public.schema_migrations. Env overrides, used
# by the tests: REPO_ROOT, MIGRATIONS_DIR, PSQL_CMD.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$REPO_ROOT/supabase/migrations}"
read -ra PSQL <<< "${PSQL_CMD:-docker exec -i supabase-db psql -U postgres -d postgres}"
DRY_RUN="${DRY_RUN:-0}"

sql() { "${PSQL[@]}" -v ON_ERROR_STOP=1 -qAt "$@"; }

ensure_table() {
  sql <<'SQL'
set client_min_messages = warning;
create table if not exists public.schema_migrations (
  name text primary key,
  applied_at timestamptz not null default now()
);
alter table public.schema_migrations enable row level security;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.schema_migrations from anon, authenticated';
  end if;
end $$;
SQL
}


shopt -s nullglob
files=("$MIGRATIONS_DIR"/[0-9][0-9][0-9][0-9]_*.sql)

if [ "${1:-}" = "--baseline" ]; then
  last="${2:?usage: migrate.sh --baseline <last applied number, e.g. 0061>}"
  ensure_table
  # Assign first, then compare: inside a test the substitution's failure would
  # be swallowed and a dead connection would look like "no rows".
  existing=$(sql -c 'select count(*) from public.schema_migrations')
  if [ "$existing" != "0" ]; then
    echo "schema_migrations already has rows, refusing to baseline again" >&2
    exit 1
  fi
  count=0
  for f in "${files[@]}"; do
    name=$(basename "$f")
    if (( 10#${name%%_*} <= 10#$last )); then
      sql -c "insert into public.schema_migrations (name) values ('$name')"
      count=$((count + 1))
    fi
  done
  echo "Baselined $count migrations up to $last (none were run)"
  exit 0
fi

has_table=$(sql -c "select to_regclass('public.schema_migrations') is not null")
if [ "$has_table" != "t" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "schema_migrations does not exist yet: run 'migrate.sh --baseline <last applied>' first" >&2
    exit 1
  fi
  ensure_table
fi

recorded=$(sql -c 'select count(*) from public.schema_migrations')
if [ "$recorded" = "0" ]; then
  echo "schema_migrations is empty: this database has not been baselined." >&2
  echo "Run 'migrate.sh --baseline <number of the last migration already applied>' once, then retry." >&2
  exit 1
fi

applied=$(sql -c 'select name from public.schema_migrations')
pending=0
for f in "${files[@]}"; do
  name=$(basename "$f")
  if grep -qxF "$name" <<< "$applied"; then
    continue
  fi
  pending=$((pending + 1))
  if [ "$DRY_RUN" = "1" ]; then
    echo "pending: $name"
    continue
  fi
  echo "Applying $name"
  {
    cat "$f"
    printf "\ninsert into public.schema_migrations (name) values ('%s');\n" "$name"
  } | "${PSQL[@]}" -v ON_ERROR_STOP=1 --single-transaction -q -f - >/dev/null
done

if [ "$pending" = "0" ]; then
  echo "No pending migrations"
elif [ "$DRY_RUN" = "1" ]; then
  echo "$pending pending (dry run, nothing applied)"
else
  echo "Applied $pending migration(s)"
fi
