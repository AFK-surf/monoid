// A station handed over by the real launcher between its two engines and back (native/launcher, `stillfail-station
// run`, SIGUSR2): Node → MoonBit → MoonBit → Node, on a release laid out as station-bundle.sh lays one, with
// `station/main.js` (Node running src/main.ts) for Node and without it (`stillfail-reader run`) for the MoonBit
// station. A station that config.json sets to `"engine": "moonbit"` comes back to Node this way, so each hop must keep
// what a person has going: the session answers its next turn under the next process, its job stays running in the
// group it had, the event stream resumes where it was, and a stop ends with nothing left. Nothing here compares the
// two engines' answers: the MoonBit station is frozen for new TypeScript features (station/AGENTS.md), this holds only
// that a handover between them keeps working.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { createServer as httpServer } from "node:http";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { DatabaseSync } from "node:sqlite";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { GrantKey } from "./fake-control-plane.ts";

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

/// `work`, or failing with `what` once `ms` have passed (a real process's answer that may never come: every wait on one
/// is bounded, so a test fails saying where instead of running into its own timeout).
async function withTimeout<T>(work: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what}: no answer in ${ms} ms`)), ms);
    timer.unref?.();
  });
  try {
    return await Promise.race([work, late]);
  } finally {
    clearTimeout(timer);
  }
}

/// Looked at until `look` gives something (real processes: every 50 ms), or failing with `what` after `ms`; at once
/// where the launcher gave up or ended (`aborted`). A look that does not come back counts against `ms` too.
async function until<T>(what: string, look: () => T | null | undefined | false | Promise<T | null | undefined | false>, detail: () => string = () => "", ms = 30_000, aborted?: () => string): Promise<T> {
  const end = Date.now() + ms;
  let last: unknown = null;
  const never = (why: string) => new Error(`never: ${what}${why}${last ? ` (${(last as Error).message})` : ""}; ${detail()}`);
  for (;;) {
    const gone = aborted?.() ?? "";
    if (gone !== "") throw never(` (${gone})`);
    if (/giving up/.test(detail())) throw never("");
    const left = end - Date.now();
    if (left <= 0) throw never(` in ${ms} ms`);
    try {
      const v = await withTimeout(Promise.resolve().then(look), left, what);
      if (v) {
        return v as T;
      }
    } catch (e) {
      last = e;
    }
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
  `call() { /usr/bin/curl -s --max-time 20 -X POST "$URL" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" -d "$2" > "$FAKE_OUT/$SID-$N-$1.json"; }\n` +
  calls.map(([id, body]) => `call ${id} '${body.replaceAll("'", "'\\''").replaceAll("$TO", `'"$TO"'`).replaceAll("$JOB", `'"$JOB"'`).replaceAll("$LAST", `'"$(last)"'`)}'`).join("\n") + "\n";

const line = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

type Answer = { status: number; json: any; text: string };

/// One station, as the launcher runs it.
class Station {
  child!: ChildProcess;
  conn!: Connection;
  said = "";
  ended!: Promise<number | null>;
  readonly kind: "node" | "mb";
  readonly app: string;
  readonly data: string;
  readonly out: string;
  /// The UDP port its mesh is bound on now (the system's pick of `127.0.0.1:0`, read from its `mesh listening`).
  meshPort = 0;
  readonly id: string;
  readonly bin: string;
  constructor(o: { kind: "node" | "mb"; app: string; data: string; out: string; id: string; bin: string }) {
    this.kind = o.kind;
    this.app = o.app;
    this.data = o.data;
    this.out = o.out;
    this.id = o.id;
    this.bin = o.bin;
  }

  tail = () => this.said.slice(-6000);
  takenOver = () => [...this.said.matchAll(/(?:Node|station) (\d+) has taken over/g)].map((m) => Number(m[1]));
  /// The port each process it ran bound its mesh on, in order.
  meshPorts = () => [...this.said.matchAll(/mesh listening[^\n]*?sockets=[^\n]*?127\.0\.0\.1:(\d+)/g)].map((m) => Number(m[1]));
  /// Why the launcher is no more, once it is not.
  exited = () => (this.child && (this.child.exitCode !== null || this.child.signalCode !== null) ? `launcher exited (code=${this.child.exitCode}, signal=${this.child.signalCode})` : "");

  /// A member's request on the mesh: a body given as JSON, or bytes as they are.
  async ask(method: string, path: string, body?: unknown): Promise<Answer> {
    try {
      return await this.asked(method, path, body);
    } catch (e) {
      // (a stream the station reset or never answered is an answer too: compared as one)
      return { status: 0, json: null, text: `the stream failed: ${(e as Error).message}` };
    }
  }

  private asked(method: string, path: string, body?: unknown): Promise<Answer> {
    return withTimeout(this.asking(method, path, body), 30_000, `${this.kind}: ${method} ${path}`);
  }

  private async asking(method: string, path: string, body?: unknown): Promise<Answer> {
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

/// The stations of a test, each a release with Node or without it, on a data directory seeded as a station's.
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
  /// (each wait bounded: a stop that hangs would hide the error that brought the test here)
  async stop() {
    const running = () => this.stations.filter((s) => s.child && s.child.exitCode === null && s.child.signalCode === null);
    for (const s of running()) s.child.kill("SIGTERM");
    const ended = (ms: number) => withTimeout(Promise.all(this.stations.map((s) => s.ended)), ms, "the launchers' stop").catch(() => undefined);
    await ended(35_000);
    if (running().length > 0) {
      for (const s of running()) s.child.kill("SIGKILL");
      await ended(2_000);
    }
    for (const s of this.stations) endAll(s.data);
    if (this.client) await withTimeout(this.client.close(), 5_000, "the member's endpoint closed").catch(() => undefined);
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
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
      origin: this.plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: { keys: [this.grant.jwk] }, peers: [], revocations: [],
    }));
    mkdirSync(join(data, "homes", "cc"), { recursive: true });
    writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
    writeFileSync(join(data, "config.json"), JSON.stringify({
      language: "en",
      profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }],
      maxNudges: 1,
    }));
    const s = new Station({ kind, app, data, out, id, bin });
    await this.launch(s);
    return s;
  }

  /// The launcher started on a station's release and data, and a member let in to it on the mesh.
  async launch(s: Station) {
    const env: Record<string, string> = {
      PATH: s.bin, HOME: s.data, TMPDIR: tmpdir(), FAKE_OUT: s.out, FAKE_SCRIPTS: this.scripts,
      STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: "127.0.0.1:0",
      STILLFAIL_AGENT_NICE: "0", STILLFAIL_HELD_EVERY_MS: "300",
      // (Node's, for main.js: its addon, the program and the runner as the release would have them beside it)
      STILLFAIL_NODE: process.execPath, STILLFAIL_MESH_NATIVE: meshNative,
      STILLFAIL_MB_READER: join(s.app, "station", "stillfail-reader"), STILLFAIL_RUNNER: join(s.app, "station", "stillfail-runner"),
    };
    s.said = "";
    s.child = spawn(launcher, ["run", "--app", s.app, "--data", s.data], { stdio: ["ignore", "pipe", "pipe"], env });
    children.push(s.child);
    s.child.stdout!.on("data", (d) => (s.said += d));
    s.child.stderr!.on("data", (d) => (s.said += d));
    s.ended = new Promise((resolve) => s.child.on("exit", (code) => resolve(code)));
    await until(`${s.kind}: taken over`, () => s.takenOver()[0], s.tail, 60_000, s.exited);
    // (its mesh bound where the system put it: dialled only once it listens there)
    s.meshPort = await until(`${s.kind}: mesh listening`, () => s.meshPorts()[0], s.tail, 30_000, s.exited);
    await this.connect(s);
  }

  /// A member let in on the mesh, each try's handshake given up after 5 s (iroh's own wait is its idle timeout's).
  async connect(s: Station) {
    const now = Math.floor(Date.now() / 1000);
    const credential = this.grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u1", email: "ada@x.com", name: "Ada", ws: "w1", role: "owner", device: this.client.id(), sid: "s1", iat: now, exp: now + 3600 });
    const old = s.conn as Connection | undefined;
    if (old) {
      try { old.close?.(0, "reconnecting"); } catch {}
    }
    s.conn = await until(`${s.kind}: connected on the mesh`, async () => {
      let giveUp!: () => void;
      const givenUp = new Promise<void>((r) => (giveUp = r));
      const timer = setTimeout(() => giveUp(), 5_000);
      timer.unref?.();
      let conn: Connection | undefined;
      try {
        conn = await withTimeout(this.client.connect({ id: s.id, ips: [`127.0.0.1:${s.meshPort}`] }, Buffer.from("stillfail/admin/1"), undefined, givenUp), 5_000, `${s.kind}: connect`);
        const first = await withTimeout(conn.openBi(), 5_000, `${s.kind}: the hello's stream`);
        await withTimeout(line(first, { credential, protocol: 2 }), 5_000, `${s.kind}: the hello sent`);
        const hello = await withTimeout(new Reader(first).line(), 5_000, `${s.kind}: the hello's answer`);
        if (hello?.ok === true) return conn;
        try { conn.close?.(0, "refused"); } catch {}
        return null;
      } catch (e) {
        try { conn?.close?.(0, "failed"); } catch {}
        throw e;
      } finally {
        clearTimeout(timer);
        giveUp();
      }
    }, s.tail, 30_000, s.exited);
  }

}


/// A session made through the admin API, its key and thread.
type Made = { key: string; thread: number };

/// A message to the session: its agent's turn runs `do` (a script of the fake's), and the answers of its
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
  return answers;
}

/// Whether a session's turns are all over, the last with a state said (a nudge for one with none, or for a title,
/// is a turn of its own that has to end too).
/// How many turns a session has had.

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

/// An event stream of a member's on the mesh (GET /events): what it said so far, as it comes.
async function events(s: Station, since?: string) {
  const { stream, reader, head } = await withTimeout((async () => {
    const stream = await s.conn.openBi();
    await line(stream, { method: "GET", path: `/admin/api/events${since === undefined ? "" : `?since=${encodeURIComponent(since)}`}`, headers: {} });
    await stream.finish();
    const reader = new Reader(stream);
    const head = await reader.line();
    return { stream, reader, head };
  })(), 15_000, `${s.kind}: the event stream's head`);
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

test("a handover by the launcher: Node → MoonBit → MoonBit → Node, the session answers, its job runs on in its group, the event stream resumes", { skip, timeout: 240_000 }, async () => {
  const twins = new Twins();
  let at = "start";
  try {
    await twins.start(["node"]);
    const s = twins.stations[0]!;
    const made: Made = await (async () => {
      const said = await s.ask("POST", "/sessions", { runtime: "claude", profile: "cc" });
      assert.equal(said.status, 200, said.text);
      return { key: said.json.key, thread: said.json.thread?.id ?? said.json.thread?.thread?.id };
    })();
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
      const seenMesh = s.meshPorts().length;
      const lastId = stream.ids().at(-1)!;
      Twins.layOut(s.app, hop.to);
      s.child.kill("SIGUSR2");
      at = `${hop.name}: handover`;
      const next = await until(`${hop.name}: the next process took over`, () => s.takenOver()[seen], s.tail, 60_000, s.exited);
      await until(`${hop.name}: the process before gone`, () => !alive(before), s.tail, 30_000, s.exited);
      // (no front here: each process binds a mesh of its own, on a port of the system's)
      s.meshPort = await until(`${hop.name}: mesh listening`, () => s.meshPorts()[seenMesh], s.tail, 30_000, s.exited);
      const failed = s.said.split("\n").filter((l) => /memory is not carried over|carried over is not taken up/.test(l));
      assert.deepEqual(failed, [], `${hop.name}: every part's memory carried over and taken up: ${failed.join("\n")}`);
      const cmd = commandOf(next);
      assert.ok(hop.to === "node" ? cmd.includes("main.js") : cmd.includes("stillfail-reader") && !cmd.includes("main.js"), `${hop.name}: the process serving is the release's: ${cmd}`);
      await twins.connect(s);
      // the event stream taken up where it was: what came after the last id it heard, no `missed`
      at = `${hop.name}: events`;
      stream = await events(s, lastId);
      await until(`${hop.name}: the stream's first id`, () => stream.ids().length > 0, () => stream.text().slice(0, 400), 10_000);
      assert.ok(!stream.names().includes("missed"), `${hop.name}: nothing missed: ${stream.text().slice(0, 600)}`);
      // the session's next turn, under the next process
      at = `${hop.name}: turn`;
      const [said] = await turn(twins, [made], `chain-${i}`, [
        ["list", mcp(1, "job_list", {})],
        ["post", mcp(2, "chat_post", { to: "$TO", text: `hop ${i}`, kind: "all_done", done: `hop ${i} answered` })],
      ]);
      assert.match(JSON.stringify(said!.post), /all_done/, `${hop.name}: the session's next turn posted`);
      assert.match(JSON.stringify(said!.list), new RegExp(job.id), `${hop.name}: the job listed`);
      // the job still running, in the group it had, that group alive
      const j = jobRow();
      assert.equal(j.state, "running", `${hop.name}: ${JSON.stringify(j)}`);
      assert.equal(j.pgid, job.pgid, `${hop.name}: the job's group`);
      assert.ok(alive(job.pgid!), `${hop.name}: the job's group ${job.pgid} alive`);
      // (written each HELD_EVERY_MS from the serving process's loop: the one before's until the next one's first)
      await until(`${hop.name}: health.json of the process serving`, () => readJson(join(s.data, "run", "health.json"))?.pid === next, () => JSON.stringify(readJson(join(s.data, "run", "health.json"))), 30_000);
    }
    // every turn of the session kept, each ended with its state
    const db = s.db();
    try {
      const t = db.prepare("SELECT declared FROM turns WHERE session_key = ? AND ended_at IS NOT NULL ORDER BY started_at").all(made.key) as { declared: string | null }[];
      assert.ok(t.filter((x) => x.declared === "all_done").length >= 1 + hops.length, JSON.stringify(t));
    } finally {
      db.close();
    }
    // a stop: the launcher, its station and the job's runner end with it
    at = "stop";
    s.child.kill("SIGTERM");
    assert.equal(await s.ended, 0, s.tail());
  } catch (e) {
    const said = twins.stations.map((x) => `\n--- ${x.kind} ---\n${x.said.slice(-1500)}`).join("");
    throw new Error(`[at ${at}] ${(e as Error).message}${said}`, { cause: e });
  } finally {
    await twins.stop();
  }
});
