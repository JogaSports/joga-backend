// Stripe webhook. Confirms bookings when a card payment succeeds.
//
// Stripe can't send Supabase keys, so this uses auth 'none' and verifies the
// Stripe signature instead. If the space was lost while paying (the hold
// lapsed and someone else booked), the payment is refunded automatically.
import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { errorResponse, requireEnv } from "../_shared/http.ts";
import { cryptoProvider, type Stripe, stripe } from "../_shared/stripe.ts";

const webhookSecret = requireEnv("STRIPE_WEBHOOK_SECRET");

// Database errors that mean "this booking can't happen": refund, don't retry.
const REFUND_ON = new Set([
  "game_full",
  "hold_not_found",
  "game_not_bookable",
  "already_booked",
  "amount_mismatch",
  "insufficient_wallet",
]);

export default {
  fetch: withSupabase({ auth: "none" }, async (req, ctx) => {
    const signature = req.headers.get("stripe-signature");
    if (!signature) {
      return errorResponse(400, "missing_signature", "Missing Stripe signature.");
    }

    let event: Stripe.Event;
    try {
      event = await stripe.webhooks.constructEventAsync(
        await req.text(),
        signature,
        webhookSecret,
        undefined,
        cryptoProvider,
      );
    } catch (err) {
      console.warn("stripe-webhook: invalid signature", err);
      return errorResponse(401, "invalid_signature", "Invalid signature.");
    }

    if (event.type !== "payment_intent.succeeded") {
      return Response.json({ received: true, ignored: event.type });
    }

    const intent = event.data.object as Stripe.PaymentIntent;
    const meta = intent.metadata;
    if (!meta.hold_id || !meta.player_id) {
      // Not a booking payment (e.g. created elsewhere in Stripe).
      return Response.json({ received: true, ignored: "not_a_booking" });
    }

    const { data: booking, error } = await ctx.supabaseAdmin.rpc("confirm_paid_booking", {
      p_hold: meta.hold_id,
      p_player: meta.player_id,
      p_wallet_pence: Number(meta.wallet_pence ?? 0),
      p_card_pence: intent.amount_received,
      p_payment_intent: intent.id,
    });

    if (!error) {
      return Response.json({ received: true, booking });
    }

    if (REFUND_ON.has(error.message)) {
      console.warn(`stripe-webhook: refunding ${intent.id} (${error.message})`);
      await stripe.refunds.create(
        {
          payment_intent: intent.id,
          reason: "requested_by_customer",
          metadata: { reason: error.message },
        },
        { idempotencyKey: `refund-${intent.id}` },
      );
      return Response.json({ received: true, refunded: error.message });
    }

    // Anything else is unexpected: return 500 so Stripe retries later.
    console.error("stripe-webhook: confirm failed", error);
    return errorResponse(500, "server_error", "Could not confirm booking.");
  }),
};
