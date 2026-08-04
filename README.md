# Nafil Estates — Backend

FastAPI service for Nafil Estates, using the same stack as Arbinx-Backend
(FastAPI + SQLAlchemy + Postgres + JWT + reportlab + APScheduler).

## Division of responsibility

Supabase is the source of truth. The mobile app talks to Supabase **directly** for auth
and ordinary CRUD (visitor passes, issues, announcements) — that path is protected by Row
Level Security, so it needs no server in between.

This service exists for the things Supabase/PostgREST can't do well:

- **PDF generation** — visitor reports, statements, invoices (reportlab/pypdf)
- **Scheduled jobs** — expiring stale visitor passes, billing reminders, digests (APScheduler)
- **Aggregations/reports** — multi-table analytics across estates
- **Third-party integrations** — payment gateways, utility vending, SMS (httpx)
- **Anything needing the service-role key**, which must never ship in the mobile app

It authenticates by **verifying Supabase-issued JWTs** (`app/core/security.py`) rather than
issuing its own — one identity system, no second user table.

## Running it

The venv already exists and dependencies are installed. From `Nafil Backend/`:

```bash
source .venv/bin/activate && uvicorn app.main:app --reload
```

API docs at http://localhost:8000/docs · health check at http://localhost:8000/health

### First run: fill in `.env`

`.env` exists with `SUPABASE_URL` already set, but **three secrets are blank** and the
server will not boot without them (pydantic-settings fails fast on startup, by design —
better a clear error than a half-configured service):

| Variable | Where to get it |
|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Dashboard → Settings → API Keys → `service_role` → Reveal |
| `SUPABASE_JWT_SECRET` | Dashboard → Settings → API → JWT Settings → JWT Secret |
| `DATABASE_URL` | Replace `[YOUR-PASSWORD]` with your database password |

If startup fails with `ValidationError: 4 validation errors for Settings`, that's this —
one or more values are still blank.

### Fresh machine

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # then fill in the three secrets above
```

## Structure

```
app/
  main.py            # app factory, CORS, router registration, scheduler lifespan
  core/
    config.py        # pydantic-settings, env-driven
    db.py            # SQLAlchemy engine/session, Base, get_db dependency
    security.py      # Supabase JWT verification + require_roles() dependency
  models/models.py    # SQLAlchemy models mirroring the Supabase schema
  schemas/            # Pydantic request/response models
  routers/            # HTTP endpoints (health, reports)
  services/           # pdf.py (reportlab), scheduler.py (APScheduler jobs)
supabase/migrations/    # schema + RLS policies (source of truth)
```

## Database migrations

Schema lives in `supabase/migrations/` and is applied via the Supabase SQL editor or
`supabase db push`. The SQLAlchemy models are a **mapping**, not a migration tool — if you
change a migration, update `app/models/models.py` to match.

All four migrations are **already applied** to project `itfepppqjtodmizbglze` ("Nafil DB"):

| # | Migration | What it does |
|---|---|---|
| 0001 | `init_core_schema` | Tables, enums, indexes, RLS policies |
| 0002 | `auth_user_trigger` | Auto-create `profiles` row on signup |
| 0003 | `move_helpers_to_private` | Move SECURITY DEFINER helpers out of the REST-exposed `public` schema |
| 0004 | `rls_performance_and_fk_indexes` | InitPlan-wrap auth calls, consolidate policies, index FKs |

### Writing RLS policies

Two rules, both learned from Supabase's advisor on this schema:

1. **Wrap auth calls in a subquery**: `(select auth.uid())`, not `auth.uid()`. Otherwise
   Postgres re-evaluates it per row.
2. **One policy per action per table.** Permissive policies are OR'd but each is *executed* —
   a `FOR ALL` policy alongside a `FOR SELECT` one means both run on every read.

Run `get_advisors` (or the dashboard's Advisors tab) after any schema change.

## Notes

- `playwright` is in requirements (carried over from the Arbinx stack) but unused so far.
  If nothing ends up needing headless-browser rendering, drop it — it's a heavy install.
- `passlib`/`python-multipart` are likewise unused while auth stays with Supabase; keep them
  only if you add file uploads or local password handling.
- The scheduler runs in-process. Running multiple uvicorn workers would double-fire jobs —
  use a single scheduler instance or an advisory lock before scaling out.
