// Over-7-day build detection for the app itself (`prefs.staleBuild`): dev builds (builtAt=0) never prompt,
// fresh release builds stay quiet until TestClock crosses STALE_BUILD_MS, and stale builds prompt immediately.
import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { holdLanguage } from "../src/i18n.ts";
import * as prefsMod from "../src/prefs.ts";
import { isBuildStale, ownBuiltAt, setOwnBuiltAt, STALE_BUILD_MS } from "../src/station/oldest.ts";
import { prefs, setup, ui } from "./views-rig.ts";

holdLanguage();

afterEach(() => {
  setOwnBuiltAt(0);
});

test("isBuildStale: 0/dev never stale, <7d false, >=7d true", () => {
  const now = 1_800_000_000_000;
  assert.equal(isBuildStale(0, now), false);
  assert.equal(isBuildStale(-1, now), false);
  assert.equal(isBuildStale(Number.NaN, now), false);
  assert.equal(isBuildStale(now - STALE_BUILD_MS + 1, now), false);
  assert.equal(isBuildStale(now - STALE_BUILD_MS, now), true);
  assert.equal(isBuildStale(now - STALE_BUILD_MS - 86_400_000, now), true);
});

test("prefs.staleBuild is omitted in dev (builtAt=0) and flips reactively when TestClock crosses 7 days", async () => {
  setOwnBuiltAt(0);
  const t = setup({ all: true });
  const u = ui();
  t.set(prefs(), {});
  t.subscribe(1, prefs());
  await t.read(u, 1);
  assert.equal("staleBuild" in u.value, false);

  // Set a release build timestamp with 30s left before 7 days
  const now = t.host.nowMs();
  setOwnBuiltAt(now - STALE_BUILD_MS + 30_000);
  await t.read(u, 1);
  assert.equal(u.value.staleBuild, undefined);

  // Advance TestClock across the 7-day deadline: prefs emits staleBuild: true reactively with zero polling
  await t.host.time.pass(30_000);
  await t.read(u, 1);
  assert.equal(u.value.staleBuild, true);
});

test("prefs.staleBuild is true immediately on start when build is already >=7 days old", async () => {
  const t = setup({ all: true });
  setOwnBuiltAt(t.host.nowMs() - STALE_BUILD_MS - 5000);
  const u = ui();
  t.set(prefs(), {});
  t.subscribe(1, prefs());
  await t.read(u, 1);
  assert.equal(u.value.staleBuild, true);
});

test("client.device builtAt updates ownBuiltAt and triggers prefs.staleBuild", async () => {
  const t = setup({ all: true });
  const u = ui();
  t.set(prefs(), {});
  t.subscribe(1, prefs());
  await t.read(u, 1);
  assert.equal(u.value.staleBuild, undefined);

  const oldBuiltAt = t.host.nowMs() - STALE_BUILD_MS - 10_000;
  prefsMod.device(t.data, { app: "desktop", build: "0.1.9000", builtAt: oldBuiltAt });
  assert.equal(ownBuiltAt(), oldBuiltAt);
  await t.read(u, 1);
  assert.equal(u.value.staleBuild, true);
});
