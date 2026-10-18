// Mehrschichtiger, animierter Hintergrund (nur Dekoration, reine CSS-Animationen mit transform/opacity).
// Ebenen: fliessender Farbverlauf · Lichtwellen · geometrische Formen · schwebende Partikel.
// Die Parallax-Verschiebung kommt aus --mx/--my (InteractionFx); bei "Bewegung reduzieren" steht alles still.
const PARTICLES = Array.from({ length: 22 }, (_, i) => ({
  left: (i * 37) % 100,
  top: (i * 53) % 100,
  size: 2 + (i % 3),
  delay: (i * 0.9) % 9,
  duration: 9 + (i % 5) * 2,
}));

export function AmbientBackground() {
  return (
    <div className="ambient" aria-hidden="true">
      <div className="ambient-layer ambient-flow" />
      <div className="ambient-layer ambient-par1">
        <svg className="ambient-waves" viewBox="0 0 1440 600" preserveAspectRatio="none">
          <path className="wave w1" d="M0 360 C240 300 480 420 720 360 S1200 300 1440 360" />
          <path className="wave w2" d="M0 420 C260 380 520 470 780 410 S1220 360 1440 420" />
          <path className="wave w3" d="M0 300 C300 250 560 350 840 300 S1260 250 1440 300" />
        </svg>
      </div>
      <div className="ambient-layer ambient-par2">
        <i className="ambient-hex h1" /><i className="ambient-hex h2" /><i className="ambient-hex h3" /><i className="ambient-ring r1" />
      </div>
      <div className="ambient-layer ambient-par3">
        {PARTICLES.map((p, i) => (
          <span key={i} className={`ambient-dot${i % 4 === 0 ? " gold" : ""}${i >= 12 ? " desktop-only" : ""}`} style={{ left: `${p.left}%`, top: `${p.top}%`, width: p.size, height: p.size, animationDelay: `${p.delay}s`, animationDuration: `${p.duration}s` }} />
        ))}
      </div>
    </div>
  );
}
