// The station's platform as the MoonBit program runs it (station/mb src/station_main live_p5_1_*.mbt), with real IO
// and no Node: an enrolled station started under a launcher of the test's (`stillfail-reader run`, a PATH with no Node
// in it) reaches a control plane of the test's (HTTP and its presence WebSocket), says so in run/presence.json,
// run/health.json and its status socket; its config.json is read again as another program edits it and written as the
// admin API edits it; the admin API (on the agents' door where STILLFAIL_LOCAL_ADMIN says so, as the station's owner)
// answers the machine (`/host`), the overview with the parts' fields (`/overview`: the rigs'), the rigs' own routes,
// and an event stream told of a change the store made (`/events`); a machine enrolled as a rig starts as one and
// stops with no process of its left behind.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, createPublicKey, verify } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer, type Server } from "node:net";
import { createServer as httpServer, request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { randomBytes } from "node:crypto";
import { createSocket } from "node:dgram";
import { mbHarnessBinary, mbStationBinary } from "./mb-harness.ts";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { Store } from "../src/store/store.ts";

const binary = mbStationBinary();
/// (the tests' program, its harness: the station's own commands are the reader's)
const harnessProgram = mbHarnessBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : harnessProgram === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
// (short: a Unix socket's path is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sf5-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// An environment with no Node: an empty PATH of its own, HOME and TMPDIR as given.
const noNode = (more: Record<string, string> = {}) => ({ PATH: fresh("path"), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), ...more });

/// What `f` comes to, looked at again as the program goes on (its files, its sockets): there within `ms`, or the test
/// fails saying what it waited for.
async function given<T>(what: string, f: () => T | null | undefined | Promise<T | null | undefined>, ms = 20_000): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

const readJson = (p: string) => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null);

/// The control plane of the test's: its HTTP (the log's batches) and its presence socket (`/v1/stations/connect`),
/// which tells the station its state as it connects and answers each ping.
async function controlPlane(peers: unknown[] = []) {
  const sockets: { headers: Record<string, unknown>; socket: WebSocket; said: string[] }[] = [];
  const posts: { path: string; headers: Record<string, unknown>; body: string }[] = [];
  const server = httpServer((req, res) => {
    let text = "";
    req.on("data", (d) => (text += d));
    req.on("end", () => {
      posts.push({ path: req.url!, headers: req.headers, body: text });
      res.writeHead(200, { "content-type": "application/json" }).end("{}");
    });
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      const entry = { headers: req.headers, socket: ws, said: [] as string[] };
      sockets.push(entry);
      ws.on("message", (m) => {
        const text = String(m);
        entry.said.push(text);
        if (text === "ping") ws.send("pong");
      });
      // The station's state as the plane says it: its roster (none other), its name.
      ws.send(JSON.stringify({ type: "state", workspace: "w1", workspace_name: "团队", name: "mac", peers, relay_urls: [] }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  after(() => {
    for (const s of sockets) s.socket.terminate();
    wss.close();
    server.close();
  });
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, sockets, posts };
}

/// Whether `signature` is the station's (its id, the Ed25519 key's public half) over `message`.
function signedBy(id: string, message: string, signature: string): boolean {
  const key = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(id, "hex")]), format: "der", type: "spki" });
  return verify(null, Buffer.from(message), key, Buffer.from(signature, "hex"));
}

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string };

/// `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fourth's pipe.
async function launch(data: string, app: string, env: Record<string, string>): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", ...env }),
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 20_000);
      const look = () => {
        const found = said.find(ok);
        if (found !== undefined) {
          clearTimeout(timer);
          resolve(found);
        } else waiters.push(look);
      };
      look();
    });
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

/// A request of one of the station's own listeners: its answer whole.
function ask(port: number | { socket: string }, path: string, o: { method?: string; body?: string } = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({ ...(typeof port === "number" ? { host: "127.0.0.1", port } : { socketPath: port.socket }), path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers: { "content-type": "application/json" } }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text }));
    });
    req.on("error", reject);
    req.end(o.body);
  });
}

/// An event stream of the admin API (GET /events): what it said so far, as it comes, and its end.
function events(port: number, path: string) {
  const heard: string[] = [];
  let close = () => {};
  const opened = new Promise<number>((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path }, (res) => {
      res.setEncoding("utf8");
      res.on("data", (d: string) => heard.push(d));
      resolve(res.statusCode!);
    });
    req.on("error", reject);
    close = () => req.destroy();
    req.end();
  });
  return { heard, opened, close: () => close(), text: () => heard.join("") };
}

/// The program's id of a data directory (`stillfail-reader id`): its key made there.
function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

/// The processes `pid` started that are still there.
const childrenOf = (pid: number) => spawnSync("pgrep", ["-P", String(pid)], { encoding: "utf8" }).stdout.trim().split("\n").filter((l) => l !== "").map(Number);

test("an enrolled station on the plane: its presence, its config, the machine, the overview, the parts' routes and the events", { skip }, async () => {
  const plane = await controlPlane();
  const data = fresh("live");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const id = stationId(data);
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: {}, peers: [], revocations: [],
  }));
  writeFileSync(join(data, "config.json"), `${JSON.stringify({ language: "en" })}\n`);
  // A chat of the station's own (still.fail's), there before it starts.
  const before = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  const thread = before.openThread("ember", "local", "t1", "first", null);
  before.close();

  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1" });
  assert.deepEqual(await a.next("ready", (m) => m.ready === true), { ready: true, version: "0.1.9500" });
  const mcp = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;

  // ── the presence socket: signed as enrollment is, online at the plane, said in its files and its status ──
  const socket = await given("the presence socket", () => plane.sockets[0]);
  const h = socket.headers;
  const ts = String(h["x-stillfail-ts"]);
  assert.equal(h["x-stillfail-station"], id, JSON.stringify(h));
  assert.ok(signedBy(id, `stillfail-station-connect-v1:${plane.origin}:${id}:${ts}`, String(h["x-stillfail-signature"])), "signed with the station's key");
  assert.equal(h["x-stillfail-version"], "0.1.9500");
  const presence = await given("presence.json online", () => readJson(join(data, "run", "presence.json"))?.online === true && readJson(join(data, "run", "presence.json")));
  assert.equal(presence.error, null);
  await given("health.json presenceOnline", () => readJson(join(data, "run", "health.json"))?.presenceOnline === true);
  // the times it keeps and signs are the world's (ms since 1970, now), never the monotonic clock's (a day of 1970)
  const health = readJson(join(data, "run", "health.json"));
  for (const [what, at] of [["health.json updatedAt", Number(health.updatedAt)], ["the presence socket's x-stillfail-ts", Number(ts) * 1000]] as const) {
    assert.ok(at > 1_700_000_000_000 && Math.abs(at - Date.now()) < 10 * 60_000, `${what}: ${at}`);
  }
  const status = await given("the status socket says reached", async () => {
    const s = JSON.parse((await ask({ socket: join(data, "run", "status.sock") }, "/v1/status")).body);
    return s.reached === true && s.health?.presenceOnline === true ? s : null;
  });
  assert.equal(status.enrolled, true);
  assert.equal(status.workspace, "w1");

  // ── config.json: read again as another program edits it, written as the admin API edits it ──
  assert.deepEqual(JSON.parse((await ask(mcp, "/admin-api/tools/access")).body).access, "off");
  writeFileSync(join(data, "config.json"), `${JSON.stringify({ language: "en", tools: { access: "read" } })}\n`);
  await given("config.json read again", async () => JSON.parse((await ask(mcp, "/admin-api/tools/access")).body).access === "read");
  const put = await ask(mcp, "/admin-api/tools/access", { method: "PUT", body: JSON.stringify({ access: "full" }) });
  assert.equal(put.status, 200, put.body);
  await given("config.json written", () => readJson(join(data, "config.json"))?.tools?.access === "full");
  assert.equal(readJson(join(data, "config.json")).language, "en", "what the edit did not touch kept");

  // ── the machine (GET /host), as the station samples it ──
  const host = JSON.parse((await ask(mcp, "/admin-api/host")).body);
  assert.equal(typeof host.hostname, "string");
  assert.ok(host.cpus >= 1, JSON.stringify(host));
  assert.ok(host.memory.totalBytes > 0, JSON.stringify(host.memory));
  assert.equal(host.disk.path, data);
  assert.ok(host.disk.totalBytes > 0);
  assert.ok(host.stationRssBytes > 0);

  // ── the overview, with the parts' fields (the rigs'), and the rigs' own route ──
  const overview = JSON.parse((await ask(mcp, "/admin-api/overview")).body);
  assert.deepEqual(overview.rigs, [], JSON.stringify(overview).slice(0, 400));
  assert.equal(overview.mesh?.state ?? overview.cloud?.state ?? "running", "running");
  const rigs = await ask(mcp, "/admin-api/rigs");
  assert.equal(rigs.status, 200, rigs.body);
  assert.deepEqual(JSON.parse(rigs.body), { workspace: "w1", rigs: [] });
  const mode = await ask(mcp, "/admin-api/mode", { body: JSON.stringify({ mode: "whole" }) });
  assert.equal(mode.status, 400, "the rigs' route answers what it refuses");

  // ── an event stream, told of a change the store made ──
  const stream = events(mcp, "/admin-api/events");
  assert.equal(await stream.opened, 200);
  const retitled = await ask(mcp, `/admin-api/threads/${thread.id}/title`, { method: "PUT", body: JSON.stringify({ title: "renamed" }) });
  assert.equal(retitled.status, 200, retitled.body);
  await given("the stream told of the chat renamed", () => stream.text().includes(`event: chat-changed\ndata: ${JSON.stringify({ thread: thread.id })}`));
  stream.close();
  const after = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  assert.equal(after.getThread(thread.id)?.title, "renamed");
  after.close();

  // its heartbeat on the presence socket (every 30 s), answered: online still
  await given("a ping on the presence socket", () => socket.said.includes("ping"), 40_000);
  assert.equal(readJson(join(data, "run", "health.json")).presenceOnline, true);

  // ── a stop: what it hands over written, nothing of it left ──
  const pid = a.child.pid!;
  const kids = childrenOf(pid);
  assert.ok(kids.length > 0, "its readers run");
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
  for (const k of kids) await given(`its child ${k} gone`, () => { try { process.kill(k, 0); return false; } catch { return true; } });
});

/// A request of the admin API with a body of bytes: its status and bytes.
function askBytes(port: number, path: string, o: { method?: string; body?: Buffer } = {}): Promise<{ status: number; body: Buffer }> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers: { "content-type": "application/octet-stream" } }, (res) => {
      const got: Buffer[] = [];
      res.on("data", (d: Buffer) => got.push(d));
      res.on("end", () => resolve({ status: res.statusCode!, body: Buffer.concat(got) }));
    });
    req.on("error", reject);
    req.end(o.body);
  });
}

test("the admin API's files as bytes: an image uploaded whole and in parts, one kept already cloned, a folder's entries and an image read back", { skip }, async () => {
  const plane = await controlPlane();
  const data = fresh("files");
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9502\n");
  const id = stationId(data);
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: {}, peers: [], revocations: [],
  }));
  writeFileSync(join(data, "config.json"), `${JSON.stringify({ language: "en" })}\n`);
  // A PNG (its bytes no UTF-8) and a file of every byte, past what one part carries in a test of two.
  const png = Buffer.from("89504e470d0a1a0a0000000d4948445200000001000000010806000000" + "1f15c4890000000d49444154789c6360f8cfc0f01f0005000201" + "e5274de80000000049454e44ae426082", "hex");
  const every = Buffer.concat(Array.from({ length: 8 }, () => Buffer.from(Array.from({ length: 256 }, (_, i) => 255 - i))));
  // A session whose workspace holds a folder (a file, a folder, a link) and an image sent in it.
  mkdirSync(join(work, "uploads"), { recursive: true });
  writeFileSync(join(work, "uploads", "shot.png"), png);
  mkdirSync(join(work, "sub", "Inner"), { recursive: true });
  writeFileSync(join(work, "sub", "a.txt"), "a\n");
  symlinkSync(join(work, "sub", "a.txt"), join(work, "sub", "link"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  store.close();

  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1" });
  await a.next("ready", (m) => m.ready === true);
  const mcp = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;

  // ── an upload whole: its bytes on the disk as they were sent ──
  const whole = await askBytes(mcp, "/admin-api/uploads?name=shot.png", { body: png });
  assert.equal(whole.status, 200, whole.body.toString());
  const sent = JSON.parse(whole.body.toString());
  assert.equal(sent.size, png.length);
  assert.deepEqual(readFileSync(sent.path), png, "the image's bytes as they were");

  // ── in parts: the first, the first again (taken once), the rest; then the same content kept already, cloned ──
  const part = (q: string, body: Buffer) => askBytes(mcp, `/admin-api/uploads/parts?${q}`, { body }).then((r) => {
    assert.equal(r.status, 200, r.body.toString());
    return JSON.parse(r.body.toString());
  });
  const q = `id=parts-0001&name=every.bin&size=${every.length}`;
  assert.deepEqual(await part(`${q}&offset=0`, every.subarray(0, 1000)), { have: 1000 });
  assert.deepEqual(await part(`${q}&offset=0`, every.subarray(0, 1000)), { have: 1000 }, "a part asked again is not added again");
  const done = await part(`${q}&offset=1000`, every.subarray(1000));
  assert.equal(done.have, every.length);
  assert.deepEqual(readFileSync(done.file.path), every, "the parts' bytes as they were, in order");
  const sha256 = createHash("sha256").update(every).digest("hex");
  const kept = await part(`id=parts-0002&name=every.bin&size=${every.length}&offset=0&sha256=${sha256}`, Buffer.alloc(0));
  assert.equal(kept.have, every.length, "kept already: nothing to send");
  assert.notEqual(kept.file.path, done.file.path, "a copy of its own");
  assert.deepEqual(readFileSync(kept.file.path), every, "the copy's bytes as the file's");

  // ── a folder of the session's: its entries by kind (a link neither), folders first ──
  const peek = await ask(mcp, `/admin-api/sessions/s1/peek?path=${encodeURIComponent(join(work, "sub"))}`);
  assert.equal(peek.status, 200, peek.body);
  const folder = JSON.parse(peek.body);
  assert.equal(folder.kind, "dir", peek.body);
  assert.deepEqual(folder.entries, ["Inner/", "a.txt", "link"]);
  assert.equal(folder.count, 3);
  // ── the image sent in it, read back whole, and as a preview ──
  const file = await askBytes(mcp, "/admin-api/sessions/s1/files?name=shot.png");
  assert.equal(file.status, 200, file.body.toString());
  assert.deepEqual(file.body, png);
  const shown = await ask(mcp, `/admin-api/sessions/s1/peek?path=${encodeURIComponent(join(work, "uploads", "shot.png"))}`);
  assert.equal(shown.status, 200, shown.body);
  assert.deepEqual(Buffer.from(JSON.parse(shown.body).image.data, "base64"), png);
  // ── what is not there: its code kept (the route's words for it) ──
  const gone = await ask(mcp, "/admin-api/sessions/s1/files?name=gone.png");
  assert.equal(gone.status, 404, gone.body);

  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("a machine enrolled as a rig starts as one, answers as one, and stops with nothing of it left", { skip }, async () => {
  const plane = await controlPlane();
  const data = fresh("rig");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9501\n");
  const id = stationId(data);
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "rig", relay_url: "", relay_urls: [], grant_keys: {}, peers: [], revocations: [],
    rig: { owner: "u1", owner_email: "a@b.c", owner_name: "A", person: "ab".repeat(32) },
  }));
  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1" });
  await a.next("ready", (m) => m.ready === true);
  const mcp = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  // on the plane as a rig
  await given("the presence socket", () => plane.sockets[0]);
  await given("presence.json online", () => readJson(join(data, "run", "presence.json"))?.online === true);
  // a rig serves no member: no admin API of a station's, no rigs' part of one
  assert.equal((await ask(mcp, "/admin-api/overview")).status, 404);
  // nothing to hand over turn by turn: drained at once
  a.tell({ op: "drain" });
  assert.deepEqual(await a.next("drained", (m) => m.drained !== undefined), { drained: "idle" });
  const pid = a.child.pid!;
  const kids = childrenOf(pid);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
  for (const k of kids) await given(`its child ${k} gone`, () => { try { process.kill(k, 0); return false; } catch { return true; } });
  assert.deepEqual(childrenOf(pid), []);
});

/// A UDP port free now on 127.0.0.1 (each station's endpoint bound there, its roster entry naming it).
async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

const line = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

/// A member's connection: its credential first, answered.
async function member(conn: Connection, credential: string) {
  const first = await conn.openBi();
  await line(first, { credential, protocol: 2 });
  return new Reader(first).line();
}

/// One request of a member's on its own stream: its status and JSON body.
async function memberAsk(conn: Connection, method: string, path: string, body?: unknown): Promise<[number, any]> {
  const stream = await conn.openBi();
  await line(stream, { method, path, headers: { "content-type": "application/json" } });
  if (body !== undefined) await stream.write(Buffer.from(JSON.stringify(body)));
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  return [head.status, JSON.parse((await reader.rest()).toString() || "null")];
}

/// The mesh addon of the machine's (native/mesh), where it is built.
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();

test("on the mesh: a member let in by its credential asks the admin API; two stations ask each other and carry a web request", { skip: skip || (addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)" : false) }, async () => {
  const grant = new GrantKey();
  const [dataA, dataB] = [fresh("ma"), fresh("mb")];
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9502\n");
  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: idA, name: "alpha", ips: [`127.0.0.1:${portA}`] }, { id: idB, name: "beta", ips: [`127.0.0.1:${portB}`] }];
  const plane = await controlPlane(peers);
  for (const [data, id, name] of [[dataA, idA, "alpha"], [dataB, idB, "beta"]] as const) {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
      origin: plane.origin, station: id, workspace: "w1", workspace_name: "团队", name, relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] }, peers, revocations: [],
    }));
  }
  const env = (port: number) => ({ STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${port}` });
  const [a, b] = [await launch(dataA, app, env(portA)), await launch(dataB, app, env(portB))];
  await a.next("ready", (m) => m.ready === true);
  await b.next("ready", (m) => m.ready === true);
  const mcpB = (await b.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  for (const d of [dataA, dataB]) await given("online at the plane", () => readJson(join(d, "run", "presence.json"))?.online === true);

  // ── a member, by real iroh: let in by the credential the workspace's key signed, then the admin API ──
  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  after(() => client.close());
  const now = Math.floor(Date.now() / 1000);
  const credential = () => grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u1", email: "o@x.co", name: "O", ws: "w1", role: "owner", device: client.id(), sid: "s1", iat: now, exp: now + 3600 });
  const toA = await given("connected to alpha", () => client.connect({ id: idA, ips: [`127.0.0.1:${portA}`] }, Buffer.from("stillfail/admin/1")));
  const hello = await member(toA, credential());
  assert.equal(hello.ok, true, JSON.stringify(hello));
  const [rigsStatus, rigs] = await memberAsk(toA, "GET", "/admin/api/rigs");
  assert.equal(rigsStatus, 200);
  assert.deepEqual(rigs, { workspace: "w1", rigs: [] });
  const [overviewStatus, overview] = await memberAsk(toA, "GET", "/admin/api/overview");
  assert.equal(overviewStatus, 200);
  assert.deepEqual(overview.rigs, []);
  // one whose credential another key signed is refused
  const stranger = await client.connect({ id: idA, ips: [`127.0.0.1:${portA}`] }, Buffer.from("stillfail/admin/1"));
  const refused = await member(stranger, new GrantKey().credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u2", ws: "w1", role: "owner", device: client.id(), sid: "s2", iat: now, exp: now + 3600 }));
  assert.notEqual(refused.ok, true);

  // ── the two stations ask each other (stillfail/station/2): alpha's new name carried to beta's copy ──
  const [marked, markSaid] = await memberAsk(toA, "PUT", "/admin/api/station-mark", { name: "Alpha One" });
  assert.equal(marked, 200, JSON.stringify(markSaid));
  const toB = await client.connect({ id: idB, ips: [`127.0.0.1:${portB}`] }, Buffer.from("stillfail/admin/1"));
  assert.equal((await member(toB, credential())).ok, true);
  await given("beta's copy of alpha's mark", async () => {
    const [, marks] = await memberAsk(toB, "GET", "/admin/api/station-marks");
    return JSON.stringify(marks).includes("Alpha One");
  });

  // ── a web request of a service on alpha's machine, from beta's agents' door (/peer, stillfail/http/1) ──
  const bytes = Buffer.from([0, 1, 2, 200, 255, 10, 13, 0, 128]);
  const service = httpServer((req, res) => {
    res.writeHead(201, { "content-type": "application/octet-stream", "x-said": `${req.method} ${req.url}` }).end(bytes);
  });
  await new Promise<void>((r) => service.listen(0, "127.0.0.1", () => r()));
  after(() => service.close());
  const servicePort = (service.address() as AddressInfo).port;
  const carried = await new Promise<{ status: number; headers: Record<string, unknown>; body: Buffer }>((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port: mcpB, path: `/peer/${idA}/${servicePort}/hello?x=1` }, (res) => {
      const parts: Buffer[] = [];
      res.on("data", (d) => parts.push(d));
      res.on("end", () => resolve({ status: res.statusCode!, headers: res.headers, body: Buffer.concat(parts) }));
    });
    req.on("error", reject);
    req.end();
  });
  assert.equal(carried.status, 201, carried.body.toString());
  assert.equal(carried.headers["x-said"], "GET /hello?x=1");
  assert.equal(carried.headers["content-type"], "application/octet-stream");
  assert.deepEqual(carried.body, bytes, "the service's bytes as they were");

  for (const s of [a, b]) s.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
  assert.equal(await b.ended, 0, b.err());
});

test("a rig on the mesh: another station's tunnel to a device goes through the rig's grants", { skip: skip || (addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)" : false) }, async () => {
  // (a station of the workspace's, by real iroh, its key the test's)
  const station = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  after(() => station.close());
  const data = fresh("rigmesh");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9503\n");
  const id = stationId(data);
  const port = await freeUdpPort();
  const peers = [{ id: station.id(), name: "alpha", ips: [] }, { id, name: "rig", ips: [`127.0.0.1:${port}`] }];
  const plane = await controlPlane(peers);
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "rig", relay_url: "", relay_urls: [], grant_keys: {}, peers, revocations: [],
    rig: { owner: "u1", owner_email: "a@b.c", owner_name: "A", person: "ab".repeat(32) },
  }));
  const r = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${port}` });
  await r.next("ready", (m) => m.ready === true);
  await given("presence.json online", () => readJson(join(data, "run", "presence.json"))?.online === true);
  // a device the rig has none of: refused by its grants (`Rig::device`), not by a whole station's devices
  const conn = await given("connected to the rig", () => station.connect({ id, ips: [`127.0.0.1:${port}`] }, Buffer.from("stillfail/http/1")));
  const asked = async (probe: boolean) => {
    const stream = await conn.openBi();
    await line(stream, { workspace: "w1", session: "s1", device: "0123456789abcdef", tcp: true, probe });
    await stream.finish();
    const reader = new Reader(stream);
    const head = await reader.line();
    return { status: head.status, body: (await reader.rest()).toString() };
  };
  for (const probe of [true, false]) {
    const said = await asked(probe);
    assert.equal(said.status, 404, JSON.stringify(said));
    assert.equal(said.body, "that machine refused: no such device on this rig");
  }
  r.tell({ op: "stop" });
  assert.equal(await r.ended, 0, r.err());
});

test("a part's route matched as the admin API matches it: a pattern's groups, Express's segments by name", { skip }, async () => {
  const child = spawn(harnessProgram!, ["--builder", "harness-station-main", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "inherit"], env: noNode() });
  children.push(child);
  const lines = createInterface({ input: child.stdout! });
  const answers: any[] = [];
  lines.on("line", (l) => answers.push(JSON.parse(l)));
  const match = async (pattern: string, path: string) => {
    const id = answers.length + 1000 + Math.random();
    child.stdin!.write(`${JSON.stringify({ id, op: "partRoute", pattern, path })}\n`);
    const found = await given(`the harness's answer to ${pattern}`, () => answers.find((x) => x.id === id));
    return found.ok;
  };
  assert.deepEqual(await match("/terminals/:id/end", "/terminals/t%201/end"), { id: "t 1" });
  assert.deepEqual(await match("/terminals", "/terminals"), {});
  assert.equal(await match("/profiles", "/profiles/123/check"), null, "a prefix is no match");
  assert.equal(await match("/profiles/:id/check", "/profiles/123"), null);
  assert.deepEqual(await match("/files/*", "/files/a/b"), { "*": "a/b" });
  assert.deepEqual(await match("^\\/rigs\\/([0-9a-f]{64})\\/log$", `/rigs/${"ab".repeat(32)}/log`), ["ab".repeat(32)]);
  assert.equal(await match("^\\/rigs$", "/rigs/x"), null);
  child.stdin!.end();
});
