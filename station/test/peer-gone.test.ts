// A connection kept to a station whose endpoint is gone (killed, or started again with another): its requests are not
// left to wait ANSWER_MS for an answer that cannot come. Asked on it after CHECK_MS with nothing heard, it is found gone
// and dropped, the request failed with PeerGone; a station that connects here again has what was kept to it asked the
// same. A live one that is slow (a relay's round trip of over a second) is kept, and costs one ask at most. Here the
// answer is waited for a minute: what fails, fails by the check, and is taken with given() (there by the time all set
// going is done, or the test fails saying so).
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { Cloud } from "../src/cloud/state.ts";
import { PEER_ALPN, PEER_BYTES_ALPN, PeerGone, PeerStopped, STOPPING, peerCall, servePeer } from "../src/mesh/peer.ts";
import type { Connection, Endpoint } from "../src/mesh/native.ts";
import { type Bytes, withBytes } from "../src/mesh/bus.ts";
import { given, settle } from "./hub-fakes.ts";
import { memoryMesh, vanish } from "./memory-mesh.ts";

const cloudOf = (station: string, peers: string[]): any =>
  Object.assign(Object.create(Cloud.prototype), {
    state: { workspace: "ws", workspace_name: "ws", name: "", station, peers: peers.map((id) => ({ id })), revocations: [], joined: [] },
    lock: null,
    peersCurrent: true,
    relays: () => [],
  });

/// A promise and what settles it.
function held<T = void>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

/// A station answering what it is asked with `handle`, its connections in the list given back as they come.
function serving(endpoint: Endpoint, peers: string[], handle: (request: any) => Promise<any>) {
  const conns: Connection[] = [];
  const remote: any = { handle: (_ws: string, _peer: string, request: any) => handle(request) };
  void (async () => {
    for (;;) {
      const conn = await endpoint.accept();
      if (!conn) return;
      conns.push(conn);
      void servePeer(conn, cloudOf(endpoint.id(), peers), remote).catch(() => {});
    }
  })();
  return conns;
}

const settled = <T>(p: Promise<T>) => p.then((v) => ({ v }), (e: Error) => ({ e }));

/// Two stations; `again` binds the target's key anew (its station started again).
async function pair(options: Parameters<typeof memoryMesh>[0] = {}) {
  const mesh = memoryMesh(options);
  const secret = randomBytes(32);
  const bind = (key = randomBytes(32)) => mesh.bind({ secretKey: key, alpns: [PEER_BYTES_ALPN, PEER_ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [source, target] = await Promise.all([bind(), bind(secret)]);
  return { source, target, again: () => bind(secret) };
}

/// A killed station's: what it was asked is never answered (its process is gone).
const killedAfter = (dead: { now: boolean }) => async (r: any) => (dead.now ? new Promise(() => {}) : { ok: r.method });

test("a request on a connection whose other end is gone fails as that, by the check, not by the answer's timeout; the next dials anew", async () => {
  const { source, target, again } = await pair();
  const dead = { now: false };
  serving(target, [source.id()], killedAfter(dead));
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 0, heardMs: 100 });
  try {
    assert.deepEqual(await call(target.id(), "ws", { method: "first" }), { ok: "first" });
    // Its station killed (its endpoint gone without a word), and started again with the same key.
    dead.now = true;
    vanish(target);
    const back = await again();
    serving(back, [source.id()], async (r) => ({ ok: r.method }));
    const failed = await given(settled(call(target.id(), "ws", { method: "lost" })), "the request failed by the check");
    assert.ok("e" in failed && failed.e instanceof PeerGone, `failed as gone: ${"e" in failed ? failed.e.message : "answered"}`);
    assert.ok(!(failed.e instanceof PeerStopped), "killed, it said nothing: not a process stopping");
    assert.match(failed.e.message, /connection was gone/);
    assert.deepEqual(await given(call(target.id(), "ws", { method: "again" }), "answered on a new connection"), { ok: "again" });
  } finally { await Promise.all([source.close(), target.close()]); }
});

test("a request whose bytes a station killed stops taking fails as gone at once: not after its stream's reset, which waits behind the write flow control holds, nor its connection's close; the next dials anew", async () => {
  // (each stream's window 64 KiB, its reset held behind a write waiting for room, as the shell's: drill 3a, 2026-11-16,
  // where a move's pack of a chat's room held the turn till the station killed came back)
  const { source, target, again } = await pair({ window: 64 * 1024, held: true });
  const dead = { now: false };
  serving(target, [source.id()], killedAfter(dead));
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 60_000, heardMs: 50, idleMs: 0 });
  // (a megabyte, more than the window: what a station that takes none of it leaves waiting)
  async function* megabyte(): Bytes {
    for (let i = 0; i < 16; i++) yield Buffer.alloc(64 * 1024, i);
  }
  try {
    assert.deepEqual(await call(target.id(), "ws", { method: "first" }), { ok: "first" });
    dead.now = true;
    vanish(target);
    const back = await again();
    serving(back, [source.id()], async (r) => ({ ok: r.method }));
    const failed = await given(settled(call(target.id(), "ws", withBytes({ method: "lost" }, megabyte()))), "the request failed as its bytes were not taken");
    assert.ok("e" in failed && failed.e instanceof PeerGone, `failed as gone: ${"e" in failed ? failed.e.message : "answered"}`);
    assert.deepEqual(await given(call(target.id(), "ws", withBytes({ method: "again" }, megabyte())), "answered on a new connection"), { ok: "again" });
  } finally { await Promise.all([source.close(), target.close()]); }
});

test("a station connecting again has the connection kept to it from before asked: gone, it is dropped, what waited on it failed at once", async () => {
  const { source, target, again } = await pair();
  const dead = { now: false };
  serving(target, [source.id()], killedAfter(dead));
  // (no check of its own in this test: only the station's coming again finds it)
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 60_000 });
  void (async () => { for (;;) { const c = await source.accept(); if (!c) return; call.arrived(c); } })();
  try {
    assert.deepEqual(await call(target.id(), "ws", { method: "first" }), { ok: "first" });
    dead.now = true;
    vanish(target);
    const waiting = settled(call(target.id(), "ws", { method: "lost" }));
    const back = await again();
    serving(back, [source.id()], async (r) => ({ ok: r.method }));
    // It asks this station something: its connection here arrives.
    await back.connect({ id: source.id() }, PEER_BYTES_ALPN, [PEER_ALPN]);
    const failed = await given(waiting, "what waited on the kept connection failed");
    assert.ok("e" in failed && failed.e instanceof PeerGone, `failed as gone: ${"e" in failed ? failed.e.message : "answered"}`);
    assert.deepEqual(await given(call(target.id(), "ws", { method: "again" }), "answered on a new connection"), { ok: "again" });
  } finally { await Promise.all([source.close(), target.close()]); }
});

test("a live station's connection over a slow relay is kept: one ask while requests wait, none once something is heard", async () => {
  const { source, target } = await pair();
  const slow = held();
  const heardReached = held();
  const heardGo = held();
  type Kept = { answering: ((ms: number) => Promise<boolean>) | null; asked: number; received: number };
  let kept!: Kept;
  const conns = serving(target, [source.id()], async (r) => {
    if (r.method === "heard") {
      // (a packet back from it, as an ACK of the request: heard since it went)
      kept.received += 1;
      heardReached.resolve();
      await heardGo.promise;
    } else if (r.method !== "quick") await slow.promise;
    return { ok: r.method };
  });
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 0, heardMs: 3_000 });
  try {
    assert.deepEqual(await call(target.id(), "ws", { method: "quick" }), { ok: "quick" });
    // This station's end of the connection (the other end's peer): its relay's round trip held by the test.
    kept = (conns[0] as any).peer as Kept;
    const relay = held<boolean>();
    const askedOnce = held<number>();
    kept.asked = 0;
    kept.answering = (ms) => (askedOnce.resolve(ms), relay.promise);
    const waiting = [call(target.id(), "ws", { method: "slow-1" }), call(target.id(), "ws", { method: "slow-2" })];
    assert.equal(await given(askedOnce.promise, "its connection asked whether it is there"), 3_000, "given HEARD_MS to answer in");
    await settle();
    assert.equal(kept.asked, 1, "one ask however many wait");
    // Its answer back over the relay, within HEARD_MS: there.
    relay.resolve(true);
    slow.resolve();
    assert.deepEqual(await given(Promise.all(waiting), "both answered"), [{ ok: "slow-1" }, { ok: "slow-2" }]);
    assert.equal(conns.length, 1, "the connection kept");
    // Something heard on it since the request went: not asked at all.
    kept.asked = 0;
    kept.answering = () => new Promise<boolean>(() => {});
    const heard = call(target.id(), "ws", { method: "heard" });
    await given(heardReached.promise, "the request reached it");
    await settle();
    assert.equal(kept.asked, 0, "nothing asked of a connection heard from");
    heardGo.resolve();
    assert.deepEqual(await given(heard, "answered"), { ok: "heard" });
  } finally { slow.resolve(); heardGo.resolve(); await Promise.all([source.close(), target.close()]); }
});

test("a request in flight as the other station's process hands over to its next (its connections closed STOPPING, no answer) fails at once as that, the connection let go; the next request is answered by the next process", async () => {
  const { source, target, again } = await pair();
  const reached = held();
  // (the process that hands over: what it was asked it never answers, it stops first)
  const conns = serving(target, [source.id()], async (r) => (r.method === "first" ? { ok: r.method } : (reached.resolve(), new Promise(() => {}))));
  // (no check by time: what fails here fails by the close alone)
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 60_000 });
  try {
    assert.deepEqual(await call(target.id(), "ws", { method: "first" }), { ok: "first" });
    const waiting = settled(call(target.id(), "ws", { method: "in-flight" }));
    await given(reached.promise, "the request reached the process that hands over");
    // The next process binds the same key; the one before closes its connections as it stops (the front's `part`).
    const next = await again();
    serving(next, [source.id()], async (r) => ({ ok: r.method }));
    for (const c of conns) c.close(0, STOPPING);
    const failed = await given(waiting, "the request in flight failed as its connection closed");
    assert.ok("e" in failed && failed.e instanceof PeerStopped, `failed as the other's process stopping: ${"e" in failed ? failed.e.message : "answered"}`);
    assert.ok(failed.e instanceof PeerGone, "a PeerGone: no answer came, the next request dials anew");
    assert.deepEqual(await given(call(target.id(), "ws", { method: "again" }), "answered by the next process"), { ok: "again" });
  } finally { await Promise.all([source.close(), target.close()]); }
});

test("a request failed on a connection whose other end neither answers nor closes is not held waiting for its close: let go, the request failed, the next dials anew (FB-34)", { timeout: 20_000 }, async () => {
  const { source, target } = await pair();
  serving(target, [source.id()], async (r) => ({ ok: r.method }));
  // (what the addon says of a connection whose other end is stuck: its streams fail, it is not there, it never closes)
  const stuck = { now: false };
  const kept: Connection[] = [];
  const halfDead = (conn: Connection): Connection => new Proxy(conn, {
    get(c, prop) {
      if (stuck.now) {
        if (prop === "openBi") return async () => { throw new Error("stream failed"); };
        if (prop === "answers") return async () => false;
        if (prop === "isClosed") return () => false;
        if (prop === "closeReason") return () => null;
        if (prop === "closed") return () => new Promise<string>(() => {});
      }
      const v = (c as any)[prop];
      return typeof v === "function" ? v.bind(c) : v;
    },
  });
  const dialing = new Proxy(source, {
    get(e, prop) {
      if (prop === "connect") return async (...args: unknown[]) => {
        const conn = halfDead(await (e.connect as (...a: unknown[]) => Promise<Connection>)(...args));
        kept.push(conn);
        return conn;
      };
      const v = (e as any)[prop];
      return typeof v === "function" ? v.bind(e) : v;
    },
  });
  // (no check by time: what fails here fails by the stream alone, and the close is waited for `heardMs` at most)
  const call = peerCall(dialing, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 60_000, heardMs: 20 });
  try {
    assert.deepEqual(await call(target.id(), "ws", { method: "first" }), { ok: "first" });
    stuck.now = true;
    const failed = await settled(call(target.id(), "ws", { method: "stuck" }));
    assert.ok("e" in failed, "the request failed");
    assert.ok(!(failed.e instanceof PeerStopped), `its other end said nothing of stopping: ${failed.e.message}`);
    assert.match(failed.e.message, /stream failed/);
    // (its letting go, begun as the request failed, done before its other end is there again)
    await settle();
    stuck.now = false;
    assert.deepEqual(await given(call(target.id(), "ws", { method: "again" }), "answered on a new connection"), { ok: "again" });
    assert.equal(kept.length, 2, "the half-dead connection was let go and a new one dialed");
  } finally { await Promise.all([source.close(), target.close()]); }
});
