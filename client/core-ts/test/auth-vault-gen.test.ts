// Adversarial tests for PR-B2s:
// - Authoritative content-digest driven `(account, workspace)` `authGen` (0 false invalidations)
// - Routine workspace switch A -> B preserves A's cache and other windows
// - Independent `vaultGen` for single-vault expiry (V1 locked, V2 & non-vault untouched) and explicit `vault.lock`
// - Full Store projection pipeline invalidation (`entry.sent`, `entry.input`, `entry.value`, `entry.read`, `#kept`, `#from`, `#have`)
// - Underlying old records intentionally retained in `#held` while re-authorization is pending: 0 old markers visible
// - Delayed write call authorization verification (`verifyCallAuth` / `Core.receive`)
// - Unconditional `sensitive` ceiling (21 topics + `stationPart(machineLogins|logins)`) + `station`/`profiles` sanitized retention
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { Deferred, Effect } from "effect";
import { apply as applyOps, type Op } from "../src/delta.ts";
import { STORAGE_KEY } from "../src/accounts.ts";
import { AuthCapability, AuthGenTracker } from "../src/auth-gen.ts";
import { Core, syncWorkspaceAuth } from "../src/core.ts";
import { DEVICE_TABLES } from "../src/data.ts";
import { HostError } from "../src/host.ts";
import { parseClientMessage, type CoreMessage, type Topic } from "../src/protocol.ts";
import { Runner } from "../src/runtime.ts";
import { Retold } from "../src/station/retold.ts";
import { logKey } from "../src/station/link.ts";
import { COALESCE_MS, EVICT_AFTER_MS, Store } from "../src/store.ts";
import { DEVICE_GLOBAL_TOPIC_SET, sanitizeKeptValue } from "../src/topic-policy.ts";
import { FakeHost, jsonResponse } from "../src/testing.ts";
import { account, nowS } from "./helpers.ts";

function setup() {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  const pass = (ms: number) => host.time.pass(ms, ms > 1000 ? 100 : 10);
  return { host, store, runner, pass };
}

describe("PR-B2s authGen / vaultGen boundaries and sensitive ceiling", () => {
  it("advances authGen only on authoritative digest changes and never on routine workspace switch A -> B", async () => {
    const { host, store, pass } = setup();
    store.registerClient(1, 101);
    store.registerClient(2, 102);
    host.takeEmitted();

    // Seed initial accounts & workspaces
    assert.equal(store.authGen.syncAccounts(["acct-1"]), false);
    assert.equal(store.authGen.syncWorkspace("ws-a", JSON.stringify(["acct-1", "owner", true, false, true])), false);
    assert.equal(store.authGen.syncWorkspace("ws-b", JSON.stringify(["acct-1", "owner", true, false, true])), false);

    // Identical re-sync (e.g. token refresh) must NOT bump authGen
    assert.equal(store.authGen.syncAccounts(["acct-1"]), false);
    assert.equal(store.authGen.syncWorkspace("ws-a", JSON.stringify(["acct-1", "owner", true, false, true])), false);
    assert.equal(store.authGen.globalGen, 1);
    assert.equal(store.authGen.workspaceAuthGen("ws-a"), 1);

    const wsATopic: Topic = { topic: "chats", scope: "ws-a", mine: false };
    const wsBTopic: Topic = { topic: "chats", scope: "ws-b", mine: false };

    // Both Window 1 and Window 2 subscribe to ws-a
    store.subscribe(1, 1, wsATopic);
    store.subscribe(2, 1, wsATopic);
    store.set(wsATopic, { ok: { items: [{ id: "a1", marker: "WS_A_OK" }] } });
    await pass(COALESCE_MS * 2);
    host.takeEmitted();

    // Window 1 switches from ws-a -> ws-b (unsubscribes ws-a with keep=true, subscribes ws-b)
    store.unsubscribe(1, 1, true);
    const keepOut = host.takeEmitted() as [number, { id: number; v: string | null }][];
    assert.equal(keepOut.length, 1);
    const tokenA = keepOut[0]![1].v;
    assert.ok(typeof tokenA === "string" && tokenA.length > 0);

    store.subscribe(1, 2, wsBTopic);
    store.set(wsBTopic, { ok: { items: [{ id: "b1", marker: "WS_B_OK" }] } });
    await pass(COALESCE_MS * 2);
    const bMsgs = host.takeEmitted();
    assert.equal(bMsgs.filter(([c]) => c === 1).length, 1);
    assert.equal(bMsgs.filter(([c]) => c === 2).length, 0, "Window 2 in ws-a is unaffected by Window 1 switch");

    // AuthGen did not advance; returning Window 1 to ws-a hits cache (`same: true`)
    assert.equal(store.authGen.workspaceAuthGen("ws-a"), 1);
    store.subscribe(1, 3, wsATopic, false, undefined, tokenA!);
    const backMsgs = host.takeEmitted() as [number, Record<string, unknown>][];
    assert.equal(backMsgs.length, 1);
    assert.equal(backMsgs[0]![1].same, true, "returning to ws-a hits cache with same: true");

    // Role downgrade on ws-a bumps ONLY ws-a authGen, NOT ws-b!
    assert.equal(store.authGen.syncWorkspace("ws-a", JSON.stringify(["acct-1", "member", true, false, true])), true);
    assert.equal(store.authGen.workspaceAuthGen("ws-a"), 2);
    assert.equal(store.authGen.workspaceAuthGen("ws-b"), 1, "ws-b authGen must remain unchanged");
  });

  it("invalidates full projection pipeline (sent/input/value/read/held) and blocks old records until re-authorized", async () => {
    const { host, store, pass } = setup();
    store.registerClient(1, 201);
    host.takeEmitted();

    const wsTopic: Topic = { topic: "workspace", workspace: "ws-1" };
    // Intentionally keep old record in underlying held Data store!
    let heldRecord: unknown = { id: "ws-1", name: "OLD_SECRET_MARKER" };
    let authorized = true;
    store.setHeld((t) => (t.topic === "workspace" && t.workspace === "ws-1" ? heldRecord : undefined));
    store.setAuthorize((t) => (t.workspace === "ws-1" ? authorized : true));

    // Initial authorized read & direct set + keep
    store.subscribe(1, 10, wsTopic);
    await pass(COALESCE_MS * 2);
    const first = host.takeEmitted() as [number, { value?: { name?: string } }][];
    assert.equal(first[0]![1].value?.name, "OLD_SECRET_MARKER");

    // Also test direct entry.input & stale async producer capture
    const capturedGen = store.readGen(wsTopic);
    store.unsubscribe(1, 10, true);
    const keptMsg = host.takeEmitted() as [number, { id: number; v: string }][];
    const oldToken = keptMsg[0]![1].v;
    assert.ok(typeof oldToken === "string");

    // Revoke / downgrade authorization while underlying heldRecord STILL contains OLD_SECRET_MARKER!
    authorized = false;
    store.authGen.bumpWorkspace("ws-1");
    const boundaryMsgs = host.takeEmitted() as [number, CoreMessage][];
    assert.ok(boundaryMsgs.some(([, m]) => "auth" in m && m.auth.workspace === "ws-1" && m.auth.authGen === 2));

    // Stale async producer write-back with old capturedGen must be dropped!
    store.set(wsTopic, { ok: { id: "ws-1", name: "OLD_ASYNC_MARKER" } }, capturedGen);
    assert.equal(store.value(wsTopic), undefined, "store.value must not leak held record while unauthorized");

    // New subscriber with oldToken while unauthorized: 0 old markers emitted (placeholder only!)
    store.subscribe(1, 11, wsTopic, false, undefined, oldToken);
    await pass(COALESCE_MS * 2);
    const whileUnauth = host.takeEmitted();
    assert.equal(
      JSON.stringify(whileUnauth).includes("OLD_SECRET_MARKER") || JSON.stringify(whileUnauth).includes("OLD_ASYNC_MARKER"),
      false,
      "old markers must never appear while new authorization is unconfirmed",
    );
    assert.equal(whileUnauth.length, 0, "no value emitted while unauthorized");

    // Confirm new authorization with fresh record -> new value emitted whole (NOT same: true) and visible!
    heldRecord = { id: "ws-1", name: "NEW_AUTHORIZED_VALUE" };
    authorized = true;
    store.changed(wsTopic);
    await pass(COALESCE_MS * 2);
    const afterAuth = host.takeEmitted() as [number, { id: number; value?: { name?: string }; same?: boolean; authGen?: number }][];
    assert.equal(afterAuth.length, 1);
    assert.equal(afterAuth[0]![1].same, undefined);
    assert.equal(afterAuth[0]![1].value?.name, "NEW_AUTHORIZED_VALUE");
    assert.equal(afterAuth[0]![1].authGen, 2);
  });

  it("isolates single-vault expiry (V1 locked, V2 and non-vault untouched) and explicit vault.lock clears all vaults", async () => {
    const { host, store, pass } = setup();
    store.registerClient(1, 301);
    host.takeEmitted();

    const v1Items: Topic = { topic: "vaultItems", workspace: "ws-1", vault: "v1" };
    const v2Items: Topic = { topic: "vaultItems", workspace: "ws-1", vault: "v2" };
    const ws1Vaults: Topic = { topic: "vaults", workspace: "ws-1" };
    const ws2Vaults: Topic = { topic: "vaults", workspace: "ws-2" };
    const ws1Chats: Topic = { topic: "chats", scope: "ws-1", mine: false };

    store.subscribe(1, 1, v1Items);
    store.subscribe(1, 2, v2Items);
    store.subscribe(1, 3, ws1Vaults);
    store.subscribe(1, 4, ws2Vaults);
    store.subscribe(1, 5, ws1Chats);

    const v1GenBefore = store.readGen(v1Items);
    store.set(v1Items, { ok: { vault: "v1", open: true, items: [{ id: "i1", name: "V1_PLAIN" }] } });
    store.set(v2Items, { ok: { vault: "v2", open: true, items: [{ id: "i2", name: "V2_PLAIN" }] } });
    store.set(ws1Vaults, { ok: { vaults: [{ id: "v1", open: true }, { id: "v2", open: true }] } });
    store.set(ws2Vaults, { ok: { vaults: [], cross: "ws-1" } });
    store.set(ws1Chats, { ok: { items: [{ id: "c1" }] } });
    await pass(COALESCE_MS * 2);
    host.takeEmitted();

    // V1 times out (ws-2 has cross-workspace vaults dependency on ws-1; initial vaultGen=1, bump -> 2)
    store.authGen.bumpVault("ws-1", "v1", ["ws-2"]);
    const bumpMsgs = host.takeEmitted() as [number, CoreMessage][];
    assert.ok(bumpMsgs.some(([, m]) => "auth" in m && m.auth.vault === "v1" && m.auth.vaultGen === 2));

    // Non-vault ws-1 authGen did NOT bump, and V2 / chats are STILL cached!
    assert.equal(store.authGen.workspaceAuthGen("ws-1"), 1);
    assert.equal(store.authGen.vaultGen("ws-1", "v1"), 2);
    assert.equal(store.authGen.vaultGen("ws-1", "v2"), 1);
    assert.ok(store.value(v2Items) !== undefined, "V2 must remain cached");
    assert.ok(store.value(ws1Chats) !== undefined, "non-vault chats must remain cached");
    assert.equal(store.value(v1Items), undefined, "V1 must be invalidated");
    assert.equal(store.value(ws1Vaults), undefined, "ws-1 vaults aggregate must be invalidated");
    assert.equal(store.value(ws2Vaults), undefined, "cross-workspace dependent ws-2 vaults must be invalidated");

    // Delayed unlocked V1 payload from before lock is dropped!
    store.set(v1Items, { ok: { vault: "v1", open: true, items: [{ id: "i1", name: "V1_STALE_UNLOCKED" }] } }, v1GenBefore);
    await pass(COALESCE_MS * 2);
    const afterLate = host.takeEmitted();
    assert.equal(JSON.stringify(afterLate).includes("V1_STALE_UNLOCKED"), false);

    // Explicit vault.lock invalidates ALL vaults (both V1 and V2) without touching non-vault chats!
    store.authGen.bumpAllVaults();
    const lockAllMsgs = host.takeEmitted() as [number, CoreMessage][];
    assert.ok(lockAllMsgs.some(([, m]) => "auth" in m && m.auth.vaultAll === true));
    assert.equal(store.value(v2Items), undefined, "V2 must be invalidated on explicit vault.lock");
    assert.ok(store.value(ws1Chats) !== undefined, "non-vault chats still untouched on explicit vault.lock");
  });

  it("enforces unconditional sensitive ceiling and sanitizes profiles/station kept values", async () => {
    const { host, store, pass } = setup();
    const sensitiveTopics: Topic[] = [
      { topic: "vaults", workspace: "ws-1" },
      { topic: "vaultItems", workspace: "ws-1", vault: "v1" },
      { topic: "accounts" },
      { topic: "lock", workspace: "ws-1" },
      { topic: "stationPart", scope: "ws-1", station: "ws-1/s1", part: "logins" },
      { topic: "stationPart", scope: "ws-1", station: "ws-1/s1", part: "machineLogins" },
    ];
    for (let i = 0; i < sensitiveTopics.length; i++) {
      const topic = sensitiveTopics[i]!;
      store.subscribe(1, 10 + i, topic);
      store.set(topic, { ok: { secret: `S-${i}` } });
      await pass(COALESCE_MS * 2);
      host.takeEmitted();
      store.unsubscribe(1, 10 + i, true);
      const out = host.takeEmitted() as [number, { id: number; v: string | null }][];
      assert.equal(out.length, 1);
      assert.equal(out[0]![1].v, null, `${topic.topic} must return v: null on keep`);
    }
    assert.equal(store.keptOf(1), 0, "sensitive topics must never enter #kept");
    // Unsubscription completed cleanly and evicts normally after EVICT_AFTER_MS
    await pass(EVICT_AFTER_MS + 1_000);
    assert.deepEqual(store.liveTopics(), []);

    // profiles & station: kept values strip machineLogins/logins/manages, then fresh subscribe patches them back
    const profilesTopic: Topic = { topic: "profiles", scope: "ws-1" };
    const fullProfiles = {
      items: [{ key: "p1", name: "Claude", pad: "x".repeat(300) }],
      machineLogins: [{ station: "ws-1/s1", logins: [{ id: "ml-1", email: "secret@corp" }] }],
      manages: true,
    };
    store.subscribe(1, 50, profilesTopic);
    store.set(profilesTopic, { ok: fullProfiles });
    await pass(COALESCE_MS * 2);
    host.takeEmitted();
    store.unsubscribe(1, 50, true);
    const [[, pKeep]] = host.takeEmitted() as [number, { id: number; v: string }][];
    assert.ok(typeof pKeep.v === "string");
    const keptProfiles = store.keptValueOf(1, profilesTopic) as Record<string, unknown>;
    assert.equal("machineLogins" in keptProfiles, false, "#kept profiles must not retain machineLogins");
    assert.equal("manages" in keptProfiles, false, "#kept profiles must not retain manages");

    // Re-subscribe with have: Core diffs sanitized keptProfiles -> fullProfiles and patches fresh sensitive fields back!
    store.subscribe(1, 51, profilesTopic, false, undefined, pKeep.v);
    const [[, pResub]] = host.takeEmitted() as [number, { id: number; same?: boolean; kept?: boolean; delta?: Op[]; value?: unknown }][];
    assert.notEqual(pResub.same, true, "profiles with sensitive fields must not answer same: true against sanitized kept base");
    if (pResub.kept && pResub.delta) {
      assert.deepEqual(applyOps(structuredClone(keptProfiles), pResub.delta), fullProfiles);
    } else {
      assert.deepEqual(pResub.value, fullProfiles);
    }

    // station: overview.machineLogins & overview.logins stripped in #kept
    const stationTopic: Topic = { topic: "station", scope: "ws-1", station: "ws-1/s1" };
    const fullStation = {
      station: "ws-1/s1",
      name: "Box",
      pad: "y".repeat(300),
      overview: { counts: { running: 2 }, machineLogins: [{ id: "ml-2" }], logins: [{ id: "l-2" }] },
    };
    store.subscribe(1, 60, stationTopic);
    store.set(stationTopic, { ok: fullStation });
    await pass(COALESCE_MS * 2);
    host.takeEmitted();
    store.unsubscribe(1, 60, true);
    const [[, sKeep]] = host.takeEmitted() as [number, { id: number; v: string }][];
    assert.ok(typeof sKeep.v === "string");
    const keptStation = store.keptValueOf(1, stationTopic) as { overview: Record<string, unknown> };
    assert.equal("machineLogins" in keptStation.overview, false, "#kept station.overview must not retain machineLogins");
    assert.equal("logins" in keptStation.overview, false, "#kept station.overview must not retain logins");
  });

  it("verifies delayed write call authorization context and rejects stale conn/account/authGen/vaultGen", () => {
    const tracker = new AuthGenTracker();
    const signedIn = new Set(["acct-1"]);
    const owners = new Map<string, string>([["ws-1", "acct-1"]]);
    const ownerOf = (ws: string) => owners.get(ws) ?? null;

    // Valid call passes (initial vaultGen=1)
    assert.equal(
      tracker.verifyCallAuth({ conn: 5, account: "acct-1", workspace: "ws-1", authGen: 1, vault: "v1", vaultGen: 1 }, 5, ownerOf, signedIn, { workspace: "ws-1", vault: "v1", isVault: true }, true),
      null,
    );
    // Missing auth on protected write over handshaked conn rejected
    assert.equal(
      tracker.verifyCallAuth(undefined, 5, ownerOf, signedIn, { workspace: "ws-1", vault: "v1", isVault: true }, true)?.code,
      "auth_stale",
    );
    // Target mismatch (declared ws-1 vs resolved ws-2) rejected
    assert.equal(
      tracker.verifyCallAuth({ conn: 5, workspace: "ws-1", authGen: 1 }, 5, ownerOf, signedIn, { workspace: "ws-2" }, true)?.code,
      "auth_stale",
    );
    // Stale conn rejected
    assert.equal(tracker.verifyCallAuth({ conn: 4, workspace: "ws-1", authGen: 1 }, 5, ownerOf, signedIn)?.code, "auth_stale");
    // Stale authGen after role downgrade rejected
    tracker.bumpWorkspace("ws-1");
    assert.equal(tracker.verifyCallAuth({ conn: 5, workspace: "ws-1", authGen: 1 }, 5, ownerOf, signedIn)?.code, "auth_stale");
    // Stale vaultGen after single-vault lock rejected (initial 1 -> bumped 2)
    tracker.bumpVault("ws-1", "v1");
    assert.equal(tracker.verifyCallAuth({ conn: 5, workspace: "ws-1", authGen: 2, vault: "v1", vaultGen: 1 }, 5, ownerOf, signedIn)?.code, "auth_stale");
    // Unaffected vault v2 still valid at vaultGen=1!
    assert.equal(tracker.verifyCallAuth({ conn: 5, workspace: "ws-1", authGen: 2, vault: "v2", vaultGen: 1 }, 5, ownerOf, signedIn), null);
    // Monotonic strict advance: global syncAccounts advances above highest workspace gen!
    tracker.syncAccounts(["acct-1"]);
    assert.equal(tracker.syncAccounts(["acct-2"]), true);
    assert.ok(tracker.globalGen > 2, "globalGen must strictly exceed all prior workspace gens");
    // Signed-out account rejected
    signedIn.delete("acct-1");
    assert.equal(tracker.verifyCallAuth({ conn: 5, account: "acct-1", workspace: "ws-1", authGen: tracker.globalGen }, 5, ownerOf, signedIn)?.code, "auth_stale");

    // downloads is NOT device-global; transport topics ARE device-global
    assert.equal(DEVICE_GLOBAL_TOPIC_SET.has("downloads"), false);
    assert.equal(DEVICE_GLOBAL_TOPIC_SET.has("link"), true);
    assert.equal(DEVICE_GLOBAL_TOPIC_SET.has("connection"), true);

    // stationPart(part="profiles") and station overview.profiles[].login sanitization
    const cleanPart = sanitizeKeptValue("stationPart", [
      { id: "p1", name: "Claude", login: { state: "needs_approval", url: "https://x", userCode: "SECRET-CODE" } },
    ], { part: "profiles" }) as Record<string, unknown>[];
    assert.equal("login" in cleanPart[0]!, false);

    // Protocol parser preserves `auth` on calls
    const parsed = parseClientMessage({
      id: 7,
      call: "vault.putItem",
      params: { workspace: "ws-1" },
      auth: { conn: 5, account: "acct-1", workspace: "ws-1", authGen: 2, vault: "v1", vaultGen: 2 },
    });
    assert.ok("kind" in parsed && parsed.kind === "call" && parsed.auth?.vaultGen === 2);
  });

  it("end-to-end real Core: auto-handshake, monotonic cross-restart conn, protected write auth enforcement, and vault.lock", async () => {
    const host1 = new FakeHost();
    const core1 = await Core.create(host1, { iroh: null });
    const c1 = core1.connect({ authHandshake: true, requireCallAuth: true });
    await host1.time.pass(10);
    const snap1 = host1.takeEmitted().find(([c, m]) => c === c1 && "auth" in m) as [number, { id: 0; auth: { conn: number; global: number; aggregate: number; vaultGlobal: number } }] | undefined;
    assert.ok(snap1, "Core.connect({ authHandshake: true }) must emit { id: 0, auth } snapshot");
    const conn1 = snap1[1].auth.conn;
    assert.ok(conn1 > 0);
    assert.equal(snap1[1].auth.vaultGlobal, 1);
    assert.equal(snap1[1].auth.aggregate, 1);

    // Protected write RPC without `auth` on handshaked production connection is rejected with auth_stale!
    core1.receiveRaw(c1, { id: 10, call: "chat.send", params: { station: "ws-1/s1", thread: 1, text: "hi" } });
    await host1.time.pass(10);
    const rejMissing = host1.takeEmitted().find(([c, m]) => c === c1 && "id" in m && m.id === 10) as [number, { error?: { code: string } }] | undefined;
    assert.equal(rejMissing?.[1].error?.code, "auth_stale");

    // Protected write RPC with mismatched target workspace is rejected with auth_stale!
    core1.receiveRaw(c1, {
      id: 11,
      call: "chat.send",
      params: { station: "ws-2/s1", thread: 1, text: "hi" },
      auth: { conn: conn1, workspace: "ws-1", authGen: 1 },
    });
    await host1.time.pass(10);
    const rejTarget = host1.takeEmitted().find(([c, m]) => c === c1 && "id" in m && m.id === 11) as [number, { error?: { code: string } }] | undefined;
    assert.equal(rejTarget?.[1].error?.code, "auth_stale");

    await core1.close();

    // Restarted Core produces strictly greater monotonic `conn` (never regresses to <= conn1)
    assert.ok((DEVICE_TABLES as readonly string[]).includes("auth"), "auth device table must be in DEVICE_TABLES for cross-process persistence");
    const host2 = new FakeHost();
    const core2 = await Core.create(host2, { iroh: null });
    const c2 = core2.connect({ authHandshake: true, requireCallAuth: true });
    await host2.time.pass(10);
    const snap2 = host2.takeEmitted().find(([c, m]) => c === c2 && "auth" in m) as [number, { id: 0; auth: { conn: number } }] | undefined;
    assert.ok(snap2 && snap2[1].auth.conn > conn1, "restarted Core must emit strictly higher conn id");
    const conn2 = snap2[1].auth.conn;

    // Production write RPCs (`auth.signOut`, `job.stop`, `vault.lock`, `composer.text` with `new:ws-1`):
    // - with valid current-gen `auth`: NEVER rejected with `auth_stale`
    // - without `auth` or with stale `authGen`: 100% rejected with `auth_stale`
    (core2.inner.accounts as unknown as { list: () => { sub: string }[] }).list = () => [{ sub: "acct-1" }];
    for (const [idx, req] of [
      { call: "auth.signOut", params: { account: "acct-1" }, auth: { conn: conn2, authGen: 1 } },
      { call: "job.stop", params: { station: "ws-1/s1", id: "j1" }, auth: { conn: conn2, workspace: "ws-1", authGen: 1 } },
      { call: "vault.lock", params: { workspace: "ws-1" }, auth: { conn: conn2, workspace: "ws-1", authGen: 1 } },
      { call: "composer.text", params: { key: "new:ws-1", text: "draft" }, auth: { conn: conn2, workspace: "ws-1", authGen: 1 } },
    ].entries()) {
      const validId = 200 + idx;
      const missingId = 300 + idx;
      const staleId = 400 + idx;
      core2.receiveRaw(c2, { id: validId, call: req.call, params: req.params, auth: req.auth });
      core2.receiveRaw(c2, { id: missingId, call: req.call, params: req.params });
      core2.receiveRaw(c2, { id: staleId, call: req.call, params: req.params, auth: { ...req.auth, authGen: 999 } });
      await host2.time.pass(20);
      const msgs = host2.takeEmitted();
      const validAns = msgs.find(([c, m]) => c === c2 && "id" in m && m.id === validId) as [number, { error?: { code: string } }] | undefined;
      const missingAns = msgs.find(([c, m]) => c === c2 && "id" in m && m.id === missingId) as [number, { error?: { code: string } }] | undefined;
      const staleAns = msgs.find(([c, m]) => c === c2 && "id" in m && m.id === staleId) as [number, { error?: { code: string } }] | undefined;
      assert.notEqual(validAns?.[1].error?.code, "auth_stale", `${req.call} with valid auth must not fail auth_stale`);
      assert.equal(missingAns?.[1].error?.code, "auth_stale", `${req.call} without auth must fail auth_stale`);
      assert.equal(staleAns?.[1].error?.code, "auth_stale", `${req.call} with stale authGen must fail auth_stale`);
    }

    // View-bound `terminal.input` / `screen.input` authorization:
    // - view opened in current workspace gen passes even when params only carry `view` (no `workspace`)
    // - after workspace authGen bumps, old view's `viewAuthGen` is rejected as `auth_stale`, while a newly opened view passes
    const wsTermGen1 = core2.inner.store.authGen.workspaceAuthGen("ws-term");
    assert.equal(
      core2.inner.store.authGen.verifyCallAuth(
        { conn: conn2, authGen: core2.inner.store.authGen.globalGen },
        conn2,
        () => "acct-1",
        new Set(["acct-1"]),
        { workspace: "ws-term", viewAuthGen: wsTermGen1 },
        true,
      ),
      null,
      "view opened in current workspace gen must pass",
    );
    const wsTermGen2 = core2.inner.store.authGen.bumpWorkspace("ws-term");
    assert.equal(
      core2.inner.store.authGen.verifyCallAuth(
        { conn: conn2, authGen: core2.inner.store.authGen.globalGen },
        conn2,
        () => "acct-1",
        new Set(["acct-1"]),
        { workspace: "ws-term", viewAuthGen: wsTermGen1 },
        true,
      )?.code,
      "auth_stale",
      "view opened before workspace bump must fail auth_stale",
    );
    // Even if the caller explicitly supplies `auth.workspace` with the new workspace authGen, stale `viewAuthGen` MUST still be rejected!
    assert.equal(
      core2.inner.store.authGen.verifyCallAuth(
        { conn: conn2, workspace: "ws-term", authGen: wsTermGen2 },
        conn2,
        () => "acct-1",
        new Set(["acct-1"]),
        { workspace: "ws-term", viewAuthGen: wsTermGen1 },
        true,
      )?.code,
      "auth_stale",
      "explicit auth.workspace must never bypass stale viewAuthGen",
    );
    assert.equal(
      core2.inner.store.authGen.verifyCallAuth(
        { conn: conn2, authGen: core2.inner.store.authGen.globalGen },
        conn2,
        () => "acct-1",
        new Set(["acct-1"]),
        { workspace: "ws-term", viewAuthGen: wsTermGen2 },
        true,
      ),
      null,
      "new view opened after workspace bump must pass",
    );

    // After workspace bump, default-branch streaming calls like `station.file` emit wire `authGen === workspaceAuthGen(ws)` (never stale globalGen)
    core2.receiveRaw(c2, {
      id: 450,
      call: "station.file",
      params: { station: "ws-term/s1", key: "k1", name: "a.png" },
      auth: { conn: conn2, workspace: "ws-term", authGen: wsTermGen2 },
    });
    await host2.time.pass(20);
    const sfAns = host2.takeEmitted().find(([c, m]) => c === c2 && "id" in m && m.id === 450) as [number, { authGen?: number; error?: { code: string } }] | undefined;
    assert.equal(sfAns?.[1].authGen, wsTermGen2, "station.file answer must carry workspace authGen after bump");
    assert.notEqual(sfAns?.[1].error?.code, "auth_stale", "station.file with valid workspace authGen must not fail auth_stale");

    // Workspace revocation boundary advances `aggregateAuthGen` and matches account-level aggregates (`workspaces`, `lockPrompts`, `downloads`)
    assert.ok(core2.inner.store.authGen.aggregateAuthGen >= wsTermGen2);
    assert.equal(core2.inner.store.authGen.authGenOf({ topic: "workspaces" }), core2.inner.store.authGen.aggregateAuthGen);
    assert.equal(core2.inner.store.authGen.matches({ topic: "workspaces" }, { kind: "workspace", workspace: "ws-1", authGen: 2 }), true);
    assert.equal(core2.inner.store.authGen.matches({ topic: "lockPrompts" }, { kind: "workspace", workspace: "ws-1", authGen: 2 }), true);
    assert.equal(core2.inner.store.authGen.matches({ topic: "downloads" }, { kind: "workspace", workspace: "ws-1", authGen: 2 }), true);

    // Same-owner role downgrade (`owner -> member`) sets per-(ws, topicKey) `pendingAuthConfirm` and
    // triggers `stations.refreshWorkspace(ws)` to re-read overview/chatRows/sessions/threads & active held topics:
    core2.inner.workspaces.setOwners(new Map([["ws-same", "acct-1"]]));
    (core2.inner.accounts as unknown as { list: () => { sub: string }[] }).list = () => [{ sub: "acct-1" }];
    const refreshedWorkspaces: string[] = [];
    const origRefresh = core2.inner.stations.refreshWorkspace.bind(core2.inner.stations);
    core2.inner.stations.refreshWorkspace = (ws: string) => {
      refreshedWorkspaces.push(ws);
      origRefresh(ws);
    };
    let wsRole = "owner";
    const s1JobsTopic: Topic = { topic: "jobs", station: "ws-same/s1" };
    const s1OverviewTopic: Topic = { topic: "overview", station: "ws-same/s1" };
    const s1ArchivedTopic: Topic = { topic: "archivedRows", station: "ws-same/s1" };
    const s1ChatRowsTopic: Topic = { topic: "chatRows", station: "ws-same/s1" };
    const s1SessionsTopic: Topic = { topic: "sessions", station: "ws-same/s1" };
    const s1ThreadsTopic: Topic = { topic: "threads", station: "ws-same/s1" };
    const s1SessionTopic: Topic = { topic: "session", station: "ws-same/s1", key: "k-active" };
    const s2Topic: Topic = { topic: "jobs", station: "ws-same/s2" };
    core2.inner.data.shared = ((t: Topic) => {
      if (t.topic === "workspace" && t.workspace === "ws-same") return { id: "ws-same", role: wsRole };
      if (t.topic === "jobs" && t.station === "ws-same/s1") return [{ id: "j1" }];
      if (t.topic === "overview" && t.station === "ws-same/s1") return { name: "S1" };
      if (t.topic === "archivedRows" && t.station === "ws-same/s1") return [{ id: "a1" }];
      if (t.topic === "chatRows" && t.station === "ws-same/s1") return [{ id: "c1" }];
      if (t.topic === "sessions" && t.station === "ws-same/s1") return [{ key: "k-active" }];
      if (t.topic === "threads" && t.station === "ws-same/s1") return [{ id: 1 }];
      if (t.topic === "session" && t.station === "ws-same/s1" && t.key === "k-active") return { key: "k-active" };
      if (t.topic === "jobs" && t.station === "ws-same/s2") return [{ id: "j2" }];
      return undefined;
    }) as typeof core2.inner.data.shared;
    (core2.inner.adb.personal() as unknown as { isLoaded: () => boolean }).isLoaded = () => true;
    syncWorkspaceAuth(core2.inner, "ws-same");
    assert.equal(core2.inner.pendingAuthConfirm.has("ws-same"), false);
    wsRole = "member";
    syncWorkspaceAuth(core2.inner, "ws-same");
    assert.deepEqual(refreshedWorkspaces, ["ws-same"], "downgrade must proactively call stations.refreshWorkspace(ws)");
    assert.equal(core2.inner.pendingAuthConfirm.has("ws-same"), true, "same-owner downgrade must gate held Data via pendingAuthConfirm");
    assert.equal(core2.inner.store.value(s1JobsTopic), undefined, "s1 jobs gated before confirmation");
    assert.equal(core2.inner.store.value(s1OverviewTopic), undefined, "s1 overview gated before confirmation");
    assert.equal(core2.inner.store.value(s1ArchivedTopic), undefined, "s1 archivedRows gated before confirmation");
    assert.equal(core2.inner.store.value(s1ChatRowsTopic), undefined, "s1 chatRows gated before confirmation");
    assert.equal(core2.inner.store.value(s1SessionsTopic), undefined, "s1 sessions gated before confirmation");
    assert.equal(core2.inner.store.value(s1ThreadsTopic), undefined, "s1 threads gated before confirmation");
    assert.equal(core2.inner.store.value(s1SessionTopic), undefined, "s1 active session gated before confirmation");
    assert.equal(core2.inner.store.value(s2Topic), undefined, "s2 gated before confirmation");
    // Strict per-(ws, topicKey) with mandatory readGen: stale readGen MUST NOT confirm new generation!
    const newGen = core2.inner.store.authGen.workspaceAuthGen("ws-same");
    core2.inner.confirmWorkspaceAuth?.("ws-same", s1JobsTopic, newGen - 1);
    assert.equal(core2.inner.store.value(s1JobsTopic), undefined, "stale readGen must NOT confirm s1 jobs");
    core2.inner.confirmWorkspaceAuth?.("ws-same", s1JobsTopic, newGen);
    assert.equal(core2.inner.pendingAuthConfirm.has("ws-same"), true);
    assert.deepEqual(core2.inner.store.value(s1JobsTopic), { ok: [{ id: "j1" }] }, "confirmed s1 jobs recovers");
    assert.equal(core2.inner.store.value(s1OverviewTopic), undefined, "confirming s1 jobs must NOT unblock unrefreshed s1 overview");
    assert.equal(core2.inner.store.value(s1ArchivedTopic), undefined, "confirming s1 jobs must NOT unblock unrefreshed s1 archivedRows");
    assert.equal(core2.inner.store.value(s2Topic), undefined, "confirming station-1 must NOT unblock station-2's old record");
    // Independently confirming s1's chatRows, sessions, threads, and active session restores each without unblocking s1 overview!
    core2.inner.confirmWorkspaceAuth?.("ws-same", s1ChatRowsTopic, newGen);
    core2.inner.confirmWorkspaceAuth?.("ws-same", s1SessionsTopic, newGen);
    core2.inner.confirmWorkspaceAuth?.("ws-same", s1ThreadsTopic, newGen);
    core2.inner.confirmWorkspaceAuth?.("ws-same", s1SessionTopic, newGen);
    assert.deepEqual(core2.inner.store.value(s1ChatRowsTopic), { ok: [{ id: "c1" }] }, "independently confirmed s1 chatRows recovers");
    assert.deepEqual(core2.inner.store.value(s1SessionsTopic), { ok: [{ key: "k-active" }] }, "independently confirmed s1 sessions recovers");
    assert.deepEqual(core2.inner.store.value(s1ThreadsTopic), { ok: [{ id: 1 }] }, "independently confirmed s1 threads recovers");
    assert.deepEqual(core2.inner.store.value(s1SessionTopic), { ok: { key: "k-active" } }, "independently confirmed s1 active session recovers");
    assert.equal(core2.inner.store.value(s1OverviewTopic), undefined, "s1 overview still gated until independently confirmed");
    // An unrelated global bump MUST NOT bypass `pendingAuthConfirm` for still-unconfirmed topics!
    core2.inner.store.authGen.syncAccounts(["acct-1", "acct-2"]);
    assert.ok(core2.inner.store.authGen.globalGen >= core2.inner.store.authGen.aggregateAuthGen, "syncAccounts globalGen must cover aggregateAuthGen");
    assert.equal(core2.inner.store.value(s2Topic), undefined, "unrelated global bump must NOT bypass pendingAuthConfirm for unconfirmed s2");
    // Pure local `draft` is never gated; `drivePlace` skips pendingAuthConfirm but STILL enforces workspace ownership!
    assert.equal(core2.inner.store.isAuthorized({ topic: "draft", station: "ws-same/s2", chat: "c1" }), true);
    assert.equal(core2.inner.store.isAuthorized({ topic: "drivePlace", station: "ws-same/s2", root: "/", path: "a" }), true);
    assert.equal(core2.inner.store.isAuthorized({ topic: "drivePlace", station: "ws-unauthorized/s1", root: "/", path: "a" }), false);
    // Cross-workspace `vaults(B)` dependent on `Workspace(A)` advances `vaultWorkspaceGen(B)` on `bumpWorkspace(A, ["B"])`
    const depBefore = core2.inner.store.authGen.vaultWorkspaceGen("ws-dep-b");
    core2.inner.store.authGen.bumpWorkspace("ws-same", ["ws-dep-b"]);
    assert.ok(core2.inner.store.authGen.vaultWorkspaceGen("ws-dep-b") > depBefore, "dependent workspace vaultWorkspaceGen must advance on Workspace(A) boundary");
    // Upgrade `member -> owner` clears pendingAuthConfirm without gating!
    wsRole = "owner";
    syncWorkspaceAuth(core2.inner, "ws-same");
    assert.equal(core2.inner.pendingAuthConfirm.has("ws-same"), false, "role upgrade must NOT set pendingAuthConfirm");
    await core2.close();
  });

  it("Astra r8 P0/P1: explicit V2 open survives V1 lock, Retold preserves readGen, drivePlace is account-scoped, and connSeq persists before handshake", async () => {
    // 1. P0-1: Single-vault lock of V1 bumps vaultWorkspaceGen(ws) without bumping vaultGen(ws, v2)
    const authGen = new AuthGenTracker();
    const startWsVaultGen = authGen.vaultWorkspaceGen("ws-iso");
    const startV2Gen = authGen.vaultGen("ws-iso", "v2");
    authGen.bumpVault("ws-iso", "v1");
    assert.ok(authGen.vaultWorkspaceGen("ws-iso") > startWsVaultGen, "locking V1 advances vaultWorkspaceGen");
    assert.equal(authGen.vaultGen("ws-iso", "v2"), startV2Gen, "locking V1 must NOT advance explicit V2 vaultGen");

    // 2. P0-2: Retold preserves original readGen so stale-gen overview replay neither writes Data nor confirms pendingAuthConfirm
    const retold = new Retold();
    const readId = retold.asked();
    retold.told("ws-r/s1", "overview", { name: "stale" }, 1);
    const replayed = retold.since(readId, "ws-r/s1");
    assert.equal(replayed.length, 1);
    assert.equal(replayed[0]!.readGen, 1);
    retold.over(readId);

    const host = new FakeHost();
    const core = await Core.create(host, { iroh: null });
    core.inner.workspaces.setOwners(new Map([["ws-r", "acct-A"]]));
    (core.inner.accounts as unknown as { list: () => { sub: string }[] }).list = () => [{ sub: "acct-A" }, { sub: "acct-B" }];
    // Bump ws-r to gen 2 and put it in pendingAuthConfirm; an old-gen (1) overview SSE event must be rejected before Retold/Data/confirm
    const ovTopic: Topic = { topic: "overview", station: "ws-r/s1" };
    core.inner.store.authGen.bumpWorkspace("ws-r");
    const curGen = core.inner.store.authGen.workspaceAuthGen("ws-r");
    core.inner.pendingAuthConfirm.set("ws-r", { gen: curGen, confirmedKeys: new Set() });
    let dataWritten = false;
    const origSet = core.inner.data.set.bind(core.inner.data);
    core.inner.data.set = (topic: Topic, value: unknown, confirmed?: boolean, changed?: ReadonlySet<string>) => {
      if (topic.topic === "overview" && topic.station === "ws-r/s1") dataWritten = true;
      return origSet(topic, value, confirmed, changed);
    };
    core.inner.stations.onEvent("ws-r/s1", "overview", JSON.stringify({ name: "stale-overview" }), false, curGen - 1);
    assert.equal(dataWritten, false, "stale-gen overview event must NOT write Data");
    assert.equal(core.inner.pendingAuthConfirm.get("ws-r")?.confirmedKeys.size, 0, "stale-gen overview event must NOT confirm pendingAuthConfirm");

    // 3. P1-1: drivePlace is scoped by workspace owner account (acct-A's place is invisible to acct-B)
    const dpTopic: Topic = { topic: "drivePlace", station: "ws-dp/s1", root: "/r", path: "/p" };
    await core.inner.runner.run(core.inner.data.accounts(["acct-A", "acct-B"]));
    core.inner.workspaces.setOwners(new Map([["ws-dp", "acct-A"]]));
    core.inner.data.set(dpTopic, { at: 42, of: 100, changed: 1000 }, false);
    assert.deepEqual(core.inner.data.shared(dpTopic), { at: 42, of: 100, changed: 1000 });
    core.inner.workspaces.setOwners(new Map([["ws-dp", "acct-B"]]));
    assert.equal(core.inner.data.shared(dpTopic), undefined, "account B must NOT see account A's drivePlace");
    core.inner.workspaces.setOwners(new Map());
    assert.equal(core.inner.data.shared(dpTopic), undefined, "unowned workspace must NOT read drivePlace");
    await core.close();

    // 4. P1-3: connSeq must persist BEFORE publishing `{ id: 0, auth }` snapshot (both delayed write and failed write)
    const delayedHost = new FakeHost();
    const coreDelayed = await Core.create(delayedHost, { iroh: null });
    const gate = Effect.runSync(Deferred.make<void>());
    const origStorageSet = delayedHost.storageSet.bind(delayedHost);
    delayedHost.storageSet = (key: string, value: Uint8Array) =>
      key === "device/auth"
        ? Deferred.await(gate).pipe(Effect.andThen(origStorageSet(key, value)))
        : origStorageSet(key, value);
    const cDelayed = coreDelayed.connect({ authHandshake: true, requireCallAuth: true });
    await delayedHost.time.pass(20);
    assert.equal(
      delayedHost.takeEmitted().some(([c, m]) => c === cDelayed && "auth" in m),
      false,
      "handshake snapshot must NOT be emitted while device/auth write is still pending",
    );
    Effect.runSync(Deferred.succeed(gate, undefined));
    await delayedHost.time.pass(20);
    assert.equal(
      delayedHost.takeEmitted().some(([c, m]) => c === cDelayed && "auth" in m),
      true,
      "handshake snapshot must be emitted once device/auth persistence succeeds",
    );
    await coreDelayed.close();

    const failHost = new FakeHost();
    const coreFail = await Core.create(failHost, { iroh: null });
    const failGate = Effect.runSync(Deferred.make<void, HostError>());
    failHost.storageSet = (key: string, value: Uint8Array) =>
      key === "device/auth"
        ? Deferred.await(failGate)
        : FakeHost.prototype.storageSet.call(failHost, key, value);
    const defects: unknown[] = [];
    coreFail.inner.runner.onDefect = (err) => defects.push(err);
    const cFail = coreFail.connect({ authHandshake: true, requireCallAuth: true });
    // Queue a subscription (`prefs`) + an exempt RPC (`commands.find`) + an in-flight RPC that finishes AFTER persistence fails
    coreFail.receiveRaw(cFail, { id: 76, subscribe: { topic: "prefs" } });
    coreFail.receiveRaw(cFail, { id: 77, call: "commands.find", params: { query: "", offered: [] } });
    await failHost.time.pass(10);
    Effect.runSync(Deferred.fail(failGate, new HostError("disk full")));
    await failHost.time.pass(20);
    const failEmitted = failHost.takeEmitted().filter(([c]) => c === cFail).map(([, m]) => m);
    assert.equal(defects.length, 0, "persistence failure must NOT call runner.onDefect (would fatal crash-loop hosts)");
    assert.equal(
      failEmitted.some((m) => "auth" in m || ("conn" in m && typeof (m as { conn?: unknown }).conn === "number")),
      false,
      "handshake snapshot and conn-tagged messages must NOT be emitted when device/auth persistence fails",
    );
    const rpcErr = failEmitted.find((m) => "id" in m && m.id === 77) as { error?: { code?: string }; conn?: number } | undefined;
    assert.equal(rpcErr?.error?.code, "storage_failed", "deferred RPC must receive explicit storage_failed error rather than hanging");
    assert.equal(rpcErr?.conn, undefined, "storage_failed error must not leak unpersisted conn");
    const subErr = failEmitted.find((m) => "id" in m && m.id === 76 && "error" in m);
    assert.equal(subErr, undefined, "queued subscription value must NEVER be emitted as an RPC storage_failed error");
    // After persistence failure, protected write RPC must be rejected with storage_failed (never fall into unhandshaked path)
    coreFail.receiveRaw(cFail, { id: 78, call: "chat.send", params: { station: "ws-1/s1", thread: 1, text: "blocked" } });
    await failHost.time.pass(10);
    const postFailWrite = failHost.takeEmitted().find(([c, m]) => c === cFail && "id" in m && m.id === 78) as [number, { error?: { code?: string }; conn?: number }] | undefined;
    assert.equal(postFailWrite?.[1].error?.code, "storage_failed", "protected write after auth persist failure must fail with storage_failed");
    assert.equal(postFailWrite?.[1].conn, undefined, "post-failure storage_failed must not carry conn");
    // In-flight RPC emission reaching emitClient after #authFailed is set must NOT leak conn and must receive storage_failed
    coreFail.inner.store.emitClient(cFail, { id: 79, ok: { leaked: true }, conn: 999 } as unknown as CoreMessage, true);
    const lateRpc = failHost.takeEmitted().find(([c, m]) => c === cFail && "id" in m && m.id === 79) as [number, { error?: { code?: string }; conn?: number }] | undefined;
    assert.equal(lateRpc?.[1].error?.code, "storage_failed", "late in-flight RPC after auth failure must receive storage_failed");
    assert.equal(lateRpc?.[1].conn, undefined, "late in-flight RPC must NOT leak unpersisted conn");
    // Once storage recovers, syncAuth(cFail) clears #authFailed and emits a fresh persisted conn snapshot
    failHost.storageSet = FakeHost.prototype.storageSet.bind(failHost);
    coreFail.syncAuth(cFail);
    await failHost.time.pass(20);
    assert.equal(coreFail.inner.store.isAuthFailed(cFail), false, "syncAuth recovery must clear #authFailed");
    assert.equal(
      failHost.takeEmitted().some(([c, m]) => c === cFail && "auth" in m),
      true,
      "after storage recovers, syncAuth must succeed and emit handshake snapshot",
    );
    await coreFail.close().catch(() => undefined);
  });

  it("Astra r12/r13: P0-1 approve start gen, P0-2 thread/job-log & Retold/marks gate, P0-3 cloud sub!==owner & joined reread, P1-1/P1-5 unloaded futureDiskSeq reload", async () => {
    // 1. Astra P1-1: Delayed persistence gates BOTH `{ id: 0, auth }` AND exempt RPC answers, releasing them in order
    const gateHost = new FakeHost();
    const coreGate = await Core.create(gateHost, { iroh: null });
    const gate = Effect.runSync(Deferred.make<void>());
    const origSetGate = gateHost.storageSet.bind(gateHost);
    gateHost.storageSet = (key: string, value: Uint8Array) =>
      key === "device/auth"
        ? Deferred.await(gate).pipe(Effect.andThen(origSetGate(key, value)))
        : origSetGate(key, value);
    const cGate = coreGate.connect({ authHandshake: true, requireCallAuth: true });
    coreGate.receiveRaw(cGate, { id: 88, call: "commands.find", params: { query: "", offered: [] } });
    await gateHost.time.pass(20);
    assert.equal(
      gateHost.takeEmitted().filter(([c]) => c === cGate).length,
      0,
      "neither handshake nor exempt RPC answer may emit while device/auth write is pending",
    );
    Effect.runSync(Deferred.succeed(gate, undefined));
    await gateHost.time.pass(20);
    const released = gateHost.takeEmitted().filter(([c]) => c === cGate).map(([, m]) => m);
    assert.ok(released.length >= 2, "both handshake and deferred exempt RPC must release after persistence");
    assert.ok("auth" in released[0]!, "handshake snapshot must emit before deferred RPC answer");
    assert.equal((released[1] as { id?: number }).id, 88);
    await coreGate.close();

    // 2. Astra P1-5: `#unloaded` device/auth recovers via reload("auth") with futureDiskSeq > Date.now()*1000, preserving max on merge & disk
    const unloadHost = new FakeHost();
    const futureDiskSeq = Date.now() * 1000 + 5_000_000;
    let failGetOnce = true;
    let persistedAuthSeq = 0;
    const origGet = unloadHost.storageGet.bind(unloadHost);
    const origSetUnload = unloadHost.storageSet.bind(unloadHost);
    unloadHost.storageGet = (key: string) => {
      if (key === "device/auth" && failGetOnce) {
        failGetOnce = false;
        return Effect.fail(new HostError("transient read fail"));
      }
      if (key === "device/auth") {
        return Effect.succeed(new TextEncoder().encode(JSON.stringify({ connSeq: futureDiskSeq })));
      }
      return origGet(key);
    };
    unloadHost.storageSet = (key: string, value: Uint8Array) => {
      if (key === "device/auth") {
        const parsed = JSON.parse(new TextDecoder().decode(value)) as { connSeq?: number };
        if (typeof parsed.connSeq === "number") persistedAuthSeq = parsed.connSeq;
      }
      return origSetUnload(key, value);
    };
    const coreUnload = await Core.create(unloadHost, { iroh: null });
    assert.equal(coreUnload.inner.data.device.isUnloaded("auth"), true);
    const cUnload = coreUnload.connect({ authHandshake: true, requireCallAuth: true });
    await unloadHost.time.pass(20);
    const unloadSnap = unloadHost.takeEmitted().find(([c, m]) => c === cUnload && "auth" in m) as [number, { auth: { conn: number } }] | undefined;
    assert.ok(unloadSnap && unloadSnap[1].auth.conn > futureDiskSeq, "reloaded device/auth must advance conn strictly above futureDiskSeq");
    assert.ok(persistedAuthSeq > futureDiskSeq, "persisted device/auth connSeq must be strictly above futureDiskSeq");
    await coreUnload.close();

    // 3. Astra P0-2 & P0-3: Real thread/job-log streamReadGen gate + Retold stale session dropped on replay
    const stHost = new FakeHost();
    const coreSt = await Core.create(stHost, { iroh: null });
    const addr = "ws-sse/s1";
    await coreSt.inner.runner.run(coreSt.inner.data.accounts(["acct-sse"]));
    coreSt.inner.workspaces.setOwners(new Map([["ws-sse", "acct-sse"]]));
    coreSt.inner.data.set({ topic: "workspace", workspace: "ws-sse" }, { id: "ws-sse", stations: [{ id: "s1", online: true }] }, false);
    coreSt.inner.stations.reconcile();
    const link = coreSt.inner.stations.link(addr);
    assert.ok(link, "reconcile must create station link for ws-sse/s1");
    let logChangeCount = 0;
    const origOnChange = coreSt.inner.stations.onChange.bind(coreSt.inner.stations);
    coreSt.inner.stations.onChange = (a, kind, key) => {
      if (a === addr && kind === "log") logChangeCount++;
      origOnChange(a, kind, key);
    };
    let toldCount = 0;
    const origOnTold = coreSt.inner.stations.onTold.bind(coreSt.inner.stations);
    coreSt.inner.stations.onTold = (a, tid, entries) => {
      if (a === addr && tid === 7) toldCount += entries.length;
      origOnTold(a, tid, entries);
    };
    coreSt.inner.store.authGen.bumpWorkspace("ws-sse");
    const curWsGen = coreSt.inner.store.authGen.workspaceAuthGen("ws-sse");
    // Stale streamReadGen (curWsGen - 1) must NOT mutate thread channel, onTold, job-log memory, or onChange
    coreSt.inner.stations.onEvent(addr, "thread", JSON.stringify({ id: 7, entries: [{ n: 1, text: "stale" }] }), false, curWsGen - 1);
    coreSt.inner.stations.onEvent(addr, "job-log", JSON.stringify({ id: "j1", lines: 50, text: "stale-log\n", outputAt: 100 }), false, curWsGen - 1);
    assert.equal(toldCount, 0, "stale streamReadGen thread event must NOT invoke onTold");
    assert.equal(logChangeCount, 0, "stale streamReadGen job-log event must NOT invoke onChange");
    assert.equal(link?.memory.get(logKey("j1", 50)), undefined, "stale streamReadGen job-log event must NOT mutate link.memory");
    // Current streamReadGen updates both thread & job-log normally
    coreSt.inner.stations.onEvent(addr, "thread", JSON.stringify({ id: 7, entries: [{ n: 1, text: "fresh" }] }), false, curWsGen);
    coreSt.inner.stations.onEvent(addr, "job-log", JSON.stringify({ id: "j1", lines: 50, text: "fresh-log\n", outputAt: 200 }), false, curWsGen);
    assert.equal(toldCount, 1, "current streamReadGen thread event must invoke onTold");
    assert.equal(logChangeCount, 1, "current streamReadGen job-log event must invoke onChange");
    assert.notEqual(link.memory.get(logKey("j1", 50)), undefined, "current streamReadGen job-log event must update link.memory");

    // Stale session event cannot overwrite Data summary after workspaceAuthGen bumps
    coreSt.inner.data.putSummary(addr, { key: "s-keep", title: "current-title", updatedAt: 200 });
    coreSt.inner.store.authGen.bumpWorkspace("ws-sse");
    const nextWsGen = coreSt.inner.store.authGen.workspaceAuthGen("ws-sse");
    coreSt.inner.stations.onEvent(addr, "session", JSON.stringify({ key: "s-keep", title: "stale-title", updatedAt: 100 }), false, nextWsGen - 1);
    assert.equal((coreSt.inner.data.of(addr)?.summary(addr, "s-keep") as { title?: string } | undefined)?.title, "current-title", "stale session must NOT overwrite current summary");

    // 4. Astra P0-3: CloudSync joined afterWrite (viewOf !== id) enqueues full workspace reread
    const enqueuedKeys: string[] = [];
    const origEnqueue = coreSt.inner.scheduler.enqueue.bind(coreSt.inner.scheduler);
    const origAsk = coreSt.inner.scheduler.ask.bind(coreSt.inner.scheduler);
    coreSt.inner.scheduler.enqueue = (lane, key, priority, effect) => {
      enqueuedKeys.push(key);
      return origEnqueue(lane, key, priority, effect);
    };
    coreSt.inner.scheduler.ask = (lane, key, priority, effect) => {
      enqueuedKeys.push(key);
      return origAsk(lane, key, priority, effect);
    };
    coreSt.inner.workspaces.setOwners(new Map([["ws-sse", "acct-sse"], ["ws-joined", "acct-sse"]]));
    enqueuedKeys.length = 0;
    await coreSt.inner.runner.run(
      coreSt.inner.cloudSync.afterWrite("acct-sse", "POST", "/v1/invitations/inv-1/accept", {
        view: { id: "ws-joined", name: "Joined", role: "member", members: [], stations: [] },
      }),
    );
    assert.ok(enqueuedKeys.includes("workspace/ws-joined"), "joined afterWrite (viewOf !== id) must enqueue full workspace reread");

    // 5. Astra P0-4: vault.approve with real `params.request` — positive control succeeds, stale boundary during #request rejects with auth_stale and 0 POSTs
    coreSt.inner.data.set(
      { topic: "workspace", workspace: "ws-sse" },
      { id: "ws-sse", name: "SSE", role: "owner", members: [], stations: [{ id: "s1", name: "S1", online: true }] },
      false,
    );
    const origReachable = coreSt.inner.stations.reachable.bind(coreSt.inner.stations);
    coreSt.inner.stations.reachable = (a) => (a === addr ? true : origReachable(a));
    let plainGrantPosts = 0;
    let bumpDuringRead = false;
    const origCall = coreSt.inner.stations.requests.call.bind(coreSt.inner.stations.requests);
    coreSt.inner.stations.requests.call = (station, method, path, body, ...rest) => {
      if (method === "POST" && path === "/vault/plain/grants") {
        plainGrantPosts++;
        return Effect.succeed({ ok: true });
      }
      if (method === "GET" && path === "/vault/plain") {
        return Effect.succeed({
          items: [{ id: "it-1", listing: { name: "API", kind: "token", modes: ["env"], hosts: [], lasts: "chat" } }],
        });
      }
      if (method === "GET" && path === "/vault/requests") {
        if (bumpDuringRead) {
          bumpDuringRead = false;
          coreSt.inner.store.authGen.bumpWorkspace("ws-sse");
        }
        return Effect.succeed({
          requests: [
            { id: "req-plain-ok", vault: "plain", item: "it-1", mode: "env", status: "pending", box: "" },
            { id: "req-plain-stale", vault: "plain", item: "it-1", mode: "env", status: "pending", box: "" },
          ],
        });
      }
      if (method === "GET" && path === "/vault/vaults") return Effect.succeed({ vaults: [] });
      if (method === "GET" && path === "/vault/items") return Effect.succeed({ items: [] });
      if (method === "GET" && path === "/vault/boxes") return Effect.succeed({ boxes: [] });
      if (method === "GET" && path.startsWith("/vault/")) return Effect.succeed({ uses: [] });
      return origCall(station, method, path, body, ...rest);
    };
    // Positive control: normal approve passes #request + entry boundary check (reaches plainMode -> vault_locked, NOT auth_stale)
    const cApp = coreSt.connect({ authHandshake: false });
    coreSt.receiveRaw(cApp, { id: 91, call: "vault.approve", params: { workspace: "ws-sse", request: "req-plain-ok", scope: "once" } });
    await stHost.time.pass(50);
    const okAns = stHost.takeEmitted().find(([c, m]) => c === cApp && "id" in m && m.id === 91) as [number, { ok?: unknown; error?: { code?: string } }] | undefined;
    assert.equal(okAns?.[1].error?.code, "vault_locked", `positive control vault.approve must pass #request + authGen check (expected vault_locked, got ${JSON.stringify(okAns?.[1])})`);
    assert.equal(plainGrantPosts, 0, "plainMode disabled prevents /vault/plain/grants");

    // Negative test: workspaceAuthGen bumps during #request async station read -> explicitly returns auth_stale and 0 new POSTs
    coreSt.inner.data.forgetRecord("vault", "ws-sse");
    plainGrantPosts = 0;
    bumpDuringRead = true;
    coreSt.receiveRaw(cApp, { id: 92, call: "vault.approve", params: { workspace: "ws-sse", request: "req-plain-stale", scope: "once" } });
    await stHost.time.pass(50);
    const staleAns = stHost.takeEmitted().find(([c, m]) => c === cApp && "id" in m && m.id === 92) as [number, { error?: { code?: string } }] | undefined;
    assert.equal(staleAns?.[1].error?.code, "auth_stale", "approve across boundary during #request must explicitly fail with auth_stale");
    assert.equal(plainGrantPosts, 0, "stale approve must issue 0 POST /vault/plain/grants");
    await coreSt.close();

    // 6. Astra P0-2: Dual-account different roles (acct-member owns ws-role, acct-admin also has live /v1/events socket) —
    // admin delta carrying `invitations`/`added` must NEVER be merged into acct-member's workspace view in either arrival order,
    // and must trigger a full owner-context reread instead.
    for (const order of ["admin-first", "member-first"] as const) {
      const dualHost = new FakeHost();
      dualHost.store(STORAGE_KEY, [
        account("acct-member", "m@x.com", "Member", "tok-member", "rm", nowS(dualHost) + 3600),
        account("acct-admin", "a@x.com", "Admin", "tok-admin", "ra", nowS(dualHost) + 3600),
      ]);
      const wsFetchByToken: string[] = [];
      let memberWsRev = 1;
      dualHost.onFetch((req) => {
        const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
        const isAdmin = auth === "Bearer tok-admin";
        const path = req.url.replace("https://stillfail.test", "");
        if (path === "/v1/me") {
          return jsonResponse(200, {
            workspaces: [{ id: "ws-role", name: "Shared", role: isAdmin ? "admin" : "member" }],
            invitations: [],
            relay_url: "https://relay.test",
          });
        }
        if (path === "/v1/workspaces/ws-role") {
          wsFetchByToken.push(isAdmin ? "admin" : "member");
          if (isAdmin) {
            return jsonResponse(200, {
              id: "ws-role",
              name: "Shared",
              role: "admin",
              rev: memberWsRev,
              members: [{ sub: "acct-member", role: "member" }, { sub: "acct-admin", role: "admin" }],
              invitations: [{ id: "inv-admin-only", email: "secret@example.com", role: "admin" }],
              stations: [],
            });
          }
          return jsonResponse(200, {
            id: "ws-role",
            name: "Shared",
            role: "member",
            rev: memberWsRev,
            members: [{ sub: "acct-member", role: "member" }],
            stations: [],
          });
        }
        return jsonResponse(404, { error: "not_found" });
      });
      const coreDual = await Core.create(dualHost, { clock: dualHost.time.clock, iroh: null });
      await dualHost.time.pass(500, 50);
      assert.equal(coreDual.inner.workspaces.owner("ws-role"), "acct-member", `${order}: acct-member should own ws-role`);
      const findSock = (tok: string) =>
        dualHost.sockets.find((s) => s.url.endsWith("/v1/events") && !s.closed && (s.url.includes(tok) || s.protocols.some((p) => p.includes(tok))));
      const memberSock = findSock("tok-member");
      const adminSock = findSock("tok-admin");
      assert.ok(memberSock && adminSock, `${order}: both accounts must have open /v1/events sockets`);

      wsFetchByToken.length = 0;
      memberWsRev = 2;
      const adminDelta = JSON.stringify({
        type: "workspace",
        id: "ws-role",
        rev: [1, 2],
        invitations: [{ id: "inv-secret", email: "secret@example.com", role: "admin" }],
        added: [{ sub: "acct-new", role: "admin" }],
      });
      const memberDelta = JSON.stringify({
        type: "workspace",
        id: "ws-role",
        rev: [1, 2],
        name: "Shared-Updated",
      });
      if (order === "admin-first") {
        adminSock.send(adminDelta);
        await dualHost.time.pass(200, 20);
        const mid = coreDual.inner.data.shared({ topic: "workspace", workspace: "ws-role" }) as Record<string, unknown> | undefined;
        assert.equal("invitations" in (mid ?? {}), false, `${order}: admin delta must never merge invitations into member view`);
        assert.equal("added" in (mid ?? {}), false, `${order}: admin delta must never merge added into member view`);
        assert.ok(wsFetchByToken.includes("member"), `${order}: non-owner delta must enqueue full owner workspace reread`);
        assert.equal(wsFetchByToken.includes("admin"), false, `${order}: owner reread must use acct-member, not acct-admin`);
        memberSock.send(memberDelta);
        await dualHost.time.pass(200, 20);
      } else {
        memberSock.send(memberDelta);
        await dualHost.time.pass(200, 20);
        adminSock.send(adminDelta);
        await dualHost.time.pass(200, 20);
      }
      const wsAfter = coreDual.inner.data.shared({ topic: "workspace", workspace: "ws-role" }) as Record<string, unknown> | undefined;
      assert.equal("invitations" in (wsAfter ?? {}), false, `${order}: final member view must never contain admin invitations`);
      assert.equal("added" in (wsAfter ?? {}), false, `${order}: final member view must never contain admin added`);
      await coreDual.close();
    }
  });

  it("r14: Retold scoped restore removal, #authFailed protected-sub drop + stale-conn RPC rejection + exponential backoff auto-recovery", async () => {
    // 1. Opus P1: concurrent full sharedRows read + scoped restore removal retains removal via Retold(readGen) so removed row never resurrects
    const rHost = new FakeHost();
    const rCore = await Core.create(rHost, { clock: rHost.time.clock, iroh: null });
    const addr = "ws-ret/s1";
    await rCore.inner.runner.run(rCore.inner.data.accounts(["acct-ret"]));
    rCore.inner.workspaces.setOwners(new Map([["ws-ret", "acct-ret"]]));
    rCore.inner.data.set({ topic: "workspace", workspace: "ws-ret" }, { id: "ws-ret", stations: [{ id: "s1", online: true }] }, false);
    rCore.inner.stations.reconcile();
    const link = rCore.inner.stations.link(addr);
    assert.ok(link, "reconcile must create link for ws-ret/s1");
    const origReach = rCore.inner.stations.reachable.bind(rCore.inner.stations);
    rCore.inner.stations.reachable = (a) => (a === addr ? true : origReach(a));
    // Seed a shared row + active restore entry, hold GET /chats?shared=1 (full list) while scoped restore returns empty rows
    const releaseFull = rHost.hold("/chats?shared=1");
    let scopedDone = false;
    const origReqCall = rCore.inner.stations.requests.call.bind(rCore.inner.stations.requests);
    rCore.inner.stations.requests.call = (station, method, path, body, ...rest) => {
      if (method === "GET" && path === "/chats?shared=1") {
        // Simulate slow full shared-list read that still contains row-gone
        return Effect.sleep(50).pipe(
          Effect.andThen(Effect.succeed({ rows: [{ id: "row-gone", session: "k-gone", title: "Gone", updatedAt: 10 }], me: "me@x.com", selves: ["me@x.com"] })),
        );
      }
      if (method === "GET" && path.startsWith("/chats?shared=1&session=k-gone")) {
        scopedDone = true;
        return Effect.succeed({ rows: [] });
      }
      return origReqCall(station, method, path, body, ...rest);
    };
    void releaseFull;
    // Register restore record in views.local and trigger both full shared read + scoped checkRestores concurrently
    rCore.inner.views.local.restores = (a: string) =>
      a === addr ? [{ id: 1, session: "k-gone", thread: null, restore: { id: "row-gone" }, restoreGuard: false } as never] : [];
    const curGen = rCore.inner.store.authGen.workspaceAuthGen("ws-ret");
    // Start full shared read (takes 50ms) and immediately fire scoped restore removal (completes at ~0ms)
    link.sharedRows = new Map();
    rCore.inner.stations.onEvent(addr, "chat-shared", JSON.stringify({ id: "row-gone", session: "k-gone", title: "Gone", updatedAt: 10 }), false, curGen);
    assert.equal(link.sharedRows.has("row-gone"), true, "precondition: row-gone must exist in sharedRows before scoped restore removal");
    rCore.inner.stations.checkRestores(addr, { session: "k-gone" });
    await rHost.time.pass(100, 10);
    assert.equal(scopedDone, true, "scoped restore check must have run");
    assert.equal(link.sharedRows?.has("row-gone") ?? false, false, "scoped restore removal must remove row-gone");
    await rCore.close();

    // 2. Astra P0-1 + Astra P1 + Opus P2: #authFailed blocks protected subscription frames (even without conn),
    // rejects stale-conn RPCs on/after recovery as auth_stale, and auto-recovers via exponential backoff without syncAuth.
    const fHost = new FakeHost();
    fHost.store(STORAGE_KEY, [account("acct-fail", "f@x.com", "Fail", "tok-f", "rf", nowS(fHost) + 3600)]);
    fHost.onFetch((req) => {
      if (req.url.endsWith("/v1/me")) {
        return jsonResponse(200, {
          workspaces: [{ id: "ws-fail", name: "Secret WS", role: "owner" }],
          invitations: [],
          relay_url: "https://relay.test",
        });
      }
      if (req.url.endsWith("/v1/workspaces/ws-fail")) {
        return jsonResponse(200, { id: "ws-fail", name: "Secret WS", role: "owner", members: [], stations: [] });
      }
      return jsonResponse(404, { error: "not_found" });
    });
    let failAuthWrite = true;
    const origSet = fHost.storageSet.bind(fHost);
    fHost.storageSet = (key, value) => {
      if (failAuthWrite && key.includes("auth")) return Effect.fail(new HostError("disk full"));
      return origSet(key, value);
    };
    const fCore = await Core.create(fHost, { clock: fHost.time.clock, iroh: null });
    await fCore.inner.runner.run(fCore.inner.data.accounts(["acct-fail"]));
    fCore.inner.workspaces.setOwners(new Map([["ws-fail", "acct-fail"]]));
    const cFail = fCore.connect({ authHandshake: true, requireCallAuth: true });
    await fHost.time.pass(50, 10);
    assert.equal(fCore.inner.store.isAuthFailed(cFail), true, "initial persist failure must mark client authFailed");
    fHost.takeEmitted();

    // (a) Protected workspace subscription emits 0 frames while #authFailed, whereas device-global passes
    fCore.inner.store.subscribe(cFail, 501, { topic: "workspace", workspace: "ws-fail" }, false);
    fCore.inner.store.subscribe(cFail, 502, { topic: "prefs" }, false);
    fCore.inner.data.set(
      { topic: "workspace", workspace: "ws-fail" },
      { id: "ws-fail", name: "Secret WS", role: "owner", members: [], stations: [] },
      false,
    );
    fCore.inner.store.invalidate({ topic: "workspace", workspace: "ws-fail" });
    fCore.inner.store.set({ topic: "prefs" }, { ok: { theme: "dark" } });
    await fHost.time.pass(50, 10);
    const duringFail = fHost.takeEmitted().filter(([c]) => c === cFail);
    assert.equal(
      duringFail.filter(([, m]) => "id" in m && m.id === 501).length,
      0,
      "#authFailed client must receive 0 frames for protected workspace topic even without conn",
    );
    assert.ok(
      duringFail.some(([, m]) => "id" in m && m.id === 502 && "value" in m),
      "device-global topic without conn may still pass through while #authFailed",
    );

    // (c) Restore storageSet and advance virtual clock (NO manual syncAuth) -> exponential backoff auto-recovers!
    failAuthWrite = false;
    await fHost.time.pass(2_500, 100);
    assert.equal(fCore.inner.store.isAuthFailed(cFail), false, "exponential backoff retry must automatically clear #authFailed");
    const recoveredConn = fCore.inner.store.connOf(cFail);
    assert.ok(recoveredConn > 0, "auto-recovery must establish a persisted connId > 0");
    const afterRecover = fHost.takeEmitted().filter(([c]) => c === cFail);
    assert.ok(
      afterRecover.some(([, m]) => "id" in m && m.id === 0 && "auth" in m && (m.auth as { conn?: number }).conn === recoveredConn),
      "auto-recovery must emit authoritative { id: 0, auth } snapshot with new connId",
    );
    // r15 P1: without any new store.set or re-subscribe, auto-recovery immediately replays full initial value for protected sub 501
    const replayedSub501 = afterRecover.find(([, m]) => "id" in m && m.id === 501 && "value" in m) as
      | [number, { id: number; value?: { id?: string; name?: string }; conn?: number }]
      | undefined;
    assert.ok(replayedSub501 !== undefined, `auto-recovery must replay protected subscription 501 initial value without new writes, got ${JSON.stringify(afterRecover)}`);
    assert.equal(replayedSub501[1].value?.id, "ws-fail", "replayed initial value must match full sent workspace");
    assert.equal(replayedSub501[1].value?.name, "Secret WS", "replayed initial value must match full sent workspace name");
    assert.equal(replayedSub501[1].conn, recoveredConn, "replayed initial value must carry new recoveredConn");

    // (b) Stale-conn RPC reply (oldConn !== recoveredConn) arriving after recovery (or drained during markClientAuthReady)
    // is rejected as auth_stale without conn, never delivered with stale conn!
    const oldConn = recoveredConn - 1 > 0 ? recoveredConn - 1 : recoveredConn + 999;
    fCore.inner.store.emitClient(cFail, { id: 601, ok: { leaked: true }, conn: oldConn, authGen: 1 } as CoreMessage, true);
    const staleRpcEmits = fHost.takeEmitted().filter(([c, m]) => c === cFail && "id" in m && m.id === 601);
    assert.equal(staleRpcEmits.length, 1, "stale-conn RPC must emit an error reply");
    const staleReply = staleRpcEmits[0]![1] as { error?: { code?: string }; conn?: number; ok?: unknown };
    assert.equal(staleReply.error?.code, "auth_stale", "stale-conn RPC must be rejected with auth_stale");
    assert.equal(staleReply.conn, undefined, "auth_stale rejection must not carry stale conn");
    assert.equal(staleReply.ok, undefined, "stale-conn RPC must not deliver ok payload");
    await fCore.close();
  });

  it("lock-only downgrade keeps workspace readable for blocked station views while gating station held data, and cloud fullRead role downgrade confirms workspace without deadlocking", async () => {
    const host = new FakeHost();
    host.store(STORAGE_KEY, [account("acct-lock", "a@x.test", "A", "tok-lock", "ref-lock", nowS(host) + 3600)]);
    let role = "owner";
    let locked = false;
    host.onFetch((req) => {
      const path = req.url.replace("https://stillfail.test", "");
      if (path === "/v1/me") {
        return jsonResponse(200, { workspaces: [{ id: "ws-lock", name: "Dev", role }], invitations: [], relay_url: "https://relay.test" });
      }
      if (path === "/v1/workspaces/ws-lock") {
        return jsonResponse(200, { id: "ws-lock", name: "Dev", role, ...(locked ? { locked: true } : {}), stations: [{ id: "st-1", name: "willow", online: true }] });
      }
      if (path === "/v1/me/personal-lock") {
        return jsonResponse(200, { head: null, entries: [] });
      }
      return jsonResponse(404, { error: "not_found" });
    });
    const core = await Core.create(host, { clock: host.time.clock, iroh: null });
    await host.time.pass(500, 50);

    const wsTopic: Topic = { topic: "workspace", workspace: "ws-lock" };
    const overviewTopic: Topic = { topic: "overview", station: "ws-lock/st-1" };
    const chatRowsTopic: Topic = { topic: "chatRows", station: "ws-lock/st-1" };
    (core.inner.adb.personal() as unknown as { isLoaded: () => boolean }).isLoaded = () => true;
    syncWorkspaceAuth(core.inner, "ws-lock");

    // Seed station held records under initial gen.
    core.inner.data.set(overviewTopic, { counts: { running: 1 } }, false);
    core.inner.data.set(chatRowsTopic, [{ id: "c1" }], false);
    assert.equal(core.inner.pendingAuthConfirm.has("ws-lock"), false);
    assert.ok(core.inner.store.value(wsTopic) !== undefined);
    assert.ok(core.inner.store.value(overviewTopic) !== undefined);

    // 1. Lock-only downgrade (`safe: false -> true`, e.g. untrusted device discovering safe mode while cloud role/owner is unchanged):
    const genBeforeLock = core.inner.store.authGen.workspaceAuthGen("ws-lock");
    locked = true;
    core.inner.data.set(wsTopic, { id: "ws-lock", name: "Dev", role: "owner", locked: true, stations: [{ id: "st-1", name: "willow", online: true }] });
    await host.time.pass(50, 10);
    assert.ok(core.inner.store.authGen.workspaceAuthGen("ws-lock") > genBeforeLock, "lock-only downgrade must advance authGen");
    assert.equal(core.inner.pendingAuthConfirm.has("ws-lock"), true, "lock-only downgrade must still set pendingAuthConfirm");
    assert.equal(core.inner.store.value(overviewTopic), undefined, "station overview must remain gated on lock-only downgrade");
    assert.equal(core.inner.store.value(chatRowsTopic), undefined, "station chatRows must remain gated on lock-only downgrade");
    assert.ok(
      core.inner.store.value(wsTopic) !== undefined,
      "workspace metadata must stay readable on lock-only downgrade so station/lock views surface blocked state even when cloud is offline",
    );

    // 2. Cloud role downgrade (`owner -> member`) via authoritative fullRead `#workspace("ws-lock")`:
    // Must bump authGen, keep station held data gated, and immediately confirm `{ topic: "workspace" }` with the new role.
    const genBeforeRole = core.inner.store.authGen.workspaceAuthGen("ws-lock");
    role = "member";
    core.inner.cloudSync.refreshWorkspace("ws-lock");
    await host.time.pass(200, 20);
    assert.ok(core.inner.store.authGen.workspaceAuthGen("ws-lock") > genBeforeRole, "cloud role downgrade must advance authGen");
    assert.equal(core.inner.pendingAuthConfirm.has("ws-lock"), true, "cloud role downgrade must keep pendingAuthConfirm active for station data");
    assert.equal(core.inner.store.value(overviewTopic), undefined, "station overview must remain gated after cloud role downgrade");
    const wsAfterRole = core.inner.store.value(wsTopic) as { ok?: { role?: string } } | undefined;
    assert.equal(wsAfterRole?.ok?.role, "member", "authoritative fullRead workspace view must recover with downgraded role without deadlocking");

    await core.close();
  });

  it("lock downgrade following an unconfirmed cloud downgrade preserves workspace gate and re-triggers cloud refresh", async () => {
    const host = new FakeHost();
    host.store(STORAGE_KEY, [account("acct-seq", "a@x.test", "A", "tok-seq", "ref-seq", nowS(host) + 3600)]);
    let fullReads = 0;
    let holdFetches = false;
    let role = "admin";
    let locked = false;
    const heldResponses: (() => void)[] = [];
    host.onFetch((req) => {
      const path = req.url.replace("https://stillfail.test", "");
      if (path === "/v1/me") {
        return jsonResponse(200, { workspaces: [{ id: "ws-seq", name: "Dev", role }], invitations: [], relay_url: "https://relay.test" });
      }
      if (path === "/v1/workspaces/ws-seq") {
        fullReads++;
        const payload = () => ({
          id: "ws-seq",
          name: "Dev",
          role,
          ...(locked ? { locked: true } : {}),
          ...(role === "admin" ? { adminOnly: "SECRET_ADMIN_FIELD" } : {}),
          stations: [{ id: "st-1", name: "willow", online: true }],
        });
        if (!holdFetches) return jsonResponse(200, payload());
        return new Promise((resolve) => {
          heldResponses.push(() => resolve(jsonResponse(200, payload())));
        });
      }
      if (path === "/v1/me/personal-lock") {
        return jsonResponse(200, { head: null, entries: [] });
      }
      return jsonResponse(404, { error: "not_found" });
    });
    const core = await Core.create(host, { clock: host.time.clock, iroh: null });
    await host.time.pass(500, 50);

    const wsTopic: Topic = { topic: "workspace", workspace: "ws-seq" };
    (core.inner.adb.personal() as unknown as { isLoaded: () => boolean }).isLoaded = () => true;
    syncWorkspaceAuth(core.inner, "ws-seq");
    let stationRefreshes = 0;
    const origStationRefresh = core.inner.stations.refreshWorkspace.bind(core.inner.stations);
    core.inner.stations.refreshWorkspace = (ws: string) => {
      if (ws === "ws-seq") stationRefreshes++;
      origStationRefresh(ws);
    };
    const readsAtStart = fullReads;
    assert.equal((core.inner.store.value(wsTopic) as { ok?: { adminOnly?: string } } | undefined)?.ok?.adminOnly, "SECRET_ADMIN_FIELD");

    // 1. Non-fullRead cloud downgrade (`admin -> member`) while the authoritative cloud reread is held in flight.
    holdFetches = true;
    role = "member";
    core.inner.data.set(wsTopic, {
      id: "ws-seq",
      name: "Dev",
      role: "member",
      adminOnly: "SECRET_ADMIN_FIELD",
      stations: [{ id: "st-1", name: "willow", online: true }],
    });
    await host.time.pass(50, 10);
    assert.equal(core.inner.store.value(wsTopic), undefined, "unconfirmed cloud downgrade must gate workspace view");
    assert.equal(fullReads, readsAtStart + 1, "cloud downgrade must trigger authoritative workspace refresh");
    assert.equal(stationRefreshes, 1, "cloud downgrade must trigger station refresh");

    // 2. Lock-only downgrade arrives BEFORE the in-flight cloud reread finishes:
    // Must NOT pre-confirm `{ topic: "workspace" }` (zero leak of SECRET_ADMIN_FIELD) AND must re-enqueue refresh at the new gen.
    locked = true;
    core.inner.data.set(wsTopic, {
      id: "ws-seq",
      name: "Dev",
      role: "member",
      locked: true,
      adminOnly: "SECRET_ADMIN_FIELD",
      stations: [{ id: "st-1", name: "willow", online: true }],
    });
    await host.time.pass(50, 10);
    assert.equal(core.inner.store.value(wsTopic), undefined, "lock downgrade must NEVER bypass an unconfirmed cloud downgrade gate");
    assert.equal(stationRefreshes, 2, "lock downgrade while cloud unconfirmed must re-trigger station refresh");

    // Release the stale in-flight G+1 response (discarded by readGen check), then release the new G+2 refresh!
    assert.ok(heldResponses.length >= 1, "first cloud refresh must be in flight");
    heldResponses.shift()!();
    await host.time.pass(50, 10);
    assert.equal(core.inner.store.value(wsTopic), undefined, "stale pre-lock-bump cloud response must be discarded");
    assert.equal(fullReads, readsAtStart + 2, "lock downgrade while cloud unconfirmed must schedule a fresh G+2 reread");
    assert.equal(heldResponses.length, 1, "fresh G+2 cloud refresh must be in flight");
    heldResponses.shift()!();
    await host.time.pass(50, 10);

    const recovered = core.inner.store.value(wsTopic) as { ok?: { role?: string; adminOnly?: string; locked?: boolean } } | undefined;
    assert.equal(recovered?.ok?.role, "member", "workspace must recover once fresh G+2 fullRead completes");
    assert.equal(recovered?.ok?.adminOnly, undefined, "recovered member view must not contain adminOnly");
    assert.equal(recovered?.ok?.locked, true);

    // 3. Lock-only upgrade (`locked: true -> false`) while a cloud downgrade (`admin -> member`) is still unconfirmed:
    // Must preserve pendingAuthConfirm AND trigger both cloudSync.refreshWorkspace and stations.refreshWorkspace at the new gen.
    holdFetches = false;
    role = "admin";
    core.inner.cloudSync.refreshWorkspace("ws-seq");
    await host.time.pass(100, 20);
    assert.equal((core.inner.store.value(wsTopic) as { ok?: { role?: string } } | undefined)?.ok?.role, "admin");
    const readsBeforeUpgradeCase = fullReads;
    const stationRefreshesBeforeUpgradeCase = stationRefreshes;

    holdFetches = true;
    role = "member";
    core.inner.data.set(wsTopic, {
      id: "ws-seq",
      name: "Dev",
      role: "member",
      locked: true,
      adminOnly: "SECRET_ADMIN_FIELD",
      stations: [{ id: "st-1", name: "willow", online: true }],
    });
    await host.time.pass(50, 10);
    assert.equal(core.inner.store.value(wsTopic), undefined, "unconfirmed cloud downgrade must gate workspace view");
    assert.equal(stationRefreshes, stationRefreshesBeforeUpgradeCase + 1);

    locked = false;
    core.inner.data.set(wsTopic, {
      id: "ws-seq",
      name: "Dev",
      role: "member",
      adminOnly: "SECRET_ADMIN_FIELD",
      stations: [{ id: "st-1", name: "willow", online: true }],
    });
    await host.time.pass(50, 10);
    assert.equal(core.inner.store.value(wsTopic), undefined, "lock-only upgrade must NOT clear an unconfirmed cloud downgrade gate");
    assert.equal(
      stationRefreshes,
      stationRefreshesBeforeUpgradeCase + 2,
      "lock-only upgrade while cloud unconfirmed must also refresh stations under the new authGen",
    );

    heldResponses.shift()!();
    await host.time.pass(50, 10);
    assert.equal(core.inner.store.value(wsTopic), undefined, "stale pre-upgrade cloud response must be discarded");
    assert.equal(fullReads, readsBeforeUpgradeCase + 2, "lock-only upgrade while cloud unconfirmed must schedule a fresh reread");
    assert.equal(heldResponses.length, 1);
    heldResponses.shift()!();
    await host.time.pass(50, 10);

    const recoveredAfterUpgrade = core.inner.store.value(wsTopic) as { ok?: { role?: string; adminOnly?: string; locked?: boolean } } | undefined;
    assert.equal(recoveredAfterUpgrade?.ok?.role, "member");
    assert.equal(recoveredAfterUpgrade?.ok?.adminOnly, undefined);
    assert.equal(recoveredAfterUpgrade?.ok?.locked, undefined);

    await core.close();
  });

  it("Direction 2A: AuthCapability / WorkspaceCapability / VaultCapability / CompositeCapability enforce generation, vault isolation, owner binding, and guarded egress/commits", async () => {
    const tracker = new AuthGenTracker();
    let owner = "acct-a";

    // 1. WorkspaceCapability without trackVaultGlobal (ADB semantics): unaffected by vault.lock, invalidated by workspace bump or owner switch
    const adbCap = tracker.workspaceCapability("wsA", { sub: "acct-a", resolveOwner: () => owner });
    assert.equal(adbCap.isValid(), true);
    let committed = 0;
    assert.equal(adbCap.commit(() => ++committed), 1);

    // vault.lock does NOT invalidate ADB WorkspaceCapability, but DOES invalidate vaultWorkspaceCapability
    const vaultWsCap = tracker.vaultWorkspaceCapability("wsA");
    const v1Cap = tracker.vaultCapability("wsA", "v1");
    const v2Cap = tracker.vaultCapability("wsA", "v2");
    tracker.bumpVault("wsA", "v1");
    assert.equal(adbCap.isValid(), true, "single-vault bump must not invalidate ADB WorkspaceCapability");
    assert.equal(vaultWsCap.isValid(), true, "single-vault bump must not invalidate vaultGlobal-only WorkspaceCapability");
    assert.equal(v1Cap.isValid(), false, "single-vault bump must invalidate v1 VaultCapability");
    assert.equal(v2Cap.isValid(), true, "single-vault bump must NOT invalidate v2 VaultCapability");

    // Guarded egress sink refuses stale v1Cap without invoking the inner effect
    let egressCalls = 0;
    const v1Res = await Effect.runPromise(
      Effect.result(v1Cap.ask(() => Effect.sync(() => ++egressCalls))),
    );
    assert.equal(v1Res._tag, "Failure");
    assert.equal(v1Res.failure.code, "auth_stale");
    assert.equal(egressCalls, 0, "stale capability must block egress before running effect");
    assert.equal(v1Cap.commit(() => ++committed), undefined, "stale capability must block commit");

    // v2Cap still succeeds
    const v2Res = await Effect.runPromise(v2Cap.guard(Effect.sync(() => ++egressCalls)));
    assert.equal(v2Res, 1);

    // 2. AuthCapability snapshot anchoring: narrowVault / workspace derived AFTER an intermediate bump stay anchored to entry snapshot
    const entryCap = tracker.capture();
    const compositeCap = AuthCapability.all(
      entryCap.workspace("wsB", { trackVaultGlobal: true }),
      entryCap.vault("wsA", "v2"),
    );
    assert.equal(compositeCap.isValid(), true);
    tracker.bumpVault("wsA", "v2");
    assert.equal(compositeCap.isValid(), false, "CompositeCapability must invalidate when source vault bumps");
    assert.equal(
      entryCap.vault("wsA", "v2").isValid(),
      false,
      "VaultCapability derived from entry AuthCapability must stay anchored to entry snapshot",
    );

    // 3. vault.lock invalidates vaultWorkspaceCapability but NOT ADB WorkspaceCapability
    tracker.bumpAllVaults();
    assert.equal(vaultWsCap.isValid(), false, "bumpAllVaults must invalidate vaultWorkspaceCapability");
    assert.equal(adbCap.isValid(), true, "bumpAllVaults must NOT invalidate ADB WorkspaceCapability");

    // 4. Owner switch invalidates owner-bound WorkspaceCapability immediately even without wsAuthGen bump
    owner = "acct-b";
    assert.equal(adbCap.isValid(), false, "owner switch must invalidate owner-bound WorkspaceCapability");
    const ownerFail = await Effect.runPromise(Effect.result(adbCap.assertValid()));
    assert.equal(ownerFail._tag, "Failure");
    assert.equal(ownerFail.failure.code, "auth_stale");

    // 5. Opus P2: workspaceCapability().narrowVault() stays anchored to entry snapshot even if vault bumps after capture
    const wsCapEntry = tracker.vaultWorkspaceCapability("ws-anchor");
    tracker.bumpVault("ws-anchor", "v-late");
    const narrowedLate = wsCapEntry.narrowVault("v-late");
    assert.equal(
      narrowedLate.isValid(),
      false,
      "narrowVault() derived from workspaceCapability() must anchor to entry snapshot, not post-bump current gen",
    );
    // And AuthCapability does NOT expose guard/commit directly (must narrow to workspace/vault/all)
    assert.equal("guard" in entryCap, false, "AuthCapability must not expose guard() directly");
    assert.equal("commit" in entryCap, false, "AuthCapability must not expose commit() directly");
  });

  it("Direction 2A P1-2/P1-3/P1-4: HostWire transport guard blocks stale send before fetch, and stale ACK commit is suppressed", async () => {
    const tracker = new AuthGenTracker();
    const { HostWire } = await import("../src/station/wire.ts");
    const { StationAddr } = await import("../src/station/addr.ts");

    let fetchCalls = 0;
    const host = new FakeHost();
    host.fetch = () =>
      Effect.sync(() => {
        fetchCalls++;
        return { status: 200, headers: [], body: new TextEncoder().encode("{}") };
      });
    const wire = new HostWire(host);
    const addr = new StationAddr("ws-wire", "st-1");
    const head = { method: "PUT", path: "/vault/items", headers: [] as [string, string][] };

    // 1. P1-3: guard returns false before send -> HostWire aborts with auth_stale and 0 fetch calls
    const cap = tracker.vaultCapability("ws-wire", "v1");
    tracker.bumpVault("ws-wire", "v1");
    const staleRes = await Effect.runPromise(
      Effect.scoped(Effect.result(wire.request(addr, head, new Uint8Array(), undefined, () => cap.isValid()))),
    );
    assert.equal(staleRes._tag, "Failure");
    assert.equal(staleRes.failure.code, "auth_stale");
    assert.equal(fetchCalls, 0, "transport-level guard must abort with auth_stale before calling host.fetch");

    // 2. P1-4: ACK arrives after auth boundary -> cap.commit suppresses local write-back cleanly
    const cap2 = tracker.vaultCapability("ws-wire", "v2");
    let localWrites = 0;
    const okRes = await Effect.runPromise(
      Effect.scoped(wire.request(addr, head, new Uint8Array(), undefined, () => cap2.isValid())),
    );
    assert.equal(okRes.status, 200);
    assert.equal(fetchCalls, 1);
    // Boundary fires while awaiting ACK
    tracker.bumpVault("ws-wire", "v2");
    const committed = cap2.commit(() => {
      localWrites++;
      return true;
    });
    assert.equal(committed, undefined, "post-ACK commit must be suppressed once capability is stale");
    assert.equal(localWrites, 0, "stale ACK must never mutate local cache");

    // 3. P1-3: Requests.call forwards guard to StationWire.request so invalidation while waiting for a link aborts with auth_stale and 0 sends
    const { CoreError } = await import("../src/error.ts");
    const cap3 = tracker.vaultCapability("ws-wire", "v3");
    let wireSent = 0;
    const enteredWait = Deferred.makeUnsafe<void>();
    const waitGate = Deferred.makeUnsafe<void>();
    const fakeWire = {
      request: (_station: InstanceType<typeof StationAddr>, _head: { method: string; path: string; headers: [string, string][] }, _body: Uint8Array, _onProgress?: unknown, guard?: () => boolean) =>
        Effect.gen(function* () {
          if (guard && !guard()) return yield* Effect.fail(new CoreError("auth_stale", "stale"));
          yield* Deferred.succeed(enteredWait, undefined);
          yield* Deferred.await(waitGate);
          if (guard && !guard()) return yield* Effect.fail(new CoreError("auth_stale", "stale"));
          wireSent++;
          return { status: 200, headers: [] as [string, string][], body: { take: Effect.succeed(null) }, via: null };
        }),
    };
    const hostWire = new FakeHost();
    const coreWire = await Core.create(hostWire, { clock: hostWire.time.clock, wire: () => fakeWire, iroh: null });
    try {
      const pending = Effect.runPromise(Effect.result(coreWire.inner.stations.requests.call(addr, "PUT", "/vault/items", {}, { guard: () => cap3.isValid() })));
      await Effect.runPromise(Deferred.await(enteredWait));
      tracker.bumpVault("ws-wire", "v3");
      Effect.runSync(Deferred.succeed(waitGate, undefined));
      const waitRes = await pending;
      assert.equal(waitRes._tag, "Failure");
      assert.equal(waitRes.failure.code, "auth_stale");
      assert.equal(wireSent, 0, "invalidation while waiting for link must abort before sending");
    } finally {
      await coreWire.close();
    }

    // 4. R3 P1-1: Real Link.#open re-checks guard AFTER conn.openBi() resolves and resets stream with 0 writes
    const { Link } = await import("../src/mesh.ts");
    const makePendingLinkCase = async (kind: "request" | "ask") => {
      const capOpen = tracker.vaultCapability("ws-wire", `v-open-${kind}`);
      const enteredOpenBi = Deferred.makeUnsafe<void>();
      const releaseOpenBi = Deferred.makeUnsafe<void>();
      let writeCalls = 0;
      let resetCalls = 0;
      const fakeStream = {
        write: () => Effect.sync(() => { writeCalls++; }),
        finish: () => Effect.void,
        read: () => Effect.succeed(null),
        reset: () => { resetCalls++; },
      };
      const fakeConn = {
        openBi: () =>
          Effect.gen(function* () {
            yield* Deferred.succeed(enteredOpenBi, undefined);
            yield* Deferred.await(releaseOpenBi);
            return fakeStream;
          }),
        acceptBi: () => Effect.succeed(null),
        paths: () => [],
        stats: () => ({ rxBytes: 0, txBytes: 0 }),
        closeReason: () => null,
        close: () => {},
      };
      const fakeControl = {} as never;
      const fakeCreds = { credential: () => Effect.succeed("cred") } as never;
      const link = new Link(fakeConn as never, fakeControl, "cred", fakeCreds, null);
      const pendingCall = Effect.runPromise(
        Effect.result(
          kind === "request"
            ? link.request(head, new Uint8Array([1, 2, 3]), undefined, () => capOpen.isValid())
            : link.ask(head, { adb: { op: "revoke" } }, () => capOpen.isValid()),
        ),
      );
      await Effect.runPromise(Deferred.await(enteredOpenBi));
      tracker.bumpVault("ws-wire", `v-open-${kind}`);
      Effect.runSync(Deferred.succeed(releaseOpenBi, undefined));
      const res = await pendingCall;
      assert.equal(res._tag, "Failure", `Link.${kind} must fail when invalidated during openBi()`);
      assert.equal(res.failure.code, "auth_stale", `Link.${kind} must fail with auth_stale`);
      assert.equal(writeCalls, 0, `Link.${kind} must write 0 bytes after openBi() when guard is stale`);
      assert.equal(resetCalls, 1, `Link.${kind} must reset the opened stream immediately when guard is stale`);
    };
    await makePendingLinkCase("request");
    await makePendingLinkCase("ask");

    // 5. R4 P1-1: Link.#open re-checks guard between head write and body write (0 body bytes written)
    //    AND between BODY_STEP chunks (2nd chunk never written)
    const { BODY_STEP } = await import("../src/mesh.ts");
    const runWriteSuspendCase = async (mode: "head-to-body" | "chunked") => {
      const capW = tracker.vaultCapability("ws-wire", `v-write-${mode}`);
      const enteredWrite = Deferred.makeUnsafe<void>();
      const releaseWrite = Deferred.makeUnsafe<void>();
      const writes: Uint8Array[] = [];
      let resetCalls = 0;
      const suspendOnCall = mode === "head-to-body" ? 1 : 2; // 1=head, 2=first body chunk
      const fakeStream = {
        write: (bytes: Uint8Array) =>
          Effect.gen(function* () {
            writes.push(bytes.slice());
            if (writes.length === suspendOnCall) {
              yield* Deferred.succeed(enteredWrite, undefined);
              yield* Deferred.await(releaseWrite);
            }
          }),
        finish: () => Effect.void,
        read: () => Effect.succeed(null),
        reset: () => { resetCalls++; },
      };
      const fakeConn = {
        openBi: () => Effect.succeed(fakeStream),
        acceptBi: () => Effect.succeed(null),
        paths: () => [],
        stats: () => ({ rxBytes: 0, txBytes: 0 }),
        closeReason: () => null,
        close: () => {},
      };
      const link = new Link(fakeConn as never, {} as never, "cred", { credential: () => Effect.succeed("cred") } as never, null);
      const payload = mode === "head-to-body" ? new Uint8Array([9, 8, 7, 6]) : new Uint8Array(BODY_STEP + 16).fill(42);
      const wroteProgress: number[] = [];
      const pendingCall = Effect.runPromise(
        Effect.result(
          link.request(
            head,
            payload,
            mode === "chunked" ? (n) => wroteProgress.push(n) : undefined,
            () => capW.isValid(),
          ),
        ),
      );
      await Effect.runPromise(Deferred.await(enteredWrite));
      tracker.bumpVault("ws-wire", `v-write-${mode}`);
      Effect.runSync(Deferred.succeed(releaseWrite, undefined));
      const res = await pendingCall;
      assert.equal(res._tag, "Failure", `${mode}: must fail when capability revoked mid-write`);
      assert.equal(res.failure.code, "auth_stale", `${mode}: must fail with auth_stale`);
      assert.equal(resetCalls, 1, `${mode}: must reset stream immediately`);
      if (mode === "head-to-body") {
        assert.equal(writes.length, 1, "head-to-body: stream.write must be called only once (0 body bytes written)");
      } else {
        assert.equal(writes.length, 2, "chunked: 2nd body chunk must never be written after revocation");
        assert.deepEqual(wroteProgress, [BODY_STEP], "chunked: only 1st chunk progress recorded");
      }
    };
    await runWriteSuspendCase("head-to-body");
    await runWriteSuspendCase("chunked");
  });
});
