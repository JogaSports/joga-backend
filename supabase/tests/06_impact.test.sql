begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

-- Players can't see the impact dashboard.
select tests.act_as(1);
select throws_ok($$ select public.impact_dashboard('season') $$, 'admins_only',
  'the impact dashboard is admins only');

-- Admins can.
select tests.act_as(3);
select throws_ok($$ select public.impact_dashboard('decade') $$, 'invalid_period',
  'the period must be month, season or since_launch');

select ok((public.impact_dashboard('season') ->> 'active_players')::integer > 0,
  'counts active players this season');
select ok(
  (public.impact_dashboard('since_launch') ->> 'games_played')::integer
    >= (public.impact_dashboard('season') ->> 'games_played')::integer,
  'since launch includes at least as many games as the season'
);
select is(jsonb_array_length(public.impact_dashboard('season') -> 'monthly_active'), 6,
  'six months of active players for the chart');
select is(
  (select count(*)::integer from jsonb_array_elements(public.impact_dashboard('season') -> 'towns')),
  (select count(*)::integer from public.cities where is_live),
  'one row per live town'
);
select is(
  (select sum((s ->> 'percent')::integer) between 98 and 102
   from jsonb_array_elements(public.impact_dashboard('season') -> 'sessions') s),
  true, 'session mix adds up to 100%'
);
select ok((public.impact_dashboard('season') ->> 'walking_games')::integer > 0,
  'walking football is counted');

-- No individual players anywhere in the output.
select ok(
  public.impact_dashboard('since_launch')::text !~ '[0-9a-f]{8}-[0-9a-f]{4}-',
  'the dashboard contains no player ids'
);

select * from finish();
rollback;
