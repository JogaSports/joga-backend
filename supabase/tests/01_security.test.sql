begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- Every public table has row-level security on.
select is(
  (select count(*)::integer from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'every public table has RLS enabled'
);

-- Anonymous visitors can't call the booking API.
set local role anon;
select throws_ok(
  $$ select public.hold_space(tests.game_id(101)) $$,
  '42501', null,
  'anon cannot hold a space'
);
reset role;

select tests.act_as(1);  -- Ray

select is((select count(*)::integer from public.wallet_ledger where player_id <> tests.user_id(1)), 0,
  'players cannot see other wallets');

select is((select count(*)::integer from public.bookings where player_id <> tests.user_id(1)), 0,
  'players cannot see other players'' bookings');

select throws_ok(
  $$ insert into public.bookings (game_id, player_id, price_pence, card_pence)
     values (tests.game_id(101), tests.user_id(1), 800, 800) $$,
  '42501', null,
  'players cannot insert bookings directly'
);

select throws_ok(
  $$ insert into public.wallet_ledger (player_id, type, amount_pence, label)
     values (tests.user_id(1), 'top_up', 10000, 'free money') $$,
  '42501', null,
  'players cannot write to their wallet'
);

select throws_ok(
  $$ update public.profiles set role = 'admin' where id = tests.user_id(1) $$,
  '42501', null,
  'players cannot make themselves admin'
);

select lives_ok(
  $$ update public.profiles set position = 'Striker' where id = tests.user_id(1) $$,
  'players can edit their own profile'
);

update public.profiles set first_name = 'Hacked' where id = tests.user_id(2);
select tests.act_as_owner();
select is((select first_name from public.profiles where id = tests.user_id(2)), 'Dan',
  'players cannot edit someone else''s profile');

select tests.act_as(1);
select throws_ok(
  $$ select private.wallet_balance(tests.user_id(2)) $$,
  '42501', null,
  'the private schema is not reachable'
);

select throws_ok(
  $$ select public.confirm_paid_booking(gen_random_uuid(), tests.user_id(1), 0, 900, 'pi_fake') $$,
  '42501', null,
  'players cannot confirm a paid booking themselves'
);

select throws_ok(
  $$ select * from public.admin_games() $$,
  'admins_only',
  'admin data is admins only'
);

select * from finish();
rollback;
