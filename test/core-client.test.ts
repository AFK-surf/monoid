import assert from "node:assert/strict";
import { test } from "node:test";
import { CoreClient, CoreError, WAKE_ANSWER_MS, type Channel, type Opener } from "../web/src/core/client.ts";

/** A worker stand-in: records what the client posts and answers on demand. */
class FakeWorkers {
  opened: {
    conn: number;
    sent: unknown[];
    closed: boolean;
    reply: (data: unknown) => void;
    replyRaw: (data: unknown) => void;
    handshake: (overrides?: Record<string, unknown>) => void;
    fail: (reason: string) => void;
  }[] = [];
  delays: number[] = [];
  #autoHandshake: boolean;
  #nextConn = 1;

  constructor(options: { autoHandshake?: boolean } = {}) {
    this.#autoHandshake = options.autoHandshake ?? true;
  }

  opener: Opener = (onMessage, onFail) => {
    const conn = this.#nextConn++;
    const replyRaw = (data: unknown) => onMessage(data);
    const reply = (data: unknown) => {
      if (this.#autoHandshake && typeof data === "object" && data !== null) {
        const m = data as Record<string, unknown>;
        if (typeof m.id === "number" && m.id > 0 && ("value" in m || "delta" in m || "ok" in m || "waiting" in m || "error" in m)) {
          onMessage({ conn, authGen: 1, vaultGen: 1, ...m });
          return;
        }
      }
      onMessage(data);
    };
    const handshake = (overrides: Record<string, unknown> = {}) => {
      onMessage({
        id: 0,
        auth: { conn, global: 1, aggregate: 1, vaultGlobal: 1, scopes: {}, vaults: {}, ...overrides },
      });
    };
    const worker = { conn, sent: [] as unknown[], closed: false, reply, replyRaw, handshake, fail: onFail };
    this.opened.push(worker);
    const channel: Channel = { post: (message) => worker.sent.push(structuredClone(message)), close: () => { worker.closed = true; } };
    if (this.#autoHandshake) queueMicrotask(() => { if (!worker.closed) handshake(); });
    return channel;
  };
  get last() {
    const worker = this.opened.at(-1);
    assert.ok(worker);
    return worker;
  }
  client(): CoreClient {
    const c = new CoreClient(this.opener, { schedule: (ms, run) => { this.delays.push(ms); run(); } });
    if (this.#autoHandshake && this.opened.length > 0) this.last.handshake();
    return c;
  }
}

test("a call is answered by the message with its id", async () => {
  const workers = new FakeWorkers();
  const client = workers.client();
  const first = client.call("station.request", { station: "local", method: "GET", path: "/overview" });
  const second = client.call("auth.signOut", { account: "a" });
  assert.deepEqual(workers.last.sent, [
    { id: 1, call: "station.request", params: { station: "local", method: "GET", path: "/overview" }, auth: { conn: 1, authGen: 1 } },
    { id: 2, call: "auth.signOut", params: { account: "a" }, auth: { conn: 1, authGen: 1, account: "a" } },
  ]);
  workers.last.reply({ id: 2, error: { code: "signed_out", message: "已退出", status: 401 } });
  workers.last.reply({ id: 1, ok: { hosts: 1 } });
  assert.deepEqual(await first, { hosts: 1 });
  await assert.rejects(second, (error: unknown) => error instanceof CoreError && error.code === "signed_out" && error.status === 401 && error.message === "已退出");
});

test("subscription values and errors go to their subscriber until it unsubscribes", () => {
  const workers = new FakeWorkers();
  const client = workers.client();
  const seen: unknown[] = [];
  const stop = client.subscribe({ topic: "sessions", station: "w/s" }, (v) => seen.push(v), (e) => seen.push(e.code));
  assert.deepEqual(workers.last.sent, [{ id: 1, subscribe: { topic: "sessions", station: "w/s" }, keyed: true }]);
  workers.last.reply({ id: 1, value: [] });
  workers.last.reply({ id: 1, error: { code: "offline", message: "离线" } });
  workers.last.reply({ id: 1, value: [{ key: "k" }] });
  stop();
  stop();
  workers.last.reply({ id: 1, value: ["late"] });
  assert.deepEqual(seen, [[], "offline", [{ key: "k" }]]);
  assert.deepEqual(workers.last.sent.at(-1), { id: 1, unsubscribe: true });
  assert.equal(workers.last.sent.length, 2);
});

test("a failed worker is replaced: calls in flight fail, subscriptions come back", async () => {
  const workers = new FakeWorkers();
  const client = workers.client();
  const values: unknown[] = [];
  client.subscribe({ topic: "accounts" }, (v) => values.push(v), () => undefined);
  const stopped = client.subscribe({ topic: "link", station: "w/s" }, () => undefined, () => undefined);
  stopped();
  const pending = client.call("cloud.request", {});
  const old = workers.last;
  old.reply({ fatal: "unreachable" });
  await assert.rejects(pending, (error: unknown) => error instanceof CoreError && error.code === "core_restarted");
  assert.equal(old.closed, true);
  assert.equal(workers.opened.length, 2);
  assert.deepEqual(workers.last.sent, [{ id: 1, subscribe: { topic: "accounts" }, keyed: true }]);
  // The old worker's late words are not the new one's.
  old.reply({ id: 1, value: "stale" });
  workers.last.reply({ id: 1, value: ["a"] });
  assert.deepEqual(values, [["a"]]);
  // Calls get fresh ids.
  void client.call("x");
  assert.deepEqual(workers.last.sent.at(-1), { id: 4, call: "x", params: {} });
});

test("faults the worker reports and the worker failing go to onFault, not to calls", async () => {
  const workers = new FakeWorkers();
  const faults: Error[] = [];
  const client = new CoreClient(workers.opener, { schedule: (_ms, run) => run(), onFault: (error) => faults.push(error) });
  const pending = client.call("x");
  workers.last.reply({ fault: { name: "TypeError", message: "boom", stack: "TypeError: boom\n    at worker.js:1:1" } });
  workers.last.reply({ id: 1, ok: 1 });
  assert.equal(await pending, 1);
  workers.last.reply({ fatal: "panic" });
  workers.last.fail("load");
  assert.deepEqual(faults.map((e) => [e.name, e.message]), [["TypeError", "boom"], ["CoreFailed", "panic"], ["CoreFailed", "load"]]);
  assert.equal(faults[0]!.stack, "TypeError: boom\n    at worker.js:1:1");
});

test("a worker that keeps failing is retried with growing pauses, reset by a healthy answer", () => {
  const workers = new FakeWorkers();
  workers.client();
  workers.last.fail("load");
  workers.last.fail("load");
  workers.last.reply({ fatal: "panic" });
  assert.deepEqual(workers.delays, [0, 1000, 2000]);
  workers.last.reply({ id: 99, ok: null });
  workers.last.fail("again");
  assert.deepEqual(workers.delays, [0, 1000, 2000, 0]);
});

test("calls made while the worker is being replaced are sent once it is up", () => {
  const workers = new FakeWorkers();
  let later: (() => void) | null = null;
  const client = new CoreClient(workers.opener, { schedule: (_ms, run) => { later = run; } });
  workers.last.fail("gone");
  void client.call("auth.begin", { redirect_uri: "r" });
  client.subscribe({ topic: "workspaces" }, () => undefined, () => undefined);
  assert.equal(workers.opened.length, 1);
  assert.ok(later);
  (later as () => void)();
  assert.deepEqual(workers.last.sent, [{ id: 2, subscribe: { topic: "workspaces" }, keyed: true }, { id: 1, call: "auth.begin", params: { redirect_uri: "r" } }]);
});

test("back from the back/forward cache: bye, then everything subscribed again", async () => {
  const workers = new FakeWorkers();
  const client = workers.client();
  client.subscribe({ topic: "session", station: "local", key: "k" }, () => undefined, () => undefined);
  const pending = client.call("station.file", {});
  client.suspend();
  client.resume();
  await assert.rejects(pending);
  assert.deepEqual(workers.last.sent.slice(2), [{ bye: true }, { id: 1, subscribe: { topic: "session", station: "local", key: "k" }, keyed: true }]);
});

test("a worker of the page's own ends as the page leaves, and a new one starts when it is back", async () => {
  const workers = new FakeWorkers();
  const client = new CoreClient(workers.opener, { schedule: (_ms, run) => run(), endWithPage: true });
  client.subscribe({ topic: "accounts" }, () => undefined, () => undefined);
  client.focus({ visible: true }).catch(() => undefined);
  const pending = client.call("auth.complete", { query: "?code=c" });
  client.suspend();
  const old = workers.last;
  assert.equal(old.closed, true, "not kept frozen with the page, holding the core's lock");
  assert.deepEqual(old.sent.at(-1), { bye: true });
  // Back from the cache: what the old one was asked is lost; a new one hears the subscriptions and where the page is.
  client.resume();
  await assert.rejects(pending);
  assert.equal(workers.opened.length, 2);
  assert.deepEqual(workers.last.sent, [
    { id: 1, subscribe: { topic: "accounts" }, keyed: true },
    { id: 4, call: "client.focus", params: { visible: true } },
  ]);
  // Shown again with no pageshow saying it came back: the same.
  client.suspend();
  client.wake(1000);
  assert.equal(workers.opened.length, 3);
  assert.deepEqual(workers.last.sent.slice(0, 2), [{ id: 1, subscribe: { topic: "accounts" }, keyed: true }, { id: 5, call: "client.focus", params: { visible: true } }]);
  assert.deepEqual(workers.last.sent.at(-1), { id: 6, call: "client.wake", params: { away: 1000 } });
});

test("back after being away: the core is told, and a worker that was up and now says nothing is replaced", () => {
  const workers = new FakeWorkers();
  const timers: [number, () => void][] = [];
  const client = new CoreClient(workers.opener, { schedule: (ms, run) => { if (ms === WAKE_ANSWER_MS) timers.push([ms, run]); else run(); } });
  client.subscribe({ topic: "accounts" }, () => undefined, () => undefined);
  // Not up yet (still starting): it is told, but not timed.
  client.wake(1234.4);
  assert.deepEqual(workers.last.sent.at(-1), { id: 2, call: "client.wake", params: { away: 1234 } });
  assert.equal(timers.length, 0);
  workers.last.reply({ id: 1, value: [] });
  // Up, and it answers: nothing happens.
  client.wake(60_000);
  workers.last.reply({ id: 3, ok: {} });
  timers.shift()![1]();
  assert.equal(workers.opened.length, 1);
  // Up, and silent: a new worker, with the subscriptions again.
  client.wake(60_000);
  const old = workers.last;
  timers.shift()![1]();
  assert.equal(old.closed, true);
  assert.deepEqual(old.sent.at(-1), { bye: true });
  assert.equal(workers.opened.length, 2);
  assert.deepEqual(workers.last.sent, [{ id: 1, subscribe: { topic: "accounts" }, keyed: true }]);
});

test("deltas apply to the subscription's value, copying only along their paths", () => {
  const workers = new FakeWorkers();
  const client = workers.client();
  const seen: unknown[] = [];
  client.subscribe({ topic: "session", station: "w/s", key: "k" }, (v) => seen.push(v), (e) => seen.push(e.code));
  const first = { detail: { timeline: [{ text: "a" }], usage: { n: 1 } }, link: { state: "offline", message: "断了" }, other: { x: 1 } };
  // Before any value there is nothing to apply a delta to.
  workers.last.reply({ id: 1, delta: [{ path: ["other"], set: 2 }] });
  workers.last.reply({ id: 1, value: first });
  workers.last.reply({ id: 1, delta: [
    { path: ["detail", "timeline"], append: [{ text: "b" }] },
    { path: ["detail", "usage", "n"], set: 2 },
    { path: ["link", "state"], set: "online" },
    { path: ["link", "message"], remove: true },
  ] });
  workers.last.reply({ id: 1, delta: [{ path: ["detail", "timeline", 1, "text"], set: "bc" }] });
  assert.equal(seen.length, 3);
  const second = seen[1] as typeof first;
  const third = seen[2] as typeof first;
  assert.deepEqual(second, { detail: { timeline: [{ text: "a" }, { text: "b" }], usage: { n: 2 } }, link: { state: "online" }, other: { x: 1 } });
  assert.deepEqual(first.detail.timeline, [{ text: "a" }], "the old value is left as it was");
  assert.equal(second.other, first.other);
  assert.equal(second.detail.timeline[0], first.detail.timeline[0]);
  assert.deepEqual(third.detail.timeline[1], { text: "bc" });
  assert.equal(third.detail.timeline[0], first.detail.timeline[0]);
  assert.equal(third.link, second.link);
  // After an error, deltas wait for a whole value again.
  workers.last.reply({ id: 1, error: { code: "offline", message: "离线" } });
  workers.last.reply({ id: 1, delta: [{ path: ["other"], set: 3 }] });
  workers.last.reply({ id: 1, value: { fresh: true } });
  assert.deepEqual(seen.slice(3), ["offline", { fresh: true }]);
});

test("pre-handshake protected calls queue and get signed on handshake snapshot; aborted queued calls are never sent", async () => {
  const workers = new FakeWorkers({ autoHandshake: false });
  const client = workers.client();
  const ac = new AbortController();
  const keptCall = client.call("station.request", { station: "ws1/s1", method: "POST", path: "/x" });
  const abortedCall = client.call("vault.open", { workspace: "ws1", vault: "v1", item: "i1" }, undefined, ac.signal);
  // Nothing sent before handshake for protected calls.
  assert.deepEqual(workers.last.sent, []);
  ac.abort();
  await assert.rejects(abortedCall, (e: unknown) => e instanceof CoreError && e.code === "cancelled");
  // Aborting a queued call never posts `{ cancel: true }`.
  assert.deepEqual(workers.last.sent, []);
  workers.last.handshake({ conn: 7, global: 2, scopes: { ws1: 4 }, vaultGlobal: 1, vaults: { "ws1/v1": 3 } });
  assert.deepEqual(workers.last.sent, [
    { id: 1, call: "station.request", params: { station: "ws1/s1", method: "POST", path: "/x" }, auth: { conn: 7, authGen: 4, workspace: "ws1" } },
  ]);
  workers.last.replyRaw({ id: 1, conn: 7, authGen: 4, ok: { done: true } });
  assert.deepEqual(await keptCall, { done: true });
});

test("reconnect / bfcache recovery rejects old-page protected writes as auth_stale while allowing auth.complete", async () => {
  const workers = new FakeWorkers({ autoHandshake: false });
  const client = new CoreClient(workers.opener, { schedule: (_ms, run) => run(), endWithPage: true });
  workers.last.handshake({ conn: 1, global: 1 });
  client.suspend();
  client.resume();
  assert.equal(workers.opened.length, 2);
  // auth.complete goes out immediately even before the new worker's handshake.
  const complete = client.call("auth.complete", { query: "?code=ok" });
  // Protected write from the old page during reconnect window (`everHandshaked && authConn === 0`) is rejected immediately.
  const staleAfterResume = client.call("station.request", { station: "ws1/s1", method: "POST", path: "/p" });
  await assert.rejects(staleAfterResume, (e: unknown) => e instanceof CoreError && e.code === "auth_stale");
  assert.deepEqual(workers.last.sent, [{ id: 1, call: "auth.complete", params: { query: "?code=ok" } }]);
  workers.last.replyRaw({ id: 1, ok: { signedIn: true } });
  assert.deepEqual(await complete, { signedIn: true });
  // After new handshake arrives, fresh calls succeed with new conn/gen.
  workers.last.handshake({ conn: 2, global: 3, scopes: { ws1: 3 } });
  const freshAfterHandshake = client.call("station.request", { station: "ws1/s1", method: "GET", path: "/p" });
  assert.deepEqual(workers.last.sent.at(-1), {
    id: 3,
    call: "station.request",
    params: { station: "ws1/s1", method: "GET", path: "/p" },
    auth: { conn: 2, authGen: 3, workspace: "ws1" },
  });
  workers.last.replyRaw({ id: 3, conn: 2, authGen: 3, ok: { ok: 1 } });
  assert.deepEqual(await freshAfterHandshake, { ok: 1 });
});

test("device-global topics, self-triggered write ok, missing-gen sensitive read, monotonic same-conn snapshot, and boundary onWaiting", async () => {
  const workers = new FakeWorkers({ autoHandshake: false });
  const client = workers.client();
  const linkSeen: unknown[] = [];
  const wsSeen: unknown[] = [];
  let wsWaiting = 0;
  client.subscribe({ topic: "link", station: "ws1/s1" }, (v) => linkSeen.push(v), () => undefined);
  client.subscribe({ topic: "overview", station: "ws1/s1" }, (v) => wsSeen.push(v), () => undefined, () => { wsWaiting++; });
  // Before handshake, non-device-global subscription values are rejected, while device-global link is accepted.
  workers.last.replyRaw({ id: 2, value: { stale: "pre-handshake" } });
  assert.deepEqual(wsSeen, []);
  workers.last.replyRaw({ id: 1, value: { state: "online" } });
  assert.deepEqual(linkSeen, [{ state: "online" }]);

  workers.last.handshake({ conn: 5, global: 4, aggregate: 4, scopes: { ws1: 4 }, vaultGlobal: 2, vaults: { "ws1/v1": 2 } });
  const prefsSeen: unknown[] = [];
  client.subscribe({ topic: "prefs" }, (v) => prefsSeen.push(v), () => undefined);
  // Device-global prefs & link with authGen: 0 are accepted even though global is 4.
  workers.last.replyRaw({ id: 3, conn: 5, authGen: 0, value: { lang: "zh" } });
  workers.last.replyRaw({ id: 1, conn: 5, authGen: 0, value: { state: "ready" } });
  assert.deepEqual(prefsSeen, [{ lang: "zh" }]);
  assert.deepEqual(linkSeen, [{ state: "online" }, { state: "ready" }]);
  // Missing conn or missing/stale authGen for non-device topic is dropped.
  workers.last.replyRaw({ id: 2, value: { stale: "no-conn" } });
  workers.last.replyRaw({ id: 2, conn: 5, value: { stale: "no-gen" } });
  workers.last.replyRaw({ id: 2, conn: 5, authGen: 3, value: { stale: "old-gen" } });
  assert.deepEqual(wsSeen, []);
  workers.last.replyRaw({ id: 2, conn: 5, authGen: 4, value: { fresh: 4 } });
  assert.deepEqual(wsSeen, [{ fresh: 4 }]);
  // Same-conn full snapshot must never lower watermarks.
  workers.last.handshake({ conn: 5, global: 1, aggregate: 1, scopes: { ws1: 1 }, vaultGlobal: 1, vaults: { "ws1/v1": 1 } });
  workers.last.replyRaw({ id: 2, conn: 5, authGen: 3, value: { stale: "regressed" } });
  assert.deepEqual(wsSeen, [{ fresh: 4 }]);
  // Workspace boundary clears sub.value, notifies onWaiting, and re-subscribes.
  workers.last.replyRaw({ id: 0, auth: { conn: 5, global: 4, aggregate: 5, workspace: "ws1", authGen: 5 } });
  assert.equal(wsWaiting, 1);
  assert.deepEqual(workers.last.sent.at(-1), { id: 2, subscribe: { topic: "overview", station: "ws1/s1" }, keyed: true });
  // Ordinary committed write (`auth.signOut`) succeeds even after self-triggered global boundary!
  const signOut = client.call("auth.signOut", { account: "a" });
  workers.last.replyRaw({ id: 0, auth: { conn: 5, global: 6, aggregate: 6 } });
  workers.last.replyRaw({ id: 4, conn: 5, authGen: 4, ok: { signedOut: true } });
  assert.deepEqual(await signOut, { signedOut: true });
  // Sensitive read (`vault.open`) missing authGen/vaultGen is rejected as auth_stale.
  const openMissingGen = client.call("vault.open", { workspace: "ws1", vault: "v1", item: "i1" });
  workers.last.replyRaw({ id: 5, conn: 5, ok: { plain: { secret: "x" } } });
  await assert.rejects(openMissingGen, (e: unknown) => e instanceof CoreError && e.code === "auth_stale");
  // Stale stream progress rejects immediately with auth_stale (never hangs or delivers stale data).
  const progressSeen: unknown[] = [];
  const pCall = client.call("station.file", { station: "ws1/s1" }, (v) => progressSeen.push(v));
  workers.last.replyRaw({ id: 6, conn: 5, authGen: 4, value: { bytes: 10 } });
  await assert.rejects(pCall, (e: unknown) => e instanceof CoreError && e.code === "auth_stale");
  assert.deepEqual(progressSeen, []);
  // Credential-returning `workspace.createProvisionKey` is protected: rejects on boundary instead of delivering key.
  const provKey = client.call("workspace.createProvisionKey", { workspace: "ws1", name: "n" });
  workers.last.replyRaw({ id: 0, auth: { conn: 5, global: 6, aggregate: 7, workspace: "ws1", authGen: 7 } });
  workers.last.replyRaw({ id: 7, conn: 5, authGen: 6, ok: { key: "secret-prov" } });
  await assert.rejects(provKey, (e: unknown) => e instanceof CoreError && e.code === "auth_stale");
  // Same-conn full snapshot advancing watermark clears affected non-device subscribers (`onWaiting`).
  workers.last.replyRaw({ id: 2, conn: 5, authGen: 7, value: { fresh: 7 } });
  const waitingBeforeSnap = wsWaiting;
  workers.last.handshake({ conn: 5, global: 6, aggregate: 8, scopes: { ws1: 8 }, vaultGlobal: 2, vaults: { "ws1/v1": 2 } });
  assert.equal(wsWaiting, waitingBeforeSnap + 1);
  // Out-of-order `dependentVaultGens` advances dependent workspace even when `authGen` is not greater than prev.
  let vaultsBWaiting = 0;
  client.subscribe({ topic: "vaults", workspace: "wsB" }, () => undefined, () => undefined, () => { vaultsBWaiting++; });
  workers.last.replyRaw({ id: 8, conn: 5, authGen: 6, vaultGen: 2, value: { vaults: [] } });
  workers.last.replyRaw({ id: 0, auth: { conn: 5, global: 6, aggregate: 8, workspace: "ws1", authGen: 8, dependentVaultGens: { wsB: 5 } } });
  assert.equal(vaultsBWaiting, 1);
  // `#restart()` clears non-device subscribers and ignores incremental boundaries until full snapshot arrives!
  workers.last.replyRaw({ id: 2, conn: 5, authGen: 8, value: { fresh: 8 } });
  const waitingBeforeRestart = wsWaiting;
  workers.last.fail("crash");
  assert.equal(wsWaiting, waitingBeforeRestart + 1);
  // Incremental boundary while `#authConn === 0` must NOT lift reconnect write gate.
  workers.last.replyRaw({ id: 0, auth: { conn: 6, global: 9, aggregate: 9 } });
  const blockedDuringReconnect = client.call("station.request", { station: "ws1/s1", method: "POST", path: "/x" });
  await assert.rejects(blockedDuringReconnect, (e: unknown) => e instanceof CoreError && e.code === "auth_stale");

  // Full snapshot lifts gate; test workspace.enroll boundary rejection + rejoin/resume consumer clear & `#authConn = 0`.
  workers.last.replyRaw({ id: 0, auth: { conn: 6, global: 9, aggregate: 9, scopes: { ws1: 9 }, vaultGlobal: 1, vaults: {} } });
  const enrollCall = client.call("workspace.enroll", { workspace: "ws1" });
  const enrollReq = (workers.last.sent as { id?: number; call?: string }[]).findLast((m) => m.call === "workspace.enroll");
  assert.ok(enrollReq?.id !== undefined);
  workers.last.replyRaw({ id: 0, auth: { conn: 6, global: 9, aggregate: 10, workspace: "ws1", authGen: 10 } });
  workers.last.replyRaw({ id: enrollReq.id, ok: { token: "stale-enroll" }, conn: 6, authGen: 9 });
  await assert.rejects(enrollCall, (e: unknown) => e instanceof CoreError && e.code === "auth_stale");

  // Rejoin clears non-device-global subscribers and resets `#authConn = 0` until a new full handshake snapshot arrives.
  const wsSub = (workers.last.sent as { id?: number; subscribe?: { topic?: string } }[]).findLast((m) => m.subscribe?.topic === "overview");
  assert.ok(wsSub?.id !== undefined);
  workers.last.replyRaw({ id: wsSub.id, value: [{ id: "live-row" }], conn: 6, authGen: 10 });
  const waitingBeforeRejoin = wsWaiting;
  workers.last.replyRaw({ rejoin: true });
  assert.equal(wsWaiting, waitingBeforeRejoin + 1, "rejoin must clear non-device-global subscriber and notify onWaiting");
  const blockedAfterRejoin = client.call("station.request", { station: "ws1/s1", method: "POST", path: "/x" });
  await assert.rejects(blockedAfterRejoin, (e: unknown) => e instanceof CoreError && e.code === "auth_stale");

  // Retired conn=6 snapshot and values must be rejected while awaiting a strictly newer conn (> 6).
  const seenBeforeStale = wsSeen.length;
  workers.last.replyRaw({ id: 0, auth: { conn: 6, global: 10, aggregate: 10, scopes: { ws1: 10 }, vaultGlobal: 1, vaults: {} } });
  workers.last.replyRaw({ id: wsSub.id, value: { stale: "conn-6-after-rejoin" }, conn: 6, authGen: 10 });
  assert.equal(wsSeen.length, seenBeforeStale, "retired conn=6 value must be ignored after rejoin");
  const stillBlocked = client.call("station.request", { station: "ws1/s1", method: "POST", path: "/x" });
  await assert.rejects(stillBlocked, (e: unknown) => e instanceof CoreError && e.code === "auth_stale");

  // Strictly newer conn=7 full snapshot restores connection and accepts values/writes.
  workers.last.replyRaw({ id: 0, auth: { conn: 7, global: 10, aggregate: 10, scopes: { ws1: 10 }, vaultGlobal: 1, vaults: {} } });
  const wsSubAfter = (workers.last.sent as { id?: number; subscribe?: { topic?: string } }[]).findLast((m) => m.subscribe?.topic === "overview");
  assert.ok(wsSubAfter?.id !== undefined);
  workers.last.replyRaw({ id: wsSubAfter.id, value: { fresh: "conn-7" }, conn: 7, authGen: 10 });
  assert.deepEqual(wsSeen.at(-1), { fresh: "conn-7" });
  const recoveredWrite = client.call("station.request", { station: "ws1/s1", method: "POST", path: "/ok" });
  const recoveredReq = (workers.last.sent as { id?: number; call?: string; auth?: { conn?: number } }[]).findLast((m) => m.call === "station.request");
  assert.equal(recoveredReq?.auth?.conn, 7);
  workers.last.replyRaw({ id: recoveredReq!.id, ok: { done: true }, conn: 7, authGen: 10 });
  assert.deepEqual(await recoveredWrite, { done: true });
});
