import { createClient } from "@supabase/supabase-js";
import Stripe from "stripe";

const packs = {
  small: { coins: 100, amount: 100 },
  medium: { coins: 300, amount: 300 },
  large: { coins: 750, amount: 750 },
} as const;

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secretKey = Deno.env.get("STRIPE_SECRET_KEY");
  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secretKey || !webhookSecret) return new Response("Webhook not configured", { status: 500 });

  const signature = request.headers.get("stripe-signature");
  if (!signature) return new Response("Missing signature", { status: 400 });

  const stripe = new Stripe(secretKey, { httpClient: Stripe.createFetchHttpClient() });
  let event: Stripe.Event;
  try {
    const rawBody = await request.text();
    event = await stripe.webhooks.constructEventAsync(
      rawBody,
      signature,
      webhookSecret,
      undefined,
      Stripe.createSubtleCryptoProvider(),
    );
  } catch {
    return new Response("Invalid signature", { status: 400 });
  }

  if (event.type !== "checkout.session.completed" && event.type !== "checkout.session.async_payment_succeeded") {
    return new Response("ok", { status: 200 });
  }

  try {
    const received = event.data.object as Stripe.Checkout.Session;
    const session = await stripe.checkout.sessions.retrieve(received.id);
    if (session.payment_status !== "paid") return new Response("ok", { status: 200 });

    const userId = session.client_reference_id;
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    // Kauf zum Marktkurs: bezahlter Betrag muss dem beim Checkout berechneten Angebot entsprechen.
    if (session.metadata?.mode === "market") {
      const coins = Number(session.metadata.gibb_coins);
      const quoted = Number(session.metadata.quoted_rappen);
      if (!userId || session.currency !== "chf" || !Number.isInteger(coins) || coins < 1 || session.amount_total !== quoted) {
        return new Response("Invalid checkout data", { status: 400 });
      }
      const { error: marketError } = await admin.rpc("credit_market_purchase", {
        stripe_event: event.id,
        checkout_session: session.id,
        payment_intent: typeof session.payment_intent === "string" ? session.payment_intent : null,
        purchased_user: userId,
        purchased_coins: coins,
        paid_amount: quoted,
        paid_currency: "chf",
      });
      if (marketError) throw marketError;
      return new Response("ok", { status: 200 });
    }

    const packId = session.metadata?.pack_id as keyof typeof packs | undefined;
    const pack = packId ? packs[packId] : undefined;
    if (!pack || !userId || session.currency !== "chf" || session.amount_total !== pack.amount) {
      return new Response("Invalid checkout data", { status: 400 });
    }
    const { error } = await admin.rpc("credit_gibb_purchase", {
      stripe_event: event.id,
      checkout_session: session.id,
      payment_intent: typeof session.payment_intent === "string" ? session.payment_intent : null,
      purchased_user: userId,
      purchased_coins: pack.coins,
      paid_amount: pack.amount,
      paid_currency: "chf",
    });
    if (error) throw error;
    return new Response("ok", { status: 200 });
  } catch {
    // 500 veranlasst Stripe zu einem späteren, sicheren Retry.
    return new Response("Fulfillment failed", { status: 500 });
  }
});
