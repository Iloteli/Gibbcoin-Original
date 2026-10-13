"use client";

import { useEffect, useState } from "react";
import QRCode from "qrcode";

// Swiss QR Code (QR-Rechnung, Version 2.0) für eine normale IBAN:
// Referenztyp NON, der Bestell-Code steht als "Zusätzliche Informationen" (Mitteilung).
type Props = { iban: string; name: string; street?: string; zip: string; city: string; amountRappen: number; message: string };

export function swissQrPayload({ iban, name, street = "", zip, city, amountRappen, message }: Props) {
  const clean = (value: string, max: number) => value.replace(/[\r\n]+/g, " ").trim().slice(0, max);
  return [
    "SPC", "0200", "1",
    iban.replace(/\s+/g, "").toUpperCase(),
    "S", clean(name, 70), clean(street, 70), "", clean(zip, 16), clean(city, 35), "CH",
    "", "", "", "", "", "", "",                     // endgültige Zahlungsempfängerin (leer)
    (amountRappen / 100).toFixed(2), "CHF",
    "", "", "", "", "", "", "",                     // Zahlungspflichtige/r (leer)
    "NON", "",
    clean(message, 140),
    "EPD",
  ].join("\r\n");
}

export function SwissQrBill(props: Props) {
  const [src, setSrc] = useState("");
  const payload = swissQrPayload(props);
  useEffect(() => {
    let alive = true;
    QRCode.toDataURL(payload, { errorCorrectionLevel: "M", margin: 0, width: 280, color: { dark: "#000000", light: "#ffffff" } })
      .then((url) => { if (alive) setSrc(url); })
      .catch(() => { if (alive) setSrc(""); });
    return () => { alive = false; };
  }, [payload]);
  if (!src) return null;
  return (
    <figure className="swiss-qr">
      <div className="swiss-qr-code">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={src} alt="QR-Rechnung zum Scannen in der Banking-App" width={220} height={220} />
        <svg className="swiss-cross" viewBox="0 0 19.8 19.8" aria-hidden="true"><rect width="19.8" height="19.8" fill="#fff" /><rect x="1.4" y="1.4" width="17" height="17" fill="#000" /><rect x="8.3" y="4" width="3.3" height="11" fill="#fff" /><rect x="4.4" y="7.9" width="11" height="3.3" fill="#fff" /></svg>
      </div>
      <figcaption>In der Banking-App (PostFinance, UBS, Raiffeisen …) <b>„QR-Rechnung scannen“</b> wählen – IBAN, Betrag und Code sind schon ausgefüllt.</figcaption>
    </figure>
  );
}
