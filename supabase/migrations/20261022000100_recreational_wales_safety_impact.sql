-- =============================================================================
-- Joga Sports · 05 · Recreational football in Wales, safety and impact
--
-- Brings the backend in line with the app (joga-app 0.2.2):
--   1. Towns: Swansea, Newport and Wrexham; an "in Wales" flag.
--   2. Recreational only: no skill levels; new game tags
--      (beginner, womens, mixed, walking, casual).
--   3. Profiles: position and preferred foot as enums; age and code of
--      conduct recorded at sign-up through complete_profile().
--   4. Venue facilities (step-free access, defibrillator, ...).
--   5. Deeper stats are free for everyone.
--   6. Reliability (turn-up rate) for the profile.
--   7. Safety: report a player, block and unblock.
--   8. Community impact dashboard for admins (aggregates only).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Towns
-- -----------------------------------------------------------------------------
alter table public.cities add column in_wales boolean not null default true;
update public.cities set in_wales = false where id = 'bristol';
insert into public.cities (id, name) values
  ('swansea', 'Swansea'),
  ('newport', 'Newport'),
  ('wrexham', 'Wrexham')
on conflict (id) do nothing;

comment on column public.cities.in_wales is 'Wales launches first; Bristol is outside Wales.';

-- -----------------------------------------------------------------------------
-- 2. Recreational: drop skill levels, replace game tags
--
-- The listing view and the two functions that return it depend on these
-- columns, so they're dropped here and rebuilt in section 9.
-- -----------------------------------------------------------------------------
drop function public.recommended_games(integer);
drop function public.my_upcoming_games();
drop view public.game_listing;

create type public.game_tag_v2 as enum ('beginner', 'womens', 'mixed', 'walking', 'casual');

-- Tags that still exist carry over; 'competitive' becomes 'mixed';
-- 'over_30s' is dropped.
alter table public.games add column tags_v2 public.game_tag_v2[] not null default '{}';
update public.games set tags_v2 = array(
  select distinct (case t::text when 'competitive' then 'mixed' else t::text end)::public.game_tag_v2
  from unnest(tags) as t
  where t::text in ('womens', 'mixed', 'casual', 'competitive')
);
alter table public.games drop column tags;
alter table public.games rename column tags_v2 to tags;
drop type public.game_tag;
alter type public.game_tag_v2 rename to game_tag;

alter table public.games drop column level;
alter table public.profiles drop column level;
drop type public.skill_level;

create index games_tags_idx on public.games using gin (tags);

-- -----------------------------------------------------------------------------
-- 3. Profiles
-- -----------------------------------------------------------------------------
create type public.player_position as enum ('goalkeeper', 'defender', 'midfielder', 'winger', 'striker');
create type public.preferred_foot as enum ('left', 'right', 'both');

alter table public.profiles drop constraint if exists profiles_position_check;
alter table public.profiles alter column position type public.player_position using
  case when lower(position) in ('goalkeeper', 'defender', 'midfielder', 'winger', 'striker')
       then lower(position)::public.player_position end;

alter table public.profiles
  add column foot              public.preferred_foot,
  add column age_confirmed_at  timestamptz,
  add column conduct_agreed_at timestamptz;

comment on column public.profiles.age_confirmed_at is
  'When the player confirmed they are 18 or over. Null = profile not set up yet.';
comment on column public.profiles.conduct_agreed_at is
  'When the player agreed to the code of conduct.';

-- Players already on the platform signed up under the old flow.
update public.profiles
set age_confirmed_at = created_at, conduct_agreed_at = created_at
where age_confirmed_at is null;

-- Column-level grants: the consent stamps are set by complete_profile() only.
revoke update on public.profiles from authenticated;
grant update (first_name, last_name, city_id, position, foot, avatar_url)
  on public.profiles to authenticated;

-- Finish sign-up: name, town, position, foot, and the two consents.
create or replace function public.complete_profile(
  p_first_name text,
  p_last_name  text,
  p_city       text,
  p_position   public.player_position,
  p_foot       public.preferred_foot
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player  uuid := private.require_user();
  v_profile public.profiles;
begin
  if char_length(trim(coalesce(p_first_name, ''))) = 0 then
    raise exception 'name_required' using detail = 'Add your first name.';
  end if;
  if not exists (select 1 from public.cities where id = p_city and is_live) then
    raise exception 'city_not_found' using detail = 'Choose a town from the list.';
  end if;

  update public.profiles
  set first_name        = left(trim(p_first_name), 50),
      last_name         = left(trim(coalesce(p_last_name, '')), 50),
      city_id           = p_city,
      position          = p_position,
      foot              = p_foot,
      age_confirmed_at  = coalesce(age_confirmed_at, now()),
      conduct_agreed_at = coalesce(conduct_agreed_at, now())
  where id = v_player
  returning * into v_profile;

  return v_profile;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Venue facilities
-- -----------------------------------------------------------------------------
create type public.venue_facility as enum (
  'step_free', 'accessible_toilet', 'changing_rooms', 'defibrillator',
  'first_aid', 'floodlights', 'parking'
);
alter table public.venues
  add column facilities public.venue_facility[] not null default '{}';

-- -----------------------------------------------------------------------------
-- 5. Deeper stats are free for everyone (was Joga+)
-- -----------------------------------------------------------------------------
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

comment on function public.my_member_stats() is
  'Deeper stats for the signed-in player. Free for everyone; the name is kept so the app API does not change.';

-- -----------------------------------------------------------------------------
-- 6. Reliability: share of booked, played games the player turned up to
-- -----------------------------------------------------------------------------
create or replace function public.my_reliability()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    round(100.0 * count(*) filter (where ml.attended) / nullif(count(*), 0))::integer,
    100)
  from public.match_lines ml
  join public.bookings b
    on b.game_id = ml.game_id and b.player_id = ml.player_id and b.status = 'confirmed'
  where ml.player_id = (select auth.uid());
$$;

-- -----------------------------------------------------------------------------
-- 7. Safety: reports and blocks
-- -----------------------------------------------------------------------------
create type public.report_reason as enum (
  'abuse', 'discrimination', 'violence', 'unsafe_play', 'no_show', 'other'
);
create type public.report_status as enum ('open', 'reviewed', 'actioned');

create table public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reported_id uuid not null references public.profiles (id) on delete cascade,
  game_id     uuid references public.games (id) on delete set null,
  reason      public.report_reason not null,
  details     text not null default '' check (char_length(details) <= 1000),
  status      public.report_status not null default 'open',
  admin_notes text not null default '',
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz,
  check (reporter_id <> reported_id)
);
create index reports_open_idx on public.reports (created_at) where status = 'open';
create index reports_reported_idx on public.reports (reported_id);

comment on table public.reports is
  'Player reports. Write-only for players (no one can see who reported them); admins review.';

create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked_idx on public.blocks (blocked_id);

alter table public.reports enable row level security;
alter table public.blocks  enable row level security;

create policy "Admins read reports" on public.reports
  for select to authenticated using (public.is_admin());
create policy "Admins review reports" on public.reports
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Players read their own blocks" on public.blocks
  for select to authenticated using (blocker_id = (select auth.uid()));

-- Writes only through the functions below.
revoke insert, update, delete on public.reports, public.blocks from anon, authenticated;
grant update (status, admin_notes, reviewed_at) on public.reports to authenticated;

create or replace function public.report_player(
  p_player  uuid,
  p_reason  public.report_reason,
  p_details text default '',
  p_game    uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_user();
begin
  if p_player = v_me then
    raise exception 'cannot_report_self' using detail = 'You can''t report yourself.';
  end if;
  if not exists (select 1 from public.profiles where id = p_player) then
    raise exception 'player_not_found' using detail = 'That player doesn''t exist.';
  end if;
  -- Light abuse protection: 10 reports a day per player.
  if (select count(*) from public.reports
      where reporter_id = v_me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'too_many_reports' using detail = 'You''ve sent a lot of reports today. We''ll review them.';
  end if;

  insert into public.reports (reporter_id, reported_id, game_id, reason, details)
  values (v_me, p_player, p_game, p_reason, left(coalesce(p_details, ''), 1000));
end;
$$;

create or replace function public.block_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_user();
begin
  if p_player = v_me then
    raise exception 'cannot_block_self' using detail = 'You can''t block yourself.';
  end if;
  if not exists (select 1 from public.profiles where id = p_player) then
    raise exception 'player_not_found' using detail = 'That player doesn''t exist.';
  end if;
  insert into public.blocks (blocker_id, blocked_id) values (v_me, p_player)
  on conflict do nothing;
end;
$$;

create or replace function public.unblock_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_user();
begin
  delete from public.blocks
  where blocker_id = v_me and blocked_id = p_player;
end;
$$;

create or replace function public.my_blocked_players()
returns table (player_id uuid, first_name text, last_name text, blocked_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.first_name, p.last_name, b.created_at
  from public.blocks b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = (select auth.uid())
  order by b.created_at desc;
$$;

-- -----------------------------------------------------------------------------
-- 8. Community impact dashboard (admins; aggregates only, no individuals)
--
-- p_period: 'month' (this calendar month), 'season' (from 1 August) or
-- 'since_launch'. Returns one JSON object shaped like the app's
-- ImpactDashboard.
-- -----------------------------------------------------------------------------
create or replace function public.impact_dashboard(p_period text default 'season')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz     text := (private.settings()).timezone;
  v_now    timestamptz := now();
  v_from   timestamptz;
  v_prev   timestamptz;
  v_result jsonb;
begin
  if not public.is_admin() then
    raise exception 'admins_only' using errcode = '42501', detail = 'Admins only.';
  end if;
  if p_period not in ('month', 'season', 'since_launch') then
    raise exception 'invalid_period' using detail = 'Choose month, season or since_launch.';
  end if;

  v_from := case p_period
    when 'since_launch' then '-infinity'::timestamptz
    else private.period_start(p_period)
  end;
  -- The previous period of the same length, for town growth.
  v_prev := case p_period
    when 'since_launch' then '-infinity'::timestamptz
    else v_from - (v_now - v_from)
  end;

  with
  -- Games that were played (a result was submitted).
  played as (
    select g.id, g.starts_at, g.duration_minutes, g.capacity, g.tags, v.city_id
    from public.games g
    join public.venues v on v.id = g.venue_id
    join public.match_results mr on mr.game_id = g.id
    where g.status <> 'cancelled' and g.starts_at <= v_now
  ),
  attended as (
    select ml.player_id, p.id as game_id, p.starts_at, p.duration_minutes, p.tags, p.city_id
    from public.match_lines ml
    join played p on p.id = ml.game_id
    where ml.attended
  ),
  firsts as (
    select player_id, min(starts_at) as first_game from attended group by player_id
  ),
  in_period as (select * from attended where starts_at >= v_from),
  games_in_period as (select * from played where starts_at >= v_from),
  fill as (
    select gp.id,
           (select count(*) from public.bookings b
            where b.game_id = gp.id and b.status = 'confirmed')::numeric / gp.capacity as ratio
    from games_in_period gp
  ),
  retention_base as (
    select f.player_id,
           exists (select 1 from attended a
                   where a.player_id = f.player_id
                     and a.starts_at >= f.first_game + interval '28 days') as stayed
    from firsts f
    where f.first_game >= v_from and f.first_game <= v_now - interval '28 days'
  ),
  months as (
    select generate_series(
      date_trunc('month', v_now at time zone v_tz) - interval '5 months',
      date_trunc('month', v_now at time zone v_tz),
      interval '1 month') as month_start
  ),
  monthly as (
    select m.month_start,
           (select count(distinct a.player_id) from attended a
            where (a.starts_at at time zone v_tz) >= m.month_start
              and (a.starts_at at time zone v_tz) < m.month_start + interval '1 month') as players
    from months m
  ),
  towns as (
    select c.id as city_id,
           (select count(distinct a.player_id) from in_period a where a.city_id = c.id) as players,
           (select count(*) from games_in_period g where g.city_id = c.id) as games,
           (select count(distinct a.player_id) from attended a
            where a.city_id = c.id and a.starts_at >= v_prev and a.starts_at < v_from) as prev_players
    from public.cities c
    where c.is_live
  ),
  sessions as (
    select case
             when 'walking' = any (tags) then 'walking'
             when 'womens' = any (tags) then 'womens'
             when 'beginner' = any (tags) then 'beginner'
             else 'open'
           end as type
    from games_in_period
  )
  select jsonb_build_object(
    'period', p_period,
    'active_players', (select count(distinct player_id) from in_period),
    'games_played', (select count(*) from games_in_period),
    'player_hours', (select coalesce(round(sum(duration_minutes) / 60.0), 0) from in_period)::integer,
    'new_players', (select count(*) from firsts where first_game >= v_from),
    -- Needs a sign-up question ("played organised football in the last
    -- year?"). Null until that data exists; the app hides the tile.
    'returners_percent', null,
    'retention_percent', (select round(100.0 * count(*) filter (where stayed) / nullif(count(*), 0))::integer
                          from retention_base),
    -- Share of active players who played in at least one women's game.
    -- Gender is not collected.
    'women_percent', (select round(100.0 * count(distinct player_id) filter (where 'womens' = any (tags))
                                   / nullif(count(distinct player_id), 0))::integer
                      from in_period),
    'womens_games', (select count(*) from games_in_period where 'womens' = any (tags)),
    'walking_games', (select count(*) from games_in_period where 'walking' = any (tags)),
    'average_fill_percent', (select coalesce(round(100 * avg(ratio)), 0)::integer from fill),
    'monthly_active', (select coalesce(jsonb_agg(jsonb_build_object(
                          'year', extract(year from month_start)::integer,
                          'month', extract(month from month_start)::integer,
                          'players', players) order by month_start), '[]'::jsonb)
                       from monthly),
    'towns', (select coalesce(jsonb_agg(jsonb_build_object(
                 'city_id', city_id,
                 'players', players,
                 'games', games,
                 'growth_percent', case when p_period = 'since_launch' or prev_players = 0 then null
                                        else round(100.0 * (players - prev_players) / prev_players)::integer end)
                 order by players desc, city_id), '[]'::jsonb)
              from towns),
    'sessions', (select coalesce(jsonb_agg(jsonb_build_object(
                    'type', type,
                    'percent', round(100.0 * n / total)::integer) order by n desc, type), '[]'::jsonb)
                 from (select type, count(*) as n, sum(count(*)) over () as total
                       from sessions group by type) s)
  ) into v_result;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. Rebuild the listing view and the functions that return it
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
  c.in_wales,
  v.address,
  v.surface,
  v.parking,
  v.facilities,
  v.photo_url,
  g.pitch,
  g.starts_at,
  g.duration_minutes,
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
  'e.g. city_id=eq.cardiff&status=eq.scheduled&tags=cs.{womens}.';

-- "For you" on Home: the player's town, not full, not booked, and not run
-- by someone they've blocked.
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
    and not exists (
      select 1 from public.bookings b
      where b.game_id = gl.id and b.player_id = me.id and b.status = 'confirmed'
    )
    and not exists (
      select 1 from public.blocks bl
      where bl.blocker_id = me.id and bl.blocked_id = gl.organiser_id
    )
  order by gl.starts_at
  limit least(greatest(p_limit, 1), 20);
$$;

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

-- -----------------------------------------------------------------------------
-- 10. Grants for everything new or rebuilt: signed-in users only
-- -----------------------------------------------------------------------------
revoke all on public.game_listing from anon;
grant select on public.game_listing to authenticated, service_role;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.recommended_games(integer)',
    'public.my_upcoming_games()',
    'public.complete_profile(text, text, text, public.player_position, public.preferred_foot)',
    'public.my_member_stats()',
    'public.my_reliability()',
    'public.report_player(uuid, public.report_reason, text, uuid)',
    'public.block_player(uuid)',
    'public.unblock_player(uuid)',
    'public.my_blocked_players()',
    'public.impact_dashboard(text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;
