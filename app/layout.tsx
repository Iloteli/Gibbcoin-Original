import type { Metadata, Viewport } from "next";
import { DeviceClass } from "./components/DeviceClass";
import { ServiceWorkerRegistration } from "./components/ServiceWorkerRegistration";
import { MaintenanceWatch } from "./components/MaintenanceWatch";
import "./globals.css";

const title = "GIBB Coin – Dein Campus Wallet";
const description = "GIBB Coins sicher senden, empfangen, kaufen und mit persönlichen Benachrichtigungen verwalten.";
const metadataBase = new URL("https://gibbcoin.netlify.app");

export const viewport: Viewport = {
  themeColor: "#070b0a",
  width: "device-width",
  initialScale: 1,
  // Ohne cover bleibt env(safe-area-inset-*) auf iPhones bei 0. Zusammen mit
  // der durchscheinenden Statusleiste liefe der Inhalt sonst unter Notch und
  // Home-Indikator.
  viewportFit: "cover",
};

export const metadata: Metadata = {
  metadataBase,
  title,
  description,
    applicationName: "GIBB Coin",
    manifest: "/manifest.json",
    appleWebApp: {
      capable: true,
      statusBarStyle: "black-translucent",
      title: "GIBB Coin",
    },
    icons: {
      icon: [
        { url: "/favicon.svg", type: "image/svg+xml" },
        { url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
        { url: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
      ],
      apple: [{ url: "/icons/icon-180.png", sizes: "180x180", type: "image/png" }],
    },
    openGraph: {
      title,
      description,
      type: "website",
      siteName: "GIBB Coin",
      url: metadataBase,
      images: [{ url: "/og.png", width: 1672, height: 941, alt: "GIBB Coin – Dein Campus Wallet" }],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: ["/og.png"],
    },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="de">
      <body><DeviceClass /><ServiceWorkerRegistration /><MaintenanceWatch />{children}</body>
    </html>
  );
}
