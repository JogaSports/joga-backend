begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- Tonight's game (100) kicked off an hour ago. Ray (1) has 24 games,
-- a 4-week streak and hasn't played this week.
update public.games set starts_at = now() - interval '1 hour' where id = tests.game_id(100);

create temporary table sheet as
select jsonb_agg(jsonb_build_object(
         'player_id', player_id,
         'team', case when n <= 5 then 'white' else 'orange' end,
         'attended', true,
         'goals', case when player_id = tests.user_id(1) then 2 else 0 end,
         'assists', 0)) as lines
from (
  select b.player_id, row_number() over (order by b.created_at, b.player_id) as n
  from public.bookings b
  where b.game_id = tests.game_id(100) and b.status = 'confirmed'
) booked;
grant select on sheet to authenticated;

select tests.act_as(1);
select throws_ok(
  $$ select public.submit_match(tests.game_id(100), (select lines from sheet), tests.user_id(1)) $$,
  'not_organiser',
  'only the organiser can submit'
);

select tests.act_as(2);  -- Dan, the organiser
select throws_ok(
  $$ select public.submit_match(tests.game_id(100),
       '[{"player_id":"00000000-0000-4000-a000-000000000126","team":"white"}]'::jsonb, null) $$,
  'player_not_booked',
  'players must be booked on the game'
);

select lives_ok(
  $$ select public.submit_match(tests.game_id(100), (select lines from sheet), tests.user_id(1)) $$,
  'organiser submits the result'
);
select is((select white_score + orange_score from public.match_results where game_id = tests.game_id(100)),
  2, 'score is built from goals');
select is((select status::text from public.games where id = tests.game_id(100)), 'completed', 'game completed');

select tests.act_as(1);
select results_eq(
  $$ select games, goals, potm from public.player_stats(tests.user_id(1), 'career') $$,
  $$ values (25, 20, 5) $$,
  'career stats include tonight'
);
select results_eq(
  $$ select current_weeks, played_this_week from public.my_streak() $$,
  $$ values (5, true) $$,
  'streak goes up to 5 weeks'
);
select is(
  (select amount_pence from public.wallet_ledger where label = '25 games played'),
  250, '25-game milestone credited to the wallet'
);

-- Correcting the result doesn't pay rewards twice.
select tests.act_as(2);
select lives_ok(
  $$ select public.submit_match(tests.game_id(100), (select lines from sheet), tests.user_id(1)) $$,
  'organiser can resubmit a correction'
);
select tests.act_as(1);
select is((select count(*)::integer from public.wallet_ledger where label = '25 games played'), 1,
  'rewards are not paid twice');

-- Leaderboard includes tonight's goals.
select ok(
  (select value from public.leaderboard('cardiff', 'goals') where is_me) >= 2,
  'leaderboard includes the new goals'
);

-- Results can't be submitted before kick-off.
select tests.act_as(2);
select throws_ok(
  $$ select public.submit_match(tests.game_id(101), '[]'::jsonb, null) $$,
  'game_not_started',
  'results wait until kick-off'
);

select * from finish();
rollback;
