"use client";

import Image from "next/image";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "../lib/supabase";
import type { Recipient } from "../lib/types";
import { openUserProfile } from "./UserProfileModal";

type Contact = {
  contact_id: string;
  user_id: string;
  username: string;
  display_name: string;
  wallet_code: string;
  nickname: string | null;
  is_favorite: boolean;
  created_at: string;
};

type PaymentRequest = {
  id: string;
  requester_user_id: string;
  target_user_id: string;
  requester_label: string;
  target_label: string;
  amount: number;
  note: string | null;
  status: "pending" | "paid" | "declined" | "cancelled";
  transaction_id: string | null;
  created_at: string;
};

type Props = {
  userId: string;
  onRecipient: (recipient: Recipient) => void;
  onChanged: () => Promise<void>;
};

function requestError(message?: string) {
  if (message?.includes("insufficient_balance") || message?.includes("insufficient_funds")) return "Dein Guthaben reicht zum Bezahlen dieser Anfrage nicht aus.";
  if (message?.includes("request_already_processed")) return "Diese Anfrage wurde bereits bearbeitet.";
  if (message?.includes("target_not_found") || message?.includes("request_not_found")) return "Die Anfrage oder das Zielkonto ist nicht mehr verfügbar.";
  if (message?.includes("invalid_amount")) return "Der Betrag muss zwischen 1 und 1’000 GIBB liegen.";
  if (message?.includes("wallet_locked")) return "Ein beteiligtes Konto ist aktuell gesperrt.";
  return "Die Zahlungsanfrage konnte nicht verarbeitet werden.";
}

function statusLabel(status: PaymentRequest["status"]) {
  if (status === "paid") return "Bezahlt";
  if (status === "declined") return "Abgelehnt";
  if (status === "cancelled") return "Abgebrochen";
  return "Offen";
}

export function PaymentsHub({ userId, onRecipient, onChanged }: Props) {
  const [tab, setTab] = useState<"requests" | "contacts">("requests");
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [requests, setRequests] = useState<PaymentRequest[]>([]);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Recipient[]>([]);
  const [selected, setSelected] = useState<Recipient | null>(null);
  const [searching, setSearching] = useState(false);
  const [amount, setAmount] = useState("");
  const [note, setNote] = useState("");
  const [nickname, setNickname] = useState("");
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const loadHub = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const [{ data: contactData, error: contactError }, { data: requestData, error: paymentError }] = await Promise.all([
      supabase.rpc("list_contacts"),
      supabase.from("payment_requests").select("id,requester_user_id,target_user_id,requester_label,target_label,amount,note,status,transaction_id,created_at").order("created_at", { ascending: false }).limit(30),
    ]);
    if (contactError || paymentError) {
      setError("Kontakte oder Zahlungsanfragen konnten gerade nicht geladen werden.");
      return;
    }
    setContacts((contactData ?? []) as Contact[]);
    setRequests((requestData ?? []) as PaymentRequest[]);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadHub(), 0);
    const supabase = getSupabase();
    if (!supabase) return () => window.clearTimeout(timer);
    const channel = supabase.channel(`payment-hub-${userId}`).on("postgres_changes", { event: "*", schema: "public", table: "payment_requests" }, () => void loadHub()).subscribe();
    return () => { window.clearTimeout(timer); void supabase.removeChannel(channel); };
  }, [loadHub, userId]);

  useEffect(() => {
    const supabase = getSupabase();
    const needle = query.trim();
    if (!supabase || selected || needle.length < 2) return;
    let active = true;
    const timer = window.setTimeout(async () => {
      setSearching(true);
      const { data } = await supabase.rpc("search_users", { p_query: needle });
      if (!active) return;
      setResults(((data ?? []) as Array<{ user_id: string; username: string; display_name: string; avatar_url?: string | null; profile_color?: string | null }>).filter((item) => item.user_id !== userId).map((item) => ({
        id: item.user_id,
        display_name: item.display_name,
        email_hint: `@${item.username}`,
        avatar_url: item.avatar_url ?? null,
        profile_color: item.profile_color ?? null,
      })));
      setSearching(false);
    }, 250);
    return () => { active = false; window.clearTimeout(timer); };
  }, [query, selected, userId]);

  const pendingReceived = useMemo(() => requests.filter((item) => item.target_user_id === userId && item.status === "pending").length, [requests, userId]);

  function resetRecipient() {
    setQuery(""); setSelected(null); setResults([]); setSearching(false);
  }

  function chooseRecipient(recipient: Recipient) {
    setSelected(recipient); setQuery(recipient.display_name); setResults([]); setSearching(false); setError(""); setMessage("");
  }

  async function createRequest(event: React.FormEvent) {
    event.preventDefault();
    const parsed = Number(amount);
    if (!selected) { setError("Wähle zuerst aus, von wem du GIBB anfordern möchtest."); return; }
    if (!Number.isInteger(parsed) || parsed < 1 || parsed > 1000) { setError("Der Betrag muss zwischen 1 und 1’000 GIBB liegen."); return; }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy("create-request"); setError(""); setMessage("");
    const { error: rpcError } = await supabase.rpc("create_payment_request", { p_target_user_id: selected.id, p_amount: parsed, p_note: note.trim() || null });
    setBusy("");
    if (rpcError) { setError(requestError(rpcError.message)); return; }
    setMessage(`${selected.display_name} hat eine Zahlungsanfrage über ${parsed} GIBB erhalten.`);
    setAmount(""); setNote(""); resetRecipient();
    await loadHub();
  }

  async function respondToRequest(item: PaymentRequest, accept: boolean) {
    const supabase = getSupabase();
    if (!supabase) return;
    if (accept && !window.confirm(`${item.amount} GIBB an ${item.requester_label} bezahlen?`)) return;
    setBusy(`request:${item.id}`); setError(""); setMessage("");
    const { error: rpcError } = await supabase.rpc("respond_payment_request", { p_request_id: item.id, p_accept: accept });
    setBusy("");
    if (rpcError) { setError(requestError(rpcError.message)); return; }
    setMessage(accept ? `${item.amount} GIBB wurden an ${item.requester_label} bezahlt.` : `Die Anfrage von ${item.requester_label} wurde abgelehnt.`);
    await Promise.all([loadHub(), onChanged()]);
  }

  async function saveContact(event: React.FormEvent) {
    event.preventDefault();
    if (!selected) { setError("Wähle zuerst eine Person aus."); return; }
    if (nickname.trim().length === 1 || nickname.trim().length > 40) { setError("Der Spitzname muss leer sein oder 2 bis 40 Zeichen haben."); return; }
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy("save-contact"); setError(""); setMessage("");
    const { error: rpcError } = await supabase.rpc("save_contact", { p_contact_user_id: selected.id, p_nickname: nickname.trim() || null });
    setBusy("");
    if (rpcError) { setError("Der Kontakt konnte nicht gespeichert werden."); return; }
    setMessage(`${selected.display_name} wurde zu deinen Kontakten hinzugefügt.`);
    setNickname(""); resetRecipient();
    await loadHub();
  }

  async function toggleFavorite(contact: Contact) {
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(`contact:${contact.contact_id}`);
    const { error: rpcError } = await supabase.rpc("set_contact_favorite", { p_contact_id: contact.contact_id, p_is_favorite: !contact.is_favorite });
    setBusy("");
    if (rpcError) { setError("Der Favorit konnte nicht geändert werden."); return; }
    await loadHub();
  }

  async function removeContact(contact: Contact) {
    if (!window.confirm(`${contact.nickname || contact.display_name} aus deinen Kontakten entfernen?`)) return;
    const supabase = getSupabase();
    if (!supabase) return;
    setBusy(`contact:${contact.contact_id}`);
    const { error: rpcError } = await supabase.rpc("remove_contact", { p_contact_id: contact.contact_id });
    setBusy("");
    if (rpcError) { setError("Der Kontakt konnte nicht entfernt werden."); return; }
    setMessage("Kontakt entfernt.");
    await loadHub();
  }

  function requestFromContact(contact: Contact) {
    setTab("requests");
    chooseRecipient({ id: contact.user_id, display_name: contact.display_name, email_hint: `@${contact.username}`, avatar_url: null });
    window.setTimeout(() => document.getElementById("request-amount")?.focus(), 0);
  }

  return (
    <section className="card card-pad payments-hub" id="requests">
      <div className="section-heading payments-hub-heading"><div><span className="section-number">03</span><h2>Anfragen & Kontakte</h2></div><small>{pendingReceived > 0 ? `${pendingReceived} offene Anfrage${pendingReceived === 1 ? "" : "n"}` : "Alles erledigt"}</small></div>
      <div className="payments-hub-tabs" role="tablist" aria-label="Anfragen und Kontakte">
        <button type="button" role="tab" aria-selected={tab === "requests"} className={tab === "requests" ? "active" : ""} onClick={() => { setTab("requests"); setError(""); setMessage(""); resetRecipient(); }}>Zahlungsanfragen {pendingReceived > 0 && <b>{pendingReceived}</b>}</button>
        <button type="button" role="tab" aria-selected={tab === "contacts"} className={tab === "contacts" ? "active" : ""} onClick={() => { setTab("contacts"); setError(""); setMessage(""); resetRecipient(); }}>Kontakte <b>{contacts.length}</b></button>
      </div>

      {tab === "requests" ? <div className="payments-hub-grid">
        <form className="request-form" onSubmit={createRequest}>
          <div><strong>GIBB anfordern</strong><p>Die andere Person entscheidet selbst, ob sie bezahlt.</p></div>
          <RecipientSearch query={query} selected={selected} results={results} searching={searching} onQuery={(value) => { setQuery(value); setSelected(null); setResults([]); }} onSelect={chooseRecipient} onClear={resetRecipient} />
          <div className="request-fields"><div className="field"><label htmlFor="request-amount">Betrag</label><div className="amount-control"><input className="input" id="request-amount" type="number" inputMode="numeric" min="1" max="1000" step="1" value={amount} onChange={(event) => setAmount(event.target.value)} placeholder="50" /><span>GIBB</span></div></div><div className="field"><label htmlFor="request-note">Grund <span>optional</span></label><input className="input" id="request-note" maxLength={160} value={note} onChange={(event) => setNote(event.target.value)} placeholder="z. B. Mittagessen" /></div></div>
          <button className="primary" type="submit" disabled={busy !== ""}>{busy === "create-request" ? "Wird gesendet …" : "Zahlungsanfrage senden"}</button>
        </form>
        <div className="request-list"><div className="request-list-head"><strong>Letzte Anfragen</strong><span>{requests.length}</span></div>{requests.length === 0 && <div className="empty">Noch keine Zahlungsanfragen.</div>}{requests.map((item) => { const received = item.target_user_id === userId; const pending = item.status === "pending"; return <article className={`payment-request ${received ? "received" : "sent"}`} key={item.id}><div className="payment-request-main"><span>{received ? "Von" : "An"}</span><strong>{received ? item.requester_label : item.target_label}</strong><small>{item.note || "Ohne Nachricht"}</small></div><div className="payment-request-value"><strong>{item.amount} GIBB</strong><span className={`request-status status-${item.status}`}>{statusLabel(item.status)}</span></div>{received && pending && <div className="payment-request-actions"><button className="secondary compact" type="button" disabled={busy !== ""} onClick={() => void respondToRequest(item, false)}>Ablehnen</button><button className="primary compact" type="button" disabled={busy !== ""} onClick={() => void respondToRequest(item, true)}>{busy === `request:${item.id}` ? "Prüft …" : "Bezahlen"}</button></div>}</article>; })}</div>
      </div> : <div className="contacts-layout">
        <form className="contact-form" onSubmit={saveContact}><div><strong>Kontakt hinzufügen</strong><p>Speichere Personen für schnelle Zahlungen und Anfragen.</p></div><RecipientSearch query={query} selected={selected} results={results} searching={searching} onQuery={(value) => { setQuery(value); setSelected(null); setResults([]); }} onSelect={chooseRecipient} onClear={resetRecipient} /><div className="field"><label htmlFor="contact-nickname">Spitzname <span>optional</span></label><input className="input" id="contact-nickname" maxLength={40} value={nickname} onChange={(event) => setNickname(event.target.value)} placeholder="z. B. Mein Lernpartner" /></div><button className="primary" type="submit" disabled={busy !== ""}>{busy === "save-contact" ? "Speichert …" : "Kontakt speichern"}</button></form>
        <div className="contact-list"><div className="request-list-head"><strong>Gespeicherte Kontakte</strong><span>{contacts.length}</span></div>{contacts.length === 0 && <div className="empty">Noch keine Kontakte gespeichert.</div>}{contacts.map((contact) => <article className="contact-row" key={contact.contact_id}><button className={`favorite-button ${contact.is_favorite ? "active" : ""}`} type="button" aria-label={contact.is_favorite ? "Aus Favoriten entfernen" : "Als Favorit markieren"} disabled={busy !== ""} onClick={() => void toggleFavorite(contact)}>★</button><div><button className="user-profile-link" type="button" onClick={() => openUserProfile(contact.user_id)}><strong>{contact.nickname || contact.display_name}</strong><span>{contact.nickname ? `${contact.display_name} · ` : ""}@{contact.username}</span></button></div><div className="contact-actions"><button className="secondary compact" type="button" onClick={() => requestFromContact(contact)}>Anfordern</button><button className="primary compact" type="button" onClick={() => onRecipient({ id: contact.user_id, display_name: contact.display_name, email_hint: `@${contact.username}`, avatar_url: null })}>Senden</button><button className="contact-remove" type="button" aria-label={`${contact.display_name} entfernen`} disabled={busy !== ""} onClick={() => void removeContact(contact)}>×</button></div></article>)}</div>
      </div>}
      {message && <p className="message success-message" role="status">✓ {message}</p>}
      {error && <p className="message error" role="alert">{error}</p>}
    </section>
  );
}

type SearchProps = {
  query: string;
  selected: Recipient | null;
  results: Recipient[];
  searching: boolean;
  onQuery: (value: string) => void;
  onSelect: (recipient: Recipient) => void;
  onClear: () => void;
};

function RecipientSearch({ query, selected, results, searching, onQuery, onSelect, onClear }: SearchProps) {
  return <div className="field recipient-search-field"><label htmlFor="hub-recipient">Person suchen</label><div className={`search-control ${selected ? "has-selection" : ""}`}><input className="input" id="hub-recipient" autoComplete="off" value={query} onChange={(event) => onQuery(event.target.value)} placeholder="Name oder Benutzername …" />{selected && <button type="button" aria-label="Auswahl entfernen" onClick={onClear}>×</button>}</div>{searching && <div className="search-hint">Suche läuft …</div>}{!searching && query.trim().length >= 2 && !selected && results.length === 0 && <div className="search-hint">Keine passende Person gefunden.</div>}{results.length > 0 && <div className="recipient-list">{results.map((item) => <button type="button" key={item.id} className="recipient" onClick={() => onSelect(item)}>{item.avatar_url ? <Image className="recipient-avatar recipient-pic" src={item.avatar_url} alt="" width={36} height={36} unoptimized referrerPolicy="no-referrer" /> : <span className="recipient-avatar" aria-hidden="true" style={item.profile_color ? { background: item.profile_color, color: "#061024" } : undefined}>{item.display_name[0]}</span>}<span><strong>{item.display_name}</strong><small>{item.email_hint}</small></span><b aria-hidden="true">→</b></button>)}</div>}</div>;
}
