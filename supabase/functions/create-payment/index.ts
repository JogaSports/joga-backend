// Creates a Stripe PaymentIntent for the card part of a booking.
//
// Flow (see docs/API.md):
//   1. App calls rpc('hold_space')            -> hold
//   2. App calls this function with the hold  -> clientSecret
//   3. App shows the Stripe Payment Sheet
//   4. stripe-webhook confirms the booking when payment succeeds
//
// If wallet credit covers everything, this returns { paymentRequired: false }
// and the app calls rpc('confirm_booking_with_wallet') instead.
import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { errorResponse } from "../_shared/http.ts";
import { stripe } from "../_shared/stripe.ts";

type RequestBody = { holdId?: string; useWallet?: boolean };

type Quote = {
  game_pence: number;
  fee_pence: number;
  wallet_applied_pence: number;
  total_pence: number;
};

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    if (req.method !== "POST") {
      return errorResponse(405, "method_not_allowed", "Use POST.");
    }

    const body = (await req.json().catch(() => ({}))) as RequestBody;
    const holdId = body.holdId;
    const useWallet = body.useWallet ?? true;
    if (!holdId) {
      return errorResponse(400, "invalid_request", "holdId is required.");
    }

    const playerId = ctx.userClaims?.id;
    if (!playerId) {
      return errorResponse(401, "not_authenticated", "Sign in to continue.");
    }

    // RLS means players can only read their own holds.
    const { data: hold, error: holdError } = await ctx.supabase
      .from("space_holds")
      .select("id, game_id, expires_at")
      .eq("id", holdId)
      .maybeSingle();

    if (holdError) {
      console.error("create-payment: hold lookup failed", holdError);
      return errorResponse(500, "server_error", "Something went wrong. Please try again.");
    }
    if (!hold || new Date(hold.expires_at) <= new Date()) {
      return errorResponse(
        409,
        "hold_not_found",
        "Your hold on this space has ended. Please try again.",
      );
    }

    // Price comes from the database, never from the app.
    const { data: quote, error: quoteError } = await ctx.supabase
      .rpc("booking_quote", { p_game: hold.game_id, p_use_wallet: useWallet })
      .single<Quote>();

    if (quoteError || !quote) {
      console.error("create-payment: quote failed", quoteError);
      return errorResponse(500, "server_error", "Something went wrong. Please try again.");
    }

    if (quote.total_pence === 0) {
      return Response.json({ paymentRequired: false, walletPence: quote.wallet_applied_pence });
    }

    const intent = await stripe.paymentIntents.create(
      {
        amount: quote.total_pence,
        currency: "gbp",
        automatic_payment_methods: { enabled: true },
        description: "Joga Sports game booking",
        metadata: {
          hold_id: hold.id,
          game_id: hold.game_id,
          player_id: playerId,
          wallet_pence: String(quote.wallet_applied_pence),
          card_pence: String(quote.total_pence),
        },
      },
      {
        // Same hold and amounts -> same PaymentIntent, so retries are safe.
        idempotencyKey: `booking-${hold.id}-${quote.total_pence}-${quote.wallet_applied_pence}`,
      },
    );

    return Response.json({
      paymentRequired: true,
      clientSecret: intent.client_secret,
      amountPence: quote.total_pence,
      walletPence: quote.wallet_applied_pence,
    });
  }),
};
