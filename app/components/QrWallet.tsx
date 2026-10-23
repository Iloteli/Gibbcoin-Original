"use client";

import jsQR from "jsqr";
import { QRCodeSVG } from "qrcode.react";
import { useCallback, useEffect, useRef, useState } from "react";
import { getSupabase } from "../lib/supabase";
import { openShopPayment, payIdFromText } from "./ShopCheckout";
import type { Recipient } from "../lib/types";

type Props = {
  userId: string;
  walletId?: string;
  onRecipient: (recipient: Recipient) => void;
};

type RecipientLookup = {
  user_id: string;
  username: string;
  display_name: string;
  wallet_code: string;
};

type BarcodeDetectorInstance = {
  detect: (source: unknown) => Promise<Array<{ rawValue: string }>>;
};

type BarcodeDetectorConstructor = new (options: { formats: string[] }) => BarcodeDetectorInstance;

const walletLinkPattern = /^(?:gibbcoin:\/\/pay\?user=|https:\/\/[^/?#]+(?:\/[^?#]*)?\?pay=)([0-9a-f-]{36})$/i;

export function QrWallet({ userId, walletId, onRecipient }: Props) {
  const [scannerActive, setScannerActive] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [copied, setCopied] = useState(false);
  const scannerVideo = useRef<HTMLVideoElement>(null);
  const scannerCanvas = useRef<HTMLCanvasElement>(null);
  const scannerStream = useRef<MediaStream | null>(null);
  const scannerTimer = useRef<number | null>(null);
  const lastRejectedCode = useRef<string | null>(null);
  const qrValue = typeof window !== "undefined" && window.location.protocol === "https:"
    ? `${window.location.origin}/?pay=${userId}`
    : `gibbcoin://pay?user=${userId}`;
  const walletCode = walletId ? walletId.replaceAll("-", "").slice(-6).toUpperCase() : "------";

  const stopScanner = useCallback(() => {
    if (scannerTimer.current !== null) window.clearTimeout(scannerTimer.current);
    scannerTimer.current = null;
    scannerStream.current?.getTracks().forEach((track) => track.stop());
    scannerStream.current = null;
    if (scannerVideo.current) scannerVideo.current.srcObject = null;
    lastRejectedCode.current = null;
    setScannerActive(false);
  }, []);

  useEffect(() => () => {
    if (scannerTimer.current !== null) window.clearTimeout(scannerTimer.current);
    scannerStream.current?.getTracks().forEach((track) => track.stop());
  }, []);

  const handleScannedValue = useCallback(async (rawValue: string) => {
    // QR-Code einer Laden-Kasse: Bezahlen-Fenster öffnen
    const payId = payIdFromText(rawValue);
    if (payId) { stopScanner(); setError(""); openShopPayment(payId); return true; }
    const match = rawValue.match(walletLinkPattern);
    const recipientId = match?.[1];
    if (!recipientId || recipientId === userId) {
      if (lastRejectedCode.current !== rawValue) {
        setError(recipientId === userId ? "Das ist dein eigener Wallet-QR-Code." : "Dieser QR-Code gehört nicht zu einem gültigen GIBB-Wallet.");
        lastRejectedCode.current = rawValue;
      }
      return false;
    }

    const supabase = getSupabase();
    if (!supabase) return false;
    const { data, error: lookupError } = await supabase.rpc("get_recipient", { p_user_id: recipientId });
    const recipient = (data as RecipientLookup[] | null)?.[0];
    if (lookupError || !recipient) {
      if (lastRejectedCode.current !== rawValue) {
        setError("Dieses GIBB-Wallet wurde nicht gefunden.");
        lastRejectedCode.current = rawValue;
      }
      return false;
    }

    stopScanner();
    setError("");
    setNotice(`${recipient.display_name} wurde als Empfänger übernommen. Betrag eingeben und Zahlung bestätigen.`);
    onRecipient({
      id: recipient.user_id,
      display_name: recipient.display_name,
      email_hint: `@${recipient.username}`,
      avatar_url: null,
    });
    return true;
  }, [onRecipient, stopScanner, userId]);

  async function startScanner() {
    if (scannerActive) return;
    setError("");
    setNotice("");
    if (!navigator.mediaDevices?.getUserMedia) {
      setError("Die Kamera wird von diesem Gerät nicht unterstützt. Du kannst den Zahlungslink weiterhin kopieren.");
      return;
    }

    try {
      const Detector = (window as Window & { BarcodeDetector?: BarcodeDetectorConstructor }).BarcodeDetector;
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: { ideal: "environment" }, width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
      scannerStream.current = stream;
      lastRejectedCode.current = null;
      setScannerActive(true);

      window.setTimeout(async () => {
        try {
          const video = scannerVideo.current;
          if (!video || scannerStream.current !== stream) {
            stream.getTracks().forEach((track) => track.stop());
            return;
          }
          video.srcObject = stream;
          await video.play();

          let detector: BarcodeDetectorInstance | null = null;
          if (Detector) {
            try { detector = new Detector({ formats: ["qr_code"] }); } catch { detector = null; }
          }

          const scan = async () => {
            const currentVideo = scannerVideo.current;
            if (!currentVideo || scannerStream.current !== stream) return;
            let rawValue = "";

            if (detector) {
              try {
                const codes = await detector.detect(currentVideo);
                rawValue = codes[0]?.rawValue ?? "";
              } catch {
                // Der Canvas-Fallback prüft denselben Frame in Browsern ohne BarcodeDetector-Unterstützung.
              }
            }

            if (!rawValue && currentVideo.readyState >= 2 && currentVideo.videoWidth > 0 && scannerCanvas.current) {
              const canvas = scannerCanvas.current;
              const scale = Math.min(1, 800 / currentVideo.videoWidth);
              canvas.width = Math.max(1, Math.round(currentVideo.videoWidth * scale));
              canvas.height = Math.max(1, Math.round(currentVideo.videoHeight * scale));
              const context = canvas.getContext("2d", { willReadFrequently: true });
              if (context) {
                context.drawImage(currentVideo, 0, 0, canvas.width, canvas.height);
                const image = context.getImageData(0, 0, canvas.width, canvas.height);
                rawValue = jsQR(image.data, image.width, image.height, { inversionAttempts: "attemptBoth" })?.data ?? "";
              }
            }

            if (rawValue && await handleScannedValue(rawValue)) return;
            scannerTimer.current = window.setTimeout(() => void scan(), rawValue ? 900 : 300);
          };

          void scan();
        } catch {
          stopScanner();
          setError("Die Kamera konnte nicht gestartet werden. Bitte prüfe die Browser-Berechtigung.");
        }
      }, 100);
    } catch {
      stopScanner();
      setError("Kamerazugriff wurde nicht erlaubt. Du kannst den Zahlungslink weiterhin kopieren.");
    }
  }

  async function copyPaymentLink() {
    setError("");
    try {
      await navigator.clipboard.writeText(qrValue);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2200);
    } catch {
      setError("Der Zahlungslink konnte auf diesem Gerät nicht kopiert werden.");
    }
  }

  return (
    <section className="card card-pad qr-wallet" id="qr-code">
      <div className="section-heading">
        <div><span className="section-number">02</span><h2>QR-Code</h2></div>
        <small>Teilen & sicher scannen</small>
      </div>
      <div className="qr-layout">
        <article className="qr-code-card">
          <div className="qr-frame">
            <QRCodeSVG value={qrValue} size={220} level="H" bgColor="#ffffff" fgColor="#07100d" title="Persönlicher GIBB-Coin-QR-Code" />
          </div>
          <div className="qr-wallet-label"><span>Dein Wallet</span><strong>•••• {walletCode}</strong></div>
          <p>Andere Benutzer können diesen Code scannen, um dich als Empfänger auszuwählen. Er enthält keine E-Mail-Adresse.</p>
          <div className="qr-actions">
            <button className="primary" type="button" onClick={() => void copyPaymentLink()}>{copied ? "Link kopiert ✓" : "Zahlungslink kopieren"}</button>
            <button className="secondary" type="button" aria-pressed={scannerActive} onClick={scannerActive ? stopScanner : () => void startScanner()}>{scannerActive ? "Scanner stoppen" : "QR-Code scannen"}</button>
          </div>
        </article>

        <article className="qr-scanner-card">
          <div className="qr-scanner-heading"><span>Kamera-Scanner</span><b className={scannerActive ? "active" : ""}>{scannerActive ? "Kamera aktiv" : "Bereit"}</b></div>
          <h3>{scannerActive ? "QR-Code in die Kamera halten" : "Wallet sicher erkennen"}</h3>
          {scannerActive ? (
            <div className="camera-view">
              <video ref={scannerVideo} muted playsInline aria-label="Kameravorschau für QR-Code" />
              <canvas ref={scannerCanvas} aria-hidden="true" />
              <span className="scan-corners" aria-hidden="true" />
              <span className="scan-line" aria-hidden="true" />
              <small><b aria-hidden="true">●</b> Automatische Erkennung läuft</small>
            </div>
          ) : (
            <div className="camera-placeholder">
              <span aria-hidden="true">▦</span>
              <p>Scanner starten, Kamerazugriff erlauben und den QR-Code eines anderen GIBB-Wallets erfassen.</p>
            </div>
          )}
          <ol className="qr-steps">
            <li><span>1</span>QR-Code scannen</li>
            <li><span>2</span>Empfänger wird übernommen</li>
            <li><span>3</span>Betrag selbst eingeben</li>
            <li><span>4</span>Zahlung bewusst bestätigen</li>
          </ol>
        </article>
      </div>
      {notice && <p className="message success-message qr-message" role="status">✓ {notice}</p>}
      {error && <p className="message error qr-message" role="alert">{error}</p>}
      <p className="qr-security-note"><span aria-hidden="true">✓</span> Ein Scan sendet niemals automatisch GIBB.</p>
    </section>
  );
}
