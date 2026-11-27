// Unprotected stations in a safe-mode workspace: views surface `unprotected: true`, allow `protect: true` even when
// offline/blocked so owners on a signing device are never stranded without a Protect action, and map legacy
// `credential_refused` on unprotected offline stations to security-mode waiting state instead of generic offline.
import assert from "node:assert/strict";
import { test } from "node:test";
import { t } from "../src/i18n.ts";
import type { ViewsEnv } from "../src/views/views.ts";
import { setup, ui } from "./views-rig.ts";

const WS = "ws";
const S_PROTECTED = "st1";
const S_UNPROTECTED = "st2";

type Diag = NonNullable<ReturnType<NonNullable<ViewsEnv["linkDiag"]>>>;

function makeRig(opts: { canProtect: boolean; diag?: Record<string, Diag> }) {
  const r = setup({
    all: true,
    env: () => ({
      guard: (scope) =>
        scope === WS
          ? {
              protects: (id) => id === S_PROTECTED,
              can: () => opts.canProtect,
            }
          : null,
      linkDiag: (station) => opts.diag?.[station] ?? null,
    }),
  });
  r.set({ topic: "workspace", workspace: WS }, {
    id: WS,
    name: "Team",
    role: "owner",
    stations: [
      { id: S_PROTECTED, name: "Willow", online: true, last_seen: 1000, version: "0.1.11874" },
      { id: S_UNPROTECTED, name: "NewBox", online: false, last_seen: null, version: "0.1.11853" },
    ],
  });
  return r;
}

test("unprotected offline station with lock_station waiting exposes unprotected=true, protect=true for signing owner, and blocked problem", async () => {
  const r = makeRig({ canProtect: true });
  const addr = `${WS}/${S_UNPROTECTED}`;
  const waitingText = t("core-logic.mesh.lock_station.waiting");

  const list = ui();
  const page = ui();
  r.subscribe(1, { topic: "stations", scope: WS });
  r.subscribe(2, { topic: "station", scope: WS, station: addr });
  r.set({ topic: "link", station: addr }, { state: "offline", cause: "lock", message: waitingText });
  await r.readAll([[list, 1], [page, 2]]);

  const row = list.value.find((s: { id: string }) => s.id === S_UNPROTECTED);
  const protectedRow = list.value.find((s: { id: string }) => s.id === S_PROTECTED);
  assert.equal(protectedRow.unprotected, undefined);
  assert.equal(protectedRow.protect, undefined);

  assert.equal(row.unprotected, true);
  assert.equal(row.protect, true, "signing owner sees protect even when station is offline/blocked");
  assert.equal(row.summary, t("core-views.station.lock_short"));
  assert.equal(row.line, t("core-views.station.lock_short"));
  assert.equal(row.blocked, waitingText);
  assert.equal(row.problems[0]?.key, "blocked");

  assert.equal(page.value.unprotected, true);
  assert.equal(page.value.protect, true);
  assert.equal(page.value.blocked, waitingText);
  assert.equal(page.value.problems[0]?.key, "blocked");
});

test("unprotected offline station without signing capability sets unprotected=true and omits protect", async () => {
  const r = makeRig({ canProtect: false });
  const addr = `${WS}/${S_UNPROTECTED}`;

  const page = ui();
  r.subscribe(1, { topic: "station", scope: WS, station: addr });
  r.set({ topic: "link", station: addr }, { state: "offline", cause: "lock", message: t("core-logic.mesh.lock_station.waiting") });
  await r.read(page, 1);
  assert.equal(page.value.unprotected, true);
  assert.equal(page.value.protect, undefined);
});

test("legacy unprotected station failing with credential_refused + unknown credential key is classified as security-mode waiting instead of away", async () => {
  const addr = `${WS}/${S_UNPROTECTED}`;
  const r = makeRig({
    canProtect: true,
    diag: {
      [addr]: {
        lastErrorCode: "credential_refused",
        lastEnd: "unknown credential key",
      } as unknown as Diag,
    },
  });

  const list = ui();
  const page = ui();
  r.subscribe(1, { topic: "stations", scope: WS });
  r.subscribe(2, { topic: "station", scope: WS, station: addr });
  r.set({ topic: "link", station: addr }, { state: "offline", cause: "unreached", message: "unknown credential key" });
  await r.readAll([[list, 1], [page, 2]]);
  const row = list.value.find((s: { id: string }) => s.id === S_UNPROTECTED);
  assert.equal(row.line, t("core-views.station.lock_short"));
  assert.equal(page.value.unprotected, true);
  assert.equal(page.value.protect, true);
  assert.equal(page.value.summary, t("core-views.station.lock_short"));
  assert.equal(page.value.blocked, t("core-logic.mesh.lock_station.waiting"));
  assert.deepEqual(page.value.problems.map((p: { key: string }) => p.key), ["blocked"]);
});

test("ordinary credential_refused (expired/revoked) does not trigger legacyLockWait", async () => {
  const addr = `${WS}/${S_UNPROTECTED}`;
  for (const reason of ["credential expired", "credential revoked"]) {
    const r = makeRig({
      canProtect: true,
      diag: {
        [addr]: {
          lastErrorCode: "credential_refused",
          lastEnd: reason,
        } as unknown as Diag,
      },
    });
    const page = ui();
    r.subscribe(1, { topic: "station", scope: WS, station: addr });
    r.set({ topic: "link", station: addr }, { state: "offline", cause: "unreached", message: reason });
    await r.read(page, 1);
    assert.equal(page.value.unprotected, true);
    assert.equal(page.value.protect, true);
    assert.equal(page.value.blocked, undefined, `ordinary credential_refused (${reason}) must not be treated as lock waiting`);
  }
});

test("unprotected station that is simply offline/unreached keeps unprotected=true, protect=true, and blocked=undefined", async () => {
  const addr = `${WS}/${S_UNPROTECTED}`;
  const r = makeRig({ canProtect: true });
  const page = ui();
  r.subscribe(1, { topic: "station", scope: WS, station: addr });
  r.set({ topic: "link", station: addr }, { state: "offline", cause: "unreached", message: "timed out" });
  await r.read(page, 1);
  assert.equal(page.value.unprotected, true);
  assert.equal(page.value.protect, true);
  assert.equal(page.value.blocked, undefined);
  assert.equal(page.value.problems[0]?.key, "away");
});

test("explicit network/updating causes and stale diag never trigger legacyLockWait", async () => {
  const addr = `${WS}/${S_UNPROTECTED}`;
  for (const [cause, message] of [
    ["network", "unknown credential key"],
    ["updating", "unknown credential key"],
    ["unreached", "timed out"],
  ] as const) {
    const r = makeRig({
      canProtect: true,
      diag: {
        [addr]: {
          lastErrorCode: "credential_refused",
          lastEnd: "unknown credential key",
        } as unknown as Diag,
      },
    });
    const page = ui();
    r.subscribe(1, { topic: "station", scope: WS, station: addr });
    r.set({ topic: "link", station: addr }, { state: "offline", cause, message });
    await r.read(page, 1);
    assert.equal(page.value.unprotected, true);
    assert.equal(page.value.protect, true);
    assert.equal(page.value.blocked, undefined, `cause=${cause} message=${message} must not set blocked`);
  }
});
