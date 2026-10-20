# Setting up email (password reset) on the self-hosted auth service

Today `~/supabase/docker/.env` on the VPS still has the template mail settings
(`SMTP_HOST=supabase-mail`, sender `fake_sender`). No such mail server exists, so
every password-reset request fails with a 500 and **residents cannot reset a
forgotten password**. Sign-ups are unaffected because `ENABLE_EMAIL_AUTOCONFIRM`
is `true` (nobody is sent a confirmation email, and nobody needs one).

This guide uses **Resend** (free plan at the time of writing: 3,000 emails a
month, 100 a day, SMTP included; check resend.com/pricing). Any SMTP provider
works the same way, only the host and credentials differ.

## 1. Resend account and domain

1. Create an account at resend.com and add the domain you will send from, for
   example `nafilestates.com` (or a subdomain such as `mail.nafilestates.com`).
2. Resend shows DNS records (SPF, DKIM, and optionally MX). Add them in
   Namecheap under Advanced DNS and wait for Resend to show the domain as
   **Verified**.
3. Create an API key with "Sending access" only. Copy it once; it is the SMTP
   password. Treat it like a password: never commit it or paste it into chat.

## 2. Configure the auth service (on the VPS)

```bash
ssh deploy@vps.nafilestates.com
cd ~/supabase/docker
cp .env .env.bak-$(date +%Y%m%d)
```

Edit `.env` and set (use your own sender address on the verified domain):

```
SMTP_HOST=smtp.resend.com
SMTP_PORT=465
SMTP_USER=resend
SMTP_PASS=<the Resend API key>
SMTP_ADMIN_EMAIL=no-reply@nafilestates.com
SMTP_SENDER_NAME=Nafil Estates
```

Leave `ENABLE_EMAIL_AUTOCONFIRM=true` as it is. Then restart only the auth
container:

```bash
docker compose up -d auth
docker compose ps auth     # should show healthy
```

## 3. Check the redirect allow-list

Reset links send people back to the app. In the same `.env`, `SITE_URL` and
`ADDITIONAL_REDIRECT_URLS` must include the addresses the app asks for:
`https://app.nafilestates.com/set-password` and `nafil-estates://set-password`.
If they do not, the email link lands on the wrong page. See "Restarting the
Supabase auth service" in `AGENTS.md`.

## 4. Test

1. In the app, tap "Forgot password?" and enter an account you can read mail for.
2. The app should say "Check your email", and the message should arrive within a
   minute (check spam the first time).
3. If it does not, read the auth logs:
   `docker logs supabase-auth --since 10m | grep -iE "smtp|mail|error"`.
   `no such host` means `SMTP_HOST` is still the template value; an
   authentication error means the API key or `SMTP_USER` is wrong.

The app (1.0.5 and later) now shows "Something went wrong on our side" instead of
a raw error if the mail service ever fails again.
