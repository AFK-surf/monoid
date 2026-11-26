// The devices attached to a station (devices/, 2026-11-10): kept by their station, each its adder's; a chat reaches one
// on a port of its own station, carried over the mesh to the station it is on (memory-mesh.ts here), only its own
// processes let through, the device's station saying whether the chat may (a whole station: every chat).
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { type AddressInfo, type Server, type Socket, connect, createServer } from "node:net";
import { test } from "node:test";
import { StationKey } from "../src/cloud/key.ts";
import { Cloud } from "../src/cloud/state.ts";
import { AirPlayCredentialStore } from "../src/devices/airplay/credentials.ts";
import { AirPlayPairingManager, commitAirPlayRebind, commitDeviceAdd } from "../src/devices/airplay/pairing.ts";
import { AirPlayControlServer, sendAirPlayAction, sendAirPlayAudio } from "../src/devices/airplay/server.ts";
import { AirPlayError, type AirPlayAdapter, type AirPlayControlAction, type AirPlayCredentials, type AirPlayProtocol } from "../src/devices/airplay/types.ts";
import { PyAtvAdapter, airplayWorkerScript } from "../src/devices/airplay/worker.ts";
import { DeviceRegistry } from "../src/devices/registry.ts";
import { reachDevice } from "../src/devices/connect.ts";
import { reachedAt } from "../src/devices/tool.ts";
import { Forwards } from "../src/mesh/peer-forward.ts";
import { DeviceRefused, PEER_HTTP_ALPN, PeerHttp, peerNamed, serveHttp } from "../src/mesh/peer-http.ts";
import { PEER_ALPN } from "../src/mesh/peer.ts";
import { syncCalls } from "./main-thread-sync.ts";
import { memoryMesh } from "./memory-mesh.ts";

const cloudOf = (station: string, name: string, peers: { id: string; name: string }[]): any =>
  Object.assign(Object.create(Cloud.prototype), {
    state: { workspace: "ws", workspace_name: "ws", name, station, peers, revocations: [], joined: [] },
    lock: null,
    peersCurrent: true,
    listeners: new Set(),
    relays: () => [],
  });

const PAT = { sub: "pat", email: "Pat@Example.com", name: "Pat" };

async function listen(server: Server): Promise<number> {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return (server.address() as AddressInfo).port;
}

/// A device on the network: it answers each line it is sent with the line upper-cased.
async function camera(): Promise<{ port: number; close(): Promise<void> }> {
  const server = createServer((s) => s.on("data", (c: Buffer) => s.write(c.toString().toUpperCase())));
  const port = await listen(server);
  return { port, close: () => new Promise((r) => server.close(() => r())) };
}

/// What 127.0.0.1:`port` answers to `line`, or that it was cut off.
function talk(port: number, line: string): Promise<string> {
  return new Promise((resolve) => {
    const socket: Socket = connect({ host: "127.0.0.1", port });
    let heard = "";
    socket.on("data", (c: Buffer) => {
      heard += c.toString();
      if (heard.length >= line.length) socket.end();
    });
    socket.on("error", () => resolve(`cut: ${heard}`));
    socket.once("connect", () => socket.write(line));
    socket.once("close", () => resolve(heard));
  });
}

test("a device is kept by its station, its adder's, as what it is reached at", () => {
  const registry = new DeviceRegistry(new DatabaseSync(":memory:"));
  const made = registry.add("ws", PAT, { name: "cam", kind: "tcp", target: "192.168.1.20:554" }, 100);
  assert.ok(typeof made !== "string");
  assert.equal(made.owner, "pat");
  assert.equal(made.owner_email, "pat@example.com");
  assert.match(made.id, /^[0-9a-f]{16}$/);
  assert.match(registry.add("ws", PAT, { name: "CAM", kind: "tcp", target: "10.0.0.1:80" }, 101) as string, /named CAM is attached here already/);
  assert.match(registry.add("ws", PAT, { name: "x", kind: "tcp", target: "nohost" }, 101) as string, /host:port/);
  assert.match(registry.add("ws", PAT, { name: "x", kind: "usb", target: "a" }, 101) as string, /kind: adb, tcp, serial, airplay or android_tv/);
  assert.match(registry.add("ws", PAT, { name: "x", kind: "serial", target: "ttyUSB0" }, 101) as string, /its path/);
  assert.match(registry.add("ws", PAT, { name: "x", kind: "serial", target: "/dev/ttyUSB0", baud: 7 }, 101) as string, /baud/);
  assert.ok(typeof registry.add("ws", PAT, { name: "board", kind: "serial", target: "/dev/ttyUSB0", baud: 9600 }, 101) !== "string");
  assert.ok(typeof registry.add("ws", PAT, { name: "pixel", kind: "adb", target: "R5CT1234" }, 102) !== "string");
  assert.deepEqual(registry.of("ws").map((d) => d.name), ["cam", "board", "pixel"]);
  assert.deepEqual(registry.of("other"), []);
  assert.equal(registry.get("other", made.id), null);
  assert.equal(registry.remove("ws", made.id), true);
  assert.deepEqual(registry.of("ws").map((d) => d.name), ["board", "pixel"]);
  // What the agent is told, by kind.
  assert.match(reachedAt({ name: "pixel", kind: "adb", target: "R5CT1234" }, 4000), /adb -P 4000 -s R5CT1234/);
  assert.match(reachedAt({ name: "cam", kind: "tcp", target: "10.0.0.1:554" }, 4000), /127\.0\.0\.1:4000/);
  assert.match(reachedAt({ name: "board", kind: "serial", target: "/dev/ttyUSB0", baud: 9600 }, 4000), /9600 baud/);
  assert.match(reachedAt({ name: "shield", kind: "android_tv", target: "192.168.1.52", protocols: ["atv_remote", "adb"] }, 4000), /adb -P 4000 -s 192\.168\.1\.52:5555/);
  assert.doesNotMatch(reachedAt({ name: "shield", kind: "android_tv", target: "192.168.1.52", protocols: ["atv_remote"] }, 4000), /adb -P/);
});

test("a device on another station: forwarded to a port here, its bytes carried there and back; only the chat's processes let through", async () => {
  const cam = await camera();
  const mesh = memoryMesh({ window: 64 * 1024 });
  const bind = (alpns: Buffer[]) => mesh.bind({ secretKey: randomBytes(32), alpns, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [here, there] = await Promise.all([bind([PEER_HTTP_ALPN, PEER_ALPN]), bind([PEER_HTTP_ALPN, PEER_ALPN])]);
  const roster = [{ id: here.id(), name: "Here" }, { id: there.id(), name: "Studio" }];
  const hereCloud = cloudOf(here.id(), "Here", roster);
  const thereCloud = cloudOf(there.id(), "Studio", roster);
  const registry = new DeviceRegistry(new DatabaseSync(":memory:"));
  const d = registry.add("ws", PAT, { name: "cam", kind: "tcp", target: `127.0.0.1:${cam.port}` }, 1);
  assert.ok(typeof d !== "string");
  const asked: string[] = [];
  void (async () => {
    for (;;) {
      const conn = await there.accept();
      if (!conn) return;
      void serveHttp(conn, thereCloud, {
        device: async (peer, workspace, session, id, probe) => {
          asked.push(`${peer === here.id() ? "here" : peer}/${workspace}/${session}/${id}/${probe}`);
          const kept = registry.get(workspace, id);
          if (kept === null) throw new DeviceRefused(404, "no such device on this station");
          return probe ? null : reachDevice(kept);
        },
      }).catch(() => conn.close(0, "refused"));
    }
  })();
  const http = new PeerHttp(here, hereCloud, (id) => ({ id }));
  const route = { tunnel: (s: string, p: number, probe?: boolean) => http.tunnel(s, p, probe), tunnelDevice: (s: string, dev: string, session: string, probe?: boolean) => http.tunnelDevice(s, dev, session, probe) };
  const forwards = new Forwards({
    route: () => route,
    resolve: (station) => {
      const { id } = peerNamed(hereCloud, station);
      return { id, name: roster.find((p) => p.id === id)!.name };
    },
    holders: async () => [4242],
  });
  try {
    let admitting = true;
    const admitted: number[][] = [];
    const target = { id: d.id, name: "cam", here: null, admit: async (holders: number[]) => (admitted.push(holders), admitting ? null : "this device's port is another chat's") };
    const v = await forwards.openDevice("s1", there.id(), target, false);
    assert.equal(v.device, "cam");
    assert.equal(v.station, "Studio");
    const port = Number(v.local.split(":")[1]);
    assert.deepEqual(asked, [`here/ws/s1/${d.id}/true`]);
    assert.equal(await talk(port, "hello"), "HELLO");
    assert.deepEqual(admitted, [[4242]]);
    // Asked again: the same forward.
    assert.equal((await forwards.openDevice("s1", there.id(), target, false)).note, "already forwarded");
    // Another chat's process: cut off, nothing carried.
    admitting = false;
    assert.match(await talk(port, "hi"), /^(cut: )?$/);
    assert.equal(asked.length, 2);
    // A device that station does not have: refused as it is asked for.
    await assert.rejects(forwards.openDevice("s1", there.id(), { ...target, id: "fedcba9876543210" }, false), /no such device/);
    // Handed back: its port is closed.
    forwards.closeDevice("s1", d.id, "handed back");
    assert.deepEqual(await forwards.list("s1"), []);
  } finally {
    await forwards.close();
    http.close();
    await Promise.all([here.close(), there.close()]);
    await cam.close();
  }
});

test("a device on this station itself: reached with no mesh between", async () => {
  const cam = await camera();
  const forwards = new Forwards({ route: () => null, resolve: (s) => ({ id: s, name: s }) });
  try {
    const v = await forwards.openDevice("s1", "self", { id: "0123456789abcdef", name: "cam", here: () => reachDevice({ id: "0123456789abcdef", name: "cam", kind: "tcp", target: `127.0.0.1:${cam.port}` }), admit: null }, true);
    assert.equal(await talk(Number(v.local.split(":")[1]), "local"), "LOCAL");
    assert.equal((await forwards.list("s1"))[0]!.station_state, "online");
  } finally {
    await forwards.close();
    await cam.close();
  }
});

function fakeAirPlayAdapter() {
  const calls: { method: string; params: unknown }[] = [];
  const cancelled: string[] = [];
  const audioSnapshots: { path: string; bytes: Buffer }[] = [];
  let tokenSeq = 1;
  const tokens = new Map<string, AirPlayProtocol>();
  const adapter: AirPlayAdapter = {
    envStatus: async () => ({ ready: true, python: "/usr/bin/python3", pyatvVersion: "0.16.1" }),
    installEnv: async () => ({ ok: true, pyatvVersion: "0.16.1", python: "/usr/bin/python3" }),
    scan: async (opts) => {
      calls.push({ method: "scan", params: opts });
      return [
        {
          identifier: "AA:BB:CC:DD:EE:FF",
          name: "Living Room TV",
          address: "192.168.1.50",
          model: "Apple TV 4K",
          os: "tvOS 18.0",
          protocols: [
            { protocol: "airplay", pairing: "mandatory" },
            { protocol: "companion", pairing: "mandatory" },
            { protocol: "raop", pairing: "notNeeded" },
          ],
        },
      ];
    },
    pairStart: async (params) => {
      calls.push({ method: "pairStart", params });
      const pairToken = `tok-${tokenSeq++}`;
      tokens.set(pairToken, params.protocol);
      return { pairToken, protocol: params.protocol, deviceProvidesPin: true };
    },
    pairFinish: async (params) => {
      calls.push({ method: "pairFinish", params });
      const proto = tokens.get(params.pairToken);
      if (!proto) throw new AirPlayError("invalid_pair_token", "unknown token");
      tokens.delete(params.pairToken);
      if (params.pin !== "1234") throw new AirPlayError("invalid_pin", "wrong PIN");
      return { credentials: `cred-${proto}-secret`, protocol: proto };
    },
    pairCancel: async (params) => {
      calls.push({ method: "pairCancel", params });
      cancelled.push(params.pairToken);
      tokens.delete(params.pairToken);
    },
    control: async (params) => {
      calls.push({ method: "control", params });
      if (params.action === "stream_audio") {
        const p = String(params.args?.path ?? "");
        audioSnapshots.push({ path: p, bytes: readFileSync(p) });
        return { ok: true, streamedBytes: audioSnapshots.at(-1)!.bytes.length };
      }
      return { ok: true, action: params.action, args: params.args ?? null, hasCreds: Boolean(params.credentials && Object.keys(params.credentials).length > 0) };
    },
    close: async () => {},
  };
  return { adapter, calls, cancelled, audioSnapshots };
}

test("airplay: device validation, updateMeta, and reachedAt formatting", () => {
  const registry = new DeviceRegistry(new DatabaseSync(":memory:"));
  const ok = registry.add("ws", PAT, {
    name: "Living Room TV",
    kind: "airplay",
    target: "AA:BB:CC:DD:EE:FF",
    model: "Apple TV 4K",
    protocols: ["airplay", "companion"],
    paired: true,
  }, 100);
  assert.ok(typeof ok !== "string");
  assert.equal(ok.model, "Apple TV 4K");
  assert.deepEqual(ok.protocols, ["airplay", "companion"]);
  assert.equal(ok.paired, true);
  // Reject invalid airplay targets, duplicate protocols, and bad paired type.
  assert.match(registry.add("ws", PAT, { name: "bad1", kind: "airplay", target: "bad host/path" }, 101) as string, /target/);
  assert.match(registry.add("ws", PAT, { name: "bad2", kind: "airplay", target: "192.168.1.50", protocols: ["airplay", "airplay"] }, 101) as string, /protocols/);
  assert.match(registry.add("ws", PAT, { name: "bad3", kind: "airplay", target: "192.168.1.50", paired: "yes" }, 101) as string, /paired/);
  // updateMeta persists new protocols/paired state.
  const updated = registry.updateMeta("ws", ok.id, { protocols: ["airplay", "companion", "raop"], paired: true });
  assert.ok(updated !== null && typeof updated !== "string");
  assert.deepEqual(registry.get("ws", ok.id)?.protocols, ["airplay", "companion", "raop"]);
  // reachedAt mentions device_control and /action endpoint.
  const guide = reachedAt({ name: "Living Room TV", kind: "airplay", target: "AA:BB:CC:DD:EE:FF" }, 4123);
  assert.match(guide, /device_control/);
  assert.match(guide, /127\.0\.0\.1:4123\/action/);
});

test("airplay credentials: AES-256-GCM encryption, AAD binding, atomic delete, zero main-thread sync IO", async () => {
  const dir = mkdtempSync(join(tmpdir(), "airplay-creds-"));
  try {
    const key = new StationKey(randomBytes(32));
    const store = new AirPlayCredentialStore(dir, key);
    const id = "0123456789abcdef";
    const creds: AirPlayCredentials = { airplay: "ap-secret-1", companion: "comp-secret-2" };

    // Verify zero synchronous fs calls on main thread during set, get, and delete.
    let readBack: AirPlayCredentials | null = null;
    assert.deepEqual(await syncCalls(async () => {
      await store.set("ws-a", id, creds);
      readBack = await store.get("ws-a", id);
    }), []);
    assert.deepEqual(readBack, creds);

    const encPath = join(dir, "devices", "credentials", `${id}.enc`);
    const raw = readFileSync(encPath, "utf8");
    assert.equal(raw.includes("ap-secret-1"), false, "ciphertext must not contain plaintext secret");
    if (process.platform !== "win32") {
      assert.equal(statSync(encPath).mode & 0o777, 0o600);
    }

    // Wrong workspace AAD fails decryption.
    await assert.rejects(store.get("ws-b", id));
    // Path traversal id rejected.
    await assert.rejects(store.get("ws-a", "../escape"), /invalid device id/);

    // Delete erases the .enc file off main thread.
    assert.deepEqual(await syncCalls(async () => {
      await store.delete("ws-a", id);
    }), []);
    assert.equal(existsSync(encPath), false);
    assert.equal(await store.get("ws-a", id), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("airplay pairing: multi-protocol PIN flow, skip, cancel, TTL expiry, no-pairing shortcut", async () => {
  const fake = fakeAirPlayAdapter();
  const mgr = new AirPlayPairingManager(fake.adapter, { ttlMs: 80 });
  try {
    // 1. Multi-protocol pairing: airplay (PIN) -> companion (skip) -> done.
    const s1 = await mgr.start({ ws: "ws", identifier: "AA:BB:CC:DD:EE:FF", address: "192.168.1.50", name: "ATV", model: "Apple TV 4K", protocols: ["airplay", "companion"] });
    assert.equal(s1.done, false);
    assert.equal(s1.step, 1);
    assert.equal(s1.total, 2);
    assert.equal(s1.protocol, "airplay");

    // Wrong PIN fails without advancing.
    await assert.rejects(mgr.finish("ws", s1.pairId, { pin: "9999" }), /wrong PIN/);
    // Correct PIN completes step 1 and starts step 2 (companion).
    const s2 = await mgr.finish("ws", s1.pairId, { pin: "1234" });
    assert.equal(s2.done, false);
    assert.equal(s2.step, 2);
    assert.equal(s2.protocol, "companion");

    // Skip step 2 -> cancels companion token and completes session.
    const s3 = await mgr.finish("ws", s1.pairId, { skip: true });
    assert.equal(s3.done, true);
    assert.deepEqual(s3.pairedProtocols, ["airplay"]);
    assert.equal(fake.cancelled.length, 1);

    // Atomic takeCredentials works once and clears memory.
    const taken = mgr.takeCredentials("ws", s1.pairId);
    assert.ok(taken !== null);
    assert.deepEqual(taken.credentials, { airplay: "cred-airplay-secret" });
    assert.equal(mgr.takeCredentials("ws", s1.pairId), null);

    // 2. No-pairing-needed device completes immediately.
    const direct = await mgr.start({ ws: "ws", identifier: "192.168.1.60", protocols: [] });
    assert.equal(direct.done, true);
    const takenDirect = mgr.takeCredentials("ws", direct.pairId);
    assert.ok(takenDirect !== null);
    assert.deepEqual(takenDirect.credentials, {});

    // 3. Explicit cancel calls pairCancel.
    const c1 = await mgr.start({ ws: "ws", identifier: "192.168.1.61", protocols: ["airplay"] });
    assert.equal(c1.done, false);
    const cancelsBefore = fake.cancelled.length;
    await mgr.cancel("ws", c1.pairId);
    assert.equal(fake.cancelled.length, cancelsBefore + 1);

    // 4. TTL expiry auto-cancels and dismisses TV PIN dialog.
    const t1 = await mgr.start({ ws: "ws", identifier: "192.168.1.62", protocols: ["companion"] });
    assert.equal(t1.done, false);
    const cancelsBeforeTtl = fake.cancelled.length;
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(fake.cancelled.length, cancelsBeforeTtl + 1);
    await assert.rejects(mgr.finish("ws", t1.pairId, { pin: "1234" }), /not found or expired/);
  } finally {
    await mgr.close();
  }
});

test("airplay over cross-station mesh: zero-port Duplex control server, all standard actions, stream_audio upload & temp cleanup", async () => {
  const dir = mkdtempSync(join(tmpdir(), "airplay-mesh-"));
  const key = new StationKey(randomBytes(32));
  const credStore = new AirPlayCredentialStore(dir, key);
  const fake = fakeAirPlayAdapter();
  const airplayServer = new AirPlayControlServer(fake.adapter, credStore);

  const mesh = memoryMesh({ window: 64 * 1024 });
  const bind = (alpns: Buffer[]) => mesh.bind({ secretKey: randomBytes(32), alpns, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [here, there] = await Promise.all([bind([PEER_HTTP_ALPN, PEER_ALPN]), bind([PEER_HTTP_ALPN, PEER_ALPN])]);
  const roster = [{ id: here.id(), name: "Here" }, { id: there.id(), name: "LivingRoomHost" }];
  const hereCloud = cloudOf(here.id(), "Here", roster);
  const thereCloud = cloudOf(there.id(), "LivingRoomHost", roster);
  const registry = new DeviceRegistry(new DatabaseSync(":memory:"));
  const dev = registry.add("ws", PAT, { name: "AppleTV", kind: "airplay", target: "AA:BB:CC:DD:EE:FF", model: "Apple TV 4K", protocols: ["airplay", "companion", "raop"], paired: true }, 1);
  assert.ok(typeof dev !== "string");
  await credStore.set("ws", dev.id, { airplay: "secret-ap", companion: "secret-cp" });

  void (async () => {
    for (;;) {
      const conn = await there.accept();
      if (!conn) return;
      void serveHttp(conn, thereCloud, {
        device: async (_peer, workspace, _session, id, probe) => {
          const kept = registry.get(workspace, id);
          if (kept === null) throw new DeviceRefused(404, "no such device on this station");
          return probe ? null : reachDevice(kept, airplayServer);
        },
      }).catch(() => conn.close(0, "refused"));
    }
  })();

  const http = new PeerHttp(here, hereCloud, (id) => ({ id }));
  const route = { tunnel: (s: string, p: number, probe?: boolean) => http.tunnel(s, p, probe), tunnelDevice: (s: string, d: string, session: string, probe?: boolean) => http.tunnelDevice(s, d, session, probe) };
  const forwards = new Forwards({
    route: () => route,
    resolve: (station) => {
      const { id } = peerNamed(hereCloud, station);
      return { id, name: roster.find((p) => p.id === id)!.name };
    },
  });

  try {
    const v = await forwards.openDevice("s1", there.id(), { id: dev.id, name: dev.name, here: null, admit: null }, false);
    const port = Number(v.local.split(":")[1]);
    assert.equal(forwards.devicePort("s1", dev.id), port);

    const actions: [AirPlayControlAction, Record<string, unknown> | undefined][] = [
      ["status", undefined],
      ["power", { state: "on" }],
      ["remote", { key: "play_pause", press: "single", repeat: 1 }],
      ["apps", undefined],
      ["launch", { app: "com.apple.TVWatchList" }],
      ["playing", undefined],
      ["seek", { position: 42 }],
      ["volume", { level: 35 }],
      ["keyboard", { text: "hello", action: "set" }],
      ["play_url", { url: "https://example.com/video.m3u8" }],
    ];
    for (const [action, args] of actions) {
      const res = (await sendAirPlayAction(port, action, args)) as { ok: boolean; action: string; hasCreds: boolean };
      assert.equal(res.ok, true, action);
      assert.equal(res.action, action);
      assert.equal(res.hasCreds, true, "stored credentials injected on host");
    }

    // Security: stream_audio must be rejected on POST /action so arbitrary host paths cannot be read.
    await assert.rejects(sendAirPlayAction(port, "stream_audio", { path: "/etc/passwd" }), /stream-audio/);

    // Audio streaming over mesh tunnel -> host temp file -> RAOP stream_file -> temp file deleted immediately.
    const localAudio = join(dir, "chime.mp3");
    const audioPayload = Buffer.from("ID3-fake-mp3-audio-payload-1234567890");
    writeFileSync(localAudio, audioPayload);
    const streamRes = (await sendAirPlayAudio(port, localAudio)) as { ok: boolean; streamedBytes: number };
    assert.equal(streamRes.ok, true);
    assert.equal(streamRes.streamedBytes, audioPayload.length);
    assert.equal(fake.audioSnapshots.length, 1);
    assert.deepEqual(fake.audioSnapshots[0]!.bytes, audioPayload);
    assert.equal(existsSync(fake.audioSnapshots[0]!.path), false, "host temp audio file must be unlinked after streaming");
  } finally {
    airplayServer.close();
    await forwards.close();
    http.close();
    await Promise.all([here.close(), there.close()]);
    rmSync(dir, { recursive: true, force: true });
  }
});

test("airplay-worker.py: NDJSON JSON-RPC protocol with mock pyatv and pyatv_missing handling", { skip: process.platform === "win32" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "airplay-py-"));
  try {
    // Write a minimal mock pyatv package so we can test the real Python worker end-to-end.
    const pkg = join(dir, "pyatv");
    mkdirSync(pkg, { recursive: true });
    writeFileSync(join(pkg, "const.py"), `
from enum import Enum
__version__ = "0.16.99-mock"
class Protocol(Enum):
    AirPlay = 1
    Companion = 2
    RAOP = 3
class PairingRequirement(Enum):
    Mandatory = 1
    Optional = 2
    NotNeeded = 3
    Unsupported = 4
    Disabled = 5
class InputAction(Enum):
    SingleTap = 0
    DoubleTap = 1
    Hold = 2
class FeatureState(Enum):
    Available = 1
    Unavailable = 2
`);
    writeFileSync(join(pkg, "exceptions.py"), `
class AuthenticationError(Exception):
    pass
class NotSupportedError(Exception):
    pass
`);
    writeFileSync(join(pkg, "__init__.py"), `
from types import SimpleNamespace
from . import const, exceptions

class _FakeService:
    def __init__(self, protocol, pairing):
        self.protocol = protocol
        self.pairing = pairing
        self.credentials = None

class _FakeConfig:
    def __init__(self):
        self.identifier = "AA:BB:CC:DD:EE:FF"
        self.all_identifiers = [self.identifier]
        self.name = "Mock Apple TV"
        self.address = "192.168.1.99"
        self.services = [
            _FakeService(const.Protocol.AirPlay, const.PairingRequirement.Mandatory),
            _FakeService(const.Protocol.Companion, const.PairingRequirement.Mandatory),
            _FakeService(const.Protocol.RAOP, const.PairingRequirement.NotNeeded),
        ]
        self.device_info = SimpleNamespace(model_str="Apple TV 4K", model="AppleTV4K", operating_system="tvOS", version="18.0")
        self.creds = {}
    def set_credentials(self, proto, cred):
        self.creds[proto] = cred

class _FakePairing:
    def __init__(self, proto):
        self.device_provides_pin = True
        self._pin = None
        self.has_paired = False
        self.service = SimpleNamespace(credentials=f"mock-cred-{proto.name}")
    async def begin(self):
        pass
    def pin(self, pin):
        self._pin = pin
    async def finish(self):
        if self._pin != "4321":
            raise exceptions.AuthenticationError("bad pin")
        self.has_paired = True
    async def close(self):
        pass

class _FakeATV:
    def __init__(self):
        self.power = SimpleNamespace(power_state=SimpleNamespace(name="On"), turn_on=self._noop, turn_off=self._noop)
        self.metadata = SimpleNamespace(
            app=SimpleNamespace(name="TV", identifier="com.apple.TVWatchList"),
            playing=self._playing,
        )
        self.features = SimpleNamespace(all_features=lambda: {"Play": SimpleNamespace(state=const.FeatureState.Available)})
        self.remote_control = SimpleNamespace(
            play_pause=self._noop, volume_up=self._noop, set_position=self._noop
        )
        self.apps = SimpleNamespace(app_list=self._apps, launch_app=self._noop)
        self.audio = SimpleNamespace(volume=40.0, set_volume=self._noop)
        self.keyboard = SimpleNamespace(text_set=self._noop, text_append=self._noop, text_clear=self._noop)
        self.stream = SimpleNamespace(play_url=self._noop, stream_file=self._noop)
    async def _noop(self, *args, **kwargs):
        return None
    async def _playing(self):
        return SimpleNamespace(title="Demo", artist="Artist", album="Album", media_type=SimpleNamespace(name="Video"), device_state=SimpleNamespace(name="Playing"), position=12, total_time=120)
    async def _apps(self):
        return [SimpleNamespace(name="YouTube", identifier="com.google.ios.youtube")]
    def close(self):
        pass

async def scan(loop, **kwargs):
    return [_FakeConfig()]

async def pair(config, proto, loop):
    return _FakePairing(proto)

async def connect(config, loop):
    return _FakeATV()
`);

    const runRpc = async (env: NodeJS.ProcessEnv, requests: Record<string, unknown>[]) => {
      const child = spawn("python3", ["-u", airplayWorkerScript()], { env, stdio: ["pipe", "pipe", "pipe"] });
      const lines: any[] = [];
      let buf = "";
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => {
        buf += chunk;
        for (;;) {
          const nl = buf.indexOf("\n");
          if (nl === -1) break;
          const line = buf.slice(0, nl).trim();
          buf = buf.slice(nl + 1);
          if (line) lines.push(JSON.parse(line));
        }
      });
      for (const req of requests) child.stdin.write(`${JSON.stringify(req)}\n`);
      child.stdin.end();
      const code = await new Promise<number | null>((resolve) => child.once("close", resolve));
      return { code, lines };
    };

    const res = await runRpc({ ...process.env, PYTHONPATH: dir }, [
      { id: 1, method: "ping", params: {} },
      { id: 2, method: "scan", params: { timeoutMs: 1000 } },
      { id: 3, method: "pair_start", params: { identifier: "AA:BB:CC:DD:EE:FF", protocol: "airplay" } },
    ]);
    assert.equal(res.code, 0);
    assert.equal(res.lines[0].ok, true);
    assert.equal(res.lines[0].result.pyatvVersion, "0.16.99-mock");
    assert.equal(res.lines[1].result[0].identifier, "AA:BB:CC:DD:EE:FF");
    assert.equal(res.lines[2].ok, true);
    assert.equal(res.lines[2].result.deviceProvidesPin, true);

    // Control actions round-trip.
    const ctrl = await runRpc({ ...process.env, PYTHONPATH: dir }, [
      { id: 10, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "status" } },
      { id: 11, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "remote", args: { key: "play_pause", press: "single" } } },
      { id: 12, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "apps" } },
      { id: 13, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "launch", args: { app: "YouTube" } } },
      { id: 14, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "playing" } },
      { id: 15, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "volume", args: { level: 50 } } },
      { id: 16, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "play_url", args: { url: "https://example.com/a.mp4" } } },
    ]);
    assert.equal(ctrl.code, 0);
    for (const row of ctrl.lines) assert.equal(row.ok, true, JSON.stringify(row));
    assert.equal(ctrl.lines[0].result.model, "Apple TV 4K");
    assert.equal(ctrl.lines[3].result.app, "com.google.ios.youtube");
    assert.equal(ctrl.lines[4].result.title, "Demo");

    // Regression #4: long-running stream_audio must NOT block concurrent control requests (e.g. volume).
    writeFileSync(join(pkg, "__init__.py"), readFileSync(join(pkg, "__init__.py"), "utf8").replace(
      "self.stream = SimpleNamespace(play_url=self._noop, stream_file=self._noop)",
      "self.stream = SimpleNamespace(play_url=self._noop, stream_file=self._slow_stream)",
    ) + `
import asyncio as _asyncio
async def _slow_stream(self, path):
    await _asyncio.sleep(0.35)
_FakeATV._slow_stream = _slow_stream
`);
    const conc = await runRpc({ ...process.env, PYTHONPATH: dir }, [
      { id: 20, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "stream_audio", args: { path: "/tmp/a.mp3" } } },
      { id: 21, method: "control", params: { identifier: "AA:BB:CC:DD:EE:FF", action: "volume", args: { level: 25 } } },
    ]);
    assert.equal(conc.code, 0);
    assert.equal(conc.lines.length, 2);
    assert.equal(conc.lines[0].id, 21, "fast volume request must complete before slow stream_audio");
    assert.equal(conc.lines[1].id, 20);
    assert.equal(conc.lines[0].ok, true);
    assert.equal(conc.lines[1].ok, true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("airplay regression #1 & #2: duplicate name preserves pairId for retry; rebind validates target and rejects empty credentials", async () => {
  const dir = mkdtempSync(join(tmpdir(), "airplay-commit-"));
  const key = new StationKey(randomBytes(32));
  const credStore = new AirPlayCredentialStore(dir, key);
  const registry = new DeviceRegistry(new DatabaseSync(":memory:"));
  const fake = fakeAirPlayAdapter();
  const pairing = new AirPlayPairingManager(fake.adapter);
  try {
    // Existing device occupies name "Living Room".
    const existing = registry.add("ws", PAT, { name: "Living Room", kind: "tcp", target: "10.0.0.1:80" }, 10);
    assert.ok(typeof existing !== "string");

    // Complete pairing for Apple TV.
    const started = await pairing.start({ ws: "ws", identifier: "AA:BB:CC:DD:EE:FF", address: "192.168.1.50", model: "Apple TV 4K", protocols: ["airplay"] });
    assert.equal(started.done, false);
    const done = await pairing.finish("ws", started.pairId, { pin: "1234" });
    assert.equal(done.done, true);

    // First add fails with duplicate name -> pairId must NOT be consumed.
    const dup = await commitDeviceAdd(registry, pairing, credStore, "ws", PAT, { name: "Living Room", kind: "airplay", target: "AA:BB:CC:DD:EE:FF", pairId: started.pairId }, 11);
    assert.equal(dup.ok, false);
    assert.equal(dup.status, 422);

    // Retry with a different name reuses the same pairId and succeeds.
    const added = await commitDeviceAdd(registry, pairing, credStore, "ws", PAT, { name: "Living Room TV", kind: "airplay", target: "AA:BB:CC:DD:EE:FF", pairId: started.pairId }, 12);
    assert.equal(added.ok, true);
    assert.deepEqual(await credStore.get("ws", added.device.id), { airplay: "cred-airplay-secret" });
    // Now pairId is consumed.
    assert.equal(pairing.peekCredentials("ws", started.pairId), null);

    // Rebind #2a: mismatched device target is rejected with 422 and keeps old creds.
    const wrongStart = await pairing.start({ ws: "ws", identifier: "11:22:33:44:55:66", address: "192.168.1.99", protocols: ["companion"] });
    assert.equal(wrongStart.done, false);
    await pairing.finish("ws", wrongStart.pairId, { pin: "1234" });
    const wrongRebind = await commitAirPlayRebind(registry, pairing, credStore, "ws", added.device.id, wrongStart.pairId);
    assert.equal(wrongRebind.ok, false);
    assert.equal(wrongRebind.status, 422);
    assert.match(wrongRebind.message, /does not match/);
    assert.deepEqual(await credStore.get("ws", added.device.id), { airplay: "cred-airplay-secret" });

    // Rebind #2b: skipping all protocols (empty credentials) is rejected with 422 and keeps old creds intact.
    const skipStart = await pairing.start({ ws: "ws", identifier: "AA:BB:CC:DD:EE:FF", address: "192.168.1.50", protocols: ["companion"] });
    assert.equal(skipStart.done, false);
    await pairing.finish("ws", skipStart.pairId, { skip: true });
    const emptyRebind = await commitAirPlayRebind(registry, pairing, credStore, "ws", added.device.id, skipStart.pairId);
    assert.equal(emptyRebind.ok, false);
    assert.equal(emptyRebind.status, 422);
    assert.match(emptyRebind.message, /no credentials/);
    assert.deepEqual(await credStore.get("ws", added.device.id), { airplay: "cred-airplay-secret" });
    assert.equal(registry.get("ws", added.device.id)?.paired, true);

    // Rebind with matching target and valid credentials succeeds and replaces stored creds.
    const okStart = await pairing.start({ ws: "ws", identifier: "AA:BB:CC:DD:EE:FF", address: "192.168.1.50", protocols: ["companion"] });
    assert.equal(okStart.done, false);
    await pairing.finish("ws", okStart.pairId, { pin: "1234" });
    const okRebind = await commitAirPlayRebind(registry, pairing, credStore, "ws", added.device.id, okStart.pairId);
    assert.equal(okRebind.ok, true);
    assert.deepEqual(await credStore.get("ws", added.device.id), { companion: "cred-companion-secret" });
    assert.deepEqual(okRebind.device.protocols, ["companion"]);
  } finally {
    await pairing.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("airplay regression #3: PyAtvAdapter concurrent cold start spawns exactly one Python worker process", { skip: process.platform === "win32" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "airplay-singleflight-"));
  const pidLog = join(dir, "pids.txt");
  const script = join(dir, "fake-worker.py");
  writeFileSync(script, `
import json, os, sys
with open(${JSON.stringify(pidLog)}, "a") as f:
    f.write(f"{os.getpid()}\\n")
for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    req = json.loads(line)
    sys.stdout.write(json.dumps({"id": req["id"], "ok": True, "result": {"pid": os.getpid()}}) + "\\n")
    sys.stdout.flush()
`);
  const adapter = new PyAtvAdapter({
    dataDir: dir,
    script,
    detectEnv: async () => {
      await new Promise((r) => setTimeout(r, 40));
      return { ready: true, python: "python3", pyatvVersion: "0.16.1" };
    },
  });
  try {
    const results = await Promise.all([
      adapter.scan({ timeoutMs: 500 }),
      adapter.scan({ timeoutMs: 500 }),
      adapter.scan({ timeoutMs: 500 }),
    ]);
    const pids = readFileSync(pidLog, "utf8").trim().split("\n").filter(Boolean);
    assert.equal(pids.length, 1, `expected exactly 1 spawned worker, got ${pids.length}: ${pids.join(",")}`);
    assert.equal(results.length, 3);
  } finally {
    await adapter.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
