-- =============================================================================
-- Joga Sports · 02 · Functions
--
-- Rules:
--  * Every function sets `search_path = ''` and fully qualifies names.
--  * `private.*` helpers are internal (the schema isn't exposed by the API).
--  * `public.*` functions are the app's API (called with `supabase.rpc`).
--    They are SECURITY DEFINER and check `auth.uid()` themselves.
--  * Errors are raised with a stable machine code as the message
--    (e.g. 'game_full') and a human sentence in DETAIL, so the app can map
--    codes to copy.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Generic triggers
-- -----------------------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger set_updated_at before update on public.profiles
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.venues
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.games
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.app_settings
  for each row execute function private.set_updated_at();

-- Default a game's capacity from its format.
create or replace function private.set_game_defaults()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.capacity is null then
    new.capacity := case new.format
      when 'five_a_side' then 10
      when 'seven_a_side' then 14
    end;
  end if;
  return new;
end;
$$;

create trigger set_game_defaults before insert on public.games
  for each row execute function private.set_game_defaults();

-- The wallet ledger is append-only.
create or replace function private.forbid_ledger_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'wallet_ledger_is_append_only'
    using detail = 'Wallet entries cannot be changed. Add a correcting entry instead.';
end;
$$;

create trigger forbid_ledger_update before update on public.wallet_ledger
  for each row execute function private.forbid_ledger_update();

-- -----------------------------------------------------------------------------
-- Small helpers
-- -----------------------------------------------------------------------------
create or replace function private.settings()
returns public.app_settings
language sql
stable
set search_path = ''
as $$
  select * from public.app_settings where id;
$$;

-- Monday of the week containing `ts`, in the app's timezone.
create or replace function private.week_start(ts timestamptz)
returns date
language sql
stable
set search_path = ''
as $$
  select date_trunc('week', ts at time zone (select timezone from public.app_settings where id))::date;
$$;

create or replace function private.is_member(p_player uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships m
    where m.player_id = p_player
      and m.status = 'active'
      and (m.current_period_end is null or m.current_period_end > now())
  );
$$;

create or replace function private.wallet_balance(p_player uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(amount_pence), 0)::integer
  from public.wallet_ledger
  where player_id = p_player;
$$;

-- Confirmed bookings plus live holds, excluding one player's own hold.
create or replace function private.taken_spaces(p_game uuid, p_excluding_player uuid default null)
returns integer
language sql
stable
set search_path = ''
as $$
  select (
    (select count(*) from public.bookings
      where game_id = p_game and status = 'confirmed')
    +
    (select count(*) from public.space_holds
      where game_id = p_game
        and expires_at > now()
        and player_id is distinct from p_excluding_player)
  )::integer;
$$;

create or replace function private.require_user()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not_authenticated'
      using errcode = '28000', detail = 'Sign in to continue.';
  end if;
  return v_user;
end;
$$;

create or replace function private.new_referral_code(p_name text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_base text := upper(left(regexp_replace(coalesce(p_name, ''), '[^A-Za-z]', '', 'g'), 6));
  v_code text;
begin
  if v_base = '' then
    v_base := 'JOGA';
  end if;
  loop
    v_code := v_base || lpad(floor(random() * 100)::integer::text, 2, '0');
    exit when not exists (select 1 from public.profiles where referral_code = v_code);
    v_base := v_base || chr(65 + floor(random() * 26)::integer);
  end loop;
  return v_code;
end;
$$;

-- -----------------------------------------------------------------------------
-- Sign-up: create a profile, handle a referral code.
-- -----------------------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta     jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_full     text := coalesce(v_meta ->> 'full_name', v_meta ->> 'name', '');
  v_first    text := coalesce(nullif(v_meta ->> 'first_name', ''), split_part(v_full, ' ', 1), '');
  v_last     text := coalesce(
                       nullif(v_meta ->> 'last_name', ''),
                       nullif(trim(substr(v_full, char_length(split_part(v_full, ' ', 1)) + 1)), ''),
                       '');
  v_city     text := (select id from public.cities where id = v_meta ->> 'city_id');
  v_referrer uuid;
begin
  insert into public.profiles (id, first_name, last_name, city_id, referral_code)
  values (
    new.id,
    left(v_first, 50),
    left(v_last, 50),
    v_city,
    private.new_referral_code(coalesce(nullif(v_first, ''), split_part(new.email, '@', 1)))
  );

  if nullif(v_meta ->> 'referral_code', '') is not null then
    select id into v_referrer
    from public.profiles
    where referral_code = upper(v_meta ->> 'referral_code')
      and id <> new.id;

    if v_referrer is not null then
      update public.profiles set referred_by = v_referrer where id = new.id;
      insert into public.referrals (referred_id, referrer_id) values (new.id, v_referrer);
      insert into public.wallet_ledger (player_id, type, amount_pence, label)
      values (new.id, 'referral', (private.settings()).referral_reward_pence, 'Welcome credit · referral');
    end if;
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- -----------------------------------------------------------------------------
-- Pricing
-- -----------------------------------------------------------------------------
create type public.booking_quote as (
  game_pence             integer,
  fee_pence              integer,
  subtotal_pence         integer,
  wallet_available_pence integer,
  wallet_applied_pence   integer,
  total_pence            integer,
  is_member              boolean
);

create or replace function private.quote(p_player uuid, p_game uuid, p_use_wallet boolean)
returns public.booking_quote
language plpgsql
stable
set search_path = ''
as $$
declare
  q       public.booking_quote;
  v_price integer;
begin
  select price_pence into v_price from public.games where id = p_game;
  if not found then
    raise exception 'game_not_found' using errcode = 'P0002', detail = 'This game no longer exists.';
  end if;

  q.is_member := private.is_member(p_player);
  q.game_pence := v_price;
  q.fee_pence := case when q.is_member then 0 else (private.settings()).booking_fee_pence end;
  q.subtotal_pence := q.game_pence + q.fee_pence;
  q.wallet_available_pence := greatest(private.wallet_balance(p_player), 0);
  q.wallet_applied_pence := case
    when p_use_wallet then least(q.wallet_available_pence, q.subtotal_pence)
    else 0
  end;
  q.total_pence := q.subtotal_pence - q.wallet_applied_pence;
  return q;
end;
$$;

-- -----------------------------------------------------------------------------
-- Booking internals
-- -----------------------------------------------------------------------------
create or replace function private.refund_to_wallet(p_booking public.bookings, p_label text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  -- The game price is refunded. The booking fee is not.
  if p_booking.price_pence > 0 then
    insert into public.wallet_ledger (player_id, type, amount_pence, label, game_id, booking_id)
    values (p_booking.player_id, 'refund', p_booking.price_pence, p_label, p_booking.game_id, p_booking.id);
  end if;
  update public.bookings set refunded_at = now() where id = p_booking.id;
end;
$$;

create or replace function private.confirm_booking(
  p_hold           uuid,
  p_player         uuid,
  p_wallet_pence   integer,
  p_card_pence     integer,
  p_payment_intent text
)
returns public.bookings
language plpgsql
set search_path = ''
as $$
declare
  v_hold    public.space_holds;
  v_game    public.games;
  v_venue   text;
  v_fee     integer;
  v_booking public.bookings;
  v_pending public.bookings;
begin
  select * into v_hold
  from public.space_holds
  where id = p_hold and player_id = p_player
  for update;
  if not found then
    raise exception 'hold_not_found' using errcode = 'P0002',
      detail = 'Your hold on this space has ended. Please try again.';
  end if;

  -- Lock the game so concurrent bookings are serialised.
  select * into v_game from public.games where id = v_hold.game_id for update;
  if v_game.status <> 'scheduled' or v_game.starts_at <= now() then
    raise exception 'game_not_bookable' using detail = 'This game can no longer be booked.';
  end if;

  -- A lapsed hold is still honoured if there's room.
  if v_hold.expires_at <= now()
     and private.taken_spaces(v_game.id, p_player) >= v_game.capacity then
    raise exception 'game_full' using detail = 'Sorry, the last space has just gone.';
  end if;

  if exists (select 1 from public.bookings
             where game_id = v_game.id and player_id = p_player and status = 'confirmed') then
    raise exception 'already_booked' using detail = 'You are already booked on this game.';
  end if;

  v_fee := case when private.is_member(p_player) then 0 else (private.settings()).booking_fee_pence end;

  if p_wallet_pence < 0 or p_card_pence < 0
     or p_wallet_pence + p_card_pence <> v_game.price_pence + v_fee then
    raise exception 'amount_mismatch' using detail = 'The price changed. Please try again.';
  end if;

  if p_wallet_pence > private.wallet_balance(p_player) then
    raise exception 'insufficient_wallet' using detail = 'Not enough wallet credit.';
  end if;

  insert into public.bookings (
    game_id, player_id, price_pence, fee_pence, wallet_pence, card_pence, stripe_payment_intent_id
  )
  values (v_game.id, p_player, v_game.price_pence, v_fee, p_wallet_pence, p_card_pence, p_payment_intent)
  returning * into v_booking;

  select name into v_venue from public.venues where id = v_game.venue_id;

  if p_wallet_pence > 0 then
    insert into public.wallet_ledger (player_id, type, amount_pence, label, game_id, booking_id)
    values (p_player, 'booking', -p_wallet_pence, 'Game booking · ' || v_venue, v_game.id, v_booking.id);
  end if;

  delete from public.space_holds where id = v_hold.id;
  delete from public.waitlist where game_id = v_game.id and player_id = p_player;

  -- The space someone gave up late has now been filled: refund them.
  select * into v_pending
  from public.bookings
  where game_id = v_game.id
    and status = 'cancelled'
    and refund_if_filled
    and refunded_at is null
  order by cancelled_at
  limit 1
  for update skip locked;
  if found then
    perform private.refund_to_wallet(v_pending, 'Refund · space filled at ' || v_venue);
  end if;

  return v_booking;
end;
$$;

-- -----------------------------------------------------------------------------
-- Stats and streaks
-- -----------------------------------------------------------------------------
create or replace function private.period_start(p_period text)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tz    text := (private.settings()).timezone;
  v_local timestamp := now() at time zone v_tz;
begin
  return case p_period
    when 'career' then null
    -- Football season runs from 1 August.
    when 'season' then make_timestamptz(
      case when extract(month from v_local) >= 8 then extract(year from v_local)::integer
           else extract(year from v_local)::integer - 1 end,
      8, 1, 0, 0, 0, v_tz)
    when 'month' then date_trunc('month', v_local) at time zone v_tz
    else null
  end;
end;
$$;

create or replace function private.player_totals(p_player uuid, p_from timestamptz default null)
returns table (games integer, goals integer, assists integer, potm integer, wins integer)
language sql
stable
set search_path = ''
as $$
  select
    count(*)::integer,
    coalesce(sum(ml.goals), 0)::integer,
    coalesce(sum(ml.assists), 0)::integer,
    count(*) filter (where mr.potm_id = ml.player_id)::integer,
    count(*) filter (
      where (ml.team = 'white' and mr.white_score > mr.orange_score)
         or (ml.team = 'orange' and mr.orange_score > mr.white_score)
    )::integer
  from public.match_lines ml
  join public.match_results mr on mr.game_id = ml.game_id
  join public.games g on g.id = ml.game_id
  where ml.player_id = p_player
    and ml.attended
    and (p_from is null or g.starts_at >= p_from);
$$;

-- Weekly streak: at least one game each week (Monday–Sunday).
create or replace function private.streak(p_player uuid)
returns table (current_weeks integer, best_weeks integer, played_this_week boolean, last_12 boolean[])
language plpgsql
stable
set search_path = ''
as $$
declare
  v_this   date := private.week_start(now());
  v_played date[];
  v_weeks  date[];
  v_anchor date;
begin
  select coalesce(array_agg(distinct private.week_start(g.starts_at)), '{}')
  into v_played
  from public.match_lines ml
  join public.games g on g.id = ml.game_id
  where ml.player_id = p_player and ml.attended;

  select coalesce(array_agg(w order by w), '{}')
  into v_weeks
  from (
    select unnest(v_played) as w
    union
    select sf.week_start from public.streak_freezes sf where sf.player_id = p_player
  ) s;

  played_this_week := v_this = any (v_played);

  -- Count back from this week (or last week, if this week isn't played yet).
  current_weeks := 0;
  v_anchor := case when v_this = any (v_weeks) then v_this else v_this - 7 end;
  while v_anchor = any (v_weeks) loop
    current_weeks := current_weeks + 1;
    v_anchor := v_anchor - 7;
  end loop;

  -- Longest run of consecutive weeks.
  select coalesce(max(run), 0)
  into best_weeks
  from (
    select count(*)::integer as run
    from (
      select w, w - (row_number() over (order by w))::integer * 7 as grp
      from unnest(v_weeks) as w
    ) x
    group by grp
  ) y;

  select array_agg((v_this - i * 7) = any (v_weeks) order by i desc)
  into last_12
  from generate_series(0, 11) as i;

  return next;
end;
$$;

create or replace function private.award_rewards(p_player uuid, p_game uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_member boolean := private.is_member(p_player);
  v_totals record;
  v_streak integer;
  v_rule   public.reward_rules;
  v_credit integer;
begin
  select * into v_totals from private.player_totals(p_player, null);
  select current_weeks into v_streak from private.streak(p_player);

  for v_rule in
    select * from public.reward_rules r
    where r.is_active
      and (
        (r.kind = 'games_played' and r.threshold <= v_totals.games)
        or (r.kind = 'streak_weeks' and r.threshold <= v_streak)
        or (r.kind = 'potm_awards' and r.threshold <= v_totals.potm)
      )
  loop
    v_credit := case when v_member then v_rule.member_credit_pence else v_rule.credit_pence end;

    insert into public.player_rewards (player_id, rule_id, game_id, credit_pence)
    values (p_player, v_rule.id, p_game, v_credit)
    on conflict (player_id, rule_id) do nothing;

    if found and v_credit > 0 then
      insert into public.wallet_ledger (player_id, type, amount_pence, label, game_id)
      values (p_player, 'reward', v_credit, v_rule.label, p_game);
    end if;
  end loop;
end;
$$;

-- A referred player's first game pays the referrer.
create or replace function private.progress_referral(p_player uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_ref  public.referrals;
  v_name text;
begin
  select * into v_ref
  from public.referrals
  where referred_id = p_player and stage <> 'rewarded'
  for update;
  if not found then
    return;
  end if;

  select first_name into v_name from public.profiles where id = p_player;

  update public.referrals
  set stage = 'rewarded', rewarded_at = now()
  where referred_id = p_player;

  insert into public.wallet_ledger (player_id, type, amount_pence, label)
  values (v_ref.referrer_id, 'referral', (private.settings()).referral_reward_pence,
          'Referral · ' || coalesce(nullif(v_name, ''), 'a friend'));
end;
$$;

-- =============================================================================
-- Public API
-- =============================================================================

-- Is the signed-in user an admin? Used by security policies.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin'
  );
$$;

-- Is the signed-in user a Joga+ member?
create or replace function public.is_member()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_member((select auth.uid()));
$$;

-- Spaces taken on a game (confirmed bookings plus live holds).
create or replace function public.booked_count(p_game uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select private.taken_spaces(p_game, null);
$$;

-- Players booked on a game, with public profile fields only.
create or replace function public.game_players(p_game uuid)
returns table (player_id uuid, first_name text, last_initial text, avatar_url text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.first_name, left(p.last_name, 1), p.avatar_url
  from public.bookings b
  join public.profiles p on p.id = b.player_id
  where b.game_id = p_game and b.status = 'confirmed'
  order by b.created_at;
$$;

-- ---- Booking ----------------------------------------------------------------

create or replace function public.booking_quote(p_game uuid, p_use_wallet boolean default true)
returns public.booking_quote
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return private.quote(private.require_user(), p_game, p_use_wallet);
end;
$$;

-- Step 1 of booking: hold a space while the player pays.
create or replace function public.hold_space(p_game uuid)
returns public.space_holds
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player uuid := private.require_user();
  v_game   public.games;
  v_hold   public.space_holds;
begin
  select * into v_game from public.games where id = p_game for update;
  if not found then
    raise exception 'game_not_found' using errcode = 'P0002', detail = 'This game no longer exists.';
  end if;
  if v_game.status <> 'scheduled' or v_game.starts_at <= now() then
    raise exception 'game_not_bookable' using detail = 'This game can no longer be booked.';
  end if;
  if exists (select 1 from public.bookings
             where game_id = p_game and player_id = v_player and status = 'confirmed') then
    raise exception 'already_booked' using detail = 'You are already booked on this game.';
  end if;
  if private.taken_spaces(p_game, v_player) >= v_game.capacity then
    raise exception 'game_full' using detail = 'This game is full. Join the waitlist instead.';
  end if;

  insert into public.space_holds (game_id, player_id, expires_at)
  values (p_game, v_player, now() + make_interval(mins => (private.settings()).hold_minutes))
  on conflict (game_id, player_id)
    do update set expires_at = excluded.expires_at, created_at = now()
  returning * into v_hold;

  return v_hold;
end;
$$;

-- Step 2a: confirm when wallet credit (or Joga+ on a free game) covers
-- everything. Card payments go through the create-payment edge function
-- and are confirmed by the Stripe webhook instead.
create or replace function public.confirm_booking_with_wallet(p_hold uuid)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player uuid := private.require_user();
  v_game   uuid;
  q        public.booking_quote;
begin
  select game_id into v_game from public.space_holds where id = p_hold and player_id = v_player;
  if not found then
    raise exception 'hold_not_found' using errcode = 'P0002',
      detail = 'Your hold on this space has ended. Please try again.';
  end if;

  q := private.quote(v_player, v_game, true);
  if q.total_pence > 0 then
    raise exception 'payment_required' using detail = 'Card payment needed for the remaining amount.';
  end if;

  return private.confirm_booking(p_hold, v_player, q.wallet_applied_pence, 0, null);
end;
$$;

-- Step 2b: confirm after Stripe has taken payment. Server only (secret key).
-- Idempotent: a repeated webhook returns the existing booking.
create or replace function public.confirm_paid_booking(
  p_hold           uuid,
  p_player         uuid,
  p_wallet_pence   integer,
  p_card_pence     integer,
  p_payment_intent text
)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.bookings;
begin
  select * into v_existing from public.bookings where stripe_payment_intent_id = p_payment_intent;
  if found then
    return v_existing;
  end if;
  return private.confirm_booking(p_hold, p_player, p_wallet_pence, p_card_pence, p_payment_intent);
end;
$$;

-- Cancel. Inside the free window the game price goes back to the wallet;
-- after it, the player is refunded only if someone takes the space.
-- Returns 'refunded' or 'refund_if_filled'.
create or replace function public.cancel_booking(p_game uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player  uuid := private.require_user();
  v_booking public.bookings;
  v_game    public.games;
  v_venue   text;
begin
  select * into v_game from public.games where id = p_game for update;
  if not found then
    raise exception 'game_not_found' using errcode = 'P0002', detail = 'This game no longer exists.';
  end if;

  select * into v_booking
  from public.bookings
  where game_id = p_game and player_id = v_player and status = 'confirmed'
  for update;
  if not found then
    raise exception 'booking_not_found' using errcode = 'P0002', detail = 'You are not booked on this game.';
  end if;

  if v_game.starts_at <= now() then
    raise exception 'game_started' using detail = 'This game has already kicked off.';
  end if;

  select name into v_venue from public.venues where id = v_game.venue_id;

  if v_game.starts_at - now() >= make_interval(hours => (private.settings()).free_cancellation_hours) then
    update public.bookings
    set status = 'cancelled', cancelled_at = now()
    where id = v_booking.id
    returning * into v_booking;
    perform private.refund_to_wallet(v_booking, 'Refund · ' || v_venue);
    return 'refunded';
  end if;

  update public.bookings
  set status = 'cancelled', cancelled_at = now(), refund_if_filled = true
  where id = v_booking.id;
  return 'refund_if_filled';
end;
$$;

create or replace function public.join_waitlist(p_game uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player uuid := private.require_user();
begin
  if not exists (select 1 from public.games where id = p_game and status = 'scheduled') then
    raise exception 'game_not_found' using errcode = 'P0002', detail = 'This game no longer exists.';
  end if;
  insert into public.waitlist (game_id, player_id) values (p_game, v_player)
  on conflict do nothing;
end;
$$;

create or replace function public.leave_waitlist(p_game uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.waitlist where game_id = p_game and player_id = private.require_user();
$$;

-- ---- Match control ----------------------------------------------------------

-- Organiser (or admin) submits the match sheet. Updates stats, streaks,
-- rewards and referrals in one transaction. Can be resubmitted to correct.
--
-- p_lines: [{"player_id": uuid, "team": "white"|"orange",
--            "attended": bool, "goals": int, "assists": int}, ...]
create or replace function public.submit_match(p_game uuid, p_lines jsonb, p_potm uuid default null)
returns public.match_results
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := private.require_user();
  v_game   public.games;
  v_result public.match_results;
  v_player uuid;
begin
  select * into v_game from public.games where id = p_game for update;
  if not found then
    raise exception 'game_not_found' using errcode = 'P0002', detail = 'This game no longer exists.';
  end if;
  if v_game.organiser_id <> v_caller and not public.is_admin() then
    raise exception 'not_organiser' using errcode = '42501',
      detail = 'Only the organiser can submit this result.';
  end if;
  if v_game.status = 'cancelled' then
    raise exception 'game_cancelled' using detail = 'This game was cancelled.';
  end if;
  if v_game.starts_at > now() then
    raise exception 'game_not_started' using detail = 'Results can be submitted after kick-off.';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'invalid_lines' using detail = 'Match lines must be a list.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) as l (player_id uuid)
    where not exists (
      select 1 from public.bookings b
      where b.game_id = p_game and b.player_id = l.player_id and b.status = 'confirmed'
    )
  ) then
    raise exception 'player_not_booked' using detail = 'Every player must be booked on this game.';
  end if;

  delete from public.match_lines where game_id = p_game;
  insert into public.match_lines (game_id, player_id, team, attended, goals, assists)
  select p_game, l.player_id, l.team, coalesce(l.attended, true),
         coalesce(l.goals, 0), coalesce(l.assists, 0)
  from jsonb_to_recordset(p_lines)
    as l (player_id uuid, team public.team, attended boolean, goals integer, assists integer);

  if p_potm is not null and not exists (
    select 1 from public.match_lines where game_id = p_game and player_id = p_potm and attended
  ) then
    raise exception 'potm_not_in_game' using detail = 'Player of the match must have played.';
  end if;

  insert into public.match_results (game_id, white_score, orange_score, potm_id, submitted_by)
  select p_game,
         coalesce(sum(goals) filter (where team = 'white' and attended), 0),
         coalesce(sum(goals) filter (where team = 'orange' and attended), 0),
         p_potm,
         v_caller
  from public.match_lines
  where game_id = p_game
  on conflict (game_id) do update
    set white_score = excluded.white_score,
        orange_score = excluded.orange_score,
        potm_id = excluded.potm_id,
        submitted_by = excluded.submitted_by,
        submitted_at = now()
  returning * into v_result;

  update public.games set status = 'completed' where id = p_game;

  for v_player in
    select player_id from public.match_lines where game_id = p_game and attended
  loop
    perform private.award_rewards(v_player, p_game);
    perform private.progress_referral(v_player);
  end loop;

  return v_result;
end;
$$;

-- ---- Player -----------------------------------------------------------------

-- Totals for any player. p_period: 'career' | 'season' | 'month'.
create or replace function public.player_stats(p_player uuid, p_period text default 'career')
returns table (games integer, goals integer, assists integer, potm integer, wins integer)
language sql
stable
security definer
set search_path = ''
as $$
  select * from private.player_totals(p_player, private.period_start(p_period));
$$;

-- The signed-in player's last N games for the form chart, oldest first.
create or replace function public.my_form(p_limit integer default 10)
returns table (game_id uuid, starts_at timestamptz, goals integer, assists integer, won boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select * from (
    select g.id, g.starts_at, ml.goals, ml.assists,
           (ml.team = 'white' and mr.white_score > mr.orange_score)
             or (ml.team = 'orange' and mr.orange_score > mr.white_score)
    from public.match_lines ml
    join public.match_results mr on mr.game_id = ml.game_id
    join public.games g on g.id = ml.game_id
    where ml.player_id = (select auth.uid()) and ml.attended
    order by g.starts_at desc
    limit least(greatest(p_limit, 1), 50)
  ) recent
  order by starts_at;
$$;

create or replace function public.my_streak()
returns table (
  current_weeks     integer,
  best_weeks        integer,
  played_this_week  boolean,
  last_12           boolean[],
  week_ends_at      timestamptz,
  freezes_left      integer,
  next_reward_weeks integer,
  next_reward_pence integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_player uuid := private.require_user();
  v_tz     text := (private.settings()).timezone;
  v_member boolean := private.is_member(v_player);
  v_used   integer;
begin
  select s.current_weeks, s.best_weeks, s.played_this_week, s.last_12
  into current_weeks, best_weeks, played_this_week, last_12
  from private.streak(v_player) s;

  -- Sunday 23:59:59 local time.
  week_ends_at := ((private.week_start(now()) + 7)::timestamp at time zone v_tz) - interval '1 second';

  select count(*) into v_used
  from public.streak_freezes
  where player_id = v_player
    and date_trunc('month', created_at at time zone v_tz) = date_trunc('month', now() at time zone v_tz);
  freezes_left := case when v_member then greatest((private.settings()).streak_freezes_per_month - v_used, 0) else 0 end;

  select r.threshold, case when v_member then r.member_credit_pence else r.credit_pence end
  into next_reward_weeks, next_reward_pence
  from public.reward_rules r
  where r.kind = 'streak_weeks' and r.is_active and r.threshold > current_weeks
  order by r.threshold
  limit 1;

  return next;
end;
$$;

-- Joga+ perk: protect this week's streak without playing.
create or replace function public.use_streak_freeze()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player uuid := private.require_user();
  v_left   integer;
begin
  if not private.is_member(v_player) then
    raise exception 'members_only' using errcode = '42501', detail = 'Streak freezes are a Joga+ perk.';
  end if;
  select freezes_left into v_left from public.my_streak();
  if v_left <= 0 then
    raise exception 'no_freezes_left' using detail = 'You have used this month''s streak freeze.';
  end if;
  insert into public.streak_freezes (player_id, week_start)
  values (v_player, private.week_start(now()))
  on conflict do nothing;
end;
$$;

-- Joga+ only: deeper stats for the signed-in player.
create or replace function public.my_member_stats()
returns table (city_rank integer, best_venue text, involvements_per_game numeric, potm_rate_percent integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_player uuid := private.require_user();
  v_city   text;
  v_totals record;
begin
  if not private.is_member(v_player) then
    raise exception 'members_only' using errcode = '42501', detail = 'Deeper stats are a Joga+ perk.';
  end if;

  select city_id into v_city from public.profiles where id = v_player;
  select * into v_totals from private.player_totals(v_player, null);

  select l.rank into city_rank
  from public.leaderboard(coalesce(v_city, 'cardiff'), 'goals') l
  where l.player_id = v_player;

  select v.name into best_venue
  from public.match_lines ml
  join public.games g on g.id = ml.game_id
  join public.venues v on v.id = g.venue_id
  where ml.player_id = v_player and ml.attended
  group by v.name
  order by sum(ml.goals + ml.assists) desc, count(*) desc
  limit 1;

  involvements_per_game := case when v_totals.games = 0 then 0
    else round((v_totals.goals + v_totals.assists)::numeric / v_totals.games, 2) end;
  potm_rate_percent := case when v_totals.games = 0 then 0
    else round(v_totals.potm * 100.0 / v_totals.games)::integer end;

  return next;
end;
$$;

-- Apple requires in-app account deletion. Organisers with games must hand
-- them over first.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player uuid := private.require_user();
begin
  if exists (select 1 from public.games where organiser_id = v_player) then
    raise exception 'organiser_has_games' using detail = 'Hand your games to another organiser first.';
  end if;
  if exists (select 1 from public.bookings b join public.games g on g.id = b.game_id
             where b.player_id = v_player and b.status = 'confirmed' and g.starts_at > now()) then
    raise exception 'has_upcoming_bookings' using detail = 'Cancel your upcoming games first.';
  end if;
  delete from auth.users where id = v_player;
end;
$$;

-- ---- Leaderboards (after test) ------------------------------------------------

-- Monthly city table. p_metric: 'goals' | 'assists' | 'potm' | 'streak'.
create or replace function public.leaderboard(
  p_city   text,
  p_metric text,
  p_month  date default null,
  p_limit  integer default 50
)
returns table (rank integer, player_id uuid, first_name text, last_initial text, value integer, is_me boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz    text := (private.settings()).timezone;
  v_month date := date_trunc('month', coalesce(p_month, (now() at time zone v_tz)::date))::date;
  v_from  timestamptz := v_month::timestamp at time zone v_tz;
  v_to    timestamptz := (v_month + interval '1 month')::timestamp at time zone v_tz;
begin
  if p_metric not in ('goals', 'assists', 'potm', 'streak') then
    raise exception 'invalid_metric' using detail = 'Choose goals, assists, potm or streak.';
  end if;

  return query
  with players as (
    select ml.player_id,
           sum(ml.goals)::integer as goals,
           sum(ml.assists)::integer as assists,
           (count(*) filter (where mr.potm_id = ml.player_id))::integer as potm
    from public.match_lines ml
    join public.match_results mr on mr.game_id = ml.game_id
    join public.games g on g.id = ml.game_id
    join public.venues v on v.id = g.venue_id
    where ml.attended and v.city_id = p_city and g.starts_at >= v_from and g.starts_at < v_to
    group by ml.player_id
  ),
  scored as (
    select pl.player_id,
           case p_metric
             when 'goals' then pl.goals
             when 'assists' then pl.assists
             when 'potm' then pl.potm
             else (select s.current_weeks from private.streak(pl.player_id) s)
           end as value
    from players pl
  )
  select (rank() over (order by s.value desc))::integer,
         s.player_id,
         p.first_name,
         left(p.last_name, 1),
         s.value,
         s.player_id = (select auth.uid())
  from scored s
  join public.profiles p on p.id = s.player_id
  where s.value > 0
  order by s.value desc, p.first_name
  limit least(greatest(p_limit, 1), 100);
end;
$$;

-- ---- Admin ------------------------------------------------------------------

create or replace function public.admin_games(p_from timestamptz default null, p_to timestamptz default null)
returns table (
  game_id            uuid,
  starts_at          timestamptz,
  venue_name         text,
  city_id            text,
  format             public.game_format,
  booked             integer,
  capacity           integer,
  revenue_pence      integer,
  venue_cost_pence   integer,
  margin_pence       integer,
  status             public.game_status,
  result_outstanding boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admins_only' using errcode = '42501', detail = 'Admins only.';
  end if;

  return query
  select g.id, g.starts_at, v.name, v.city_id, g.format,
         private.taken_spaces(g.id, null),
         g.capacity,
         coalesce(rev.revenue, 0)::integer,
         g.venue_cost_pence,
         (coalesce(rev.revenue, 0) - g.venue_cost_pence)::integer,
         g.status,
         (g.status = 'scheduled'
           and g.starts_at + make_interval(mins => g.duration_minutes) < now()
           and not exists (select 1 from public.match_results r where r.game_id = g.id))
  from public.games g
  join public.venues v on v.id = g.venue_id
  left join lateral (
    select sum(b.price_pence + b.fee_pence) as revenue
    from public.bookings b
    where b.game_id = g.id and b.status = 'confirmed'
  ) rev on true
  where g.starts_at >= coalesce(p_from, now() - interval '1 day')
    and g.starts_at < coalesce(p_to, now() + interval '7 days')
  order by g.starts_at;
end;
$$;

-- ---- Housekeeping (run by pg_cron) ----------------------------------------

-- Remove holds that lapsed longer ago than the grace period (which covers
-- card payments still being confirmed by Stripe).
create or replace function private.release_expired_holds()
returns integer
language sql
set search_path = ''
as $$
  with gone as (
    delete from public.space_holds
    where expires_at < now() - make_interval(mins => (private.settings()).hold_grace_minutes)
    returning 1
  )
  select count(*)::integer from gone;
$$;
