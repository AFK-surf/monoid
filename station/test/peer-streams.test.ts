// A connection gives as many streams at once as its other end allows (QUIC's MAX_STREAMS; memoryMesh `streams`), and
// a stream counts until both its ends ended it. Requests whose answers never come must not use them up: the asker resets
// a request it gave up on, the station asked resets its end once the asker did, and a connection that gives no stream in
// time (its other end a station of before, keeping its ends open) is let go and dialed anew. What times out here does
// by the answer's deadline, ANSWER_MS of the wall's. Before, every request on
// such a connection timed out while its other end still answered whether it was there, so it was kept (2026-11-25).
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { Cloud } from "../src/cloud/state.ts";
import { PEER_ALPN, PEER_BYTES_ALPN, peerCall, servePeer } from "../src/mesh/peer.ts";
import type { Connection, Endpoint } from "../src/mesh/native.ts";
import { given } from "./hub-fakes.ts";
import { memoryMesh } from "./memory-mesh.ts";

const cloudOf = (station: string, peers: string[]): any =>
  Object.assign(Object.create(Cloud.prototype), {
    state: { workspace: "ws", workspace_name: "ws", name: "", station, peers: peers.map((id) => ({ id })), revocations: [], joined: [] },
    lock: null,
    peersCurrent: true,
    relays: () => [],
  });

const settled = <T>(p: Promise<T>) => p.then((v) => ({ v }), (e: Error) => ({ e }));

/// Two stations whose connections each give `streams` streams at once.
async function pair(streams: number) {
  const mesh = memoryMesh({ streams });
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [PEER_BYTES_ALPN, PEER_ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [source, target] = await Promise.all([bind(), bind()]);
  return { source, target };
}

/// What `stuck` asks is never answered (its handler never ends); anything else is answered at once.
const stuckOrAnswered = async (r: any) => (r.method === "stuck" ? new Promise(() => {}) : { ok: r.method });

/// A station answering with `handle`, its connections in the list given back; `old(n)`: the nth connection is served as
/// a station of before would, its ends of streams kept open while their handlers run, which here is for ever.
function serving(endpoint: Endpoint, peers: string[], handle: (request: any) => Promise<any>, old: (n: number) => boolean = () => false) {
  const conns: Connection[] = [];
  const remote: any = { handle: (_ws: string, _peer: string, request: any) => handle(request) };
  void (async () => {
    for (;;) {
      const conn = await endpoint.accept();
      if (!conn) return;
      conns.push(conn);
      if (old(conns.length)) void (async () => { while (await conn.acceptBi()) {} })();
      else void servePeer(conn, cloudOf(endpoint.id(), peers), remote).catch(() => {});
    }
  })();
  return conns;
}

const ANSWER_MS = 100;

test("requests given up on do not use up their connection's streams: each is reset by both ends, and the next is answered on the same connection", async () => {
  const { source, target } = await pair(2);
  const conns = serving(target, [source.id()], stuckOrAnswered);
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, ANSWER_MS, { checkMs: 60_000 });
  try {
    assert.deepEqual(await call(target.id(), "ws", { method: "first" }), { ok: "first" });
    // (more given up than the connection has streams: each frees its own)
    for (let i = 0; i < 4; i++) {
      const failed = await settled(call(target.id(), "ws", { method: "stuck" }));
      assert.ok("e" in failed && /timed out/.test(failed.e.message), `timed out: ${"e" in failed ? failed.e.message : "answered"}`);
    }
    assert.deepEqual(await given(call(target.id(), "ws", { method: "after" }), "answered after the stuck ones"), { ok: "after" });
    assert.equal(conns.length, 1, "answered on the connection kept, none dialed anew");
  } finally { await Promise.all([source.close(), target.close()]); }
});

test("a connection that gives no stream in time is let go, though its other end answers it is there, and the next request dials anew", async () => {
  const { source, target } = await pair(1);
  // (its first connection served as a station of before: the stream of a request given up on stays its)
  const conns = serving(target, [source.id()], stuckOrAnswered, (n) => n === 1);
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, ANSWER_MS, { checkMs: 60_000 });
  try {
    const first = await settled(call(target.id(), "ws", { method: "never" }));
    assert.ok("e" in first, "the station of before answered nothing");
    // Its one stream held: this one gets none in time.
    const starved = await settled(call(target.id(), "ws", { method: "starved" }));
    assert.ok("e" in starved && /timed out/.test(starved.e.message), `timed out: ${"e" in starved ? starved.e.message : "answered"}`);
    assert.deepEqual(await given(call(target.id(), "ws", { method: "again" }), "answered on a new connection"), { ok: "again" });
    assert.equal(conns.length, 2, "the connection with no stream to give was let go and a new one dialed");
  } finally { await Promise.all([source.close(), target.close()]); }
});
