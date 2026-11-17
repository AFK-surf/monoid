import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { Duplex } from "node:stream";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, watch } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Clock, Effect, Exit, Fiber, Scope, Stream, SubscriptionRef } from "effect";
import { TestClock } from "effect/testing";
import { Cloud, writeState } from "../src/cloud/state.ts";
import { StationKey } from "../src/cloud/key.ts";
import { presence } from "../src/cloud/presence.ts";
import { STILLFAIL } from "../src/cloud/provider.ts";
import WebSocket from "ws";
import { CLOUD_ORIGIN, CloudTransport, cloudEntry, dialCloud, type DialIO } from "../src/cloud/transport.ts";
const entry = { origin: CLOUD_ORIGIN, host: "entry.test", port: 24443 };
class TLS extends Duplex {
  encrypted = true;
  alpnProtocol = "http/1.1";
  writes = "";
  written?: (bytes: string) => void;
  _read() {}
  _write(chunk: Buffer, _encoding: string, done: () => void) { this.writes += chunk.toString(); this.written?.(this.writes); done(); }
  setNoDelay() { return this; }
  setKeepAlive() { return this; }
  setTimeout() { return this; }
  ref() { return this; }
  unref() { return this; }
}
function rig() {
  let now = 0;
  const waits = new Set<{ at: number; f: () => void }>();
  const attempts: { host: string; port: number; servername: string; socket: TLS }[] = [];
  const told = new EventEmitter();
  const io: DialIO = {
    after: (ms, f) => { const w = { at: now + ms, f }; waits.add(w); return () => void waits.delete(w); },
    tls: (host, port, servername) => { const socket = new TLS(); attempts.push({ host, port, servername, socket }); told.emit("dial", socket); return socket; },
  };
  return { io, attempts, waits, async dial(index = 0): Promise<TLS> { while (!attempts[index]) await once(told, "dial"); return attempts[index].socket; }, advance(ms: number) { now += ms; for (const w of [...waits]) if (w.at <= now && waits.delete(w)) w.f(); } };
}
test("fast direct TLS keeps canonical identity and never starts an entry", () => {
  const r = rig(); let result: unknown;
  dialCloud(r.io, CLOUD_ORIGIN, entry, 10_000, (e, socket) => { assert.equal(e, null); result = socket; });
  r.attempts[0]!.socket.emit("secureConnect"); r.advance(20_000);
  assert.equal(r.attempts.length, 1); assert.equal(r.attempts[0]!.servername, "app.still.fail");
  assert.equal(result, r.attempts[0]!.socket); assert.equal(r.waits.size, 0);
});
test("delayed hedge accepts one TLS socket, destroys losers and late successes", () => {
  const r = rig(); const results: unknown[] = [];
  dialCloud(r.io, CLOUD_ORIGIN, entry, 10_000, (e, socket) => results.push(e ?? socket));
  r.advance(999); assert.equal(r.attempts.length, 1); r.advance(1); assert.equal(r.attempts.length, 2);
  assert.deepEqual([r.attempts[1]!.host, r.attempts[1]!.port, r.attempts[1]!.servername], [entry.host, entry.port, "app.still.fail"]);
  r.attempts[1]!.socket.emit("secureConnect"); assert(r.attempts[0]!.socket.destroyed);
  r.attempts[0]!.socket.emit("secureConnect"); assert.deepEqual(results, [r.attempts[1]!.socket]); assert.equal(r.waits.size, 0);
});
test("early direct failure starts entry once; blackholes share one deadline", () => {
  const r = rig(); const results: unknown[] = [];
  dialCloud(r.io, CLOUD_ORIGIN, entry, 10_000, (e) => results.push(e));
  r.attempts[0]!.socket.emit("error", new Error("direct refused")); assert.equal(r.attempts.length, 2);
  r.advance(1000); assert.equal(r.attempts.length, 2); r.advance(9000);
  assert.match((results[0] as Error).message, /timed out/); assert.equal(results.length, 1); assert(r.attempts.every((a) => a.socket.destroyed));
});
test("certificate rejection never hands a candidate to HTTP", () => {
  const r = rig(); const results: unknown[] = [];
  dialCloud(r.io, CLOUD_ORIGIN, entry, 10_000, (e, socket) => results.push(e ?? socket));
  r.attempts[0]!.socket.emit("error", Object.assign(new Error("hostname mismatch"), { code: "ERR_TLS_CERT_ALTNAME_INVALID" }));
  r.attempts[1]!.socket.emit("error", new Error("entry refused"));
  assert(results[0] instanceof AggregateError); assert.equal(results.length, 1); assert(r.attempts.every((a) => a.socket.destroyed));
});
test("cancel and owner shutdown destroy pending candidates and reject new dials", async () => {
  const r = rig(); const owner = new CloudTransport(() => entry, undefined, r.io); const errors: Error[] = [];
  const cancel = owner.dial(10_000, (e) => { if (e) errors.push(e); });
  r.advance(1000); cancel(); cancel(); assert.equal(errors.length, 1); assert(r.attempts.every((a) => a.socket.destroyed));
  owner.dial(10_000, (e) => { if (e) errors.push(e); }); await owner.close();
  owner.dial(10_000, (e) => { if (e) errors.push(e); }); assert.equal(errors.length, 3);
  assert(r.attempts.every((a) => a.socket.destroyed)); assert.equal(r.waits.size, 0);
  await assert.rejects(owner.fetch(`${CLOUD_ORIGIN}/x`), /closed/);
});
test("origin and provider scope exclude Comma and third parties", async () => {
  const owner = new CloudTransport(() => entry);
  assert(owner.eligible(`${CLOUD_ORIGIN}/x`)); assert(!owner.eligible(`${CLOUD_ORIGIN}/x`, "comma"));
  assert(!owner.eligible("https://other.test/x")); assert(!owner.eligible("https://app.still.fail:444/x"));
  assert.equal(cloudEntry({}), null); assert.throws(() => cloudEntry({ cloudEntry: { ...entry, origin: "https://other.test" } })); await owner.close();
});
// Undici and ws speak their real HTTP protocols on a scripted Duplex; no sockets or native addons.
test("HTTP pool survives request A abort and serves B with canonical Host", async () => {
  const r = rig(); const owner = new CloudTransport(() => entry, undefined, r.io);
  try {
    const abort = new AbortController(); const a = owner.fetch(`${CLOUD_ORIGIN}/a`, { signal: abort.signal }); const failed = assert.rejects(a, { name: "AbortError" });
    const b = owner.fetch(`${CLOUD_ORIGIN}/b`);
    const first = await r.dial();
    abort.abort(); await failed; assert(!first.destroyed);
    first.emit("secureConnect");
    assert.equal(first.writes, "");
    const socket = await r.dial(1);
    const written = once(socket, "request"); socket.written = (bytes) => { if (bytes.includes("\r\n\r\n")) socket.emit("request"); };
    socket.emit("secureConnect"); await written;
    assert.match(socket.writes, /GET \/b HTTP\/1.1/); assert.doesNotMatch(socket.writes, /GET \/a HTTP\/1.1/); assert.match(socket.writes, /host: app\.still\.fail/i);
    socket.push("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"); assert.equal(await (await b).text(), "ok");
  } finally { await owner.close(); }
});
test("HTTP status errors and post-write failures are never replayed through an entry", async () => {
  for (const status of [401, 403, 429, 503, null]) {
    const r = rig(); const owner = new CloudTransport(() => entry, undefined, r.io);
    try {
      const response = owner.fetch(`${CLOUD_ORIGIN}/post`, { method: "POST", body: "signed-body" });
      const settled = response.then(async (r) => { await r.text(); return r.status; }, (e) => e);
      const socket = await r.dial(); const written = once(socket, "request"); socket.written = (bytes) => { if (bytes.includes("signed-body")) socket.emit("request"); };
      socket.emit("secureConnect"); await written; r.advance(1000);
      if (status === null) socket.destroy(new Error("lost after write")); else socket.push(`HTTP/1.1 ${status} Error\r\nContent-Length: 0\r\n\r\n`);
      const result = await settled; if (status === null) assert(result instanceof Error); else assert.equal(result, status); assert.equal(r.attempts.length, 1);
    } finally { await owner.close(); }
  }
});
test("presence Upgrade preserves signed headers and canonical Host", async () => {
  const r = rig(); const owner = new CloudTransport(() => entry, undefined, r.io);
  const socket = owner.websocket("wss://app.still.fail/v1/stations/connect", { "x-stillfail-signature": "proof", "x-stillfail-station": "station" }, WebSocket); socket.on("error", () => {});
  try {
    const tls = await r.dial(); const opened = once(socket, "open");
    tls.written = (bytes) => {
      if (!bytes.includes("\r\n\r\n")) return;
      assert.match(bytes, /Host: app\.still\.fail/i); assert.match(bytes, /x-stillfail-signature: proof/i); assert.match(bytes, /x-stillfail-station: station/i);
      const key = /Sec-WebSocket-Key: (.+)\r\n/i.exec(bytes)![1]!; const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      tls.push(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    };
    tls.emit("secureConnect"); await opened; assert.equal(socket.readyState, WebSocket.OPEN);
  } finally { socket.terminate(); await owner.close(); }
});
test("presence deadline covers both TLS blackholes and a stalled Upgrade", async () => {
  for (const connected of [false, true]) {
    const r = rig(); const owner = new CloudTransport(() => entry, undefined, r.io);
    const socket = owner.websocket("wss://app.still.fail/v1/stations/connect", {}, WebSocket);
    const closed = new Promise<void>((resolve) => socket.once("close", () => resolve()));
    socket.on("error", () => {});
    const tls = await r.dial();
    if (connected) tls.emit("secureConnect");
    r.advance(20_000); await closed;
    assert(r.attempts.every((a) => a.socket.destroyed)); assert.equal(r.waits.size, 0);
    await owner.close();
  }
});
test("presence cancellation closes pending TLS before WebSocket termination", async () => {
  const r = rig(); const owner = new CloudTransport(() => entry, undefined, r.io);
  const socket = owner.websocket("wss://app.still.fail/v1/stations/connect", {}, WebSocket);
  const closed = new Promise<void>((resolve) => socket.once("close", () => resolve())); socket.on("error", () => {});
  await r.dial(); r.advance(1000); socket.terminate();
  assert(r.attempts.every((a) => a.socket.destroyed)); await closed;
  assert.equal(r.waits.size, 0); await owner.close();
});

test("HTTP pool shutdown cancels an in-flight connector before Agent destruction", async () => {
  const r = rig(); const owner = new CloudTransport(() => entry, undefined, r.io);
  const response = owner.fetch(`${CLOUD_ORIGIN}/pending`);
  const failed = assert.rejects(response, /fetch failed/);
  await r.dial(); r.advance(1000);
  await owner.close(); await failed;
  assert(r.attempts.every((a) => a.socket.destroyed)); assert.equal(r.waits.size, 0);
});


test("public presence reports an invalid entry and connects after its config is corrected", async (t) => {
  const data = mkdtempSync(join(tmpdir(), "presence-config-"));
  // Main writes status asynchronously and atomically. Observe the published file instead of elapsed wall time.
  mkdirSync(join(data, "run"), { recursive: true });
  const statusWatch = watch(join(data, "run"), { persistent: false });
  const status = () => JSON.parse(readFileSync(join(data, "run", "presence.json"), "utf8"));
  const statusWritten = (online: boolean) => new Promise<void>((resolve, reject) => {
    const changed = () => {
      try {
        if (status().online !== online) return;
        statusWatch.off("change", changed);
        resolve();
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") reject(error);
      }
    };
    statusWatch.on("change", changed);
    changed();
  });
  const offlineWritten = statusWritten(false);
  const scope = Effect.runSync(Scope.make());
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  let sleeping!: () => void;
  const asleep = new Promise<void>((resolve) => { sleeping = resolve; });
  const observedClock: Clock.Clock = {
    ...clock,
    sleep: (duration) => Effect.suspend(() => { sleeping(); return clock.sleep(duration); }),
  };
  let raw = { cloudEntry: { ...entry, port: 0 } };
  const key = new StationKey(Buffer.alloc(32, 7));
  writeState(data, {
    origin: CLOUD_ORIGIN, station: key.id, workspace: "workspace", workspace_name: "Team", name: "station",
    relay_url: "", relay_urls: [], grant_keys: { keys: [] }, peers: [], revocations: [],
  });
  const state = new Cloud(data, false, observedClock, () => cloudEntry(raw));
  const r = rig();
  const wire = new CloudTransport(() => cloudEntry(raw), observedClock, r.io);
  let opened!: () => void;
  const online = new Promise<void>((resolve) => { opened = resolve; });
  const websocket = t.mock.method(state.transport, "websocket", (...args: Parameters<CloudTransport["websocket"]>) => {
    const socket = wire.websocket(...args);
    socket.once("open", opened);
    return socket;
  });
  const up = Effect.runSync(SubscriptionRef.make(true));
  const running = Effect.runFork(presence({ cloud: { state, changes: Stream.never }, key, up, spec: () => STILLFAIL })
    .pipe(Effect.provideService(Clock.Clock, observedClock)));
  try {
    const next = await Promise.race([
      asleep.then(() => "retry"),
      Effect.runPromise(Fiber.await(running)).then(() => "exited"),
    ]);
    assert.equal(next, "retry", "invalid configuration must stay in the public presence retry loop");
    await offlineWritten;
    assert.equal(status().online, false);
    assert.match(status().error, /cloudEntry.*TCP port.*correct config.json/);
    assert.equal(websocket.mock.callCount(), 0, "invalid configuration must not silently use a direct socket");
    assert.equal(running.pollUnsafe(), undefined);

    raw = { cloudEntry: entry };
    await Effect.runPromise(clock.adjust("1000 millis"));
    const tls = await r.dial();
    tls.written = (bytes) => {
      if (!bytes.includes("\r\n\r\n")) return;
      assert.match(bytes, /x-stillfail-station: /i);
      const nonce = /Sec-WebSocket-Key: (.+)\r\n/i.exec(bytes)![1]!;
      const accept = createHash("sha1").update(nonce + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      tls.push(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    };
    const onlineWritten = statusWritten(true);
    tls.emit("secureConnect");
    await online;
    await onlineWritten;
    assert.equal(websocket.mock.callCount(), 1);
    assert.equal(status().online, true);
    assert.equal(status().error, null);
    assert.equal(running.pollUnsafe(), undefined, "presence keeps the recovered connection alive");
  } finally {
    await Effect.runPromise(Fiber.interrupt(running));
    await wire.close();
    await state.close();
    await Effect.runPromise(Scope.close(scope, Exit.void));
    statusWatch.close();
    rmSync(data, { recursive: true, force: true });
  }
});
