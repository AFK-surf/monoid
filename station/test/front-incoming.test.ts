// The streams a connection's other end opens, as the front hands them (src/mesh/front.ts `Incoming`): each on a
// socket of its own, so they come in any order; taken in the order they were opened. 2026-11-13: a device's requests,
// opened right after its credential stream, came first and were refused as its credential (`malformed credential`).
import assert from "node:assert/strict";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Front, Incoming, withFront } from "../src/mesh/front.ts";
import type { Mesh } from "../src/mesh/native.ts";

function stream(id: number, index?: number) {
  const destroyed = { yes: false };
  const socket = { destroy: () => void (destroyed.yes = true) } as unknown as Socket;
  return { came: { socket, carry: Buffer.alloc(0), id, ...(index === undefined ? {} : { index }) }, destroyed };
}

async function taken(incoming: Incoming, n: number): Promise<number[]> {
  const ids: number[] = [];
  for (let i = 0; i < n; i++) ids.push((await incoming.take())!.id);
  return ids;
}

test("streams that come out of order are taken in the order they were opened", async () => {
  const incoming = new Incoming();
  // Opened 0 (the credential), 1, 2, 3; their sockets came 2, 1, 3, 0.
  incoming.give(stream(12, 2).came);
  incoming.give(stream(11, 1).came);
  incoming.give(stream(13, 3).came);
  incoming.give(stream(10, 0).came);
  assert.deepEqual(await taken(incoming, 4), [10, 11, 12, 13]);
});

test("one asked for before it came is given once those before it came", async () => {
  const incoming = new Incoming();
  const first = incoming.take();
  incoming.give(stream(21, 1).came);
  let settled = false;
  void first.then(() => (settled = true));
  await Promise.resolve();
  assert.equal(settled, false, "the request is not taken ahead of the credential");
  incoming.give(stream(20, 0).came);
  assert.equal((await first)!.id, 20);
  assert.equal((await incoming.take())!.id, 21);
});

test("a front from before the index: streams go as they came", async () => {
  const incoming = new Incoming();
  incoming.give(stream(31).came);
  incoming.give(stream(30).came);
  assert.deepEqual(await taken(incoming, 2), [31, 30]);
});

test("the connection gone: those waiting for one before them are let go", async () => {
  const incoming = new Incoming();
  const waiting = stream(41, 1);
  incoming.give(waiting.came);
  incoming.end();
  assert.equal(waiting.destroyed.yes, true);
  assert.equal(await incoming.take(), null);
});

test("the front ending with EPIPE on its control socket settles gone without an unhandled readline error", async () => {
  const dir = await mkdtemp(join(tmpdir(), "front-epipe-"));
  const sock = join(dir, "front.sock");
  let accepted: Socket | undefined;
  const server = createServer((s) => { accepted = s; });
  await new Promise<void>((resolve) => server.listen(sock, resolve));
  try {
    const front = await Front.open(sock);
    const pending = front.ask("endpoint.addresses");
    accepted!.destroy();
    await front.gone;
    await assert.rejects(pending, /the front is gone/);
    front.close();
  } finally {
    server.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("the streams' sockets a killed process left are taken away as the next opens; one still running keeps its own", async () => {
  const dir = await mkdtemp(join(tmpdir(), "front-left-"));
  const sock = join(dir, "front.sock");
  const server = createServer(() => {});
  await new Promise<void>((resolve) => server.listen(sock, resolve));
  // (a pid no process has: beyond what the systems give)
  const gone = 4_000_000_000;
  await writeFile(join(dir, `mesh-${gone}-1.sock`), "");
  await writeFile(join(dir, `mesh-${gone}-2.sock`), "");
  await writeFile(join(dir, `mesh-${process.ppid}-1.sock`), "");
  await writeFile(join(dir, "mesh-not-ours.sock"), "");
  try {
    const front = await Front.open(sock);
    const left = (await readdir(dir)).sort();
    assert.deepEqual(left, ["front.sock", `mesh-${process.ppid}-1.sock`, "mesh-not-ours.sock", front.streamsPath.slice(dir.length + 1)].sort());
    front.close();
  } finally {
    server.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("whether the endpoint is linked to the front is said as its link goes and comes again (ops/health.ts)", async () => {
  const dir = await mkdtemp(join(tmpdir(), "front-link-"));
  const sock = join(dir, "front.sock");
  const links: Socket[] = [];
  // A front that answers a bind, and anything else with nothing.
  const server = createServer((s) => {
    links.push(s);
    let pending = "";
    s.on("data", (chunk) => {
      pending += chunk;
      for (let at; (at = pending.indexOf("\n")) >= 0; pending = pending.slice(at + 1)) {
        const asked = JSON.parse(pending.slice(0, at));
        s.write(JSON.stringify({ id: asked.id, ok: asked.op === "bind" ? { id: "station", sockets: [] } : asked.op === "relayStatus" ? [] : null }) + "\n");
      }
    });
    s.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(sock, resolve));
  try {
    const mesh = withFront({} as Mesh, sock);
    assert.equal(mesh.frontLink!(), "ok", "none bound: none linking");
    const endpoint = await mesh.bind({ secretKey: Buffer.alloc(32), alpns: [], relayUrls: [] });
    assert.equal(mesh.frontLink!(), "ok");
    // The front gone: linking to it again until it is back.
    links[0]!.destroy();
    while (mesh.frontLink!() === "ok") await new Promise((r) => setImmediate(r));
    assert.equal(mesh.frontLink!(), "reconnecting");
    while (links.length < 2 || mesh.frontLink!() !== "ok") await new Promise((r) => setImmediate(r));
    // Closed: no longer counted.
    links[1]!.destroy();
    await endpoint.close();
    assert.equal(mesh.frontLink!(), "ok");
  } finally {
    for (const s of links) s.destroy();
    server.close();
    await rm(dir, { recursive: true, force: true });
  }
});

// Another station on this station's key at a relay (2026-11-16): the relay holds this endpoint inactive and says so in its
// status (`conflict`), which the mesh says (`relayConflict`, health.json). Whether the endpoint is the front's or the
// addon's own; and the front's linked again says what the front it is linked to now says, not the one gone.
test("a relay holding an endpoint inactive for another of its key is said by the mesh, the front's and the addon's", async () => {
  const dir = await mkdtemp(join(tmpdir(), "front-relays-"));
  const sock = join(dir, "front.sock");
  const links: Socket[] = [];
  // Each link's front says its relays: the first's held inactive, the next's not (it came back, the other gone).
  const relaysOf = (link: number) => [{ url: "https://r.example/", connected: true, access: "https://r.example/", conflict: link === 0 }];
  const server = createServer((s) => {
    const link = links.push(s) - 1;
    let pending = "";
    s.on("data", (chunk) => {
      pending += chunk;
      for (let at; (at = pending.indexOf("\n")) >= 0; pending = pending.slice(at + 1)) {
        const asked = JSON.parse(pending.slice(0, at));
        s.write(JSON.stringify({ id: asked.id, ok: asked.op === "bind" ? { id: "station", sockets: [] } : asked.op === "relayStatus" ? relaysOf(link) : null }) + "\n");
      }
    });
    s.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(sock, resolve));
  try {
    const mesh = withFront({} as Mesh, sock);
    assert.equal(mesh.relayConflict?.(), false, "none bound: none held inactive");
    const endpoint = await mesh.bind({ secretKey: Buffer.alloc(32), alpns: [], relayUrls: [] });
    // As bound: its relays as the front said them then.
    assert.equal(mesh.relayConflict!(), true);
    // The front gone and another linked: what that one says, at once.
    links[0]!.destroy();
    while (mesh.frontLink!() === "ok") await new Promise((r) => setImmediate(r));
    while (links.length < 2 || mesh.frontLink!() !== "ok") await new Promise((r) => setImmediate(r));
    assert.equal(mesh.relayConflict!(), false, "what the front gone said of its relays is not this one's");
    await endpoint.close();
  } finally {
    for (const s of links) s.destroy();
    server.close();
    await rm(dir, { recursive: true, force: true });
  }

  // The addon's endpoint (no front): kept while bound, its status read as asked.
  const said = { conflict: false };
  let closed = 0;
  const addon = {
    bind: async () => ({
      relayStatus: () => [{ url: "https://r.example/", connected: true, access: "https://r.example/", conflict: said.conflict }],
      close: async () => void closed++,
    }),
  } as unknown as Mesh;
  const native = await import("../src/mesh/native.ts");
  const own = (native as Record<string, unknown>).withRelays as ((m: Mesh) => Mesh) | undefined;
  assert.equal(typeof own, "function", "the addon's mesh keeps what it binds (withRelays)");
  const mesh = own!(addon);
  const endpoint = await mesh.bind({ secretKey: Buffer.alloc(32), alpns: [], relayUrls: [] });
  assert.equal(mesh.relayConflict!(), false);
  said.conflict = true;
  assert.equal(mesh.relayConflict!(), true);
  await endpoint.close();
  assert.equal(closed, 1);
  assert.equal(mesh.relayConflict!(), false, "closed: no longer counted");
});

// A relay put in or taken out as the station runs (relays.ts keepRelays: a workspace turning still.fail's off) stays so
// across the front's link made again: bound again as the endpoint is now, not as it was first bound.
test("the front's endpoint linked again is bound with the relays it is on now", async () => {
  const dir = await mkdtemp(join(tmpdir(), "front-rebind-"));
  const sock = join(dir, "front.sock");
  const links: Socket[] = [];
  const bound: string[][] = [];
  const told: { link: number; op: string; args?: unknown }[] = [];
  const server = createServer((s) => {
    const link = links.push(s);
    let pending = "";
    s.on("data", (chunk) => {
      pending += chunk;
      for (let at; (at = pending.indexOf("\n")) >= 0; pending = pending.slice(at + 1)) {
        const asked = JSON.parse(pending.slice(0, at));
        told.push({ link, op: asked.op, args: asked.args });
        if (asked.op === "bind") bound.push(asked.options.relayUrls);
        s.write(JSON.stringify({ id: asked.id, ok: asked.op === "bind" ? { id: "station", sockets: [] } : asked.op === "relayStatus" ? [] : null }) + "\n");
      }
    });
    s.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(sock, resolve));
  try {
    const mesh = withFront({} as Mesh, sock);
    const endpoint = await mesh.bind({ secretKey: Buffer.alloc(32), alpns: [], relayUrls: ["https://ours.example", "https://own.example"] });
    await endpoint.removeRelay("https://ours.example/");
    await endpoint.insertRelay("https://more.example");
    await endpoint.insertRelay("https://own.example/");
    await endpoint.disabledRelays!("peer-a", ["https://ours.example"], true);
    await endpoint.disabledRelays!("peer-b", ["https://ours.example"], false);
    await endpoint.disabledRelays!("peer-b", [], false);
    const activeScope = { scope: "01".repeat(32), peers: [], relayUrls: ["https://own.example"] };
    const removedScope = { ...activeScope, scope: "02".repeat(32) };
    await endpoint.meshConfigure!(activeScope);
    await endpoint.meshConfigure!(removedScope);
    await endpoint.meshRemove!(removedScope.scope);
    await endpoint.route!(Buffer.from("test"), ["/tmp/test.sock"], ["GET /test"]);
    links[0]!.destroy();
    while (mesh.frontLink!() === "ok") await new Promise((r) => setImmediate(r));
    while (links.length < 2 || mesh.frontLink!() !== "ok") await new Promise((r) => setImmediate(r));
    assert.deepEqual(bound, [["https://ours.example", "https://own.example"], ["https://own.example", "https://more.example"]]);
    assert.deepEqual(told.filter((x) => x.link === 2 && x.op === "disabledRelays").map((x) => x.args), [{ peer: "peer-a", relays: ["https://ours.example"], public: true }]);
    assert.deepEqual(told.filter((x) => x.link === 2 && x.op === "meshConfigure").map((x) => x.args), [activeScope]);
    const replay = told.findIndex((x) => x.link === 2 && x.op === "disabledRelays");
    const routed = told.findIndex((x) => x.link === 2 && x.op === "route");
    assert.ok(replay >= 0 && routed > replay, "restrictions replay before incoming requests are routed");
    await endpoint.close();
  } finally {
    for (const s of links) s.destroy();
    server.close();
    await rm(dir, { recursive: true, force: true });
  }
});
