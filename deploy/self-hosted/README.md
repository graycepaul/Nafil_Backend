# Self-hosted VPS setup

Builds a complete, isolated copy of the Nafil Estates backend (self-hosted
Supabase + this API) on its own VPS. Nothing here touches the live Supabase
project or Render service — this is a separate stack with its own database,
its own keys, and its own domain, until you deliberately cut over.

## 0. Buy the VPS

Hostinger KVM 2 (2 vCPU / 8 GB RAM) minimum — the self-hosted Supabase stack
runs Postgres, GoTrue (auth), PostgREST, Realtime, Storage, Kong, and Studio
as separate containers, and is noticeably heavier than plain Postgres alone.
Pick the latest Ubuntu LTS as the OS. Point a subdomain (e.g. `api.nafilestates.com`)
at the VPS's IP once you have it — you'll need it for TLS.

## 1. Harden the box

```bash
ssh root@your-vps-ip
adduser deploy && usermod -aG sudo deploy
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw enable
```

Copy your local public key up (`ssh-copy-id deploy@your-vps-ip` from your own
machine, not the server) and confirm `ssh deploy@your-vps-ip` logs in with no
password prompt before touching anything else.

Then disable root login and password auth. Cloud images often ship more than
one `sshd_config.d/*.conf` drop-in with conflicting values (check with
`sudo grep -rn "PermitRootLogin\|PasswordAuthentication" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/`),
and since `Include` runs before the rest of the file, whichever drop-in sorts
first wins. Add one that's guaranteed to sort first and win outright:

```bash
sudo tee /etc/ssh/sshd_config.d/10-hardening.conf > /dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
EOF
sudo sshd -t && sudo systemctl restart ssh
```

Verify from a **new** terminal tab before closing the old one: `ssh deploy@your-vps-ip`
should still work with your key, and `ssh root@your-vps-ip` should be refused outright.

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

Fill in the generated secrets and URLs the scripted way, don't hand-edit them:

```bash
sh utils/generate-keys.sh        # POSTGRES_PASSWORD, JWT_SECRET, legacy ANON/SERVICE_ROLE keys
sh utils/add-new-auth-keys.sh    # asymmetric ES256 keys — the same signing-key system prod already uses
```

Then set the URL/tenant values by hand:

```bash
sed -i \
  -e 's#^SUPABASE_PUBLIC_URL=.*#SUPABASE_PUBLIC_URL=https://api.nafilestates.com#' \
  -e 's#^API_EXTERNAL_URL=.*#API_EXTERNAL_URL=https://api.nafilestates.com/auth/v1#' \
  -e 's#^SITE_URL=.*#SITE_URL=https://app.nafilestates.com#' \
  -e 's#^POOLER_TENANT_ID=.*#POOLER_TENANT_ID=nafil-estates#' \
  .env
```

Before starting the stack, bind the Postgres pooler (`5432`/`6543`) and the
API gateway (`8000`) to `127.0.0.1` in `docker-compose.yml`, not `0.0.0.0` —
Docker inserts its own iptables rules and can expose published container
ports straight to the internet regardless of what UFW says. Check with
`grep -n "5432\|6543\|8000" docker-compose.yml`, prefix each `ports:` entry
with `127.0.0.1:`, then verify from **outside** the VPS (`nc -zv your-vps-ip 5432`
should time out, not succeed) before going further.

```bash
docker compose pull
docker compose up -d
docker compose ps   # everything should show "healthy"
```

## 4. Load your schema

Run every migration in [`../../supabase/migrations`](../../supabase/migrations)
against the new database, in order, exactly as they were applied to the
production project, via the running Postgres container:

```bash
for f in ~/migrations/*.sql; do
  echo "Applying: $f"
  docker exec -i supabase-db psql -U postgres -d postgres < "$f"
done
```

(Copy the migrations folder up first with `scp -r "path/to/Nafil Backend/supabase/migrations" deploy@your-vps-ip:~/migrations`.)
Watch for `ERROR` lines partway through — that means a later migration
depends on something this run skipped or failed.

This is a schema-only copy — no resident data. Do not point this instance at
real users until you've decided to cut over.

## 5. Deploy the backend

```bash
git clone https://github.com/graycepaul/Nafil_Backend.git ~/nafil-backend
cd ~/nafil-backend/deploy/self-hosted
cp .env.backend.example .env.backend   # fill in the real values
docker compose -f docker-compose.backend.yml up -d --build
```

The api container joins `supabase_default`, the network the Supabase stack's
`docker compose up` created automatically, so `DATABASE_URL=postgresql://postgres:...@db:5432/postgres`
resolves `db` by container name, straight to Postgres, no pooler needed for
our own service.

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
