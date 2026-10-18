// GIBB-Coin-Zeichen: Sechseck-Münze mit geometrischem G, Verlauf Electric Blue → Cyan → Violett.
export function BrandMark({ size = 40, glow = true, className = "" }: { size?: number; glow?: boolean; className?: string }) {
  return (
    <svg className={`brand-mark ${glow ? "glow" : ""} ${className}`} width={size} height={size} viewBox="0 0 64 64" role="img" aria-label="GIBB Coin">
      <defs>
        <linearGradient id="gibb-mark-fill" x1="8" y1="4" x2="58" y2="62" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#2f7bff" />
          <stop offset=".55" stopColor="#3ee0ff" />
          <stop offset="1" stopColor="#8b5cff" />
        </linearGradient>
        <linearGradient id="gibb-mark-edge" x1="32" y1="2" x2="32" y2="62" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#ffffff" stopOpacity=".75" />
          <stop offset="1" stopColor="#ffffff" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d="M32 3 57 17.5v29L32 61 7 46.5v-29Z" fill="url(#gibb-mark-fill)" />
      <path d="M32 3 57 17.5v29L32 61 7 46.5v-29Z" fill="none" stroke="url(#gibb-mark-edge)" strokeWidth="1.5" />
      <path d="M32 11 50 21.5v21L32 53 14 42.5v-21Z" fill="#070b16" fillOpacity=".55" />
      {/* Geometrisches G */}
      <path d="M40.5 25.5A10.5 10.5 0 1 0 42.5 34H33" fill="none" stroke="#ffffff" strokeWidth="4.2" strokeLinecap="round" strokeLinejoin="round" />
      <circle cx="44.5" cy="20.5" r="2.2" fill="#f5c66b" />
    </svg>
  );
}
