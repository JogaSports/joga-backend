# Data model

```mermaid
erDiagram
  cities ||--o{ venues : has
  venues ||--o{ games : hosts
  profiles ||--o{ games : organises
  games ||--o{ space_holds : "held while paying"
  games ||--o{ bookings : has
  games ||--o{ waitlist : has
  profiles ||--o{ bookings : makes
  profiles ||--o{ wallet_ledger : "credit in/out"
  bookings ||--o{ wallet_ledger : "paid or refunded by"
  games ||--o{ match_lines : "one per player"
  games ||--|| match_results : "score + POTM"
  profiles ||--o{ match_lines : plays
  reward_rules ||--o{ player_rewards : awards
  profiles ||--o{ player_rewards : earns
  profiles ||--o| memberships : "Joga+"
  profiles ||--o{ streak_freezes : uses
  profiles ||--o{ referrals : refers
  profiles ||--o{ reports : "reports / is reported"
  profiles ||--o{ blocks : "blocks"
```

| Table | What it holds | Written by |
|---|---|---|
| `app_settings` | Booking fee, hold length, cancellation window, referral reward, timezone | Admin |
| `cities` | Cardiff, Swansea, Newport, Wrexham (in Wales) and Bristol | Admin / migration |
| `venues` | Name, city, address, surface, parking, photo, facilities (step-free, defibrillator, first aid…) | Admin |
| `profiles` | One per user: name, city, position, preferred foot, role, referral code, when they confirmed 18+ and agreed to the code of conduct | Sign-up trigger, `complete_profile`; player edits safe fields |
| `games` | Sport, format, venue, time, tags (beginner, womens, mixed, walking, casual), price, capacity, venue cost, organiser | Admin |
| `space_holds` | A space held for 5 minutes while paying | `hold_space` |
| `bookings` | Who's booked, what they paid (wallet + card), cancellation and refund state | Booking functions, Stripe webhook |
| `waitlist` | Players waiting for a full game | `join_waitlist` |
| `wallet_ledger` | Append-only credit movements; balance = sum | Booking, reward and referral functions |
| `memberships` | Joga+ status and period end | RevenueCat webhook |
| `match_lines` | Per player per game: team, attended, goals, assists | `submit_match` |
| `match_results` | Score, player of the match, who submitted | `submit_match` |
| `reward_rules` | Milestones: games played, streak weeks, POTM awards, with credit amounts | Admin |
| `player_rewards` | Which milestones each player has earned (never paid twice) | `submit_match` |
| `streak_freezes` | Weeks protected by a Joga+ streak freeze | `use_streak_freeze` |
| `referrals` | Who referred whom and whether it's paid out | Sign-up trigger, `submit_match` |
| `reports` | A player reporting another: reason, details, optional game, review status | `report_player`; admins review |
| `blocks` | Who has blocked whom | `block_player`, `unblock_player` |

## Rules worth knowing

- **Spaces taken** = confirmed bookings + holds that haven't expired.
- **Weekly streak**: at least one attended game per week (Monday to Sunday,
  UK time). A streak freeze counts as a played week.
- **Seasons** run from 1 August.
- **Refunds** return the game price to the wallet; the £1 booking fee isn't
  refunded. Free cancellation until 24 hours before kick-off; after that,
  only if someone else takes the space.
- **Rewards** are checked for every player after each result is submitted.
  Joga+ members get the `member_credit_pence` amount.
- **Recreational only**: there are no ability levels. "Beginner-friendly"
  is a tag for games that suit people new to playing or coming back.
- **Profile set-up**: a profile with no `age_confirmed_at` hasn't finished
  sign-up; the app shows the set-up screens until `complete_profile` runs.
- **Reports** can't be read by players, not even their own, so nobody can
  find out who reported them.
- **Impact dashboard** (`impact_dashboard`) only returns totals; no player
  ids or names. The "women" figure is the share of active players who played
  in a women's game; gender is not collected.
