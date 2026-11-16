// A workspace turning still.fail's relays off (ways.json `off: ["ours"]`, its own relay kept) on real endpoints and real
// iroh-relays (n0's, scripts/native.ts `iroh-relay`): two stations bound on still.fail's relay and the workspace's own,
// as a station is bound, each taking still.fail's off as keepRelays does (`removeRelay`), and dialing the other as the
// station transport does (relays.ts `stationAddr`: the workspace's relays on, those off disabled). They talk through
// the workspace's relay alone: still.fail's is no path of theirs even where an old address names it, the station is no
// longer reached through it, and its relay stopped changes nothing. On the addon and on the MoonBit front (the shell's
// endpoint), real processes and time: the side run's. Before zzj3720/iroh#17 the relay transport home on still.fail's
// relay was never told it was removed: the station stayed home there, named it, and was reached through it.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { withFront } from "../src/mesh/front.ts";
import { loadMesh } from "../src/mesh/native.ts";
import type { Addr, Connection, Endpoint, Mesh, Stream } from "../src/mesh/native.ts";
import { stationAddr } from "../src/mesh/relays.ts";
import { sameUrl } from "../src/mesh/ways.ts";
import { wall } from "../src/ops/fibers.ts";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";

// Never skipped: `test:side` brings both (native.ts `iroh-relay`, `reader`); one not there is a failure, not a pass.
const RELAY_BIN = process.env.STILLFAIL_RELAY_BIN;
const reader = mbReaderBinary();
const needs = () => {
  assert.ok(RELAY_BIN && existsSync(RELAY_BIN), "no iroh-relay here (STILLFAIL_RELAY_BIN: node ../scripts/native.ts run … iroh-relay)");
  assert.ok(reader !== null, "the MoonBit program is not built here (station/mb/build.sh)");
};
const ALPN = Buffer.from("stillfail/test/1");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
type After = { after(f: () => unknown): void };
/// Looked at every 50 ms until it holds or `ms` went by (then the assertion after it says what is wrong).
const until = async (what: () => boolean, ms = 10_000) => {
  const by = wall.now() + ms;
  while (!what() && wall.now() < by) await sleep(50);
};

function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const port = (server.address() as { port: number }).port;
      server.close(() => resolve(port));
    });
  });
}

/// iroh-relay in dev mode (plain HTTP) on `port`: its url, and what stops it.
async function relay(t: After, port: number): Promise<{ url: string; sent(): Promise<number>; stop(): void }> {
  const metricsPort = await freePort();
  const config = join(tmpdir(), `relay-off-${process.pid}-${port}.toml`);
  writeFileSync(config, `enable_relay = true\nhttp_bind_addr = "127.0.0.1:${port}"\nenable_metrics = true\nmetrics_bind_addr = "127.0.0.1:${metricsPort}"\nenable_quic_addr_discovery = false\n`);
  const child: ChildProcess = spawn(RELAY_BIN!, ["--dev", "--config-path", config], { stdio: "ignore" });
  const stop = () => {
    child.kill("SIGKILL");
    rmSync(config, { force: true });
  };
  t.after(stop);
  const url = `http://127.0.0.1:${port}`;
  while (!(await fetch(url).then(() => true, () => false))) await sleep(50);
  const sent = async () => {
    const response = await fetch(`http://127.0.0.1:${metricsPort}/metrics`);
    assert.equal(response.status, 200);
    const metrics = await response.text();
    const counter = metrics.match(/^relayserver_send_packets_recv_total\s+(\d+)$/m);
    assert.ok(counter, `missing relay datagram counter: ${metrics}`);
    return Number(counter[1]);
  };
  return { url, sent, stop };
}

/// The two relays: still.fail's the one iroh puts after the other (a relay transport of its own with
/// `home_on_every_relay`, the one upstream never told of a removal).
async function relays(t: After) {
  const ports = [await freePort(), await freePort()].sort((a, b) => String(a).localeCompare(String(b)));
  const own = await relay(t, ports[0]!);
  const ours = await relay(t, ports[1]!);
  return { ours, own };
}

/// A MoonBit front of its own, the mesh a station has through it.
async function front(t: After): Promise<Mesh> {
  const dir = mkdtempSync(join(tmpdir(), "relay-off-front-"));
  const socket = join(dir, "front.sock");
  const process = new MbProcess(reader!, ["--builder", "mesh", "--socket", socket, "--shell-dir", join(dir, "shell")]);
  await new Promise<void>((resolve, reject) => {
    process.once("message", (m: { listening?: string }) => (m.listening === socket ? resolve() : reject(new Error(JSON.stringify(m)))));
    process.once("exit", (code: number) => reject(new Error(`ended (${code})`)));
  });
  t.after(async () => {
    await process.terminate();
    rmSync(dir, { recursive: true, force: true });
  });
  return withFront(loadMesh(), socket);
}

/// Every stream opened to `endpoint` answered with what came on it.
function echoing(endpoint: Endpoint) {
  void (async () => {
    for (let conn = await endpoint.accept(); conn; conn = await endpoint.accept()) {
      const c = conn;
      void (async () => {
        for (let s = await c.acceptBi(); s; s = await c.acceptBi()) {
          const stream = s;
          void (async () => {
            for (let b = await stream.read(); b; b = await stream.read()) await stream.write(b);
            await stream.finish();
          })().catch(() => {});
        }
      })().catch(() => {});
    }
  })().catch(() => {});
}

async function readAll(s: Stream): Promise<string> {
  const parts: Buffer[] = [];
  for (let b = await s.read(); b; b = await s.read()) parts.push(b);
  return Buffer.concat(parts).toString();
}

/// One round on `conn`, within 20 s.
async function round(conn: Connection, said: string): Promise<string> {
  return wall.within(20_000, (async () => {
    const s = await conn.openBi();
    await s.write(Buffer.from(said));
    await s.finish();
    return readAll(s);
  })(), `no answer to ${said} in 20 s`);
}

/// The relays `endpoint` is home on now.
const homes = (endpoint: Endpoint) => (endpoint.relayStatus?.() ?? []).map((r) => sameUrl(r.url));

/// The relays `conn` has a path through now.
const relayed = (conn: Connection) => (conn.paths?.() ?? []).flatMap((p) => (p.relay ? [sameUrl(p.relay)] : []));

/// A station's cloud.json as the dialing station reads it: workspace "ws" with `peer`, still.fail's relay `ours` and the
/// workspace's own `own`, still.fail's turned off.
const cloudOf = (peer: string, ours: string, own: string): any => {
  const data = mkdtempSync(join(tmpdir(), "relay-off-cloud-"));
  mkdirSync(join(data, "mesh"));
  return {
    data,
    state: { station: "me", stillfail_relays: [ours] },
    relays: () => [ours, own],
    memberships: () => [{ workspace: "ws", peers: [{ id: peer }] }],
    membership: (ws: string) => (ws === "ws" ? {} : null),
    rigs: () => [],
    waysSaid: () => ({ relays: [own], off: ["ours"] }),
  };
};

async function turnedOff(t: After, meshes: { target: Mesh; dialer: Mesh }) {
  const { ours, own } = await relays(t);
  const bind = (mesh: Mesh) => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [ours.url, own.url], discovery: false, relayOnly: true });
  const target = await bind(meshes.target);
  t.after(() => target.close().catch(() => {}));
  const dialer = await bind(meshes.dialer);
  t.after(() => dialer.close().catch(() => {}));
  echoing(target);
  await until(() => homes(target).length === 2);
  assert.deepEqual(homes(target).sort(), [sameUrl(ours.url), sameUrl(own.url)].sort(), "home on both at first");

  // The workspace turns still.fail's relays off: each station takes them off (relays.ts keepRelays).
  await target.removeRelay(ours.url);
  await dialer.removeRelay(ours.url);
  await until(() => !homes(target).includes(sameUrl(ours.url)));
  assert.deepEqual(homes(target), [sameUrl(own.url)], "home on the workspace's relay alone");

  // Not reached through still.fail's relay any more: an endpoint there alone dials it in vain.
  const prober = await loadMesh().bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [ours.url], discovery: false, relayOnly: true });
  t.after(() => prober.close().catch(() => {}));
  await prober.online();
  let giveUp = () => {};
  const givenUp = new Promise<void>((r) => (giveUp = r));
  const probed = prober.connect({ id: target.id(), relays: [ours.url] }, ALPN, [], givenUp).then(() => "reached", (e: Error) => e.message);
  const reached = await Promise.race([probed, sleep(5_000).then(() => "not in 5 s")]);
  giveUp();
  assert.notEqual(reached, "reached", "reached through still.fail's relay, turned off");

  // Dialed as the station transport dials it, an old address naming still.fail's relay too (as the DHT may).
  const addr: Addr = stationAddr(cloudOf(target.id(), ours.url, own.url), target.id(), "ws");
  assert.deepEqual({ relays: addr.relays, disabled: addr.disabledRelays }, { relays: [own.url], disabled: [ours.url] });
  (dialer as { addAddr?(a: Addr): void }).addAddr?.({ id: target.id(), relays: [ours.url, own.url] });
  const conn = await wall.within(20_000, dialer.connect(addr, ALPN), "not connected in 20 s");
  assert.equal(await round(conn, "first"), "first");
  const by = wall.now() + 3_000;
  while (wall.now() < by) {
    assert.ok(!relayed(conn).includes(sameUrl(ours.url)), `a path through still.fail's relay: ${relayed(conn).join(", ")}`);
    await sleep(100);
  }
  assert.ok(relayed(conn).includes(sameUrl(own.url)), `through the workspace's relay: ${relayed(conn).join(", ")}`);

  // still.fail's relay gone: nothing changes.
  ours.stop();
  for (let i = 0; i < 5; i++) assert.equal(await round(conn, `after ${i}`), `after ${i}`);
  conn.close(0, "done");
}

test("still.fail's relays turned off: two stations on the addon talk through the workspace's relay alone", async (t) => {
  needs();
  await turnedOff(t, { target: loadMesh(), dialer: loadMesh() });
});

test("so do two on the MoonBit front, as the station has it", async (t) => {
  needs();
  await turnedOff(t, { target: await front(t), dialer: await front(t) });
});


async function narrowedWhileKept(t: After, mesh: Mesh) {
  const { ours, own } = await relays(t);
  const bind = (m: Mesh) => m.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [ours.url, own.url], discovery: false, bindAddr: "127.0.0.1:0" });
  const target = await bind(loadMesh());
  t.after(() => target.close().catch(() => {}));
  const dialer = await bind(mesh);
  t.after(() => dialer.close().catch(() => {}));
  echoing(target);
  await Promise.all([target.online(), dialer.online()]);
  const conn = await wall.within(20_000, dialer.connect({ id: target.id(), relays: [ours.url, own.url], ips: target.sockets() }, ALPN), "dial timed out");
  const ready = () => (conn.paths?.() ?? []).some((p) => p.selected && p.ip)
    && relayed(conn).includes(sameUrl(ours.url)) && relayed(conn).includes(sameUrl(own.url));
  await until(ready, 30_000);
  assert.ok(ready(), `expected direct selected and both relay backups: ${JSON.stringify(conn.paths?.())}`);
  assert.equal(await round(conn, "before policy"), "before policy");
  assert.ok(dialer.disabledRelays, "live policy operation present");
  await dialer.disabledRelays(target.id(), [ours.url], false);
  await until(() => !relayed(conn).includes(sameUrl(ours.url)));
  assert.ok(!relayed(conn).includes(sameUrl(ours.url)), "forbidden backup abandoned");
  const ownBefore = await own.sent();
  const untilPackets = async (count: number) => {
    await wall.within(30_000, (async () => {
      while ((await own.sent()) < ownBefore + count) await sleep(50);
    })(), "allowed relay did not carry the observation window");
  };
  // Let pre-ack packets drain, then measure a second window bounded by actual allowed-relay traffic.
  await untilPackets(4);
  const before = await ours.sent();
  await untilPackets(12);
  assert.equal(await ours.sent(), before, "forbidden relay received datagrams in the second window");
  assert.ok((conn.paths?.() ?? []).some((p) => p.ip), "direct path survived");
  assert.equal(await round(conn, "same connection after policy"), "same connection after policy");
  assert.ok(homes(dialer).includes(sameUrl(ours.url)), "endpoint still resides on the relay for other peers");
  conn.close(0, "done");
}

test("live policy removes a direct connection's relay backup on the addon", async (t) => {
  needs();
  await narrowedWhileKept(t, loadMesh());
});

test("live policy removes a direct connection's relay backup through the MoonBit front", async (t) => {
  needs();
  await narrowedWhileKept(t, await front(t));
});
