// The harness of mb-fault-replica-retire*.test.ts: two MoonBit stations (`stillfail-reader run`, no Node on their PATH)
// over real loopback iroh under a launcher of the test's, a control plane of the test's, a fake Claude Code, and the
// reads the three files hold them by. Each file is its own process: it calls setupRetireHarness() for its cleanup.
// Under scripts/native.ts run (mesh runner archive-rs reader launcher).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer as netServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after } from "node:test";
import { type WebSocket, WebSocketServer } from "ws";
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";

export const binary = mbStationBinary();
export const runner = process.env.STILLFAIL_RUNNER ?? "";
export const skip =
  binary === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : process.platform === "win32"
      ? "the launcher's descriptors are Unix's"
      : runner === "" || !existsSync(runner)
        ? "no stillfail-runner (run under scripts/native.ts run runner)"
        : !existsSync("/usr/bin/curl")
          ? "no /usr/bin/curl for the fake runtime"
          : false;

export const dirs: string[] = [];
// (short: a runner's and the status's Unix sockets are at most 104 bytes on macOS)
export const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfrr-${what}-`));
  dirs.push(dir);
  return dir;
};
export const children: ChildProcess[] = [];
export const closers: (() => void)[] = [];
let registered = false;
/// Registers the cleanup of this file's process once: closers run, children killed, their runners' process groups
/// ended, the directories `fresh` made removed. Each test file calls it at its top.
export function setupRetireHarness(): void {
  if (registered) return;
  registered = true;
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
}

/// Looked at until `look` gives something (real processes: every 50 ms), or failing with `what` after `ms`.
export async function given<T>(
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

export const readJson = (p: string) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};
export const sha = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");

export const TOOLS = ["sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "wc", "uname", "lsof"];

/// A PATH of the tools a station runs, Node not among them, with a fake Claude Code whose every prompt posts
/// `<prefix>-<n>` and all_done to the thread it was asked in (n counts a session's prompts across its processes and
/// stations), keeping a transcript where Claude Code keeps one so the session can be taken up elsewhere.
export function binOf(prefix: string): string {
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
export function stationDir(config: object): { data: string; app: string; id: string } {
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

export const cloudJson = (data: string, o: { origin: string; id: string; name: string; peers: unknown[] }) => {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: o.origin, station: o.id, workspace: "w1", workspace_name: "团队", name: o.name, relay_url: "", relay_urls: [], grant_keys: null, peers: o.peers, revocations: [],
  }));
};

/// The control plane of the test's: its HTTP answered `{}`, its presence socket given each station its state.
export async function plane(stateOf: (station: string) => object) {
  const sockets = new Map<WebSocket, string>();
  const sendState = (ws: WebSocket, station: string) => {
    if (ws.readyState === 1) ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...stateOf(station) }));
  };
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => res.writeHead(200, { "content-type": "application/json" }).end("{}"));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    const station = String(req.headers["x-stillfail-station"] ?? "");
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.set(ws, station);
      ws.on("close", () => sockets.delete(ws));
      ws.on("error", () => sockets.delete(ws));
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      sendState(ws, station);
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets.keys()) s.terminate();
    sockets.clear();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  const push = () => {
    for (const [ws, station] of sockets) sendState(ws, station);
  };
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, push };
}

export type Launched = {
  child: ChildProcess;
  door: number;
  stop: () => Promise<void>;
  kill: () => Promise<void>;
  err: () => string;
  alive: () => boolean;
  meshPort: () => number | null;
};

/// `stillfail-reader run` under a launcher of the test's (its descriptors: the agents' door, the loopback port and its
/// channel), ready and its door open.
export async function launch(data: string, app: string, env: Record<string, string>): Promise<Launched> {
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
  const meshPort = () => {
    let port: number | null = null;
    for (const m of err.matchAll(/mesh listening\b[^\n]*?\bsockets=[^\n]*?"127\.0\.0\.1:(\d+)"/g)) {
      port = Number(m[1]);
    }
    return port;
  };
  return { child, door, stop, kill, err: tail, alive, meshPort };
}

export type Answer = { status: number; text: string; json: any };

export function http(port: number, path: string, o: { method?: string; body?: unknown; raw?: Buffer } = {}): Promise<Answer> {
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
export function treeOf(dir: string): Record<string, string> {
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
export function findNamed(dir: string, name: string): string[] {
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
export function rows<T>(data: string, sql: string, ...params: (string | number)[]): T[] {
  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  try {
    db.exec("PRAGMA busy_timeout = 5000;");
    return db.prepare(sql).all(...params) as T[];
  } finally {
    db.close();
  }
}

export const handedTo = (data: string, key: string) => rows<{ station: string }>(data, "SELECT station FROM handed_over WHERE session = ?", key)[0] ?? null;

/// Two stations of workspace `w1` on loopback iroh (both on the test channel, where moving is offered), each with the
/// config given; the fakes of both writing their notes in one place.
export async function pair(names: [string, string], configs: [object, object], env: [Record<string, string>, Record<string, string>] = [{}, {}]) {
  const [a, b] = [stationDir(configs[0]), stationDir(configs[1])];
  const peers: [{ id: string; name: string; ips: string[] }, { id: string; name: string; ips: string[] }] = [
    { id: a.id, name: names[0], ips: [] },
    { id: b.id, name: names[1], ips: [] },
  ];
  const p = await plane((station) => ({ workspace: "w1", workspace_name: "团队", name: station === a.id ? names[0] : names[1], peers }));
  cloudJson(a.data, { origin: p.origin, id: a.id, name: names[0], peers });
  cloudJson(b.data, { origin: p.origin, id: b.id, name: names[1], peers });
  const out = fresh("out");
  const bins = [binOf(`${names[0]}-reply`), binOf(`${names[1]}-reply`)];
  const datas = [a.data, b.data] as const;
  const live: [Launched | null, Launched | null] = [null, null];
  const hasPeerIp = (data: string, peerId: string, ip: string) => {
    const saved = readJson(join(data, "mesh", "cloud.json"));
    const entry = Array.isArray(saved?.peers) ? saved.peers.find((x: any) => x?.id === peerId) : null;
    return Array.isArray(entry?.ips) && entry.ips.includes(ip);
  };
  const start = async (i: 0 | 1) => {
    // Bind UDP port 0 directly so the kernel assigns a free port atomically (no pre-probe TOCTOU against other test workers).
    const launched = await launch(i === 0 ? a.data : b.data, i === 0 ? a.app : b.app, {
      PATH: bins[i]!,
      FAKE_OUT: out,
      FAKE_STATION: names[i]!,
      STILLFAIL_MESH_BIND_ADDR: "127.0.0.1:0",
      ...env[i],
    });
    live[i] = launched;
    const got = await given(
      `${names[i]} mesh listening`,
      () => {
        const port = launched.meshPort();
        if (port !== null) return { port };
        if (!launched.alive()) return { dead: true as const };
        return null;
      },
      launched.err,
    );
    if ("dead" in got) throw new Error(`${names[i]} exited before mesh listening:\n${launched.err()}`);
    const ip = `127.0.0.1:${got.port}`;
    peers[i].ips = [ip];
    p.push();
    const other = (1 - i) as 0 | 1;
    const otherIp = peers[other].ips[0];
    if (otherIp !== undefined) {
      await given(
        `${names[i]} sees ${names[other]} at ${otherIp}`,
        () => !launched.alive() || hasPeerIp(datas[i], peers[other].id, otherIp),
        launched.err,
      );
      if (!launched.alive()) throw new Error(`${names[i]} exited before seeing ${names[other]} at ${otherIp}:\n${launched.err()}`);
    }
    const peerLive = live[other];
    if (peerLive !== null && peerLive.alive()) {
      await given(
        `${names[other]} sees ${names[i]} at ${ip}`,
        () => !peerLive.alive() || hasPeerIp(datas[other], peers[i].id, ip),
        () => `${launched.err()}\n${peerLive.err()}`,
      );
      if (!peerLive.alive()) throw new Error(`${names[other]} exited before seeing ${names[i]} at ${ip}:\n${peerLive.err()}`);
    }
    return launched;
  };
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
export async function texts(port: number, thread: number): Promise<string[]> {
  const r = await http(port, `/admin-api/threads/${thread}/entries`);
  assert.equal(r.status, 200, r.text);
  return (r.json.entries as any[]).filter((e) => e.kind === "message").map((e) => String(e.text));
}

/// A chat made on the station at `port` on account `profile`, its first message answered: its key and thread.
export async function chat(port: number, store: Store, profile: string, text: string, detail: () => string): Promise<{ key: string; thread: number }> {
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
export async function attach(port: number, thread: number, name: string, bytes: Buffer, text: string): Promise<string> {
  const up = await http(port, `/admin-api/uploads?name=${encodeURIComponent(name)}`, { raw: bytes });
  assert.equal(up.status, 200, up.text);
  const sent = await http(port, `/admin-api/threads/${thread}/messages`, { body: { text, attachments: [{ path: up.json.path, name }] } });
  assert.ok(sent.status < 300, sent.text);
  return sha(bytes);
}

/// The move page of `port` toward `to`.
export const movePage = async (port: number, to: string) => (await http(port, `/admin-api/move?to=${to}`)).json;
export const itemOf = (page: any, module: string, id: string) => page?.modules?.find((m: any) => m.id === module)?.items?.find((x: any) => x.id === id);
