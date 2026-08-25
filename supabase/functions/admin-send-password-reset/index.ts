import { createClient } from "npm:@supabase/supabase-js@2.112.3";

const responseHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const passwordResetRedirect = "https://gibb-coin-schulwallet.pxfyvkgcs6.chatgpt.site/?password-reset=1";

type AuthorizationResult = {
  ok?: boolean;
  error?: string;
  email?: string;
  display_name?: string;
  role?: string;
};

function jsonResponse(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: responseHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);

  try {
    const accessToken = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    if (!accessToken) return jsonResponse({ error: "authentication_required" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: "server_configuration_error" }, 500);

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: authData, error: authError } = await admin.auth.getUser(accessToken);
    if (authError || !authData.user) return jsonResponse({ error: "authentication_required" }, 401);
    const { data: assurance, error: assuranceError } = await admin.auth.mfa.getAuthenticatorAssuranceLevel(accessToken);
    if (assuranceError) return jsonResponse({ error: "authentication_required" }, 401);
    if (assurance.nextLevel === "aal2" && assurance.currentLevel !== "aal2") {
      return jsonResponse({ error: "mfa_required" }, 403);
    }

    const body = await request.json() as { target_user_id?: string };
    if (!body.target_user_id || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(body.target_user_id)) {
      return jsonResponse({ error: "invalid_request" }, 400);
    }

    const { data: authorizationData, error: authorizationError } = await admin.rpc(
      "admin_authorize_password_reset",
      { p_admin_user_id: authData.user.id, p_target_user_id: body.target_user_id },
    );
    if (authorizationError) throw authorizationError;
    const authorization = authorizationData as AuthorizationResult | null;
    if (!authorization?.ok || !authorization.email) {
      const error = authorization?.error ?? "password_reset_not_authorized";
      const status = error === "user_not_found" ? 404 : 403;
      return jsonResponse({ error }, status);
    }

    const { error: resetError } = await admin.auth.resetPasswordForEmail(authorization.email, {
      redirectTo: passwordResetRedirect,
    });
    if (resetError) {
      console.error("admin password-reset email failed", resetError.code, resetError.message);
      return jsonResponse({ error: "email_delivery_failed" }, 502);
    }

    const { error: auditError } = await admin.rpc("admin_record_password_reset", {
      p_admin_user_id: authData.user.id,
      p_target_user_id: body.target_user_id,
    });
    if (auditError) console.error("admin password-reset audit failed", auditError);

    return jsonResponse({
      sent: true,
      user_id: body.target_user_id,
      display_name: authorization.display_name,
    }, 200);
  } catch (error) {
    console.error("admin-send-password-reset failed", error);
    return jsonResponse({ error: "password_reset_failed" }, 500);
  }
});
