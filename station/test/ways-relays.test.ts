// A workspace's ways (mesh/ways.ts) turning relays off reach the station's own connections, not only its devices': the
// relays it is kept on (relays.ts `wantedRelays`), where it dials the other stations (`stationAddr`: peer.ts, peer-http.ts)
// and what it no longer goes through (`disabledRelays`), a connection kept from before let go. And a dial no request
// waits for any more is given up (peer.ts), not left to retransmit for the connection's idle timeout.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Cloud } from "../src/cloud/state.ts";
import type { Addr, Connection, Endpoint } from "../src/mesh/native.ts";
import { PEER_HTTP_ALPN, PeerHttp } from "../src/mesh/peer-http.ts";
import { PEER_ALPN, PEER_BYTES_ALPN, peerCall, servePeer } from "../src/mesh/peer.ts";
import { stationAddr, wantedRelays } from "../src/mesh/relays.ts";
import { offRelays, waysOf, workspaceRelays } from "../src/mesh/ways.ts";
import { memoryMesh } from "./memory-mesh.ts";

const OURS = "https://ours.example";
const OWN = "https://relay.example";
const B_OWN = "https://b.example";

/// A station's cloud.json in memory, in workspace "ws" with `peers`, still.fail's relay OURS and the ways the cloud kept.
const cloudOf = (station: string, peers: string[], ways: { relays: string[]; off: string[] }): any => {
  const data = mkdtempSync(join(tmpdir(), "ways-relays-"));
  mkdirSync(join(data, "mesh"));
  return Object.assign(Object.create(Cloud.prototype), {
    data,
    state: { workspace: "ws", workspace_name: "ws", name: "", station, peers: peers.map((id) => ({ id, name: id.slice(0, 6) })), revocations: [], joined: [], relay_url: OURS, relay_urls: [OURS, ...ways.relays], stillfail_relays: [OURS], ways },
    lock: null,
    peersCurrent: true,
    listeners: new Set(),
  });
};

/// A station in two workspaces: "a" turned still.fail's relays off for its own, "b" keeps them with its own beside.
const twoWorkspaces = (): any => ({
  data: mkdtempSync(join(tmpdir(), "ways-relays-")),
  state: { station: "me", stillfail_relays: [OURS] },
  relays: () => [OURS, OWN, B_OWN],
  memberships: () => [{ workspace: "a", peers: [{ id: "x" }, { id: "y" }] }, { workspace: "b", peers: [{ id: "y" }] }],
  membership: (ws: string) => (ws === "a" || ws === "b" ? {} : null),
  rigs: () => [],
  waysSaid: (ws: string) => (ws === "a" ? { relays: [OWN], off: ["ours"] } : { relays: [B_OWN], off: [] }),
});

const shape = (a: Addr) => ({ relays: a.relays, disabledRelays: a.disabledRelays ?? [] });

test("a workspace's relays are still.fail's and its own but those its ways turn off; never none", () => {
  const cloud = cloudOf("me", [], { relays: [OWN], off: ["ours"] });
  const ways = waysOf(cloud);
  assert.deepEqual(workspaceRelays(ways, "ws"), [OWN]);
  assert.deepEqual(offRelays(ways, "ws"), [OURS]);
  assert.deepEqual(wantedRelays(cloud), [OWN], "the station kept on its own relay alone");
  ways.change("ws", (now) => ({ ...now, off: [`${OWN}/`] }));
  assert.deepEqual(workspaceRelays(ways, "ws"), [OURS], "one relay off by its URL, as written or not");
  assert.deepEqual(offRelays(ways, "ws"), [OWN]);
  ways.change("ws", (now) => ({ ...now, off: ["ours", OWN] }));
  assert.deepEqual(workspaceRelays(ways, "ws"), [OURS, OWN], "a record that turns all off (made by hand) turns none off");
  assert.deepEqual(offRelays(ways, "ws"), []);
});

test("a station in several workspaces is kept on each one's relays; another station is dialed by the workspaces both are in", () => {
  const cloud = twoWorkspaces();
  assert.deepEqual(wantedRelays(cloud), [OWN, OURS, B_OWN]);
  assert.deepEqual(shape(stationAddr(cloud, "x", "a")), { relays: [OWN], disabledRelays: [OURS] }, "asked in a: a's ways");
  assert.deepEqual(shape(stationAddr(cloud, "x", null)), { relays: [OWN], disabledRelays: [OURS] }, "of a alone");
  assert.deepEqual(shape(stationAddr(cloud, "y", "b")), { relays: [OURS, B_OWN], disabledRelays: [] }, "asked in b: b's ways");
  assert.deepEqual(shape(stationAddr(cloud, "y", null)), { relays: [OWN, OURS, B_OWN], disabledRelays: [] }, "of both: a relay off in one alone is not disabled");
  assert.deepEqual(shape(stationAddr(cloud, "z", null)), { relays: [OWN, OURS, B_OWN], disabledRelays: [] }, "of none: as this station is kept");
});

/// Two stations on a mesh in memory; what this one dials with (`dialed`) and the connections it made (`made`).
async function pair(ways: { relays: string[]; off: string[] }) {
  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [PEER_BYTES_ALPN, PEER_ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [source, target] = await Promise.all([bind(), bind()]);
  const dialed: Addr[] = [];
  const made: Connection[] = [];
  const connect = source.connect.bind(source);
  source.connect = async (addr, ...rest) => {
    dialed.push(addr);
    const conn = await connect(addr, ...rest);
    made.push(conn);
    return conn;
  };
  const remote: any = { handle: async (_ws: string, _peer: string, request: any) => ({ ok: request.method }) };
  void (async () => {
    for (;;) {
      const conn = await target.accept();
      if (!conn) return;
      void servePeer(conn, cloudOf(target.id(), [source.id()], ways), remote).catch(() => {});
    }
  })();
  return { source, target, dialed, made, cloud: cloudOf(source.id(), [target.id()], ways) };
}

/// A connection said to go through `relay` now (the memory mesh's say nothing of their paths).
const through = (conn: Connection, relay: string) => {
  conn.paths = () => [{ selected: true, relay: `${relay}/`, txPackets: 0, lostPackets: 0 }];
};

test("the station transport dials a station of a workspace that turned still.fail's relays off through its own alone, still.fail's disabled", async () => {
  const p = await pair({ relays: [OWN], off: ["ours"] });
  const call = peerCall(p.source, p.cloud);
  try {
    assert.deepEqual(await call(p.target.id(), "ws", { method: "first" }), { ok: "first" });
    assert.deepEqual(p.dialed.map(shape), [{ relays: [OWN], disabledRelays: [OURS] }]);
  } finally { await Promise.all([p.source.close(), p.target.close()]); }
});

test("a station's connection kept from before its relay was turned off is let go: the next request dials anew, not through it", async () => {
  const p = await pair({ relays: [OWN], off: [] });
  const call = peerCall(p.source, p.cloud);
  try {
    assert.deepEqual(await call(p.target.id(), "ws", { method: "first" }), { ok: "first" });
    assert.deepEqual(p.dialed.map(shape), [{ relays: [OURS, OWN], disabledRelays: [] }]);
    through(p.made[0]!, OURS);
    assert.deepEqual(await call(p.target.id(), "ws", { method: "kept" }), { ok: "kept" }, "on through a relay still on");
    assert.equal(p.dialed.length, 1, "the connection kept");
    waysOf(p.cloud).change("ws", (now) => ({ ...now, off: ["ours"] }));
    assert.deepEqual(await call(p.target.id(), "ws", { method: "again" }), { ok: "again" });
    assert.ok(p.made[0]!.isClosed(), "the one through still.fail's relay closed");
    assert.deepEqual(p.dialed.map(shape), [{ relays: [OURS, OWN], disabledRelays: [] }, { relays: [OWN], disabledRelays: [OURS] }]);
  } finally { await Promise.all([p.source.close(), p.target.close()]); }
});

/// An endpoint whose dials never come up: what each was given up with, and whether it was.
function neverUp() {
  const dials: { addr: Addr; givenUp: boolean; passed: boolean }[] = [];
  const endpoint = {
    connect: (addr: Addr, _alpn: Buffer, _additional?: Buffer[], givenUp?: Promise<void>) => {
      const dial = { addr, givenUp: false, passed: givenUp !== undefined };
      dials.push(dial);
      void givenUp?.then(() => void (dial.givenUp = true));
      return new Promise<Connection>(() => {});
    },
  } as unknown as Endpoint;
  return { endpoint, dials };
}

const turns = async (n = 5) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };

test("a dial no request waits for any more is given up: with several sharing it, as the last stops waiting", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { endpoint, dials } = neverUp();
  const target = "t".repeat(64);
  const call = peerCall(endpoint, cloudOf("me", [target], { relays: [], off: [] }), undefined, undefined, 1_000);
  const outcome = (p: Promise<unknown>) => p.then(() => "answered", (e: Error) => e.message);
  const first = outcome(call(target, "ws", { method: "a" }));
  t.mock.timers.tick(500);
  const second = outcome(call(target, "ws", { method: "b" }));
  await turns();
  assert.equal(dials.length, 1, "one dial for both");
  assert.ok(dials[0]!.passed, "dialed with a way to give it up");
  t.mock.timers.tick(500);
  assert.match(await first, /timed out/);
  await turns();
  assert.equal(dials[0]!.givenUp, false, "the second still waits for it");
  t.mock.timers.tick(500);
  assert.match(await second, /timed out/);
  await turns();
  assert.equal(dials[0]!.givenUp, true, "given up as the last stopped waiting");
});

test("a request's dial alone, timed out, is given up at once", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { endpoint, dials } = neverUp();
  const target = "t".repeat(64);
  const call = peerCall(endpoint, cloudOf("me", [target], { relays: [], off: [] }), undefined, undefined, 1_000);
  const asked = call(target, "ws", { method: "a" }).then(() => "answered", (e: Error) => e.message);
  t.mock.timers.tick(1_000);
  assert.match(await asked, /timed out/);
  await turns();
  assert.equal(dials[0]!.givenUp, true);
});

test("web requests to another station dial it through its workspace's relays on, those off disabled; a connection through one turned off since is let go", async () => {
  const target = "t".repeat(64);
  const cloud = cloudOf("me", [target], { relays: [OWN], off: [] });
  const dialed: Addr[] = [];
  const made: any[] = [];
  const endpoint = {
    connect: async (addr: Addr) => {
      dialed.push(addr);
      let closed = false;
      const conn = { alpn: () => PEER_HTTP_ALPN, isClosed: () => closed, close: () => void (closed = true), openBi: async () => ({}), paths: () => [] as any[] };
      made.push(conn);
      return conn;
    },
  } as unknown as Endpoint;
  const http = new PeerHttp(endpoint, cloud);
  const stream = (http as any).stream.bind(http) as (id: string, given: string, workspace: string) => Promise<unknown>;
  await stream(target, "tttttt", "ws");
  assert.deepEqual(dialed.map(shape), [{ relays: [OURS, OWN], disabledRelays: [] }]);
  made[0].paths = () => [{ selected: true, relay: `${OURS}/`, txPackets: 0, lostPackets: 0 }];
  await stream(target, "tttttt", "ws");
  assert.equal(dialed.length, 1, "kept while its relay is on");
  waysOf(cloud).change("ws", (now) => ({ ...now, off: ["ours"] }));
  await stream(target, "tttttt", "ws");
  assert.ok(made[0].isClosed(), "the one through still.fail's relay closed");
  assert.deepEqual(dialed.map(shape), [{ relays: [OURS, OWN], disabledRelays: [] }, { relays: [OWN], disabledRelays: [OURS] }]);
  http.close();
});

test("a relay turned off lets go at once of the idle connections kept through it, not of those going direct", async () => {
  const p = await pair({ relays: [OWN], off: [] });
  const direct = await pair({ relays: [OWN], off: [] });
  const call = peerCall(p.source, p.cloud);
  const callDirect = peerCall(direct.source, direct.cloud);
  try {
    assert.deepEqual(await call(p.target.id(), "ws", { method: "first" }), { ok: "first" });
    assert.deepEqual(await callDirect(direct.target.id(), "ws", { method: "first" }), { ok: "first" });
    through(p.made[0]!, OURS);
    direct.made[0]!.paths = () => [{ selected: true, ip: "192.168.1.2:4000", txPackets: 0, lostPackets: 0 }];
    waysOf(p.cloud).change("ws", (now) => ({ ...now, off: ["ours"] }));
    waysOf(direct.cloud).change("ws", (now) => ({ ...now, off: ["ours"] }));
    assert.ok(p.made[0]!.isClosed(), "closed with no request made: its relay turned off");
    assert.ok(!direct.made[0]!.isClosed(), "one going direct is kept");
    assert.deepEqual(await callDirect(direct.target.id(), "ws", { method: "kept" }), { ok: "kept" });
    assert.equal(direct.dialed.length, 1, "on the connection kept");
  } finally {
    call.close?.();
    callDirect.close?.();
    await Promise.all([p.source.close(), p.target.close(), direct.source.close(), direct.target.close()]);
  }
});

test("so are web requests' connections to another station", async () => {
  const target = "t".repeat(64);
  const cloud = cloudOf("me", [target], { relays: [OWN], off: [] });
  const made: any[] = [];
  const endpoint = {
    connect: async () => {
      let closed = false;
      const conn = { alpn: () => PEER_HTTP_ALPN, isClosed: () => closed, close: () => void (closed = true), openBi: async () => ({}), paths: () => [] as any[] };
      made.push(conn);
      return conn;
    },
  } as unknown as Endpoint;
  const http = new PeerHttp(endpoint, cloud);
  await (http as any).stream(target, "tttttt", "ws");
  made[0].paths = () => [{ selected: true, relay: `${OURS}/`, txPackets: 0, lostPackets: 0 }];
  waysOf(cloud).change("ws", (now) => ({ ...now, off: ["ours"] }));
  await new Promise((r) => setImmediate(r));
  assert.ok(made[0].isClosed(), "closed with no request made: its relay turned off");
  http.close();
});
