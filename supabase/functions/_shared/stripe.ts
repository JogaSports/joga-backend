import Stripe from "stripe";
import { requireEnv } from "./http.ts";

/** Stripe client configured for the Deno edge runtime. */
export const stripe = new Stripe(requireEnv("STRIPE_SECRET_KEY"), {
  httpClient: Stripe.createFetchHttpClient(),
});

/** Needed to verify webhook signatures with Web Crypto. */
export const cryptoProvider = Stripe.createSubtleCryptoProvider();

export type { Stripe };
