# API for the app

Everything the Flutter app calls, and which app repository uses it. The app
uses `supabase_flutter` with the project URL and **publishable** key.

- **Reads**: `supabase.from('<table or view>').select()` (row-level security
  decides what each player sees).
- **Actions**: `supabase.rpc('<function>', params: {...})`.
- **Payments**: `supabase.functions.invoke('create-payment', body: {...})`.

All functions need a signed-in user unless noted.

## Errors

Database functions raise a stable **code** as the error message and a human
sentence as the detail. In Dart:

```dart
try {
  await supabase.rpc('hold_space', params: {'p_game': gameId});
} on PostgrestException catch (e) {
  // e.message == 'game_full', e.details == 'This game is full. Join the waitlist instead.'
}
```

| Code | When |
|---|---|
| `not_authenticated` | No signed-in user |
| `game_not_found` | Game doesn't exist |
| `game_not_bookable` | Game cancelled, completed or already started |
| `game_full` | No spaces left (confirmed bookings + live holds) |
| `already_booked` | Player is already on this game |
| `hold_not_found` | Hold expired or doesn't belong to the player |
| `payment_required` | Wallet doesn't cover it; use `create-payment` |
| `amount_mismatch` | Payment amounts don't add up to price + fee |
| `insufficient_wallet` | Not enough credit |
| `booking_not_found` | Cancelling a game the player isn't booked on |
| `game_started` | Too late to cancel |
| `not_organiser` | Only the game's organiser (or an admin) can submit |
| `game_not_started` | Results before kick-off |
| `game_cancelled` | Result for a cancelled game |
| `invalid_lines` / `player_not_booked` / `potm_not_in_game` | Bad match sheet |
| `members_only` | Joga+ feature |
| `no_freezes_left` | Streak freeze already used this month |
| `invalid_metric` | Leaderboard metric not recognised |
| `admins_only` | Admin data |
| `organiser_has_games` / `has_upcoming_bookings` | Account deletion blocked |

## Games — `GamesRepository`

### `game_listing` (view)

Games with venue, organiser and live spaces. Columns: `id, sport, format,
venue_id, venue_name, city_id, city_name, address, surface, parking,
photo_url, pitch, starts_at, duration_minutes, level, tags, price_pence,
capacity, booked, spaces_left, organiser_id, organiser_first_name,
organiser_last_initial, organiser_games_run, status`.

```dart
// Find screen
supabase.from('game_listing').select()
  .eq('city_id', 'cardiff')
  .eq('status', 'scheduled')
  .gt('starts_at', DateTime.now().toIso8601String())
  .eq('format', 'five_a_side')        // optional filters
  .contains('tags', ['over_30s'])
  .lte('price_pence', 699)
  .order('starts_at');
```

| Function | Returns | Used for |
|---|---|---|
| `recommended_games(p_limit = 3)` | `game_listing` rows | Home "For you": player's city, level or casual, not full, not booked |
| `my_upcoming_games()` | `game_listing` rows | My Games upcoming, Home next game |
| `game_players(p_game)` | `player_id, first_name, last_initial, avatar_url` | Who's playing (details, game day) |
| `booked_count(p_game)` | integer | Spaces taken, including live holds |

## Booking — `BookingRepository`

| Function | Returns | Notes |
|---|---|---|
| `booking_quote(p_game, p_use_wallet = true)` | `game_pence, fee_pence, subtotal_pence, wallet_available_pence, wallet_applied_pence, total_pence, is_member` | Price breakdown. Fee is 0 for Joga+ |
| `hold_space(p_game)` | `space_holds` row (`id`, `expires_at`) | Locks the game; holds a space for 5 minutes |
| `confirm_booking_with_wallet(p_hold)` | `bookings` row | When `total_pence` is 0 |
| `cancel_booking(p_game)` | `'refunded'` or `'refund_if_filled'` | Refunds go to the wallet |
| `join_waitlist(p_game)` / `leave_waitlist(p_game)` | – | After test |

### Edge function `create-payment`

Signed-in user. `POST { "holdId": uuid, "useWallet": true }`

```json
{ "paymentRequired": true, "clientSecret": "pi_..._secret_...", "amountPence": 150, "walletPence": 750 }
```

or `{ "paymentRequired": false, "walletPence": 900 }` → call
`confirm_booking_with_wallet`.

Show the Stripe Payment Sheet with `clientSecret`. When payment succeeds,
the `stripe-webhook` function confirms the booking; the app sees it arrive
through realtime on `bookings` (or re-fetches). If the space was lost while
paying, the payment is refunded automatically.

Errors: `{ "error": "hold_not_found", "message": "..." }` with HTTP 409.

## Player — `PlayerRepository`

| Call | Returns | Used for |
|---|---|---|
| `from('profiles').select().eq('id', uid)` | profile | Current player. Players can update `first_name, last_name, city_id, level, position, avatar_url` |
| `is_member()` | boolean | Joga+ status |
| `player_stats(p_player, p_period)` | `games, goals, assists, potm, wins` | `p_period`: `career`, `season` (from 1 Aug), `month` |
| `my_form(p_limit = 10)` | `game_id, starts_at, goals, assists, won` oldest first | Form chart |
| `my_streak()` | `current_weeks, best_weeks, played_this_week, last_12, week_ends_at, freezes_left, next_reward_weeks, next_reward_pence` | Streak, Home nudge |
| `use_streak_freeze()` | – | Joga+ |
| `my_member_stats()` | `city_rank, best_venue, involvements_per_game, potm_rate_percent` | Joga+ deeper stats |
| `delete_my_account()` | – | Required by Apple |

**Post-game** for a game: `match_results` (score, `potm_id`) +
`match_lines` for the player (team, goals, assists) + `player_rewards`
with that `game_id` + `wallet_ledger` entries with that `game_id` +
`my_streak()`.

**Home summary**: `player_stats(uid, 'season')` + `my_streak()` +
`my_upcoming_games()` + `recommended_games()`.

## Match control — `MatchRepository`

| Call | Notes |
|---|---|
| `game_players(p_game)` | Build the sheet; split teams in the app |
| `submit_match(p_game, p_lines, p_potm)` | Organiser or admin, after kick-off. Updates stats, streaks, rewards, referrals. Resubmitting corrects without paying rewards twice |

```json
p_lines = [
  { "player_id": "…", "team": "white", "attended": true, "goals": 2, "assists": 1 },
  { "player_id": "…", "team": "orange", "attended": false }
]
```

## Wallet — `WalletRepository`

`from('wallet_ledger').select().order('created_at', ascending: false)`
— the player's entries only. Balance = sum of `amount_pence`.
Milestone progress: `reward_rules` + `player_rewards` + `player_stats`.

## Compete — `CompeteRepository` (after test)

| Call | Notes |
|---|---|
| `leaderboard(p_city, p_metric, p_month = null, p_limit = 50)` | `rank, player_id, first_name, last_initial, value, is_me`. Metrics: `goals`, `assists`, `potm`, `streak` |
| `from('profiles').select('referral_code')` + `from('referrals')` | Code and referral progress |

Referral codes are applied at sign-up by passing `referral_code` in the
user metadata: `supabase.auth.signUp(..., data: {'referral_code': 'RAY24'})`.

## Membership — `MembershipRepository`

Purchases go through RevenueCat (App Store, Google Play, Stripe on web).
Set the RevenueCat app user id to the Supabase user id. The
`revenuecat-webhook` function updates `memberships`; the app reads
`is_member()` or listens on `memberships`.

## Admin — `AdminRepository`

`admin_games(p_from = now - 1 day, p_to = now + 7 days)`: `game_id,
starts_at, venue_name, city_id, format, booked, capacity, revenue_pence,
venue_cost_pence, margin_pence, status, result_outstanding`. Admins also
manage `games`, `venues`, `cities`, `reward_rules` and `app_settings`
directly (row-level security allows admins only).

## Sign-in — `AuthRepository`

Supabase Auth with Apple, Google and email. Sign-up metadata the database
reads: `first_name`, `last_name` (or `full_name`), `city_id`,
`referral_code`. A profile is created automatically.

## Realtime — `AppServices.changes`

Published tables: `games`, `bookings`, `match_results`, `wallet_ledger`,
`memberships`. RLS applies, so each player only receives their own
bookings, wallet entries and membership.

## Demo ids (local seed)

Match the app's `FakeSeed` so screens can switch from fake to real data:

| App | Database |
|---|---|
| Ray `p-ray` | `00000000-0000-4000-a000-000000000001` |
| Dan (organiser) | `…000000000002` |
| Tonight's game `g-100` | `20000000-0000-4000-a000-000000000100` |
| Last-space game `g-101` | `20000000-0000-4000-a000-000000000101` |
| Full game `g-104` | `20000000-0000-4000-a000-000000000104` |
| Last played game `g-099` | `20000000-0000-4000-a000-000000000001` |
