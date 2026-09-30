-- =============================================================================
-- Joga Sports · Local seed data
--
-- The same world as the app's demo (lib/data/fake/fake_seed.dart): Ray in
-- Cardiff, with a game tonight, a last-space game tomorrow, 24 games of
-- history and a 4-week streak. Dates are relative to now() so it always
-- looks live.
--
-- Local only. `supabase db reset` runs this after the migrations.
--
-- Demo logins (password for all: joga-demo-2026)
--   ray@joga.demo     player
--   dan@joga.demo     organiser (runs tonight's game)
--   admin@joga.demo   admin
-- =============================================================================

-- Deterministic ids so the app, tests and docs can refer to them.
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-a000-' || lpad(n::text, 12, '0'))::uuid
$$;
create function pg_temp.vid(n integer) returns uuid language sql immutable as $$
  select ('10000000-0000-4000-a000-' || lpad(n::text, 12, '0'))::uuid
$$;
create function pg_temp.gid(n integer) returns uuid language sql immutable as $$
  select ('20000000-0000-4000-a000-' || lpad(n::text, 12, '0'))::uuid
$$;
-- Local time today + offset days at hh:mm, as timestamptz.
create function pg_temp.at_local(days integer, hh integer, mm integer default 0) returns timestamptz
language sql stable as $$
  select (date_trunc('day', now() at time zone 'Europe/London')
          + make_interval(days => days, hours => hh, mins => mm)) at time zone 'Europe/London'
$$;

-- -----------------------------------------------------------------------------
-- People
-- -----------------------------------------------------------------------------
create temporary table seed_people (n integer, first_name text, last_name text, email text,
                                    city_id text, role public.user_role, position text);
insert into seed_people values
  (1,  'Ray',    'Mensah',    'ray@joga.demo',   'cardiff', 'player',    'Winger'),
  (2,  'Dan',    'Thomas',    'dan@joga.demo',   'cardiff', 'organiser', 'Defender'),
  (3,  'Joga',   'Admin',     'admin@joga.demo', 'cardiff', 'admin',     null),
  (101, 'Ade',    'Rotimi',    null, 'cardiff', 'player',    'Midfielder'),
  (102, 'Sam',    'Kelly',     null, 'cardiff', 'player',    'Striker'),
  (103, 'Liam',   'Price',     null, 'cardiff', 'player',    'Defender'),
  (104, 'Gethin', 'Knight',    null, 'cardiff', 'player',    'Goalkeeper'),
  (105, 'Omar',   'Bashir',    null, 'cardiff', 'player',    'Midfielder'),
  (106, 'Tomi',   'Fashola',   null, 'cardiff', 'player',    'Striker'),
  (107, 'Mo',     'Nasser',    null, 'cardiff', 'player',    'Winger'),
  (108, 'Rhys',   'Evans',     null, 'cardiff', 'player',    'Defender'),
  (109, 'Jack',   'Williams',  null, 'bristol', 'organiser', 'Midfielder'),
  (110, 'Chris',  'Davies',    null, 'cardiff', 'player',    'Striker'),
  (111, 'Alex',   'Parry',     null, 'cardiff', 'organiser', 'Defender'),
  (112, 'Matt',   'Griffiths', null, 'cardiff', 'player',    'Midfielder'),
  (113, 'Tom',    'Lewis',     null, 'cardiff', 'organiser', 'Winger'),
  (114, 'Kieran', 'O''Neill',  null, 'bristol', 'player',    'Striker'),
  (115, 'Josh',   'Bennett',   null, 'bristol', 'player',    'Midfielder'),
  (116, 'Kwame',  'Asante',    null, 'bristol', 'player',    'Striker'),
  (117, 'Dylan',  'Walsh',     null, 'bristol', 'player',    'Defender'),
  (118, 'Callum', 'Jones',     null, 'bristol', 'player',    'Goalkeeper'),
  (119, 'Ben',    'Hughes',    null, 'bristol', 'player',    'Winger'),
  (120, 'Luke',   'Stevens',   null, 'bristol', 'player',    'Midfielder'),
  (121, 'Harri',  'Watkins',   null, 'bristol', 'player',    'Defender'),
  (122, 'Idris',  'Yusuf',     null, 'bristol', 'player',    'Striker'),
  (123, 'Sophie', 'Hale',      null, 'cardiff', 'player',    'Midfielder'),
  (124, 'Amara',  'Obi',       null, 'cardiff', 'organiser', 'Striker'),
  (125, 'Ellie',  'Morgan',    null, 'cardiff', 'player',    'Defender'),
  (126, 'Grace',  'Lloyd',     null, 'cardiff', 'player',    'Winger');

-- Auth users (the sign-up trigger creates each profile).
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
select
  '00000000-0000-0000-0000-000000000000',
  pg_temp.uid(p.n),
  'authenticated',
  'authenticated',
  coalesce(p.email, lower(p.first_name) || '.' || lower(regexp_replace(p.last_name, '[^A-Za-z]', '', 'g')) || '@joga.demo'),
  extensions.crypt('joga-demo-2026', extensions.gen_salt('bf')),
  now(),
  '{"provider": "email", "providers": ["email"]}'::jsonb,
  jsonb_build_object('first_name', p.first_name, 'last_name', p.last_name, 'city_id', p.city_id),
  now() - interval '7 months',
  now(),
  '', '', '', ''
from seed_people p;

insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select u.id::text, u.id,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), now(), now()
from auth.users u
where u.email like '%@joga.demo';

update public.profiles pr
set role = p.role,
    position = p.position,
    level = case when p.n in (102, 106, 110) then 'competitive'::public.skill_level
                 when p.n in (115, 125) then 'beginner'::public.skill_level
                 else 'intermediate'::public.skill_level end,
    created_at = now() - interval '7 months'
from seed_people p
where pr.id = pg_temp.uid(p.n);

update public.profiles set referral_code = 'RAY24' where id = pg_temp.uid(1);

-- -----------------------------------------------------------------------------
-- Venues
-- -----------------------------------------------------------------------------
insert into public.venues (id, name, city_id, address, surface, parking) values
  (pg_temp.vid(1), 'Gôl Cardiff',        'cardiff', 'Leckwith Road, Cardiff CF11 8AZ',  '3G · moulds or astros', 'Free, on site'),
  (pg_temp.vid(2), 'Leckwith 3G',        'cardiff', 'Leckwith Close, Cardiff CF11 8AX', '3G · moulds or astros', 'Free, on site'),
  (pg_temp.vid(3), 'Canton Sports Cage', 'cardiff', 'Market Road, Cardiff CF5 1QE',     'Astro · astros only',   'Street parking'),
  (pg_temp.vid(4), 'Splott 3G',          'cardiff', 'Splott Road, Cardiff CF24 2BZ',    '3G · moulds or astros', 'Pay and display'),
  (pg_temp.vid(5), 'Temple Quay Cage',   'bristol', 'Temple Gate, Bristol BS1 6PL',     'Astro · astros only',   'NCP nearby'),
  (pg_temp.vid(6), 'Eastville 3G',       'bristol', 'Eastville Park, Bristol BS5 6YA',  '3G · moulds or astros', 'Free, on site'),
  (pg_temp.vid(7), 'Ashton Park Astro',  'bristol', 'Blackmoors Lane, Bristol BS3 2JL', 'Astro · astros only',   'Free, on site');

-- -----------------------------------------------------------------------------
-- Upcoming games (ids match the app's FakeSeed: g-100 -> gid(100), ...)
-- -----------------------------------------------------------------------------
insert into public.games (id, format, venue_id, pitch, starts_at, level, tags, price_pence, venue_cost_pence, organiser_id) values
  -- Ray's game tonight: full, kicks off in about 1h 25m.
  (pg_temp.gid(100), 'five_a_side',  pg_temp.vid(1), 'Pitch 1',   now() + interval '1 hour 24 minutes 36 seconds',
     'intermediate', '{mixed}', 800, 5500, pg_temp.uid(2)),
  -- One space left, for the booking demo.
  (pg_temp.gid(101), 'five_a_side',  pg_temp.vid(1), 'Pitch 2',   pg_temp.at_local(1, 19), 'intermediate', '{mixed}',  800, 5500, pg_temp.uid(2)),
  (pg_temp.gid(102), 'seven_a_side', pg_temp.vid(3), 'Main cage', pg_temp.at_local(1, 20), 'beginner',     '{casual}', 600, 7000, pg_temp.uid(111)),
  (pg_temp.gid(103), 'five_a_side',  pg_temp.vid(4), 'Pitch 3',   pg_temp.at_local(2, 18, 30), 'competitive', '{competitive}', 700, 5500, pg_temp.uid(2)),
  -- Full: waitlist demo.
  (pg_temp.gid(104), 'seven_a_side', pg_temp.vid(2), 'Pitch 1',   pg_temp.at_local(3, 19), 'intermediate', '{mixed}',  600, 7000, pg_temp.uid(2)),
  (pg_temp.gid(105), 'five_a_side',  pg_temp.vid(1), 'Pitch 4',   pg_temp.at_local(4, 20), 'intermediate', '{over_30s,casual}', 800, 5500, pg_temp.uid(113)),
  (pg_temp.gid(106), 'five_a_side',  pg_temp.vid(2), 'Pitch 2',   pg_temp.at_local(5, 10), 'beginner',     '{womens,casual}', 600, 5500, pg_temp.uid(124)),
  (pg_temp.gid(108), 'seven_a_side', pg_temp.vid(2), 'Pitch 1',   pg_temp.at_local(5, 18), 'intermediate', '{mixed}',  600, 7000, pg_temp.uid(2)),
  (pg_temp.gid(201), 'five_a_side',  pg_temp.vid(5), 'Cage A',    pg_temp.at_local(1, 19, 30), 'intermediate', '{mixed}', 750, 5500, pg_temp.uid(109)),
  (pg_temp.gid(202), 'seven_a_side', pg_temp.vid(6), 'Pitch 2',   pg_temp.at_local(2, 20), 'competitive', '{competitive}', 650, 7000, pg_temp.uid(109)),
  (pg_temp.gid(203), 'five_a_side',  pg_temp.vid(7), 'Pitch 1',   pg_temp.at_local(3, 18), 'beginner',    '{casual,over_30s}', 700, 5500, pg_temp.uid(109)),
  -- Finished earlier today, result not yet submitted (admin view).
  (pg_temp.gid(90),  'five_a_side',  pg_temp.vid(3), 'Main cage', now() - interval '3 hours', 'intermediate', '{mixed}', 700, 5500, pg_temp.uid(111)),
  (pg_temp.gid(91),  'seven_a_side', pg_temp.vid(6), 'Pitch 1',   now() - interval '2 hours', 'beginner', '{casual}', 600, 7000, pg_temp.uid(109));

-- Bookings on upcoming games: game, list of seed people.
create temporary table seed_bookings (game integer, people integer[]);
insert into seed_bookings values
  (100, array[1, 101, 102, 103, 104, 105, 106, 107, 108, 110]),
  (101, array[105, 106, 107, 108, 110, 112, 123, 125, 126]),
  (102, array[110, 111, 112, 113, 123, 125, 126, 103]),
  (103, array[113, 114, 115, 116, 117, 118]),
  (104, array[103, 104, 105, 106, 107, 108, 110, 112, 113, 123, 125, 126, 101, 102]),
  (105, array[116, 117, 118, 119, 120]),
  (106, array[123, 125, 126, 124]),
  (108, array[1, 107, 108, 110, 112, 123, 125, 126]),
  (201, array[114, 115, 116, 117, 118, 119, 120]),
  (202, array[115, 116, 117, 118, 119, 120, 121, 122, 114, 109]),
  (203, array[117, 118, 119, 120, 121, 122, 114, 115, 116]),
  (90,  array[102, 103, 104, 105, 106, 107, 108, 110, 112, 101]),
  (91,  array[114, 115, 116, 117, 118, 119]);

insert into public.bookings (game_id, player_id, price_pence, fee_pence, card_pence, created_at)
select g.id, pg_temp.uid(p), g.price_pence, 100, g.price_pence + 100, now() - interval '2 days'
from seed_bookings sb
cross join lateral unnest(sb.people) as p
join public.games g on g.id = pg_temp.gid(sb.game);

-- -----------------------------------------------------------------------------
-- Ray's history: 24 completed games. Weeks played (weeks ago) give a
-- current 4-week streak and a best of 9, matching the app demo.
-- -----------------------------------------------------------------------------
do $$
declare
  -- weeks ago, goals, assists, won, potm  (most recent first)
  v_games constant integer[][] := array[
    [1, 3, 2, 1, 1], [2, 1, 1, 0, 0], [3, 2, 0, 0, 0], [4, 3, 0, 1, 1], [6, 1, 1, 1, 0],
    [7, 0, 0, 0, 0], [8, 2, 1, 1, 0], [10, 1, 0, 1, 0], [11, 0, 2, 0, 0], [13, 1, 1, 1, 0],
    [14, 0, 0, 1, 0], [15, 1, 0, 1, 1], [16, 0, 1, 0, 0], [17, 0, 0, 1, 0], [18, 1, 0, 1, 0],
    [19, 0, 1, 0, 0], [20, 0, 0, 1, 1], [21, 1, 0, 1, 0], [24, 1, 0, 0, 0], [26, 0, 1, 1, 0],
    [28, 0, 0, 0, 0], [30, 0, 0, 1, 0], [32, 0, 0, 0, 0], [34, 0, 0, 0, 0]
  ];
  v_others constant integer[] := array[101, 102, 103, 104, 105, 106, 107, 108, 110, 112, 123, 125, 126];
  i        integer;
  j        integer;
  v_game   uuid;
  v_start  timestamptz;
  v_goals  integer;
  v_assist integer;
  v_won    boolean;
  v_my     integer;
  v_their  integer;
  v_team   integer[];
  v_opp    integer[];
  v_potm   uuid;
begin
  for i in 1 .. array_length(v_games, 1) loop
    v_game   := pg_temp.gid(i);                 -- gid(1) is last week's game (the app's g-099)
    v_goals  := v_games[i][2];
    v_assist := v_games[i][3];
    v_won    := v_games[i][4] = 1;
    v_my     := case when v_won then v_goals + 4 else v_goals + 3 end;
    v_their  := case when v_won then v_my - 2 else v_my + 2 end;
    -- Tuesday 19:00 local time, N weeks ago.
    v_start  := ((date_trunc('week', now() at time zone 'Europe/London')::date - 7 * v_games[i][1] + 1)
                 + time '19:00') at time zone 'Europe/London';

    -- Rotate teammates and opponents through the Cardiff regulars.
    v_team := array[v_others[1 + (i) % 13], v_others[1 + (i + 1) % 13], v_others[1 + (i + 2) % 13], v_others[1 + (i + 3) % 13]];
    v_opp  := array[v_others[1 + (i + 4) % 13], v_others[1 + (i + 5) % 13], v_others[1 + (i + 6) % 13],
                    v_others[1 + (i + 7) % 13], v_others[1 + (i + 8) % 13]];

    insert into public.games (id, format, venue_id, pitch, starts_at, level, tags, price_pence, venue_cost_pence, organiser_id, status)
    values (v_game, 'five_a_side', pg_temp.vid(1 + i % 4), 'Pitch 1', v_start, 'intermediate', '{mixed}', 800, 5500,
            pg_temp.uid(2), 'completed');

    insert into public.bookings (game_id, player_id, price_pence, fee_pence, card_pence, created_at)
    select v_game, pid, 800, 100, 900, v_start - interval '3 days'
    from unnest(array[pg_temp.uid(1)] || array(select pg_temp.uid(x) from unnest(v_team || v_opp) x)) as pid;

    -- Ray
    insert into public.match_lines (game_id, player_id, team, goals, assists)
    values (v_game, pg_temp.uid(1), 'white', v_goals, v_assist);
    -- Teammates share the rest of the white goals; opponents share theirs.
    for j in 1 .. 4 loop
      insert into public.match_lines (game_id, player_id, team, goals, assists)
      values (v_game, pg_temp.uid(v_team[j]), 'white',
              (v_my - v_goals) / 4 + case when j <= (v_my - v_goals) % 4 then 1 else 0 end,
              case when j = 1 then 1 else 0 end);
    end loop;
    for j in 1 .. 5 loop
      insert into public.match_lines (game_id, player_id, team, goals, assists)
      values (v_game, pg_temp.uid(v_opp[j]), 'orange',
              v_their / 5 + case when j <= v_their % 5 then 1 else 0 end,
              case when j <= 2 then 1 else 0 end);
    end loop;

    v_potm := case when v_games[i][5] = 1 then pg_temp.uid(1) else pg_temp.uid(v_team[1]) end;
    insert into public.match_results (game_id, white_score, orange_score, potm_id, submitted_by, submitted_at)
    values (v_game, v_my, v_their, v_potm, pg_temp.uid(2), v_start + interval '70 minutes');
  end loop;
end;
$$;

-- Rewards already earned before this data starts (so they aren't re-awarded
-- when the next result is submitted).
insert into public.player_rewards (player_id, rule_id, credit_pence, awarded_at)
select pr.id, r.id, 0, now() - interval '1 month'
from public.profiles pr
cross join lateral private.player_totals(pr.id, null) t
join public.reward_rules r
  on (r.kind = 'games_played' and r.threshold <= t.games)
  or (r.kind = 'potm_awards' and r.threshold <= t.potm);

-- -----------------------------------------------------------------------------
-- Ray's wallet (balance £7.50) and referrals
-- -----------------------------------------------------------------------------
insert into public.wallet_ledger (player_id, type, amount_pence, label, created_at) values
  (pg_temp.uid(1), 'reward',   450, 'Welcome credit',             now() - interval '60 days'),
  (pg_temp.uid(1), 'refund',   600, 'Refund · Canton cancelled',  now() - interval '30 days'),
  (pg_temp.uid(1), 'booking', -600, 'Game booking · Splott 3G',   now() - interval '16 days'),
  (pg_temp.uid(1), 'referral', 200, 'Referral · Sophie',          now() - interval '12 days'),
  (pg_temp.uid(1), 'reward',   100, '10 games played',            now() - interval '11 days');

update public.profiles set referred_by = pg_temp.uid(1)
where id in (pg_temp.uid(123), pg_temp.uid(115), pg_temp.uid(114));

insert into public.referrals (referred_id, referrer_id, stage, created_at, rewarded_at) values
  (pg_temp.uid(123), pg_temp.uid(1), 'rewarded',   now() - interval '40 days', now() - interval '12 days'),
  (pg_temp.uid(115), pg_temp.uid(1), 'first_game', now() - interval '10 days', null),
  (pg_temp.uid(114), pg_temp.uid(1), 'joined',     now() - interval '3 days',  null);
