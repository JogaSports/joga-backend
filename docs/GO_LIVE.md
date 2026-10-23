# Going live

How to take this backend from your laptop to a production Supabase project.
Do the steps in order. Each ends with a check, so if something breaks you
know it was the last step.

You'll end up with:

| | Staging | Production |
|---|---|---|
| Supabase project | `joga-staging` | `joga-prod` |
| Deploys | Every push to `main` | Only when you run the Deploy workflow and pick `production` |
| RevenueCat | Sandbox purchases | Real purchases |
| Used by | Your test builds, TestFlight | The App Store / Play Store app |

The Welsh FA demo on Vercel uses fake data and never talks to either project.

---

## 1. Check it locally

Needs Docker Desktop running and the Supabase CLI (`brew install supabase/tap/supabase`).

```bash
cd joga-backend
supabase start
supabase db reset     # every migration + the demo seed, from scratch
supabase test db      # 84 tests, all should pass
```

Studio: http://127.0.0.1:54323. Emails (sign-up codes): http://127.0.0.1:54324.
Demo logins: `ray@joga.demo`, `dan@joga.demo`, `admin@joga.demo`, password
`joga-demo-2026`.

Commit and push. The **CI** workflow runs the same tests on GitHub.

**Check:** CI is green on the commit.

---

## 2. Create the two projects

Supabase dashboard → the JogaSports organisation → **New project**, twice:

| | Name | Region | Plan |
|---|---|---|---|
| 1 | `joga-staging` | West EU (London) | Free is fine |
| 2 | `joga-prod` | West EU (London) | Free for now; **Pro** before real players |

Both projects can stay on the **free plan** until real players arrive. Free
projects pause after a week without traffic (press **Restore** on the
project page to wake one) and have no automatic backups, which is fine while
the only data is test data. Before launch, upgrade the organisation to
**Pro** (from $25/month) for daily backups and no pausing.

Save each **database password** in your password manager when you create it.
You can't see it again.

From each project, note:

- **Project ref**: the id in the URL (`https://supabase.com/dashboard/project/<ref>`)

- **Settings → API Keys**: the **publishable** key (goes in the app) and the
  **secret** key (never in the app, never in git)

**Check:** both projects show "Healthy" on their home page.

---

## 3. Let GitHub deploy

1. Create a personal access token: supabase.com/dashboard/account/tokens →
   name it `github-deploy`.
2. GitHub → `joga-backend` → **Settings → Environments**:
   - New environment **staging**. Add secrets `SUPABASE_ACCESS_TOKEN`,
     `SUPABASE_DB_PASSWORD` (staging's), `SUPABASE_PROJECT_ID` (staging's ref).
   - New environment **production**. Same three secrets with production's
     password and ref. Tick **Required reviewers** and add yourself, so a
     production deploy waits for your approval.
3. **Settings → Branches → Add branch ruleset** for `main`: require a pull
   request and the CI checks to pass. This stops a broken migration reaching
   staging.

**Deploy staging:** push to `main` (or Actions → Deploy → Run workflow →
`staging`).

**Deploy production:** Actions → Deploy → Run workflow → `production` →
approve.

The workflow runs `supabase db push` (migrations only, never the seed) then
`supabase functions deploy`.

**Check:** in each project's **Database → Migrations** you see all five
migrations, and **Edge Functions** lists `revenuecat-webhook`. The Stripe
functions (`create-payment`, `stripe-webhook`) aren't deployed until the PO
decides how bookings are paid.

---

## 4. Secrets for the edge functions

Only the Joga+ webhook needs one for now. Run once per project (log in first
with `supabase login`):

```bash
supabase secrets set --project-ref <staging-ref> REVENUECAT_WEBHOOK_AUTH=<long random string>
supabase secrets set --project-ref <prod-ref>    REVENUECAT_WEBHOOK_AUTH=<another long random string>
```

Make random strings with `openssl rand -hex 32`.

**Check:** `supabase secrets list --project-ref <ref>` shows it.

---

## 5. Auth settings (each project)

Dashboard → **Authentication**:

| Where | Setting |
|---|---|
| Sign In / Providers → Email | Enabled. **Confirm email** on. Minimum password length **8** |
| Sign In / Providers → Apple | Enabled. Client IDs: your iOS bundle ID (and Services ID for web/Android). Secret key only needed for web/Android |
| Sign In / Providers → Google | Enabled. Client IDs: web ID first, then iOS and Android IDs, comma-separated. Client secret: the web client's. **Skip nonce check** on |
| URL Configuration | Site URL: your website. Redirect URLs: `com.jogasports.app://login-callback` (must match the bundle ID) |
| Emails → Templates → Confirm signup | Subject `Your Joga code: {{ .Token }}`; body from `supabase/templates/confirmation.html` |
| Emails → Templates → Reset password | Subject `Reset your Joga password`; body from `supabase/templates/recovery.html` |
| Emails → SMTP Settings | See step 6 |
| Rate Limits | Emails per hour: 100 once SMTP is set |
| Attack Protection | Leave CAPTCHA off until the app sends a CAPTCHA token on sign-up, or every sign-up will fail. Once on Pro, turn on **leaked password protection** |

Settings that already match `config.toml` locally: 6-digit codes that last
an hour, refresh token rotation, anonymous sign-ins off.

**Check:** sign up in the app against staging, get the code by email, enter
it, finish the profile.

---

## 6. Email through Resend

Supabase's own email sender only allows a few emails an hour and isn't for
production.

1. Resend → **Domains** → add your domain (e.g. `jogasports.co.uk`) → add the
   DNS records it shows at your domain registrar → wait for **Verified**.
2. Resend → **API Keys** → create one with **sending access** only, one per
   project.
3. Supabase → Authentication → Emails → **SMTP Settings** → enable custom SMTP:

   | Field | Value |
   |---|---|
   | Sender email | `no-reply@<your domain>` |
   | Sender name | `Joga` |
   | Host | `smtp.resend.com` |
   | Port | `465` |
   | Username | `resend` |
   | Password | the Resend API key |

**Check:** request a sign-up code; it arrives from `no-reply@<your domain>`
and shows in Resend → Logs.

---

## 7. Joga+ with RevenueCat

Joga+ is a digital subscription, so it goes through App Store / Play billing.

1. RevenueCat → project → **Integrations → Webhooks**: URL
   `https://<prod-ref>.supabase.co/functions/v1/revenuecat-webhook`,
   **Authorization header** = production's `REVENUECAT_WEBHOOK_AUTH`.
   Add a second webhook for staging if you test purchases there.
2. In the app, configure RevenueCat with the Supabase user id as the app
   user id, so the webhook can match the player.

**Check:** RevenueCat → Webhooks → **Send test event** returns 200.

**Booking payments** are on hold until the PO decides how venues are paid.
The booking functions already work without card payments: a booking the
player's wallet credit covers goes through `confirm_booking_with_wallet`.
If the PO chooses card payments, Stripe plugs in through the two functions
already in the repo (set `enabled = true` for them in `config.toml`, add
them to the deploy line in `deploy.yml`, and set `STRIPE_SECRET_KEY` and
`STRIPE_WEBHOOK_SECRET`).

---

## 8. Real data in production

The migrations create the five towns and the reward rules. Venues and games
are yours to add.

1. **Make yourself admin.** Sign up in the production app, then in the SQL
   editor:

   ```sql
   update public.profiles set role = 'admin'
   where id = (select id from auth.users where email = 'you@example.com');
   ```

2. **Add venues** (Table Editor → `venues`, or SQL):

   ```sql
   insert into public.venues (name, city_id, address, surface, parking, facilities)
   values ('Swansea Bay 3G', 'swansea', 'Fabian Way, Swansea SA1',
           '3G · moulds or astros', 'Free, on site',
           '{floodlights,changing_rooms,step_free,defibrillator,first_aid,parking}');
   ```

3. **Make organisers.** They sign up in the app first, then:
   `update public.profiles set role = 'organiser' where id = '<their id>';`

4. **Add games:**

   ```sql
   insert into public.games (format, venue_id, pitch, starts_at, tags,
                             price_pence, venue_cost_pence, organiser_id)
   values ('five_a_side', '<venue id>', 'Pitch 1',
           '2026-11-05 19:00 Europe/London', '{mixed}', 700, 5000, '<organiser id>');
   ```

   Capacity fills in from the format (10 or 14).

5. Check the prices and rules in `app_settings` (booking fee £1, 5-minute
   hold, 24-hour free cancellation, £2 referral credit) and `reward_rules`.

Never run `seed.sql` against a hosted project: it creates demo users with a
known password.

**Check:** the app's Find screen shows your games in the right town.

---

## 9. Security checklist

Before real players:

- [ ] Dashboard → **Advisors → Security Advisor**: no errors. Then
      **Performance Advisor**.

- [ ] **Database → Settings**: SSL enforcement on.

- [ ] Two-factor authentication on every Supabase, GitHub,
      RevenueCat, Resend, Apple and Google account that can touch production.

- [ ] Only the people who need it are members of the production project.

- [ ] The secret key and database password exist only in your password
      manager, GitHub environment secrets and Supabase secrets. If one ever
      lands in git or a chat, rotate it.

- [ ] Organisation upgraded to **Pro**, and daily backups showing under
      Database → Backups. Add point-in-time recovery ($100/month per 7 days)
      once you take real
      money at volume.

- [ ] UK GDPR: privacy policy in the app and on the website; register with
      the ICO and pay the data protection fee; sign the data processing
      agreements (Supabase, RevenueCat, Resend, PostHog, Google
      Firebase); record where data is stored (Supabase London region).

- [ ] Safety: someone checks `reports` at least daily. In Studio:
      `select * from reports where status = 'open' order by created_at;`

---

## 10. After launch

**Changing the database:** `supabase migration new <name>` → write SQL →
`supabase db reset && supabase test db` → pull request → merge (deploys to
staging) → test on staging → run Deploy → `production`.

Never edit a migration that has already been deployed: add a new one.

**Undoing a change:** migrations only go forward. Write a new migration that
reverses it. For data loss, restore from Database → Backups (this rolls the
whole database back to that day).

**Watching it:** Dashboard → Logs (API, Postgres, Edge Functions) and
Reports. RevenueCat shows webhook failures; check them after
every release.
