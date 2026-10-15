"use client";

import Image from "next/image";
import { useEffect, useRef, useState, type CSSProperties } from "react";
import { getSupabase } from "../lib/supabase";
import { ProfileBadges } from "./ProfileBadges";

const PROFILE_EVENT = "gibb:open-profile";

type PublicUserProfile = {
  ok: boolean;
  error?: string;
  user_id: string;
  username: string;
  display_name: string;
  bio: string | null;
  profile_color: string;
  avatar_url: string | null;
  equipped_title: string | null;
  role: "user" | "admin" | "super_admin";
  joined_at: string;
  balance: number;
  dino_best_score: number;
  is_me: boolean;
};

export function openUserProfile(userId: string) {
  window.dispatchEvent(new CustomEvent(PROFILE_EVENT, { detail: { userId } }));
}

function roleLabel(profile: PublicUserProfile) {
  if (profile.role === "super_admin") return "Owner";
  if (profile.role === "admin") return "Admin";
  return profile.equipped_title || "Mitglied";
}

export function UserProfileModal() {
  const [profile, setProfile] = useState<PublicUserProfile | null>(null);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const closeButton = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    async function showProfile(event: Event) {
      const userId = (event as CustomEvent<{ userId?: string }>).detail?.userId;
      if (!userId) return;
      setOpen(true);
      setLoading(true);
      setError("");
      setProfile(null);
      const supabase = getSupabase();
      if (!supabase) {
        setLoading(false);
        setError("Das Profil kann offline nicht geladen werden.");
        return;
      }
      const { data, error: rpcError } = await supabase.rpc("get_public_user_profile", { p_user_id: userId });
      const result = data as PublicUserProfile | null;
      setLoading(false);
      if (rpcError || !result?.ok) {
        setError(result?.error === "profile_not_found" ? "Dieses Profil ist nicht mehr verfügbar." : "Das Profil konnte gerade nicht geladen werden.");
        return;
      }
      setProfile(result);
    }

    window.addEventListener(PROFILE_EVENT, showProfile);
    return () => window.removeEventListener(PROFILE_EVENT, showProfile);
  }, []);

  useEffect(() => {
    if (!open) return;
    closeButton.current?.focus();
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [open]);

  if (!open) return null;

  return <div className="modal-backdrop public-profile-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setOpen(false); }}>
    <section className="public-profile-modal" role="dialog" aria-modal="true" aria-labelledby="public-profile-title" aria-busy={loading}>
      <button ref={closeButton} className="public-profile-close" type="button" aria-label="Profil schließen" onClick={() => setOpen(false)}>×</button>
      {loading && <div className="public-profile-loading" role="status"><i aria-hidden="true" /><strong>Profil wird geladen …</strong></div>}
      {!loading && error && <div className="public-profile-error" role="alert"><span aria-hidden="true">!</span><strong>{error}</strong></div>}
      {!loading && profile && <>
        <div className="public-profile-hero" style={{ "--profile-color": profile.profile_color } as CSSProperties}>
          {profile.avatar_url ? <Image className="public-profile-avatar" src={profile.avatar_url} alt="" width={86} height={86} unoptimized referrerPolicy="no-referrer" /> : <span className="public-profile-avatar" aria-hidden="true">{profile.display_name[0]?.toUpperCase()}</span>}
          <div><span>{profile.is_me ? "DEIN ÖFFENTLICHES PROFIL" : "GIBB COIN PROFIL"}</span><h2 id="public-profile-title">{profile.display_name}</h2><p>@{profile.username}</p></div>
          <b>{roleLabel(profile)}</b>
        </div>
        <p className="public-profile-bio">{profile.bio || "Dieses Mitglied hat noch keine Profilbeschreibung hinzugefügt."}</p>
        <div className="public-profile-stats">
          <div><span>Wallet</span><strong>{profile.balance.toLocaleString("de-CH")} GIBB</strong></div>
          <div><span>Dino-Rekord</span><strong>{profile.dino_best_score.toLocaleString("de-CH")}</strong></div>
          <div><span>Dabei seit</span><strong>{new Date(profile.joined_at).toLocaleDateString("de-CH", { month: "short", year: "numeric" })}</strong></div>
        </div>
        <ProfileBadges userId={profile.user_id} balance={profile.balance} dinoBest={profile.dino_best_score} role={profile.role} showLocked={profile.is_me} />
        <small className="public-profile-privacy">Es werden nur öffentliche Profildaten angezeigt.</small>
      </>}
    </section>
  </div>;
}
