// The MoonBit station (`stillfail-reader run`, no Node on its PATH) holding a workspace's lock against the faults
// around it, on real iroh from real devices: with a lock pinned, a device the lock does not name and a member's new
// device refused at the hello (`lock_unconfirmed`, closed as refused) and told the chain alone; entries signed by a
// key not on the lock, tampered after signing, after a parent it does not keep or past its head refused without
// moving its head; a second entry after the head's parent answered a fork; a removal closing the removed member's
// connection at once, their credential (still the cloud's, still valid) refused after; a renewal the station refuses
// answered and the connection kept as let in; the control plane's lock frames (another genesis, the chain cut back)
// never unpinning or replacing it. A workspace whose chain moved (`moved {root}`): pinned from what its owner's
// device brings (the chain, the logs, the bodies), its state the logs' and the bodies'; a device it does not name
// told whom to ask (`left`) and nothing else of the workspace; a body no kept log commits to refused; a member a
// statement took out closed at once and told that removal (`out`); a core under the move's floor answered 426;
// the builds of the lock's devices given in GET /lock and kept across a restart. Two stations of one lock: an entry
// one takes reaches the other over the real mesh and the other lets in and closes devices by it at once. As
// src/mesh/serve.ts, src/cloud/state.ts and src/mesh/lock-sync.ts hold them for the TypeScript station (lock-forks,
// lock-left-out, lock-told-out, door, lock-moved, lock-bodies, lock-moved-pin, device-builds).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes, sign as nodeSign, type KeyObject } from "node:crypto";
import { createSocket } from "node:dgram";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer } from "node:http";
import { type AddressInfo, createServer as tcpServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { type Entry, bodyHash, endpointBytes, entryHash, signedBytes, wsTag } from "../../shared/lock.ts";
import { loadMesh, type Connection, type Endpoint, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { mbStationBinary } from "./mb-harness.ts";
import { GrantKey } from "./fake-control-plane.ts";

const binary = mbStationBinary();
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)"
  : process.platform === "win32" ? "the launcher's descriptors are Unix's"
  : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sfl-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const cleanups: (() => void | Promise<void>)[] = [];
after(async () => {
  for (const fn of cleanups.splice(0).reverse()) {
    try { await fn(); } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  if (process.env.STATION_KEEP !== "1") for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

// ── the world around the stations: a PATH with no Node, ports, the control plane, the launcher's channel ──

const TOOLS = ["sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "wc", "uname", "lsof"];
function toolsPath(): string {
  const dir = fresh("path");
  const search = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  for (const t of TOOLS) {
    const found = search.map((d) => join(d, t)).find((p) => existsSync(p));
    if (found !== undefined && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false);
  return dir;
}
const noNode = (more: Record<string, string> = {}) => ({ PATH: toolsPath(), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), ...more });

/// Looked at until `f` gives something (real processes: every 50 ms), failing with `what` after `ms`.
async function given<T>(what: string, f: () => T | null | undefined | false | Promise<T | null | undefined | false>, ms = 20_000, detail: () => string = () => ""): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`never came (${ms}ms): ${what}${last ? ` (${(last as Error).message})` : ""}; ${detail()}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

const readJson = (p: string) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

type Peer = { id: string; name: string; ips: string[] };
/// The control plane of the test's: its presence socket, each station given its workspace and peers, and frames pushed
/// to a station as the plane would push them.
async function controlPlane(ws: string, peers: () => Peer[]) {
  const sockets: { station: string; socket: WebSocket }[] = [];
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => res.writeHead(200, { "content-type": "application/json" }).end("{}"));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    const station = String(req.headers["x-stillfail-station"] ?? "");
    wss.handleUpgrade(req, socket, head, (w) => {
      sockets.push({ station, socket: w });
      w.on("message", (m) => {
        if (String(m) === "ping") w.send("pong");
      });
      const me = peers().find((p) => p.id === station);
      w.send(JSON.stringify({ type: "state", workspace: ws, workspace_name: "Team", name: me?.name ?? "s", peers: peers(), relay_urls: [], revocations: [] }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => {
    for (const s of sockets) s.socket.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return {
    origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    push(station: string, frame: unknown) {
      const open = sockets.filter((s) => s.station === station && s.socket.readyState === 1);
      assert.ok(open.length > 0, `a presence socket of ${station.slice(0, 8)} open`);
      for (const s of open) s.socket.send(JSON.stringify(frame));
    },
  };
}

type Launched = { child: ChildProcess; next: (what: string, ok: (m: any) => boolean) => Promise<any>; err: () => string; stop: () => Promise<void> };
/// `stillfail-reader run` under the test as its launcher (its listeners handed over as descriptors, its channel's lines).
async function launch(data: string, app: string, env: Record<string, string>): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = tcpServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcpSrv, loopSrv] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcpSrv), fd(loopSrv), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", ...env }),
  });
  children.push(child);
  mcpSrv.close();
  loopSrv.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  const next = (what: string, ok: (m: any) => boolean) => new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err.slice(-3000)}`)), 20_000);
    const look = () => {
      const found = said.find(ok);
      if (found !== undefined) {
        clearTimeout(timer);
        resolve(found);
      } else waiters.push(look);
    };
    look();
  });
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      channel.write(`${JSON.stringify({ op: "stop" })}\n`);
      assert.equal(await ended, 0, err.slice(-3000));
    }
  };
  return { child, next, err: () => err, stop };
}

type Station = { id: string; name: string; data: string; port: number; run: Launched };
/// `n` stations of workspace `ws`, each told the others as its peers, online at the plane.
async function stations(ws: string, names: string[], build = "9300") {
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), `${build}\n`);
  const made = await Promise.all(names.map(async (name) => {
    const data = fresh(name);
    return { id: stationId(data), name, data, port: await freeUdpPort() };
  }));
  const peers = () => made.map((s) => ({ id: s.id, name: s.name, ips: [`127.0.0.1:${s.port}`] }));
  const plane = await controlPlane(ws, peers);
  const grant = new GrantKey("k1");
  const start = async (s: (typeof made)[number]) => {
    const run = await launch(s.data, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${s.port}` });
    await run.next(`${s.name} ready`, (m) => m.ready === true);
    await given(`${s.name} online at the plane`, () => readJson(join(s.data, "run", "presence.json"))?.online === true, 20_000, () => run.err().slice(-2000));
    return run;
  };
  const out: Station[] = [];
  for (const s of made) {
    mkdirSync(join(s.data, "mesh"), { recursive: true });
    writeFileSync(join(s.data, "mesh", "cloud.json"), JSON.stringify({
      origin: plane.origin, station: s.id, workspace: ws, workspace_name: "Team", name: s.name, relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] }, peers: peers(), revocations: [],
    }));
  }
  for (const s of made) out.push({ ...s, run: await start(s) });
  cleanups.push(async () => {
    for (const s of out) await s.run.stop().catch(() => {});
  });
  /// The station started again on its data, as a restart does.
  const restart = async (s: Station) => {
    await s.run.stop();
    s.run = await start(s);
  };
  return { plane, grant, stations: out, restart };
}

// ── keys, locks and the people's own logs (as a device makes them) ──

const hexOf = (k: KeyObject) => Buffer.from(k.export({ format: "jwk" }).x as string, "base64url").toString("hex");
function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = hexOf(publicKey);
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Buffer) => nodeSign(null, bytes, privateKey).toString("hex") };
}
type Key = ReturnType<typeof ed>;
const signed = (e: Omit<Entry, "sig">, key: Key): Entry => ({ ...e, sig: { key: key.id, alg: "Ed25519", sig: key.sign(signedBytes(entryHash(e as Entry))) } });
/// A device: its key on its person's log, the key it signs a workspace's things with, and its base key (its id).
type Dev = { key: Key; signer: Key; base: Key };
const dev = (): Dev => ({ key: ed(), signer: ed(), base: ed() });

let salts = 0;
const salt = () => createHash("sha256").update(`salt ${salts++} ${Math.random()}`).digest("hex").slice(0, 32);
/// A person's own log: entries after its head, and the bodies of the statements they made of a workspace.
class Log {
  readonly app = dev();
  entries: Entry[];
  bodies = new Map<string, any>();
  readonly sub: string;
  constructor(sub: string) {
    this.sub = sub;
    this.entries = [signed({ v: 1, ws: `person:${sub}`, seq: 0, prev: null, at: 1000, kind: "genesis", body: { sub, device: { key: this.app.key.id, id: this.app.base.hex, label: `${sub}'s app`, sign_key: this.app.signer.id } } }, this.app.key)];
  }
  get genesis() {
    return entryHash(this.entries[0]!);
  }
  add(kind: string, body: unknown): Entry {
    const head = this.entries.at(-1)!;
    const e = signed({ v: 1, ws: `person:${this.sub}`, seq: head.seq + 1, prev: entryHash(head), at: 1000, kind, body }, this.app.key);
    this.entries.push(e);
    return e;
  }
  /// A statement of workspace `ws`: its body (naming the one before it), its commitment after the head.
  say(ws: string, kind: string, what: Record<string, unknown>): { body: any; h: string; entry: Entry } {
    const t = wsTag(ws, this.genesis);
    const before = [...this.entries].reverse().find((e) => e.kind === "ws" && e.body.t === t);
    const body = { ws, kind, ...what, prev: before?.body.h ?? null, salt: salt() };
    const h = bodyHash(body)!;
    this.bodies.set(h, body);
    return { body, h, entry: this.add("ws", { t, h }) };
  }
}

// ── a member's device on the mesh ──

const ADMIN = Buffer.from("stillfail/admin/1");
const write = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

async function bindClient(): Promise<Endpoint> {
  const e = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  cleanups.push(() => void e.close());
  return e;
}

type Device = {
  /// The device's endpoint on the mesh, and the base key that proves it is its own.
  endpoint: Endpoint; dev: Dev; sub: string;
};
type Hello = { conn: Connection; line: any; renew: (line: unknown) => Promise<any> };

/// A device's connection to a station: its hello (its credential and its base key's proof of the endpoint, and what
/// else `lock` brings), the station's line, and its later lines (renewals) on the same stream.
async function hello(s: Station, d: Device, credential: string, ws: string, more: Record<string, unknown> = {}): Promise<Hello> {
  const conn = await given(`connected to ${s.name}`, () => d.endpoint.connect({ id: s.id, ips: [`127.0.0.1:${s.port}`] }, ADMIN));
  const first = await conn.openBi();
  const lock = { device: d.dev.base.hex, proof: d.dev.base.sign(endpointBytes(ws, d.endpoint.id())), ...more };
  await write(first, { credential, protocol: 2, lock });
  const reader = new Reader(first);
  const line = await reader.line();
  return { conn, line, renew: async (l) => { await write(first, l); return reader.line(); } };
}

async function ask(conn: Connection, method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<[number, any]> {
  const stream = await conn.openBi();
  await write(stream, { method, path, headers: { "content-type": "application/json", ...headers } });
  if (body !== undefined) await stream.write(Buffer.from(JSON.stringify(body)));
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  const rest = (await reader.rest()).toString();
  let json: any = rest;
  try { json = JSON.parse(rest || "null"); } catch {}
  return [head.status, json];
}

/// How a connection ended as its end is told, and how long after `since`; failing after `ms` (well under QUIC's idle
/// timeout of 30 s, which an end never told the other side comes to).
async function endOf(conn: Connection, since: number, ms = 10_000) {
  let timer: NodeJS.Timeout | undefined;
  const closed = await Promise.race([
    conn.closed(),
    new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`the connection not closed within ${ms} ms`)), ms); }),
  ]).finally(() => clearTimeout(timer));
  return { closed, why: conn.closeReason?.() ?? null, after: Date.now() - since };
}

/// Refused at the hello for the lock: not let in, told so, closed as refused (door.mbt: code 1), not as the station
/// stopping, soon after its line.
async function refusedForLock(h: Hello, what: string) {
  const since = Date.now();
  assert.notEqual(h.line.ok, true, `${what}: ${JSON.stringify(h.line)}`);
  assert.equal(h.line.code, "lock_unconfirmed", `${what}: ${JSON.stringify(h.line)}`);
  assert.ok(typeof h.line.error === "string" && h.line.error !== "", `${what}: words`);
  const end = await endOf(h.conn, since);
  assert.deepEqual(end.why, { kind: "application", reason: "lock_unconfirmed" }, `${what}: ${JSON.stringify(end)}`);
  assert.ok(end.after < 5_000, `${what}: closed ${end.after} ms after its line`);
  return h.line;
}

const memberCred = (grant: GrantKey, ws: string, sub: string, role: string, endpoint: string, more: Record<string, unknown> = {}) => {
  const now = Math.floor(Date.now() / 1000);
  return grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub, email: `${sub}@x`, name: sub, ws, role, device: endpoint, sid: `sid-${sub}`, iat: now, exp: now + 3600, ...more });
};

const genesisOf = (ws: string, by: Key, people: { sub: string; role: string; dev: Dev }[], stationKeys: Station[], cloudKey: GrantKey) => signed({
  v: 1, ws, seq: 0, prev: null, at: Math.floor(Date.now() / 1000), kind: "genesis",
  body: {
    owner: people.find((p) => p.role === "owner")!.sub,
    origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [cloudKey.jwk] },
    members: people.map((p) => ({ sub: p.sub, email: `${p.sub}@x`, role: p.role })),
    devices: people.map((p) => ({ id: p.dev.base.hex, sub: p.sub, kind: "app", label: p.sub, sign_key: p.dev.signer.id })),
    passkeys: [], stations: stationKeys.map((s) => ({ key: s.id, name: s.name })), gateways: [],
  },
}, by);
const after1 = (prev: Entry, kind: string, body: unknown, by: Key, seq = prev.seq + 1, prevHash = entryHash(prev)) =>
  signed({ v: 1, ws: prev.ws, seq, prev: prevHash, at: prev.at + 1, kind, body }, by);

test("a pinned lock: devices it does not name refused at the hello, forged or tampered entries and a fork refused without moving its head, a removal closing its member's connection at once, a refused renewal leaving the connection as let in, and the plane's lock frames never unpinning it", { skip, timeout: 120_000 }, async () => {
  const WS = "01HLOCKFAULTSLOCKFAULTS001";
  const { plane, grant, stations: [a] } = await stations(WS, ["alpha"]);
  const people = { alice: dev(), bob: dev(), carol: dev() };
  const genesis = genesisOf(WS, people.alice.signer, [{ sub: "alice", role: "owner", dev: people.alice }, { sub: "bob", role: "admin", dev: people.bob }, { sub: "carol", role: "member", dev: people.carol }], [a!], grant);
  const device = async (sub: string, d: Dev): Promise<Device> => ({ endpoint: await bindClient(), dev: d, sub });
  const [alice, bob, carol] = await Promise.all([device("alice", people.alice), device("bob", people.bob), device("carol", people.carol)]);
  const enter = (d: Device, role: string, more: Record<string, unknown> = {}) => hello(a!, d, memberCred(grant, WS, d.sub, role, d.endpoint.id()), WS, more);

  // ── the owner pins it ──
  const owner = await enter(alice!, "owner");
  assert.equal(owner.line.ok, true, JSON.stringify(owner.line));
  const [pinned, pin] = await ask(owner.conn, "POST", "/admin/api/lock", { entries: [genesis] });
  assert.equal(pinned, 200, JSON.stringify(pin));
  const head = async () => (await ask(owner.conn, "GET", "/admin/api/lock"))[1].head;
  assert.equal((await head()).genesis, entryHash(genesis));
  await given("lock.json written", () => readJson(join(a!.data, "mesh", "lock.json"))?.entries?.length === 1);

  // members of it let in, on the devices it names
  const b = await enter(bob!, "admin");
  assert.equal(b.line.ok, true, JSON.stringify(b.line));
  assert.equal(b.line.lock?.seq, 0, "the hello's line says the lock's head");
  const c = await enter(carol!, "member");
  assert.equal(c.line.ok, true, JSON.stringify(c.line));

  // ── devices it does not name, refused at the hello, all at once, beside a member served ──
  const erin = await device("erin", dev());
  const carolsNew = await device("carol", dev());
  const [strangerLine, newDeviceLine, [served]] = await Promise.all([
    enter(erin, "owner").then((h) => refusedForLock(h, "a device of someone the lock does not name")),
    enter(carolsNew, "member").then((h) => refusedForLock(h, "a member's device the lock does not name")),
    ask(b.conn, "GET", "/admin/api/overview"),
  ]);
  assert.equal(served, 200, "the member served while the others were refused");
  for (const [what, line] of [["stranger", strangerLine], ["new device", newDeviceLine]] as const) {
    // the chain (every member's to read) and its head, nothing of a moved workspace's: no logs, no bodies, no list
    assert.equal(line.lock?.genesis, entryHash(genesis), `${what}: its head said`);
    assert.equal(line.out, undefined, `${what}: nothing of a removal`);
    assert.equal(line.left, undefined, `${what}: no list to ask of (the chain did not move)`);
    assert.equal(line.person, undefined, `${what}: no person's log`);
  }

  // ── entries that do not hold, each refused, the head where it was ──
  const stranger = ed();
  const removeCarol = after1(genesis, "member.remove", { sub: "carol" }, people.alice.signer);
  const tampered = { ...removeCarol, body: { sub: "bob" } };
  const forged: [string, Entry][] = [
    ["signed by a key not on the lock", after1(genesis, "member.remove", { sub: "carol" }, stranger)],
    ["its body changed after it was signed", tampered],
    ["after a parent the lock does not keep", after1(genesis, "member.remove", { sub: "carol" }, people.alice.signer, 1, "ab".repeat(32))],
    ["past the head (seq 2 after 0)", after1(genesis, "member.remove", { sub: "carol" }, people.alice.signer, 2)],
    ["a genesis of another's making", genesisOf(WS, stranger, [{ sub: "erin", role: "owner", dev: erin.dev }], [a!], grant)],
    ["an admin removing the owner", after1(genesis, "member.remove", { sub: "alice" }, people.bob.signer)],
  ];
  for (const [what, e] of forged) {
    const [st, said] = await ask(owner.conn, "POST", "/admin/api/lock", { entries: [e] });
    assert.ok(st >= 400 && st < 500, `${what}: ${st} ${JSON.stringify(said)}`);
    assert.ok(typeof said?.error === "string" && said.error !== "", `${what}: said why`);
    const h = await head();
    assert.equal(h.seq, 0, `${what}: the head not moved (${JSON.stringify(h)})`);
    assert.equal(h.hash, entryHash(genesis), `${what}: the head not moved`);
  }
  assert.equal(readJson(join(a!.data, "mesh", "lock.json"))?.entries?.length, 1, "nothing of them written");
  await refusedForLock(await enter(erin, "owner"), "the forged genesis's owner");

  // ── a removal: the removed member's connection closed at once, their credential refused after ──
  const since = Date.now();
  const [removed, took] = await ask(owner.conn, "POST", "/admin/api/lock", { entries: [removeCarol] });
  assert.equal(removed, 200, JSON.stringify(took));
  assert.equal(took.head.seq, 1);
  const end = await endOf(c.conn, since);
  assert.deepEqual(end.why, { kind: "application", reason: "lock_unconfirmed" }, JSON.stringify(end));
  assert.ok(end.after < 5_000, `carol's connection closed ${end.after} ms after the removal`);
  await refusedForLock(await enter(carol!, "member"), "the removed member, their credential still the cloud's");
  assert.equal(b.conn.isClosed(), false, "bob's connection untouched");

  // ── a second entry after the head's parent: a fork, answered so, the head the first ──
  const removeBob = after1(genesis, "member.remove", { sub: "bob" }, people.alice.signer);
  const [forked, fork] = await ask(owner.conn, "POST", "/admin/api/lock", { entries: [removeBob] });
  assert.equal(forked, 409, JSON.stringify(fork));
  assert.equal(fork.head.hash, entryHash(removeCarol), "the head the entry taken first");
  assert.equal((await ask(b.conn, "GET", "/admin/api/overview"))[0], 200, "bob still served: the fork took nobody out");

  // ── renewals: one the station refuses answered why and the connection kept as let in; a good one taken ──
  const now = Math.floor(Date.now() / 1000);
  const expired = await b.renew({ credential: memberCred(grant, WS, "bob", "admin", bob!.endpoint.id(), { iat: now - 7200, exp: now - 60 }) });
  assert.notEqual(expired.ok, true, JSON.stringify(expired));
  assert.match(String(expired.error), /expired/, JSON.stringify(expired));
  const elsewhere = await b.renew({ credential: memberCred(grant, WS, "bob", "admin", "f".repeat(64)) });
  assert.match(String(elsewhere.error), /another device/, JSON.stringify(elsewhere));
  assert.equal(b.conn.isClosed(), false, "a refused renewal ends nothing");
  assert.equal((await ask(b.conn, "GET", "/admin/api/overview"))[0], 200, "served as it was let in");
  const renewed = await b.renew({ credential: memberCred(grant, WS, "bob", "admin", bob!.endpoint.id(), { exp: now + 7200 }) });
  assert.equal(renewed.ok, true, JSON.stringify(renewed));
  assert.equal(renewed.expires_at, now + 7200);

  // ── the plane's lock frames: another genesis, the chain cut back to its genesis, a stranger's chain; nothing of it
  // unpins or replaces the lock (station/src/cloud/AGENTS.md: only `disable` or the local CLI) ──
  const madeUp = genesisOf(WS, stranger, [{ sub: "erin", role: "owner", dev: erin.dev }], [a!], grant);
  plane.push(a!.id, { type: "lock", entries: [madeUp] });
  plane.push(a!.id, { type: "lock", entries: [genesis] });
  plane.push(a!.id, { type: "lock", entries: [madeUp, after1(madeUp, "member.remove", { sub: "alice" }, stranger)] });
  plane.push(a!.id, { type: "lock", entries: [] });
  // (a frame after them that shows: the station's name in the workspace, as a hello's line says it)
  plane.push(a!.id, { type: "state", workspace: WS, workspace_name: "Team", name: "alpha-later", peers: [{ id: a!.id, name: "alpha-later", ips: [`127.0.0.1:${a!.port}`] }], relay_urls: [], revocations: [] });
  await given("the plane's frames taken (the name after them said)", async () => {
    const h = await enter(alice!, "owner");
    h.conn.close(0, "done");
    return h.line.station === "alpha-later" ? h : null;
  });
  const after = await head();
  assert.equal(after.hash, entryHash(removeCarol), `the lock as it was: ${JSON.stringify(after)}`);
  assert.equal(after.genesis, entryHash(genesis));
  assert.deepEqual(readJson(join(a!.data, "mesh", "lock.json"))?.entries?.map((e: Entry) => entryHash(e)), [entryHash(genesis), entryHash(removeCarol)], "lock.json as it was");
  await refusedForLock(await enter(erin, "owner"), "the made-up chain's owner, after the plane's frames");
  await refusedForLock(await enter(carol!, "member"), "the removed member, after the plane's frames");
  assert.equal((await ask(owner.conn, "GET", "/admin/api/overview"))[0], 200, "the owner served throughout");
  assert.doesNotMatch(a!.run.err(), /panic|SQLITE_BUSY|database is locked/i);
});

test("a workspace whose chain moved: pinned from what its owner's device brings, a device it does not name told only whom to ask, a body no log commits to refused, a member taken out closed and told why, cores under the floor answered 426, and the builds of its devices kept across a restart", { skip, timeout: 120_000 }, async () => {
  const WS = "01HLOCKMOVEDLOCKMOVED00002";
  const { grant, stations: [a], restart } = await stations(WS, ["home"]);
  const alice = new Log("alice"), bob = new Log("bob"), carol = new Log("carol");
  // the old chain, then its move to alice's log; the handover's statements (lock-moved-world.ts `handover`)
  const first = genesisOf(WS, alice.app.signer, [{ sub: "alice", role: "owner", dev: alice.app }, { sub: "bob", role: "admin", dev: bob.app }, { sub: "carol", role: "member", dev: carol.app }], [a!], grant);
  const moved = after1(first, "moved", { root: alice.genesis }, alice.app.signer);
  alice.say(WS, "open", { origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [grant.jwk] }, email: "alice@x" });
  alice.say(WS, "member", { sub: "bob", email: "bob@x", lock: bob.genesis, role: "admin" });
  const carolIn = alice.say(WS, "member", { sub: "carol", email: "carol@x", lock: carol.genesis, role: "member" });
  alice.say(WS, "station", { key: a!.id });
  // dan, a member said in bob's statement alone (no device of his anywhere)
  bob.say(WS, "member", { sub: "dan", email: "dan@x", lock: ed().hex, role: "member" });
  const device = async (log: Log, d: Dev = log.app): Promise<Device> => ({ endpoint: await bindClient(), dev: d, sub: log.sub });
  const enter = (d: Device, role: string, more: Record<string, unknown> = {}) => hello(a!, d, memberCred(grant, WS, d.sub, role, d.endpoint.id()), WS, more);
  const [aliceApp, bobApp, carolApp] = await Promise.all([device(alice), device(bob), device(carol)]);

  // ── pinned from what the owner's device brings: the chain, the logs, the bodies ──
  const owner = await enter(aliceApp!, "owner");
  assert.equal(owner.line.ok, true, JSON.stringify(owner.line));
  const logs = [alice, bob, carol].map((l) => l.entries);
  const bodies = [alice, bob, carol].flatMap((l) => [...l.bodies.values()]);
  const [pinned, pin] = await ask(owner.conn, "POST", "/admin/api/lock", { entries: [first, moved], logs, bodies });
  assert.equal(pinned, 200, JSON.stringify(pin));
  assert.equal(pin.head?.hash, entryHash(moved), JSON.stringify(pin));
  // the owner's connection goes by the state the logs make (her log brought again where it was let go)
  const ownerNow = owner.conn.isClosed() ? await enter(aliceApp!, "owner", { person: alice.entries }) : owner;
  assert.equal(ownerNow.line.ok, true, JSON.stringify(ownerNow.line));
  const [got, lock] = await ask(ownerNow.conn, "GET", "/admin/api/lock");
  assert.equal(got, 200, JSON.stringify(lock));
  assert.equal(lock.head.hash, entryHash(moved), "the chain as it moved");
  // the members the logs let in, on their app devices, by their own logs
  const b = await enter(bobApp!, "admin", { person: bob.entries });
  assert.equal(b.line.ok, true, JSON.stringify(b.line));
  const c = await enter(carolApp!, "member", { person: carol.entries });
  assert.equal(c.line.ok, true, JSON.stringify(c.line));
  // bob's log now with dan's statement: given the station by bob's device
  const [brought, broughtSaid] = await ask(b.conn, "POST", "/admin/api/lock/person", { chain: bob.entries, bodies: [...bob.bodies.values()] });
  assert.equal(brought, 200, JSON.stringify(broughtSaid));

  // ── devices the state does not name: told whom to ask, nothing else of the workspace ──
  const holdsNothingElse = (r: any, what: string) => {
    assert.deepEqual(Object.keys(r).filter((k) => !["error", "code", "lock", "entries", "person", "left"].includes(k)), [], `${what}: no other field (${Object.keys(r)})`);
    assert.equal(r.out, undefined, `${what}: nothing of a removal`);
    assert.equal(JSON.stringify(r).includes("dan@x"), false, `${what}: no name only a body says`);
    assert.deepEqual(Object.keys(r.left ?? {}).sort(), ["approvers", "apps"], `${what}: only whom to ask and whether its person has an app`);
  };
  const erin = await device(new Log("erin"));
  const erinLine = await refusedForLock(await enter(erin, "member"), "a device of someone the list does not name");
  assert.deepEqual(new Set(erinLine.left?.approvers), new Set([alice.app.base.hex, bob.app.base.hex]), `the owners' and admins' apps: ${JSON.stringify(erinLine.left)}`);
  assert.equal(erinLine.left?.apps, false);
  holdsNothingElse(erinLine, "erin");
  const carolsNew = await device(carol, dev());
  const newLine = await refusedForLock(await enter(carolsNew, "member"), "a new device of a member the list names");
  assert.deepEqual(newLine.left, { approvers: [carol.app.base.hex], apps: true }, "carol's own app alone");
  holdsNothingElse(newLine, "carol's new device");
  const dans = await device(new Log("dan"));
  const danLine = await refusedForLock(await enter(dans, "member"), "a member with no app device");
  assert.deepEqual(danLine.left, { approvers: [], apps: false }, "nobody to ask, no app of his");
  holdsNothingElse(danLine, "dan");

  // ── a statement's body no kept log commits to: refused, never kept, nobody let in by it ──
  const mallory = new Log("mallory");
  const madeUp = { ws: WS, kind: "member", sub: "mallory", email: "mallory@x", lock: mallory.genesis, role: "owner", prev: null, salt: salt() };
  const [bodiesAsked, bodiesSaid] = await ask(ownerNow.conn, "POST", "/admin/api/lock/bodies", { bodies: [madeUp] });
  assert.equal(bodiesAsked, 200, JSON.stringify(bodiesSaid));
  assert.equal(bodiesSaid.taken, 0, JSON.stringify(bodiesSaid));
  assert.equal(bodiesSaid.refused?.length, 1, JSON.stringify(bodiesSaid));
  assert.ok(typeof bodiesSaid.refused[0].why === "string" && bodiesSaid.refused[0].why !== "", JSON.stringify(bodiesSaid));
  const [, kept] = await ask(ownerNow.conn, "GET", "/admin/api/lock/bodies");
  assert.equal(kept.bodies.some((x: any) => x.sub === "mallory"), false, "not kept");
  assert.equal(kept.bodies.length, bodies.length, "the bodies brought, all kept");
  // (her log brought too, its genesis unbound by any body in force: still left out)
  await refusedForLock(await enter(await device(mallory), "owner", { person: mallory.entries, bodies: [madeUp] }), "mallory with her made-up body");

  // ── builds: a core under the move's floor told to update (426), one above it kept by its device's id ──
  const [old, oldSaid] = await ask(b.conn, "GET", "/admin/api/lock", undefined, { "stillfail-build": "0.1.9000" });
  assert.equal(old, 426, JSON.stringify(oldSaid));
  assert.equal(oldSaid.update, true);
  assert.equal((await ask(b.conn, "GET", "/admin/api/overview", undefined, { "stillfail-build": "0.1.9000" }))[0], 426, "every route of the workspace");
  assert.equal((await ask(b.conn, "GET", "/admin/api/lock", undefined, { "stillfail-build": "0.1.9250" }))[0], 200);
  assert.equal((await ask(c.conn, "GET", "/admin/api/overview", undefined, { "stillfail-build": "0.1.9260" }))[0], 200);
  const [, withBuilds] = await ask(ownerNow.conn, "GET", "/admin/api/lock", undefined, { "stillfail-build": "0.1.9270" });
  assert.ok(withBuilds.serves.includes("builds"));
  const seen = withBuilds.builds.devices;
  assert.equal(seen[bob.app.base.hex]?.build, 9250, JSON.stringify(withBuilds.builds));
  assert.equal(seen[carol.app.base.hex]?.build, 9260);
  assert.equal(seen[alice.app.base.hex]?.build, 9270);
  const named = new Set([alice, bob, carol].map((l) => l.app.base.hex));
  for (const id of Object.keys(seen)) assert.ok(named.has(id), `a device the lock does not name in builds: ${id}`);
  const since = withBuilds.builds.since;
  assert.equal(since, Math.floor(since), `since in whole seconds, as nowSecs: ${since}`);

  // ── a member a statement takes out: closed at once, told that removal and the log entry committing to it ──
  const removal = bob.say(WS, "member.remove", { sub: "carol", cancels: [carolIn.h] });
  const at = Date.now();
  const [removed, removedSaid] = await ask(b.conn, "POST", "/admin/api/lock/person", { chain: bob.entries, bodies: [...bob.bodies.values()] });
  assert.equal(removed, 200, JSON.stringify(removedSaid));
  const end = await endOf(c.conn, at);
  assert.deepEqual(end.why, { kind: "application", reason: "lock_unconfirmed" }, JSON.stringify(end));
  assert.ok(end.after < 5_000, `carol's connection closed ${end.after} ms after the removal came`);
  const outLine = await refusedForLock(await enter(carolApp!, "member", { person: carol.entries }), "carol taken out");
  assert.ok(outLine.out !== undefined, `told what took her out: ${JSON.stringify(outLine)}`);
  assert.deepEqual(outLine.out.bodies.map((x: any) => bodyHash(x)).sort(), [removal.h, [...bob.bodies.keys()][0]].sort(), "the removal and its prev chain (bob's statement before it)");
  assert.deepEqual(outLine.out.logs.map((l: any) => l.genesis), [bob.genesis], "bob's log alone");
  assert.equal(entryHash(outLine.out.logs[0].entries.at(-1)), entryHash(removal.entry), "up to the entry that commits to it");
  assert.equal(b.conn.isClosed(), false);

  // ── a restart: the moved lock pinned as it was, the builds and their `since` kept ──
  await restart(a!);
  const again = await enter(aliceApp!, "owner", { person: alice.entries });
  assert.equal(again.line.ok, true, JSON.stringify(again.line));
  const [, afterRestart] = await ask(again.conn, "GET", "/admin/api/lock");
  assert.equal(afterRestart.head.hash, entryHash(moved), "the chain kept");
  assert.equal(afterRestart.builds.since, since, "since: the first start's");
  assert.equal(afterRestart.builds.devices[bob.app.base.hex]?.build, 9250, JSON.stringify(afterRestart.builds));
  assert.equal(afterRestart.builds.devices[alice.app.base.hex]?.build, 9270);
  await refusedForLock(await enter(carolApp!, "member", { person: carol.entries }), "carol, after the restart");
  await refusedForLock(await enter(erin, "member"), "erin, after the restart");
  assert.equal((await ask(again.conn, "GET", "/admin/api/lock", undefined, { "stillfail-build": "0.1.9000" }))[0], 426, "the floor after the restart");
  assert.doesNotMatch(a!.run.err(), /panic|SQLITE_BUSY|database is locked/i);
});

test("two stations of one lock: an entry one takes reaches the other over the real mesh, which lets in a device it adds and closes a removed member's connection at once; the removed member's credential refused on both", { skip, timeout: 120_000 }, async () => {
  const WS = "01HLOCKPAIRLOCKPAIRLOCK003";
  const { grant, stations: [a, b] } = await stations(WS, ["alpha", "beta"]);
  const people = { alice: dev(), bob: dev() };
  const genesis = genesisOf(WS, people.alice.signer, [{ sub: "alice", role: "owner", dev: people.alice }, { sub: "bob", role: "member", dev: people.bob }], [a!, b!], grant);
  const device = async (sub: string, d: Dev): Promise<Device> => ({ endpoint: await bindClient(), dev: d, sub });
  const [aliceA, bobDev] = [await device("alice", people.alice), await device("bob", people.bob)];
  const enter = (s: Station, d: Device, role: string) => hello(s, d, memberCred(grant, WS, d.sub, role, d.endpoint.id()), WS);
  const ownerA = await enter(a!, aliceA, "owner");
  const ownerB = await enter(b!, aliceA, "owner");
  for (const o of [ownerA, ownerB]) {
    assert.equal(o.line.ok, true, JSON.stringify(o.line));
    const [st, said] = await ask(o.conn, "POST", "/admin/api/lock", { entries: [genesis] });
    assert.equal(st, 200, JSON.stringify(said));
  }
  const bobOnB = await enter(b!, bobDev, "member");
  assert.equal(bobOnB.line.ok, true, JSON.stringify(bobOnB.line));

  // alice's second device: refused on beta until alpha's entry reaches it
  const laptop = dev();
  const laptopDev = await device("alice", laptop);
  await refusedForLock(await enter(b!, laptopDev, "owner"), "a device no entry names yet");
  const addLaptop = after1(genesis, "device", { id: laptop.base.hex, sub: "alice", kind: "app", label: "laptop", sign_key: laptop.signer.id }, people.alice.signer);
  const [added, addedSaid] = await ask(ownerA.conn, "POST", "/admin/api/lock", { entries: [addLaptop] });
  assert.equal(added, 200, JSON.stringify(addedSaid));
  await given("beta takes alpha's entry over the mesh", async () => (await ask(ownerB.conn, "GET", "/admin/api/lock"))[1]?.head?.seq === 1, 20_000, () => b!.run.err().slice(-2000));
  const laptopOnB = await enter(b!, laptopDev, "owner");
  assert.equal(laptopOnB.line.ok, true, `let in on beta by the entry alpha took: ${JSON.stringify(laptopOnB.line)}`);
  assert.equal((await ask(laptopOnB.conn, "GET", "/admin/api/overview"))[0], 200);

  // bob removed on alpha: his connection on beta closed as the entry reaches it, his credential refused on both
  const at = Date.now();
  const removeBob = after1(addLaptop, "member.remove", { sub: "bob" }, people.alice.signer);
  const [removed, removedSaid] = await ask(ownerA.conn, "POST", "/admin/api/lock", { entries: [removeBob] });
  assert.equal(removed, 200, JSON.stringify(removedSaid));
  const end = await endOf(bobOnB.conn, at, 15_000);
  assert.deepEqual(end.why, { kind: "application", reason: "lock_unconfirmed" }, JSON.stringify(end));
  assert.ok(end.after < 10_000, `bob's connection on beta closed ${end.after} ms after alpha took his removal`);
  assert.equal((await ask(ownerB.conn, "GET", "/admin/api/lock"))[1].head.hash, entryHash(removeBob), "beta at alpha's head");
  for (const s of [a!, b!]) await refusedForLock(await enter(s, bobDev, "member"), `bob's credential on ${s.name}`);
  // the owner's devices served on both throughout
  assert.equal((await ask(ownerB.conn, "GET", "/admin/api/overview"))[0], 200);
  assert.equal((await ask(laptopOnB.conn, "GET", "/admin/api/overview"))[0], 200);
  assert.equal((await ask(ownerA.conn, "GET", "/admin/api/overview"))[0], 200);
  for (const s of [a!, b!]) assert.doesNotMatch(s.run.err(), /panic|SQLITE_BUSY|database is locked/i);
});
