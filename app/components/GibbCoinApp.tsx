"use client";

import type { Session } from "@supabase/supabase-js";
import { useEffect, useState } from "react";
import { getSupabase, getUsableSupabaseSession, isSupabaseAuthError, waitForSupabaseAuthRetry } from "../lib/supabase";
import { Dashboard } from "./Dashboard";
import { LoginPage } from "./LoginPage";
import { MfaChallengePage } from "./MfaChallengePage";
import { PasswordResetPage } from "./PasswordResetPage";

const BANNED_NOTICE = "Dieses Konto wurde gebannt. Du wurdest automatisch abgemeldet und kannst dich erst nach einer Freigabe durch einen Admin wieder anmelden.";

function rememberAccountNotice(message: string) {
  window.sessionStorage.setItem("gibb-account-notice", message);
}

function hasPasswordRecoveryMarker() {
  if (typeof window === "undefined") return false;
  const search = new URLSearchParams(window.location.search);
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  return search.get("password-reset") === "1" && hash.get("type") === "recovery";
}

export function GibbCoinApp() {
  const [session, setSession] = useState<Session | null>(null);
  const [passwordRecovery, setPasswordRecovery] = useState(false);
  const [recoverySession, setRecoverySession] = useState<Session | null>(null);
  const [mfaRequired, setMfaRequired] = useState(false);
  // Keep the server render and the browser's first render identical. The
  // Supabase client is initialized only after hydration below.
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const maybeSupabase = getSupabase();
    if (!maybeSupabase) {
      const configurationCheck = window.setTimeout(() => setLoading(false), 0);
      return () => window.clearTimeout(configurationCheck);
    }
    const supabase = maybeSupabase;
    const recoveryLinkAtLoad = hasPasswordRecoveryMarker();
    let active = true;
    let validationId = 0;

    async function validateSession(nextSession: Session | null) {
      const currentValidation = ++validationId;
      if (recoveryLinkAtLoad) {
        if (active) {
          setPasswordRecovery(true);
          setRecoverySession(nextSession);
          setSession(null);
          setLoading(false);
        }
        return;
      }
      if (!nextSession) {
        if (active) { setSession(null); setMfaRequired(false); setLoading(false); }
        return;
      }

      if (active) setLoading(true);
      let validatedSession = nextSession;
      const fetchWalletStatus = (userId: string) => supabase
        .from("wallets")
        .select("status")
        .eq("user_id", userId)
        .maybeSingle();
      let walletResult = await fetchWalletStatus(validatedSession.user.id);
      if (isSupabaseAuthError(walletResult.error)) {
        await waitForSupabaseAuthRetry(walletResult.error, 0);
        const restoredSession = await getUsableSupabaseSession();
        if (restoredSession) {
          validatedSession = restoredSession;
          walletResult = await fetchWalletStatus(validatedSession.user.id);
        }
      }
      if (!active || currentValidation !== validationId) return;
      const { data: wallet } = walletResult;

      if (wallet?.status === "locked") {
        rememberAccountNotice(BANNED_NOTICE);
        await supabase.auth.signOut({ scope: "local" });
        if (active) { setSession(null); setLoading(false); }
        return;
      }

      let assuranceResult = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
      if (assuranceResult.error) {
        const restoredSession = await getUsableSupabaseSession();
        if (restoredSession) {
          validatedSession = restoredSession;
          assuranceResult = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
        }
      }
      if (!active || currentValidation !== validationId) return;
      const { data: assurance, error: assuranceError } = assuranceResult;
      if (assuranceError) {
        // Fail closed without destroying a possibly valid session. A temporary
        // check error must never create the former login/logout loop.
        setSession(validatedSession);
        setMfaRequired(true);
        setLoading(false);
        return;
      }

      setSession(validatedSession);
      setMfaRequired(assurance.nextLevel === "aal2" && assurance.currentLevel !== "aal2");
      setLoading(false);
    }

    void supabase.auth.getSession().then(({ data }) => void validateSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((event, nextSession) => {
      if (event === "PASSWORD_RECOVERY") {
        setPasswordRecovery(true);
        setRecoverySession(nextSession);
        setSession(null);
        setLoading(false);
        return;
      }
      if (event === "MFA_CHALLENGE_VERIFIED" && nextSession) {
        setSession(nextSession);
        setMfaRequired(false);
        setLoading(false);
        return;
      }
      if (event === "TOKEN_REFRESHED" && nextSession) {
        setSession(nextSession);
        return;
      }
      window.setTimeout(() => void validateSession(nextSession), 0);
    });
    return () => { active = false; data.subscription.unsubscribe(); };
  }, []);

  useEffect(() => {
    const maybeSupabase = getSupabase();
    const userId = session?.user.id;
    if (!maybeSupabase || !userId) return;
    const supabase = maybeSupabase;
    let signingOut = false;

    async function signOutUnavailableAccount(message: string) {
      if (signingOut) return;
      signingOut = true;
      rememberAccountNotice(message);
      await supabase.auth.signOut({ scope: "local" });
    }

    async function checkAccountStatus() {
      let result = await supabase.from("wallets").select("status").eq("user_id", userId).maybeSingle();
      if (isSupabaseAuthError(result.error)) {
        const restoredSession = await getUsableSupabaseSession();
        if (restoredSession) result = await supabase.from("wallets").select("status").eq("user_id", userId).maybeSingle();
      }
      if (isSupabaseAuthError(result.error)) return;
      const { data: wallet } = result;
      if (wallet?.status === "locked") await signOutUnavailableAccount(BANNED_NOTICE);
    }

    const channel = supabase
      .channel(`account-ban-${userId}`)
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "wallets", filter: `user_id=eq.${userId}` }, (payload) => {
        if ((payload.new as { status?: string }).status === "locked") void signOutUnavailableAccount(BANNED_NOTICE);
      })
      .subscribe();
    const fallbackCheck = window.setInterval(() => void checkAccountStatus(), 15_000);

    return () => {
      window.clearInterval(fallbackCheck);
      void supabase.removeChannel(channel);
    };
  }, [session?.user.id]);

  async function finishPasswordRecovery(message?: string) {
    const supabase = getSupabase();
    if (message) window.sessionStorage.setItem("gibb-success-notice", message);
    window.history.replaceState({}, "", window.location.pathname);
    if (supabase) await supabase.auth.signOut({ scope: "local" });
    setPasswordRecovery(false);
    setRecoverySession(null);
    setSession(null);
    setMfaRequired(false);
    setLoading(false);
  }

  async function logoutFromMfa() {
    const supabase = getSupabase();
    if (supabase) await supabase.auth.signOut({ scope: "local" });
    setSession(null);
    setMfaRequired(false);
  }

  if (loading) return <main className="loading-page"><div><div className="loader" /><p>GIBB Coin wird geladen …</p></div></main>;
  if (passwordRecovery) return <PasswordResetPage recoveryAvailable={Boolean(recoverySession)} onComplete={finishPasswordRecovery} />;
  if (!session) return <LoginPage />;
  if (mfaRequired) return <MfaChallengePage onVerified={(verifiedSession) => { setSession(verifiedSession); setMfaRequired(false); }} onLogout={logoutFromMfa} />;
  return <Dashboard user={session.user} />;
}
