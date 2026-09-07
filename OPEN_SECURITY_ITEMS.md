# Open security/infra items

Tracking log for follow-ups flagged in the 2026-09-07 pre-launch security
and scalability audit that weren't closed immediately - either because they
need a decision only the team can make, or because they need verifying
against live infra this repo can't see. Check items off in place; keep this
file rather than letting them live only in chat history.

## Open

- [ ] **Pick an offsite backup target.** `deploy/self-hosted/backup.sh`
      encrypts nightly dumps (AES-256) but still only writes to
      `~/backups` on the same VPS - if the VPS is lost, the backups are
      lost with it. Needs a destination chosen (Backblaze B2, S3, etc.)
      and an `rclone`/similar sync step added to the script.
- [ ] **Verify the Supabase stack's own `docker-compose.yml` port
      bindings.** Not in this repo - it's Supabase's self-hosted compose
      file on the VPS. Confirm Postgres (5432/6543) and the API gateway
      (8000) are bound to `127.0.0.1`, not `0.0.0.0`. This is the single
      highest-impact item from the infra audit; everything else assumes
      it's already true.
- [ ] **Install fail2ban** (or equivalent) on the VPS for SSH brute-force
      protection. Key-only auth already mitigates password guessing, but
      there's no lockout for repeated failed attempts today.
- [ ] **Revisit DB connection pooling** (Supavisor/pgbouncer) once the
      backend runs more than a couple of `uvicorn` workers, or if
      connection-pressure symptoms show up. Not urgent at the current
      2-4 worker scale - direct connections comfortably fit under
      Postgres's default `max_connections`.
- [ ] **Confirm GoTrue's own rate-limit env vars** are set on the
      self-hosted Supabase stack (e.g. email-send / token-refresh
      limits) - nginx now rate-limits the reverse-proxied path, but
      GoTrue may have its own separate, more specific limits worth
      checking are non-default.
- [ ] **Confirm unattended OS security updates** are enabled on the VPS
      (`unattended-upgrades` or equivalent) - not covered by the deploy
      README's hardening steps.

## Closed (2026-09-07)

- [x] Internal push secret rotated (was committed in plaintext in
      `0028_generic_push_notifications.sql`) - see
      `0041_batch_push_notifications.sql`.
- [x] Push notification fan-out batched (`/push/notify-batch` +
      statement-level trigger) - a bulk event is now ~1 backend request
      instead of one per recipient.
- [x] Internal-secret comparison switched to `hmac.compare_digest`
      (was a timing-unsafe `!=`).
- [x] Signup no longer confirms whether an email is already registered.
- [x] Staff invite codes bumped from 8 to 12 hex characters.
- [x] nginx rate limiting added (auth paths, internal push path, general
      API traffic) plus HSTS/X-Frame-Options/X-Content-Type-Options/
      Referrer-Policy headers.
- [x] Nightly backups encrypted at rest (AES-256).
- [x] API container given a memory/CPU ceiling; worker count made
      tunable via `WEB_CONCURRENCY` without a rebuild.
