// The MoonBit station (`stillfail-reader run`, no Node on its PATH) through what the TypeScript's own copy and
// retirement tests hold (replica-stations, replica-export, replica-retire, sending-pack), two real stations over real
// loopback iroh each: a station's chats copied to the other as it keeps them (their rows and attached files, a copy a
// fresh station takes back as they were), the keeper stopped while chats change, a chat is made and one deleted, and
// once it is back the copy caught up by its coming back alone (the deleted chat and its file gone from it too); a
// station's retirement previewed as what it holds (its chats, accounts of its home workspace, connects), its start
// refused while retiring is switched off (replica/AGENTS.md, module.ts RETIRE_STARTS) with nothing written nor asked
// of the other, and the whole station moved instead (station_move `all`, what replaces it): refused while the station
// picked is down with nothing changed here, then every chat, transcript, room (nested, executable), account and
// connect on the station picked beside its own chat, the station left answering its old chats with where they went;
// and a hand-over's faults: a file changed, added and deleted while its first pass is sent is there as it was when the
// chat was held, and the station taking it killed mid-transfer leaves the chat working here, moved once that station
// is back. Under scripts/native.ts run (mesh runner archive-rs reader launcher).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { createSocket } from "node:dgram";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer as netServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { type WebSocket, WebSocketServer } from "ws";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { FakeFeishu } from "./feishu-fake.ts";

const binary = mbReaderBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const skip =
  binary === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : process.platform === "win32"
      ? "the launcher's descriptors are Unix's"
      : runner === "" || !existsSync(runner)
        ? "no stillfail-runner (run under scripts/native.ts run runner)"
        : !existsSync("/usr/bin/curl")
          ? "no /usr/bin/curl for the fake runtime"
          : false;

const dirs: string[] = [];
// (short: a runner's and the status's Unix sockets are at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfrr-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
after(async () => {
  for (const c of closers.splice(0).reverse()) {
    try {
      c();
    } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  // (what a run left: its agents' runners and their process groups, by what their files say)
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (!existsSync(runners)) continue;
    for (const f of readdirSync(runners).filter((n) => n.endsWith(".json"))) {
      try {
        const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
        if (typeof info.pgid === "number") try { process.kill(-info.pgid, "SIGKILL"); } catch {}
        if (typeof info.runner === "number") try { process.kill(info.runner, "SIGKILL"); } catch {}
      } catch {}
    }
  }
  if (process.env.STATION_KEEP !== "1") for (const d of dirs) rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

/// Looked at until `look` gives something (real processes: every 50 ms), or failing with `what` after `ms`.
async function given<T>(
  what: string,
  look: () => T | null | undefined | false | Promise<T | null | undefined | false>,
  detail: () => string | Promise<string> = () => "",
  ms = 20_000,
): Promise<T> {
  const end = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await look();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > end) throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}; ${await detail()}`);
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
const sha = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

const TOOLS = ["sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "wc", "uname", "lsof"];

/// A PATH of the tools a station runs, Node not among them, with a fake Claude Code whose every prompt posts
/// `<prefix>-<n>` and all_done to the thread it was asked in (n counts a session's prompts across its processes and
/// stations), keeping a transcript where Claude Code keeps one so the session can be taken up elsewhere.
function binOf(prefix: string): string {
  const dir = fresh("path");
  const search = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  for (const t of TOOLS) {
    const found = search.map((d) => join(d, t)).find((p) => existsSync(p));
    if (found !== undefined && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false, "no Node on PATH");
  const claude = `#!/bin/sh
mode=new; case " $* " in *" --resume "*) mode=resume ;; esac
sid=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift ;;
    --mcp-config) cfg="$2"; shift ;;
  esac
  shift
done
[ -n "$sid" ] && printf '%s %s %s\\n' "$FAKE_STATION" "$mode" "$sid" >> "$FAKE_OUT/started"
if [ -n "$CLAUDE_CONFIG_DIR" ]; then /bin/mkdir -p "$CLAUDE_CONFIG_DIR/projects/fake" && printf '{"sessionId":"%s"}\\n' "$sid" >> "$CLAUDE_CONFIG_DIR/projects/fake/$sid.jsonl"; fi
url=$(printf '%s' "$cfg" | /usr/bin/sed -n 's/.*"url":"\\([^"]*\\)".*/\\1/p')
say() { printf '%s\\n' "$1"; }
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  n=$(( $(/bin/cat "$FAKE_OUT/n-$sid" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$FAKE_OUT/n-$sid"
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-$sid"; else to=$(/bin/cat "$FAKE_OUT/to-$sid" 2>/dev/null); fi
  /usr/bin/curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \\
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"A chat","text":"${prefix}-'"$n"'","kind":"all_done","done":"replied turn '"$n"'"}}}' > "$FAKE_OUT/post-$sid-$n.json"
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"posted"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"posted"}'
done
`;
  writeFileSync(join(dir, "claude"), claude);
  chmodSync(join(dir, "claude"), 0o755);
  return dir;
}

/// A data directory (its key made by the program), its release `app`, config.json as given.
function stationDir(config: object): { data: string; app: string; id: string } {
  const data = fresh("data");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9400\n");
  const made = spawnSync(binary!, ["id", "--data", data], { env: { PATH: fresh("empty"), HOME: data, TMPDIR: tmpdir() }, encoding: "utf8" });
  assert.equal(made.status, 0, made.stderr);
  const id = made.stdout.trim();
  assert.match(id, /^[0-9a-f]{64}$/);
  writeFileSync(join(data, "config.json"), JSON.stringify(config));
  return { data, app, id };
}

const cloudJson = (data: string, o: { origin: string; id: string; name: string; peers: unknown[] }) => {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: o.origin, station: o.id, workspace: "w1", workspace_name: "团队", name: o.name, relay_url: "", relay_urls: [], grant_keys: null, peers: o.peers, revocations: [],
  }));
};

/// The control plane of the test's: its HTTP answered `{}`, its presence socket given each station its state.
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
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}` };
}

type Launched = { child: ChildProcess; door: number; stop: () => Promise<void>; kill: () => Promise<void>; err: () => string; alive: () => boolean };

/// `stillfail-reader run` under a launcher of the test's (its descriptors: the agents' door, the loopback port and its
/// channel), ready and its door open.
async function launch(data: string, app: string, env: Record<string, string>): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = netServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: {
      HOME: fresh("home"), TMPDIR: tmpdir(),
      STILLFAIL_RUNNER: runner, STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_AGENT_NICE: "0", STILLFAIL_HELD_EVERY_MS: "200",
      ...env,
    },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    try { said.push(JSON.parse(line)); } catch {}
  });
  let err = "";
  child.stdout!.on("data", (d) => (err += d));
  child.stderr!.on("data", (d) => (err += d));
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  const tail = () => err.slice(-3000);
  await given("the station ready", () => said.some((m) => m.ready === true), () => `said=${JSON.stringify(said)}; ${tail()}`);
  const door = (await given("the agents' door", () => said.find((m) => m.serving === "mcp"), tail)).port as number;
  const alive = () => child.exitCode === null && child.signalCode === null;
  const stop = async () => {
    if (!alive()) return;
    channel.write(`${JSON.stringify({ op: "stop" })}\n`);
    assert.equal(await ended, 0, tail());
  };
  const kill = async () => {
    if (!alive()) return;
    child.kill("SIGKILL");
    await ended;
  };
  return { child, door, stop, kill, err: tail, alive };
}

type Answer = { status: number; text: string; json: any };

function http(port: number, path: string, o: { method?: string; body?: unknown; raw?: Buffer } = {}): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = {};
    if (o.body !== undefined) headers["content-type"] = "application/json";
    if (o.raw !== undefined) headers["content-type"] = "application/octet-stream";
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined && o.raw === undefined ? "GET" : "POST"), headers, agent: false }, (res) => {
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
    req.end(o.raw ?? (o.body === undefined ? undefined : JSON.stringify(o.body)));
  });
}

/// Every file under `dir` (its links not followed): its path, mode and SHA-256.
function treeOf(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (at: string) => {
    for (const name of readdirSync(at)) {
      const full = join(at, name);
      const st = statSync(full);
      if (st.isDirectory()) walk(full);
      else out[relative(dir, full)] = `${(st.mode & 0o777).toString(8)} ${sha(readFileSync(full))}`;
    }
  };
  walk(dir);
  return out;
}

/// Every file under `dir` whose name is `name`.
function findNamed(dir: string, name: string): string[] {
  const out: string[] = [];
  const walk = (at: string) => {
    for (const n of readdirSync(at)) {
      const full = join(at, n);
      const st = statSync(full, { throwIfNoEntry: false });
      if (st === undefined) continue;
      if (st.isDirectory()) walk(full);
      else if (n === name) out.push(full);
    }
  };
  if (existsSync(dir)) walk(dir);
  return out;
}

/// A query of a station's database as it is now (a reader's own connection; the Store keeps rows in memory).
function rows<T>(data: string, sql: string, ...params: (string | number)[]): T[] {
  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  try {
    db.exec("PRAGMA busy_timeout = 5000;");
    return db.prepare(sql).all(...params) as T[];
  } finally {
    db.close();
  }
}

const handedTo = (data: string, key: string) => rows<{ station: string }>(data, "SELECT station FROM handed_over WHERE session = ?", key)[0] ?? null;

/// Two stations of workspace `w1` on loopback iroh (both on the test channel, where moving is offered), each with the
/// config given; the fakes of both writing their notes in one place.
async function pair(names: [string, string], configs: [object, object], env: [Record<string, string>, Record<string, string>] = [{}, {}]) {
  const [a, b] = [stationDir(configs[0]), stationDir(configs[1])];
  const ports = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: a.id, name: names[0], ips: [`127.0.0.1:${ports[0]}`] }, { id: b.id, name: names[1], ips: [`127.0.0.1:${ports[1]}`] }];
  const p = await plane((station) => ({ workspace: "w1", workspace_name: "团队", name: station === a.id ? names[0] : names[1], peers }));
  cloudJson(a.data, { origin: p.origin, id: a.id, name: names[0], peers });
  cloudJson(b.data, { origin: p.origin, id: b.id, name: names[1], peers });
  const out = fresh("out");
  const bins = [binOf(`${names[0]}-reply`), binOf(`${names[1]}-reply`)];
  const start = (i: 0 | 1) => launch(i === 0 ? a.data : b.data, i === 0 ? a.app : b.app, { PATH: bins[i]!, FAKE_OUT: out, FAKE_STATION: names[i]!, STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${ports[i]}`, ...env[i] });
  const first = await start(0);
  const second = await start(1);
  for (const d of [a.data, b.data]) await given("online at the plane", () => readJson(join(d, "run", "presence.json"))?.online === true, () => `${first.err()}\n${second.err()}`);
  const store = (data: string) => {
    const s = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
    closers.push(() => s.close());
    return s;
  };
  /// How each runtime process began, in order: its station, `new` or `resume`, its runtime session.
  const started = () => (existsSync(join(out, "started")) ? readFileSync(join(out, "started"), "utf8").trim().split("\n") : []);
  return { a, b, stations: [first, second] as [Launched, Launched], start, store, started };
}

/// The texts of the messages of a thread, as the station's admin API reads them.
async function texts(port: number, thread: number): Promise<string[]> {
  const r = await http(port, `/admin-api/threads/${thread}/entries`);
  assert.equal(r.status, 200, r.text);
  return (r.json.entries as any[]).filter((e) => e.kind === "message").map((e) => String(e.text));
}

/// A chat made on the station at `port` on account `profile`, its first message answered: its key and thread.
async function chat(port: number, store: Store, profile: string, text: string, detail: () => string): Promise<{ key: string; thread: number }> {
  const made = await http(port, "/admin-api/sessions", { body: { runtime: "claude", profile } });
  assert.equal(made.status, 200, made.text);
  const key: string = made.json.key;
  const thread: number = made.json.thread?.id ?? made.json.thread?.thread?.id;
  const sent = await http(port, `/admin-api/threads/${thread}/messages`, { body: { text } });
  assert.ok(sent.status < 300, sent.text);
  await given(`${key}'s first turn ended`, () => store.listTurns(key).some((t) => t.summary.endedAt != null), detail);
  return { key, thread };
}

/// A file sent in a chat as the app sends one: uploaded, then named in a message. Its bytes' SHA-256.
async function attach(port: number, thread: number, name: string, bytes: Buffer, text: string): Promise<string> {
  const up = await http(port, `/admin-api/uploads?name=${encodeURIComponent(name)}`, { raw: bytes });
  assert.equal(up.status, 200, up.text);
  const sent = await http(port, `/admin-api/threads/${thread}/messages`, { body: { text, attachments: [{ path: up.json.path, name }] } });
  assert.ok(sent.status < 300, sent.text);
  return sha(bytes);
}

// ── 1. a station's copies: kept by the other, caught up after it was away, a deleted chat gone from them ──

/// The newest generation of `origin`'s copy kept at `data` (`replicas/w1/<origin>/<gen>/head.json`), or of the
/// station's own (`replica/own/w1/<gen>`).
function newestHead(dir: string): { gen: string; dir: string; head: any } | null {
  if (!existsSync(dir)) return null;
  let best: { gen: string; dir: string; head: any } | null = null;
  for (const gen of readdirSync(dir)) {
    const head = readJson(join(dir, gen, "head.json"));
    if (head === null || typeof head.gen !== "string") continue;
    if (best === null || (head.made ?? 0) > (best.head.made ?? 0) || ((head.made ?? 0) === (best.head.made ?? 0) && head.to > best.head.to)) best = { gen, dir: join(dir, gen), head };
  }
  return best;
}

/// What a fresh station takes back of `origin`'s copy kept at `keeper` (`--builder replica-restore`, as a new station
/// restores a lost one before its store opens): its database's sessions and their messages, and the attached files
/// where its messages say.
function restoreFrom(keeper: string, origin: string, name: string, from: string, bin: string) {
  const kept = join(keeper, "replicas", "w1", origin);
  const newest = newestHead(kept);
  assert.ok(newest !== null, `no copy of ${origin} kept at ${keeper}`);
  const to = fresh("restore");
  const copy = join(to, "restore", "copy");
  mkdirSync(join(copy, newest.gen), { recursive: true });
  writeFileSync(join(copy, newest.gen, "head.json"), readFileSync(join(newest.dir, "head.json")));
  if (existsSync(join(newest.dir, "log"))) cpSync(join(newest.dir, "log"), join(copy, newest.gen, "log"), { recursive: true });
  mkdirSync(join(copy, "files"), { recursive: true });
  if (existsSync(join(kept, "files"))) cpSync(join(kept, "files"), join(copy, "files"), { recursive: true });
  writeFileSync(join(to, "restore", "ready.json"), JSON.stringify({ origin, workspace: "w1", gen: newest.gen, name, from }));
  Store.open(join(to, "stillfail.db"), join(to, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never).close();
  const r = spawnSync(binary!, ["--builder", "replica-restore", "--db", join(to, "stillfail.db"), "--data", to, "--now", "1000", "--sep", "/"], { encoding: "utf8", env: { PATH: bin, HOME: to, TMPDIR: tmpdir() } });
  assert.equal(r.status, 0, r.stderr);
  const said = JSON.parse(r.stdout.trim().split("\n").at(-1)!);
  assert.equal(said.error, undefined, JSON.stringify(said));
  assert.equal(said.ready?.origin, origin, JSON.stringify(said));
  const sessions = rows<{ key: string }>(to, "SELECT key FROM sessions ORDER BY key").map((x) => x.key);
  const said_ = (key: string) => rows<{ text: string }>(to, "SELECT e.text AS text FROM entries e JOIN thread_sessions t ON t.thread = e.thread WHERE t.session = ? AND e.kind = 'message' ORDER BY e.n", key).map((x) => x.text);
  const files = rows<{ attachments: string }>(to, "SELECT attachments FROM entries WHERE attachments IS NOT NULL AND attachments != '[]'")
    .flatMap((x) => JSON.parse(x.attachments) as { path: string; name: string }[])
    .map((f) => ({ name: f.name, path: f.path, sha: existsSync(f.path) ? sha(readFileSync(f.path)) : null }));
  return { to, gen: newest.gen, head: newest.head, sessions, said: said_, files };
}

test("a station's chats copied to the other as it keeps them, their files with them; the keeper away while a chat is said to, one made and one deleted; back, its copy caught up by its coming back alone, the deleted chat and its file gone from it", { skip, timeout: 240_000 }, async () => {
  const profiles = [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc", access: { kind: "anthropic-api", key: "sk-ant-copies-test" }, models: ["claude-opus-5-5"] }];
  const config = { language: "en", updateChannel: "beta", profiles, maxNudges: 0 };
  const { a, b, stations, start, store } = await pair(["alpha", "beta"], [config, config]);
  let [alpha, beta] = stations;
  const both = () => `alpha: ${alpha.err()}\nbeta: ${beta.err()}`;
  const storeA = store(a.data);
  const kept = join(b.data, "replicas", "w1", a.id);
  const own = join(a.data, "replica", "own", "w1");
  const bin = binOf("restore");

  // three chats on alpha, two with a file sent in them
  const one = await chat(alpha.door, storeA, "cc", "the first chat, on alpha", both);
  const two = await chat(alpha.door, storeA, "cc", "the second chat, on alpha", both);
  const gone = await chat(alpha.door, storeA, "cc", "the chat to be deleted", both);
  const oneFile = randomBytes(40_000);
  const goneFile = Buffer.from("the deleted chat's file, nothing else has these bytes\n");
  const oneSha = await attach(alpha.door, one.thread, "plan.bin", oneFile, "the first chat's file");
  const goneSha = await attach(alpha.door, gone.thread, "gone.txt", goneFile, "the deleted chat's file");

  // (each message sent with a file is a turn of its chat: both answered, every chat idle, before what alpha says is read)
  const ended = (key: string) => storeA.listTurns(key).filter((t) => t.summary.endedAt != null).length;
  await given("the turns on the files sent ended", () => ended(one.key) >= 2 && ended(gone.key) >= 2, both);
  const wantBefore = new Map<string, string[]>();
  for (const c of [one, two, gone]) wantBefore.set(c.key, await texts(alpha.door, c.thread));

  // ── kept on beta: a head naming the three chats and both files, what a fresh station takes back of it the chats as
  // they are on alpha (each head taken back once) ──
  const tried = new Map<string, ReturnType<typeof restoreFrom>>();
  const first = await given("alpha's copy kept on beta with its three chats as they are, and both files", () => {
    const h = newestHead(kept);
    if (h === null || h.head.chats !== 3 || !(oneSha in h.head.files) || !(goneSha in h.head.files) || !existsSync(join(kept, "files", oneSha)) || !existsSync(join(kept, "files", goneSha))) return null;
    const at = `${h.gen}:${h.head.to}`;
    if (!tried.has(at)) tried.set(at, restoreFrom(b.data, a.id, "alpha", b.id, bin));
    const r = tried.get(at)!;
    return [one, two, gone].every((c) => JSON.stringify(r.said(c.key)) === JSON.stringify(wantBefore.get(c.key))) ? { ...h, restored: r } : null;
  }, () => `kept=${JSON.stringify(newestHead(kept)?.head)}; ${both()}`, 60_000);
  assert.deepEqual(readFileSync(join(kept, "files", oneSha)), oneFile);
  assert.deepEqual(readFileSync(join(kept, "files", goneSha)), goneFile);
  // what a fresh station takes back of it is the chats as they were on alpha, their files where their messages say
  const before = first.restored;
  assert.deepEqual(before.sessions, [one.key, two.key, gone.key].sort());
  for (const c of [one, two, gone]) assert.deepEqual(before.said(c.key), await texts(alpha.door, c.thread), c.key);
  assert.deepEqual(before.files.map((f) => [f.name, f.sha]).sort(), [["gone.txt", goneSha], ["plan.bin", oneSha]]);
  for (const f of before.files) assert.ok(f.path.startsWith(before.to), `${f.path} under the restored station`);

  // ── beta away: alpha's chats change meanwhile (said to, one made, one deleted with its file), its own copy goes on ──
  await beta.stop();
  const keptAtStop = newestHead(kept)!;
  const ownBefore = newestHead(own)!;
  const turnsBefore = ended(one.key);
  const sent = await http(alpha.door, `/admin-api/threads/${one.thread}/messages`, { body: { text: "said while beta was away" } });
  assert.ok(sent.status < 300, sent.text);
  await given("the first chat's turn on it ended", () => ended(one.key) >= turnsBefore + 1, both);
  const three = await chat(alpha.door, storeA, "cc", "a chat made while beta was away", both);
  const deleted = await http(alpha.door, `/admin-api/sessions/${encodeURIComponent(gone.key)}`, { method: "DELETE" });
  assert.ok(deleted.status < 300, deleted.text);
  await given("the chat deleted on alpha", () => rows(a.data, "SELECT key FROM sessions WHERE key = ?", gone.key).length === 0, both);
  const ownAfter = await given("alpha's own copy past what beta holds: three chats, the deleted one's file not in it", () => {
    const h = newestHead(own);
    return h !== null && h.head.chats === 3 && !(goneSha in h.head.files) && oneSha in h.head.files && (h.gen !== ownBefore.gen || h.head.to > ownBefore.head.to) ? h : null;
  }, () => `own=${JSON.stringify(newestHead(own)?.head)}; ${alpha.err()}`, 60_000);
  // nothing reached beta while it was away: its copy as it was
  assert.deepEqual(newestHead(kept)!.head, keptAtStop.head);
  assert.ok(existsSync(join(kept, "files", goneSha)));

  // ── beta back: told by nobody but its coming back, its copy level with alpha's own, the deleted file gone ──
  beta = await start(1);
  const caught = await given("beta's copy caught up with alpha's own", () => {
    const h = newestHead(kept);
    return h !== null && h.gen === ownAfter.gen && h.head.to >= ownAfter.head.to && !existsSync(join(kept, "files", goneSha)) ? h : null;
  }, () => `kept=${JSON.stringify(newestHead(kept)?.head)}; own=${JSON.stringify(newestHead(own)?.head)}; files=${JSON.stringify(existsSync(join(kept, "files")) ? readdirSync(join(kept, "files")) : [])}; ${both()}`, 60_000);
  assert.equal(caught.head.chats, 3);
  assert.deepEqual(Object.keys(caught.head.files), [oneSha]);
  assert.deepEqual(readFileSync(join(kept, "files", oneSha)), oneFile);
  const now = restoreFrom(b.data, a.id, "alpha", b.id, bin);
  assert.deepEqual(now.sessions, [one.key, two.key, three.key].sort(), "the deleted chat not in what is taken back, the one made is");
  for (const c of [one, two, three]) assert.deepEqual(now.said(c.key), await texts(alpha.door, c.thread), c.key);
  assert.ok(now.said(one.key).includes("said while beta was away"), JSON.stringify(now.said(one.key)));
  assert.deepEqual(now.files.map((f) => [f.name, f.sha]), [["plan.bin", oneSha]], "the deleted chat's file not in it");
  assert.equal(rows(now.to, "SELECT key FROM sessions WHERE key = ?", gone.key).length, 0);
  await Promise.all([alpha.stop(), beta.stop()]);
});

// ── 2. a station's retirement previewed and refused; the whole station moved instead ──

/// The move page of `port` toward `to`.
const movePage = async (port: number, to: string) => (await http(port, `/admin-api/move?to=${to}`)).json;
const itemOf = (page: any, module: string, id: string) => page?.modules?.find((m: any) => m.id === module)?.items?.find((x: any) => x.id === id);

test("a station's retirement previewed as what it holds, its start refused while retiring is switched off, nothing written nor asked of the other; moved whole instead: refused while the station picked is down, nothing changed; then its chats, transcripts, rooms, account and connect on the station picked beside its own chat, the station left answering its old chats with where they went", { skip, timeout: 300_000 }, async () => {
  const feishu = await FakeFeishu.start();
  closers.push(() => void feishu.close());
  const leavingProfiles = [{ id: "lk", name: "Leaving key", runtime: "claude", home: "homes/lk", access: { kind: "anthropic-api", key: "sk-ant-leaving-only" }, models: ["claude-opus-5-5"] }];
  const takerProfiles = [{ id: "tk", name: "Taker key", runtime: "claude", home: "homes/tk", access: { kind: "anthropic-api", key: "sk-ant-taker-only" }, models: ["claude-opus-5-5"] }];
  const connects = [{ id: "f1", kind: "feishu", enabled: true, name: "Leaving bot", bind: { runtime: "claude" }, feishu: { appId: "cli_leaving", appSecret: "sec-leaving", domain: "feishu" } }];
  const { a, b, stations, start, store, started } = await pair(
    ["leaving", "taker"],
    [{ language: "en", updateChannel: "beta", profiles: leavingProfiles, connects, maxNudges: 0 }, { language: "en", updateChannel: "beta", profiles: takerProfiles, maxNudges: 0 }],
    [{ STILLFAIL_FEISHU_API: feishu.base }, { STILLFAIL_FEISHU_API: feishu.base }],
  );
  let [leaving, taker] = stations;
  const both = () => `leaving: ${leaving.err()}\ntaker: ${taker.err()}`;
  const storeL = store(a.data);
  const storeT = store(b.data);

  // two chats on the station leaving, a room with nested and executable files; the taker's own chat
  const l1 = await chat(leaving.door, storeL, "lk", "the first chat, on the station leaving", both);
  const l2 = await chat(leaving.door, storeL, "lk", "the second chat, on the station leaving", both);
  const ws1 = storeL.getSession(l1.key)!.workspace;
  writeFileSync(join(ws1, "notes.md"), "# notes\nwritten on the station leaving\n");
  mkdirSync(join(ws1, "deep", "er"), { recursive: true });
  writeFileSync(join(ws1, "deep", "er", "blob.bin"), randomBytes(200_000));
  writeFileSync(join(ws1, "run.sh"), "#!/bin/sh\necho moved\n");
  chmodSync(join(ws1, "run.sh"), 0o755);
  const room1 = treeOf(ws1);
  // (a new session is written no instructions file: give the second room a file of its own to carry)
  writeFileSync(join(storeL.getSession(l2.key)!.workspace, "plan.md"), "# plan\n");
  const room2 = treeOf(storeL.getSession(l2.key)!.workspace);
  const t1 = await chat(taker.door, storeT, "tk", "the taker's own chat", both);
  const takerOwn = await texts(taker.door, t1.thread);
  const said1 = await texts(leaving.door, l1.thread);
  const said2 = await texts(leaving.door, l2.thread);
  // (each chat's runtime session, from the fake's notes: the transcripts that go along are named by it)
  const sidOf = (n: number) => started()[n]!.split(" ")[2]!;
  const [sid1, sid2] = [sidOf(0), sidOf(1)];
  await given("f1 connected", async () => (await http(leaving.door, "/admin-api/overview")).json?.connects?.find((c: any) => c.id === "f1")?.connection?.state === "connected", both);

  // ── the preview: this station's chats of its home workspace, its own account and its connect ──
  const preview = await http(leaving.door, "/admin-api/retire/preview");
  assert.equal(preview.status, 200, preview.text);
  const shown = preview.json;
  assert.equal(shown.home, true, preview.text);
  assert.equal(shown.chats + shown.archived, 2, preview.text);
  assert.equal(shown.archived, 0, preview.text);
  assert.deepEqual(shown.accounts.map((x: any) => [x.id, x.name]), [["lk", "Leaving key"]]);
  assert.deepEqual(shown.accountsStay, []);
  assert.deepEqual(shown.connects.map((c: any) => c.id), ["f1"]);
  assert.deepEqual(shown.jobs, []);

  // ── its start refused while retiring is switched off: said in words, nothing written, the other asked nothing ──
  const retire = await http(leaving.door, "/admin-api/retire", { body: { to: b.id } });
  assert.equal(retire.status, 409, retire.text);
  assert.match(String(retire.json?.error), /switched off for now|暂时关闭/);
  assert.equal(existsSync(join(a.data, "replica", "retiring.json")), false, "nothing written");
  const overviewOf = async (port: number) => (await http(port, "/admin-api/overview")).json;
  assert.equal((await overviewOf(leaving.door)).copies?.retiring ?? null, null, JSON.stringify((await overviewOf(leaving.door)).copies));
  assert.deepEqual((await overviewOf(taker.door)).copies?.taking ?? [], [], "the station picked told nothing");
  assert.equal(handedTo(a.data, l1.key), null);

  // ── moved whole to the station picked while it is down: refused in words naming it, nothing held or changed here ──
  await given("the chats movable to the taker", async () => itemOf(await movePage(leaving.door, b.id), "chats", l1.key)?.state === "here", async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 30_000);
  const wsBefore = rows<{ key: string; ws: string | null }>(a.data, "SELECT key, ws FROM sessions ORDER BY key");
  await taker.stop();
  const down = await http(leaving.door, "/admin-api/move", { body: { to: b.id, all: true } });
  if (down.status === 202) {
    // (taken, then failed in the turn: said on the page, nothing gone)
    await given("the whole move toward the station down ended", async () => (await movePage(leaving.door, b.id))?.moving === null, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 90_000);
  } else {
    assert.equal(down.status, 409, down.text);
    assert.match(String(down.json?.error), /taker/, down.text);
  }
  for (const k of [l1.key, l2.key]) assert.equal(handedTo(a.data, k), null, k);
  assert.deepEqual(treeOf(ws1), room1);
  assert.deepEqual(await texts(leaving.door, l1.thread), said1);
  assert.deepEqual(rows<{ key: string; ws: string | null }>(a.data, "SELECT key, ws FROM sessions ORDER BY key"), wsBefore, "nothing held as handed or coming");
  assert.deepEqual(readJson(join(a.data, "config.json")).profiles.map((p: any) => p.id), ["lk"], "its account still here");
  assert.deepEqual(readJson(join(a.data, "config.json")).connects.map((c: any) => c.id), ["f1"], "its connect still here");

  // ── the station picked back: moved whole, every chat there ──
  taker = await start(1);
  await given("the chats movable to the taker again", async () => {
    const page = await movePage(leaving.door, b.id);
    return page?.moving === null && [l1.key, l2.key].every((k) => itemOf(page, "chats", k)?.state === "here" && itemOf(page, "chats", k)?.cannot === undefined);
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 45_000);
  const moved = await http(leaving.door, "/admin-api/move", { body: { to: b.id, all: true } });
  assert.equal(moved.status, 202, moved.text);
  const done = await given("everything there", async () => {
    const page = await movePage(leaving.door, b.id);
    return page?.moving === null && [l1.key, l2.key].every((k) => itemOf(page, "chats", k)?.state === "there") ? page : null;
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 120_000);
  assert.equal(itemOf(done, "connects", `f1@${a.id}`)?.state, "there", JSON.stringify(done));
  const account = done.modules.find((m: any) => m.id === "accounts")?.items ?? [];
  assert.deepEqual(account.map((x: any) => [x.label, x.state]), [["Leaving key", "there"]], JSON.stringify(account));

  // the chats there beside its own, their messages and rooms as they were (nested, executable)
  for (const k of [l1.key, l2.key]) assert.equal(handedTo(a.data, k)?.station, b.id, k);
  const there1 = await given("the first chat on the taker", () => storeT.getSession(l1.key), both);
  const there2 = await given("the second chat on the taker", () => storeT.getSession(l2.key), both);
  assert.deepEqual(treeOf(there1.workspace), room1);
  assert.deepEqual(treeOf(there2.workspace), room2);
  assert.equal(statSync(join(there1.workspace, "run.sh")).mode & 0o777, 0o755);
  const thread1 = storeT.sessionThreads(l1.key)[0]!.thread.id;
  const thread2 = storeT.sessionThreads(l2.key)[0]!.thread.id;
  assert.deepEqual(await texts(taker.door, thread1), said1);
  assert.deepEqual(await texts(taker.door, thread2), said2);
  assert.deepEqual(await texts(taker.door, t1.thread), takerOwn, "the taker's own chat as it was");
  assert.notEqual(thread1, t1.thread);
  // their transcripts under the taker's data directory
  for (const sid of [sid1, sid2]) assert.ok(findNamed(b.data, `${sid}.jsonl`).length >= 1, `${sid}'s transcript on the taker`);

  // the account (its host) and the connect on the taker, the station left keeping only a borrowed copy of the account
  // and no connect: of its home workspace, they move (move/AGENTS.md accounts: a whole move moves a login's host)
  const cfgT = readJson(join(b.data, "config.json"));
  const cfgL = readJson(join(a.data, "config.json"));
  const hosted = (cfgT.profiles as any[]).filter((p) => p.access?.key === "sk-ant-leaving-only");
  assert.equal(hosted.length, 1, JSON.stringify(cfgT.profiles));
  assert.equal(hosted[0].share?.borrowed, undefined, "hosted on the taker now");
  assert.ok((cfgT.profiles as any[]).some((p) => p.id === "tk" && p.access?.key === "sk-ant-taker-only"), "the taker's own account stays");
  assert.deepEqual((cfgL.profiles as any[]).map((p) => [p.id, p.share?.borrowed, p.share?.host]), [["lk", true, b.id]], "borrowed from the taker on the station left");
  assert.deepEqual((cfgT.connects as any[]).map((c) => [c.id, c.kind, c.feishu?.appId, c.enabled]), [[`f1@${a.id}`, "feishu", "cli_leaving", true]]);
  assert.deepEqual(cfgL.connects ?? [], [], "the connect gone from the station left");

  // ── the station left answers its old chats with where they went, runs nothing for them ──
  const turnsHere = storeL.listTurns(l1.key).length;
  const stale = await http(leaving.door, `/admin-api/threads/${l1.thread}/messages`, { body: { text: "to the station left" } });
  assert.equal(stale.status, 409, stale.text);
  assert.deepEqual([stale.json.moved?.session, stale.json.moved?.station, stale.json.moved?.there], [l1.key, b.id, thread1], stale.text);
  const goneTo = await http(leaving.door, `/admin-api/moved?session=${encodeURIComponent(l1.key)}`);
  assert.equal(goneTo.status, 200, goneTo.text);
  assert.deepEqual(goneTo.json.moved.map((m: any) => [m.session, m.station, m.there]).sort(), [[l1.key, b.id, thread1], [l2.key, b.id, thread2]].sort());
  // ── and the chat goes on on the taker, its runtime session taken up there ──
  const onTaker = await http(taker.door, `/admin-api/threads/${thread1}/messages`, { body: { text: "said on the taker" } });
  assert.ok(onTaker.status < 300, onTaker.text);
  await given("the taker's turn on the moved chat", async () => (await texts(taker.door, thread1)).includes("taker-reply-2"), async () => `${JSON.stringify(await texts(taker.door, thread1))}; ${both()}`, 30_000);
  assert.ok(started().includes(`taker resume ${sid1}`), JSON.stringify(started()));
  assert.equal(storeL.listTurns(l1.key).length, turnsHere, "nothing ran on the station left");
  await Promise.all([leaving.stop(), taker.stop()]);
});

// ── 3. a hand-over's faults: files changing as they are sent, the station taking them killed ──

/// The step of the newest hand-over out of `data` of `key` (`replica/handover/out/<id>.json`).
function outStep(data: string, key: string): string | null {
  const dir = join(data, "replica", "handover", "out");
  if (!existsSync(dir)) return null;
  let best: any = null;
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".json"))) {
    const o = readJson(join(dir, f));
    if (o === null || (o.key !== key && o.session !== key && !(Array.isArray(o.keys) && o.keys.includes(key)))) continue;
    if (best === null || (o.at ?? 0) >= (best.at ?? 0)) best = o;
  }
  return best?.step ?? null;
}

test("a chat's files changed, added and deleted while its first pass is sent: there as they were when it was held; the station taking it killed mid-transfer: the chat goes on here with its files, and moves once that station is back", { skip, timeout: 300_000 }, async () => {
  const profiles = [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc", access: { kind: "anthropic-api", key: "sk-ant-faults-test" }, models: ["claude-opus-5-5"] }];
  const config = { language: "en", updateChannel: "beta", profiles, maxNudges: 0 };
  const { a, b, stations, start, store } = await pair(["leaving", "taker"], [config, config]);
  let [leaving, taker] = stations;
  const both = () => `leaving: ${leaving.err()}\ntaker: ${taker.err()}`;
  const storeL = store(a.data);
  const storeT = store(b.data);
  // (a big file, so the first pass is under way long enough to change the room under it, yet sent within CI's slice)
  const big = () => randomBytes(48 * 1024 * 1024);

  // ── changed as it is sent ──
  const c1 = await chat(leaving.door, storeL, "cc", "the chat whose files change", both);
  const ws1 = storeL.getSession(c1.key)!.workspace;
  writeFileSync(join(ws1, "big.bin"), big());
  writeFileSync(join(ws1, "notes.md"), "before the move\n");
  writeFileSync(join(ws1, "doomed.txt"), "deleted as it is sent\n");
  await given("the chat movable", async () => itemOf(await movePage(leaving.door, b.id), "chats", c1.key)?.state === "here", async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 30_000);
  assert.equal((await http(leaving.door, "/admin-api/move", { body: { to: b.id, module: "chats", item: c1.key, withNeeds: true } })).status, 202);
  await given("its first pass under way", () => outStep(a.data, c1.key) === "files", () => `step=${outStep(a.data, c1.key)}; ${both()}`, 30_000);
  writeFileSync(join(ws1, "notes.md"), "changed while it was sent, longer than before\n");
  unlinkSync(join(ws1, "doomed.txt"));
  writeFileSync(join(ws1, "added.txt"), "added while it was sent\n");
  const stepAfter = outStep(a.data, c1.key);
  assert.ok(stepAfter === "files" || stepAfter === "held", `the changes made before the chat was held (now ${stepAfter})`);
  const expected = treeOf(ws1);
  await given("the chat there", async () => {
    const page = await movePage(leaving.door, b.id);
    return page?.moving === null && itemOf(page, "chats", c1.key)?.state === "there";
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; step=${outStep(a.data, c1.key)}; ${both()}`, 120_000);
  const there1 = await given("the chat on the taker", () => storeT.getSession(c1.key), both);
  const got = treeOf(there1.workspace);
  assert.deepEqual(got, expected, "the room as it was when held: changed, added, deleted");
  assert.equal(readFileSync(join(there1.workspace, "notes.md"), "utf8"), "changed while it was sent, longer than before\n");
  assert.equal(existsSync(join(there1.workspace, "doomed.txt")), false);

  // ── the station taking it killed mid-transfer ──
  const c2 = await chat(leaving.door, storeL, "cc", "the chat whose taker is killed", both);
  const ws2 = storeL.getSession(c2.key)!.workspace;
  writeFileSync(join(ws2, "big.bin"), big());
  writeFileSync(join(ws2, "notes.md"), "kept whatever happens\n");
  const room2 = treeOf(ws2);
  const said2 = await texts(leaving.door, c2.thread);
  await given("the second chat movable", async () => itemOf(await movePage(leaving.door, b.id), "chats", c2.key)?.state === "here", async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 30_000);
  // (the turn's end read from what the station keeps of it, move/turn.json and move/last.json: a move page asked while
  // the station picked is down plans afresh, out of any turn, and waits out each of its questions of it)
  const lastOf = () => readJson(join(a.data, "move", "last.json"))?.w1 ?? null;
  const lastBefore = lastOf()?.at ?? 0;
  assert.equal((await http(leaving.door, "/admin-api/move", { body: { to: b.id, module: "chats", item: c2.key, withNeeds: true } })).status, 202);
  await given("its first pass under way", () => outStep(a.data, c2.key) === "files", () => `step=${outStep(a.data, c2.key)}; ${both()}`, 30_000);
  await taker.kill();
  const ended = await given("the move toward the killed station ended", () => {
    const last = lastOf();
    return !existsSync(join(a.data, "move", "turn.json")) && last !== null && last.at > lastBefore ? last : null;
  }, () => `last=${JSON.stringify(lastOf())}; step=${outStep(a.data, c2.key)}; ${both()}`, 90_000);
  // the chat here as it was: not handed, its files and messages
  assert.deepEqual(ended.failed?.item, { module: "chats", id: c2.key }, JSON.stringify(ended));
  assert.match(String(ended.failed?.error), /^The chat did not go to taker and goes on here: /, JSON.stringify(ended));
  assert.deepEqual(ended.done, [], JSON.stringify(ended));
  assert.equal(handedTo(a.data, c2.key), null);
  assert.deepEqual(treeOf(ws2), room2);
  assert.deepEqual(await texts(leaving.door, c2.thread), said2);
  // and it goes on here
  const turns = storeL.listTurns(c2.key).filter((t) => t.summary.endedAt != null).length;
  assert.ok((await http(leaving.door, `/admin-api/threads/${c2.thread}/messages`, { body: { text: "still here after the failed move" } })).status < 300);
  await given("the chat answered here after the failed move", () => storeL.listTurns(c2.key).filter((t) => t.summary.endedAt != null).length > turns, both, 30_000);

  // ── the station back: moved, its files byte for byte ──
  taker = await start(1);
  const room2now = treeOf(ws2);
  const failed = await given("the second chat movable again", async () => {
    const page = await movePage(leaving.door, b.id);
    const i = itemOf(page, "chats", c2.key);
    return page?.moving === null && i?.state === "failed" && i?.cannot === undefined ? i : null;
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 60_000);
  // said why the move did not go and what to do, in the words of the request the kill cut: its files' sending, the ask
  // that followed them, or (the station found gone in the turn) any later one
  assert.match(String(failed.error), /^(?:the other station did not answer(?: while its files were being sent)?: (?:move it|try) again once it answers|taker does not answer: nothing more is asked of it in this move\. Move again once it is up\.)$/, JSON.stringify(failed));
  assert.equal((await http(leaving.door, "/admin-api/move", { body: { to: b.id, module: "chats", item: c2.key, withNeeds: true } })).status, 202);
  await given("the second chat there", async () => {
    const page = await movePage(leaving.door, b.id);
    return page?.moving === null && itemOf(page, "chats", c2.key)?.state === "there";
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 120_000);
  const there2 = await given("the second chat on the taker", () => storeT.getSession(c2.key), both);
  assert.deepEqual(treeOf(there2.workspace), room2now);
  const thread2 = storeT.sessionThreads(c2.key)[0]!.thread.id;
  const saidThere = await texts(taker.door, thread2);
  for (const t of [...said2, "still here after the failed move"]) assert.equal(saidThere.filter((x) => x === t).length, 1, `${t} once: ${JSON.stringify(saidThere)}`);
  await Promise.all([leaving.stop(), taker.stop()]);
});
