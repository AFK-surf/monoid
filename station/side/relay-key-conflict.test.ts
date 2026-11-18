// Two endpoints on one station's key at one relay (2026-11-16: a front left from before held the key on the relays
// beside the one the launcher started; every device's handshake failed for hours, and `stillfail status` said all was
// normal). iroh-relay holds the one that connected first inactive and says so (SameEndpointIdConnected); that
// endpoint's relay status says it (zzj3720/iroh `RelayStatus::same_endpoint_id_connected`), the mesh says it
// (`relayConflict`), the station writes it to health.json and `stillfail status` reports it, until the other leaves and
// the relay says the connection is healthy again. On the real iroh-relay (n0's, scripts/native.ts `iroh-relay`), the
// addon and the MoonBit front: real processes and time, the side run's. It loads and runs on code from before this (its
// waits bounded, `withRelays` taken where there is one), so there it fails on what status says, not on a missing name.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { status } from "../src/cli.ts";
import { withFront } from "../src/mesh/front.ts";
import * as native from "../src/mesh/native.ts";
import type { Endpoint, Mesh } from "../src/mesh/native.ts";
import { writeHealth } from "../src/ops/health.ts";
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
const { loadMesh } = native;
/// The addon's mesh keeping what it binds (`withRelays`), where this code has it.
const watched = (m: Mesh): Mesh => {
  const withRelays = (native as Record<string, unknown>).withRelays;
  return typeof withRelays === "function" ? (withRelays as (m: Mesh) => Mesh)(m) : m;
};
/// Looked at every 50 ms until it holds or `ms` went by (then the assertion after it says what is wrong): what a relay
/// says comes within a moment on this machine.
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

/// iroh-relay in dev mode (plain HTTP) on this machine: its url, and the process.
async function relay(t: { after(f: () => unknown): void }): Promise<string> {
  const port = await freePort();
  const config = join(tmpdir(), `relay-conflict-${process.pid}-${port}.toml`);
  writeFileSync(config, `enable_relay = true\nhttp_bind_addr = "127.0.0.1:${port}"\nenable_metrics = false\nenable_quic_addr_discovery = false\n`);
  const child: ChildProcess = spawn(RELAY_BIN!, ["--dev", "--config-path", config], { stdio: "ignore" });
  t.after(() => {
    child.kill("SIGKILL");
    rmSync(config, { force: true });
  });
  const url = `http://127.0.0.1:${port}`;
  while (!(await fetch(url).then(() => true, () => false))) await sleep(50);
  return url;
}

/// A station's data directory as `stillfail status` reads it: running (this process), online at the cloud.
function stationData(t: { after(f: () => unknown): void }): string {
  const data = mkdtempSync(join(tmpdir(), "relay-conflict-"));
  t.after(() => rmSync(data, { recursive: true, force: true }));
  mkdirSync(join(data, "run"));
  mkdirSync(join(data, "mesh"));
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin: "https://still.fail", station: "s".repeat(64), workspace: "w1", workspace_name: "Team", name: "mac", key: "k" }));
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: process.pid, startedAt: 1, version: "0.1.2" }));
  writeFileSync(join(data, "run", "presence.json"), JSON.stringify({ online: true, at: 1_700_000_000, error: null }));
  return data;
}

/// What the station writes of itself (main.ts sayHealth), then what `stillfail status` says of it.
async function said(data: string, mesh: Mesh): Promise<string> {
  await writeHealth(data, { pid: process.pid, updatedAt: wall.now(), heldMaxMs: 0, front: mesh.frontLink?.() ?? "direct", presenceOnline: true, relayConflict: mesh.relayConflict?.() === true });
  return status(data).split("\n").at(-1)!;
}

const NORMAL = "工作：正常（已连接 Slack，运行 agent 和任务）";
const CONFLICT = /^工作：异常（另一台机器或进程正在用这个 station 的同一份密钥/;

/// The station's endpoint bound by `mesh` on `url` with `key`, then another of the same key bound by the addon (a
/// front left from before, or another machine with a copy of the key): the first is said in conflict until the other
/// closes.
async function twoOnOneKey(t: { after(f: () => unknown): void }, mesh: Mesh) {
  const url = await relay(t);
  const data = stationData(t);
  const key = randomBytes(32);
  const options = { secretKey: key, alpns: [ALPN], relayUrls: [url], discovery: false, relayOnly: true };
  const station: Endpoint = await mesh.bind(options);
  t.after(() => station.close().catch(() => {}));
  await station.online();
  // Alone on the key: normal (asked a few times: the front's status is read again as it is asked).
  for (let i = 0; i < 5; i++) {
    assert.equal(await said(data, mesh), NORMAL);
    await sleep(100);
  }
  const other = await loadMesh().bind(options);
  await other.online();
  await until(() => mesh.relayConflict?.() === true);
  assert.match(await said(data, mesh), CONFLICT);
  // The other gone: the relay says the station's connection is healthy again.
  await other.close();
  await until(() => mesh.relayConflict?.() === false);
  assert.equal(await said(data, mesh), NORMAL);
}

test("the addon's endpoint held inactive by the relay for another on its key is said in health.json and status, until the other leaves", async (t) => {
  needs();
  await twoOnOneKey(t, watched(loadMesh()));
});

test("so is the MoonBit front's, as the station has it", async (t) => {
  needs();
  const dir = mkdtempSync(join(tmpdir(), "relay-conflict-front-"));
  const socket = join(dir, "front.sock");
  const front = new MbProcess(reader!, ["--builder", "mesh", "--socket", socket, "--shell-dir", join(dir, "shell")]);
  await new Promise<void>((resolve, reject) => {
    front.once("message", (m: { listening?: string }) => (m.listening === socket ? resolve() : reject(new Error(JSON.stringify(m)))));
    front.once("exit", (code: number) => reject(new Error(`ended (${code})`)));
  });
  t.after(async () => {
    await front.terminate();
    rmSync(dir, { recursive: true, force: true });
  });
  await twoOnOneKey(t, withFront(loadMesh(), socket));
});

// Two Nodes binding a fresh front at once (FB-36: a handover's new Node and the old Node's link made again) bind one
// endpoint of the key, never two: with two, the one the front kept was later held inactive by the relay for the other,
// left over, and every station this one dialed answered that other, so no dial of this station's came through.
test("two Nodes binding a fresh MoonBit front at once leave one endpoint of the key on the relay, which dials and is dialed", async (t) => {
  needs();
  const url = await relay(t);
  const data = stationData(t);
  const dir = mkdtempSync(join(tmpdir(), "relay-conflict-race-"));
  const socket = join(dir, "front.sock");
  const front = new MbProcess(reader!, ["--builder", "mesh", "--socket", socket, "--shell-dir", join(dir, "shell")]);
  await new Promise<void>((resolve, reject) => {
    front.once("message", (m: { listening?: string }) => (m.listening === socket ? resolve() : reject(new Error(JSON.stringify(m)))));
    front.once("exit", (code: number) => reject(new Error(`ended (${code})`)));
  });
  t.after(async () => {
    await front.terminate();
    rmSync(dir, { recursive: true, force: true });
  });
  const key = randomBytes(32);
  const options = { secretKey: key, alpns: [ALPN], relayUrls: [url], discovery: false, relayOnly: true };
  const m1 = withFront(loadMesh(), socket);
  const m2 = withFront(loadMesh(), socket);
  const [e1, e2] = await Promise.all([m1.bind(options), m2.bind(options)]);
  t.after(() => e2.close().catch(() => {}));
  assert.deepEqual(e2.sockets(), e1.sockets(), "one endpoint of the key, not two");
  await Promise.all([e1.online(), e2.online()]);
  // The Node before goes, as in a handover.
  await e1.close();
  await until(() => m2.relayConflict?.() === true, 2_000);
  assert.equal(m2.relayConflict?.(), false, "no other endpoint of the key on the relay");
  assert.equal(await said(data, m2), NORMAL);
  // Another station on the same relay: this one dials it, and it dials this one.
  const peer = await loadMesh().bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [url], discovery: false, relayOnly: true });
  t.after(() => peer.close().catch(() => {}));
  await peer.online();
  const comingThere = peer.accept();
  const out = await e2.connect({ id: peer.id(), relays: [url] }, ALPN);
  assert.equal((await comingThere)?.remoteId(), e2.id());
  out.close(0, "");
  const comingHere = e2.accept();
  const back = await peer.connect({ id: e2.id(), relays: [url] }, ALPN);
  assert.equal((await comingHere)?.remoteId(), peer.id());
  back.close(0, "");
});
