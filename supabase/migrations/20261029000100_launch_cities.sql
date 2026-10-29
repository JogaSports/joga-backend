-- =============================================================================
-- Joga Sports · 06 · Launch cities
--
-- The PO's launch list: Bristol, London, Cardiff, Nairobi and Tbilisi.
--   1. Each city gets a country, a timezone, a currency and a display order.
--   2. London, Nairobi and Tbilisi are added.
--   3. Swansea, Newport and Wrexham are retired (deleted if nothing uses
--      them, otherwise hidden).
--   4. "In Wales" is replaced by the country code.
--   5. City leaderboards use the city's own clock, so "this month" in
--      Nairobi starts at midnight in Nairobi.
--
-- Money is NOT made multi-currency here. Game prices are stored in the
-- minor unit of the city's currency (pence, Kenyan cents, tetri), but the
-- booking fee, rewards and wallet are still single amounts with no
-- currency. That needs a product decision before Nairobi or Tbilisi take
-- payments; see docs/DECISIONS-NEEDED.md.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. City details
-- -----------------------------------------------------------------------------
alter table public.cities
  add column country_code text not null default 'GB' check (country_code ~ '^[A-Z]{2}$'),
  add column timezone     text not null default 'Europe/London',
  add column currency     text not null default 'GBP' check (currency ~ '^[A-Z]{3}$'),
  add column sort_order   integer not null default 100;

-- A timezone typo would break every date calculation for that city.
create or replace function private.check_city_timezone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'invalid_timezone' using detail = format('%s is not a known timezone.', new.timezone);
  end if;
  return new;
end;
$$;

create trigger check_city_timezone before insert or update of timezone on public.cities
  for each row execute function private.check_city_timezone();

comment on column public.cities.country_code is 'ISO 3166 country code: GB, KE, GE.';
comment on column public.cities.timezone     is 'IANA timezone for showing kick-off times and for city leaderboards.';
comment on column public.cities.currency     is 'ISO 4217 currency of game prices in this city. Prices are in its minor unit.';
comment on column public.cities.sort_order   is 'Order the app lists cities in.';

-- -----------------------------------------------------------------------------
-- 2. Launch cities, in the PO's order
-- -----------------------------------------------------------------------------
insert into public.cities (id, name, country_code, timezone, currency, sort_order) values
  ('bristol', 'Bristol', 'GB', 'Europe/London',  'GBP', 1),
  ('london',  'London',  'GB', 'Europe/London',  'GBP', 2),
  ('cardiff', 'Cardiff', 'GB', 'Europe/London',  'GBP', 3),
  ('nairobi', 'Nairobi', 'KE', 'Africa/Nairobi', 'KES', 4),
  ('tbilisi', 'Tbilisi', 'GE', 'Asia/Tbilisi',   'GEL', 5)
on conflict (id) do update set
  name         = excluded.name,
  country_code = excluded.country_code,
  timezone     = excluded.timezone,
  currency     = excluded.currency,
  sort_order   = excluded.sort_order,
  is_live      = true;

-- -----------------------------------------------------------------------------
-- 3. Retire Swansea, Newport and Wrexham
--
-- Delete them where nothing points at them (the hosted projects have no
-- venues there). If a venue or player does use one, keep the row so
-- history stays intact, but hide it from the app.
-- -----------------------------------------------------------------------------
update public.profiles set city_id = null
where city_id in ('swansea', 'newport', 'wrexham')
  and not exists (select 1 from public.venues v where v.city_id = profiles.city_id);

delete from public.cities c
where c.id in ('swansea', 'newport', 'wrexham')
  and not exists (select 1 from public.venues v where v.city_id = c.id)
  and not exists (select 1 from public.profiles p where p.city_id = c.id);

update public.cities set is_live = false, sort_order = 999
where id in ('swansea', 'newport', 'wrexham');

-- -----------------------------------------------------------------------------
-- 4. Listing view: country, timezone and currency instead of "in Wales"
-- -----------------------------------------------------------------------------
drop function public.recommended_games(integer);
drop function public.my_upcoming_games();
drop view public.game_listing;

alter table public.cities drop column in_wales;

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
  c.country_code,
  c.timezone,
  c.currency,
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
  'Games with venue, organiser and live spaces. price_pence is in the minor unit of `currency`; '
  'show starts_at in `timezone`. Filter with PostgREST, e.g. city_id=eq.nairobi&status=eq.scheduled.';

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
-- 5. City leaderboards on the city's own clock
-- -----------------------------------------------------------------------------
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
  v_tz    text := coalesce((select c.timezone from public.cities c where c.id = p_city),
                           (private.settings()).timezone);
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

comment on column public.app_settings.timezone is
  'Clock for weekly streaks, seasons and personal stats periods. City leaderboards use cities.timezone.';

-- -----------------------------------------------------------------------------
-- 6. Grants: signed-in users only (as before)
-- -----------------------------------------------------------------------------
revoke all on public.game_listing from anon;
grant select on public.game_listing to authenticated, service_role;

revoke execute on function public.recommended_games(integer) from public, anon;
revoke execute on function public.my_upcoming_games() from public, anon;
revoke execute on function public.leaderboard(text, text, date, integer) from public, anon;
grant execute on function public.recommended_games(integer) to authenticated, service_role;
grant execute on function public.my_upcoming_games() to authenticated, service_role;
grant execute on function public.leaderboard(text, text, date, integer) to authenticated, service_role;
