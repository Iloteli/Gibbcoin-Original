"use client";

import { createClient, type Session, type SupabaseClient } from "@supabase/supabase-js";

let client: SupabaseClient | null = null;

type SupabaseErrorLike = {
  code?: string | null;
  message?: string | null;
  status?: number | null;
};

// Supabase publishable keys are intended for browsers and public source. Sites
// runtime variables are not always embedded into the browser bundle, so these
// public project values keep authentication available after deployment.
const DEFAULT_SUPABASE_URL = "https://laduzigqgvvnrqcgfgab.supabase.co";
const DEFAULT_SUPABASE_PUBLISHABLE_KEY = "sb_publishable_bdH33RHJl23SY6qNkUwvhQ_IzQOArAb";
const AUTH_STORAGE_KEY = "gibb-coin-auth-v2";

// Eine relative Adresse (z. B. "/sb") meint die eigene, selbst gehostete Instanz
// hinter dem Server-Gateway – unter derselben Adresse wie die Website.
function resolveSupabaseUrl(configured: string) {
  if (!configured.startsWith("/")) return configured;
  const origin = typeof window !== "undefined" && window.location?.origin ? window.location.origin : "http://localhost";
  return `${origin}${configured}`;
}

function getSupabaseConfig() {
  return {
    url: resolveSupabaseUrl(process.env.NEXT_PUBLIC_SUPABASE_URL || DEFAULT_SUPABASE_URL),
    publishableKey: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
      || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
      || DEFAULT_SUPABASE_PUBLISHABLE_KEY,
  };
}

export function getSupabase(): SupabaseClient | null {
  const { url, publishableKey } = getSupabaseConfig();
  if (!client) {
    client = createClient(url, publishableKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        // Keep the repaired session isolated from legacy tabs that may still
        // hold and revoke a rotated token under Supabase's former default key.
        storageKey: AUTH_STORAGE_KEY,
      },
    });
  }
  return client;
}

export function isSupabaseAuthError(error: SupabaseErrorLike | null | undefined) {
  if (!error) return false;
  const code = (error.code ?? "").toUpperCase();
  const message = (error.message ?? "").toLocaleLowerCase("en-US");
  return error.status === 401
    || code === "PGRST301"
    || code === "PGRST303"
    || message.includes("jwt")
    || message.includes("unauthorized")
    || message.includes("refresh token");
}

export async function waitForSupabaseAuthRetry(
  error: SupabaseErrorLike | null | undefined,
  attempt: number,
) {
  if (!isSupabaseAuthError(error)) return false;
  const code = (error?.code ?? "").toUpperCase();
  const message = (error?.message ?? "").toLocaleLowerCase("en-US");
  const clockSkew = code === "PGRST303" && message.includes("issued at future");
  const delays = clockSkew ? [750, 1_500, 3_000] : [150, 300, 600];
  const delayMs = delays[attempt];
  if (delayMs === undefined) return false;
  await new Promise<void>((resolve) => globalThis.setTimeout(resolve, delayMs));
  return true;
}

export async function getUsableSupabaseSession(): Promise<Session | null> {
  const supabase = getSupabase();
  if (!supabase) return null;

  try {
    // getSession() uses Supabase Auth's own single-flight refresh flow. Calling
    // refreshSession() from several UI components can race with MFA token
    // rotation and invalidate an otherwise valid, freshly verified session.
    const { data, error } = await supabase.auth.getSession();
    if (error || !data.session) return null;

    // A locally cached JWT can look fresh even after its server-side session
    // was revoked. getUser() checks the current token against Auth and lets the
    // SDK remove only genuinely invalid local sessions.
    const { data: userData, error: userError } = await supabase.auth.getUser(data.session.access_token);
    if (userError || !userData.user) return null;
    return { ...data.session, user: userData.user };
  } catch {
    return null;
  }
}

export async function createCheckoutSession(packId: string): Promise<{ url?: string; error?: string }> {
  const supabase = getSupabase();
  if (!supabase) return { error: "client_unavailable" };

  const { data: { session }, error: sessionError } = await supabase.auth.getSession();
  if (sessionError || !session?.access_token) return { error: "not_authenticated" };

  const { url, publishableKey } = getSupabaseConfig();
  try {
    const response = await fetch(`${url.replace(/\/$/, "")}/functions/v1/create-checkout-session`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${session.access_token}`,
        apikey: publishableKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ pack_id: packId }),
    });
    const payload = await response.json().catch(() => ({})) as { url?: unknown; error?: unknown };
    if (!response.ok) return { error: typeof payload.error === "string" ? payload.error : `http_${response.status}` };
    if (typeof payload.url !== "string" || !payload.url.startsWith("https://checkout.stripe.com/")) {
      return { error: "invalid_checkout_url" };
    }
    return { url: payload.url };
  } catch {
    return { error: "network_error" };
  }
}
