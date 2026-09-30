-- Shared helpers for the database tests: act as a seeded user.
-- Runs first (files run in name order) and is safe to re-run.
begin;
create extension if not exists pgtap with schema extensions;
select plan(1);

create schema if not exists tests;
grant usage on schema tests to anon, authenticated, service_role;

-- Seed ids (see supabase/seed.sql)
create or replace function tests.user_id(n integer) returns uuid
language sql immutable as $$
  select ('00000000-0000-4000-a000-' || lpad(n::text, 12, '0'))::uuid
$$;
create or replace function tests.game_id(n integer) returns uuid
language sql immutable as $$
  select ('20000000-0000-4000-a000-' || lpad(n::text, 12, '0'))::uuid
$$;

-- Switch to a signed-in user for the rest of the transaction.
create or replace function tests.act_as(n integer) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.user_id(n), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', tests.user_id(n)::text, true);
  execute 'set local role authenticated';
end;
$$;

-- Back to the test owner (bypasses RLS) for setting up fixtures.
create or replace function tests.act_as_owner() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end;
$$;

-- Act as the server (secret key), e.g. the Stripe webhook.
create or replace function tests.act_as_service() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role service_role';
end;
$$;

grant execute on all functions in schema tests to anon, authenticated, service_role;

select pass('test helpers installed');
select * from finish();
commit;
