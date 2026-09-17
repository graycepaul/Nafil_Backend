# Production infrastructure — read this before touching deploy or migrations

Production runs on a self-hosted VPS. It does **not** run on any Supabase
Cloud project, regardless of what any `.env.example` placeholder or old
comment might suggest. Read this whole file before running a migration,
restarting anything, or debugging a deploy — several mistakes here look
harmless in the moment and cause real, hard-to-diagnose incidents later
(see "Incidents" at the bottom).

## The deprecated Supabase Cloud project — do not touch it

- Project ref `itfepppqjtodmizbglze`, named "Nafil DB" in the Supabase
  dashboard/MCP tooling. This was the *original* backend before the project
  migrated to self-hosted infrastructure.
- It is permanently deprecated and has been deliberately **paused**.
- Never unpause/restore it. Never point any env var
  (`SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_URL`, etc.) at any `*.supabase.co`
  URL for this project again — the only legitimate Supabase URL anywhere in
  this codebase is `https://api.nafilestates.com`.
- If you ever find it un-paused, that's a mistake, not a feature - pause it
  again (confirm with the user first; it's a real action on their account)
  and go find whatever pointed at it, because something is misconfigured.

## SSH access

```
ssh deploy@vps.nafilestates.com
```

Key-based, no password. `root@` login is disabled by design.

## Two separate stacks live on this one VPS — don't confuse them

1. **`~/supabase/docker`** — the self-hosted Supabase stack itself
   (Postgres, GoTrue/auth, PostgREST, Storage, Realtime, the Envoy gateway,
   Studio), from Supabase's own official docker-compose template. Its own
   `.env` holds `SITE_URL`, `ADDITIONAL_REDIRECT_URLS`, `API_EXTERNAL_URL`,
   JWT secrets, etc. This is a *different* git-untracked setup, not part of
   this repo.
2. **`~/nafil-backend`** — a separate `git clone` of *this* repo
   (`github.com/graycepaul/Nafil_Backend`) on the VPS, running only the
   FastAPI `api` service (`deploy/self-hosted/docker-compose.backend.yml` +
   `.env.backend`).

**Merging or pushing to GitHub does not deploy anything by itself.** The
VPS's `~/nafil-backend` checkout needs an explicit `git pull` and rebuild —
this has already caused a real incident (see below).

## Applying a new migration

```
scp supabase/migrations/00XX_name.sql deploy@vps.nafilestates.com:~/migrations/
ssh deploy@vps.nafilestates.com "docker exec -i supabase-db psql -U postgres -d postgres < ~/migrations/00XX_name.sql"
```

Watch the output for `ERROR` lines — a partial failure part-way through
still prints `CREATE FUNCTION`/etc. for the statements that succeeded.

## Deploying a backend code change

```
ssh deploy@vps.nafilestates.com "cd ~/nafil-backend && git pull && cd deploy/self-hosted && docker compose -f docker-compose.backend.yml up -d --build"
```

Do this **every time** `app/` changes, even alongside a migration that
looks self-contained — a migration whose trigger calls a new endpoint
will fail (silently, since pg_net is fire-and-forget) until the matching
backend code is actually deployed too.

## nginx config

`deploy/self-hosted/nginx.conf` in this repo is the source of truth, but
it is **not** auto-deployed. After changing it: copy it to
`/etc/nginx/sites-available/` on the VPS, run `nginx -t`, then reload.

## Restarting the Supabase auth service (GoTrue)

Needed after changing `~/supabase/docker/.env` (e.g. `SITE_URL` or
`ADDITIONAL_REDIRECT_URLS`):

```
ssh deploy@vps.nafilestates.com "cd ~/supabase/docker && docker compose up -d auth"
```

## Debugging a stuck signup/auth email

- The confirmation-email redirect is controlled by
  `~/supabase/docker/.env`'s `SITE_URL`/`ADDITIONAL_REDIRECT_URLS` on the
  VPS — nothing in this repo controls it directly.
- To check whether a request actually reached this VPS at all:
  `docker logs supabase-envoy --since 1h` (the gateway) and
  `docker logs supabase-auth --since 1h`.
- If a real signup happened but **nothing** shows up in those logs, the
  client almost certainly talked to the deprecated Cloud project instead
  (see above) — don't trust what the repo's env files say the client
  should be doing; check what the actually-deployed client is doing (e.g.
  `curl` the live web bundle and grep it for the Supabase URL it has baked
  in).

## Vercel gotcha (affects the mobile app's web export → app.nafilestates.com)

Vercel **project-level Environment Variables** (dashboard: Settings →
Environment Variables) can silently override `vercel.json`'s inline `env`
block at build time. If a deployed web build is pointing at the wrong
backend despite `vercel.json` in the repo being correct, check the
dashboard env vars first, not just the repo. Also: **"Promote to
Production" reuses an existing build artifact — it does not rebuild.**
Fixing env vars requires an actual **Redeploy** afterward, not just
promoting an old build.

## Incidents (why every rule above exists)

- **2026-09-07**: `app.nafilestates.com`'s deployed web build still had the
  deprecated Cloud project's URL baked in, months after the self-hosted
  migration and after `vercel.json` had already been fixed - the *actual*
  cause was a Vercel dashboard env var override, invisible from the repo.
  Real signups were silently landing in the wrong, deprecated database the
  entire time. Caught only because a confirmation email linked to
  `localhost:3000` (the deprecated project's own never-configured
  `SITE_URL`).
- **2026-09-07**: A migration (`0041`) that added a new backend endpoint
  was applied to the VPS database *before* the matching backend code was
  deployed there - the VPS's `~/nafil-backend` checkout was several
  commits behind `origin/main` because merging on GitHub doesn't deploy by
  itself. Every push notification silently failed (404, then a secret
  mismatch, then a real `KeyError`) across three separate rounds of
  debugging before all of it was actually resolved.
