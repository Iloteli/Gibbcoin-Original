"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { getSupabase } from "../lib/supabase";
import type { Profile } from "../lib/types";

type Props = { userId: string; profile: Profile; onChanged: () => Promise<void> };

export function ProfileEditor({ userId, profile, onChanged }: Props) {
  const [displayName, setDisplayName] = useState(profile.display_name);
  const [username, setUsername] = useState(profile.username ?? "");
  const [bio, setBio] = useState(profile.bio ?? "");
  const [color, setColor] = useState(profile.profile_color ?? "#35e070");
  const [avatarUrl, setAvatarUrl] = useState(profile.avatar_url ?? "");
  const [contacts, setContacts] = useState(0);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    const supabase = getSupabase();
    if (!supabase) return;
    void supabase.rpc("list_contacts").then(({ data }) => setContacts(Array.isArray(data) ? data.length : 0));
  }, []);

  async function uploadAvatar(file?: File) {
    if (!file) return;
    if (file.size > 2 * 1024 * 1024 || !["image/jpeg", "image/png", "image/webp"].includes(file.type)) {
      setError("Profilbilder müssen JPG, PNG oder WebP und höchstens 2 MB gross sein.");
      return;
    }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true); setError(""); setMessage("");
    const extension = file.name.split(".").pop()?.toLowerCase() || "webp";
    const path = `${userId}/avatar-${Date.now()}.${extension}`;
    const { error: uploadError } = await supabase.storage.from("avatars").upload(path, file, { upsert: true, contentType: file.type });
    if (uploadError) { setBusy(false); setError("Das Profilbild konnte nicht hochgeladen werden."); return; }
    setAvatarUrl(supabase.storage.from("avatars").getPublicUrl(path).data.publicUrl);
    setBusy(false); setMessage("Bild bereit. Speichere jetzt dein Profil.");
  }

  async function save(event: React.FormEvent) {
    event.preventDefault();
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(true); setError(""); setMessage("");

    const nextUsername = username.trim().toLowerCase();
    const { data, error: rpcError } = await supabase.rpc("update_my_profile_atomic", {
      p_username: nextUsername,
      p_display_name: displayName.trim(), p_bio: bio.trim() || null,
      p_profile_color: color, p_avatar_url: avatarUrl || null,
    });
    setBusy(false);
    const result = data as { ok?: boolean; error?: string } | null;
    if (rpcError?.code === "PGRST202") {
      setError("Die Profiländerung ist auf diesem Server noch nicht verfügbar. Es wurde nichts gespeichert.");
      return;
    }
    if (rpcError || !result?.ok) {
      setError(result?.error === "username_taken"
        ? "Dieser Benutzername ist bereits vergeben. Wähle einen anderen."
        : result?.error === "invalid_username"
          ? "Benutzername ungültig: 3 bis 24 Zeichen, nur Kleinbuchstaben, Ziffern, Punkt, Bindestrich und Unterstrich."
          : "Das Profil konnte nicht gespeichert werden. Prüfe Name und Beschreibung.");
      return;
    }
    setMessage("Profil gespeichert.");
    await onChanged();
  }

  return <section className="card card-pad profile-editor" id="profile-editor">
    <div className="section-heading compact-heading"><div><span className="section-number">PROFIL</span><h2>Dein Auftritt</h2></div><span>{contacts} Kontakte</span></div>
    <form onSubmit={save} className="profile-editor-grid">
      <div className="profile-preview" style={{ borderColor: color }}>
        {avatarUrl ? <Image src={avatarUrl} alt="Profilbild Vorschau" width={92} height={92} unoptimized /> : <span style={{ background: color }}>{displayName[0]?.toUpperCase() || "G"}</span>}
        <strong>{displayName || "Dein Name"}</strong><small>{username ? `@${username}` : profile.equipped_title || "GIBB Mitglied"}</small><p>{bio || "Deine kurze Profilbeschreibung erscheint hier."}</p>
      </div>
      <div className="profile-fields">
        <div className="field"><label htmlFor="profile-name">Anzeigename</label><input id="profile-name" className="input" minLength={2} maxLength={60} required value={displayName} onChange={(event) => setDisplayName(event.target.value)} /></div>
        <div className="field"><label htmlFor="profile-username">Benutzername <span>{username.length}/24</span></label><input id="profile-username" className="input" minLength={3} maxLength={24} required pattern="[a-z0-9][a-z0-9._\-]{2,23}" value={username} onChange={(event) => setUsername(event.target.value.toLowerCase().replace(/[^a-z0-9._-]/g, "").slice(0, 24))} placeholder="z.B. ilja.p" /><small className="field-hint">3–24 Zeichen: Kleinbuchstaben, Ziffern, Punkt, Bindestrich, Unterstrich. Eindeutig für alle.</small></div>
        <div className="field"><label htmlFor="profile-bio">Über mich <span>{bio.length}/180</span></label><textarea id="profile-bio" className="input" maxLength={180} rows={3} value={bio} onChange={(event) => setBio(event.target.value)} placeholder="Kurz und freundlich …" /></div>
        <div className="profile-small-fields"><div className="field"><label htmlFor="profile-color">Profilfarbe</label><input id="profile-color" className="input color-input" type="color" value={color} onChange={(event) => setColor(event.target.value)} /></div><div className="field"><label htmlFor="profile-avatar">Profilbild</label><input id="profile-avatar" className="input" type="file" accept="image/png,image/jpeg,image/webp" disabled={busy} onChange={(event) => void uploadAvatar(event.target.files?.[0])} /></div></div>
        <button className="primary" type="submit" disabled={busy}>{busy ? "Speichert …" : "Profil speichern"}</button>
        {message && <p className="message success-message" role="status">{message}</p>}{error && <p className="message error" role="alert">{error}</p>}
      </div>
    </form>
  </section>;
}
