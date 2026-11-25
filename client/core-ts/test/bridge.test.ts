// The core on a shell's bridge (hosts/bridge.ts), the shell here in JavaScript (node-shell.ts) as the Android app's is
// in C++ and Rust: storage, the database, still.fail cloud over HTTP and its WebSocket, and the mesh to a station.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { Effect, Fiber } from "effect";
import { FakeCloud } from "../harness/cloud.ts";
import { apply } from "../src/delta.ts";
import { Bridge, BridgeHost, bridgeIroh, startBridged } from "../src/hosts/bridge.ts";
import { ACCESS_CACHE_MS, createAccessCache } from "../src/iroh-access.ts";
import { loadAddon } from "../src/hosts/node-iroh.ts";
import { holdLanguage } from "../src/i18n.ts";
import { Mesh } from "../src/mesh.ts";
import { STATION_MESH } from "../src/station/mesh-wire.ts";
import { Runner } from "../src/runtime.ts";
import { FakeHost } from "../src/testing.ts";
import { Tracer } from "../src/trace.ts";
import { Wakes } from "../src/wake.ts";
import { Station } from "./mesh-station.ts";
import { NodeShell } from "./node-shell.ts";
import { run } from "./run.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;
const bytes = (s: string) => new TextEncoder().encode(s);
const text = (b: Uint8Array | null) => (b === null ? null : new TextDecoder().decode(b));

function shell() {
  const dir = mkdtempSync(join(tmpdir(), "bridge-"));
  const native = new NodeShell(dir);
  const bridge = new Bridge(native);
  native.bridge = bridge;
  return { dir, native, bridge, host: new BridgeHost(bridge, "http://127.0.0.1:1", false) };
}

test("an_app_wall_clock_uses_whole_milliseconds_but_the_monotonic_clock_keeps_its_precision", () => {
  const { dir, native, host } = shell();
  native.now = () => 1_793_585_377_985.439;
  native.monotonic = () => 123.456;
  try {
    assert.equal(host.nowMs(), 1_793_585_377_985);
    assert.equal(host.monotonicMs(), 123.456);
  } finally {
    native.host.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("interrupting_a_fetch_cancels_that_native_request", async () => {
  const { dir, native, bridge } = shell();
  const pending: number[] = [];
  const cancelled: number[] = [];
  native.call = (id) => { pending.push(id); };
  native.callSync = (op, json) => {
    assert.equal(op, "fetch.cancel");
    cancelled.push(JSON.parse(json).id);
    return '{"value":true}';
  };
  try {
    const first = Effect.runFork(bridge.call("fetch", {}));
    const second = Effect.runFork(bridge.call("fetch", {}));
    await run(Fiber.interrupt(first));
    assert.deepEqual(cancelled, [pending[0]]);
    // A late answer to the cancelled call is harmless; the other call still gets its own answer.
    bridge.complete(pending[0]!, '{"status":200}', null, null);
    bridge.complete(pending[1]!, '{"status":201}', null, null);
    assert.deepEqual((await run(Fiber.join(second))).json, { status: 201 });
    assert.deepEqual(cancelled, [pending[0]], "completed requests must not be cancelled");
  } finally {
    native.host.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("interrupting_an_in_flight_iroh_bind_closes_its_handle_when_it_completes_later", async () => {
  const { dir, native, bridge } = shell();
  const sent: { id: number; op: string; json: J }[] = [];
  native.call = (id, op, json) => {
    sent.push({ id, op, json: JSON.parse(json) });
  };
  try {
    const orphaned = Effect.runFork(bridge.call("iroh.bind", { relayUrls: [] }));
    const orphanedErr = Effect.runFork(bridge.call("iroh.bind", { relayUrls: [] }));
    const normal = Effect.runFork(bridge.call("iroh.bind", { relayUrls: [] }));
    assert.equal(sent.length, 3);
    const [bind1, bind2, bind3] = sent;

    await run(Fiber.interrupt(orphaned));
    await run(Fiber.interrupt(orphanedErr));

    // Late success for an interrupted iroh.bind must immediately close and forget its handle.
    bridge.complete(bind1!.id, JSON.stringify({ id: 42 }), null, null);
    // Late failure for an interrupted iroh.bind has no handle to close.
    bridge.complete(bind2!.id, null, "bind failed", null);
    // Normal completion must not trigger an automatic close.
    bridge.complete(bind3!.id, JSON.stringify({ id: 43 }), null, null);

    assert.deepEqual((await run(Fiber.join(normal))).json, { id: 43 });
    const closes = sent.filter((c) => c.op === "iroh.close");
    assert.deepEqual(closes.map((c) => c.json), [{ id: 42, forget: true }]);
  } finally {
    native.host.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("secureGetMany_unpacks_sizes_and_bytes_and_falls_back_on_unsupported", async () => {
  const { dir, native, bridge, host } = shell();
  const a = new Uint8Array(32).fill(0x11);
  const c = new Uint8Array(32).fill(0x33);
  const combined = new Uint8Array(64);
  combined.set(a, 0);
  combined.set(c, 32);
  const seen: { op: string; json: J }[] = [];
  native.call = (id, op, json) => {
    const parsed = JSON.parse(json);
    seen.push({ op, json: parsed });
    if (op === "secure.getMany") {
      bridge.complete(id, JSON.stringify({ sizes: [32, -1, 32] }), null, combined);
    } else {
      bridge.complete(id, null, "unexpected", null);
    }
  };
  try {
    const got = await run(host.secureGetMany(["k1", "k2", "k3"], { user: true, reason: "pair" }));
    assert.equal(got.length, 3);
    assert.deepEqual(got[0], a);
    assert.equal(got[1], null);
    assert.deepEqual(got[2], c);
    assert.deepEqual(seen, [{ op: "secure.getMany", json: { keys: ["k1", "k2", "k3"], user: true, reason: "pair" } }]);

    // Legacy host returning "unsupported" falls back to sequential secure.get calls.
    seen.length = 0;
    native.call = (id, op, json) => {
      const parsed = JSON.parse(json);
      seen.push({ op, json: parsed });
      if (op === "secure.getMany") {
        bridge.complete(id, null, "unsupported", null);
      } else if (op === "secure.get") {
        if (parsed.key === "k1") bridge.complete(id, "{}", null, a);
        else if (parsed.key === "k3") bridge.complete(id, "{}", null, c);
        else bridge.complete(id, '{"none":true}', null, null);
      } else {
        bridge.complete(id, null, "unexpected", null);
      }
    };
    const fallback = await run(host.secureGetMany(["k1", "k2", "k3"], { user: true, reason: "pair" }));
    assert.deepEqual(fallback, [a, null, c]);
    assert.deepEqual(seen.map((s) => s.op), ["secure.getMany", "secure.get", "secure.get", "secure.get"]);
  } finally {
    native.host.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("storage_and_the_database_go_through_the_bridge", async () => {
  const { dir, host, native } = shell();
  assert.equal(await run(host.storageGet("accounts")), null);
  await run(host.storageSet("accounts", bytes("[1]")));
  assert.equal(text(await run(host.storageGet("accounts"))), "[1]");
  await run(host.storageDelete("accounts"));
  assert.equal(await run(host.storageGet("accounts")), null);
  // The former records store: only read, through the bridge.
  {
    const db = new DatabaseSync(join(dir, "core.db"));
    db.exec("CREATE TABLE records (tbl TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY (tbl, key)) WITHOUT ROWID");
    for (const [k, v] of [["s\u0001a", "1"], ["s\u0001c", ""], ["t\u0001a", "333"]]) db.prepare("INSERT INTO records VALUES ('row', ?, ?)").run(k, bytes(v));
    db.close();
  }
  const rows = await run(host.legacyRead({ table: "row", from: "s\u0001", to: "s\u0002" }));
  assert.deepEqual(rows.map(([k, v]) => [k, text(v)]), [["s\u0001a", "1"], ["s\u0001c", ""]]);
  // An account's database: SQLite in the shell, asked synchronously (beside the storage keys' files, `accounts` one).
  await run(host.storageSet("accounts", bytes("[]")));
  const sql = await run(host.openDb("account-a"));
  sql.exec("CREATE TABLE t (k TEXT PRIMARY KEY, n INTEGER, j TEXT)");
  assert.equal(sql.run("INSERT INTO t VALUES (?, ?, ?)", ["a", 1, '{"x":"中"}']), 1);
  assert.deepEqual(sql.all("SELECT k, n, j FROM t", []), [["a", 1, '{"x":"中"}']]);
  assert.throws(() => sql.run("INSERT INTO t VALUES (?, 2, null)", ["a"]), /UNIQUE/);
  sql.close();
  await run(host.deleteDb("account-a"));
  assert.deepEqual(native.calls.slice(0, 3), ["storage.get", "storage.set", "storage.get"]);
  native.host.close();
  rmSync(dir, { recursive: true, force: true });
});

test("a_core_on_the_bridge_signs_in_and_hears_the_cloud", async () => {
  const cloud = new FakeCloud();
  // A port of its own: another run of these tests at once on this machine has its cloud too.
  await cloud.listen(0);
  const dir = mkdtempSync(join(tmpdir(), "bridge-core-"));
  const native = new NodeShell(dir);
  const fatal: string[] = [];
  const core = startBridged(native, `http://127.0.0.1:${cloud.port()}`, false, "android", (r) => fatal.push(r));
  native.bridge = core.bridge;
  const client = core.connect();
  const states = new Map<number, unknown>();
  const answers = new Map<number, J>();
  const read = () => {
    for (const [, json] of native.emitted.splice(0)) {
      const m = JSON.parse(json);
      if ("value" in m) states.set(m.id, m.value);
      else if ("delta" in m) states.set(m.id, apply(states.get(m.id), m.delta));
      else if ("ok" in m || "error" in m) answers.set(m.id, m.ok ?? m.error);
    }
  };
  // What the core emits, read as it comes until it says so: no deadline, only the test's own timeout for a hang.
  const until = async (done: () => boolean) => {
    for (read(); !done(); read()) await native.heard();
  };
  core.receive(client, JSON.stringify({ id: 1, subscribe: { topic: "accounts" } }));
  core.receive(client, JSON.stringify({ id: 50, call: "auth.begin", params: { redirect_uri: "stillfail://auth/callback", return_to: "/" } }));
  await until(() => answers.has(50));
  const state = new URL(String(answers.get(50).url)).searchParams.get("state");
  core.receive(client, JSON.stringify({ id: 51, call: "auth.complete", params: { query: `?code=code-alice&state=${state}` } }));
  core.receive(client, JSON.stringify({ id: 2, subscribe: { topic: "workspace", workspace: "ws1" } }));
  await until(() => (states.get(2) as J)?.name === "研发");
  assert.deepEqual((states.get(1) as J[]).map((a) => a.email), ["alice@x.test"]);
  // The events socket is open through the bridge: a rename the cloud tells of comes in.
  await cloud.socketOpen();
  cloud.workspaces.get("ws1")!.name = "研发部";
  cloud.push({ type: "workspace", id: "ws1" });
  await until(() => (states.get(2) as J)?.name === "研发部");
  assert.equal((states.get(2) as J).name, "研发部");
  assert.deepEqual(fatal, []);
  for (const op of ["storage.get", "db.read", "fetch", "ws.open", "ws.next"]) assert.ok(native.calls.includes(op), op);
  await cloud.close();
  native.host.close();
  rmSync(dir, { recursive: true, force: true });
});

test("a_file_picked_in_the_app_is_read_from_there_as_it_goes_up", async (t) => {
  // Hermes has no Blob (2026-10-22: every file picked on the phone failed at composer.add).
  const blob = Object.getOwnPropertyDescriptor(globalThis, "Blob")!;
  delete (globalThis as { Blob?: unknown }).Blob;
  t.after(() => Object.defineProperty(globalThis, "Blob", blob));
  const dir = mkdtempSync(join(tmpdir(), "bridge-picked-"));
  const native = new NodeShell(dir);
  const core = startBridged(native, "http://127.0.0.1:1", false, "android", () => {});
  native.bridge = core.bridge;
  native.picked.set(7, bytes("abc"));
  const client = core.connect();
  const states = new Map<number, J>();
  const read = () => {
    for (const [, json] of native.emitted.splice(0)) {
      const m = JSON.parse(json);
      if ("value" in m) states.set(m.id, m.value);
      else if ("delta" in m) states.set(m.id, apply(states.get(m.id), m.delta));
      else if ("error" in m) errors.set(m.id, m.error);
    }
  };
  const errors = new Map<number, J>();
  const until = async (done: () => boolean) => {
    for (read(); !done(); read()) await native.heard();
  };
  core.receive(client, JSON.stringify({ id: 1, subscribe: { topic: "composer", key: "phone-1" } }));
  // A picture: its size is read from its head too.
  core.receive(client, JSON.stringify({ id: 2, call: "composer.add", params: { key: "phone-1", station: "ws/st", files: [{ id: "f1", name: "a.png", size: 3, blob: { hostFile: 7, size: 3, type: "image/png" } }] } }));
  // No such station here: it fails once its first part is read from the app.
  await until(() => errors.has(2) || states.get(1)?.files?.[0]?.error != null);
  assert.equal(errors.get(2), undefined);
  // Named first (the station may have it already), read from the app as it goes (a picture's head before, for its size).
  assert.ok(native.calls.indexOf("picked.hash") >= 0 && native.calls.indexOf("picked.hash") < native.calls.lastIndexOf("picked.read"));
  assert.ok(native.picked.has(7), "a failed upload keeps its file, to go again");
  core.receive(client, JSON.stringify({ id: 3, call: "composer.remove", params: { key: "phone-1", id: "f1" } }));
  await until(() => !native.picked.has(7));
  native.host.close();
  rmSync(dir, { recursive: true, force: true });
});

test("a_file_held_whole_by_the_app_goes_up_from_the_bytes_beside_its_call", async (t) => {
  const blob = Object.getOwnPropertyDescriptor(globalThis, "Blob")!;
  delete (globalThis as { Blob?: unknown }).Blob;
  t.after(() => Object.defineProperty(globalThis, "Blob", blob));
  const dir = mkdtempSync(join(tmpdir(), "bridge-held-"));
  const native = new NodeShell(dir);
  const core = startBridged(native, "http://127.0.0.1:1", false, "android", () => {});
  native.bridge = core.bridge;
  const client = core.connect();
  const states = new Map<number, J>();
  const errors = new Map<number, J>();
  const read = () => {
    for (const [, json] of native.emitted.splice(0)) {
      const m = JSON.parse(json);
      if ("value" in m) states.set(m.id, m.value);
      else if ("delta" in m) states.set(m.id, apply(states.get(m.id), m.delta));
      else if ("error" in m) errors.set(m.id, m.error);
    }
  };
  const until = async (done: () => boolean) => {
    for (read(); !done(); read()) await native.heard();
  };
  core.receive(client, JSON.stringify({ id: 1, subscribe: { topic: "composer", key: "mbui-1" } }));
  // two files in one call, each its own run of the bytes
  const sha = "a".repeat(64);
  core.receive(client, JSON.stringify({ id: 2, call: "composer.add", params: { key: "mbui-1", station: "ws/st", files: [
    { id: "f1", name: "a.txt", size: 3, blob: { hostBytes: [0, 3], type: "text/plain", sha256: sha } },
    { id: "f2", name: "b.txt", size: 2, blob: { hostBytes: [3, 2], type: "text/plain" } },
  ] } }), bytes("abcde"));
  // taken (no such station here: each fails as it goes up), never asked of the app
  await until(() => errors.has(2) || (states.get(1)?.files?.length === 2 && states.get(1).files.every((f: J) => f.error != null)));
  assert.equal(errors.get(2), undefined);
  assert.deepEqual(states.get(1).files.map((f: J) => [f.id, f.size]), [["f1", 3], ["f2", 2]]);
  assert.ok(!native.calls.some((c) => c.startsWith("picked.")));
  native.host.close();
  rmSync(dir, { recursive: true, force: true });
});

const skip = loadAddon() === null ? "the mesh addon is not built here" : false;

test("the_mesh_goes_through_the_bridges_iroh", { skip }, async () => {
  const station = await Station.start();
  const { dir, native, bridge } = shell();
  const host = new FakeHost();
  const runner = new Runner();
  const mesh = await runner.run(Mesh.make({ host, runner, tracer: new Tracer(host, runner, 1), iroh: bridgeIroh(bridge), wakes: new Wakes(), ...STATION_MESH }, []));
  mesh.addAddr(station.addr());
  const link = await runner.run(mesh.link(station.id(), (device) => Effect.succeed({ credential: `ok-${device.length}`, issued_at: 0, expires_at: 0, relay_url: "" } as J)));
  const reply = await runner.run(link.request({ method: "POST", path: "/admin/api/x", headers: [] }, bytes("hi")));
  assert.equal(reply.status, 200);
  let all = "";
  for (;;) {
    const chunk = await runner.run(reply.body.take);
    if (chunk === null) break;
    all += text(chunk);
  }
  assert.ok(all.endsWith("|hi|one|two|three"), all);
  assert.deepEqual(station.grants, ["ok-64"]);
  for (const op of ["iroh.bind", "iroh.connect", "conn.openBi", "istream.write", "istream.read"]) assert.ok(native.calls.includes(op), op);
  await station.close();
  await runner.run(mesh.close());
  runner.shutdown();
  native.host.close();
  rmSync(dir, { recursive: true, force: true });
});

test("bridgeIroh_caches_relay_access_map_across_conn_paths_and_invalidates_on_relay_or_network_change", async () => {
  let relayStatusCalls = 0;
  let statuses: { url: string; connected: boolean; access?: string }[] = [
    { url: "https://r1.test/", connected: true, access: "https://e1.test/" },
  ];
  let rawPaths: { id: string; selected: boolean; relay: string | null; ip: string | null; rttMs: number | null; txPackets: number; lostPackets: number }[] = [
    { id: "p-direct", selected: true, relay: null, ip: "10.0.0.2:1234", rttMs: 2, txPackets: 5, lostPackets: 0 },
  ];
  const fakeBridge = {
    sync(op: string) {
      if (op === "iroh.relayStatus") {
        relayStatusCalls++;
        return statuses;
      }
      if (op === "conn.paths") return rawPaths;
      if (op === "iroh.endpointId") return "ep-1";
      return null;
    },
    call(op: string) {
      if (op === "iroh.bind") return Effect.succeed({ json: { id: 1 } });
      if (op === "iroh.connect") return Effect.succeed({ json: { id: 2 } });
      return Effect.succeed({ json: {} });
    },
  } as unknown as Parameters<typeof bridgeIroh>[0];

  const iroh = bridgeIroh(fakeBridge, () => 0);
  const runner = new Runner();
  try {
    const ep = await runner.run(iroh.bind({ secretKey: new Uint8Array(32), relayUrls: ["https://r1.test/"], lookup: false, relayOnly: false }));
    const conn = await runner.run(ep.connect({ id: "peer", relays: [], ips: [] }, new Uint8Array(), []));

    // Direct-only paths never query `iroh.relayStatus`.
    for (let i = 0; i < 10; i++) assert.equal(conn.paths()[0]!.relay, null);
    assert.equal(relayStatusCalls, 0);

    // Repeated relay paths query `iroh.relayStatus` once and reuse the cached `url -> access` map.
    rawPaths = [{ id: "p-r1", selected: true, relay: "https://r1.test", ip: null, rttMs: 25, txPackets: 10, lostPackets: 0 }];
    for (let i = 0; i < 50; i++) assert.equal(conn.paths()[0]!.relay, "https://e1.test/");
    assert.equal(relayStatusCalls, 1);

    // A previously unseen relay URL triggers one refresh.
    statuses = [...statuses, { url: "https://r2.test/", connected: true, access: "https://e2.test/" }];
    rawPaths = [{ id: "p-r2", selected: true, relay: "https://r2.test", ip: null, rttMs: 30, txPackets: 1, lostPackets: 0 }];
    assert.equal(conn.paths()[0]!.relay, "https://e2.test/");
    assert.equal(conn.paths()[0]!.relay, "https://e2.test/");
    assert.equal(relayStatusCalls, 2);

    // `setRelayEntries` invalidates the cached map so updated access URLs take effect immediately.
    statuses = [{ url: "https://r2.test/", connected: true, access: "https://e2-new.test/" }];
    await runner.run(ep.setRelayEntries!([{ entry: "https://e2-new.test/", relay: "https://r2.test/" }]));
    assert.equal(conn.paths()[0]!.relay, "https://e2-new.test/");
    assert.equal(relayStatusCalls, 3);

    // `networkChange` also invalidates the cached map.
    statuses = [{ url: "https://r2.test/", connected: true, access: "https://e2-net.test/" }];
    await runner.run(ep.networkChange());
    assert.equal(conn.paths()[0]!.relay, "https://e2-net.test/");
    assert.equal(relayStatusCalls, 4);
  } finally {
    runner.shutdown();
  }
});

test("bridgeIroh_wires_relay_control_ops_to_shell_and_refreshes_access_cache", async () => {
  const calls: { op: string; arg: J }[] = [];
  let relayStatusCalls = 0;
  let statuses = [{ url: "https://r1.test/", connected: true, access: "https://e1.test/" }];
  const fakeBridge = {
    sync(op: string) {
      if (op === "iroh.relayStatus") {
        relayStatusCalls++;
        return statuses;
      }
      if (op === "conn.paths") return [{ id: "p-r1", selected: true, relay: "https://r1.test", ip: null, rttMs: 20, txPackets: 1, lostPackets: 0 }];
      if (op === "iroh.endpointId") return "ep-1";
      return null;
    },
    call(op: string, arg: J) {
      calls.push({ op, arg });
      if (op === "iroh.bind") return Effect.succeed({ json: { id: 7 } });
      if (op === "iroh.connect") return Effect.succeed({ json: { id: 8 } });
      return Effect.succeed({ json: {} });
    },
  } as unknown as Parameters<typeof bridgeIroh>[0];

  const iroh = bridgeIroh(fakeBridge, () => 0);
  const runner = new Runner();
  try {
    const ep = await runner.run(iroh.bind({ secretKey: new Uint8Array(32), relayUrls: ["https://r1.test/"], lookup: false, relayOnly: false }));
    const conn = await runner.run(ep.connect({ id: "peer", relays: [], ips: [] }, new Uint8Array(), []));
    assert.equal(conn.paths()[0]!.relay, "https://e1.test/");
    assert.equal(relayStatusCalls, 1);

    await runner.run(ep.setDisabledRelays!("deadbeef", ["https://r2.test/", "https://r3.test/"]));
    // `setDisabledRelays` does not change relay access URLs.
    assert.equal(conn.paths()[0]!.relay, "https://e1.test/");
    assert.equal(relayStatusCalls, 1);

    statuses = [{ url: "https://r1.test/", connected: true, access: "https://e1-inserted.test/" }];
    await runner.run(ep.insertRelay!("https://r2.test/"));
    assert.equal(conn.paths()[0]!.relay, "https://e1-inserted.test/");
    assert.equal(relayStatusCalls, 2);

    statuses = [{ url: "https://r1.test/", connected: true, access: "https://e1-removed.test/" }];
    await runner.run(ep.removeRelay!("https://r2.test/"));
    assert.equal(conn.paths()[0]!.relay, "https://e1-removed.test/");
    assert.equal(relayStatusCalls, 3);

    const relayCalls = calls.filter((c) => c.op === "iroh.disabledRelays" || c.op === "iroh.insertRelay" || c.op === "iroh.removeRelay");
    assert.deepEqual(relayCalls, [
      { op: "iroh.disabledRelays", arg: { id: 7, peer: "deadbeef", relays: ["https://r2.test/", "https://r3.test/"] } },
      { op: "iroh.insertRelay", arg: { id: 7, url: "https://r2.test/" } },
      { op: "iroh.removeRelay", arg: { id: 7, url: "https://r2.test/" } },
    ]);
  } finally {
    runner.shutdown();
  }
});

test("createAccessCache_reads_relay_status_only_for_relay_paths_and_reuses_it_within_its_age", () => {
  let reads = 0;
  let t = 0;
  const statuses = [{ url: "https://r1.test/", access: "https://e1.test/" }];
  const access = createAccessCache(() => (reads++, statuses), { now: () => t });

  // Direct paths only: nothing read.
  for (let i = 0; i < 10; i++) assert.deepEqual(access.resolveAll([null, undefined]), [null, null]);
  assert.equal(reads, 0);

  // Relay paths: one read, then the map is reused until it is ACCESS_CACHE_MS old.
  assert.deepEqual(access.resolveAll([null, "https://r1.test"]), [null, "https://e1.test/"]);
  t = ACCESS_CACHE_MS - 1;
  for (let i = 0; i < 50; i++) assert.deepEqual(access.resolveAll(["https://r1.test"]), ["https://e1.test/"]);
  assert.equal(reads, 1);
  t = ACCESS_CACHE_MS;
  assert.deepEqual(access.resolveAll(["https://r1.test"]), ["https://e1.test/"]);
  assert.equal(reads, 2);

  // A clock set back reads again at once, not only when it is past the last read again.
  t = ACCESS_CACHE_MS - 10_000;
  access.resolveAll(["https://r1.test"]);
  assert.equal(reads, 3);
  access.resolveAll(["https://r1.test"]);
  assert.equal(reads, 3);
});

test("createAccessCache_follows_an_entrance_iroh_switches_to_after_the_first_read", () => {
  // As in side/mesh-real.test.ts a_faster_entrance_to_the_same_relay_keeps_the_open_link: setRelayEntries returns
  // (clear), the first paths() reads the old entrance, and iroh moves to the quicker one in the background after.
  let reads = 0;
  let t = 5_000;
  let statuses = [{ url: "https://r1.test/", access: "https://slow.test/" }];
  const access = createAccessCache(() => (reads++, statuses), { now: () => t });
  access.resolveAll(["https://r1.test"]);
  access.clear();
  assert.deepEqual(access.resolveAll(["https://r1.test"]), ["https://slow.test/"]);
  assert.equal(reads, 2);
  statuses = [{ url: "https://r1.test/", access: "https://r1.test/" }];
  t += ACCESS_CACHE_MS - 1;
  assert.deepEqual(access.resolveAll(["https://r1.test"]), ["https://slow.test/"]);
  assert.equal(reads, 2);
  t += 1;
  assert.deepEqual(access.resolveAll(["https://r1.test"]), ["https://r1.test/"]);
  assert.equal(reads, 3);
});

test("createAccessCache_reads_at_most_once_per_resolve_for_unknown_relays", () => {
  let reads = 0;
  let statuses: { url: string; access?: string }[] = [{ url: "https://r1.test/", access: "https://e1.test/" }];
  const access = createAccessCache(() => (reads++, statuses), { now: () => 0 });
  // A first read that still lacks r2 and r3 is not followed by another in the same resolve.
  assert.deepEqual(access.resolveAll(["https://r1.test", "https://r2.test", "https://r3.test"]), ["https://e1.test/", "https://r2.test", "https://r3.test"]);
  assert.equal(reads, 1);
  // Within the age, unknown relays read once for the whole resolve.
  statuses = [...statuses, { url: "https://r2.test/", access: "https://e2.test/" }, { url: "https://r3.test/", access: "https://e3.test/" }];
  assert.deepEqual(access.resolveAll(["https://r2.test", "https://r3.test", null, "https://r4.test"]), ["https://e2.test/", "https://e3.test/", null, "https://r4.test"]);
  assert.equal(reads, 2);
  // readStatus refreshes the map too; clear forgets it.
  access.readStatus();
  assert.equal(reads, 3);
  assert.deepEqual(access.resolveAll(["https://r2.test"]), ["https://e2.test/"]);
  assert.equal(reads, 3);
  access.clear();
  access.resolveAll(["https://r2.test"]);
  assert.equal(reads, 4);
});
