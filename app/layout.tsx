import type { Metadata, Viewport } from "next";
import { headers } from "next/headers";
import { ServiceWorkerRegistration } from "./components/ServiceWorkerRegistration";
import "./globals.css";

const title = "GIBB Coin – Dein Campus Wallet";
const description = "GIBB Coins sicher senden, empfangen, kaufen und mit persönlichen Benachrichtigungen verwalten.";

export const viewport: Viewport = {
  themeColor: "#070b0a",
};

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const forwardedHost = requestHeaders.get("x-forwarded-host")?.split(",")[0]?.trim();
  const requestedHost = forwardedHost || requestHeaders.get("host") || "gibb-coin.kbb8vy5sjy.workers.dev";
  const host = /^[a-z0-9.-]+(?::\d+)?$/i.test(requestedHost) ? requestedHost : "gibb-coin.kbb8vy5sjy.workers.dev";
  const forwardedProtocol = requestHeaders.get("x-forwarded-proto")?.split(",")[0]?.trim();
  const protocol = forwardedProtocol === "http" || forwardedProtocol === "https" ? forwardedProtocol : host.startsWith("localhost") ? "http" : "https";
  const origin = new URL(`${protocol}://${host}`);
  const socialImage = new URL("/og.png", origin).toString();

  return {
    metadataBase: origin,
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
      url: origin,
      images: [{ url: socialImage, width: 1672, height: 941, alt: "GIBB Coin – Dein Campus Wallet" }],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [socialImage],
    },
  };
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="de">
      <body><ServiceWorkerRegistration />{children}</body>
    </html>
  );
}
