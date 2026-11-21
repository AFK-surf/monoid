// The whole station as a release runs it, with no Node anywhere: the real launcher (native/launcher, `stillfail-station
// run`) starts the MoonBit station of a release laid out as station-bundle.sh lays one (`<app>/station/stillfail-reader`,
// no main.js, no node), every live slice of it together (station/mb src/station_main live_p5_*). It reaches a control
// plane of the test's (HTTP and its presence socket); a member let in on the mesh (real iroh) by the credential the
// workspace's key signed reads the overview, every slice's fields in it; a session made through the admin API runs a
// turn of a fake Claude Code under the runner, which lists the agents' door's tools (each slice's among them) and posts
// through it; a message a Slack stand-in sends on its Socket Mode socket comes in through the connects, makes a session
// whose turn answers in the Slack thread; and the launcher hands the station over to its next process (SIGUSR2), which
// takes the ports and the sessions up while the one before ends with nothing of it left. A file of a session's is read
// as the app reads it (whole, as a thumbnail, a part), and the drive's grant key is read back across the handover.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer as netServer } from "node:net";
import { createServer as httpServer, request } from "node:http";
import { createSocket } from "node:dgram";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { Store } from "../src/store/store.ts";
import { RUNTIME_KINDS } from "../src/agents/runtime.ts";
import { DatabaseSync } from "node:sqlite";

const binary = mbReaderBinary();
const launcher = process.env.STILLFAIL_LAUNCHER ?? "";
const runner = process.env.STILLFAIL_RUNNER ?? "";
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
  : addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)"
  : !existsSync("/usr/bin/curl") ? "no /usr/bin/curl for the fake runtime"
  : false;

const dirs: string[] = [];
// (short: a runner's and the status's Unix sockets are at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfw-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
after(async () => {
  for (const c of closers) c();
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  // (a killed child holds its files until it is gone: removing its directory before then finds it not empty)
  const gone = Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  await Promise.race([gone, new Promise<void>((r) => setTimeout(r, 5_000).unref())]);
  // (what a run left: its processes, by what their files say)
  for (const d of dirs) {
    for (const f of ["run/station.json", "run/front.pid"]) {
      try {
        const pid = Number(JSON.parse(readFileSync(join(d, f), "utf8")).pid ?? readFileSync(join(d, f), "utf8"));
        if (pid > 0) process.kill(pid, "SIGKILL");
      } catch {}
    }
    const runners = join(d, "run", "runners");
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
  if (process.env.STATION_KEEP !== "1") for (const d of dirs) rmSync(d, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
});

/// Looked at until `look` gives something (real processes: every 50 ms), or failing with `what` after `ms`.
async function until<T>(what: string, look: () => T | null | undefined | false | Promise<T | null | undefined | false>, detail: () => string = () => "", ms = 60_000): Promise<T> {
  const end = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await look();
      if (v) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > end) throw new Error(`never: ${what}${last ? ` (${(last as Error).message})` : ""}; ${detail()}`);
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

/// The control plane of the test's: its HTTP and its presence socket, which tells the station its state.
async function controlPlane(peers: unknown[]) {
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
      ws.send(JSON.stringify({ type: "state", workspace: "w1", workspace_name: "团队", name: "mac", peers, relay_urls: [] }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, sockets };
}

/// Slack, of the test's: its Web API (each method as it was asked) and its Socket Mode socket.
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
      const said = JSON.parse(String(m));
      if (typeof said.envelope_id === "string") acks.push(said.envelope_id);
    });
    ws.send(JSON.stringify({ type: "hello" }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const c of wss.clients) c.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return { base: `http://127.0.0.1:${(server.address() as AddressInfo).port}/api`, asked, sockets, acks };
}

/// Anthropic, of the test's: a Claude subscription's allowance (/api/oauth/usage), asked with the profile's token.
async function anthropicStandIn() {
  const asked: { path: string; auth: string }[] = [];
  const server = httpServer((req, res) => {
    req.resume();
    asked.push({ path: req.url ?? "", auth: String(req.headers.authorization ?? "") });
    if (!(req.url ?? "").startsWith("/api/oauth/usage")) return void res.writeHead(404).end("{}");
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({
      five_hour: { utilization: 42, resets_at: "2026-11-18T10:00:00Z" },
      seven_day: { utilization: 7, resets_at: "2026-11-24T10:00:00Z" },
    }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    server.closeAllConnections();
    server.close();
  });
  return { base: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, asked };
}

/// What a member's `GET /admin/api/events` is told, as text as it comes, till the connection goes.
async function memberEvents(conn: Connection) {
  const stream = await conn.openBi();
  await line(stream, { method: "GET", path: "/admin/api/events", headers: {} });
  await stream.finish();
  const told = { text: "" };
  void (async () => {
    for (;;) {
      const piece = await stream.read().catch(() => null);
      if (piece === null) return;
      told.text += piece.toString();
    }
  })();
  return told;
}

/// A fake Claude Code (stream-json in and out, /bin/sh and curl alone): each prompt lists the agents' door's tools,
/// asks a tool of each slice and posts all_done to the thread it was asked in.
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
call() { /usr/bin/curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" -d "$1"; }
n=0
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  n=$((n+1))
  # (its init as Claude Code says it: once a turn is given it, never before its first message, which the station reads
  # as a turn begun: said at its start, it can be read before the station's first prompt, refused as a turn running)
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  # (what the station tells it with no thread of a person's, its job's end or its nudge, is answered in the thread it
  # was asked in before, and starts no job: when that comes is the machine's, so nothing it does depends on it)
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/$sid-to"; else to=$(/bin/cat "$FAKE_OUT/$sid-to" 2>/dev/null); fi
  call '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' > "$FAKE_OUT/$sid-list-$n.json"
  # (no job where the test says so: its end is told the agent as a turn of its own, whenever the machine has it)
  if [ "$n" = 1 ] && [ -z "$FAKE_NO_JOB" ]; then
    call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"job_start","arguments":{"name":"hello","command":"echo hi"}}}' > "$FAKE_OUT/$sid-job-$n.json"
  fi
  call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"device_list","arguments":{}}}' > "$FAKE_OUT/$sid-devices-$n.json"
  # (a tool call of the test's, where it gives one: $FAKE_OUT/extra atomically claimed by one turn, else $FAKE_EXTRA,
  # a tools/call's params; outputs published via atomic rename so the test never observes half-written files)
  mv_bin=/bin/mv; [ -x "$mv_bin" ] || mv_bin=/usr/bin/mv
  extra=""
  if "$mv_bin" "$FAKE_OUT/extra" "$FAKE_OUT/extra.$sid.$n" 2>/dev/null; then
    extra=$(/bin/cat "$FAKE_OUT/extra.$sid.$n" 2>/dev/null)
  elif [ -n "$FAKE_EXTRA" ]; then
    extra="$FAKE_EXTRA"
  fi
  if [ -n "$extra" ]; then
    call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":'"$extra"'}' > "$FAKE_OUT/$sid-extra-$n.tmp"
    "$mv_bin" "$FAKE_OUT/$sid-extra-$n.tmp" "$FAKE_OUT/$sid-extra-$n.json"
  fi
  call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","text":"posted by the fake","kind":"all_done","done":"answered what it was sent"}}}' > "$FAKE_OUT/$sid-post-$n.tmp"
  "$mv_bin" "$FAKE_OUT/$sid-post-$n.tmp" "$FAKE_OUT/$sid-post-$n.json"
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"posted"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"posted"}'
done
`;
  writeFileSync(join(dir, "claude"), claude);
  chmodSync(join(dir, "claude"), 0o755);
  for (const tool of ["sh", "cat", "echo", "sleep", "env"]) {
    const found = ["/bin", "/usr/bin"].map((d) => join(d, tool)).find((p) => existsSync(p));
    if (found !== undefined) {
      try { copyFileSync(found, join(dir, tool)); chmodSync(join(dir, tool), 0o755); } catch {}
    }
  }
}

/// One request of the station's own listener: its status and body.
function ask(port: number | { socket: string }, path: string, o: { method?: string; body?: unknown; token?: string } = {}): Promise<{ status: number; body: string; json: any }> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (o.token !== undefined) headers.authorization = `Bearer ${o.token}`;
    const req = request({ ...(typeof port === "number" ? { host: "127.0.0.1", port } : { socketPath: port.socket }), path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => {
        let json: any = null;
        try { json = text === "" ? null : JSON.parse(text); } catch {}
        resolve({ status: res.statusCode!, body: text, json });
      });
    });
    req.on("error", reject);
    req.end(o.body === undefined ? undefined : JSON.stringify(o.body));
  });
}

const line = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

async function member(conn: Connection, credential: string) {
  const first = await conn.openBi();
  await line(first, { credential, protocol: 2 });
  return new Reader(first).line();
}

/// A member's request on the mesh: a body given as JSON, or bytes as they are (an upload's).
async function memberAsk(conn: Connection, method: string, path: string, body?: unknown, extraHeaders?: Record<string, string>): Promise<[number, any]> {
  const stream = await conn.openBi();
  const bytes = Buffer.isBuffer(body);
  await line(stream, { method, path, headers: { "content-type": bytes ? "application/octet-stream" : "application/json", ...extraHeaders } });
  if (body !== undefined) await stream.write(bytes ? body : Buffer.from(JSON.stringify(body)));
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  const rest = (await reader.rest()).toString();
  let json: any = rest;
  try { json = JSON.parse(rest || "null"); } catch {}
  return [head.status, json];
}

/// A member's GET on the mesh, its answer's bytes as they came.
async function memberRaw(conn: Connection, path: string): Promise<[number, Buffer]> {
  const stream = await conn.openBi();
  await line(stream, { method: "GET", path, headers: {} });
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  return [head.status, Buffer.from(await reader.rest())];
}

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

test("a release with no Node: the launcher runs the MoonBit station whole, a member reads it, an agent's turn and a Slack thread go through it, and it hands over to its next process", { skip, timeout: 300_000 }, async () => {
  // ── the release as station-bundle.sh lays it: the MoonBit station, its runner; no Node, no main.js ──
  const app = fresh("app");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(binary!, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  copyFileSync(runner, join(app, "station", "stillfail-runner"));
  chmodSync(join(app, "station", "stillfail-runner"), 0o755);
  writeFileSync(join(app, "BUILD"), "9700\n");
  assert.equal(existsSync(join(app, "station", "main.js")), false);
  assert.equal(existsSync(join(app, "node")), false);
  const bin = fresh("bin");
  fakeClaude(bin);
  assert.equal(existsSync(join(bin, "node")), false, "no Node on the station's PATH");
  const out = fresh("out");

  // ── a data directory enrolled in a workspace of the test's plane, a Claude profile, a Slack connect ──
  const data = fresh("data");
  const id = spawnSync(join(app, "station", "stillfail-reader"), ["id", "--data", data], { env: { PATH: bin, HOME: data }, encoding: "utf8" }).stdout.trim();
  assert.match(id, /^[0-9a-f]{64}$/);
  const grant = new GrantKey();
  const meshPort = await freeUdpPort();
  const plane = await controlPlane([{ id, name: "mac", ips: [`127.0.0.1:${meshPort}`] }]);
  const slack = await slackStandIn();
  const anthropic = await anthropicStandIn();
  const mcpPort = await freeTcpPort();
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] }, peers: [], revocations: [],
  }));
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "sk-ant-oat-test", expiresAt: Date.now() + 86_400_000 } }));
  writeFileSync(join(data, "config.json"), JSON.stringify({
    language: "en",
    http: { port: mcpPort },
    profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", access: { kind: "subscription" } }],
    maxNudges: 1,
    connects: [{ id: "c1", kind: "slack", mode: "multi-session", enabled: true, bind: { runtime: "claude", profile: "cc" }, createdBy: { id: "ada@x.com" }, slack: { appToken: "xapp-1", botToken: "xoxb-1", appId: "A1" } }],
  }));

  // ── the real launcher ──
  const env = {
    PATH: bin, HOME: data, TMPDIR: tmpdir(), FAKE_OUT: out,
    STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}`,
    STILLFAIL_SLACK_API: slack.base, STILLFAIL_ANTHROPIC_API: anthropic.base, STILLFAIL_AGENT_NICE: "0", STILLFAIL_HELD_EVERY_MS: "300",
  };
  const loopPort = await freeTcpPort();
  const station = spawn(launcher, ["run", "--app", app, "--data", data, "--port", String(loopPort)], { stdio: ["ignore", "pipe", "pipe"], env });
  children.push(station);
  let err = "";
  station.stdout!.on("data", (d) => (err += d));
  station.stderr!.on("data", (d) => (err += d));
  const tail = () => err.slice(-4000);
  const ended = new Promise<number | null>((resolve) => station.on("exit", (code) => resolve(code)));

  // taken over: the launcher says which process serves every entrance (run/station.json names the launcher itself)
  const takenOver = () => [...err.matchAll(/Node (\d+) has taken over/g)].map((m) => Number(m[1]));
  const first = { pid: await until("the station taken over", () => takenOver()[0], tail) };
  // (written as the launcher says it, just after its line: lifecycle.rs `check_taken`, `say_started`)
  // (the launcher says a process took over before it writes station.json, a file whole: its pid is waited for)
  await until("run/station.json names the launcher", () => readJson(join(data, "run", "station.json"))?.pid === station.pid, tail);
  const ps = spawnSync("ps", ["-o", "command=", "-p", String(first.pid)], { encoding: "utf8" }).stdout;
  assert.ok(ps.includes("stillfail-reader") && !ps.includes("node"), `the station's process is the program: ${ps}`);
  await until("the agents' door", async () => (await ask(mcpPort, "/admin-api/host")).status === 200, tail);

  // ── the control plane: online ──
  await until("presence.json online", () => readJson(join(data, "run", "presence.json"))?.online === true, tail);
  const status = await until("the status socket", async () => {
    const s = (await ask({ socket: join(data, "run", "status.sock") }, "/v1/status")).json;
    return s?.reached === true ? s : null;
  }, tail);
  assert.equal(status.workspace, "w1");

  // ── a member on the mesh, by real iroh, let in by the credential the workspace's key signed ──
  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  closers.push(() => void client.close());
  const now = Math.floor(Date.now() / 1000);
  const credential = grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u1", email: "ada@x.com", name: "Ada", ws: "w1", role: "owner", device: client.id(), sid: "s1", iat: now, exp: now + 3600 });
  const conn = await until("connected on the mesh", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")), tail);
  const hello = await member(conn, credential);
  assert.equal(hello.ok, true, JSON.stringify(hello));
  // its device may enter the workspace's mesh scope as a leaf (leaf.ts): told so, and given the scope's view
  assert.equal(hello.meshLeaf, true, JSON.stringify(hello));
  const leaf = await until("the leaf's view of the workspace's scope", async () => {
    const [st, view] = await memberAsk(conn, "GET", "/admin/api/mesh/leaf");
    return st === 200 && Array.isArray(view?.stations) && view.stations.includes(id) ? view : null;
  }, tail);
  assert.match(leaf.scope, /^[0-9a-f]{64}$/);
  assert.equal(leaf.transit, false);
  // the overview: the platform's and the rigs' (P5-1), the agents' (P5-2), the accounts' (P5-3), the drive's (P5-4) and the
  // updates', copies' and features' (P5-5)
  const [ovStatus, overview] = await memberAsk(conn, "GET", "/admin/api/overview");
  assert.equal(ovStatus, 200, JSON.stringify(overview).slice(0, 500));
  for (const field of ["machine", "rigs", "processes", "profiles", "sharing", "drive", "updates", "copies", "features", "connects"]) {
    assert.ok(field in overview, `the overview's ${field}: ${Object.keys(overview).join(",")}`);
  }
  assert.ok(overview.profiles.some((p: any) => p.id === "cc"), JSON.stringify(overview.profiles));

  // ── a Claude subscription's allowance, read of Anthropic with the profile's token (0.1.9984 read it of the console,
  // with only the console's address given the accounts: none came) ──
  const [quotaStatus, quota] = await memberAsk(conn, "POST", "/admin/api/profiles/cc/quota", {});
  assert.equal(quotaStatus, 200, `${JSON.stringify(quota)}; ${JSON.stringify(anthropic.asked)}`);
  assert.equal(quota.state, "ok", JSON.stringify(quota));
  assert.deepEqual(quota.windows.map((w: any) => [w.label, w.usedPercent]), [["5 小时", 42], ["每周", 7]], JSON.stringify(quota));
  assert.ok(anthropic.asked.some((a) => a.auth === "Bearer sk-ant-oat-test"), JSON.stringify(anthropic.asked));

  // ── the Slack connect, connected on its socket ──
  await until("the Slack socket open", () => slack.sockets.length >= 1, () => `${JSON.stringify(slack.asked.map((x) => x.m))}; ${tail()}`);

  // ── files for a message, kept by the program's own file system: one whole, and one in parts (the app's retry) ──
  const whole = Buffer.from("a whole file\n");
  const [upStatus, up] = await memberAsk(conn, "POST", "/admin/api/uploads?name=whole.txt", whole);
  assert.equal(upStatus, 200, JSON.stringify(up));
  assert.equal(up.size, whole.length);
  assert.deepEqual(readFileSync(up.path), whole);
  const parted = Buffer.concat([Buffer.alloc(5, "a"), Buffer.alloc(4, "b")]);
  const partOf = (offset: number, piece: Buffer) => memberAsk(conn, "POST", `/admin/api/uploads/parts?id=parted01&name=parted.bin&size=${parted.length}&offset=${offset}`, piece);
  const [firstStatus, firstSaid] = await partOf(0, parted.subarray(0, 5));
  assert.equal(firstStatus, 200, JSON.stringify(firstSaid));
  assert.equal(firstSaid.have, 5);
  // (the first part again, as after a broken connection, and the rest)
  assert.equal((await partOf(0, parted.subarray(0, 5)))[1].have, 5);
  const [lastStatus, lastSaid] = await partOf(5, parted.subarray(5));
  assert.equal(lastStatus, 200, JSON.stringify(lastSaid));
  assert.equal(lastSaid.have, parted.length);
  assert.deepEqual(readFileSync(lastSaid.file.path), parted);

  // ── a session made through the admin API, and a turn of its agent under the runner ──
  const [made, said] = await memberAsk(conn, "POST", "/admin/api/sessions", { runtime: "claude", profile: "cc" });
  assert.equal(made, 200, `${JSON.stringify(said)}; ${tail()}`);
  const key: string = said.key;
  const threadId: number = said.thread?.id ?? said.thread?.thread?.id;
  assert.ok(typeof key === "string" && typeof threadId === "number", JSON.stringify(said));
  // ── a file of the session's (one heard from Slack, kept in its uploads), read as the app reads it: whole, as its
  // thumbnail, a part ──
  {
    const probe = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
    const ws = (probe.getSession(key) as { workspace: string }).workspace;
    probe.close();
    mkdirSync(join(ws, "uploads"), { recursive: true });
    const heard = Buffer.from("heard from Slack\n");
    writeFileSync(join(ws, "uploads", "2026-11-18T02-38-01-F1-note.txt"), heard);
    const at = `/admin/api/sessions/${encodeURIComponent(key)}`;
    const name = encodeURIComponent("2026-11-18T02-38-01-F1-note.txt");
    for (const [path, want] of [[`${at}/files?name=${name}`, heard], [`${at}/files?name=${name}&thumb=1`, heard], [`${at}/parts?name=${name}&offset=6&length=4`, heard.subarray(6, 10)]] as const) {
      const [status, body] = await memberRaw(conn, path);
      assert.equal(status, 200, `${path}: ${body.toString()}`);
      assert.deepEqual(body, want, path);
    }
  }
  // (a device follows the station's events: what the agent posts is told it as it is written, with nothing more asked
  // of the station; 0.1.9984 told it only once a person's next message came)
  const events = await memberEvents(conn);
  const [sent, sentSaid] = await memberAsk(conn, "POST", `/admin/api/threads/${threadId}/messages`, { text: "hello there" });
  assert.ok(sent >= 200 && sent < 300, JSON.stringify(sentSaid));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  closers.push(() => store.close());
  await until("its turn ended all_done", () => store.listTurns(key).some((t) => t.summary.ending === "all_done"), () => `${JSON.stringify(store.listTurns(key).map((t) => t.summary))}; ${tail()}`);
  await until("the agent's post told on the device's events", () => events.text.includes("posted by the fake"), () => `${events.text.slice(-2000)}; ${tail()}`);
  const listFile = readdirSync(out).find((f) => f.endsWith("-list-1.json"));
  assert.ok(listFile !== undefined, readdirSync(out).join(","));
  const tools = JSON.parse(readFileSync(join(out, listFile!), "utf8")).result.tools.map((t: any) => t.name) as string[];
  // each slice's tools on the one door: the chats' (P5-2), the jobs' (P5-3), the vault's and the devices' (P5-4), Slack's
  // and Feishu's (P5-5)
  for (const name of ["chat_post", "chat_state", "session_history", "relays", "job_start", "station_task", "secret_list", "device_list", "slack_api", "feishu_api"]) {
    assert.ok(tools.includes(name), `${name} on the door: ${tools.join(",")}`);
  }
  const job = JSON.parse(readFileSync(join(out, listFile!.replace("-list-", "-job-")), "utf8"));
  assert.notEqual(job.result?.isError, true, JSON.stringify(job));
  const devices = JSON.parse(readFileSync(join(out, listFile!.replace("-list-", "-devices-")), "utf8"));
  assert.notEqual(devices.result?.isError, true, JSON.stringify(devices));

  // ── a message on Slack: through the connects to a session of its own, its turn answering in the thread ──
  slack.sockets[0]!.send(JSON.stringify({
    type: "events_api", envelope_id: "e1",
    payload: { team_id: "T1", event: { type: "app_mention", channel: "C1", user: "U1", text: "<@UB> hello from slack", ts: "1790000050.000100", channel_type: "channel" } },
  }));
  await until("the event acknowledged", () => slack.acks.includes("e1"), tail);
  const posts = () => slack.asked.filter((x) => x.m === "chat.postMessage" || x.m === "chat.update");
  const posted = await until("the answer posted in the Slack thread", () => posts().find((x) => x.form.thread_ts === "1790000050.000100" && /posted by the fake/.test(x.form.text ?? "")),
    () => `${JSON.stringify(posts().map((x) => x.form))}; ${tail()}`);
  assert.equal(posted.form.channel, "C1");
  for (const p of posts()) assert.doesNotMatch(String(p.form.text ?? ""), /^null/, `no post says null: ${JSON.stringify(posts().map((x) => x.form))}`);

  // ── a handover by the launcher (SIGUSR2): the next process takes the ports and the sessions, the one before ends ──
  const before = first.pid as number;
  const grantKey = readFileSync(join(data, "drive-grant.key"));
  station.kill("SIGUSR2");
  const next = { pid: await until("the next process took over", () => takenOver().find((p) => p !== before), tail) };
  await until("the process before gone", () => !alive(before), tail);
  assert.ok(alive(next.pid), "the next one runs");
  await until("the door served by the next process", async () => (await ask(mcpPort, "/admin-api/host")).status === 200, tail);
  // a member reads the overview again, of the next process
  const conn2 = await until("connected again", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")), tail);
  assert.equal((await member(conn2, credential)).ok, true);
  const [again] = await memberAsk(conn2, "GET", "/admin/api/overview");
  assert.equal(again, 200);
  // the drive's grant key read back, not made anew: a grant given before the handover still holds
  assert.deepEqual(readFileSync(join(data, "drive-grant.key")), grantKey);
  // the session taken up: a second message to it runs its turn under the next process
  const [sent2, s2] = await memberAsk(conn2, "POST", `/admin/api/threads/${threadId}/messages`, { text: "once more" });
  assert.ok(sent2 >= 200 && sent2 < 300, JSON.stringify(s2));
  await until("a second turn ended all_done", () => store.listTurns(key).filter((t) => t.summary.ending === "all_done").length >= 2, () => `${JSON.stringify(store.listTurns(key).map((t) => t.summary))}; ${tail()}`);

  // ── a stop: the launcher, the station and every process of theirs gone ──
  const front = Number(readFileSync(join(data, "run", "front.pid"), "utf8").trim() || "0");
  station.kill("SIGTERM");
  assert.equal(await ended, 0, tail());
  await until("the station's process gone", () => !alive(next.pid), tail);
  if (front > 0) await until("the front gone", () => !alive(front), tail);
});

/// A station of a release with no Node, on the data directory its key was made in (`keyIn`), enrolled in the test's
/// workspace `w1` and run under the real launcher, its mesh on `meshPort`.
async function launchedAt(k: { id: string; data: string }, name: string, app: string, bin: string, plane: { origin: string }, meshPort: number, env: Record<string, string>) {
  const data = k.data;
  const grant = new GrantKey();
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, station: k.id, workspace: "w1", workspace_name: "团队", name, relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] }, peers: [], revocations: [],
  }));
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  const mcpPort = await freeTcpPort();
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en", http: { port: mcpPort }, profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }], maxNudges: 1 }));
  const loopPort = await freeTcpPort();
  const station = spawn(launcher, ["run", "--app", app, "--data", data, "--port", String(loopPort)], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { PATH: bin, HOME: data, TMPDIR: tmpdir(), STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}`, STILLFAIL_AGENT_NICE: "0", ...env },
  });
  children.push(station);
  let said = "";
  station.stdout!.on("data", (d) => (said += d));
  station.stderr!.on("data", (d) => (said += d));
  const tail = () => said.slice(-4000);
  await until(`${name} taken over`, () => /Node \d+ has taken over/.test(said), tail);
  await until(`${name}'s agents' door`, async () => (await ask(mcpPort, "/admin-api/host")).status === 200, tail);
  await until(`${name} online`, () => readJson(join(data, "run", "presence.json"))?.online === true, tail);
  return { mcpPort, tail };
}

/// A station's key made in a data directory of its own, before the plane lists it.
function keyIn(app: string, bin: string) {
  const data = fresh("key");
  const id = spawnSync(join(app, "station", "stillfail-reader"), ["id", "--data", data], { env: { PATH: bin, HOME: data }, encoding: "utf8" }).stdout.trim();
  assert.match(id, /^[0-9a-f]{64}$/);
  return { id, data };
}

test("two stations of a release with no Node: an agent on one asks the other over the mesh, and is answered", { skip, timeout: 300_000 }, async () => {
  const app = fresh("app");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(binary!, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  copyFileSync(runner, join(app, "station", "stillfail-runner"));
  chmodSync(join(app, "station", "stillfail-runner"), 0o755);
  writeFileSync(join(app, "BUILD"), "9700\n");
  const bin = fresh("bin");
  fakeClaude(bin);
  const out = fresh("out");
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const a = keyIn(app, bin);
  const b = keyIn(app, bin);
  // (both on the plane's roster of the workspace, each where its mesh listens)
  const plane = await controlPlane([{ id: a.id, name: "mac-a", ips: [`127.0.0.1:${portA}`] }, { id: b.id, name: "mac-b", ips: [`127.0.0.1:${portB}`] }]);
  const there = await launchedAt(b, "mac-b", app, bin, plane, portB, { FAKE_OUT: out });
  const here = await launchedAt(a, "mac-a", app, bin, plane, portA, { FAKE_OUT: out, FAKE_EXTRA: JSON.stringify({ name: "station_list", arguments: { station: b.id } }) });

  // an agent's turn on A: its station_list of B, which A asks B for over the mesh
  const made = await ask(here.mcpPort, "/admin-api/sessions", { body: { runtime: "claude", profile: "cc" } });
  assert.equal(made.status, 200, `${made.body}; ${here.tail()}`);
  const key: string = made.json.key;
  const threadId: number = made.json.thread?.id ?? made.json.thread?.thread?.id;
  const sent = await ask(here.mcpPort, `/admin-api/threads/${threadId}/messages`, { body: { text: "what is mac-b?" } });
  assert.ok(sent.status >= 200 && sent.status < 300, sent.body);
  const store = Store.open(join(a.data, "stillfail.db"), join(a.data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  closers.push(() => store.close());
  await until("its turn ended all_done", () => store.listTurns(key).some((t) => t.summary.ending === "all_done"), () => `${JSON.stringify(store.listTurns(key).map((t) => t.summary))}; ${here.tail()}`);
  const extra = readdirSync(out).find((f) => f.endsWith("-extra-1.json"));
  assert.ok(extra !== undefined, readdirSync(out).join(","));
  const listed = JSON.parse(readFileSync(join(out, extra!), "utf8"));
  assert.notEqual(listed.result?.isError, true, `${JSON.stringify(listed)}; A: ${here.tail()}; B: ${there.tail()}`);
  const text = String(listed.result?.content?.[0]?.text ?? "");
  // B's own description, as B said it: its id and name, not "unanswered", not a refusal
  assert.ok(text.includes(b.id), `B described: ${text}; A: ${here.tail()}; B: ${there.tail()}`);
  assert.doesNotMatch(text, /unanswered|Unreached|PeerRefused|PeerError/, text);

  // the workspace's mesh directory brought level between them over the peer bus: each keeps both stations'
  // announcements of their scoped bindings, signed by each (mesh/scope-sync.ts)
  const announced = (data: string) => {
    const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
    try {
      return (db.prepare("SELECT node FROM mesh_announcements ORDER BY node").all() as { node: string }[]).map((r) => r.node);
    } finally { db.close(); }
  };
  const both = [a.id, b.id].sort();
  await until("A keeps both stations' announcements", () => JSON.stringify(announced(a.data)) === JSON.stringify(both), () => `${announced(a.data)}; A: ${here.tail()}`);
  await until("B keeps both stations' announcements", () => JSON.stringify(announced(b.data)) === JSON.stringify(both), () => `${announced(b.data)}; B: ${there.tail()}`);
});

test("a release with no Node: a relay enrolled by an agent's token on the station's door, listed and revoked", { skip, timeout: 300_000 }, async () => {
  const app = fresh("app");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(binary!, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  copyFileSync(runner, join(app, "station", "stillfail-runner"));
  chmodSync(join(app, "station", "stillfail-runner"), 0o755);
  writeFileSync(join(app, "BUILD"), "9700\n");
  const bin = fresh("bin");
  fakeClaude(bin);
  const out = fresh("out");
  const port = await freeUdpPort();
  const k = keyIn(app, bin);
  const plane = await controlPlane([{ id: k.id, name: "mac", ips: [`127.0.0.1:${port}`] }]);
  const here = await launchedAt(k, "mac", app, bin, plane, port, { FAKE_OUT: out, FAKE_NO_JOB: "1" });
  const made = await ask(here.mcpPort, "/admin-api/sessions", { body: { runtime: "claude", profile: "cc" } });
  assert.equal(made.status, 200, `${made.body}; ${here.tail()}`);
  const key: string = made.json.key;
  const threadId: number = made.json.thread?.id ?? made.json.thread?.thread?.id;
  const store = Store.open(join(k.data, "stillfail.db"), join(k.data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  closers.push(() => store.close());
  // A turn whose agent calls the relays tool as `params` says: what the tool answered.
  let turns = 0;
  const relays = async (params: unknown) => {
    // (what the turn before answered taken away: the fake numbers its turns by its own process and atomically claims
    // `extra` once, so no extra turn or title nudge can replay a previous call)
    for (const f of readdirSync(out).filter((f) => f.includes("-extra-"))) rmSync(join(out, f));
    writeFileSync(join(out, "extra.tmp"), JSON.stringify({ name: "relays", arguments: params }));
    renameSync(join(out, "extra.tmp"), join(out, "extra"));
    turns++;
    const sent = await ask(here.mcpPort, `/admin-api/threads/${threadId}/messages`, { body: { text: `relays ${turns}` } });
    assert.ok(sent.status >= 200 && sent.status < 300, sent.body);
    // Wait until both the claimed tool call's post finished AND the station recorded turn `n` ended in `store`,
    // so the next `relays()` message never races with this turn's `chat_post` or `result`.
    const done = () => {
      const file = readdirSync(out).find((f) => f.endsWith(".json") && f.includes("-extra-"));
      if (file === undefined) return undefined;
      const m = /-extra-(\d+)\.json$/.exec(file);
      if (m === null) return undefined;
      const n = Number(m[1]);
      return existsSync(join(out, file.replace(/-extra-(\d+)\.json$/, "-post-$1.json"))) && store.listTurns(key).length >= n ? file : undefined;
    };
    await until(`turn ${turns} answered its call`, done, () => `${readdirSync(out).join(",")}; turns=${store.listTurns(key).length}; ${here.tail()}`);
    const file = done();
    const said = JSON.parse(readFileSync(join(out, file!), "utf8"));
    assert.notEqual(said.result?.isError, true, `${JSON.stringify(said)}; ${here.tail()}`);
    return JSON.parse(said.result.content[0].text);
  };

  // ── a token for a relay, issued by the station an agent asked ──
  const issued = await relays({ action: "enroll", name: "edge relay" });
  assert.match(issued.token, /^[A-Za-z0-9_-]{43}$/, JSON.stringify(issued));
  assert.equal(issued.issuer, k.id);
  assert.match(issued.scope, /^[0-9a-f]{64}$/);

  // ── the relay, a mesh endpoint of its own, redeems it on the station's enrollment door ──
  const relay = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  closers.push(() => void relay.close());
  const enrol = async (request: unknown) => {
    const conn = await until("the enrollment door", () => relay.connect({ id: k.id, ips: [`127.0.0.1:${port}`] }, Buffer.from("stillfail/mesh-enrollment/1")), here.tail);
    const stream = await conn.openBi();
    await line(stream, request);
    await stream.finish();
    const said = await new Reader(stream).line();
    conn.close(0, "");
    return said;
  };
  // (the node is the transport's: one the request names is not taken)
  const enrolled = await enrol({ op: "enroll", scope: issued.scope, token: issued.token, node: k.id });
  assert.ok(enrolled.ok, `${JSON.stringify(enrolled)}; ${here.tail()}`);
  assert.equal(enrolled.ok.record.node, relay.id());
  assert.equal(enrolled.ok.record.generation, 1);
  assert.deepEqual(JSON.parse(enrolled.ok.body), enrolled.ok.record);
  // (its body as signRelayRecord writes it, byte for byte: the TypeScript stations verify it as written)
  const r = enrolled.ok.record;
  assert.equal(enrolled.ok.body, JSON.stringify({ scope: r.scope, node: r.node, issuer: r.issuer, generation: r.generation, name: r.name, made_by: r.made_by, revoked: r.revoked }));
  // a token used once is used up; the registration resumed
  const again = await enrol({ op: "enroll", scope: issued.scope, token: issued.token });
  assert.match(String(again.error), /already used/, JSON.stringify(again));
  assert.deepEqual((await enrol({ op: "resume", scope: issued.scope })).ok, enrolled.ok);

  // ── listed by the relays tool, then revoked, the next generation ──
  const listed = await relays({ action: "list" });
  assert.deepEqual(listed.mesh?.map((r: any) => [r.node, r.revoked, r.name]), [[relay.id(), 0, "edge relay"]], JSON.stringify(listed));
  const revoked = await relays({ action: "revoke", node: relay.id() });
  assert.equal(typeof revoked.body, "string", JSON.stringify(revoked));
  assert.equal(JSON.parse(revoked.body).revoked, 1, JSON.stringify(revoked));
  assert.equal(JSON.parse(revoked.body).generation, 2);
  const after = await relays({ action: "list" });
  assert.deepEqual(after.mesh?.map((r: any) => [r.node, r.revoked]), [[relay.id(), 1]], JSON.stringify(after));
  assert.match(String((await enrol({ op: "resume", scope: issued.scope })).code), /relay_not_registered/);
});

/// `--serve` child processes of `ppid` currently alive, by PID.
function serveChildrenOf(ppid: number): number[] {
  const out = spawnSync("ps", ["-eo", "pid=,ppid=,command="], { encoding: "utf8" }).stdout;
  const pids: number[] = [];
  for (const row of out.split("\n")) {
    const m = row.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (m && Number(m[2]) === ppid && m[3]!.includes("--serve")) pids.push(Number(m[1]));
  }
  return pids.sort((a, b) => a - b);
}

test("a release with no Node: --serve children answer routed reads, marks, idempotent messages and events, recover on crash, and clean up on stop", { skip, timeout: 300_000 }, async () => {
  const app = fresh("app");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(binary!, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  copyFileSync(runner, join(app, "station", "stillfail-runner"));
  chmodSync(join(app, "station", "stillfail-runner"), 0o755);
  writeFileSync(join(app, "BUILD"), "9700\n");
  const bin = fresh("bin");
  fakeClaude(bin);
  const out = fresh("out");

  const data = fresh("data");
  const id = spawnSync(join(app, "station", "stillfail-reader"), ["id", "--data", data], { env: { PATH: bin, HOME: data }, encoding: "utf8" }).stdout.trim();
  assert.match(id, /^[0-9a-f]{64}$/);
  const grant = new GrantKey();
  const meshPort = await freeUdpPort();
  const plane = await controlPlane([{ id, name: "mac", ips: [`127.0.0.1:${meshPort}`] }]);
  const mcpPort = await freeTcpPort();
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] }, peers: [], revocations: [],
  }));
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "sk-ant-oat-test", expiresAt: Date.now() + 86_400_000 } }));
  writeFileSync(join(data, "config.json"), JSON.stringify({
    language: "en",
    http: { port: mcpPort },
    profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", access: { kind: "subscription" } }],
    maxNudges: 1,
  }));

  const env = {
    PATH: bin, HOME: data, TMPDIR: tmpdir(), FAKE_OUT: out, FAKE_NO_JOB: "1",
    STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}`,
    STILLFAIL_AGENT_NICE: "0",
  };
  const loopPort = await freeTcpPort();
  const station = spawn(launcher, ["run", "--app", app, "--data", data, "--port", String(loopPort)], { stdio: ["ignore", "pipe", "pipe"], env });
  children.push(station);
  let err = "";
  station.stdout!.on("data", (d) => (err += d));
  station.stderr!.on("data", (d) => (err += d));
  const tail = () => err.slice(-4000);
  const ended = new Promise<number | null>((resolve) => station.on("exit", (code) => resolve(code)));

  const takenOver = () => [...err.matchAll(/Node (\d+) has taken over/g)].map((m) => Number(m[1]));
  const stationPid = await until("the station taken over", () => takenOver()[0], tail);
  await until("presence.json online", () => readJson(join(data, "run", "presence.json"))?.online === true, tail);

  // ── 2 --serve children spawned and registered with the front ──
  await until("requests routed to --serve", () => err.includes("requests routed to the MoonBit program"), tail);
  const initialServe = await until("2 --serve children alive", () => {
    const pids = serveChildrenOf(stationPid);
    return pids.length === 2 ? pids : null;
  }, tail);
  const runDir = join(data, "run");
  const serveSocks = () => readdirSync(runDir).filter((f) => f.startsWith(`serve-${stationPid}-`) && f.endsWith(".sock")).sort();
  assert.deepEqual(serveSocks(), [`serve-${stationPid}-0.sock`, `serve-${stationPid}-1.sock`]);

  // ── member connects on real iroh with full runtime header so --serve handles fast paths directly ──
  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  closers.push(() => void client.close());
  const now = Math.floor(Date.now() / 1000);
  const credential = grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u1", email: "ada@x.com", name: "Ada", ws: "w1", role: "owner", device: client.id(), sid: "s1", iat: now, exp: now + 3600 });
  const conn = await until("connected on the mesh", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")), tail);
  assert.equal((await member(conn, credential)).ok, true);

  const servedHeaders = { "stillfail-runtimes": RUNTIME_KINDS.join(",") };
  const [made, said] = await memberAsk(conn, "POST", "/admin/api/sessions", { runtime: "claude", profile: "cc" }, servedHeaders);
  assert.equal(made, 200, `${JSON.stringify(said)}; ${tail()}`);
  const key: string = said.key;
  const threadId: number = said.thread?.id ?? said.thread?.thread?.id;
  assert.ok(typeof key === "string" && typeof threadId === "number", JSON.stringify(said));

  // GET /admin/api/chats
  const [chatsStatus, chats] = await memberAsk(conn, "GET", "/admin/api/chats", undefined, servedHeaders);
  assert.equal(chatsStatus, 200, JSON.stringify(chats));
  const chatList = Array.isArray(chats) ? chats : chats?.chats;
  assert.ok(Array.isArray(chatList) && chatList.some((c: any) => c.id === key || c.thread === threadId), JSON.stringify(chats));

  // GET /admin/api/threads/:id/entries
  const [ent0Status, ent0] = await memberAsk(conn, "GET", `/admin/api/threads/${threadId}/entries`, undefined, servedHeaders);
  assert.equal(ent0Status, 200, JSON.stringify(ent0));
  assert.ok(Array.isArray(ent0?.entries), JSON.stringify(ent0));

  // GET /admin/api/events (streamed via --serve relay)
  const events = await memberEvents(conn);

  // POST /admin/api/threads/:id/messages with Idempotency-Key + retry
  const [msg1Status, msg1] = await memberAsk(
    conn, "POST", `/admin/api/threads/${threadId}/messages`, { text: "hello via serve" },
    { ...servedHeaders, "idempotency-key": "idem-serve-1" },
  );
  assert.equal(msg1Status, 200, JSON.stringify(msg1));
  assert.equal(typeof msg1?.n, "number", JSON.stringify(msg1));

  const [msg2Status, msg2] = await memberAsk(
    conn, "POST", `/admin/api/threads/${threadId}/messages`, { text: "hello via serve" },
    { ...servedHeaders, "idempotency-key": "idem-serve-1" },
  );
  assert.equal(msg2Status, 200, JSON.stringify(msg2));
  assert.equal(msg2.n, msg1.n, "idempotency retry returns the same entry number");

  // Agent receives delivery and completes turn; events stream receives the reply
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  closers.push(() => store.close());
  await until("agent turn ended all_done", () => store.listTurns(key).some((t) => t.summary.ending === "all_done"), () => `${JSON.stringify(store.listTurns(key).map((t) => t.summary))}; ${tail()}`);
  await until("events stream received agent reply", () => events.text.includes("posted by the fake"), () => `${events.text.slice(-2000)}; ${tail()}`);

  const [ent1Status, ent1] = await memberAsk(conn, "GET", `/admin/api/threads/${threadId}/entries`, undefined, servedHeaders);
  assert.equal(ent1Status, 200, JSON.stringify(ent1));
  const personMsgs = (ent1.entries as any[]).filter((e) => e.text === "hello via serve");
  assert.equal(personMsgs.length, 1, `no duplicate from idempotency retry: ${JSON.stringify(ent1.entries)}`);
  assert.ok((ent1.entries as any[]).some((e) => String(e.text ?? "").includes("posted by the fake")), JSON.stringify(ent1.entries));

  // PUT /admin/api/threads/:id/read (mark written in --serve, changes broadcast to store/events)
  const [readStatus, readSaid] = await memberAsk(conn, "PUT", `/admin/api/threads/${threadId}/read`, { n: msg1.n }, servedHeaders);
  assert.equal(readStatus, 200, JSON.stringify(readSaid));
  assert.equal(readSaid.n, msg1.n, JSON.stringify(readSaid));

  // ── kill one --serve child: auto-restarts and requests keep working without hanging ──
  const victim = initialServe[0]!;
  process.kill(victim, "SIGKILL");
  await until("killed --serve child exited", () => !alive(victim), tail);
  const recoveredServe = await until("killed --serve child automatically restarted", () => {
    const pids = serveChildrenOf(stationPid);
    // (its socket is made as the new child starts listening, after its pid is there to see)
    return pids.length === 2 && !pids.includes(victim) && serveSocks().length === 2 ? pids : null;
  }, tail);
  assert.deepEqual(serveSocks(), [`serve-${stationPid}-0.sock`, `serve-${stationPid}-1.sock`]);

  // Verify requests succeed on both existing and fresh connections after recovery
  const conn2 = await until("fresh connection after --serve restart", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")), tail);
  assert.equal((await member(conn2, credential)).ok, true);
  for (let i = 0; i < 4; i++) {
    const [st, body] = await memberAsk(conn2, "GET", "/admin/api/chats", undefined, servedHeaders);
    assert.equal(st, 200, `post-recovery GET /chats #${i}: ${JSON.stringify(body)}`);
  }

  // ── stop station: all --serve children and serve-*.sock files cleaned up ──
  const frontPid = Number(readFileSync(join(data, "run", "front.pid"), "utf8").trim() || "0");
  station.kill("SIGTERM");
  assert.equal(await ended, 0, tail());
  await until("station process gone", () => !alive(stationPid), tail);
  if (frontPid > 0) await until("front gone", () => !alive(frontPid), tail);
  for (const pid of recoveredServe) {
    await until(`--serve child ${pid} gone`, () => !alive(pid), tail);
  }
  assert.deepEqual(serveSocks(), [], "no serve-*.sock files left after stop");
});
