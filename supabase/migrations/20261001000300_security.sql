-- =============================================================================
-- Joga Sports · 03 · Security
--
-- Row-level security on every table. The app reads through RLS; all writes
-- that involve money, spaces or stats go through the functions in 02, never
-- straight to the tables.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Lock down the private schema and internal functions
-- -----------------------------------------------------------------------------
revoke all on schema private from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;

-- Public API functions: signed-in users only (not anon).
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;

-- Same for functions added by future migrations. (Supabase grants execute to
-- anon by default; new functions should opt in explicitly if anon needs them.)
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;

-- Payment confirmation is server-only (called by the Stripe webhook with the
-- secret key).
revoke execute on function public.confirm_paid_booking(uuid, uuid, integer, integer, text)
  from authenticated;

-- -----------------------------------------------------------------------------
-- Enable RLS everywhere
-- -----------------------------------------------------------------------------
alter table public.app_settings   enable row level security;
alter table public.cities         enable row level security;
alter table public.venues         enable row level security;
alter table public.profiles       enable row level security;
alter table public.games          enable row level security;
alter table public.space_holds    enable row level security;
alter table public.bookings       enable row level security;
alter table public.waitlist       enable row level security;
alter table public.wallet_ledger  enable row level security;
alter table public.memberships    enable row level security;
alter table public.match_lines    enable row level security;
alter table public.match_results  enable row level security;
alter table public.reward_rules   enable row level security;
alter table public.player_rewards enable row level security;
alter table public.streak_freezes enable row level security;
alter table public.referrals      enable row level security;

-- -----------------------------------------------------------------------------
-- Reference data: readable by everyone signed in, managed by admins
-- -----------------------------------------------------------------------------
create policy "Anyone signed in can read settings" on public.app_settings
  for select to authenticated using (true);
create policy "Admins manage settings" on public.app_settings
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Anyone can read cities" on public.cities
  for select to anon, authenticated using (true);
create policy "Admins manage cities" on public.cities
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Anyone can read venues" on public.venues
  for select to anon, authenticated using (true);
create policy "Admins manage venues" on public.venues
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Anyone can read games" on public.games
  for select to anon, authenticated using (true);
create policy "Admins manage games" on public.games
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Anyone signed in can read reward rules" on public.reward_rules
  for select to authenticated using (true);
create policy "Admins manage reward rules" on public.reward_rules
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- Profiles: public within the app; players edit their own safe fields only
-- -----------------------------------------------------------------------------
create policy "Signed-in users can read profiles" on public.profiles
  for select to authenticated using (true);
create policy "Players update their own profile" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));
create policy "Admins update any profile" on public.profiles
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Column-level: players can't change their role, referral code or referrer.
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (first_name, last_name, city_id, level, position, avatar_url)
  on public.profiles to authenticated;

-- -----------------------------------------------------------------------------
-- Player-owned data: read your own; writes only through functions
-- -----------------------------------------------------------------------------
create policy "Players read their own holds" on public.space_holds
  for select to authenticated using (player_id = (select auth.uid()));

create policy "Players read their own bookings" on public.bookings
  for select to authenticated using (player_id = (select auth.uid()));
create policy "Organisers read bookings for their games" on public.bookings
  for select to authenticated using (
    exists (select 1 from public.games g
            where g.id = bookings.game_id and g.organiser_id = (select auth.uid()))
  );
create policy "Admins read all bookings" on public.bookings
  for select to authenticated using (public.is_admin());

create policy "Players read their own waitlist entries" on public.waitlist
  for select to authenticated using (player_id = (select auth.uid()));
create policy "Admins read the waitlist" on public.waitlist
  for select to authenticated using (public.is_admin());

create policy "Players read their own wallet" on public.wallet_ledger
  for select to authenticated using (player_id = (select auth.uid()));
create policy "Admins read all wallets" on public.wallet_ledger
  for select to authenticated using (public.is_admin());

create policy "Players read their own membership" on public.memberships
  for select to authenticated using (player_id = (select auth.uid()));
create policy "Admins read memberships" on public.memberships
  for select to authenticated using (public.is_admin());

create policy "Players read their own rewards" on public.player_rewards
  for select to authenticated using (player_id = (select auth.uid()));

create policy "Players read their own streak freezes" on public.streak_freezes
  for select to authenticated using (player_id = (select auth.uid()));

create policy "Players read referrals they're part of" on public.referrals
  for select to authenticated using (
    referrer_id = (select auth.uid()) or referred_id = (select auth.uid())
  );

-- -----------------------------------------------------------------------------
-- Match data is social: everyone signed in can read results and stat lines
-- -----------------------------------------------------------------------------
create policy "Signed-in users can read match lines" on public.match_lines
  for select to authenticated using (true);
create policy "Signed-in users can read match results" on public.match_results
  for select to authenticated using (true);

-- -----------------------------------------------------------------------------
-- Belt and braces: no direct writes to function-managed tables
-- -----------------------------------------------------------------------------
revoke insert, update, delete on
  public.space_holds, public.bookings, public.waitlist, public.wallet_ledger,
  public.memberships, public.match_lines, public.match_results,
  public.player_rewards, public.streak_freezes, public.referrals
from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Views the app reads (they run with the caller's permissions)
-- -----------------------------------------------------------------------------
create view public.game_listing
with (security_invoker = true)
as
select
  g.id,
  g.sport,
  g.format,
  g.venue_id,
  v.name                                    as venue_name,
  v.city_id,
  c.name                                    as city_name,
  v.address,
  v.surface,
  v.parking,
  v.photo_url,
  g.pitch,
  g.starts_at,
  g.duration_minutes,
  g.level,
  g.tags,
  g.price_pence,
  g.capacity,
  public.booked_count(g.id)                 as booked,
  g.capacity - public.booked_count(g.id)    as spaces_left,
  g.organiser_id,
  o.first_name                              as organiser_first_name,
  left(o.last_name, 1)                      as organiser_last_initial,
  (select count(*) from public.games og
    where og.organiser_id = g.organiser_id and og.status = 'completed')::integer
                                            as organiser_games_run,
  g.status
from public.games g
join public.venues v on v.id = g.venue_id
join public.cities c on c.id = v.city_id
join public.profiles o on o.id = g.organiser_id;

comment on view public.game_listing is
  'Games with venue, organiser and live spaces. Filter with PostgREST, '
  'e.g. city_id=eq.cardiff&status=eq.scheduled.';

-- Recommended games for the signed-in player ("For you" on Home).
create or replace function public.recommended_games(p_limit integer default 3)
returns setof public.game_listing
language sql
stable
security invoker
set search_path = ''
as $$
  select gl.*
  from public.game_listing gl
  join public.profiles me on me.id = (select auth.uid())
  where gl.status = 'scheduled'
    and gl.starts_at > now()
    and gl.spaces_left > 0
    and gl.city_id = coalesce(me.city_id, gl.city_id)
    and (gl.level = me.level or 'casual' = any (gl.tags))
    and not exists (
      select 1 from public.bookings b
      where b.game_id = gl.id and b.player_id = me.id and b.status = 'confirmed'
    )
  order by gl.starts_at
  limit least(greatest(p_limit, 1), 20);
$$;

-- The signed-in player's upcoming games (still to be played or scored).
create or replace function public.my_upcoming_games()
returns setof public.game_listing
language sql
stable
security invoker
set search_path = ''
as $$
  select gl.*
  from public.game_listing gl
  join public.bookings b
    on b.game_id = gl.id and b.player_id = (select auth.uid()) and b.status = 'confirmed'
  where gl.status = 'scheduled'
    and gl.starts_at > now() - interval '3 hours'
  order by gl.starts_at;
$$;

grant execute on function public.recommended_games(integer) to authenticated;
grant execute on function public.my_upcoming_games() to authenticated;
revoke execute on function public.recommended_games(integer) from public, anon;
revoke execute on function public.my_upcoming_games() from public, anon;

grant select on public.game_listing to authenticated;
revoke select on public.game_listing from anon;
