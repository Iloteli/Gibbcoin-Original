"use client";

import { useEffect } from "react";

// Erkennt die Geräteklasse und schreibt sie als Attribute auf <html>, damit CSS
// gezielt darauf reagieren kann. Reine Breiten-Breakpoints reichen dafür nicht:
// ein schmales Desktop-Fenster ist kein Handy, und ein Tablet im Querformat ist
// breit, wird aber mit dem Finger bedient.
//
// Die Attribute werden bewusst erst nach dem Hydrieren gesetzt. Der Server
// kennt das Gerät nicht, und ein geratener Wert im HTML würde beim Abgleich
// auseinanderlaufen.
type UserAgentData = { mobile?: boolean };

function readDevice() {
  const coarse = window.matchMedia("(pointer: coarse)").matches;
  const touch = coarse || navigator.maxTouchPoints > 0;
  const width = window.innerWidth;

  // navigator.userAgentData.mobile ist das einzige direkte Signal des Browsers.
  // Wo es fehlt (Safari, Firefox), entscheiden Zeigegerät und Breite gemeinsam.
  const hinted = (navigator as Navigator & { userAgentData?: UserAgentData }).userAgentData?.mobile;
  const phone = hinted ?? (touch && width < 768);
  const device = phone ? "mobile" : touch && width < 1200 ? "tablet" : "desktop";

  return {
    device,
    pointer: coarse ? "coarse" : "fine",
    standalone: window.matchMedia("(display-mode: standalone)").matches
      || (navigator as Navigator & { standalone?: boolean }).standalone === true,
  };
}

export function DeviceClass() {
  useEffect(() => {
    const root = document.documentElement;
    const apply = () => {
      const { device, pointer, standalone } = readDevice();
      root.dataset.device = device;
      root.dataset.pointer = pointer;
      root.dataset.standalone = standalone ? "true" : "false";
    };

    apply();

    const queries = [
      window.matchMedia("(pointer: coarse)"),
      window.matchMedia("(display-mode: standalone)"),
      window.matchMedia("(max-width: 767px)"),
      window.matchMedia("(max-width: 1199px)"),
    ];
    queries.forEach((query) => query.addEventListener("change", apply));
    window.addEventListener("orientationchange", apply);
    window.addEventListener("resize", apply);

    return () => {
      queries.forEach((query) => query.removeEventListener("change", apply));
      window.removeEventListener("orientationchange", apply);
      window.removeEventListener("resize", apply);
    };
  }, []);

  return null;
}
