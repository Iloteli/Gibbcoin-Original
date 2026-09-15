import { createClient } from "@supabase/supabase-js";

const responseHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

type AuthorizationResult = {
  ok?: boolean;
  error?: string;
  display_name?: string;
  role?: string;
  actor_role?: string;
};

type FinalizeResult = { ok?: boolean; error?: string };

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
    if (assurance.currentLevel !== "aal2") {
      return jsonResponse({ error: "mfa_required" }, 403);
    }

    const body = await request.json() as { target_user_id?: string; pin?: string };
    if (!body.target_user_id || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(body.target_user_id)) {
      return jsonResponse({ error: "invalid_request" }, 400);
    }
    if (!/^\d{4}$/.test(body.pin ?? "")) {
      return jsonResponse({ error: "pin_must_have_four_digits" }, 400);
    }

    const { data: authorizationData, error: authorizationError } = await admin.rpc(
      "admin_authorize_account_deletion",
      {
        p_admin_user_id: authData.user.id,
        p_target_user_id: body.target_user_id,
        p_pin: body.pin,
      },
    );
    const deletionAuthorization = authorizationData as AuthorizationResult | null;
    if (authorizationError) throw authorizationError;
    if (!deletionAuthorization?.ok) {
      const status = deletionAuthorization?.error === "user_not_found" ? 404 : 403;
      return jsonResponse({ error: deletionAuthorization?.error ?? "account_delete_not_authorized" }, status);
    }
    // Recheck both authoritative roles immediately before touching Auth. The
    // database DELETE trigger remains the final race-safe guard.
    const { data: currentProfiles, error: currentProfilesError } = await admin
      .from("profiles")
      .select("id, role")
      .in("id", [authData.user.id, body.target_user_id]);
    if (currentProfilesError) throw currentProfilesError;
    const actorProfile = currentProfiles?.find((profile) => profile.id === authData.user.id);
    const targetProfile = currentProfiles?.find((profile) => profile.id === body.target_user_id);
    if (!targetProfile) {
      return jsonResponse({ error: "user_not_found" }, 404);
    }
    if (!actorProfile || !["admin", "super_admin"].includes(actorProfile.role)) {
      return jsonResponse({ error: "admin_required" }, 403);
    }
    const actorIsPrimaryOwner = isPrimaryOwnerUser(authData.user, actorProfile.role);
    if (actorProfile.role === "super_admin" && !actorIsPrimaryOwner) {
      return jsonResponse({ error: "primary_owner_required" }, 403);
    }
    if (targetProfile.role === "super_admin" && !actorIsPrimaryOwner) {
      return jsonResponse({ error: "cannot_delete_owner" }, 403);
    }
    if (actorProfile.role === "admin" && targetProfile.role === "admin") {
      return jsonResponse({ error: "cannot_delete_peer_admin" }, 403);
    }

    const { error: banError } = await admin.auth.admin.updateUserById(body.target_user_id, {
      ban_duration: "876000h",
    });
    if (banError) return jsonResponse({ error: "user_not_found" }, 404);

    const { error: deleteError } = await admin.auth.admin.deleteUser(body.target_user_id, false);
    if (deleteError) {
      await admin.auth.admin.updateUserById(body.target_user_id, { ban_duration: "none" });
      throw deleteError;
    }

    const { data: finalizeData, error: finalizeError } = await admin.rpc(
      "admin_finalize_account_deletion",
      {
        p_admin_user_id: authData.user.id,
        p_target_user_id: body.target_user_id,
      },
    );
    const finalized = finalizeData as FinalizeResult | null;
    if (finalizeError || !finalized?.ok) {
      console.error("admin account deletion cleanup failed", finalizeError ?? finalized?.error);
      return jsonResponse({ error: "account_deleted_cleanup_pending" }, 500);
    }

    return jsonResponse({
      user_id: body.target_user_id,
      display_name: deletionAuthorization.display_name,
      deleted: true,
      email_reusable: true,
    }, 200);
  } catch (error) {
    console.error("admin account deletion failed", error);
    return jsonResponse({ error: "account_delete_failed" }, 500);
  }
});
