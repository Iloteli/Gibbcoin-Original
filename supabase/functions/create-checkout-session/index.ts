import { createClient } from "@supabase/supabase-js";
import Stripe from "stripe";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const packs = {
  small: { coins: 100, amount: 100, name: "100 GIBB Coins" },
  medium: { coins: 300, amount: 300, name: "300 GIBB Coins" },
  large: { coins: 750, amount: 750, name: "750 GIBB Coins" },
} as const;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers: corsHeaders });

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new Error("not_authenticated");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authorization } } },
    );
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) throw new Error("not_authenticated");

    const body = await request.json() as { pack_id?: keyof typeof packs; gibb?: number };
    // Neu: Kauf zum aktuellen Marktkurs ({ gibb: n }). Alte feste Pakete ({ pack_id }) bleiben möglich.
    let pack: { coins: number; amount: number; name: string } | undefined;
    let mode: "market" | "pack" = "pack";
    let packId = body.pack_id;
    if (typeof body.gibb === "number") {
      const gibb = Math.floor(body.gibb);
      if (!(gibb >= 1 && gibb <= 1000)) throw new Error("invalid_pack");
      const { data: quote, error: quoteError } = await supabase.rpc("market_quote", { p_gibb: gibb });
      const q = quote as { ok?: boolean; buy_rappen?: number; buy_possible?: boolean; enabled?: boolean } | null;
      if (quoteError || !q?.ok || !q.enabled || !q.buy_possible) throw new Error("invalid_pack");
      const amount = Math.ceil(Number(q.buy_rappen));
      if (!(amount >= 50)) throw new Error("amount_too_small");
      pack = { coins: gibb, amount, name: `${gibb} GIBB Coins (Marktkurs)` };
      mode = "market";
      packId = undefined;
    } else {
      pack = packId ? packs[packId] : undefined;
    }
    if (!pack) throw new Error("invalid_pack");

    const secretKey = Deno.env.get("STRIPE_SECRET_KEY")?.trim();
    const appUrl = Deno.env.get("APP_URL")?.trim();
    const purchasesEnabled = Deno.env.get("COIN_PURCHASES_ENABLED")?.trim().toLowerCase() === "true";
    if (!purchasesEnabled) throw new Error("purchases_disabled");
    if (!secretKey || !appUrl) throw new Error("payment_not_configured");
    if (!appUrl.startsWith("https://")) throw new Error("payment_not_configured");

    console.log(JSON.stringify({
      event: "checkout_configuration",
      stripeConfigured: true,
      stripeMode: secretKey.startsWith("sk_test_") ? "test" : secretKey.startsWith("sk_live_") ? "live" : "unknown",
      appUrlConfigured: true,
    }));

    const stripe = new Stripe(secretKey, { httpClient: Stripe.createFetchHttpClient() });
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      payment_method_types: ["card", "twint"],
      client_reference_id: user.id,
      customer_email: user.email,
      line_items: [{
        quantity: 1,
        price_data: {
          currency: "chf",
          unit_amount: pack.amount,
          product_data: { name: pack.name, description: "Interne GIBB-Schulcoins; keine Auszahlung möglich" },
        },
      }],
      metadata: mode === "market"
        ? { user_id: user.id, mode: "market", gibb_coins: String(pack.coins), quoted_rappen: String(pack.amount) }
        : { user_id: user.id, pack_id: packId!, gibb_coins: String(pack.coins) },
      success_url: `${appUrl.replace(/\/$/, "")}/?purchase=success&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${appUrl.replace(/\/$/, "")}/?purchase=cancelled`,
    });

    if (!session.url || !session.url.startsWith("https://")) throw new Error("invalid_checkout_url");
    return new Response(JSON.stringify({ url: session.url }), { status: 200, headers: corsHeaders });
  } catch (error) {
    const code = error instanceof Error ? error.message : "checkout_failed";
    const status = code === "not_authenticated" ? 401
      : code === "invalid_pack" || code === "amount_too_small" ? 400
        : code === "purchases_disabled" ? 403
          : 500;
    const details = error && typeof error === "object" ? error as Record<string, unknown> : {};
    const stripeType = typeof details.type === "string" ? details.type : "";
    const publicCode = code === "not_authenticated" || code === "invalid_pack"
      || code === "payment_not_configured" || code === "purchases_disabled"
      || code === "invalid_checkout_url"
      ? code
      : stripeType === "StripeAuthenticationError"
        ? "stripe_authentication_error"
        : stripeType === "StripeInvalidRequestError"
          ? "stripe_invalid_request_error"
          : "checkout_failed";
    console.error(JSON.stringify({
      event: "checkout_failed",
      publicCode,
      errorName: error instanceof Error ? error.name : "UnknownError",
      errorType: stripeType || undefined,
      stripeCode: typeof details.code === "string" ? details.code : undefined,
      stripeParam: typeof details.param === "string" ? details.param : undefined,
      stripeConfigured: Boolean(Deno.env.get("STRIPE_SECRET_KEY")?.trim()),
      appUrlConfigured: Boolean(Deno.env.get("APP_URL")?.trim()),
    }));
    return new Response(JSON.stringify({ error: publicCode }), { status, headers: corsHeaders });
  }
});
