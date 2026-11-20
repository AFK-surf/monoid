// Faults and edges of the phones, the device tools and the connects as the MoonBit station (`stillfail-reader run`, no
// Node on its PATH) holds them, the TypeScript's unit tests (adb-grants, phone-outcome-outbox, adb, device-tools,
// group-connect, workspace-connects) asked of the real program:
// 1. A phone asked for (`device_use`): granted, denied, taken back and run out each said on its card in order, the card
//    closed at once; a chat holding no grant refused throughout. Outcomes queued while their cards cannot be written go
//    over a handover and are written once, in order, by the station after; the phone's connection to the station
//    before closed as it goes. An outcome that cannot be queued leaves the request and its card as they were.
// 2. The device tools over `comma/tools/1`: refused to a peer that is not a gateway and for another workspace; `off`
//    (or unset) refusing all, `read` only the reads, `full` all, read at each request; a command's output cut at
//    1 MiB, one that runs on ended at its timeout.
// 3. A group connect: a direct space's messages, said while its link is cut and while the station is stopped, each
//    taken once; a card asked before a stop answered after it, the answer the person's message.
// 4. A Slack connect naming another station of the workspace: a new thread's chat runs there over real iroh, what
//    follows in it goes there, what its agent says goes out through the connect; a thread begun before stays here; that
//    station down, the thread is told.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createSocket } from "node:dgram";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { ImServer } from "./group-im.ts";

const binary = mbReaderBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();

function binOf(name: string): string {
  const search = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"];
  for (const d of search) {
    const at = join(d, name);
    if (existsSync(at)) return at;
  }
  return "";
}

const skipBase = binary === null
  ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32"
    ? "the launcher's descriptors are Unix's"
    : false;
const skipMesh = skipBase || (addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)" : false);
const skipAdb = skipMesh || (binOf("python3") === "" ? "python3 is not here for the fake adb" : false);
const skipAgents = skipMesh ||
  (runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)" : false) ||
  (!existsSync("/usr/bin/curl") ? "no /usr/bin/curl for the fake runtime" : false);

const dirs: string[] = [];
// (short: Unix sockets on macOS are capped at 104 bytes)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfad-${what}-`));
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
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (existsSync(runners)) {
      for (const f of readdirSync(runners)) {
        if (!f.endsWith(".json")) continue;
        try {
          const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
          try { process.kill(-info.pgid, "SIGKILL"); } catch {}
          try { process.kill(info.runner, "SIGKILL"); } catch {}
        } catch {}
      }
    }
    rmSync(d, { recursive: true, force: true, maxRetries: 5 });
  }
});

const TOOLS = ["sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "python3", "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "tail", "wc", "uname", "dd", "lsof", "awk", "yes"];

/// A PATH of the tools a station runs, Node not among them.
function toolsPath(dir = fresh("path")): string {
  for (const t of TOOLS) {
    const found = binOf(t);
    if (found !== "" && !found.includes("node") && !existsSync(join(dir, t))) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false, "no Node on PATH");
  return dir;
}

type Launched = {
  child: ChildProcess;
  next: (what: string, ok: (m: any) => boolean) => Promise<any>;
  tell: (m: unknown) => void;
  ended: Promise<number | null>;
  err: () => string;
  stop: () => Promise<void>;
};

/// `stillfail-reader run` under a launcher of the test's: its descriptors the agents' door, the loopback port and the
/// launcher's channel.
async function launch(data: string, app: string, env: Record<string, string> = {}): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: {
      PATH: env.PATH ?? toolsPath(), HOME: env.HOME ?? fresh("home"), TMPDIR: tmpdir(),
      STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_AGENT_NICE: "0",
      ...(runner !== "" ? { STILLFAIL_RUNNER: runner } : {}),
      ...env,
    },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    try {
      said.push(JSON.parse(line));
    } catch {
      return;
    }
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stdout!.on("data", (d) => (err += d));
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err.slice(-3000)}`)), 25_000);
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
  const tell = (m: unknown) => {
    if (!channel.destroyed) channel.write(`${JSON.stringify(m)}\n`);
  };
  /// Stopped as the launcher stops it; one still there after 30 s is killed and said, never left to hold the run.
  const stop = async () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    tell({ op: "stop" });
    let timer: NodeJS.Timeout | undefined;
    const code = await Promise.race([ended, new Promise<"late">((r) => { timer = setTimeout(() => r("late"), 30_000); })]).finally(() => clearTimeout(timer));
    if (code === "late") {
      child.kill("SIGKILL");
      await ended;
      assert.fail(`the station did not stop within 30 s of being told: ${err.slice(-3000)}`);
    }
    assert.equal(code, 0, err.slice(-3000));
  };
  return { child, next, tell, ended, err: () => err.slice(-4000), stop };
}

async function given<T>(what: string, f: () => T | null | undefined | false | Promise<T | null | undefined | false>, detail: () => string | Promise<string> = () => "", ms = 25_000): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`never came (${ms} ms): ${what}${last ? ` (${(last as Error).message})` : ""}; ${await detail()}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

type Answer = { status: number; text: string; json: any };

function http(port: number, path: string, o: { method?: string; body?: unknown; token?: string } = {}): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = {};
    if (o.body !== undefined) headers["content-type"] = "application/json";
    if (o.token !== undefined) headers.authorization = `Bearer ${o.token}`;
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers, agent: false }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (d) => chunks.push(d as Buffer));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json: any = null;
        try { json = text === "" ? null : JSON.parse(text); } catch {}
        resolve({ status: res.statusCode!, text, json });
      });
    });
    req.on("error", reject);
    req.end(o.body === undefined ? undefined : JSON.stringify(o.body));
  });
}

/// An agent's tool through the agents' door, as the session the bearer names: its text and whether it is an error.
async function tool(port: number, token: string, name: string, args: Record<string, unknown> = {}): Promise<{ text: string; error: boolean }> {
  const r = await http(port, "/mcp", { token, body: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.error, undefined, r.text);
  return { text: r.json.result.content.map((c: any) => c.text ?? "").join("\n"), error: r.json.result.isError === true };
}

function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: { PATH: fresh("empty"), HOME: data, TMPDIR: tmpdir() }, encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

const line = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

async function member(conn: Connection, credential: string) {
  const first = await conn.openBi();
  await line(first, { credential, protocol: 2 });
  return new Reader(first).line();
}

const openStore = (data: string) => Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);

/// The station's database as another connection: waiting for its lock, as every connection to it does.
function withDb<T>(data: string, f: (db: DatabaseSync) => T, readOnly = false): T {
  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly });
  db.exec("PRAGMA busy_timeout = 5000;");
  try {
    return f(db);
  } finally {
    db.close();
  }
}

const readJson = (p: string) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

/// Until `conn` is closed, `ms` at most: how it was closed and how long after `since`.
async function endOf(conn: Connection, since: number, ms = 10_000): Promise<{ why: { kind: string; reason: string } | null; after: number }> {
  let timer: NodeJS.Timeout | undefined;
  await Promise.race([
    conn.closed(),
    new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`the connection not closed within ${ms} ms`)), ms); }),
  ]).finally(() => clearTimeout(timer));
  return { why: conn.closeReason?.() ?? null, after: Date.now() - since };
}

// ── 1. phones ──

/// An adb of python3 alone: `server nodaemon` listens where it is told, `connect` dials the address it is given, and
/// every call is written down.
function fakeAdb(dir: string, state: string) {
  const py = `#!/usr/bin/env python3
import json, os, signal, socket, sys
state_dir = os.environ["FAKE_ADB_DIR"]
args = sys.argv[1:]
with open(os.path.join(state_dir, "calls.jsonl"), "a") as f:
    f.write(json.dumps(args) + "\\n")
port = None
i = 0
while i < len(args) and args[i] == "-P" and i + 1 < len(args):
    port = args[i + 1]
    i += 2
rest = args[i:]
if not rest:
    sys.exit(0)
if rest[0] == "server" and len(rest) >= 2 and rest[1] == "nodaemon":
    sock_env = os.environ.get("ADB_SERVER_SOCKET", "")
    if sock_env.startswith("localfilesystem:"):
        path = sock_env[len("localfilesystem:"):]
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
    else:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", int(port or "5037")))
    srv.listen(16)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    while True:
        try:
            conn, _ = srv.accept()
            conn.close()
        except Exception:
            sys.exit(0)
if rest[0] == "connect" and len(rest) >= 2:
    host, p = rest[1].rsplit(":", 1)
    try:
        s = socket.create_connection((host, int(p)), timeout=5)
        s.sendall(b"CNXN\\n")
        s.recv(64)
        s.close()
        open(os.path.join(state_dir, "state"), "w").write("device")
    except Exception:
        pass
    print("connected to " + rest[1])
    sys.exit(0)
if rest[0] == "disconnect":
    try:
        os.remove(os.path.join(state_dir, "state"))
    except FileNotFoundError:
        pass
    print("disconnected")
    sys.exit(0)
if len(rest) >= 3 and rest[0] == "-s" and rest[2] == "get-state":
    st = os.path.join(state_dir, "state")
    if os.path.exists(st):
        print(open(st).read().strip())
        sys.exit(0)
    sys.stderr.write("error: device '" + rest[1] + "' not found\\n")
    sys.exit(1)
if len(rest) >= 3 and rest[0] == "-s" and rest[2] == "shell":
    if "getprop service.adb.tcp.port" in " ".join(rest[3:]):
        print("boot-1\\n5555")
    sys.exit(0)
if rest[0] == "devices":
    print("List of devices attached")
sys.exit(0)
`;
  writeFileSync(join(dir, "adb"), py);
  chmodSync(join(dir, "adb"), 0o755);
  mkdirSync(state, { recursive: true });
}

type PhoneStation = Awaited<ReturnType<typeof phoneStation>>;

/// A station of workspace `ws` with chats s1, s2 (Pat's) and s3 (another person's), Pat's phone lent to it over the
/// mesh by a device of theirs once `lend` is called.
async function phoneStation(tag: string) {
  const WS = `w-${tag}`;
  const data = fresh(tag);
  const app = fresh("app");
  const bin = toolsPath();
  const adbState = fresh("adbs");
  writeFileSync(join(app, "BUILD"), "10400\n");
  fakeAdb(bin, adbState);
  const id = stationId(data);
  const grantKey = new GrantKey();
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9", station: id, workspace: WS, workspace_name: "PhoneTeam", name: "here",
    relay_url: "", relay_urls: [], grant_keys: { keys: [grantKey.jwk] }, peers: [], revocations: [],
  }));
  const s = openStore(data);
  const sessions = [["s1", "pat@example.com"], ["s2", "pat@example.com"], ["s3", "other@example.com"]] as const;
  const threads: Record<string, number> = {};
  for (const [i, [key, by]] of sessions.entries()) {
    s.insertSession({ key, connect: "chat", runtime: "claude", profile: "cc", workspace: fresh(`w${key}`), token: `t-${key}`, createdBy: by, ws: WS, createdAt: Date.now(), lastActiveAt: Date.now() } as never);
    const th = s.openThread("chat", "CHAT", `17952000${String(i).padStart(2, "0")}.00${i}000`, `${tag} ${key}`, by).id;
    s.joinThread(th, key, "chat");
    threads[key] = th;
  }
  s.close();

  /// A station on its data: serving at once, or (`beside`) up beside the one before, serving once handed over.
  const start = async (beside = false) => {
    const meshPort = await freeUdpPort();
    const st = await launch(data, app, { PATH: bin, FAKE_ADB_DIR: adbState, STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}` });
    await st.next("ready", (m) => m.ready === true);
    const door = beside ? 0 : (await st.next("mcp", (m) => m.serving === "mcp")).port as number;
    return { st, door, meshPort };
  };

  /// Pat's phone, lent over a connection of its own: it answers the station's tunnels and fetches as a phone does.
  const lend = async (meshPort: number, phone: string) => {
    const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
    cleanups.push(() => client.close());
    const now = Math.floor(Date.now() / 1000);
    const cred = grantKey.credential(
      { typ: "stillfail-member+jwt" },
      { iss: "stillfail-cloud", sub: "pat", email: "pat@example.com", name: "Pat", ws: WS, role: "owner", device: client.id(), sid: `s-${tag}`, iat: now, exp: now + 3600 },
    );
    const conn = await given("the phone connected to the station", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")));
    assert.equal((await member(conn, cred)).ok, true);
    let alive = true;
    cleanups.push(() => { alive = false; });
    void (async () => {
      while (alive) {
        let incoming: MeshStream | null = null;
        try {
          incoming = await conn.acceptBi();
        } catch {
          break;
        }
        if (!incoming) break;
        const stream = incoming;
        void (async () => {
          try {
            const reader = new Reader(stream);
            const head = await reader.line();
            if (head?.fetch) {
              await line(stream, { at: Number(head.fetch.size ?? 0) });
              await line(stream, { path: `/data/user/0/fail.still.app/files/${String(head.fetch.name ?? "file")}` });
            } else {
              await line(stream, { ok: true });
              await stream.write(Buffer.from("CNXN-OK\n"));
            }
            await stream.finish();
          } catch {}
        })();
      }
    })();
    const share = await conn.openBi();
    await line(share, { method: "POST", path: "/admin/api/adb", headers: { "content-type": "application/json" }, adb: { op: "share", phone, device: "Pixel-Fake", model: "Pixel 9" } });
    const shareReader = new Reader(share);
    const head = await shareReader.line();
    assert.equal(head.status, 200, JSON.stringify(head));
    void (async () => {
      try {
        while (alive && (await shareReader.line()) !== null) {}
      } catch {}
    })();
    /// One of the owner's asks of `/admin/api/adb` (decide, revoke, grants): its status and body, or what broke it.
    const adb = async (ask: Record<string, unknown>): Promise<[number, any]> => {
      const stream = await conn.openBi();
      await line(stream, { method: "POST", path: "/admin/api/adb", headers: { "content-type": "application/json" }, adb: ask });
      await stream.finish();
      const r = new Reader(stream);
      const h = await r.line();
      return [h.status as number, JSON.parse((await r.rest()).toString() || "null")];
    };
    return { client, conn, adb };
  };
  return { WS, data, app, id, threads, start, lend };
}

const DEVICE = "Pat 的 Pixel-Fake";

/// The phone request a chat's `device_use` left waiting.
const pendingOf = (data: string, session: string) =>
  withDb(data, (db) => db.prepare("SELECT id FROM adb_requests WHERE session = ? AND status = 'pending'").get(session) as { id: string } | undefined, true);

const requestRow = (data: string, id: string) =>
  withDb(data, (db) => {
    const r = db.prepare("SELECT status, body FROM adb_requests WHERE id = ?").get(id) as { status: string; body: string } | undefined;
    return r === undefined ? undefined : { status: r.status, body: JSON.parse(r.body) };
  }, true);

/// The phone card a chat's thread holds (its message's n), and what it says of the request.
const cardOf = (data: string, thread: number, request: string) =>
  withDb(data, (db) => (db.prepare("SELECT n, card FROM entries WHERE thread = ? AND kind = 'message' AND card IS NOT NULL ORDER BY n").all(thread) as { n: number; card: string }[])
    .find((r) => JSON.parse(r.card)?.adb?.request === request), true);

/// The outcomes written on card `n`, in the order its edits were written.
const outcomesOf = (data: string, thread: number, n: number) =>
  withDb(data, (db) => (db.prepare("SELECT card FROM entries WHERE thread = ? AND kind = 'edit' AND target = ? ORDER BY n").all(thread, n) as { card: string | null }[])
    .map((r) => (r.card === null ? null : JSON.parse(r.card)?.adb?.outcome ?? null))
    .filter((o) => o !== null), true);

const closedCard = (data: string, thread: number, n: number) =>
  withDb(data, (db) => (db.prepare("SELECT COUNT(*) AS c FROM closed_cards WHERE thread = ? AND n = ?").get(thread, n) as { c: number }).c, true);

const queued = (data: string) =>
  withDb(data, (db) => {
    const has = db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'card_outbox'").get();
    return has === undefined ? 0 : (db.prepare("SELECT COUNT(*) AS c FROM card_outbox").get() as { c: number }).c;
  }, true);

/// Outcomes as they came, a restatement of how a granted phone is reached (`link`) between them left out: it is said as
/// the phone's link changes, whenever that is.
const decided = (outcomes: any[]) => outcomes.filter((o, i) => !(o.status === "granted" && o.link !== undefined && i > 0));

const refusedPhone = /holds no phone grant|ask for the phone/i;

/// Chat `session` asks for Pat's phone: its request, and its card in the chat.
async function askPhone(env: PhoneStation, door: number, session: string, reason: string) {
  const asked = await tool(door, `t-${session}`, "device_use", { device: DEVICE, reason });
  assert.equal(asked.error, false, asked.text);
  const request = (await given(`${session}'s request waiting`, () => pendingOf(env.data, session))).id;
  const card = await given(`${session}'s card posted`, () => cardOf(env.data, env.threads[session]!, request));
  assert.equal(closedCard(env.data, env.threads[session]!, card.n), 0, "a waiting card is open");
  return { request, n: card.n, thread: env.threads[session]! };
}

test("a phone's request granted, taken back, denied and run out: each closes its card at once and says its outcome on it, in order and once; a chat holding no grant refused throughout", { skip: skipAdb, timeout: 120_000 }, async () => {
  const env = await phoneStation("phone");
  const { st, door, meshPort } = await env.start();
  const phone = await env.lend(meshPort, randomBytes(16).toString("hex"));
  await given("the phone listed", async () => (await tool(door, "t-s1", "device_list")).text.includes("Pixel-Fake"), () => st.err());

  // A chat that holds no grant is refused before anything is asked, and the phone needs Pat's decision.
  writeFileSync(join(fresh("x"), "a.apk"), "x");
  assert.match((await tool(door, "t-s3", "phone_send", { path: "nope.apk" })).text, refusedPhone);
  const one = await askPhone(env, door, "s1", "install the build");
  assert.match((await tool(door, "t-s1", "phone_send", { path: "nope.apk" })).text, refusedPhone, "a request waiting is no grant");

  // Granted: the card closed at once, its outcome said on it; the phone reached.
  const [st1, b1] = await phone.adb({ op: "decide", request: one.request, scope: "hour" });
  assert.equal(st1, 200, JSON.stringify(b1));
  assert.equal(b1.request.status, "granted");
  assert.equal(requestRow(env.data, one.request)?.status, "granted");
  assert.equal(closedCard(env.data, one.thread, one.n), 1, "the card closed with the decision");
  await given("the grant said on its card", () => outcomesOf(env.data, one.thread, one.n).length >= 1 && queued(env.data) === 0, () => st.err());
  const used = await tool(door, "t-s1", "device_use", { device: DEVICE, reason: "install the build" });
  assert.match(used.text, /adb -P \d+ -s 127\.0\.0\.1:\d+/, used.text);
  // Deciding it again, or by someone who is not its owner's device, changes nothing.
  const [again, againBody] = await phone.adb({ op: "decide", request: one.request, scope: "eight" });
  assert.equal(again, 422, JSON.stringify(againBody));
  assert.match(againBody.message, /granted already/);
  assert.match((await tool(door, "t-s3", "phone_send", { path: "nope.apk" })).text, refusedPhone, "another chat still holds nothing");

  // Taken back by its owner: ended, said after the grant on the same card.
  const [st2, b2] = await phone.adb({ op: "revoke", request: one.request });
  assert.equal(st2, 200, JSON.stringify(b2));
  assert.equal(requestRow(env.data, one.request)?.status, "ended");
  await given("the taking back said", () => outcomesOf(env.data, one.thread, one.n).some((o) => o.status === "ended") && queued(env.data) === 0, () => st.err());
  assert.match((await tool(door, "t-s1", "phone_send", { path: "nope.apk" })).text, refusedPhone, "taken back, refused");

  // Denied: closed at once, said as denied; no grant.
  const two = await askPhone(env, door, "s2", "look at the logs");
  const [st3, b3] = await phone.adb({ op: "decide", request: two.request });
  assert.equal(st3, 200, JSON.stringify(b3));
  assert.equal(b3.request.status, "denied");
  assert.equal(closedCard(env.data, two.thread, two.n), 1);
  await given("the denial said", () => outcomesOf(env.data, two.thread, two.n).length >= 1 && queued(env.data) === 0, () => st.err());
  assert.match((await tool(door, "t-s2", "phone_send", { path: "nope.apk" })).text, refusedPhone);

  // Granted, then run out (its expiry passed while it was held): ended as it is next read, said on its card.
  const three = await askPhone(env, door, "s2", "run the tests");
  const [st4] = await phone.adb({ op: "decide", request: three.request, scope: "hour" });
  assert.equal(st4, 200);
  await given("the second grant said", () => outcomesOf(env.data, three.thread, three.n).length >= 1 && queued(env.data) === 0, () => st.err());
  withDb(env.data, (db) => {
    const row = db.prepare("SELECT body FROM adb_requests WHERE id = ?").get(three.request) as { body: string };
    db.prepare("UPDATE adb_requests SET body = ? WHERE id = ?").run(JSON.stringify({ ...JSON.parse(row.body), exp: 1 }), three.request);
  });
  assert.match((await tool(door, "t-s2", "phone_send", { path: "nope.apk" })).text, refusedPhone, "run out, refused");
  assert.equal(requestRow(env.data, three.request)?.status, "ended");
  await given("its running out said", () => outcomesOf(env.data, three.thread, three.n).some((o) => o.status === "ended") && queued(env.data) === 0, () => st.err());
  const [, listed] = await phone.adb({ op: "grants" });
  assert.deepEqual(listed.grants.filter((g: any) => g.status === "granted"), [], `nothing granted left: ${JSON.stringify(listed.grants)}`);

  // Every card says its outcomes in the order they came, each once.
  assert.deepEqual(decided(outcomesOf(env.data, one.thread, one.n)), [{ status: "granted", scope: "hour" }, { status: "ended", scope: "hour", why: "已收回" }]);
  assert.deepEqual(outcomesOf(env.data, two.thread, two.n), [{ status: "denied" }]);
  assert.deepEqual(decided(outcomesOf(env.data, three.thread, three.n)), [{ status: "granted", scope: "hour" }, { status: "ended", scope: "hour", why: "授权已到期" }]);
  assert.doesNotMatch(st.err(), /SQLITE_BUSY|database is locked/i);
  await st.stop();
});

test("outcomes queued while their cards cannot be written go over a handover: the station before closes the phone's connection as it goes, the one after writes each once and in order, a cold start after writes nothing again", { skip: skipAdb, timeout: 150_000 }, async () => {
  const env = await phoneStation("outbox");
  const a = await env.start();
  const phone = await env.lend(a.meshPort, randomBytes(16).toString("hex"));
  await given("the phone listed", async () => (await tool(a.door, "t-s1", "device_list")).text.includes("Pixel-Fake"), () => a.st.err());
  const one = await askPhone(env, a.door, "s1", "install the build");
  const two = await askPhone(env, a.door, "s2", "read the logs");

  // The cards' edits held back (as a write that keeps failing): what is decided now is queued, not yet written.
  withDb(env.data, (db) => db.exec(`CREATE TRIGGER hold_phone_cards BEFORE INSERT ON entries
    WHEN NEW.kind = 'edit' AND NEW.thread IN (${one.thread}, ${two.thread}) BEGIN SELECT RAISE(ABORT, 'held by the test'); END`));
  const [d1] = await phone.adb({ op: "decide", request: one.request, scope: "hour" });
  assert.equal(d1, 200);
  assert.equal(closedCard(env.data, one.thread, one.n), 1, "closed at once, whatever its edit waits for");
  const [r1] = await phone.adb({ op: "revoke", request: one.request });
  assert.equal(r1, 200);
  const [d2] = await phone.adb({ op: "decide", request: two.request });
  assert.equal(d2, 200);
  assert.equal(closedCard(env.data, two.thread, two.n), 1);
  assert.deepEqual([requestRow(env.data, one.request)?.status, requestRow(env.data, two.request)?.status], ["ended", "denied"]);
  await given("the outcomes queued, none written", () => queued(env.data) >= 3, () => a.st.err());
  const held = queued(env.data);
  assert.deepEqual([outcomesOf(env.data, one.thread, one.n), outcomesOf(env.data, two.thread, two.n)], [[], []]);

  // The next station beside it, then the handover: the phone's connection to the one before closed as it goes.
  const b0 = await env.start(true);
  const since = Date.now();
  a.st.tell({ op: "handover" });
  // (followed from the handover's ask: the process before may take a while longer to exit than to close it)
  const closed = endOf(phone.conn, since, 30_000);
  const carry = await a.st.next("carry", (m) => m.carry !== undefined);
  const end = await closed;
  assert.equal(end.why?.kind, "application", `closed by the station, not timed out: ${JSON.stringify(end.why)}`);
  assert.ok(end.after < 5_000, `the phone's connection closed ${end.after} ms after the handover was asked`);
  assert.equal(await a.st.ended, 0, a.st.err());
  b0.st.tell({ op: "carried", carried: carry.carry });
  const b = { ...b0, door: (await b0.st.next("b serving", (m) => m.serving === "mcp")).port as number };
  assert.equal(queued(env.data), held, "still queued: nothing written while held");

  // Writable again: the station after writes each outcome once, in the order decided.
  withDb(env.data, (db) => db.exec("DROP TRIGGER hold_phone_cards"));
  await given("the queue written by the station after", () => queued(env.data) === 0, () => b.st.err(), 30_000);
  const written = outcomesOf(env.data, one.thread, one.n).length + outcomesOf(env.data, two.thread, two.n).length;
  assert.equal(written, held, "each queued outcome written once");
  assert.deepEqual(decided(outcomesOf(env.data, one.thread, one.n)), [{ status: "granted", scope: "hour" }, { status: "ended", scope: "hour", why: "已收回" }]);
  assert.deepEqual(outcomesOf(env.data, two.thread, two.n), [{ status: "denied" }]);
  // The phone lends itself to the station after; the chats it was taken from still hold nothing.
  const again = await env.lend(b.meshPort, randomBytes(16).toString("hex"));
  await given("the phone listed again", async () => (await tool(b.door, "t-s1", "device_list")).text.includes("Pixel-Fake"), () => b.st.err());
  assert.match((await tool(b.door, "t-s1", "phone_send", { path: "nope.apk" })).text, refusedPhone);
  assert.match((await tool(b.door, "t-s2", "phone_send", { path: "nope.apk" })).text, refusedPhone);
  void again;
  await b.st.stop();

  // A cold start: nothing queued, nothing written again.
  const c = await env.start();
  await given("the cold start's queue looked at", async () => (await tool(c.door, "t-s1", "device_list")).error === false, () => c.st.err());
  assert.equal(queued(env.data), 0);
  assert.equal(outcomesOf(env.data, one.thread, one.n).length + outcomesOf(env.data, two.thread, two.n).length, written, "nothing written again");
  await c.st.stop();
});

test("a phone decision whose outcome cannot be queued leaves the request waiting and its card open, and says so to its owner", { skip: skipAdb, timeout: 120_000 }, async () => {
  const env = await phoneStation("rollback");
  const { st, door, meshPort } = await env.start();
  const phone = await env.lend(meshPort, randomBytes(16).toString("hex"));
  await given("the phone listed", async () => (await tool(door, "t-s1", "device_list")).text.includes("Pixel-Fake"), () => st.err());
  // (one card decided first, so the queue's tables are there to hold a failure)
  const first = await askPhone(env, door, "s2", "warm up");
  assert.equal((await phone.adb({ op: "decide", request: first.request }))[0], 200);
  await given("the first outcome written", () => queued(env.data) === 0 && outcomesOf(env.data, first.thread, first.n).length === 1, () => st.err());

  const one = await askPhone(env, door, "s1", "install the build");
  withDb(env.data, (db) => db.exec("CREATE TRIGGER fail_phone_outcome BEFORE INSERT ON card_outbox BEGIN SELECT RAISE(ABORT, 'queue failed'); END"));
  let answer: [number, any] | Error;
  try {
    answer = await phone.adb({ op: "decide", request: one.request, scope: "hour" });
  } catch (e) {
    answer = e as Error;
  }
  const said = answer instanceof Error ? answer.message : JSON.stringify(answer);
  assert.ok(answer instanceof Error || answer[0] !== 200, `the decision is not answered as done: ${said}`);
  assert.equal(requestRow(env.data, one.request)?.status, "pending", `the request still waits (${said})`);
  assert.equal(closedCard(env.data, one.thread, one.n), 0, "its card still open");
  assert.equal(queued(env.data), 0, "nothing queued");
  assert.deepEqual(outcomesOf(env.data, one.thread, one.n), [], "nothing said on its card");
  assert.match((await tool(door, "t-s1", "phone_send", { path: "nope.apk" })).text, refusedPhone, "no grant was given");
  const use = await tool(door, "t-s1", "device_use", { device: DEVICE, reason: "install the build" });
  assert.doesNotMatch(use.text, /Granted\.|adb -P/, `the phone not handed over: ${use.text}`);
  assert.equal(requestRow(env.data, one.request)?.status, "pending", "asking again keeps the one request waiting");

  // The queue working again, the same decision goes through.
  withDb(env.data, (db) => db.exec("DROP TRIGGER fail_phone_outcome"));
  const [ok, body] = await phone.adb({ op: "decide", request: one.request, scope: "hour" });
  assert.equal(ok, 200, JSON.stringify(body));
  await given("its outcome written", () => queued(env.data) === 0 && outcomesOf(env.data, one.thread, one.n).length >= 1, () => st.err());
  assert.deepEqual(decided(outcomesOf(env.data, one.thread, one.n)), [{ status: "granted", scope: "hour" }]);
  assert.equal(requestRow(env.data, one.request)?.status, "granted");
  assert.equal(closedCard(env.data, one.thread, one.n), 1);
  await st.stop();
});

// ── 2. the device tools ──

test("the device tools over comma/tools/1: a peer not a gateway closed, another workspace refused; off (or unset) refuses all, read only the reads, full all, read at each request; output cut at 1 MiB, a command that runs on ended at its timeout", { skip: skipMesh, timeout: 120_000 }, async () => {
  const WS = "w-tools";
  const data = fresh("tools");
  const app = fresh("app");
  const home = fresh("thome");
  writeFileSync(join(app, "BUILD"), "10400\n");
  writeFileSync(join(home, "notes.txt"), "read me");
  const id = stationId(data);
  const meshPort = await freeUdpPort();
  const bind = async () => {
    const ep = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
    cleanups.push(() => ep.close());
    return ep;
  };
  const gateway = await bind();
  const stranger = await bind();
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9", provider: "comma", station: id, workspace: WS, workspace_name: "Tools", name: "here",
    relay_url: "", relay_urls: [], grant_keys: null, gateway_keys: [gateway.id()], peers: [], revocations: [],
  }));
  const setAccess = (access?: string) => writeFileSync(join(data, "config.json"), `${JSON.stringify({ language: "en", ...(access === undefined ? {} : { tools: { access } }) })}\n`);
  setAccess();
  const st = await launch(data, app, { HOME: home, STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}` });
  await st.next("ready", (m) => m.ready === true);
  await st.next("mcp", (m) => m.serving === "mcp");

  const dial = (ep: Awaited<ReturnType<typeof bind>>) => given("dialled the station's tools", () => ep.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("comma/tools/1")), () => st.err());
  const conn = await dial(gateway);
  /// One request (`{op, id, context, args}`) on a stream of its own: the one line answered.
  const call = async (op: string, args: Record<string, unknown> = {}, context: Record<string, unknown> = { workspace: WS, agent: "gw-agent" }) => {
    const stream = await conn.openBi();
    await line(stream, { op, id: `rq-${op}`, context, args });
    await stream.finish();
    // (an answer carries what a command said, up to 1 MiB of each stream: longer than a head's line)
    return new Reader(stream, 12 * 1024 * 1024).line();
  };

  // A peer the control plane does not name as a gateway: closed as not one, nothing run.
  const marker = join(home, "stranger-ran");
  const other = await dial(stranger);
  const since = Date.now();
  try {
    const s = await other.openBi();
    await line(s, { op: "exec", id: "x", context: { workspace: WS }, args: { command: `echo ran > "${marker}"` } });
    await s.finish();
    const said = await new Reader(s).line().catch(() => null);
    assert.equal(said?.ok === true, false, `nothing answered to a stranger: ${JSON.stringify(said)}`);
  } catch {}
  const end = await endOf(other, since);
  // (closed by the refusal, `not_a_gateway`, or by the serving's end that follows it at once: which of the two reaches
  // the peer first is iroh's, the TypeScript's as well)
  assert.equal(end.why?.kind, "application", JSON.stringify(end.why));
  assert.ok(end.after < 10_000, `closed ${end.after} ms after it asked`);
  assert.equal(existsSync(marker), false, "nothing ran for the stranger");

  // Unset: off. Every op refused, in words that say so.
  for (const [op, args] of [["fs.read", { path: "notes.txt" }], ["exec", { command: "echo no" }], ["fs.list", { path: "." }]] as const) {
    const r = await call(op, args);
    assert.deepEqual([r.ok, r.error?.code], [false, "forbidden"], `${op} unset: ${JSON.stringify(r)}`);
    assert.match(r.error.message, /turned off/);
  }
  setAccess("off");
  assert.equal((await call("fs.stat", { path: "notes.txt" })).error?.code, "forbidden");

  // read: the reads alone, read again from config.json as it changes.
  setAccess("read");
  const read = await given("read access taken up", async () => {
    const r = await call("fs.read", { path: "notes.txt" });
    return r.ok === true ? r : null;
  }, () => st.err());
  assert.equal(Buffer.from(read.result.content_base64, "base64").toString(), "read me");
  assert.equal((await call("fs.list", { path: "." })).ok, true);
  for (const [op, args] of [["exec", { command: `echo no > "${join(home, "w")}"` }], ["fs.write", { path: "w.txt", content_base64: "" }], ["process.start", { command: "sleep 5" }], ["session.start", { prompt: "x", requester_email: "a@x" }]] as const) {
    const r = await call(op, args);
    assert.deepEqual([r.ok, r.error?.code], [false, "forbidden"], `${op} under read: ${JSON.stringify(r)}`);
    assert.match(r.error.message, /needs full access; this station allows read/);
  }
  assert.equal(existsSync(join(home, "w")) || existsSync(join(home, "w.txt")), false, "nothing written under read");
  // Another workspace's request, or one naming none, refused whatever the access; an op there is not, refused as such.
  assert.deepEqual([(await call("fs.read", { path: "notes.txt" }, { workspace: "w-other" })).error?.code], ["forbidden"]);
  assert.equal((await call("fs.read", { path: "notes.txt" }, {})).error?.code, "forbidden");
  assert.equal((await call("rm.rf", {})).error?.code, "unknown_op");

  // full: everything; a command's exit code and output.
  setAccess("full");
  const echo = await given("full access taken up", async () => {
    const r = await call("exec", { command: "echo out; echo err >&2; exit 3" });
    return r.ok === true ? r : null;
  }, () => st.err());
  assert.deepEqual([echo.result.exit_code, echo.result.stdout, echo.result.stderr, echo.result.truncated], [3, "out\n", "err\n", false]);

  // Output past 1 MiB: cut there, said to be cut, both streams; the command still ends with its own code.
  const big = await call("exec", { command: "head -c 3000000 /dev/zero | tr '\\000' a; head -c 2500000 /dev/zero | tr '\\000' b >&2; exit 0" });
  assert.equal(big.ok, true, JSON.stringify(big).slice(0, 300));
  assert.deepEqual([big.result.stdout.length, big.result.stderr.length, big.result.truncated, big.result.exit_code], [1024 * 1024, 1024 * 1024, true, 0]);
  assert.match(big.result.stdout, /^a+$/);

  // One that never ends: ended at its timeout, said as timed out, its process (and what it started) gone.
  const pidFile = join(home, "slow.pid");
  const t0 = Date.now();
  const slow = await call("exec", { command: `echo $$ > "${pidFile}"; exec sleep 60`, timeout_ms: 500 });
  const took = Date.now() - t0;
  assert.equal(slow.ok, true, JSON.stringify(slow));
  assert.deepEqual([slow.result.timed_out, slow.result.exit_code], [true, null]);
  assert.ok(took < 10_000, `answered ${took} ms after it was asked`);
  const pid = Number(readFileSync(pidFile, "utf8").trim());
  await given("the timed-out command gone", () => {
    try {
      process.kill(pid, 0);
      return false;
    } catch {
      return true;
    }
  });
  // Flooding output and never ending: cut at 1 MiB and ended at its timeout, the station serving on.
  const flood = await call("exec", { command: "exec yes flood", timeout_ms: 1500 });
  assert.equal(flood.ok, true);
  assert.deepEqual([flood.result.timed_out, flood.result.truncated, flood.result.stdout.length], [true, true, 1024 * 1024]);
  assert.equal((await call("fs.stat", { path: "notes.txt" })).ok, true, "the station serves on after it");

  // Back to off: refused again at the next request.
  setAccess("off");
  await given("off taken up again", async () => (await call("fs.read", { path: "notes.txt" })).error?.code === "forbidden", () => st.err());
  await st.stop();
});

// ── 3. a group connect ──

/// A fake Claude Code (/bin/sh and curl alone): each prompt posts `group-reply-<n>`; one saying CARD_NOW asks a card.
function fakeClaude(bin: string, prefix = "reply") {
  const claude = String.raw`#!/bin/sh
case " $* " in *" -p "*) ;; *) printf 'claude 2.0.0\n'; exit 0 ;; esac
sid=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift ;;
    --mcp-config) cfg="$2"; shift ;;
  esac
  shift
done
url=$(printf '%s' "$cfg" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
say() { printf '%s\n' "$1"; }
call() { curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" -d "$1"; }
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  n=$(( $(cat "$FAKE_OUT/n-$sid" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$FAKE_OUT/n-$sid"
  printf '%s\n' "$line" >> "$FAKE_OUT/in-$sid.log"
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  to=$(printf '%s' "$line" | sed -n 's/.*thread=\\"\([^\\]*\)\\".*/\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-$sid"; else to=$(cat "$FAKE_OUT/to-$sid" 2>/dev/null); fi
  tag=$(printf '%s' "$line" | sed -n 's/.*\(msg-[0-9a-z]*\).*/\1/p')
  case "$line" in
    *CARD_NOW*)
      call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"Group Room","text":"合并吗？","card":{"type":"options","options":[{"label":"合并"},{"label":"先不"}]},"kind":"need_human","need":"选一个"}}}' > "$FAKE_OUT/post-$sid-$n.json" ;;
    *)
      call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"Group Room","text":"'"$PREFIX"'-'"$n"' for '"$tag"'","kind":"all_done","done":"replied"}}}' > "$FAKE_OUT/post-$sid-$n.json" ;;
  esac
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"ok"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"ok"}'
done
`;
  writeFileSync(join(bin, "claude"), claude.replace('"$PREFIX"', prefix));
  chmodSync(join(bin, "claude"), 0o755);
}

/// A control plane of the test's: its HTTP answered `{}`, its presence socket given each station its state.
async function plane(stateOf: (station: string) => object) {
  const sockets: WebSocket[] = [];
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => res.writeHead(200, { "content-type": "application/json" }).end("{}"));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...stateOf(String(req.headers["x-stillfail-station"] ?? "")) }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

const cloudJson = (data: string, o: { origin: string; id: string; ws: string; name: string; peers: unknown[] }) => {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: o.origin, station: o.id, workspace: o.ws, workspace_name: "团队", name: o.name, relay_url: "", relay_urls: [], grant_keys: null, peers: o.peers, revocations: [],
  }));
};

/// The messages of a thread with this text, as the station keeps them.
const said = (data: string, text: string) =>
  withDb(data, (db) => (db.prepare("SELECT author_kind FROM entries WHERE kind = 'message' AND text = ?").all(text) as { author_kind: string }[]), true);

test("a group connect: a direct space's messages said while its link is cut and while the station is stopped each taken once, its key alone after the code; a card asked before a stop answered after it as the person's message", { skip: skipAgents, timeout: 150_000 }, async () => {
  const data = fresh("grp");
  const app = fresh("app");
  const bin = toolsPath();
  const out = fresh("out");
  writeFileSync(join(app, "BUILD"), "10400\n");
  fakeClaude(bin, "group-reply");
  const im = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("im/2")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const server = new ImServer(im);
  cleanups.push(() => server.close());
  const ada = server.member("Ada", true);
  const ips = im.sockets().filter((s) => s.startsWith("127.0.0.1:"));
  assert.ok(ips.length > 0, JSON.stringify(im.sockets()));
  const id = stationId(data);
  const origin = await plane(() => ({ workspace: "w-grp", workspace_name: "团队", name: "grp", peers: [{ id, name: "grp" }] }));
  cloudJson(data, { origin, id, ws: "w-grp", name: "grp", peers: [{ id, name: "grp" }] });
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  writeFileSync(join(data, "config.json"), JSON.stringify({
    language: "en", defaultWorkspace: fresh("work"),
    profiles: [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc" }],
    connects: [{ id: "g1", kind: "group", enabled: true, bind: { runtime: "claude", profile: "cc" },
      group: { server: im.id(), relays: ["https://relay.test"], key: randomBytes(32).toString("hex"), code: server.code(), botName: "Claude" } }],
  }));
  const start = async () => {
    const st = await launch(data, app, { PATH: bin, FAKE_OUT: out, STILLFAIL_GROUP_IPS: ips.join(",") });
    await st.next("ready", (m) => m.ready === true);
    const door = (await st.next("mcp", (m) => m.serving === "mcp")).port as number;
    return { st, door };
  };
  let s = await start();
  const connected = () => given("the group connect connected", async () => (await http(s.door, "/admin-api/overview")).json?.connects?.find((c: any) => c.id === "g1")?.connection?.state === "connected", () => s.st.err());
  const idle = () => given("no turn running", async () => (await http(s.door, "/admin-api/overview")).json?.counts?.running === 0, () => s.st.err());
  await connected();
  const me = await given("joined by the code, the code taken out", () => {
    const g = readJson(join(data, "config.json"))?.connects?.[0]?.group;
    return g?.code === undefined && typeof g?.memberId === "string" ? g.memberId as string : null;
  });
  const dm = server.direct(ada, me);
  const replies = () => server.messages(dm).filter((m) => m.author === me).map((m) => m.text);
  const answered = (tag: string) => given(`${tag} answered in the space`, () => replies().some((t) => t.includes(`for ${tag}`)), () => `${JSON.stringify(server.messages(dm))}; ${s.st.err()}`, 30_000);

  server.say(dm, ada, "一 msg-one");
  await answered("msg-one");
  await idle();

  // The link cut: what is said meanwhile is taken once it is back, from where it was; a backoff, no storm of hellos.
  const hellos = server.hellos.length;
  server.cut();
  server.say(dm, ada, "二 msg-two");
  await answered("msg-two");
  await connected();
  assert.ok(server.hellos.length - hellos <= 3, `dialled again a few times, not a storm: ${server.hellos.length - hellos}`);
  await idle();

  // Stopped, a message said meanwhile, started again: taken once, by the key alone.
  await s.st.stop();
  server.say(dm, ada, "三 msg-three");
  s = await start();
  await connected();
  await answered("msg-three");
  assert.equal(server.hellos.at(-1)!.credential, "", "its key alone, the code long used");
  await idle();
  for (const t of ["一 msg-one", "二 msg-two", "三 msg-three"]) assert.deepEqual(said(data, t).map((x) => x.author_kind), ["person"], `${t} taken once`);
  for (const tag of ["msg-one", "msg-two", "msg-three"]) assert.equal(replies().filter((t) => t.includes(`for ${tag}`)).length, 1, `${tag} answered once`);

  // A card asked, the station stopped and started again, then answered: the person's message, to the session.
  server.say(dm, ada, "CARD_NOW");
  const ask = await given("the card asked as a decision", () => [...server.spaces.get(dm)!.msgs.values()].filter((m: any) => m.kind === "decision.ask").at(-1), () => `${JSON.stringify(server.messages(dm))}; ${s.st.err()}`, 30_000);
  await idle();
  await s.st.stop();
  s = await start();
  await connected();
  const picked = server.resolve(dm, ada, ask.id, "合并");
  assert.equal(typeof picked.aseq, "number", JSON.stringify(picked));
  await given("the answer taken as the person's message", () => said(data, "合并").some((x) => x.author_kind === "person"), () => s.st.err(), 30_000);
  await given("the agent called with it", () => readdirSync(out).filter((f) => f.startsWith("in-")).some((f) => readFileSync(join(out, f), "utf8").includes("合并")), () => s.st.err(), 30_000);
  assert.equal(said(data, "合并").filter((x) => x.author_kind === "person").length, 1, "the answer once");
  await idle();
  await s.st.stop();
});

// ── 4. a connect of the workspace's, its chats on another station ──

/// Slack, of the test's: one app (`xoxb-1`/`xapp-1`), its socket open, every Web API call written down.
async function slackStandIn() {
  const asked: { m: string; form: Record<string, string> }[] = [];
  const sockets: WebSocket[] = [];
  const acks: string[] = [];
  const server = httpServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const text = Buffer.concat(chunks).toString();
    const form = (req.headers["content-type"] ?? "").includes("json") ? JSON.parse(text || "{}") : Object.fromEntries(new URLSearchParams(text));
    const m = (req.url ?? "").split("?")[0]!.replace(/^\/api\//, "");
    asked.push({ m, form });
    const ok = (body: object) => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true, ...body }));
    switch (m) {
      case "auth.test":
        return ok({ team: "Acme", team_id: "T1", url: "https://acme.slack.com/", user_id: "UB", user: "bot", bot_id: "BB" });
      case "users.info":
        return ok({ user: { id: form.user, name: "ada", real_name: "Ada", profile: { display_name: "Ada", email: "ada@x.com", image_72: "https://a" } } });
      case "apps.connections.open":
        return ok({ url: `ws://127.0.0.1:${(server.address() as AddressInfo).port}/socket` });
      case "conversations.info":
        return ok({ channel: { id: form.channel, name: `name-${form.channel}` } });
      case "chat.postMessage":
        return ok({ ts: `1790000100.${String(asked.length).padStart(6, "0")}`, channel: form.channel });
      default:
        return ok({});
    }
  });
  const wss = new WebSocketServer({ server, path: "/socket" });
  wss.on("connection", (ws) => {
    sockets.push(ws);
    ws.on("message", (m) => {
      const msg = JSON.parse(String(m));
      if (typeof msg.envelope_id === "string") acks.push(msg.envelope_id);
    });
    ws.send(JSON.stringify({ type: "hello" }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => {
    for (const c of wss.clients) c.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  let n = 0;
  const open = () => sockets.filter((w) => w.readyState === w.OPEN).at(-1);
  /// An event of Slack's on the open socket, until it is acknowledged (`acked`: Slack's acknowledgment comes once the
  /// event is handled, which a station that is down holds up for as long as it is dialled).
  const event = async (ev: Record<string, unknown>, acked = true) => {
    const envelope = `e${++n}`;
    const ws = await given("Slack's socket open", () => open());
    ws.send(JSON.stringify({ type: "events_api", envelope_id: envelope, payload: { team_id: "T1", event: { channel: "C1", user: "U1", channel_type: "channel", ...ev } } }));
    if (acked) await given(`envelope ${envelope} acknowledged`, () => acks.includes(envelope));
  };
  const posted = () => asked.filter((x) => x.m === "chat.postMessage" || x.m === "chat.update").map((x) => ({ thread: x.form.thread_ts, text: String(x.form.text ?? "") }));
  return { base: `http://127.0.0.1:${(server.address() as AddressInfo).port}/api`, asked, open, event, posted };
}

test("a Slack connect naming another station: a new thread's chat runs there over iroh, what follows in it goes there, what its agent says goes out through the connect; a thread begun before stays here; that station down, its thread is told and a new one runs here", { skip: skipAgents, timeout: 180_000 }, async () => {
  const slack = await slackStandIn();
  const profiles = [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc" }];
  const mk = () => {
    const data = fresh("wsc");
    const app = fresh("app");
    writeFileSync(join(app, "BUILD"), "10400\n");
    mkdirSync(join(data, "homes", "cc"), { recursive: true });
    writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
    return { data, app, id: stationId(data) };
  };
  const [h, s] = [mk(), mk()];
  const [portH, portS] = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: h.id, name: "laptop", ips: [`127.0.0.1:${portH}`] }, { id: s.id, name: "desktop", ips: [`127.0.0.1:${portS}`] }];
  const origin = await plane((st) => ({ workspace: "w1", workspace_name: "团队", name: st === h.id ? "laptop" : "desktop", peers }));
  cloudJson(h.data, { origin, id: h.id, ws: "w1", name: "laptop", peers });
  cloudJson(s.data, { origin, id: s.id, ws: "w1", name: "desktop", peers });
  const connect = (station?: string) => ({
    id: "cl", kind: "slack", mode: "multi-session", enabled: true, bind: { runtime: "claude", profile: "cc" }, createdBy: { id: "ada@x.com" },
    slack: { appToken: "xapp-1", botToken: "xoxb-1", appId: "A-cl" }, ...(station === undefined ? {} : { station }),
  });
  const config = (connects: object[]) => JSON.stringify({ language: "en", defaultWorkspace: fresh("work"), profiles, maxNudges: 0, connects });
  writeFileSync(join(h.data, "config.json"), config([connect()]));
  writeFileSync(join(s.data, "config.json"), config([]));
  const out = fresh("out");
  const binFor = (prefix: string) => {
    const bin = toolsPath();
    fakeClaude(bin, prefix);
    return bin;
  };
  const [binH, binS] = [binFor("laptop-reply"), binFor("desktop-reply")];
  const startH = async () => {
    const st = await launch(h.data, h.app, { PATH: binH, FAKE_OUT: out, STILLFAIL_SLACK_API: slack.base, STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portH}` });
    await st.next("ready", (m) => m.ready === true);
    return { st, door: (await st.next("mcp", (m) => m.serving === "mcp")).port as number };
  };
  const startS = async () => {
    const st = await launch(s.data, s.app, { PATH: binS, FAKE_OUT: out, STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portS}` });
    await st.next("ready", (m) => m.ready === true);
    return { st, door: (await st.next("mcp", (m) => m.serving === "mcp")).port as number };
  };
  let H = await startH();
  let S = await startS();
  const both = () => `laptop: ${H.st.err()}\ndesktop: ${S.st.err()}\nslack: ${JSON.stringify(slack.posted())}`;
  for (const d of [h.data, s.data]) await given("online at the plane", () => readJson(join(d, "run", "presence.json"))?.online === true, both);
  const connected = () => given("cl connected", async () => (await http(H.door, "/admin-api/overview")).json?.connects?.find((c: any) => c.id === "cl")?.connection?.state === "connected", both);
  await connected();
  const sessionsOf = (data: string) => withDb(data, (db) => (db.prepare("SELECT key, connect FROM sessions WHERE connect LIKE 'cl%'").all() as { key: string; connect: string }[]), true);
  const threadStation = (thread: string) => withDb(h.data, (db) => {
    const has = db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'connect_threads'").get();
    return has === undefined ? undefined : (db.prepare("SELECT station FROM connect_threads WHERE connect = 'cl' AND thread_ts = ?").get(thread) as { station: string } | undefined)?.station;
  }, true);
  const answer = (thread: string, prefix: string, tag: string) =>
    given(`${tag} answered by ${prefix} in ${thread}`, () => slack.posted().some((p) => p.thread === thread && p.text.includes(`${prefix}-`) && p.text.includes(`for ${tag}`)), both, 45_000);
  const idle = (port: number) => given("no turn running", async () => (await http(port, "/admin-api/overview")).json?.counts?.running === 0, both);

  // A thread begun while the connect names no station: here.
  const before = "1790000200.000100";
  await slack.event({ type: "app_mention", text: "<@UB> hi msg-a1", ts: before });
  await answer(before, "laptop-reply", "msg-a1");
  await idle(H.door);
  assert.deepEqual(sessionsOf(h.data).map((x) => x.connect), ["cl"]);

  // The connect now names the other station (config.json as a person edits it, taken up at the next start).
  await H.st.stop();
  writeFileSync(join(h.data, "config.json"), config([connect(s.id)]));
  H = await startH();
  await connected();

  // A new thread: its chat on the other station, under the id the workspace knows the connect by; nothing of it here.
  const fresh1 = "1790000300.000100";
  await slack.event({ type: "app_mention", text: "<@UB> look at the build msg-b1", ts: fresh1 });
  await answer(fresh1, "desktop-reply", "msg-b1");
  assert.equal(threadStation(fresh1), s.id, "the thread's chat is the other station's");
  assert.deepEqual(sessionsOf(s.data).map((x) => x.connect), [`cl@${h.id}`]);
  assert.deepEqual(sessionsOf(h.data).map((x) => x.connect), ["cl"], "no session of it here");
  await idle(S.door);
  // What follows in it, not mentioning the bot, goes there too.
  await slack.event({ type: "message", text: "and the tests msg-b2", ts: "1790000300.000200", thread_ts: fresh1 });
  await answer(fresh1, "desktop-reply", "msg-b2");
  await idle(S.door);
  assert.deepEqual(said(s.data, "and the tests msg-b2").map((x) => x.author_kind), ["person"]);
  assert.deepEqual(said(h.data, "and the tests msg-b2"), [], "kept there, not here");
  // The thread begun before stays here.
  await slack.event({ type: "app_mention", text: "<@UB> more msg-a2", ts: "1790000200.000200", thread_ts: before });
  await answer(before, "laptop-reply", "msg-a2");
  await idle(H.door);
  assert.deepEqual(said(s.data, "<@UB> more msg-a2"), []);
  assert.equal(sessionsOf(s.data).length, 1);

  // The other station down: a message for its chat is not lost silently, the thread is told where it is.
  await S.st.stop();
  const notices = () => slack.posted().filter((p) => p.thread === fresh1 && p.text.includes("⚠️") && /desktop/.test(p.text));
  const away = Date.now();
  await slack.event({ type: "message", text: "still there? msg-b3", ts: "1790000300.000300", thread_ts: fresh1 }, false);
  await given("the thread told its station is away", () => notices().length >= 1, both, 90_000);
  assert.ok(!slack.posted().some((p) => p.text.includes("for msg-b3")), "nobody answered it as if it were taken");
  // A new thread meanwhile runs on the connect's own station.
  const fresh2 = "1790000400.000100";
  const fallback = Date.now();
  await slack.event({ type: "app_mention", text: "<@UB> new msg-c1", ts: fresh2 }, false);
  await given("msg-c1 answered here", () => slack.posted().some((p) => p.thread === fresh2 && p.text.includes("laptop-reply-") && p.text.includes("for msg-c1")), both, 90_000);
  assert.equal(threadStation(fresh2), undefined, "not recorded as the other's");
  assert.equal(sessionsOf(h.data).length, 2);
  await idle(H.door);

  // Back up: its chat answers there again.
  S = await startS();
  await given("desktop online again", () => readJson(join(s.data, "run", "presence.json"))?.online === true, both);
  await slack.event({ type: "message", text: "back msg-b4", ts: "1790000300.000400", thread_ts: fresh1 });
  await answer(fresh1, "desktop-reply", "msg-b4");
  await idle(S.door);
  await S.st.stop();
  await H.st.stop();
});
