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

    const { pack_id: packId } = await request.json() as { pack_id?: keyof typeof packs };
    const pack = packId ? packs[packId] : undefined;
    if (!pack) throw new Error("invalid_pack");

    const secretKey = Deno.env.get("STRIPE_SECRET_KEY")?.trim();
    const appUrl = Deno.env.get("APP_URL")?.trim();
    if (!secretKey || !appUrl) throw new Error("payment_not_configured");

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
      metadata: { user_id: user.id, pack_id: packId!, gibb_coins: String(pack.coins) },
      success_url: `${appUrl.replace(/\/$/, "")}/?purchase=success&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${appUrl.replace(/\/$/, "")}/?purchase=cancelled`,
    });

    return new Response(JSON.stringify({ url: session.url }), { status: 200, headers: corsHeaders });
  } catch (error) {
    const code = error instanceof Error ? error.message : "checkout_failed";
    const status = code === "not_authenticated" ? 401 : code === "invalid_pack" ? 400 : 500;
    const details = error && typeof error === "object" ? error as Record<string, unknown> : {};
    const stripeType = typeof details.type === "string" ? details.type : "";
    const publicCode = code === "not_authenticated" || code === "invalid_pack" || code === "payment_not_configured"
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
