import { createClient } from "@supabase/supabase-js";

const responseHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

type AccountStatus = "active" | "locked";

const PRIMARY_OWNER_USER_ID = "d465d88f-0acb-4bff-ad55-945761acaeea";
// Ilja hat dieselben Haupt-Owner-Rechte wie Robyn und wird über die Login-E-Mail erkannt.
const PRIMARY_OWNER_EMAIL = "ilja.podorieszach@icloud.com";

function isPrimaryOwnerUser(user: { id: string; email?: string | null }, role: string) {
  return role === "super_admin" && (user.id === PRIMARY_OWNER_USER_ID || (user.email ?? "").toLowerCase() === PRIMARY_OWNER_EMAIL);
}

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
    // 2FA nur verlangen, wenn das Konto einen bestätigten Faktor hat (wie private.assert_mfa_if_enrolled).
    if (assurance.nextLevel === "aal2" && assurance.currentLevel !== "aal2") {
      return jsonResponse({ error: "mfa_required" }, 403);
    }

    const body = await request.json() as {
      target_user_id?: string;
      status?: AccountStatus;
      duration_minutes?: number | null;
      reason?: string;
    };

    if (!body.target_user_id || !["active", "locked"].includes(body.status ?? "")) {
      return jsonResponse({ error: "invalid_request" }, 400);
    }
    if (body.target_user_id === authData.user.id) {
      return jsonResponse({ error: "cannot_lock_own_account" }, 403);
    }
    const allowedDurations = [60, 1440, 10080];
    const durationMinutes = body.status === "locked" && body.duration_minutes != null
      ? Number(body.duration_minutes)
      : null;
    if (durationMinutes !== null && !allowedDurations.includes(durationMinutes)) {
      return jsonResponse({ error: "invalid_lock_duration" }, 400);
    }
    const customReason = (body.reason ?? "").trim();
    if (customReason.length > 120) return jsonResponse({ error: "invalid_admin_reason" }, 400);

    const [
      { data: caller, error: callerError },
      { data: callerWallet, error: callerWalletError },
      { data: target, error: targetError },
      { data: targetWallet, error: targetWalletError },
    ] = await Promise.all([
      admin.from("profiles").select("role").eq("id", authData.user.id).maybeSingle(),
      admin.from("wallets").select("status").eq("user_id", authData.user.id).maybeSingle(),
      admin.from("profiles").select("role").eq("id", body.target_user_id).maybeSingle(),
      admin.from("wallets").select("status,locked_until,lock_reason").eq("user_id", body.target_user_id).maybeSingle(),
    ]);

    if (callerError || !caller || !["admin", "super_admin"].includes(caller.role)) {
      return jsonResponse({ error: "admin_required" }, 403);
    }
    if (callerWalletError || callerWallet?.status !== "active") {
      return jsonResponse({ error: "account_locked" }, 403);
    }
    if (targetError || !target) return jsonResponse({ error: "user_not_found" }, 404);
    if (targetWalletError || !targetWallet) return jsonResponse({ error: "wallet_not_found" }, 404);
    const callerIsPrimaryOwner = isPrimaryOwnerUser(authData.user, caller.role);
    if (caller.role === "super_admin" && !callerIsPrimaryOwner) {
      return jsonResponse({ error: "primary_owner_required" }, 403);
    }
    if (target.role === "super_admin" && !callerIsPrimaryOwner) {
      return jsonResponse({ error: "cannot_modify_super_admin" }, 403);
    }
    if (caller.role === "admin" && target.role === "admin") {
      return jsonResponse({ error: "cannot_modify_peer_admin" }, 403);
    }

    const { error: updateError } = await admin.auth.admin.updateUserById(body.target_user_id, {
      ban_duration: body.status === "locked"
        ? durationMinutes === null ? "876000h" : `${durationMinutes}m`
        : "none",
    });
    if (updateError) throw updateError;

    const lockedUntil = body.status === "locked" && durationMinutes !== null
      ? new Date(Date.now() + durationMinutes * 60_000).toISOString()
      : null;
    const reason = body.status === "locked"
      ? customReason || "Konto im Adminpanel gebannt"
      : "Bann im Adminpanel aufgehoben";
    const { error: walletUpdateError } = await admin.rpc("admin_apply_wallet_status_v2", {
      p_admin_user_id: authData.user.id,
      p_target_user_id: body.target_user_id,
      p_status: body.status,
      p_reason: reason,
      p_locked_until: lockedUntil,
    });

    if (walletUpdateError) {
      await admin.auth.admin.updateUserById(body.target_user_id, {
        ban_duration: targetWallet.status === "locked"
          ? targetWallet.locked_until
            ? `${Math.max(1, Math.ceil((new Date(targetWallet.locked_until).getTime() - Date.now()) / 60_000))}m`
            : "876000h"
          : "none",
      });
      throw walletUpdateError;
    }

    return jsonResponse({ user_id: body.target_user_id, status: body.status, locked_until: lockedUntil }, 200);
  } catch (error) {
    console.error("admin-account-status failed", error);
    return jsonResponse({ error: "account_status_update_failed" }, 500);
  }
});
