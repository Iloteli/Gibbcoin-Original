import { createClient } from "@supabase/supabase-js";

const responseHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

type AccountStatus = "active" | "locked";

function jsonResponse(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: responseHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    const accessToken = authorization?.replace(/^Bearer\s+/i, "");
    if (!accessToken) return jsonResponse({ error: "authentication_required" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "server_configuration_error" }, 500);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: authData, error: authError } = await admin.auth.getUser(accessToken);
    if (authError || !authData.user) {
      return jsonResponse({ error: "authentication_required" }, 401);
    }
    const { data: assurance, error: assuranceError } = await admin.auth.mfa.getAuthenticatorAssuranceLevel(accessToken);
    if (assuranceError) return jsonResponse({ error: "authentication_required" }, 401);
    if (assurance.nextLevel === "aal2" && assurance.currentLevel !== "aal2") {
      return jsonResponse({ error: "mfa_required" }, 403);
    }

    const body = await request.json() as {
      target_user_id?: string;
      status?: AccountStatus;
    };

    if (!body.target_user_id || !["active", "locked"].includes(body.status ?? "")) {
      return jsonResponse({ error: "invalid_request" }, 400);
    }
    if (body.target_user_id === authData.user.id) {
      return jsonResponse({ error: "cannot_lock_own_account" }, 403);
    }

    const [
      { data: caller, error: callerError },
      { data: callerWallet, error: callerWalletError },
      { data: target, error: targetError },
      { data: targetWallet, error: targetWalletError },
    ] = await Promise.all([
      admin.from("profiles").select("role").eq("id", authData.user.id).maybeSingle(),
      admin.from("wallets").select("status").eq("user_id", authData.user.id).maybeSingle(),
      admin.from("profiles").select("role").eq("id", body.target_user_id).maybeSingle(),
      admin.from("wallets").select("status").eq("user_id", body.target_user_id).maybeSingle(),
    ]);

    if (callerError || !caller || !["admin", "super_admin"].includes(caller.role)) {
      return jsonResponse({ error: "admin_required" }, 403);
    }
    if (callerWalletError || callerWallet?.status !== "active") {
      return jsonResponse({ error: "account_locked" }, 403);
    }
    if (targetError || !target) return jsonResponse({ error: "user_not_found" }, 404);
    if (targetWalletError || !targetWallet) return jsonResponse({ error: "wallet_not_found" }, 404);
    if (target.role === "super_admin") {
      return jsonResponse({ error: "cannot_modify_super_admin" }, 403);
    }
    if (caller.role === "admin" && target.role === "admin") {
      return jsonResponse({ error: "cannot_modify_peer_admin" }, 403);
    }

    const { error: updateError } = await admin.auth.admin.updateUserById(body.target_user_id, {
      ban_duration: body.status === "locked" ? "876000h" : "none",
    });
    if (updateError) throw updateError;

    const reason = body.status === "locked"
      ? "Konto im Adminpanel gebannt"
      : "Bann im Adminpanel aufgehoben";
    const { error: walletUpdateError } = await admin.rpc("admin_apply_wallet_status", {
      p_admin_user_id: authData.user.id,
      p_target_user_id: body.target_user_id,
      p_status: body.status,
      p_reason: reason,
    });

    if (walletUpdateError) {
      await admin.auth.admin.updateUserById(body.target_user_id, {
        ban_duration: targetWallet.status === "locked" ? "876000h" : "none",
      });
      throw walletUpdateError;
    }

    return jsonResponse({ user_id: body.target_user_id, status: body.status }, 200);
  } catch (error) {
    console.error("admin-account-status failed", error);
    return jsonResponse({ error: "account_status_update_failed" }, 500);
  }
});
