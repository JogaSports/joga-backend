// RevenueCat webhook. Keeps public.memberships in sync with Joga+
// subscriptions bought through the App Store, Google Play or Stripe.
//
// Set the app's RevenueCat user id to the Supabase user id, and set the
// webhook's Authorization header in RevenueCat to the value of
// REVENUECAT_WEBHOOK_AUTH.
import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { errorResponse, requireEnv, safeEqual } from "../_shared/http.ts";

const expectedAuth = requireEnv("REVENUECAT_WEBHOOK_AUTH");

type RevenueCatEvent = {
  type: string;
  app_user_id: string;
  product_id?: string;
  store?: string;
  expiration_at_ms?: number | null;
};

const ACTIVE_EVENTS = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "UNCANCELLATION",
  "PRODUCT_CHANGE",
  "SUBSCRIPTION_EXTENDED",
  "TEMPORARY_ENTITLEMENT_GRANT",
  "NON_RENEWING_PURCHASE",
  // Cancelled but still paid up until the period ends.
  "CANCELLATION",
  "BILLING_ISSUE",
]);

const STORES: Record<string, string> = {
  APP_STORE: "app_store",
  MAC_APP_STORE: "app_store",
  PLAY_STORE: "play_store",
  STRIPE: "stripe",
  RC_BILLING: "stripe",
  PROMOTIONAL: "promotional",
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default {
  fetch: withSupabase({ auth: "none" }, async (req, ctx) => {
    const auth = req.headers.get("authorization") ?? "";
    if (!safeEqual(auth, expectedAuth) && !safeEqual(auth, `Bearer ${expectedAuth}`)) {
      return errorResponse(401, "unauthorised", "Invalid authorisation.");
    }

    const payload = (await req.json().catch(() => null)) as { event?: RevenueCatEvent } | null;
    const event = payload?.event;
    if (!event?.type) {
      return errorResponse(400, "invalid_request", "Missing event.");
    }
    if (event.type === "TEST") {
      return Response.json({ received: true, test: true });
    }
    if (!UUID.test(event.app_user_id ?? "")) {
      // Anonymous RevenueCat ids ($RCAnonymousID:...) can't be matched to a player.
      return Response.json({ received: true, ignored: "not_a_supabase_user" });
    }

    const isActive = ACTIVE_EVENTS.has(event.type);
    const isExpired = event.type === "EXPIRATION";
    if (!isActive && !isExpired) {
      return Response.json({ received: true, ignored: event.type });
    }

    const { error } = await ctx.supabaseAdmin.from("memberships").upsert({
      player_id: event.app_user_id,
      status: isExpired ? "expired" : "active",
      source: STORES[event.store ?? ""] ?? "promotional",
      product_id: event.product_id ?? null,
      current_period_end: event.expiration_at_ms
        ? new Date(event.expiration_at_ms).toISOString()
        : null,
      updated_at: new Date().toISOString(),
    });

    if (error) {
      console.error("revenuecat-webhook: upsert failed", error);
      return errorResponse(500, "server_error", "Could not update membership.");
    }
    return Response.json({ received: true });
  }),
};
