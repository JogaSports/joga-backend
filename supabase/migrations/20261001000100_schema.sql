-- =============================================================================
-- Joga Sports · 01 · Schema
-- Types, reference data and tables. Business logic lives in 02_functions,
-- access rules in 03_security.
-- =============================================================================

-- Internal helpers live in `private`, which is not exposed through the API.
create schema if not exists private;

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------
create type public.sport as enum ('football', 'padel', 'badminton');
create type public.game_format as enum ('five_a_side', 'seven_a_side');
create type public.skill_level as enum ('beginner', 'intermediate', 'competitive');
create type public.game_tag as enum ('casual', 'competitive', 'mixed', 'over_30s', 'womens');
create type public.user_role as enum ('player', 'organiser', 'admin');
create type public.game_status as enum ('scheduled', 'completed', 'cancelled');
create type public.team as enum ('white', 'orange');
create type public.booking_status as enum ('confirmed', 'cancelled');
create type public.wallet_entry_type as enum ('reward', 'referral', 'booking', 'refund', 'top_up', 'adjustment');
create type public.referral_stage as enum ('joined', 'first_game', 'rewarded');
create type public.membership_status as enum ('active', 'expired');
create type public.membership_source as enum ('app_store', 'play_store', 'stripe', 'promotional');
create type public.reward_kind as enum ('games_played', 'streak_weeks', 'potm_awards');

-- -----------------------------------------------------------------------------
-- Settings (single row). Change prices and rules without a code release.
-- -----------------------------------------------------------------------------
create table public.app_settings (
  id                       boolean primary key default true check (id),
  booking_fee_pence        integer not null default 100 check (booking_fee_pence >= 0),
  hold_minutes             integer not null default 5 check (hold_minutes between 1 and 30),
  hold_grace_minutes       integer not null default 10 check (hold_grace_minutes >= 0),
  free_cancellation_hours  integer not null default 24 check (free_cancellation_hours >= 0),
  referral_reward_pence    integer not null default 200 check (referral_reward_pence >= 0),
  streak_freezes_per_month integer not null default 1 check (streak_freezes_per_month >= 0),
  timezone                 text not null default 'Europe/London',
  updated_at               timestamptz not null default now()
);
insert into public.app_settings default values;

comment on table public.app_settings is
  'Single-row settings: booking fee, hold length, cancellation window, rewards.';

-- -----------------------------------------------------------------------------
-- Places
-- -----------------------------------------------------------------------------
create table public.cities (
  id         text primary key check (id ~ '^[a-z_]+$'),
  name       text not null,
  is_live    boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.cities (id, name) values ('cardiff', 'Cardiff'), ('bristol', 'Bristol');

create table public.venues (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 2 and 80),
  city_id    text not null references public.cities (id),
  address    text not null,
  surface    text not null default '',
  parking    text not null default '',
  photo_url  text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index venues_city_idx on public.venues (city_id);

-- -----------------------------------------------------------------------------
-- People. One profile per auth user, created by a trigger on sign-up.
-- -----------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  first_name    text not null default '' check (char_length(first_name) <= 50),
  last_name     text not null default '' check (char_length(last_name) <= 50),
  city_id       text references public.cities (id),
  level         public.skill_level not null default 'intermediate',
  position      text check (char_length(position) <= 30),
  avatar_url    text,
  role          public.user_role not null default 'player',
  referral_code text not null unique,
  referred_by   uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index profiles_city_idx on public.profiles (city_id);

-- -----------------------------------------------------------------------------
-- Games
-- -----------------------------------------------------------------------------
create table public.games (
  id               uuid primary key default gen_random_uuid(),
  sport            public.sport not null default 'football',
  format           public.game_format not null,
  venue_id         uuid not null references public.venues (id),
  pitch            text not null default '',
  starts_at        timestamptz not null,
  duration_minutes integer not null default 60 check (duration_minutes between 15 and 240),
  level            public.skill_level not null,
  tags             public.game_tag[] not null default '{}',
  price_pence      integer not null check (price_pence >= 0),
  capacity         integer not null check (capacity between 2 and 30),
  venue_cost_pence integer not null default 0 check (venue_cost_pence >= 0),
  organiser_id     uuid not null references public.profiles (id),
  status           public.game_status not null default 'scheduled',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index games_upcoming_idx on public.games (starts_at) where status = 'scheduled';
create index games_venue_idx on public.games (venue_id);
create index games_organiser_idx on public.games (organiser_id);

-- -----------------------------------------------------------------------------
-- Booking
-- -----------------------------------------------------------------------------

-- A space held for a few minutes while the player pays.
create table public.space_holds (
  id         uuid primary key default gen_random_uuid(),
  game_id    uuid not null references public.games (id) on delete cascade,
  player_id  uuid not null references public.profiles (id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (game_id, player_id)
);
create index space_holds_expiry_idx on public.space_holds (expires_at);

create table public.bookings (
  id                       uuid primary key default gen_random_uuid(),
  game_id                  uuid not null references public.games (id),
  player_id                uuid not null references public.profiles (id) on delete cascade,
  status                   public.booking_status not null default 'confirmed',
  price_pence              integer not null check (price_pence >= 0),
  fee_pence                integer not null default 0 check (fee_pence >= 0),
  wallet_pence             integer not null default 0 check (wallet_pence >= 0),
  card_pence               integer not null default 0 check (card_pence >= 0),
  stripe_payment_intent_id text unique,
  -- Late cancellation: refunded to the wallet only if someone takes the space.
  refund_if_filled         boolean not null default false,
  refunded_at              timestamptz,
  created_at               timestamptz not null default now(),
  cancelled_at             timestamptz,
  constraint bookings_paid_in_full check (price_pence + fee_pence = wallet_pence + card_pence)
);
create unique index bookings_one_confirmed_idx
  on public.bookings (game_id, player_id) where status = 'confirmed';
create index bookings_player_idx on public.bookings (player_id);
create index bookings_pending_refund_idx
  on public.bookings (game_id, cancelled_at) where refund_if_filled and refunded_at is null;

create table public.waitlist (
  game_id    uuid not null references public.games (id) on delete cascade,
  player_id  uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (game_id, player_id)
);

-- -----------------------------------------------------------------------------
-- Wallet: append-only ledger. The balance is always the sum of entries.
-- -----------------------------------------------------------------------------
create table public.wallet_ledger (
  id           bigint generated always as identity primary key,
  player_id    uuid not null references public.profiles (id) on delete cascade,
  type         public.wallet_entry_type not null,
  amount_pence integer not null check (amount_pence <> 0),
  label        text not null,
  game_id      uuid references public.games (id) on delete set null,
  booking_id   uuid references public.bookings (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index wallet_ledger_player_idx on public.wallet_ledger (player_id, created_at desc);

-- -----------------------------------------------------------------------------
-- Joga+ membership, mirrored from RevenueCat.
-- -----------------------------------------------------------------------------
create table public.memberships (
  player_id          uuid primary key references public.profiles (id) on delete cascade,
  status             public.membership_status not null,
  source             public.membership_source not null,
  product_id         text,
  current_period_end timestamptz,
  updated_at         timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Matches. Filled in by the organiser in Match Control.
-- -----------------------------------------------------------------------------
create table public.match_lines (
  game_id   uuid not null references public.games (id) on delete cascade,
  player_id uuid not null references public.profiles (id) on delete cascade,
  team      public.team not null,
  attended  boolean not null default true,
  goals     integer not null default 0 check (goals between 0 and 50),
  assists   integer not null default 0 check (assists between 0 and 50),
  primary key (game_id, player_id)
);
create index match_lines_player_idx on public.match_lines (player_id);

create table public.match_results (
  game_id      uuid primary key references public.games (id) on delete cascade,
  white_score  integer not null check (white_score >= 0),
  orange_score integer not null check (orange_score >= 0),
  potm_id      uuid references public.profiles (id) on delete set null,
  submitted_by uuid references public.profiles (id) on delete set null,
  submitted_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Rewards. Rules are data, so amounts change without a code release.
-- -----------------------------------------------------------------------------
create table public.reward_rules (
  id                  text primary key,
  kind                public.reward_kind not null,
  threshold           integer not null check (threshold > 0),
  credit_pence        integer not null default 0 check (credit_pence >= 0),
  member_credit_pence integer not null default 0 check (member_credit_pence >= 0),
  label               text not null,
  is_active           boolean not null default true,
  unique (kind, threshold)
);
insert into public.reward_rules (id, kind, threshold, credit_pence, member_credit_pence, label) values
  ('games_10',   'games_played', 10,  100,  200, '10 games played'),
  ('games_25',   'games_played', 25,  250,  500, '25 games played'),
  ('games_50',   'games_played', 50,  500, 1000, '50 games played'),
  ('games_100',  'games_played', 100, 1000, 2000, '100 games played'),
  ('streak_10',  'streak_weeks', 10,  500, 1000, '10-week streak'),
  ('streak_25',  'streak_weeks', 25, 1000, 2000, '25-week streak'),
  ('potm_10',    'potm_awards',  10,    0,    0, '10 player of the match awards');

create table public.player_rewards (
  player_id    uuid not null references public.profiles (id) on delete cascade,
  rule_id      text not null references public.reward_rules (id),
  game_id      uuid references public.games (id) on delete set null,
  credit_pence integer not null default 0,
  awarded_at   timestamptz not null default now(),
  primary key (player_id, rule_id)
);

-- Joga+ perk: a week that counts towards the streak without playing.
create table public.streak_freezes (
  player_id  uuid not null references public.profiles (id) on delete cascade,
  week_start date not null,
  created_at timestamptz not null default now(),
  primary key (player_id, week_start)
);

-- -----------------------------------------------------------------------------
-- Referrals (after the test period)
-- -----------------------------------------------------------------------------
create table public.referrals (
  referred_id uuid primary key references public.profiles (id) on delete cascade,
  referrer_id uuid not null references public.profiles (id) on delete cascade,
  stage       public.referral_stage not null default 'joined',
  created_at  timestamptz not null default now(),
  rewarded_at timestamptz,
  check (referrer_id <> referred_id)
);
create index referrals_referrer_idx on public.referrals (referrer_id);
