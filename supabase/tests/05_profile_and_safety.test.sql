begin;
create extension if not exists pgtap with schema extensions;
select plan(23);

-- ---- Recreational schema ----------------------------------------------------
select hasnt_column('public', 'games', 'level', 'games have no skill level');
select hasnt_column('public', 'profiles', 'level', 'profiles have no skill level');
select enum_has_labels('public', 'game_tag', array['beginner', 'womens', 'mixed', 'walking', 'casual'],
  'game tags match the app');
select results_eq(
  $$ select id from public.cities where is_live order by sort_order $$,
  $$ values ('bristol'), ('london'), ('cardiff'), ('nairobi'), ('tbilisi') $$,
  'the five launch cities are live, in the PO''s order'
);

select tests.act_as(1);  -- Ray
select isnt_empty(
  $$ select 1 from public.game_listing where city_id = 'nairobi' and status = 'scheduled' $$,
  'Nairobi has games to book'
);
select isnt_empty(
  $$ select 1 from public.game_listing where tags @> '{walking}' $$,
  'walking football games can be found by tag'
);
select ok(
  (select 'defibrillator' = any (facilities) from public.game_listing where id = tests.game_id(100)),
  'listing shows venue facilities'
);

-- ---- Sign-up: complete_profile -----------------------------------------------
select tests.act_as_owner();
insert into auth.users (id, email, raw_user_meta_data)
values ('00000000-0000-4000-a000-000000000998', 'new.signup@joga.demo', '{}');

select is(
  (select age_confirmed_at from public.profiles where id = '00000000-0000-4000-a000-000000000998'),
  null, 'a new account needs its profile set up'
);

select tests.act_as(998);  -- the new player

select throws_ok(
  $$ select public.complete_profile('', 'Jones', 'london', 'winger', 'left') $$,
  'name_required', 'a first name is required'
);
select throws_ok(
  $$ select public.complete_profile('Mali', 'Jones', 'atlantis', 'winger', 'left') $$,
  'city_not_found', 'the town must exist'
);
select lives_ok(
  $$ select public.complete_profile('Mali', 'Jones', 'london', 'winger', 'left') $$,
  'the profile can be completed'
);
select results_eq(
  $$ select first_name, city_id, position::text, foot::text, age_confirmed_at is not null, conduct_agreed_at is not null
     from public.profiles where id = '00000000-0000-4000-a000-000000000998' $$,
  $$ values ('Mali', 'london', 'winger', 'left', true, true) $$,
  'profile saved with both consents stamped'
);
select throws_ok(
  $$ update public.profiles set age_confirmed_at = null where id = '00000000-0000-4000-a000-000000000998' $$,
  '42501', null,
  'players cannot change their consent stamps directly'
);
select is(public.my_reliability(), 100, 'a new player starts 100% reliable');

-- ---- Safety -----------------------------------------------------------------
select tests.act_as(1);
select throws_ok($$ select public.report_player(tests.user_id(1), 'abuse') $$,
  'cannot_report_self', 'you cannot report yourself');
select lives_ok(
  $$ select public.report_player(tests.user_id(102), 'unsafe_play', 'Late tackles all game', tests.game_id(100)) $$,
  'a player can report another player'
);
select is_empty($$ select * from public.reports $$,
  'players cannot read reports, not even their own');
select throws_ok(
  $$ insert into public.reports (reporter_id, reported_id, reason) values (tests.user_id(1), tests.user_id(103), 'other') $$,
  '42501', null, 'reports go through report_player only'
);

select lives_ok($$ select public.block_player(tests.user_id(111)) $$, 'a player can block someone');
select is(
  (select count(*)::integer from public.recommended_games(20) where organiser_id = tests.user_id(111)),
  0, 'games run by a blocked organiser are not recommended'
);
select results_eq($$ select first_name from public.my_blocked_players() $$, $$ values ('Alex') $$,
  'blocked list shows the player');
select lives_ok($$ select public.unblock_player(tests.user_id(111)) $$, 'a player can unblock');
select is_empty($$ select * from public.my_blocked_players() $$, 'unblocking removes them');

select * from finish();
rollback;
