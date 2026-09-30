begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

-- Game 101: 9 of 10 booked. Ray (1) has £7.50 of wallet credit.
select tests.act_as(1);

select results_eq(
  $$ select game_pence, fee_pence, wallet_applied_pence, total_pence
     from public.booking_quote(tests.game_id(101)) $$,
  $$ values (800, 100, 750, 150) $$,
  'quote: £8 game + £1 fee, £7.50 wallet, £1.50 to pay'
);

select lives_ok($$ select public.hold_space(tests.game_id(101)) $$, 'Ray holds the last space');
select is(public.booked_count(tests.game_id(101)), 10, 'the hold counts as taken');

-- Someone else can't take the held space.
select tests.act_as(104);
select throws_ok($$ select public.hold_space(tests.game_id(101)) $$, 'game_full',
  'a held last space cannot be taken by someone else');

-- Wallet doesn't cover it all, so a card payment is required.
select tests.act_as(1);
select throws_ok(
  $$ select public.confirm_booking_with_wallet(
       (select id from public.space_holds where game_id = tests.game_id(101))) $$,
  'payment_required',
  'wallet-only confirmation needs the full amount in credit'
);

-- The Stripe webhook confirms the card payment.
create temporary table held as
  select id from public.space_holds where game_id = tests.game_id(101);
grant select on held to service_role;
select tests.act_as_service();

select throws_ok(
  $$ select public.confirm_paid_booking((select id from held), tests.user_id(1), 750, 100, 'pi_test_1') $$,
  'amount_mismatch',
  'amounts that don''t add up are rejected'
);

select lives_ok(
  $$ select public.confirm_paid_booking((select id from held), tests.user_id(1), 750, 150, 'pi_test_1') $$,
  'webhook confirms the booking'
);
select is(
  (select count(*)::integer from public.bookings where stripe_payment_intent_id = 'pi_test_1'),
  1, 'one booking created'
);
select lives_ok(
  $$ select public.confirm_paid_booking((select id from held), tests.user_id(1), 750, 150, 'pi_test_1') $$,
  'a repeated webhook is harmless'
);
select is(
  (select count(*)::integer from public.bookings where stripe_payment_intent_id = 'pi_test_1'),
  1, 'still one booking after a repeated webhook'
);

select tests.act_as(1);
select is((select sum(amount_pence)::integer from public.wallet_ledger), 0, 'wallet credit was used');
select is(public.booked_count(tests.game_id(101)), 10, 'game is now full');
select throws_ok($$ select public.hold_space(tests.game_id(101)) $$, 'already_booked',
  'cannot book the same game twice');

-- Cancelling 5 days ahead refunds the game price (not the fee) to the wallet.
select is(public.cancel_booking(tests.game_id(108)), 'refunded', 'early cancellation is refunded');
select is((select sum(amount_pence)::integer from public.wallet_ledger), 600, '£6 back in the wallet');

-- Cancelling tonight's game: refunded only if someone takes the space.
select is(public.cancel_booking(tests.game_id(100)), 'refund_if_filled', 'late cancellation waits for a replacement');

select tests.act_as(112);  -- Matt takes the space, paying by card
select public.hold_space(tests.game_id(100));
select tests.act_as_owner();
select public.confirm_paid_booking(
  (select id from public.space_holds where game_id = tests.game_id(100) and player_id = tests.user_id(112)),
  tests.user_id(112), 0, 900, 'pi_test_2');

select is(
  (select sum(amount_pence)::integer from public.wallet_ledger where player_id = tests.user_id(1)),
  1400, 'Ray is refunded £8 once his space is filled'
);

select * from finish();
rollback;
