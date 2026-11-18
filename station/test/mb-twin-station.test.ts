// The MoonBit station held to the TypeScript one side by side, as a release runs each: the real launcher
// (native/launcher, `stillfail-station run`) runs a release laid out as station-bundle.sh lays one, with `station/main.js`
// (Node running src/main.ts) for one and without it (`stillfail-reader run`) for the other, on data directories seeded
// alike (one key, one config.json, one control plane of the test's, one fake Claude Code). A member let in on the mesh
// (real iroh) by the credential the workspace's key signed asks both the same, and what each answers (status and JSON,
// dynamic fields made alike: ports, pids, times, ids) must be the same; so must what an agent's turn finds on `/mcp`
// (`tools/list`, `station_tool`), what each wrote of the chat in stillfail.db, and a handover chain Node → MoonBit →
// MoonBit → Node by the launcher (SIGUSR2, the release's main.js taken away and put back between), the session's turns,
// its job and its rows carried by every hop.
//
// Every check must pass but those `MB_OVERVIEW_EXTRAS` names (fields the MoonBit overview adds on purpose), which must
// fail; one of them that passes fails this file until it is taken out. TWIN_DUMP=<dir> writes every answer of both, the checks and the launchers' logs there, for whoever
// looks at a difference.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer as netServer } from "node:net";
import { createServer as httpServer } from "node:http";
import { createSocket } from "node:dgram";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { AsyncLocalStorage } from "node:async_hooks";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { DatabaseSync } from "node:sqlite";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { GrantKey } from "./fake-control-plane.ts";

// ── what the MoonBit station is let differ in: each a check below, by its name ──
//
// Every check not named here must pass; one named here must fail, and once it passes the file fails until its name is
// taken out. The MoonBit overview gives two fields the TypeScript's has not, on purpose: `machine` and `rigs`
// (test/mb-live-station.test.ts asserts both in the overview, test/mb-live-p5-1.test.ts its `rigs`; a client passes
// over a field it does not know).
const MB_OVERVIEW_EXTRAS = new Set<string>([
  "GET /overview .machine",
  "GET /overview .rigs",
]);

const binary = mbReaderBinary();
const launcher = process.env.STILLFAIL_LAUNCHER ?? "";
const runner = process.env.STILLFAIL_RUNNER ?? "";
const meshNative = process.env.STILLFAIL_MESH_NATIVE ?? "";
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32" ? "the launcher's signals are Unix's"
  : launcher === "" || !existsSync(launcher) ? "no stillfail-station launcher (run under scripts/native.ts run launcher)"
  : runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)"
  : addon === null || meshNative === "" ? "the mesh addon is not built here (scripts/native.ts run mesh)"
  : !existsSync("/usr/bin/curl") ? "no /usr/bin/curl for the fake runtime"
  : false;

const mainTs = fileURLToPath(new URL("../src/main.ts", import.meta.url));

// ── what a run leaves: its directories and processes, ended as the file ends ──
const dirs: string[] = [];
const fresh = (what: string) => {
  // (short: a runner's and the status's Unix sockets are at most 104 bytes on macOS)
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sft-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};
/// Every process a data directory names (the launcher's station, its front, each runner's group, each job's group,
/// which a station's stop leaves for the next to take up): killed by its pid.
function endAll(data: string) {
  if (existsSync(join(data, "stillfail.db"))) {
    try {
      const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
      for (const { pgid } of db.prepare("SELECT pgid FROM jobs WHERE pgid IS NOT NULL").all() as { pgid: number }[]) {
        try { process.kill(-pgid, "SIGKILL"); } catch {}
      }
      db.close();
    } catch {}
  }
  for (const f of ["run/station.json", "run/front.pid", "run/hub.json"]) {
    try {
      const text = readFileSync(join(data, f), "utf8");
      const pid = Number(f.endsWith(".pid") ? text.trim() : JSON.parse(text).pid);
      if (pid > 0 && pid !== process.pid) process.kill(pid, "SIGKILL");
    } catch {}
  }
  const runners = join(data, "run", "runners");
  if (existsSync(runners)) {
    for (const f of readdirSync(runners).filter((n) => n.endsWith(".json"))) {
      try {
        const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
        try { process.kill(-info.pgid, "SIGKILL"); } catch {}
        try { process.kill(info.runner, "SIGKILL"); } catch {}
      } catch {}
    }
  }
}
after(async () => {
  for (const c of closers.splice(0).reverse()) {
    try { c(); } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  for (const d of dirs) endAll(d);
  if (process.env.STATION_KEEP !== "1") for (const d of dirs) {
    // (a builder the station started may still be leaving its files as its SIGTERM ends it: ENOTEMPTY)
    rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

/// Looked at until `look` gives something (real processes: every 50 ms), or failing with `what` after `ms`.
async function until<T>(what: string, look: () => T | null | undefined | false | Promise<T | null | undefined | false>, detail: () => string = () => "", ms = 30_000): Promise<T> {
  const end = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await look();
      if (v) {
        return v as T;
      }
    } catch (e) {
      last = e;
    }
    if (Date.now() > end || /giving up/.test(detail())) throw new Error(`never: ${what}${last ? ` (${(last as Error).message})` : ""}; ${detail()}`);
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

async function freeTcpPort(): Promise<number> {
  const s = netServer();
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", () => r()));
  const port = (s.address() as AddressInfo).port;
  await new Promise<void>((r) => s.close(() => r()));
  return port;
}

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

/// The control plane of the test's, one for both: its HTTP (the model catalog at `/v1/models` under an ETag the test
/// changes, every other request answered `{}`) and its presence socket, which tells each station its state and carries
/// what the test pushes to one station's socket (`push`, by the station's id its upgrade was signed with).
async function controlPlane() {
  const sockets: WebSocket[] = [];
  const of = new Map<string, WebSocket>();
  const asked: string[] = [];
  const catalog = { etag: '"m-1"', models: { "m-1": { name: "One" } } as Record<string, unknown> };
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => {
      asked.push(req.url ?? "");
      if ((req.url ?? "").startsWith("/v1/models")) {
        return void res.writeHead(200, { "content-type": "application/json", etag: catalog.etag }).end(JSON.stringify({ models: catalog.models }));
      }
      res.writeHead(200, { "content-type": "application/json" }).end("{}");
    });
  });
  const wss = new WebSocketServer({ noServer: true });
  const peers: unknown[] = [];
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      of.set(String(req.headers["x-stillfail-station"] ?? ""), ws);
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(JSON.stringify({ type: "state", workspace: "w1", workspace_name: "团队", name: "mac", peers, relay_urls: [] }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  };
  closers.push(close);
  const connected = (station: string) => of.get(station)?.readyState === 1;
  const push = (station: string, frame: unknown) => of.get(station)!.send(JSON.stringify(frame));
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, peers, close, asked, catalog, connected, push };
}

/// A fake Claude Code (stream-json in and out, /bin/sh and curl alone). Each prompt's text says what it does: a line
/// `do: <name>` runs `$FAKE_SCRIPTS/<name>.sh` with the door's URL, its token, the thread it was asked in and its
/// session's id (the script's calls written to `$FAKE_OUT`), and the turn ends with what it printed last.
function fakeClaude(dir: string) {
  const claude = `#!/bin/sh
sid=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift ;;
    --mcp-config) cfg="$2"; shift ;;
  esac
  shift
done
url=$(printf '%s' "$cfg" | /usr/bin/sed -n 's/.*"url":"\\([^"]*\\)".*/\\1/p')
say() { printf '%s\\n' "$1"; }
n=0
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  n=$((n+1))
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/$sid-to"; else to=$(/bin/cat "$FAKE_OUT/$sid-to" 2>/dev/null); fi
  what=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*do: \\([a-z0-9_-]*\\).*/\\1/p')
  [ -n "$what" ] || what=nudge
  printf '%s\n' "$line" > "$FAKE_OUT/$sid-$n-prompt.json"
  if [ -f "$FAKE_SCRIPTS/$what.sh" ]; then
    URL="$url" TO="$to" SID="$sid" N="$n" /bin/sh "$FAKE_SCRIPTS/$what.sh" > "$FAKE_OUT/$sid-$n-$what.out" 2>&1
    printf '%s\\n' "$what" >> "$FAKE_OUT/$sid-done"
  else
    printf 'none\\n' >> "$FAKE_OUT/$sid-done"
  fi
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"done"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"done"}'
done
`;
  writeFileSync(join(dir, "claude"), claude);
  chmodSync(join(dir, "claude"), 0o755);
  // (the shell's tools a script, a job's wrapper and stillfail-job use, linked: a copy of a system binary is killed as
  // it starts outside its directory on macOS)
  for (const tool of ["sh", "cat", "echo", "env", "sed", "printf", "mv", "rm", "mkdir", "date", "tr", "head", "grep", "sleep", "curl"]) {
    const found = ["/bin", "/usr/bin"].map((d) => join(d, tool)).find((p) => existsSync(p));
    if (found !== undefined && !existsSync(join(dir, tool))) symlinkSync(found, join(dir, tool));
  }
}

/// A script the fake runs for a prompt that names it: one MCP call a line (`call <id> <json body>`), each answer kept
/// in `$FAKE_OUT/$SID-$N-<id>.json`.
const script = (calls: [string, string][]) =>
  `JOB=$(/usr/bin/grep -h -o 'job_[0-9a-f]\\{8\\}' "$FAKE_OUT"/*.json 2>/dev/null | /usr/bin/head -1)\n` +
  `last() { /usr/bin/grep -o 'job_[0-9a-f]\\{8\\}' "$FAKE_OUT/$SID-$N-start.json" 2>/dev/null | /usr/bin/head -1; }\n` +
  `call() { /usr/bin/curl -s -X POST "$URL" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" -d "$2" > "$FAKE_OUT/$SID-$N-$1.json"; }\n` +
  calls.map(([id, body]) => `call ${id} '${body.replaceAll("'", "'\\''").replaceAll("$TO", `'"$TO"'`).replaceAll("$JOB", `'"$JOB"'`).replaceAll("$LAST", `'"$(last)"'`)}'`).join("\n") + "\n";

const line = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

type Answer = { status: number; json: any; text: string };

/// One station of the pair, as the launcher runs it.
class Station {
  child!: ChildProcess;
  conn!: Connection;
  said = "";
  ended!: Promise<number | null>;
  readonly kind: "node" | "mb";
  readonly app: string;
  readonly data: string;
  readonly out: string;
  readonly mcpPort: number;
  readonly meshPort: number;
  readonly id: string;
  readonly bin: string;
  constructor(o: { kind: "node" | "mb"; app: string; data: string; out: string; mcpPort: number; meshPort: number; id: string; bin: string }) {
    this.kind = o.kind;
    this.app = o.app;
    this.data = o.data;
    this.out = o.out;
    this.mcpPort = o.mcpPort;
    this.meshPort = o.meshPort;
    this.id = o.id;
    this.bin = o.bin;
  }

  tail = () => this.said.slice(-6000);
  takenOver = () => [...this.said.matchAll(/(?:Node|station) (\d+) has taken over/g)].map((m) => Number(m[1]));

  /// A member's request on the mesh: a body given as JSON, or bytes as they are.
  async ask(method: string, path: string, body?: unknown): Promise<Answer> {
    try {
      return await this.asked(method, path, body);
    } catch (e) {
      // (a stream the station reset or never answered is an answer too: compared as one)
      return { status: 0, json: null, text: `the stream failed: ${(e as Error).message}` };
    }
  }

  private async asked(method: string, path: string, body?: unknown): Promise<Answer> {
    const stream = await this.conn.openBi();
    const bytes = Buffer.isBuffer(body);
    await line(stream, { method, path: `/admin/api${path}`, headers: { "content-type": bytes ? "application/octet-stream" : "application/json" } });
    if (body !== undefined) await stream.write(bytes ? body : Buffer.from(JSON.stringify(body)));
    await stream.finish();
    const reader = new Reader(stream);
    const head = await reader.line();
    const text = (await reader.rest()).toString();
    let json: any = null;
    try { json = JSON.parse(text || "null"); } catch {}
    return { status: head.status, json, text };
  }

  db() {
    return new DatabaseSync(join(this.data, "stillfail.db"), { readOnly: true });
  }
}

/// The pair: one release with Node, one without, on data directories seeded alike.
class Twins {
  readonly grant = new GrantKey();
  stations: Station[] = [];
  plane!: Awaited<ReturnType<typeof controlPlane>>;
  client!: Awaited<ReturnType<NonNullable<typeof addon>["bind"]>>;
  scripts!: string;

  async start(kinds: ("node" | "mb")[] = ["node", "mb"]) {
    this.plane = await controlPlane();
    this.client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
    closers.push(() => void this.client.close().catch(() => undefined));
    this.scripts = fresh("scripts");
    // (what the fake does with a prompt that names no script: the station's own asks, a title's or a state's)
    writeFileSync(join(this.scripts, "nudge.sh"), script([["nudge", mcp(1, "chat_post", { to: "$TO", text: "named it", title: "Twin chat", kind: "all_done", done: "named the chat" })]]));
    // (a key each: the member's endpoint reaches a station by its key, and two of one key would be one to it)
    this.stations = await Promise.all(kinds.map((kind) => this.station(kind)));
  }

  /// Every station of the pair stopped as its launcher is (SIGTERM), what is left of each ended, the member's endpoint
  /// and the control plane closed: the next test has the machine to itself.
  async stop() {
    for (const s of this.stations) if (s.child.exitCode === null && s.child.signalCode === null) s.child.kill("SIGTERM");
    await Promise.all(this.stations.map((s) => s.ended));
    for (const s of this.stations) endAll(s.data);
    await this.client?.close().catch(() => undefined);
    this.plane?.close();
  }

  /// A release laid out as station-bundle.sh lays one: the program, the runner and, for Node, main.js (src/main.ts).
  static layOut(app: string, kind: "node" | "mb") {
    mkdirSync(join(app, "station"), { recursive: true });
    for (const [from, to] of [[binary!, "stillfail-reader"], [runner, "stillfail-runner"]] as const) {
      if (!existsSync(join(app, "station", to))) {
        copyFileSync(from, join(app, "station", to));
        chmodSync(join(app, "station", to), 0o755);
      }
    }
    writeFileSync(join(app, "BUILD"), "9700\n");
    if (kind === "node") writeFileSync(join(app, "station", "main.js"), `import ${JSON.stringify(pathToFileURL(mainTs).href)};\n`);
    else rmSync(join(app, "station", "main.js"), { force: true });
  }

  async station(kind: "node" | "mb"): Promise<Station> {
    const app = fresh(`app-${kind}`);
    Twins.layOut(app, kind);
    const bin = fresh(`bin-${kind}`);
    fakeClaude(bin);
    const out = fresh(`out-${kind}`);
    const data = fresh(`data-${kind}`);
    const made = spawnSync(binary!, ["id", "--data", data], { env: { PATH: "/usr/bin:/bin", HOME: data }, encoding: "utf8" });
    const id = made.stdout.trim();
    assert.match(id, /^[0-9a-f]{64}$/, made.stderr);
    const meshPort = await freeUdpPort();
    const mcpPort = await freeTcpPort();
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
      origin: this.plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: { keys: [this.grant.jwk] }, peers: [], revocations: [],
    }));
    mkdirSync(join(data, "homes", "cc"), { recursive: true });
    writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
    writeFileSync(join(data, "config.json"), JSON.stringify({
      language: "en",
      http: { port: mcpPort },
      profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }],
      maxNudges: 1,
    }));
    const s = new Station({ kind, app, data, out, mcpPort, meshPort, id, bin });
    await this.launch(s);
    return s;
  }

  /// The launcher started on a station's release and data, and a member let in to it on the mesh.
  async launch(s: Station) {
    const env: Record<string, string> = {
      PATH: s.bin, HOME: s.data, TMPDIR: tmpdir(), FAKE_OUT: s.out, FAKE_SCRIPTS: this.scripts,
      STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${s.meshPort}`,
      STILLFAIL_AGENT_NICE: "0", STILLFAIL_HELD_EVERY_MS: "300",
      // (Node's, for main.js: its addon, the program and the runner as the release would have them beside it)
      STILLFAIL_NODE: process.execPath, STILLFAIL_MESH_NATIVE: meshNative,
      STILLFAIL_MB_READER: join(s.app, "station", "stillfail-reader"), STILLFAIL_RUNNER: join(s.app, "station", "stillfail-runner"),
    };
    const loopPort = await freeTcpPort();
    s.said = "";
    s.child = spawn(launcher, ["run", "--app", s.app, "--data", s.data, "--port", String(loopPort)], { stdio: ["ignore", "pipe", "pipe"], env });
    children.push(s.child);
    s.child.stdout!.on("data", (d) => (s.said += d));
    s.child.stderr!.on("data", (d) => (s.said += d));
    s.ended = new Promise((resolve) => s.child.on("exit", (code) => resolve(code)));
    await until(`${s.kind}: taken over`, () => s.takenOver()[0], s.tail, 60_000);
    await this.connect(s);
  }

  async connect(s: Station) {
    const now = Math.floor(Date.now() / 1000);
    const credential = this.grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u1", email: "ada@x.com", name: "Ada", ws: "w1", role: "owner", device: this.client.id(), sid: "s1", iat: now, exp: now + 3600 });
    s.conn = await until(`${s.kind}: connected on the mesh`, async () => {
      const conn = await this.client.connect({ id: s.id, ips: [`127.0.0.1:${s.meshPort}`] }, Buffer.from("stillfail/admin/1"));
      const first = await conn.openBi();
      await line(first, { credential, protocol: 2 });
      const hello = await new Reader(first).line();
      return hello.ok === true ? conn : null;
    }, s.tail);
  }

  /// The same request of both, each answer made comparable.
  async both(method: string, path: string | ((s: Station, i: number) => string), body?: unknown | ((s: Station) => unknown)): Promise<[Answer, Answer]> {
    const [a, b] = await Promise.all(this.stations.map((s, i) => s.ask(method, typeof path === "function" ? path(s, i) : path, typeof body === "function" ? (body as (s: Station) => unknown)(s) : body)));
    return [a!, b!];
  }
}

// ── what is made alike before two answers are compared ──
const DYNAMIC_KEY = /(?:^|_)(?:at|ts|time|ms|pid|port|uptime|since|until|started|ended|created|updated|modified|mtime|expires?)(?:$|_)|(?:At|Ms|Ts|Time|Pid|Port|Since|Until)$|^(?:now|pid|pgid|port|uptime|key|token|id|sid)$/;
function normalize(v: any, roots: string[], key = ""): any {
  if (Array.isArray(v)) return v.map((x) => normalize(x, roots, key));
  if (v !== null && typeof v === "object") {
    const out: Record<string, any> = {};
    for (const k of Object.keys(v).sort()) out[k] = normalize(v[k], roots, k);
    return out;
  }
  if (typeof v === "number" && DYNAMIC_KEY.test(key)) return "<n>";
  if (typeof v === "string") {
    if (/^\s*[{[]/.test(v)) {
      try { return { "<json>": normalize(JSON.parse(v), roots, key) }; } catch {}
    }
    let t = v;
    for (const r of roots) t = t.split(r).join("<data>");
    t = t.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/g, "<uuid>");
    t = t.replace(/\b\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z\b/g, "<iso>");
    t = t.replace(/127\.0\.0\.1:\d+/g, "127.0.0.1:<port>");
    t = t.replace(/c-[0-9a-f]{10}(?![0-9a-f])/g, "c-<id>").replace(/\bjob_[0-9a-f]{8}\b/g, "job_<id>").replace(/\bp-[0-9a-f]{10}\b/g, "p-<id>");
    t = t.replace(/\b\d{10}\.\d{6}\b/g, "<ts>").replace(/\b\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-[0-9a-f]{6}-/g, "<upload>-");
    if (DYNAMIC_KEY.test(key) && /^[\w-]{8,}$/.test(t)) return "<id>";
    return t;
  }
  return v;
}

/// A check by name: what `f` asserts must hold, unless its name is pending, when it must fail (and the file fails once
/// it holds, until the name is taken out).
/// (each test's own, by where its checks run: what a test cut at its limit still checks goes in its list, never the next
/// one's)
type Results = { name: string; ok: boolean; why: string }[];
const ownResults = new AsyncLocalStorage<Results>();
const sideBySideResults: Results = [];
async function check(name: string, f: () => void | Promise<void>) {
  let why = "";
  try {
    await f();
  } catch (e) {
    why = (e as Error).message;
  }
  ownResults.getStore()!.push({ name, ok: why === "", why });
}
function judged(results: Results) {
  const wrong: string[] = [];
  for (const r of results) {
    const extra = MB_OVERVIEW_EXTRAS.has(r.name);
    if (!r.ok && !extra) wrong.push(`${r.name}: ${r.why}`);
    if (r.ok && extra) wrong.push(`${r.name} now passes — remove from MB_OVERVIEW_EXTRAS!`);
  }
  return wrong;
}

/// Where two values made alike differ: each path, with what Node and the MoonBit station have there.
function differences(a: any, b: any, at = ""): string[] {
  if (Array.isArray(a) && Array.isArray(b)) {
    const out: string[] = a.length !== b.length ? [`${at}: Node has ${a.length} items, MoonBit ${b.length}`] : [];
    for (let i = 0; i < Math.min(a.length, b.length); i++) out.push(...differences(a[i], b[i], `${at}[${i}]`));
    return out;
  }
  if (a !== null && b !== null && typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b)) {
    const out: string[] = [];
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (!(k in b)) out.push(`${at}.${k}: only Node has it (${JSON.stringify(a[k]).slice(0, 120)})`);
      else if (!(k in a)) out.push(`${at}.${k}: only MoonBit has it (${JSON.stringify(b[k]).slice(0, 120)})`);
      else out.push(...differences(a[k], b[k], `${at}.${k}`));
    }
    return out;
  }
  return JSON.stringify(a) === JSON.stringify(b) ? [] : [`${at}: Node ${JSON.stringify(a)?.slice(0, 160)}, MoonBit ${JSON.stringify(b)?.slice(0, 160)}`];
}

function same(name: string, a: Answer, b: Answer, roots: string[], ignore: RegExp[] = []) {
  if (process.env.TWIN_DUMP) writeFileSync(join(process.env.TWIN_DUMP, name.replace(/\W+/g, "_").slice(0, 80) + ".json"), JSON.stringify({ node: a.json, mb: b.json }, null, 1));
  return check(name, () => {
    assert.equal(b.status, a.status, `status: Node ${a.status} ${a.text.slice(0, 300)}; MoonBit ${b.status} ${b.text.slice(0, 300)}`);
    const d = differences(normalize(a.json, roots), normalize(b.json, roots)).filter((x) => !ignore.some((r) => r.test(x)));
    assert.deepEqual(d, [], d.join("\n"));
  });
}

/// The rows of a table as the station wrote them, made comparable (its dynamic columns made alike), in a stable order.
function rows(db: DatabaseSync, table: string, roots: string[], where = ""): any[] {
  const all = db.prepare(`SELECT * FROM ${table} ${where} ORDER BY rowid`).all() as Record<string, unknown>[];
  return all.map((r) => normalize(Object.fromEntries(Object.entries(r).map(([k, v]) => {
    if (typeof v === "string" && (v.startsWith("{") || v.startsWith("["))) {
      try { return [k, JSON.parse(v)]; } catch {}
    }
    return [k, v];
  })), roots));
}

/// A session made on each station through the admin API, its key and thread.
type Made = { key: string; thread: number };

/// A message to each station's session: its agent's turn runs `do` (a script of the fake's), and the answers of its
/// MCP calls are read back once that turn has ended.
async function turn(twins: Twins, made: Made[], name: string, calls: [string, string][], ended: (s: Station, m: Made) => boolean | Promise<boolean> = () => true) {
  writeFileSync(join(twins.scripts, `${name}.sh`), script(calls));
  const answers: Record<string, any>[] = [];
  for (const [i, s] of twins.stations.entries()) {
    const m = made[i]!;
    const done = () => {
      try {
        const f = readdirSync(s.out).find((n) => n.endsWith("-done"));
        return f === undefined ? [] : readFileSync(join(s.out, f), "utf8").split("\n").filter((x) => x !== "");
      } catch {
        return [];
      }
    };
    const before = done().length;
    const sent = await s.ask("POST", `/threads/${m.thread}/messages`, { text: `do: ${name}` });
    assert.ok(sent.status >= 200 && sent.status < 300, `${s.kind}: ${sent.text}; ${s.tail()}`);
    await until(`${s.kind}: the turn of ${name} ran its script`, () => done().slice(before).includes(name), s.tail);
    await until(`${s.kind}: the turn of ${name} ended with a state`, () => settled(s, m.key) && ended(s, m), s.tail);
    const ran = readdirSync(s.out).find((f) => f.endsWith(`-${name}.out`));
    assert.ok(ran !== undefined, `${s.kind}: ${name} ran`);
    const at = ran!.slice(0, -`-${name}.out`.length);
    const out: Record<string, any> = {};
    for (const [id] of calls) out[id] = readJson(join(s.out, `${at}-${id}.json`));
    answers.push(out);
  }
  if (process.env.TWIN_DUMP) writeFileSync(join(process.env.TWIN_DUMP, `turn-${name}.json`), JSON.stringify({ node: answers[0], mb: answers[1] }, null, 1));
  return answers as [Record<string, any>, Record<string, any>];
}

/// Whether a session's turns are all over, the last with a state said (a nudge for one with none, or for a title,
/// is a turn of its own that has to end too).
/// How many turns a session has had.
function turnsOf(s: Station, key: string): number {
  const db = s.db();
  try {
    return (db.prepare("SELECT count(*) AS n FROM turns WHERE session_key = ?").get(key) as { n: number }).n;
  } finally {
    db.close();
  }
}
function settled(s: Station, key: string): boolean {
  const db = s.db();
  try {
    const last = db.prepare("SELECT ended_at, declared FROM turns WHERE session_key = ? ORDER BY started_at DESC, rowid DESC LIMIT 1").get(key) as { ended_at: number | null; declared: string | null } | undefined;
    const running = (db.prepare("SELECT count(*) AS n FROM turns WHERE session_key = ? AND ended_at IS NULL").get(key) as { n: number }).n;
    return last !== undefined && last.ended_at !== null && last.declared !== null && running === 0;
  } catch {
    return false;
  } finally {
    db.close();
  }
}

/// An MCP call's body, for the fake's script.
const mcp = (id: number, name: string, args: Record<string, unknown>) => JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });

/// The tools one runtime is given, by what each declares: its name, its parameters' names, types, enums and which are
/// required.
function shapes(list: any): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const shape = (schema: any): unknown => {
    if (schema === null || typeof schema !== "object") return schema;
    if (Array.isArray(schema)) return schema.map(shape);
    const kept: Record<string, unknown> = {};
    for (const k of Object.keys(schema).sort()) if (k !== "description") kept[k] = shape(schema[k]);
    return kept;
  };
  for (const t of list?.result?.tools ?? []) out[t.name] = shape(t.inputSchema);
  return out;
}

test("the MoonBit station answers as the TypeScript one, side by side, and a handover chain carries a session through both", { skip, timeout: 240_000 }, async () => {
  const twins = new Twins();
  const results = sideBySideResults;
  try {
    await ownResults.run(results, () => sideBySide(twins));
  } finally {
    if (process.env.TWIN_DUMP) {
      writeFileSync(join(process.env.TWIN_DUMP, "results.json"), JSON.stringify(results, null, 1));
      for (const s of twins.stations) writeFileSync(join(process.env.TWIN_DUMP, `log-${s.kind}.txt`), s.said);
    }
    await twins.stop();
  }
  const wrong = judged(results);
  assert.deepEqual(wrong, [], wrong.join("\n\n"));
});

async function sideBySide(twins: Twins) {
  await twins.start();
  const [node, mb] = twins.stations as [Station, Station];
  const roots = [node.data, mb.data, node.app, mb.app, node.out, mb.out, twins.scripts, node.id, mb.id];
  // (what is the machine's or the network's at the moment it is read: its disk, the relays reached, npm's latest)
  // (and the copies' export, which runs in the background and counts where it sent as it goes)
  // (the updates are each one's first look, at npm and the machine, at a moment of its own: what either has read by
  // then differs from run to run)
  const machine = [/\.disk\.freeBytes:/, /\.checkedAt:/, /^\.mesh\.reached:/, /^\.updates\b/, /^\.copies\.to:/];
  // (what an account's routes answer with: the overview, whose fields are each held below once both are settled; the
  // account's own are compared there, beside what is still each one's first look: the copies to take back)
  const overviewed = [...machine.map((r) => new RegExp(r.source.replace("^\\.", "^(?:\\.overview)?\\."))), /^(?:\.overview)?\.(automaticDecisions|machine|machineLogins|rigs|updates|mesh)\b/, /^(?:\.overview)?\.copies\.(empty|restorable)\b/, /^(?:\.overview)?\.profiles\[\d+\]\.check\b/];

  // ── the admin API's reads of a station new to it ──
  for (const path of ["/sessions", "/threads", "/workspaces", "/jobs", "/drive", "/presets", "/stars", "/usage", "/profiles/pace"]) {
    const [a, b] = await twins.both("GET", path);
    await same(`GET ${path}`, a, b, roots, machine);
  }

  // ── its settings: written, refused, read back ──
  for (const [method, path, body] of [
    ["PUT", "/archiving", { days: 2, slackDays: 5 }],
    ["PUT", "/archiving", { days: "soon" }],
    ["POST", "/profiles", { runtime: "claude", name: "Twin" }],
    ["POST", "/profiles", { runtime: "nonesuch" }],
    ["GET", `/usage?from=0&to=${Date.UTC(2030, 0, 1)}&tz=0`, undefined],
    ["GET", "/usage?historyFrom=60000", undefined],
  ] as const) {
    const [a, b] = await twins.both(method, path, body);
    await same(`${method} ${path} ${JSON.stringify(body)}`, a, b, roots, machine);
  }
  // an account of the station's own (its variables, which nothing checks): made, renamed, read, taken away
  {
    const [a, b] = await twins.both("POST", "/profiles", { runtime: "claude", name: "Twin", access: { kind: "env", env: { TWIN: "1" } } });
    await same("POST /profiles (env)", a, b, roots, overviewed);
    const ids = [a.json?.id, b.json?.id];
    if (typeof ids[0] === "string" && typeof ids[1] === "string") {
      for (const [method, body] of [["PUT", { name: "Twin renamed" }], ["GET", undefined], ["DELETE", undefined]] as const) {
        const [x, y] = await twins.both(method, (_, i) => `/profiles/${encodeURIComponent(ids[i]!)}`, body);
        await same(`${method} /profiles/:id`, x, y, [...roots, ids[0], ids[1]], overviewed);
      }
    }
  }
  // a preset: made, changed, taken away
  {
    const [a, b] = await twins.both("POST", "/presets", { name: "p1", runtime: "claude", profile: "cc" });
    await same("POST /presets", a, b, roots, machine);
    const ids = [a.json?.id, b.json?.id];
    if (typeof ids[0] === "string" && typeof ids[1] === "string") {
      for (const [method, body] of [["PUT", { name: "p2", instructions: "be brief" }], ["DELETE", undefined]] as const) {
        const [x, y] = await twins.both(method, (_, i) => `/presets/${encodeURIComponent(ids[i]!)}`, body);
        await same(`${method} /presets/:id`, x, y, roots, machine);
      }
      const [x, y] = await twins.both("GET", "/presets/kept");
      await same("GET /presets/kept after", x, y, roots, machine);
    }
  }

  // ── a chat: a session made, its agent's turns through /mcp ──
  const made: Made[] = [];
  for (const s of twins.stations) {
    const said = await s.ask("POST", "/sessions", { runtime: "claude", profile: "cc" });
    assert.equal(said.status, 200, `${s.kind}: ${said.text}; ${s.tail()}`);
    made.push({ key: said.json.key, thread: said.json.thread?.id ?? said.json.thread?.thread?.id });
  }
  {
    const [a, b] = await twins.both("GET", "/sessions");
    await same("GET /sessions with one", a, b, roots, machine);
  }
  // the tools an agent is given, each as it declares itself
  const [listed] = [await turn(twins, made, "tools", [["list", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" })], ["post", mcp(2, "chat_post", { to: "$TO", text: "listed", kind: "all_done", done: "listed the tools" })]])];
  await check("tools/list: the same tools", () => {
    const names = (x: any) => (x?.result?.tools ?? []).map((t: any) => t.name).sort();
    assert.deepEqual(names(listed[1].list), names(listed[0].list));
  });
  await check("tools/list: each tool's parameters", () => {
    const [a, b] = [shapes(listed[0].list), shapes(listed[1].list)];
    const both = (x: Record<string, unknown>, y: Record<string, unknown>) => Object.fromEntries(Object.entries(x).filter(([k]) => k in y));
    const d = differences(both(a, b), both(b, a));
    assert.deepEqual(d, [], d.join("\n"));
  });
  await check("tools/list: each tool's description", () => {
    const desc = (x: any, y: any) => Object.fromEntries((x?.result?.tools ?? []).filter((t: any) => (y?.result?.tools ?? []).some((u: any) => u.name === t.name)).map((t: any) => [t.name, normalize(t.description, roots)]));
    const d = differences(desc(listed[0].list, listed[1].list), desc(listed[1].list, listed[0].list));
    assert.deepEqual(d, [], d.join("\n"));
  });
  await check("tools/list: each tool in the same place, with what it is loaded by", () => {
    const meta = (x: any) => (x?.result?.tools ?? []).map((t: any) => [t.name, t._meta ?? null]);
    assert.deepEqual(meta(listed[1].list), meta(listed[0].list));
  });

  // a turn that names the chat, says how it goes, asks with a card and reads the chat back
  const chat = await turn(twins, made, "chat", [
    ["title", mcp(1, "chat_post", { to: "$TO", text: "working on it", title: "Twin chat" })],
    ["card", mcp(2, "chat_post", { to: "$TO", text: "Which one?", kind: "need_human", need: "pick one", card: { type: "options", assignee: "ada@x.com", options: [{ label: "A" }, { label: "B", recommended: true }] } })],
    ["history", mcp(3, "chat_history", { to: "$TO" })],
    ["list", mcp(4, "chat_list", {})],
    ["session", mcp(5, "session_history", {})],
  ]);
  for (const id of ["title", "card", "history", "list", "session"]) {
    await check(`mcp chat_* ${id}`, () => {
      const d = differences(normalize(chat[0][id], roots), normalize(chat[1][id], roots));
      assert.deepEqual(d, [], d.join("\n"));
    });
  }
  // the person answers; the agent withdraws nothing, reads, and ends done
  const answered = await turn(twins, made, "answered", [
    ["read", mcp(1, "chat_read", { chat: "$TO" })],
    ["done", mcp(2, "chat_post", { to: "$TO", text: "took B", kind: "all_done", done: "picked B as asked" })],
  ]);
  for (const id of ["read", "done"]) {
    await check(`mcp after the answer ${id}`, () => {
      const d = differences(normalize(answered[0][id], roots), normalize(answered[1][id], roots));
      assert.deepEqual(d, [], d.join("\n"));
    });
  }
  {
    const [a, b] = await twins.both("GET", "/threads");
    await same("GET /threads after the chat", a, b, roots, machine);
  }

  // ── a background job: started, listed, its log, stopped ──
  const jobs = await turn(twins, made, "jobs", [
    // (it ends once the test says so: its end comes after the turn that started it, on both)
    ["start", mcp(1, "job_start", { name: "hello", command: "echo hi; while [ ! -e ../go ]; do sleep 0.05; done; echo bye" })],
    ["list", mcp(2, "job_list", {})],
    ["post", mcp(3, "chat_post", { to: "$TO", text: "started", kind: "all_done", done: "started a job" })],
  ]);
  const turnsBefore: number[] = [];
  for (const [i, s] of twins.stations.entries()) {
    const db = s.db();
    const ws = (db.prepare("SELECT workspace FROM sessions WHERE key = ?").get(made[i]!.key) as { workspace: string }).workspace;
    turnsBefore[i] = turnsOf(s, made[i]!.key);
    db.close();
    writeFileSync(join(ws, "..", "go"), "");
    await until(`${s.kind}: the job ended`, () => {
      const db = s.db();
      try { return (db.prepare("SELECT state FROM jobs").get() as { state: string } | undefined)?.state === "exited"; } finally { db.close(); }
    }, s.tail);
  }
  // (its end told to the session: a turn of its own, which has to begin and end too; the job's row says it exited
  // before the session is told)
  for (const [i, s] of twins.stations.entries()) await until(`${s.kind}: settled after the job's end`, () => turnsOf(s, made[i]!.key) > turnsBefore[i]! && settled(s, made[i]!.key), s.tail);
  const ended = await turn(twins, made, "jobs-ended", [
    ["list", mcp(1, "job_list", {})],
    ["log", mcp(2, "job_log", { id: "$JOB" })],
    ["post", mcp(3, "chat_post", { to: "$TO", text: "ended", kind: "all_done", done: "read the job" })],
  ]);
  for (const id of ["list", "log"]) {
    await check(`mcp job_${id} after its end`, () => {
      const d = differences(normalize(ended[0][id], roots), normalize(ended[1][id], roots));
      assert.deepEqual(d, [], d.join("\n"));
    });
  }
  for (const id of ["start", "list"]) {
    await check(`mcp job_${id}`, () => {
      const d = differences(normalize(jobs[0][id], roots), normalize(jobs[1][id], roots));
      assert.deepEqual(d, [], d.join("\n"));
    });
  }

  // a job that runs until it is stopped
  const stopped = await turn(twins, made, "jobs-stop", [
    ["start", mcp(1, "job_start", { name: "lasting", command: "exec sleep 600" })],
    ["stop", `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"job_stop","arguments":{"id":"$LAST"}}}`],
    ["post", mcp(3, "chat_post", { to: "$TO", text: "stopped", kind: "all_done", done: "stopped the job" })],
  ]);
  for (const id of ["start", "stop"]) {
    await check(`mcp job_${id} (stopped)`, () => {
      const d = differences(normalize(stopped[0][id], roots), normalize(stopped[1][id], roots));
      assert.deepEqual(d, [], d.join("\n"));
    });
  }

  // ── the vault, never turned on here: what its tools answer ──
  const vault = await turn(twins, made, "vault", [
    ["list", mcp(1, "secret_list", {})],
    ["describe", mcp(2, "secret_describe", { item: "nope", reason: "to see" })],
    ["post", mcp(3, "chat_post", { to: "$TO", text: "looked", kind: "all_done", done: "looked at the vault" })],
  ]);
  for (const id of ["list", "describe"]) {
    await check(`mcp secret_${id}`, () => {
      const d = differences(normalize(vault[0][id], roots), normalize(vault[1][id], roots));
      assert.deepEqual(d, [], d.join("\n"));
    });
  }

  // ── a file uploaded for a message, read back ──
  {
    const [a, b] = await twins.both("POST", "/uploads?name=twin.txt", Buffer.from("a twin's file\n"));
    await same("POST /uploads", a, b, roots, machine);
  }

  // ── the chat archived through the admin API, and its row read back ──
  {
    const [a, b] = await twins.both("POST", (_, i) => `/sessions/${encodeURIComponent(made[i]!.key)}/archive`, {});
    await same("POST /sessions/:key/archive", a, b, roots, machine);
    const [x, y] = await twins.both("GET", "/sessions");
    await same("GET /sessions archived", x, y, roots, machine);
  }

  // ── what each wrote of it all ──
  for (const table of ["sessions", "threads", "thread_sessions", "entries", "turns", "jobs", "closed_cards", "card_choices", "archive_policy", "deliveries"]) {
    await check(`stillfail.db ${table}`, () => {
      const [a, b] = twins.stations.map((s) => {
        const db = s.db();
        try { return rows(db, table, roots); } finally { db.close(); }
      });
      const d = differences(a, b);
      assert.deepEqual(d, [], d.join("\n"));
    });
  }

  // ── what the plane's presence socket tells each: the model catalog changed (models/module.ts `plane.told("models")`)
  {
    for (const s of [node, mb]) await until(`${s.kind}: on the presence socket`, () => twins.plane.connected(s.id), s.tail);
    for (const s of [node, mb]) await until(`${s.kind}: the catalog read as it started`, () => readJson(join(s.data, "model-catalog.json"))?.etag === '"m-1"', s.tail);
    twins.plane.catalog.etag = '"m-2"';
    twins.plane.catalog.models = { "m-2": { name: "Two" } };
    for (const s of [node, mb]) twins.plane.push(s.id, { type: "models", etag: '"m-2"' });
    for (const s of [node, mb]) {
      await check(`presence models: ${s.kind} reads the catalog the plane named`, () =>
        until(`${s.kind}: model-catalog.json of the plane's new catalog`, () => readJson(join(s.data, "model-catalog.json"))?.etag === '"m-2"', s.tail, 20_000).then(() => undefined));
    }
    await check("presence models: both catalogs alike", () => assert.deepEqual(readJson(join(mb.data, "model-catalog.json")), readJson(join(node.data, "model-catalog.json"))));
  }

  // ── config.json edited by another program while an event stream is open: the overview told again by both ──
  {
    const streams = await Promise.all([node, mb].map((s) => events(s)));
    for (const [i, st] of streams.entries()) await until(`${[node, mb][i]!.kind}: the event stream's first id`, () => st.ids().length > 0, () => st.text().slice(0, 400));
    const marks = streams.map((st) => st.text().length);
    for (const s of [node, mb]) {
      const raw = readJson(join(s.data, "config.json"));
      writeFileSync(join(s.data, "config.json"), JSON.stringify({ ...raw, connects: [{ id: "s9", kind: "slack", enabled: false, bind: { runtime: "claude" }, slack: { appToken: "xapp-9", botToken: "xoxb-9" } }] }));
    }
    for (const [i, s] of [node, mb].entries()) {
      await check(`config.json changed: ${s.kind} tells the overview again`, () =>
        until(`${s.kind}: an overview with the connect added`, () => /^event: overview$/m.test(streams[i]!.text().slice(marks[i]!)) && streams[i]!.text().slice(marks[i]!).includes('"s9"'), () => streams[i]!.text().slice(-1200), 20_000).then(() => undefined));
    }
  }

  // ── the overview, once both have been up a while (what each part puts in it, its first look done): a field each ──
  {
    // (each one's first look done: the machine's sign-ins read, the copies' export caught up with the chats; on a
    // machine short of cores either can come seconds after the other)
    let [a, b] = await twins.both("GET", "/overview");
    const settled = (x: typeof a, y: typeof a) => x.json?.machineLogins?.length > 0 && y.json?.machineLogins?.length > 0 && x.json?.copies?.chats === y.json?.copies?.chats;
    await until("both overviews past their first look", async () => settled(a, b) || ([a, b] = await twins.both("GET", "/overview"), settled(a, b)), () => JSON.stringify({ node: [a.json?.machineLogins?.length, a.json?.copies?.chats], mb: [b.json?.machineLogins?.length, b.json?.copies?.chats] }), 60_000).catch(() => undefined);
    if (process.env.TWIN_DUMP) writeFileSync(join(process.env.TWIN_DUMP, "overview.json"), JSON.stringify({ node: a.json, mb: b.json }, null, 1));
    await check("GET /overview: its status", () => assert.equal(b.status, a.status, b.text.slice(0, 300)));
    for (const k of [...new Set([...Object.keys(a.json ?? {}), ...Object.keys(b.json ?? {})])].sort()) {
      await check(`GET /overview .${k}`, () => {
        const d = differences(normalize({ [k]: a.json?.[k] }, roots), normalize({ [k]: b.json?.[k] }, roots)).filter((x) => !machine.some((r) => r.test(x)));
        assert.deepEqual(d, [], d.join("\n"));
      });
    }
  }
}

/// An event stream of a member's on the mesh (GET /events): what it said so far, as it comes.
async function events(s: Station, since?: string) {
  const stream = await s.conn.openBi();
  await line(stream, { method: "GET", path: `/admin/api/events${since === undefined ? "" : `?since=${encodeURIComponent(since)}`}`, headers: {} });
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  const heard: string[] = [reader.carry.toString()];
  let open = true;
  void (async () => {
    try {
      for (let more = await stream.read(); more; more = await stream.read()) heard.push(Buffer.from(more).toString());
    } catch {}
    open = false;
  })();
  const text = () => heard.join("");
  return {
    head,
    text,
    open: () => open,
    /// The ids it was told, in order (`<run>.<n>`).
    ids: () => [...text().matchAll(/^id: (\S+)$/gm)].map((m) => m[1]!),
    names: () => [...text().matchAll(/^event: (\S+)$/gm)].map((m) => m[1]!),
  };
}

/// The process serving a station now, as `ps` names its command.
const commandOf = (pid: number) => spawnSync("ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" }).stdout.trim();

test("a handover chain by the launcher: Node → MoonBit → MoonBit → Node, a session's turns, its job, its rows and the event stream carried by every hop", { skip, timeout: 240_000 }, async () => {
  const twins = new Twins();
  const results: Results = [];
  try {
    await ownResults.run(results, () => chain(twins));
  } finally {
    if (process.env.TWIN_DUMP) {
      writeFileSync(join(process.env.TWIN_DUMP, "chain.json"), JSON.stringify(results, null, 1));
      for (const s of twins.stations) writeFileSync(join(process.env.TWIN_DUMP, "log-chain.txt"), s.said);
    }
    await twins.stop();
  }
  const wrong = judged(results);
  assert.deepEqual(wrong, [], wrong.join("\n\n"));
});

async function chain(twins: Twins) {
  await twins.start(["node"]);
  const s = twins.stations[0]!;
  const roots = [s.data, s.app, s.out, twins.scripts, s.id];
  let made: Made;
  {
    const said = await s.ask("POST", "/sessions", { runtime: "claude", profile: "cc" });
    assert.equal(said.status, 200, said.text);
    made = { key: said.json.key, thread: said.json.thread?.id ?? said.json.thread?.thread?.id };
  }
  // a turn that names the chat and starts a job that lasts past every hop
  await turn(twins, [made], "chain-start", [
    ["start", mcp(1, "job_start", { name: "lasting", command: "echo started; exec sleep 600" })],
    ["post", mcp(2, "chat_post", { to: "$TO", text: "started", title: "Chain", kind: "all_done", done: "started the lasting job" })],
  ]);
  const jobRow = () => {
    const db = s.db();
    try { return db.prepare("SELECT id, state, pgid FROM jobs").get() as { id: string; state: string; pgid: number | null }; } finally { db.close(); }
  };
  const job = await until("the job running with its group", () => {
    const j = jobRow();
    return j?.state === "running" && j.pgid !== null ? j : null;
  }, s.tail);
  const kept = (table: string) => {
    const db = s.db();
    try { return rows(db, table, roots); } finally { db.close(); }
  };
  const sessionsBefore = kept("sessions");
  let stream = await events(s);
  await until("the event stream's first id", () => stream.ids().length > 0, () => stream.text().slice(0, 400));

  const hops: { to: "node" | "mb"; name: string }[] = [
    { to: "mb", name: "Node → MoonBit" },
    { to: "mb", name: "MoonBit → MoonBit" },
    { to: "node", name: "MoonBit → Node" },
  ];
  for (const [i, hop] of hops.entries()) {
    const before = s.takenOver().at(-1)!;
    const seen = s.takenOver().length;
    const lastId = stream.ids().at(-1)!;
    Twins.layOut(s.app, hop.to);
    s.child.kill("SIGUSR2");
    const next = await until(`${hop.name}: the next process took over`, () => s.takenOver()[seen], s.tail, 60_000);
    await until(`${hop.name}: the process before gone`, () => !alive(before), s.tail);
    await check(`${hop.name}: every part's memory carried over and taken up (live.plans, live.tails, vault)`, () => {
      const failed = s.said.split("\n").filter((l) => /memory is not carried over|carried over is not taken up/.test(l));
      assert.deepEqual(failed, [], failed.join("\n"));
    });
    await check(`${hop.name}: the process serving is the release's`, () => {
      const cmd = commandOf(next);
      assert.ok(hop.to === "node" ? cmd.includes("main.js") : cmd.includes("stillfail-reader") && !cmd.includes("main.js"), cmd);
    });
    await twins.connect(s);
    // the event stream taken up where it was: what came after the last id it heard, no `missed`
    stream = await events(s, lastId);
    await until(`${hop.name}: the event stream open again`, () => stream.text().length > 0 || !stream.open(), () => stream.text().slice(0, 400));
    await check(`${hop.name}: the event stream resumed, nothing missed`, async () => {
      // (what it says before its first id: `missed`, or the log told again; a stream told nothing yet is no answer)
      await until("the stream's first id", () => stream.ids().length > 0, () => stream.text().slice(0, 400), 10_000);
      assert.ok(!stream.names().includes("missed"), stream.text().slice(0, 600));
    });
    // the session's next turn, under the next process
    await check(`${hop.name}: the session's next turn`, async () => {
      const said = await turn(twins, [made], `chain-${i}`, [
        ["list", mcp(1, "job_list", {})],
        ["post", mcp(2, "chat_post", { to: "$TO", text: `hop ${i}`, kind: "all_done", done: `hop ${i} answered` })],
      ]);
      assert.match(JSON.stringify(said[0].post), /all_done/);
      assert.match(JSON.stringify(said[0].list), new RegExp(job.id));
    });
    await check(`${hop.name}: the job still running, its group alive`, () => {
      const j = jobRow();
      assert.equal(j.state, "running", JSON.stringify(j));
      assert.equal(j.pgid, job.pgid);
      assert.ok(alive(job.pgid!), `the job's group ${job.pgid} alive`);
    });
    await check(`${hop.name}: the session's row as it was`, () => {
      const d = differences(sessionsBefore, kept("sessions")).filter((x) => !/\.(last_|turns|status|running|state|updated|title)/.test(x));
      assert.deepEqual(d, [], d.join("\n"));
    });
    // (written each HELD_EVERY_MS from the serving process's loop: the one before's until the next one's first)
    await check(`${hop.name}: health.json written by the process serving`, () =>
      until("health.json of the process serving", () => readJson(join(s.data, "run", "health.json"))?.pid === next, () => JSON.stringify(readJson(join(s.data, "run", "health.json"))), 30_000).then(() => undefined));
  }
  // every turn of the session kept, each ended with its state
  await check("the chain: every turn kept", () => {
    const db = s.db();
    try {
      const t = db.prepare("SELECT declared FROM turns WHERE session_key = ? AND ended_at IS NOT NULL ORDER BY started_at").all(made.key) as { declared: string | null }[];
      assert.ok(t.filter((x) => x.declared === "all_done").length >= 1 + hops.length, JSON.stringify(t));
    } finally {
      db.close();
    }
  });
  // a stop: the launcher, its station and the job's runner end with it; nothing of the station left
  s.child.kill("SIGTERM");
  await check("the chain: a stop ends with code 0", async () => assert.equal(await s.ended, 0, s.tail()));
}

test("every check named in MB_OVERVIEW_EXTRAS is one of this file's", { skip }, () => {
  const unknown = [...MB_OVERVIEW_EXTRAS].filter((name) => !sideBySideResults.some((r) => r.name === name));
  assert.deepEqual(unknown, [], "listed, but no check of this file has that name");
});
