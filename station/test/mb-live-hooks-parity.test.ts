// The MoonBit station's hooks that are no call by name (station/mb src/station_main), held live: `stillfail-reader run`
// under a launcher of the test's, with no Node, against a control plane of the test's (its HTTP, its release feed, its
// model catalog and its presence socket, which the test speaks on). What the TypeScript does with each, the program
// must do:
//
// - the presence socket's `release` reads the release again at once (sessions/agents.ts, rig/main.ts
//   `plane.told("release", …)`), on a whole station and on a rig; its `models` reads the model catalog again
//   (models/module.ts `plane.told("models", …)`);
// - config.json and cloud.json changed tell the event streams the overview again (agents.ts `config.listen`,
//   `cloud.listen`);
// - health.json says whether a relay holds the endpoint for another (`relayConflict`, mesh/native.ts);
// - the station's own memory counts the readers' programs and lets go of those that answer nothing (pool.ts
//   `trimIdle`, `onTrim`);
// - the moves plan an owner's secrets (move/live.ts `vault`);
// - a whole station listed as a rig with what its owner asked (cloud.json `rig_due`, `rig_pending`) becomes one
//   (agents.ts `follow`).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, createPublicKey, generateKeyPairSync, sign } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer as netServer, type Server } from "node:net";
import { createServer as httpServer, request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { WebSocketServer, type WebSocket } from "ws";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
// (short: a Unix socket's path is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sfh-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
after(async () => {
  for (const c of closers.splice(0)) c();
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  for (const d of dirs) rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

/// An environment with no Node: an empty PATH of its own, HOME and TMPDIR as given.
const noNode = (more: Record<string, string> = {}) => ({ PATH: fresh("path"), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), ...more });

/// What `f` comes to, looked at again as the program goes on (its files, its sockets): there within `ms`, or the test
/// fails saying what it waited for.
async function given<T>(what: string, f: () => T | null | undefined | false | Promise<T | null | undefined | false>, detail: () => string = () => "", ms = 20_000): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}; ${detail()}`);
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

// The tests' release key and a feed it signed (scripts/release-sign.ts's shape).
const { privateKey } = generateKeyPairSync("ed25519");
const RAW = Buffer.from(createPublicKey(privateKey).export({ format: "jwk" }).x as string, "base64url").toString("base64");
const keyId = createHash("sha256").update(Buffer.from(RAW, "base64")).digest("hex").slice(0, 16);
const feedOf = (build: number) => {
  const words = Buffer.from(JSON.stringify({
    kind: "stillfail-station-release", version: `0.1.${build}`, build, commit: "0".repeat(40), node: "24.21.0",
    builds: { "darwin-arm64": { sha256: "a".repeat(64), size: 1000, nodeSha256: "b".repeat(64) }, "linux-x64": { sha256: "a".repeat(64), size: 1000, nodeSha256: "b".repeat(64) } },
  }));
  return { version: `0.1.${build}`, build, commit: "0".repeat(40), release: words.toString("base64"), signature: sign(null, words, privateKey).toString("base64"), key: keyId };
};

/// The control plane of the test's: the release feed (`/releases/station.json`), the model catalog (`/v1/models`, its
/// ETag the test's to change), every other request answered `{}`, and its presence socket, which says the station's
/// state as it connects (unless `state` is false) and carries what the test pushes.
async function controlPlane(o: { state?: boolean } = {}) {
  const asked: string[] = [];
  const sockets: WebSocket[] = [];
  const peers: unknown[] = [];
  const catalog = { etag: '"m-1"', models: { "m-1": { name: "One" } } as Record<string, unknown> };
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => {
      const url = req.url ?? "";
      asked.push(url);
      if (url === "/releases/station.json") return void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(feedOf(9500)));
      if (url.startsWith("/releases/")) return void res.writeHead(404, { "content-type": "application/json" }).end("{}");
      if (url.startsWith("/v1/models")) {
        return void res.writeHead(200, { "content-type": "application/json", etag: catalog.etag }).end(JSON.stringify({ models: catalog.models }));
      }
      res.writeHead(200, { "content-type": "application/json" }).end("{}");
    });
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      if (o.state !== false) ws.send(JSON.stringify({ type: "state", workspace: "w1", workspace_name: "团队", name: "mac", peers, relay_urls: [] }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  const push = (frame: unknown) => {
    for (const s of sockets) if (s.readyState === s.OPEN) s.send(JSON.stringify(frame));
  };
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, asked, sockets, catalog, push, peers };
}

/// A data directory in workspace w1 of `origin` (cloud.json as the control plane wrote it, with `more`), its release
/// its own `app`, config.json as given.
function station(origin: string, config: object, more: object = {}): { data: string; app: string; id: string } {
  const data = fresh("data");
  const made = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(made.status, 0, made.stderr);
  const id = made.stdout.trim();
  const app = join(data, "app");
  mkdirSync(app, { recursive: true });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(app, "BUILD"), "9400\n");
  writeFileSync(join(data, "config.json"), `${JSON.stringify(config)}\n`);
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: {}, peers: [], revocations: [], ...more,
  }));
  return { data, app, id };
}

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string };

/// `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fourth's pipe.
async function launch(data: string, app: string, env: Record<string, string>): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = netServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_RELEASE_KEYS: RAW, ...env }),
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => said.push(JSON.parse(line)));
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) => given(what, () => said.find(ok), () => `said ${JSON.stringify(said)}; stderr ${err}`);
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

/// A request of the station's door: its status and body.
function ask(port: number, path: string, o: { method?: string; body?: unknown } = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers: { "content-type": "application/json" } }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text }));
    });
    req.on("error", reject);
    req.end(o.body === undefined ? undefined : JSON.stringify(o.body));
  });
}

/// An event stream of the admin API (GET /events): what it said so far, as it comes.
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
  closers.push(() => close());
  return { opened, close: () => close(), text: () => heard.join("") };
}

/// The processes `pid` started that are still there.
const childrenOf = (pid: number) => spawnSync("pgrep", ["-P", String(pid)], { encoding: "utf8" }).stdout.trim().split("\n").filter((l) => l !== "").map(Number);
const count = (xs: string[], x: string) => xs.filter((y) => y === x).length;

test("a whole station: the plane's models read at once, config.json and cloud.json told on the event streams, health.json's relayConflict, the readers counted and trimmed, an owner's secrets planned to move", { skip }, async () => {
  const plane = await controlPlane();
  const peer = "b".repeat(64);
  const { data, app, id } = station(plane.origin, { updateChannel: "stable", language: "en" });
  // (another station of the workspace, for what it asks of the moves)
  const cloudFile = join(data, "mesh", "cloud.json");
  plane.peers.push({ id, name: "mac" }, { id: peer, name: "other" });
  writeFileSync(cloudFile, JSON.stringify({ ...readJson(cloudFile), peers: plane.peers }));
  // A session in two chats: which is its chat is the copy index's to say, not prepared on a store new to it.
  const seed = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  seed.insertSession({ key: "s1", connect: "local", runtime: "claude", profile: "cc", workspace: data, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  for (const ts of ["t1", "t2"]) seed.joinThread(seed.openThread("ember", "local", ts, `chat ${ts}`, null).id, "s1", "local");
  seed.close();
  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_PARTS_DOOR: "1" });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  await given("the presence socket", () => plane.sockets[0], a.err);
  await given("presence.json online", () => readJson(join(data, "run", "presence.json"))?.online === true, a.err);

  // ── the release: read as the station starts (read again as the plane says one is out: the rig's test below, the
  // whole station's check being the same `bus.on_release` but reading the runtimes' registries too) ──
  await given("the stable feed read", () => plane.asked.includes("/releases/station.json"), a.err);

  // ── the model catalog: read as the station starts, then the one the plane says it changed to ──
  await given("the catalog read", () => readJson(join(data, "model-catalog.json"))?.etag === '"m-1"', () => `${JSON.stringify(plane.asked)}; ${a.err()}`);
  plane.catalog.etag = '"m-2"';
  plane.catalog.models = { "m-2": { name: "Two" } };
  plane.push({ type: "models", etag: '"m-2"' });
  await given("the catalog the plane named asked for", () => plane.asked.includes(`/v1/models?v=${encodeURIComponent('"m-2"')}`), () => `${JSON.stringify(plane.asked)}; ${a.err()}`);
  await given("model-catalog.json written anew", () => readJson(join(data, "model-catalog.json"))?.etag === '"m-2"', a.err);
  assert.deepEqual(Object.keys(readJson(join(data, "model-catalog.json")).models), ["m-2"]);
  // ── the readers price by the catalog as well (read/pool.ts `give`): a price it says is the usage page's ──
  const prices = async () => (JSON.parse((await ask(door, "/admin-api/usage")).body)?.prices?.rows ?? []) as { model: string; input: number }[];
  assert.equal((await prices()).find((p) => p.model === "claude-opus-5-5")?.input, 4, "the station's own table before the catalog names it");
  plane.catalog.etag = '"m-3"';
  plane.catalog.models = { "claude-opus-5-5": { name: "Opus", cost: { input: 7, output: 35, cacheRead: 0.7 } } };
  plane.push({ type: "models", etag: '"m-3"' });
  await given("model-catalog.json written with a price", () => readJson(join(data, "model-catalog.json"))?.etag === '"m-3"', a.err);
  let pricedNow: unknown = null;
  await given("the usage page priced by the catalog", async () => (pricedNow = await prices(), (pricedNow as { model: string; input: number }[]).find((p) => p.model === "claude-opus-5-5")?.input === 7), () => `${JSON.stringify(pricedNow)}; ${a.err()}`);

  // ── the event streams told the overview again as config.json and cloud.json change ──
  const stream = events(door, "/admin-api/events");
  assert.equal(await stream.opened, 200);
  const overviews = () => stream.text().split("event: overview\n").length - 1;
  const seen = { n: overviews() + 1 };
  // config.json edited by another program: a connect added (the overview's `connects`)
  writeFileSync(join(data, "config.json"), `${JSON.stringify({ updateChannel: "stable", language: "en", connects: [{ id: "s9", kind: "slack", enabled: false, bind: { runtime: "claude" }, slack: { appToken: "xapp-9", botToken: "xoxb-9" } }] })}\n`);
  await given("the overview told as config.json changed", () => overviews() >= seen.n && stream.text().includes('"s9"'), () => `${stream.text().slice(-2000)}; ${a.err()}`);
  // cloud.json as the plane's state frame changes it: the workspace's name
  const before = overviews();
  plane.push({ type: "state", workspace: "w1", workspace_name: "新团队", name: "mac", peers: plane.peers, relay_urls: [] });
  await given("the overview told as cloud.json changed", () => overviews() > before && stream.text().includes("新团队"), () => `${stream.text().slice(-2000)}; ${a.err()}`);
  stream.close();

  // ── health.json: a relay holding the endpoint for another is said (none here: no relay) ──
  const health = await given("health.json", () => readJson(join(data, "run", "health.json")));
  assert.equal(health.relayConflict, false);

  // ── the station's own memory: its readers' programs counted, those idle let go and started again as asked ──
  const kids = childrenOf(a.child.pid!);
  const trimmed = await ask(door, "/parts/ask/memory.trimIdle", { body: {} });
  assert.equal(trimmed.status, 200, trimmed.body);
  const t = JSON.parse(trimmed.body);
  assert.ok(t.readers >= 1, `the idle readers let go: ${trimmed.body}`);
  assert.ok(Array.isArray(t.programs), trimmed.body);
  const sample = JSON.parse((await ask(door, "/parts/ask/memory.sample", { body: {} })).body);
  assert.equal(typeof sample.mbChildrenRssMb, "number", JSON.stringify(sample));
  // (the station answers as before once its idle readers are let go)
  const overview = await ask(door, "/admin-api/overview");
  assert.equal(overview.status, 200, overview.body);
  assert.ok(t.programs.length >= 1 && t.programs.every((p: number) => kids.includes(p)), `the programs counted are the station's own children: ${trimmed.body} (children: ${kids.join(",")})`);

  // ── the moves: an owner's plain secret is an item of the vault's module ──
  const db = new DatabaseSync(join(data, "stillfail.db"));
  db.exec("PRAGMA busy_timeout = 5000");
  db.prepare("INSERT INTO vault_plain (ws, id, owner, version, body) VALUES (?, ?, ?, ?, ?)").run("w1", "p1", "u1", 1, JSON.stringify({ id: "p1", owner: "u1", name: "token", version: 1 }));
  db.close();
  // (a grant of u1's the session holds: the chat needs u1's secrets where it goes, vault.moveGrantOwners)
  const grants = new DatabaseSync(join(data, "stillfail.db"));
  grants.exec("PRAGMA busy_timeout = 5000");
  grants.prepare("INSERT INTO vault_grants (ws, id, session, body) VALUES (?, ?, ?, ?)").run("w1", "g1", "s1", JSON.stringify({ request: { owner: "u1" } }));
  grants.close();
  const plan = await ask(door, "/admin-api/move");
  assert.equal(plan.status, 200, plan.body);
  const modules = JSON.parse(plan.body).modules;
  const vault = modules.find((m: any) => m.id === "vault");
  assert.ok(vault !== undefined, plan.body);
  assert.equal(vault.total, 1, JSON.stringify(vault));
  assert.equal(vault.items[0]?.id, "vault:u1@w1", JSON.stringify(vault));
  const chat = modules.find((m: any) => m.id === "chats")?.items.find((i: any) => JSON.stringify(i).includes("s1"));
  assert.ok(chat !== undefined && JSON.stringify(chat.needs).includes("vault:u1@w1"), `the chat needs u1's secrets: ${JSON.stringify(chat)}`);

  // ── the moves' vault module taking another station's secrets and letting them go again (move.vault.put, back) ──
  const plain = { ws: "w1", id: "p2", owner: "u2", version: 1, kind: "token", name: "theirs", fields: {}, notes: "" };
  const kept = { ws: "w1", id: "v2", owner: "u2", seq: 1, name: "their vault" };
  const item = { ws: "w1", vault: "v2", id: "i2", version: 1 };
  const put = await ask(door, `/parts/peer/move.vault.put?from=${peer}`, { body: { method: "move.vault.put", workspace: "w1", ws: "w1", owner: "u2", plain: [plain], vault: kept, items: [item] } });
  assert.equal(put.status, 200, put.body);
  const counted = () => {
    const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
    try {
      const n = (sql: string) => (db.prepare(sql).get() as { n: number }).n;
      return [n("SELECT count(*) AS n FROM vault_plain WHERE id = 'p2'"), n("SELECT count(*) AS n FROM vaults WHERE id = 'v2'"), n("SELECT count(*) AS n FROM vault_items WHERE id = 'i2'")];
    } finally {
      db.close();
    }
  };
  assert.deepEqual(counted(), [1, 1, 1], "the plain secret, the vault and its item kept here");
  const back = await ask(door, `/parts/peer/move.vault.back?from=${peer}`, { body: { method: "move.vault.back", workspace: "w1", ws: "w1", owner: "u2" } });
  assert.equal(back.status, 200, back.body);
  assert.deepEqual(counted(), [0, 0, 0], "what the move put here taken out again");

  // ── a session in two chats: its chat asked, the copy index's names prepared for it (threads.requested drained) ──
  const asked = await ask(door, "/parts/hub/store.sessionChat", { body: ["s1"] });
  assert.equal(asked.status, 200, asked.body);
  await given("the session's chat names prepared by the copy index", () => {
    const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
    try {
      return (db.prepare("SELECT complete FROM session_chat_scopes WHERE session = 's1'").get() as { complete: number } | undefined)?.complete === 1;
    } finally {
      db.close();
    }
  }, a.err);

  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("a rig reads its release again at once as the plane says one is out", { skip }, async () => {
  const plane = await controlPlane();
  const { data, app } = station(plane.origin, { updateChannel: "stable" }, { name: "rig", rig: { owner: "u1", owner_email: "a@b.c", owner_name: "A", person: "ab".repeat(32) } });
  const a = await launch(data, app, {});
  await a.next("ready", (m) => m.ready === true);
  await given("the presence socket", () => plane.sockets[0], a.err);
  await given("the stable feed read", () => plane.asked.includes("/releases/station.json"), () => `${JSON.stringify(plane.asked)}; ${a.err()}`);
  const reads = count(plane.asked, "/releases/station.json");
  plane.push({ type: "release" });
  await given("the feed read again as the plane said a release is out", () => count(plane.asked, "/releases/station.json") > reads, () => `${JSON.stringify(plane.asked)}; ${a.err()}`);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("a whole station listed as a rig with what its owner asked becomes one: its agents' side ends, cloud.json says it is a rig, the process gives way", { skip }, async () => {
  // (no state frame: what cloud.json says as it starts is what the agents' side follows)
  const plane = await controlPlane({ state: false });
  const due = { owner: "u1", owner_email: "a@b.c", owner_name: "A", person: "cd".repeat(32), at: Date.now() };
  const { data, app } = station(plane.origin, { updateChannel: "stable" }, { rig_due: true, rig_pending: due });
  const a = await launch(data, app, {});
  await a.next("ready", (m) => m.ready === true);
  const cloud = await given("cloud.json says it is a rig", () => {
    const c = readJson(join(data, "mesh", "cloud.json"));
    return c?.rig !== undefined ? c : null;
  }, a.err);
  assert.deepEqual(cloud.rig, { owner: "u1", owner_email: "a@b.c", owner_name: "A", person: "cd".repeat(32) });
  assert.equal(cloud.rig_due, undefined);
  assert.equal(cloud.rig_pending, undefined);
  // (with no launcher to hand over to, the station's process ends for the rig's)
  let code: number | null | undefined;
  void a.ended.then((c) => (code = c));
  await given("the station's process ended for the rig's", () => code !== undefined, () => `cloud.json ${JSON.stringify(readJson(join(data, "mesh", "cloud.json")))}; ${a.err()}`);
  assert.equal(code, 0, a.err());
});
