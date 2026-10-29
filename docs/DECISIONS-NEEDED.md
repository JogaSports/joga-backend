# Decisions needed

Product questions the backend is waiting on. Each one says what works
today, what the options are, and what it would take to build.

## 1. Money in Nairobi and Tbilisi

**Today:** every game has a price in its city's currency (GBP in Bristol,
London and Cardiff; KES in Nairobi; GEL in Tbilisi). But three other amounts
have no currency and are treated as pence everywhere:

| Amount | Today | In Nairobi it would mean |
|---|---|---|
| Booking fee (`app_settings.booking_fee_pence`) | 100 = £1 | 100 Kenyan cents = KSh 1 |
| Rewards (`reward_rules.credit_pence`) | 100 = £1 credit | KSh 1 credit |
| Wallet balance | One number per player | Mixes pounds and shillings if a player plays in two countries |

That's harmless while payments are on hold, but it must be settled before
anyone in Nairobi or Tbilisi pays for a game or earns credit.

**Options:**

| Option | How it works | Work |
|---|---|---|
| A. Per-city amounts, wallet per currency | Each city sets its own booking fee and reward amounts; each player has a wallet balance per currency | Medium: new columns, wallet split by currency, booking checks the game's currency |
| B. Rewards as free games, not money | Milestones give "1 free game" instead of £ credit; no cross-currency maths | Medium: rewards become vouchers |
| C. GBP everywhere, convert for display | Store all prices in GBP and show local amounts at a set rate | Small to build, but prices drift with exchange rates and local organisers think in local money |

**Recommendation:** A, decided together with how bookings are paid (cash at
the venue, card in app, or mobile money such as M-Pesa in Nairobi), because
the payment method decides which currencies the app actually handles.

## 2. How bookings are paid

**Today:** card payments (Stripe) are built but switched off. Bookings work
when wallet credit covers the whole price.

**Options:** pay in app by card (Stripe, ready to switch on for UK cities);
pay at the venue (the app just reserves the space); mobile money in Nairobi
(M-Pesa, via a provider such as Flutterwave or Paystack); or a mix per city.

## 3. Weekly streaks outside the UK

**Today:** a streak week runs Monday to Sunday on UK time. For a Nairobi or
Tbilisi player, the week ends 2 to 4 hours after their local midnight on
Sunday. Only a game that kicks off in those hours would land in the wrong
week.

**Options:** leave it (rarely matters), or run streaks and personal stats on
each player's home-city clock (small: the streak and stats functions take
the player's city timezone).
