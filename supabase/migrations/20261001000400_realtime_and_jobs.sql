-- =============================================================================
-- Joga Sports · 04 · Realtime and scheduled jobs
-- =============================================================================

-- Realtime: the app listens for changes to these tables. RLS still applies,
-- so each player only receives their own bookings and wallet entries.
alter publication supabase_realtime add table
  public.games,
  public.bookings,
  public.match_results,
  public.wallet_ledger,
  public.memberships;

-- Scheduled jobs (pg_cron). Skipped where pg_cron isn't installed, such as
-- some CI databases.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;

    -- Every 5 minutes: clear holds that lapsed past the grace period.
    perform cron.schedule(
      'release-expired-holds',
      '*/5 * * * *',
      'select private.release_expired_holds()'
    );
  end if;
end;
$$;
