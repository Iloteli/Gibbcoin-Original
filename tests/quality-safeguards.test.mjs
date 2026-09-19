import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("dashboard exposes keyboard navigation and onboarding guidance", async () => {
  const dashboard = await read("app/components/Dashboard.tsx");
  assert.match(dashboard, /KeyboardHelp/);
  assert.match(dashboard, /OnboardingGuide/);
  assert.match(dashboard, /aria-label="Wallet-Bereiche"/);
});

test("offline activity reporting is clearly marked as a saved snapshot", async () => {
  const summary = await read("app/components/ActivitySummary.tsx");
  assert.match(summary, /Gespeicherter Stand/);
  assert.match(summary, /können unvollständig sein/);
  assert.match(summary, /transactions/);
});

test("UI failures provide a recoverable reload path", async () => {
  const boundary = await read("app/components/AppErrorBoundary.tsx");
  const app = await read("app/components/GibbCoinApp.tsx");
  assert.match(boundary, /Oberfläche neu laden/);
  assert.match(boundary, /window\.location\.reload/);
  assert.match(app, /AppErrorBoundary/);
});
