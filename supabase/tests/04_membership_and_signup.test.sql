begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

-- Not a member yet
select tests.act_as(1);
select is(public.is_member(), false, 'Ray starts without Joga+');
select throws_ok($$ select * from public.my_member_stats() $$, 'members_only',
  'deeper stats are for members');
select throws_ok($$ select public.use_streak_freeze() $$, 'members_only',
  'streak freezes are for members');

-- RevenueCat webhook makes Ray a member
select tests.act_as_owner();
insert into public.memberships (player_id, status, source, current_period_end)
values (tests.user_id(1), 'active', 'app_store', now() + interval '30 days');

select tests.act_as(1);
select is(public.is_member(), true, 'Ray is a member');
select is((select fee_pence from public.booking_quote(tests.game_id(101))), 0, 'members pay no booking fee');
select isnt_empty($$ select * from public.my_member_stats() $$, 'members get deeper stats');
select lives_ok($$ select public.use_streak_freeze() $$, 'a member can freeze this week');
select throws_ok($$ select public.use_streak_freeze() $$, 'no_freezes_left', 'one freeze a month');

-- Sign-up with a referral code
select tests.act_as_owner();
insert into auth.users (id, email, raw_user_meta_data)
values ('00000000-0000-4000-a000-000000000999', 'new.player@joga.demo',
        '{"full_name": "Nia Roberts", "city_id": "cardiff", "referral_code": "ray24"}');

select results_eq(
  $$ select first_name, last_name, city_id, referred_by
     from public.profiles where id = '00000000-0000-4000-a000-000000000999' $$,
  $$ values ('Nia', 'Roberts', 'cardiff', tests.user_id(1)) $$,
  'sign-up creates a profile and records the referral'
);
select is(
  (select sum(amount_pence)::integer from public.wallet_ledger
   where player_id = '00000000-0000-4000-a000-000000000999'),
  200, 'referred players get £2 welcome credit'
);

select * from finish();
rollback;
