# joga-backend

Backend for **Joga Sports**: Supabase (Postgres, Auth, Edge Functions) for
booking recreational football in Wales (Cardiff, Swansea, Newport, Wrexham)
and Bristol, tracking stats, streaks and rewards, player safety, community
impact numbers, and the Joga+ membership.

The Flutter app lives in its own repo (`joga-app`) and talks to this
backend through the functions and views documented in
[`docs/API.md`](docs/API.md).

---

## Quick start

Requires the [Supabase CLI](https://supabase.com/docs/guides/local-development)
and Docker. Deno is only needed to check edge functions.

```bash
supabase start        # starts everything locally, applies migrations + seed
supabase test db      # runs the database tests
```

Local Studio: http://127.0.0.1:54323 · API: http://127.0.0.1:54321

`supabase start` prints the local **publishable** and **secret** keys. The
Flutter app uses the publishable key and the API URL.

### Demo logins (local seed only)

Password for all: `joga-demo-2026`

| Email | Role | Notes |
|---|---|---|
| `ray@joga.demo` | Player | Same data as the app demo: game tonight, 4-week streak, £7.50 wallet |
| `dan@joga.demo` | Organiser | Runs tonight's game, so can submit its result |
| `admin@joga.demo` | Admin | Sees the admin dashboard data |

### Edge functions locally

```bash
cp supabase/functions/.env.example supabase/functions/.env   # add Stripe test keys
supabase functions serve --env-file supabase/functions/.env
stripe listen --forward-to http://127.0.0.1:54321/functions/v1/stripe-webhook
```

Or use the `Makefile`: `make start`, `make reset`, `make test`,
`make functions-serve`, `make functions-check`.

## What's in here

```
supabase/
  config.toml                     Local project config (auth, functions)
  migrations/
    …100_schema.sql               Types, tables, reference data
    …200_functions.sql            Booking, match, stats, streak, reward logic
    …300_security.sql             Row-level security, grants, views
    …400_realtime_and_jobs.sql    Realtime publication, pg_cron jobs
    …22…100_recreational_wales_safety_impact.sql
                                  Welsh towns, new tags, no levels, profile
                                  set-up, facilities, safety, impact
  seed.sql                        Local demo data (matches the app's demo)
  templates/                      Auth emails: 6-digit sign-up code, password reset link
  tests/                          pgTAP tests: security, booking, matches, membership,
                                  profile and safety, impact
  functions/
    create-payment/               Stripe PaymentIntent for a held space (not deployed yet)
    stripe-webhook/               Confirms paid bookings; refunds if the space was lost (not deployed yet)
    revenuecat-webhook/           Keeps Joga+ memberships in sync
    _shared/                      Stripe client and HTTP helpers
docs/
  API.md                          Everything the app can call, with errors
  DATA_MODEL.md                   Tables and how they relate
  GO_LIVE.md                      Production deployment, step by step
.github/workflows/                CI (tests, checks) and deploy
```

## How it's built

- **Postgres does the important work.** Holding a space, booking, cancelling,
  submitting results and paying rewards are database functions that run in
  one transaction. The last space is protected by locking the game row, so
  two people can't both get it.
- **Row-level security on every table.** Players read their own bookings and
  wallet; match results are social. Nothing that involves money, spaces or
  stats can be written to directly, only through the functions.
- **The wallet is a ledger.** Entries are append-only; the balance is the sum.
- **Rules are data.** Booking fee, hold length, cancellation window and reward
  amounts live in `app_settings` and `reward_rules`, so they change without a
  release.
- **Sport-aware from day one.** Games have a `sport` (football now; padel and
  badminton ready) and a `format`.
- **Internal helpers are private.** Functions in the `private` schema can't be
  called from the app. Public functions check who's calling themselves.

## Booking and payment flow

Card payments are on hold until the PO decides how bookings are paid; the
Stripe functions are in the repo but switched off. This is how they work
when switched on.

```
App                               Database / functions                Stripe
 │ rpc hold_space(game) ─────────▶ locks game, holds a space 5 min
 │ fn create-payment(hold) ──────▶ prices from DB ─────────────────▶ PaymentIntent
 │ ◀──────────── clientSecret ─────────────────────────────────────────┘
 │ Payment Sheet (Apple Pay / card) ───────────────────────────────▶ charge
 │                                 stripe-webhook ◀──── payment_intent.succeeded
 │                                 confirm_paid_booking: booking + wallet entry
 │ realtime: bookings / wallet ◀── (or refund if the space was lost)
```

If wallet credit covers the whole price, the app calls
`confirm_booking_with_wallet(hold)` instead and Stripe isn't involved.

## Deploying

Two hosted projects, **joga-staging** and **joga-prod**. Pushing to `main`
deploys to staging; production deploys only when you run the Deploy
workflow by hand. The full first-time setup (projects, secrets, auth, email,
Stripe, RevenueCat, security checks) is in [`docs/GO_LIVE.md`](docs/GO_LIVE.md).

## Making changes

- New migration: `supabase migration new <name>`, then `supabase db reset`.
- Every new table: enable RLS, add policies, revoke direct writes if the
  functions own it, and add a test in `supabase/tests/`.
- Every new public function: `security definer`, `set search_path = ''`,
  fully qualified names, check `auth.uid()`. New functions are **not**
  executable by anonymous users unless you grant it.
- Raise errors as `raise exception 'code' using detail = 'Human sentence.'`
  and add the code to `docs/API.md`.
