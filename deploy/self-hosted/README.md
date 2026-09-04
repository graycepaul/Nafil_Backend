# Self-hosted VPS setup

Builds a complete, isolated copy of the Nafil Estates backend (self-hosted
Supabase + this API) on its own VPS. Nothing here touches the live Supabase
project or Render service — this is a separate stack with its own database,
its own keys, and its own domain, until you deliberately cut over.

## 0. Buy the VPS

Hostinger KVM 2 (2 vCPU / 8 GB RAM) minimum — the self-hosted Supabase stack
runs Postgres, GoTrue (auth), PostgREST, Realtime, Storage, Kong, and Studio
as separate containers, and is noticeably heavier than plain Postgres alone.
Pick Ubuntu 24.04 LTS as the OS. Point a subdomain (e.g. `api.nafilestates.com`)
at the VPS's IP once you have it — you'll need it for TLS.

## 1. Harden the box

```bash
ssh root@your-vps-ip
adduser deploy && usermod -aG sudo deploy
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw enable
```
Disable root SSH login and password auth in `/etc/ssh/sshd_config` once your
`deploy` user's SSH key works — this is the single biggest thing standing
between the VPS and random internet scanners.

## 2. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
usermod -aG docker deploy
```

## 3. Deploy self-hosted Supabase

Use Supabase's own docker-compose stack, not a hand-rolled one — it's the
maintained, correct way to self-host and keeps Auth/Storage/Realtime
compatible with your existing 67 files of mobile client code and RLS
policies.

```bash
git clone --depth 1 https://github.com/supabase/supabase
cd supabase/docker
cp .env.example .env
```

Edit `.env`: set `POSTGRES_PASSWORD`, generate `JWT_SECRET`
(`openssl rand -base64 32`), and generate `ANON_KEY`/`SERVICE_ROLE_KEY` from
that secret using the script Supabase's README links to. Set `API_EXTERNAL_URL`
and `SITE_URL` to `https://api.nafilestates.com`.

```bash
docker network create nafil_net
docker compose up -d
```

Confirm Kong is up: `curl http://localhost:8000/auth/v1/health`.

## 4. Load your schema

Run every migration in [`../../supabase/migrations`](../../supabase/migrations)
against the new database, in order, exactly as they were applied to the
production project:

```bash
for f in /path/to/Nafil\ Backend/supabase/migrations/*.sql; do
  psql "postgresql://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres" -f "$f"
done
```

This is a schema-only copy — no resident data. Do not point this instance at
real users until you've decided to cut over.

## 5. Deploy the backend

```bash
cd /path/to/Nafil\ Backend/deploy/self-hosted
cp .env.backend.example .env.backend   # fill in the real values
docker compose -f docker-compose.backend.yml up -d --build
```

The api container joins `nafil_net`, the same network the Supabase stack is
on, so `DATABASE_URL=postgresql://postgres:...@db:5432/postgres` resolves
by container name.

## 6. Put nginx in front

Install nginx and certbot on the host, drop [`nginx.conf`](nginx.conf) into
`/etc/nginx/sites-available/`, symlink it into `sites-enabled`, then:

```bash
certbot --nginx -d api.nafilestates.com
```

`nginx.conf` splits traffic on this one domain: Supabase's own routes
(`/auth`, `/rest`, `/storage`, `/realtime`) go to Kong, everything else goes
to the FastAPI backend — so `SUPABASE_URL` and your API base URL can be the
same host, matching how the client code already expects to talk to Supabase.

## 7. Wire up the guardrails

Before this stack sees any real traffic, per the infrastructure plan:

- **Uptime monitor** — point UptimeRobot (or similar) at
  `https://api.nafilestates.com/health`.
- **Error tracking** — add a Sentry DSN to `.env.backend` if/when the
  backend is wired for it.
- **Nightly backups** — cron a `pg_dump` from the `db` container to offsite
  storage, with a check that the dump actually succeeded (not just that the
  cron job ran).
- **Test the restore** — before this VPS carries real data, restore a dump
  onto a throwaway database and confirm it works.

## 8. Test end-to-end, still isolated

Build a separate development/staging build of Nafil Mobile pointed at
`https://api.nafilestates.com` and `SUPABASE_URL=https://api.nafilestates.com`,
with its own test accounts. Walk through sign-up, login, issue reporting,
marketplace, wallet — the whole app — against this VPS. Production Supabase
and Render are untouched through all of this.

## 9. Cut over (only when 5–8 are proven)

This is the one step covered in the infrastructure plan's Phase 3, not here —
it involves a real data migration and a maintenance window, and shouldn't
happen until this stack has been tested and the guardrails have been proven
to actually alert you.
