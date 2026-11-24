// The MoonBit station (`stillfail-reader`, no Node) under the real launcher, through the faults of the world around it:
// the control plane drops its presence socket and then answers 503 for a while (health.json says offline, then online
// again on the station's own backoff); Slack's Socket Mode socket closed by Slack, asked to refresh, and cut (its TCP
// gone), each time connected again with the next message of the same thread answered by the same session; connects
// whose tokens Slack refuses (`invalid_auth` on the socket's address, or on who the bot is) say so in their state,
// asked again only on a backoff, while the station goes on serving; members' devices whose credentials are refused
// (expired, signed by another key, of another workspace, of another device, not a credential) told why on real iroh
// and closed as `credential_refused`, not as the station stopping, while a member let in is served throughout; a
// handover (SIGUSR2) that closes the connections the station before served at once, with the same front's endpoint
// taking the devices' connections again; and a stop that closes every connection served, at once, not on the
// other end's idle timeout. As src/mesh/door.ts, src/mesh/accept.ts, src/mesh/front.ts and src/connects/surface.ts
// hold them for the TypeScript station (mesh-lines, door, accept, front-bind-race, mesh-handover, connect-refusal).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer as netServer } from "node:net";
import { createServer as httpServer, request } from "node:http";
import { createSocket } from "node:dgram";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, before, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { mbStationBinary } from "./mb-harness.ts";
import { loadMesh, type Connection, type Endpoint } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { GrantKey } from "./fake-control-plane.ts";

const binary = mbStationBinary();
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
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sff-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
after(async () => {
  for (const c of closers.splice(0)) {
    try { c(); } catch {}
  }
  for (const c of children.filter((c) => c.exitCode === null && c.signalCode === null)) c.kill("SIGKILL");
  // (what a run left: its processes, by what their files say)
  for (const d of dirs) {
    for (const f of ["run/station.json", "run/front.pid"]) {
      try {
        const text = readFileSync(join(d, f), "utf8");
        const pid = Number(text.trim().startsWith("{") ? JSON.parse(text).pid : text.trim());
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
  if (process.env.STATION_KEEP !== "1") for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// Looked at until `look` gives something (real processes: every 50 ms), or failing with `what` after `ms`.
async function until<T>(what: string, look: () => T | null | undefined | false | Promise<T | null | undefined | false>, detail: () => string = () => "", ms = 20_000): Promise<T> {
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

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

/// The control plane of the test's: its HTTP and its presence socket. `down` makes it answer 503 to the socket's
/// upgrade and 500 to its posts, as a plane being deployed does; each upgrade asked is counted, refused or not.
async function controlPlane(peers: unknown[]) {
  const sockets: WebSocket[] = [];
  const upgrades: { at: number; refused: boolean }[] = [];
  const state = { down: false };
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => {
      if (state.down) return void res.writeHead(500, { "content-type": "application/json" }).end('{"error":"internal"}');
      res.writeHead(200, { "content-type": "application/json" }).end("{}");
    });
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    upgrades.push({ at: Date.now(), refused: state.down });
    if (state.down) {
      const body = '{"error":"service unavailable"}';
      socket.end(`HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\ncontent-length: ${body.length}\r\nconnection: close\r\n\r\n${body}`);
      return;
    }
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
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, sockets, upgrades, state };
}

/// Slack, of the test's, for three apps: `xoxb-1`/`xapp-1` a good one; `xapp-bad`'s socket address refused
/// (`invalid_auth`); `xoxb-bad`, the bot's token, refused as who the bot is is asked.
async function slackStandIn() {
  const asked: { m: string; auth: string; form: Record<string, string>; at: number }[] = [];
  const sockets: WebSocket[] = [];
  const acks: string[] = [];
  const server = httpServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const text = Buffer.concat(chunks).toString();
    const form = (req.headers["content-type"] ?? "").includes("json") ? JSON.parse(text || "{}") : Object.fromEntries(new URLSearchParams(text));
    const m = (req.url ?? "").split("?")[0]!.replace(/^\/api\//, "");
    const auth = String(req.headers.authorization ?? "");
    asked.push({ m, auth, form, at: Date.now() });
    const ok = (body: object) => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true, ...body }));
    const refused = (error: string) => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: false, error }));
    switch (m) {
      case "auth.test":
        if (auth === "Bearer xoxb-bad") return refused("invalid_auth");
        return auth === "Bearer xoxb-1"
          ? ok({ team: "Acme", team_id: "T1", url: "https://acme.slack.com/", user_id: "UB", user: "bot", bot_id: "BB" })
          : ok({ team: "Other", team_id: "T2", url: "https://other.slack.com/", user_id: "UB2", user: "bot2", bot_id: "BB2" });
      case "users.info":
        return ok({ user: { id: form.user, name: "ada", real_name: "Ada", profile: { display_name: "Ada", email: "ada@x.com", image_72: "https://a" } } });
      case "apps.connections.open":
        if (auth === "Bearer xapp-bad") return refused("invalid_auth");
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

/// A fake Claude Code (stream-json in and out, /bin/sh and curl alone): each prompt posts all_done to the thread it was
/// asked in, through the agents' door, naming the chat (so no turn of the station's own asks it a title). It answers
/// each line with a result of its own, which a real one does not for a message steered into its running turn: the
/// test gives it the next message only once its turns ended.
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
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/$sid-to"; else to=$(/bin/cat "$FAKE_OUT/$sid-to" 2>/dev/null); fi
  # (the message's tag, msg-<n>, said back: which message a post answers)
  tag=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*\\(msg-[0-9]*\\).*/\\1/p')
  call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"a Slack thread","text":"posted by the fake for '"$tag"'","kind":"all_done","done":"answered what it was sent"}}}' > "$FAKE_OUT/$sid-post-$n.json"
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
function ask(port: number, path: string): Promise<{ status: number; json: any }> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: "GET" }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => {
        let json: any = null;
        try { json = text === "" ? null : JSON.parse(text); } catch {}
        resolve({ status: res.statusCode!, json });
      });
    });
    req.on("error", reject);
    req.end();
  });
}

const ADMIN = Buffer.from("stillfail/admin/1");

/// A device's hello on a connection's first stream: what the station answers it.
async function hello(conn: Connection, credential: string) {
  const first = await conn.openBi();
  await first.write(Buffer.from(JSON.stringify({ credential, protocol: 2 }) + "\n"));
  return new Reader(first).line();
}

/// A member's request on the mesh, its status and JSON.
async function memberAsk(conn: Connection, method: string, path: string): Promise<[number, any]> {
  const stream = await conn.openBi();
  await stream.write(Buffer.from(JSON.stringify({ method, path, headers: { "content-type": "application/json" } }) + "\n"));
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  const rest = (await reader.rest()).toString();
  let json: any = rest;
  try { json = JSON.parse(rest || "null"); } catch {}
  return [head.status, json];
}

/// How a connection ended as its end is told, and how long after `since` that was; failing after `ms` (well under
/// QUIC's idle timeout of 30 s, which an end never told the other side comes to).
async function endOf(conn: Connection, since: number, ms = 10_000): Promise<{ closed: string; why: { kind: string; reason: string } | null; after: number }> {
  let timer: NodeJS.Timeout | undefined;
  const closed = await Promise.race([
    conn.closed(),
    new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`the connection not closed within ${ms} ms`)), ms); }),
  ]).finally(() => clearTimeout(timer));
  return { closed, why: conn.closeReason?.() ?? null, after: Date.now() - since };
}

// ── one station of a release with no Node, run under the real launcher, shared by the tests in their order ──

type Running = {
  id: string; data: string; meshPort: number; mcpPort: number; station: ChildProcess; ended: Promise<number | null>;
  grant: GrantKey; plane: Awaited<ReturnType<typeof controlPlane>>; slack: Awaited<ReturnType<typeof slackStandIn>>;
  tail: () => string; log: () => string; takenOver: () => number[];
  client: Endpoint; credential: (device: string, more?: Record<string, unknown>) => string;
};
let s: Running;

before(async () => {
  if (skip) return;
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
  const slack = await slackStandIn();
  const mcpPort = await freeTcpPort();
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] }, peers: [], revocations: [],
  }));
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "sk-ant-oat-test", expiresAt: Date.now() + 86_400_000 } }));
  const slackConnect = (cid: string, appToken: string, botToken: string) => ({
    id: cid, kind: "slack", mode: "multi-session", enabled: true, bind: { runtime: "claude", profile: "cc" }, createdBy: { id: "ada@x.com" }, slack: { appToken, botToken, appId: `A-${cid}` },
  });
  writeFileSync(join(data, "config.json"), JSON.stringify({
    language: "en",
    http: { port: mcpPort },
    profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", access: { kind: "subscription" } }],
    maxNudges: 0,
    connects: [slackConnect("c1", "xapp-1", "xoxb-1"), slackConnect("c-socket-refused", "xapp-bad", "xoxb-2"), slackConnect("c-bot-refused", "xapp-3", "xoxb-bad")],
  }));
  const env = {
    PATH: bin, HOME: data, TMPDIR: tmpdir(), FAKE_OUT: out,
    STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}`,
    STILLFAIL_SLACK_API: slack.base, STILLFAIL_ANTHROPIC_API: "http://127.0.0.1:9", STILLFAIL_AGENT_NICE: "0", STILLFAIL_HELD_EVERY_MS: "300",
  };
  const station = spawn(launcher, ["run", "--app", app, "--data", data], { stdio: ["ignore", "pipe", "pipe"], env });
  children.push(station);
  let said = "";
  station.stdout!.on("data", (d) => (said += d));
  station.stderr!.on("data", (d) => (said += d));
  const tail = () => said.slice(-4000);
  const ended = new Promise<number | null>((resolve) => station.on("exit", (code) => resolve(code)));
  const takenOver = () => [...said.matchAll(/Node (\d+) has taken over/g)].map((m) => Number(m[1]));
  await until("the station taken over", () => takenOver()[0], tail);
  await until("the agents' door", async () => (await ask(mcpPort, "/admin-api/host")).status === 200, tail);
  await until("presence online", () => readJson(join(data, "run", "health.json"))?.presenceOnline === true, tail);
  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  closers.push(() => void client.close());
  const credential = (device: string, more: Record<string, unknown> = {}) => {
    const now = Math.floor(Date.now() / 1000);
    return grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u1", email: "ada@x.com", name: "Ada", ws: "w1", role: "owner", device, sid: "s1", iat: now, exp: now + 3600, ...more });
  };
  s = { id, data, meshPort, mcpPort, station, ended, grant, plane, slack, tail, log: () => said, takenOver, client, credential };
});

const dial = (e: Endpoint) => until("connected on the mesh", () => e.connect({ id: s.id, ips: [`127.0.0.1:${s.meshPort}`] }, ADMIN), s.tail);
const overview = () => ask(s.mcpPort, "/admin-api/overview");
/// The connects as the overview said them last (what a wait that failed shows).
let seenConnects: unknown = null;
const connectionOf = async (cid: string) => {
  seenConnects = (await overview()).json?.connects ?? [];
  return (seenConnects as any[]).find((c: any) => c.id === cid)?.connection;
};
const connectsSaid = () => `${JSON.stringify(seenConnects)}; ${s.tail()}`;

test("members' devices whose credentials are refused are told why on real iroh and closed as refused, not as the station stopping, while a member let in is served throughout", { skip, timeout: 60_000 }, async () => {
  // a member let in first, served before, between and after the refusals
  const good = await dial(s.client);
  const welcome = await hello(good, s.credential(s.client.id()));
  assert.equal(welcome.ok, true, JSON.stringify(welcome));
  assert.equal((await memberAsk(good, "GET", "/admin/api/overview"))[0], 200);

  const other = new GrantKey("k1");
  const now = Math.floor(Date.now() / 1000);
  const cases: [string, (device: string) => string, RegExp][] = [
    ["expired", (d) => s.credential(d, { iat: now - 7200, exp: now - 60 }), /credential expired/],
    ["signed by a key not the workspace's (same kid)", (d) => other.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u1", email: "ada@x.com", ws: "w1", role: "owner", device: d, sid: "s1", iat: now, exp: now + 3600 }), /credential signature invalid/],
    ["of another workspace", (d) => s.credential(d, { ws: "w2" }), /another workspace/],
    ["of another device", () => s.credential("f".repeat(64)), /another device/],
    ["not a credential", () => "not-a-jwt", /malformed credential/],
  ];
  const strangers = await Promise.all(cases.map(async () => {
    const e = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
    closers.push(() => void e.close());
    return e;
  }));
  // all at once, beside the member's own requests
  const [results, [beside]] = await Promise.all([
    Promise.all(cases.map(async ([what, make, words], i) => {
      const e = strangers[i]!;
      const conn = await dial(e);
      const since = Date.now();
      const refusal = await hello(conn, make(e.id()));
      const end = await endOf(conn, since);
      return { what, words, refusal, end };
    })),
    memberAsk(good, "GET", "/admin/api/overview"),
  ]);
  assert.equal(beside, 200, "the member served while the others were refused");
  for (const r of results) {
    assert.notEqual(r.refusal.ok, true, `${r.what}: ${JSON.stringify(r.refusal)}`);
    assert.match(String(r.refusal.error), r.words, `${r.what}: ${JSON.stringify(r.refusal)}`);
    // closed by the station for the refusal (door.mbt: code 1, `credential_refused`), soon after its line
    assert.deepEqual(r.end.why, { kind: "application", reason: "credential_refused" }, `${r.what}: ${JSON.stringify(r.end)}`);
    assert.doesNotMatch(r.end.closed, /stopping/, `${r.what}: ${JSON.stringify(r.end)}`);
    assert.ok(r.end.after < 5_000, `${r.what} closed ${r.end.after} ms after its hello`);
  }
  // the member's connection untouched by all that, and the station still the same process, serving
  assert.equal(good.isClosed(), false);
  const [st, ov] = await memberAsk(good, "GET", "/admin/api/overview");
  assert.equal(st, 200, JSON.stringify(ov).slice(0, 300));
  assert.equal(s.takenOver().length, 1, s.tail());
  good.close(0, "done");
});

test("the control plane's presence socket closed, then the plane answering 503: the station says it offline, asks again on its backoff, and is online again once the plane is up", { skip, timeout: 60_000 }, async () => {
  const health = () => readJson(join(s.data, "run", "health.json"));
  const presence = () => readJson(join(s.data, "run", "presence.json"));
  // ── closed by the plane (going away): connected again ──
  const before = s.plane.sockets.length;
  for (const ws of s.plane.sockets) ws.close(1001, "going away");
  await until("a new presence socket", () => s.plane.sockets.length > before, s.tail);
  await until("presence.json online again", () => presence()?.online === true, () => `${JSON.stringify(presence())}; ${s.tail()}`);

  // ── the plane down (503 to the socket, 500 to its posts) and the socket cut: offline, asked again, online once up ──
  s.plane.state.down = true;
  const asked = s.plane.upgrades.length;
  for (const ws of s.plane.sockets) ws.terminate();
  await until("the socket asked again while the plane is down, and refused", () => s.plane.upgrades.slice(asked).some((u) => u.refused), s.tail);
  const offline = await until("presence.json offline, saying the plane's 503", () => {
    const p = presence();
    return p?.online === false && /503/.test(String(p.error)) ? p : null;
  }, () => `${JSON.stringify(presence())}; ${s.tail()}`);
  assert.equal(offline.conflict ?? false, false, JSON.stringify(offline));
  // (health.json's presenceOnline is the plane's roster still taken as reached: it holds for the roster's grace,
  // ROSTER_GRACE_MS, a minute, as the TypeScript's `plane.state.reached` does, so seconds of a plane's restart are not
  // shown as the station cut off)
  assert.equal(health()?.presenceOnline, true, JSON.stringify(health()));
  // the station still answers while its plane is down
  assert.equal((await ask(s.mcpPort, "/admin-api/host")).status, 200);
  const sockets = s.plane.sockets.length;
  s.plane.state.down = false;
  await until("a presence socket once the plane is up", () => s.plane.sockets.length > sockets, s.tail);
  await until("presence.json online after the outage, its error cleared", () => presence()?.online === true && presence().error === null, () => `${JSON.stringify(presence())}; ${s.tail()}`);
  await until("health.json presenceOnline after the outage", () => health()?.presenceOnline === true, () => `${JSON.stringify(health())}; ${s.tail()}`);
  // (no storm: refused upgrades a backoff apart, never more than a handful in the outage)
  const refused = s.plane.upgrades.filter((u) => u.refused);
  assert.ok(refused.length >= 1 && refused.length <= 3, `refused upgrades: ${refused.length}`);
  assert.equal(s.takenOver().length, 1, s.tail());
});

test("Slack's socket closed by Slack, asked to refresh, and cut: connected again each time, the next message of the same thread answered by the same session", { skip, timeout: 60_000 }, async () => {
  const slack = s.slack;
  const good = () => slack.asked.filter((x) => x.auth === "Bearer xapp-1" && x.m === "apps.connections.open").length;
  await until("the Slack socket open", () => slack.sockets.length >= 1 && good() >= 1, () => `${JSON.stringify(slack.asked.map((x) => x.m))}; ${s.tail()}`);
  const root = "1790000050.000100";
  const answers = (k: number) => slack.asked.filter((x) => (x.m === "chat.postMessage" || x.m === "chat.update") && x.form.thread_ts === root && (x.form.text ?? "").includes(`posted by the fake for msg-${k}`));
  const open = () => slack.sockets.filter((w) => w.readyState === w.OPEN).at(-1);
  const read = <T,>(sql: string): T[] => {
    const db = new DatabaseSync(join(s.data, "stillfail.db"), { readOnly: true });
    try {
      return db.prepare(sql).all() as T[];
    } finally { db.close(); }
  };
  const sessions = () => read<{ key: string }>("SELECT key FROM sessions WHERE connect = 'c1'").map((r) => r.key);
  // (each turn of the thread's session ended: the next message starts a turn of its own, not steered into one running)
  const idle = (turns: number) => until(`the thread's ${turns} turn(s) ended`, () => {
    const t = read<{ kind: string; ended_at: number | null }>("SELECT t.kind, t.ended_at FROM turns t JOIN sessions s ON s.key = t.session_key WHERE s.connect = 'c1'");
    return t.length >= turns && t.every((x) => x.ended_at !== null);
  }, s.tail);
  let n = 0;
  const say = async (ws: WebSocket, ts: string) => {
    n++;
    const envelope = `e${n}`;
    const event = n === 1
      ? { type: "app_mention", channel: "C1", user: "U1", text: "<@UB> hello from slack msg-1", ts, channel_type: "channel" }
      : { type: "app_mention", channel: "C1", user: "U1", text: `<@UB> again msg-${n}`, ts, thread_ts: root, channel_type: "channel" };
    ws.send(JSON.stringify({ type: "events_api", envelope_id: envelope, payload: { team_id: "T1", event } }));
    await until(`envelope ${envelope} acknowledged`, () => slack.acks.includes(envelope), s.tail);
    const k = n;
    await until(`msg-${k} answered in the thread`, () => answers(k).length >= 1, () => `${JSON.stringify(slack.asked.filter((x) => x.m.startsWith("chat.")).map((x) => x.form))}; ${s.tail()}`);
    await idle(k);
  };
  await say(open()!, root);
  const [session] = sessions();
  assert.ok(session !== undefined, "a session for the thread");

  const again = async (what: string, cut: (ws: WebSocket) => void) => {
    const ws = open()!;
    const before = slack.sockets.length;
    cut(ws);
    await until(`a socket again after ${what}`, () => slack.sockets.length > before && open() !== ws && open() !== undefined, () => `${JSON.stringify(slack.asked.map((x) => x.m))}; ${s.tail()}`);
    await until(`the connect connected after ${what}`, async () => (await connectionOf("c1"))?.state === "connected", connectsSaid);
    await say(open()!, `17900000${60 + n}.000100`);
  };
  await again("Slack closed it", (ws) => ws.close(1000, "bye"));
  await again("Slack asked for a refresh", (ws) => ws.send(JSON.stringify({ type: "disconnect", reason: "refresh_requested" })));
  await again("its TCP cut", (ws) => ws.terminate());

  // every message answered, in the one thread, by the one session
  for (let k = 1; k <= n; k++) assert.ok(answers(k).length >= 1, `msg-${k} answered`);
  assert.deepEqual(sessions(), [session], "the same session took every message of the thread");
  for (const e of ["e1", "e2", "e3", "e4"]) assert.equal(slack.acks.filter((a) => a === e).length >= 1, true, e);
  assert.equal(s.takenOver().length, 1, s.tail());
});

test("connects whose tokens Slack refuses (invalid_auth) say why in their state, asked again only on a backoff, while the station serves on", { skip, timeout: 60_000 }, async () => {
  const slack = s.slack;
  // the socket's address refused: the error said, asked again later on a backoff
  const socketAsks = () => slack.asked.filter((x) => x.m === "apps.connections.open" && x.auth === "Bearer xapp-bad");
  await until("the refused socket asked a third time", () => socketAsks().length >= 3, s.tail);
  const refusedSocket = await until("c-socket-refused's state says invalid_auth", async () => {
    const c = await connectionOf("c-socket-refused");
    return c !== undefined && /invalid_auth/.test(JSON.stringify(c)) ? c : null;
  }, connectsSaid);
  assert.notEqual(refusedSocket.state, "connected", JSON.stringify(refusedSocket));
  // the bot's token refused: said, and not asked over and over
  const botAsks = () => slack.asked.filter((x) => x.m === "auth.test" && x.auth === "Bearer xoxb-bad");
  const refusedBot = await until("c-bot-refused's state says invalid_auth", async () => {
    const c = await connectionOf("c-bot-refused");
    return c !== undefined && c.state === "error" && /invalid_auth/.test(JSON.stringify(c)) ? c : null;
  }, connectsSaid);
  assert.equal(refusedBot.state, "error", JSON.stringify(refusedBot));
  assert.equal(slack.asked.some((x) => x.m === "apps.connections.open" && x.auth === "Bearer xapp-3"), false, "no socket for a bot Slack refused");

  // the refused socket asked again a backoff apart that doubles (slack/surface.mbt `connect_loop`, from a second), not
  // in a loop; a refused bot is asked again only as the connects are brought in line with the config (a change of it
  // or of the plane's word, connections.mbt `apply` as connections.ts's), never on a timer of its own
  // each gap is checked against the schedule's floor, not the gap before it: start-up or CPU jitter only lengthens
  // gaps[0], never shortens gaps[1], so a ratio of measured gaps fails on scheduling alone
  const asks = socketAsks();
  const gaps = asks.slice(1).map((x, i) => x.at - asks[i]!.at);
  assert.ok(gaps.length >= 2, `expected at least two retry gaps: ${JSON.stringify(gaps)}`);
  for (let i = 0; i < gaps.length; i++) {
    const floor = Math.min(60_000, 1_000 * 2 ** i) * 0.8;
    assert.ok(gaps[i]! >= floor, `retry ${i} backed off below ${floor} ms: ${JSON.stringify(gaps)}`);
  }
  const bots = botAsks().length;
  assert.ok(bots >= 1);
  const quiet = Date.now();
  await until("a second of the station's own time", () => Date.now() - quiet >= 1_000 && socketAsks().length >= 3);
  assert.equal(botAsks().length, bots, `auth.test asked again for the refused bot with nothing changed: ${botAsks().length}`);
  // the good connect untouched by them, and the station the same process
  assert.equal((await connectionOf("c1"))?.state, "connected");
  assert.equal(s.takenOver().length, 1, s.tail());
});

test("a handover (SIGUSR2): the connections the station before served closed at once, the same front's endpoint taking devices again, old and new", { skip, timeout: 60_000 }, async () => {
  const front = Number(readFileSync(join(s.data, "run", "front.pid"), "utf8").trim() || "0");
  const old = await dial(s.client);
  assert.equal((await hello(old, s.credential(s.client.id()))).ok, true);
  assert.equal((await memberAsk(old, "GET", "/admin/api/overview"))[0], 200);
  const before = s.takenOver()[0]!;
  const since = Date.now();
  s.station.kill("SIGUSR2");
  const next = await until("the next process took over", () => s.takenOver().find((p) => p !== before), s.tail);
  // the connection the process before served: closed by it as it went, never left to the idle timeout
  const end = await endOf(old, since, 20_000);
  assert.equal(end.why?.kind, "application", JSON.stringify(end));
  await until("the process before gone", () => !alive(before), s.tail);
  assert.ok(alive(next));
  // the same front, its endpoint kept: no second bind of the mesh's port
  if (front > 0) assert.equal(Number(readFileSync(join(s.data, "run", "front.pid"), "utf8").trim()), front, "the front kept across the handover");
  assert.doesNotMatch(s.log(), /address already in use|Address in use|EADDRINUSE/i);
  // the same device dials again, and a new one, each served by the next process
  const again = await dial(s.client);
  assert.equal((await hello(again, s.credential(s.client.id()))).ok, true);
  const [st] = await memberAsk(again, "GET", "/admin/api/overview");
  assert.equal(st, 200);
  const newcomer = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  closers.push(() => void newcomer.close());
  const fresh = await dial(newcomer);
  assert.equal((await hello(fresh, s.credential(newcomer.id()))).ok, true);
  const [st2, ov] = await memberAsk(fresh, "GET", "/admin/api/overview");
  assert.equal(st2, 200, JSON.stringify(ov).slice(0, 300));
  assert.equal(newcomer.id() !== s.client.id(), true);
  fresh.close(0, "done");
  // presence and the Slack connect taken up by the next process
  await until("presence online under the next process", () => readJson(join(s.data, "run", "health.json"))?.presenceOnline === true, s.tail);
  await until("c1 connected under the next process", async () => (await connectionOf("c1"))?.state === "connected", s.tail);
});

test("a stop: every mesh connection served closed at once and told the other end, the launcher and its processes gone", { skip, timeout: 60_000 }, async () => {
  const conn = await dial(s.client);
  assert.equal((await hello(conn, s.credential(s.client.id()))).ok, true);
  assert.equal((await memberAsk(conn, "GET", "/admin/api/overview"))[0], 200);
  const station = s.takenOver().at(-1)!;
  const front = Number(readFileSync(join(s.data, "run", "front.pid"), "utf8").trim() || "0");
  const since = Date.now();
  s.station.kill("SIGTERM");
  const end = await endOf(conn, since, 20_000);
  assert.equal(end.why?.kind, "application", `told, not timed out: ${JSON.stringify(end)}`);
  assert.ok(end.after < 10_000, `closed ${end.after} ms after the stop`);
  assert.equal(await s.ended, 0, s.tail());
  await until("the station's process gone", () => !alive(station), s.tail);
  if (front > 0) await until("the front gone", () => !alive(front), s.tail);
});
