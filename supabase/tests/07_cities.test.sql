begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- ---- The launch cities ------------------------------------------------------
select results_eq(
  $$ select id, country_code, timezone, currency from public.cities where is_live order by sort_order $$,
  $$ values ('bristol', 'GB', 'Europe/London',  'GBP'),
            ('london',  'GB', 'Europe/London',  'GBP'),
            ('cardiff', 'GB', 'Europe/London',  'GBP'),
            ('nairobi', 'KE', 'Africa/Nairobi', 'KES'),
            ('tbilisi', 'GE', 'Asia/Tbilisi',   'GEL') $$,
  'launch cities have their country, timezone and currency'
);
select is_empty(
  $$ select 1 from public.cities where id in ('swansea', 'newport', 'wrexham') and is_live $$,
  'Swansea, Newport and Wrexham are retired'
);
select hasnt_column('public', 'cities', 'in_wales', 'the Wales flag is gone');

select throws_ok(
  $$ insert into public.cities (id, name, timezone) values ('lagos', 'Lagos', 'Africa/Lagoss') $$,
  'invalid_timezone', 'a misspelt timezone is rejected'
);
select lives_ok(
  $$ insert into public.cities (id, name, country_code, timezone, currency, is_live)
     values ('lagos', 'Lagos', 'NG', 'Africa/Lagos', 'NGN', false) $$,
  'a new city can be added with a real timezone'
);

-- ---- What the app reads -------------------------------------------------------
select tests.act_as(1);  -- Ray

select results_eq(
  $$ select distinct city_id, country_code, timezone, currency from public.game_listing
     where city_id in ('nairobi', 'tbilisi') order by city_id $$,
  $$ values ('nairobi', 'KE', 'Africa/Nairobi', 'KES'), ('tbilisi', 'GE', 'Asia/Tbilisi', 'GEL') $$,
  'game listings carry the city''s country, timezone and currency'
);
select ok(
  (select bool_and(extract(hour from starts_at at time zone 'Africa/Nairobi') between 17 and 21)
   from public.game_listing where city_id = 'nairobi' and status = 'scheduled'),
  'Nairobi games kick off in the evening, Nairobi time'
);
select isnt_empty(
  $$ select 1 from public.game_listing where city_id = 'london' and status = 'scheduled' $$,
  'London has games to book'
);
select isnt_empty(
  $$ select 1 from public.game_listing where city_id = 'tbilisi' and status = 'scheduled' $$,
  'Tbilisi has games to book'
);

select throws_ok(
  $$ select public.complete_profile('Ray', 'Mensah', 'swansea', 'winger', 'right') $$,
  'city_not_found', 'a retired city can''t be chosen at sign-up'
);

-- ---- Leaderboards on the city's own clock ---------------------------------------
select tests.act_as_owner();
-- A Tbilisi game at 01:30 on the 1st of this month, Tbilisi time: in this
-- month for Tbilisi, but still last month in UK time.
insert into public.games (id, format, venue_id, pitch, starts_at, tags, price_pence, organiser_id, status)
values ('30000000-0000-4000-a000-000000000001', 'five_a_side', '10000000-0000-4000-a000-000000000012', 'Pitch 1',
        (date_trunc('month', now() at time zone 'Asia/Tbilisi') + interval '90 minutes') at time zone 'Asia/Tbilisi',
        '{mixed}', 1500, '00000000-0000-4000-a000-000000000132', 'completed');
insert into public.match_lines (game_id, player_id, team, goals, assists)
values ('30000000-0000-4000-a000-000000000001', '00000000-0000-4000-a000-000000000139', 'white', 7, 0);
insert into public.match_results (game_id, white_score, orange_score, submitted_by)
values ('30000000-0000-4000-a000-000000000001', 7, 0, '00000000-0000-4000-a000-000000000132');

select tests.act_as(1);
select ok(
  (select value >= 7 from public.leaderboard('tbilisi', 'goals') where player_id = '00000000-0000-4000-a000-000000000139'),
  'a game just after midnight Tbilisi time counts in Tbilisi''s month'
);
select is_empty(
  $$ select 1 from public.leaderboard('nairobi', 'goals') where player_id = '00000000-0000-4000-a000-000000000139' $$,
  'leaderboards stay per city'
);

select * from finish();
rollback;
