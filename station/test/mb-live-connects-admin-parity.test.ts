// Live parity tests for the pure MoonBit station (`stillfail-reader run` with no Node on PATH,
// `stillfail-runner`, fake `claude`, and `STILLFAIL_LOCAL_ADMIN=1`) covering:
// 1. Connects (Slack & Feishu) full lifecycle, overview connection state contract (#7392, #7378),
//    inbound routing -> fake claude turn -> chat_post delivery -> entries, chat_leave, and manual archive;
// 2. Admin API & GET /admin-api/overview full field structure contract (no missing fields, no i18n key leaks);
// 3. Presets CRUD + chat_create inheriting preset, MCP search across chat/message/job/skill, and
//    usage pricing/repricing from model catalog (#7366, #7281);
// 4. Station Move route & MCP tool contract on stable vs beta channels.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, createPublicKey, generateKeyPairSync, sign } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer as netServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { type WebSocket, WebSocketServer } from "ws";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { keepUsage } from "../src/usage/module.ts";
import { FakeFeishu } from "./feishu-fake.ts";

const binary = mbReaderBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32" ? "the launcher's descriptors are Unix's"
  : runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)"
  : !existsSync("/usr/bin/curl") ? "no /usr/bin/curl for the fake runtime"
  : false;

const dirs: string[] = [];
// Short paths so Unix sockets (runner, status.sock) stay within macOS's 104-byte limit.
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfca-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
after(async () => {
  for (const c of closers.splice(0)) c();
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (!existsSync(runners)) continue;
    for (const name of readdirSync(runners)) {
      if (!name.endsWith(".json")) continue;
      try {
        const info = JSON.parse(readFileSync(join(runners, name), "utf8"));
        if (typeof info.pgid === "number") try { process.kill(-info.pgid, "SIGKILL"); } catch {}
        if (typeof info.runner === "number") try { process.kill(info.runner, "SIGKILL"); } catch {}
      } catch {}
    }
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

const TOOLS = ["sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "wc", "uname"];
function binOf(name: string): string {
  const search = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"];
  for (const d of search) {
    const at = join(d, name);
    if (existsSync(at)) return at;
  }
  return "";
}
function toolsPath(): string {
  const dir = fresh("path");
  for (const t of TOOLS) {
    const found = binOf(t);
    if (found !== "" && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false);
  return dir;
}

/// Fake Claude Code CLI (pure /bin/sh + curl, no Node) that extracts `thread="..."` and posts `all_done`.
function installFakeClaude(binDir: string) {
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
  say '{"type":"system","subtype":"status","status":"requesting","session_id":"'"$sid"'"}'
  to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-$sid"; else to=$(/bin/cat "$FAKE_OUT/to-$sid" 2>/dev/null); fi
  /usr/bin/curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \\
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"Parity Thread","text":"posted by fake claude","kind":"all_done","done":"replied in thread"}}}' > "$FAKE_OUT/post-$sid-$n.json"
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"posted"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"posted"}'
done
`;
  writeFileSync(join(binDir, "claude"), claude);
  chmodSync(join(binDir, "claude"), 0o755);
}

const readJson = (p: string) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

async function given<T>(what: string, f: () => T | null | undefined | false | Promise<T | null | undefined | false>, detail: () => string = () => "", ms = 30_000): Promise<T> {
  const end = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > end) throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}; ${detail()}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

// ── Stand-ins: Slack (Web API + Socket Mode) & Control Plane (release feed + model catalog + presence) ──

type SlackAsked = { m: string; auth: string | null; form: Record<string, string> };
async function slackStandIn() {
  const asked: SlackAsked[] = [];
  const sockets: WebSocket[] = [];
  const acks: any[] = [];
  let postSeq = 1;
  const server = httpServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const form = Object.fromEntries(new URLSearchParams(Buffer.concat(chunks).toString()));
    const m = (req.url ?? "").split("?")[0]!.replace(/^\/api\//, "");
    asked.push({ m, auth: (req.headers.authorization as string | undefined) ?? null, form });
    const ok = (body: object) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, ...body }));
    };
    switch (m) {
      case "auth.test":
        return ok({ team: "Acme", team_id: "T1", url: "https://acme.slack.com/", user_id: "UB", user: "bot", bot_id: "BB" });
      case "users.info":
        return ok({ user: { id: form.user ?? "U42", name: "ada", profile: { display_name: "Ada", real_name: "Ada", email: "ada@example.test", image_72: "https://bot" } } });
      case "apps.connections.open":
        return ok({ url: `ws://127.0.0.1:${(server.address() as AddressInfo).port}/socket` });
      case "conversations.info":
        return ok({ channel: { id: form.channel, name: `name-${form.channel}` } });
      case "chat.postMessage":
        return ok({ channel: form.channel, ts: `800000${postSeq++}.000100`, message: { text: form.text } });
      case "chat.update":
        return ok({ channel: form.channel, ts: form.ts });
      default:
        return ok({});
    }
  });
  const wss = new WebSocketServer({ server, path: "/socket" });
  wss.on("connection", (ws) => {
    sockets.push(ws);
    ws.on("message", (raw) => {
      try {
        const msg = JSON.parse(String(raw));
        if (msg.envelope_id) acks.push(msg);
      } catch {}
    });
    ws.send(JSON.stringify({ type: "hello" }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  closers.push(() => {
    for (const c of wss.clients) c.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  const pushEvent = (envelopeId: string, event: Record<string, unknown>) => {
    const ws = sockets.at(-1);
    assert.ok(ws && ws.readyState === ws.OPEN, "Slack Socket Mode socket must be open");
    ws.send(JSON.stringify({
      type: "events_api",
      envelope_id: envelopeId,
      payload: { team_id: "T1", api_app_id: "A1", type: "event_callback", event },
    }));
  };
  return { base: `http://127.0.0.1:${(server.address() as AddressInfo).port}/api`, asked, sockets, acks, pushEvent };
}

const { privateKey } = generateKeyPairSync("ed25519");
const RAW_KEY = Buffer.from(createPublicKey(privateKey).export({ format: "jwk" }).x as string, "base64url").toString("base64");
const keyId = createHash("sha256").update(Buffer.from(RAW_KEY, "base64")).digest("hex").slice(0, 16);
const feedOf = (build: number) => {
  const words = Buffer.from(JSON.stringify({
    kind: "stillfail-station-release", version: `0.1.${build}`, build, commit: "0".repeat(40), node: "24.21.0",
    builds: { "darwin-arm64": { sha256: "a".repeat(64), size: 1000, nodeSha256: "b".repeat(64) }, "linux-x64": { sha256: "a".repeat(64), size: 1000, nodeSha256: "b".repeat(64) } },
  }));
  return { version: `0.1.${build}`, build, commit: "0".repeat(40), release: words.toString("base64"), signature: sign(null, words, privateKey).toString("base64"), key: keyId };
};

async function controlPlane(peers: unknown[] = []) {
  const asked: string[] = [];
  const sockets: WebSocket[] = [];
  const catalog = { etag: '"cat-1"', models: { "m-init": { name: "Init" } } as Record<string, unknown> };
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => {
      const url = req.url ?? "";
      asked.push(url);
      if (url === "/releases/station.json") return void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(feedOf(9500)));
      if (url === "/releases/station-beta.json") return void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(feedOf(9600)));
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
      ws.send(JSON.stringify({ type: "state", workspace: "w1", workspace_name: "团队", name: "mac", peers, relay_urls: [] }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  const push = (frame: unknown) => {
    for (const s of sockets) if (s.readyState === s.OPEN) s.send(JSON.stringify(frame));
  };
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, asked, sockets, catalog, push };
}

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string };

function makeStation(origin: string, config: object, peers: unknown[] = []): { data: string; app: string; id: string } {
  const data = fresh("data");
  const made = spawnSync(binary!, ["id", "--data", data], { env: { PATH: fresh("idpath"), HOME: data, TMPDIR: tmpdir() }, encoding: "utf8" });
  assert.equal(made.status, 0, made.stderr);
  const id = made.stdout.trim();
  const app = join(data, "app");
  mkdirSync(app, { recursive: true });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(app, "BUILD"), "9400\n");
  writeFileSync(join(data, "config.json"), `${JSON.stringify(config)}\n`);
  const allPeers = [{ id, name: "mac" }, ...peers];
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: {}, peers: allPeers, revocations: [],
  }));
  return { data, app, id };
}

async function launch(data: string, app: string, binDir: string, outDir: string, env: Record<string, string> = {}): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = netServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: {
      PATH: binDir,
      HOME: data,
      TMPDIR: tmpdir(),
      STILLFAIL_RUNNER: runner,
      STILLFAIL_HELD_EVERY_MS: "300",
      STILLFAIL_AGENT_NICE: "0",
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_LOCAL_ADMIN: "1",
      STILLFAIL_RELEASE_KEYS: RAW_KEY,
      STILLFAIL_ANTHROPIC_API: "http://127.0.0.1:9",
      FAKE_OUT: outDir,
      ...env,
    },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => {
    try { said.push(JSON.parse(line)); } catch {}
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) => given(what, () => said.find(ok), () => `said ${JSON.stringify(said)}; stderr ${err}`);
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

function ask(port: number, path: string, o: { method?: string; body?: unknown; headers?: Record<string, string> } = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({
      host: "127.0.0.1",
      port,
      path,
      method: o.method ?? (o.body === undefined ? "GET" : "POST"),
      headers: { "content-type": "application/json", ...(o.headers ?? {}) },
    }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text }));
    });
    req.on("error", reject);
    req.end(o.body === undefined ? undefined : typeof o.body === "string" ? o.body : JSON.stringify(o.body));
  });
}

async function mcpCall(port: number, token: string, method: string, params: unknown = {}): Promise<any> {
  const r = await ask(port, "/mcp", { body: { jsonrpc: "2.0", id: 1, method, params }, headers: { authorization: `Bearer ${token}` } });
  assert.equal(r.status, 200, r.body);
  return JSON.parse(r.body);
}

async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const res = await mcpCall(port, token, "tools/call", { name, arguments: args });
  assert.equal(res.error, undefined, JSON.stringify(res));
  return { text: res.result.content[0].text, error: res.result.isError === true };
}

// ── Test 1 & 2: Connects (Slack & Feishu) full lifecycle + Overview contract ──

test("connects (Slack & Feishu): overview state, inbound routing -> fake claude -> chat_post -> entries, chat_leave, manuallyArchived, and full GET /admin-api/overview contract", { skip }, async () => {
  const slack = await slackStandIn();
  const feishu = await FakeFeishu.start();
  closers.push(() => void feishu.close());
  const plane = await controlPlane();
  const binDir = toolsPath();
  installFakeClaude(binDir);
  const outDir = fresh("out");

  const { data, app } = makeStation(plane.origin, {
    language: "en",
    updateChannel: "stable",
    maxNudges: 1,
    profiles: [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc", models: ["claude-opus-5-5", "claude-sonnet-4-6"] }],
    connects: [
      { id: "c1", kind: "slack", enabled: true, bind: { runtime: "claude", profile: "cc" }, slack: { appToken: "xapp-1", botToken: "xoxb-1" } },
      { id: "f1", kind: "feishu", enabled: true, bind: { runtime: "claude", profile: "cc" }, feishu: { appId: "cli_test", appSecret: "sec-1", domain: "feishu" } },
      { id: "c-off", kind: "slack", enabled: false, bind: { runtime: "claude" }, slack: { appToken: "xapp-off", botToken: "xoxb-off" } },
    ],
  });
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");

  const a = await launch(data, app, binDir, outDir, {
    STILLFAIL_SLACK_API: slack.base,
    STILLFAIL_FEISHU_API: feishu.base,
  });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp door", (m) => m.serving === "mcp")).port as number;

  await given("Slack Socket Mode open", () => slack.sockets.length >= 1, a.err);
  await given("Feishu long connection open", () => feishu.sockets.length >= 1, a.err);
  await given("presence online", () => readJson(join(data, "run", "presence.json"))?.online === true, a.err);

  // ── 1a. Overview connect state contract (#7392, #7378) ──
  const ov = await given("overview reports c1 and f1 connected and accounts ready", async () => {
    const r = await ask(door, "/admin-api/overview");
    if (r.status !== 200) return null;
    const j = JSON.parse(r.body);
    const byId = (cid: string) => (j.connects ?? []).find((x: any) => x.id === cid)?.connection?.state;
    return byId("c1") === "connected" && byId("f1") === "connected" && byId("c-off") === "disabled" && Array.isArray(j.profiles) && j.profiles.length > 0 ? j : null;
  }, a.err);

  // ── 2. Full GET /admin-api/overview contract (matching TS station/src/api/overview.ts) ──
  assert.ok(Array.isArray(ov.connects) && ov.connects.length === 3, JSON.stringify(ov.connects));
  for (const c of ov.connects) {
    assert.equal(typeof c.id, "string");
    assert.equal(typeof c.name, "string");
    assert.equal(typeof c.enabled, "boolean");
    assert.equal(typeof c.kind, "string");
    assert.equal(typeof c.mode, "string");
    assert.equal(typeof c.requireMention, "boolean");
    assert.equal(typeof c.bind, "object");
    assert.equal(typeof c.connection?.state, "string");
    assert.equal(typeof c.sessions, "number");
    assert.equal(typeof c.moves, "boolean");
  }
  assert.ok(Array.isArray(ov.profiles) && ov.profiles.some((p: any) => p.id === "cc"), JSON.stringify(ov.profiles));
  assert.equal(typeof ov.counts, "object");
  assert.equal(typeof ov.counts.sessions, "number");
  assert.equal(typeof ov.counts.running, "number");
  assert.equal(typeof ov.counts.warm, "number");
  assert.ok(Array.isArray(ov.features), JSON.stringify(ov.features));
  assert.equal(ov.features.includes("stationMove"), false, `stable station must not enable stationMove: ${JSON.stringify(ov.features)}`);
  assert.equal(typeof ov.archiving, "object");
  assert.equal(typeof ov.archiving.days, "number");
  assert.equal(typeof ov.archiving.slackDays, "number");
  assert.equal(typeof ov.archiving.reviewed, "boolean");
  assert.equal(typeof ov.archiving.canEdit, "boolean");
  assert.equal(typeof ov.automaticDecisions, "object");
  assert.ok(ov.automaticDecisions !== null, "automaticDecisions should be populated when accounts exist");
  assert.equal(typeof ov.automaticDecisions.canEditPolicy, "boolean");
  assert.equal(typeof ov.mesh, "object");
  assert.equal(ov.mesh.state, "running");
  assert.equal(ov.mesh.workspaceId, "w1");
  assert.equal(typeof ov.mesh.reached, "boolean");
  assert.equal(typeof ov.viewer, "object");
  assert.equal(ov.viewer.via, "mesh");
  assert.ok(Array.isArray(ov.updates), JSON.stringify(ov.updates));
  assert.ok(Array.isArray(ov.processes), JSON.stringify(ov.processes));
  assert.ok(ov.disk && typeof ov.disk.freeBytes === "number" && ov.disk.freeBytes > 0 && typeof ov.disk.totalBytes === "number", JSON.stringify(ov.disk));
  assert.ok(Array.isArray(ov.logins));
  assert.ok(Array.isArray(ov.apiProviders));
  assert.ok(Array.isArray(ov.machineLogins));
  assert.ok(Array.isArray(ov.rigs));
  for (const flag of ["sessionRuntimeChange", "connectRuntimeChange", "accountSubsets", "modelSpeeds", "claudeTui", "consoleSignIn", "sharing"]) {
    assert.equal(ov[flag], true, `overview.${flag} must be true`);
  }
  assert.ok(Array.isArray(ov.agentEnv), `overview.agentEnv must be an array: ${JSON.stringify(ov.agentEnv)}`);
  for (const obj of ["modelMakers", "contextCaps", "context", "diagnostics", "network", "drive", "search", "move"]) {
    assert.ok(ov[obj] !== null && typeof ov[obj] === "object" && !Array.isArray(ov[obj]), `overview.${obj} must be an object: ${JSON.stringify(ov[obj])}`);
  }
  // No untranslated station.* i18n key leaks in overview
  const ovRaw = JSON.stringify(ov);
  assert.doesNotMatch(ovRaw, /"station\.[a-z][a-zA-Z0-9._-]*"/, `untranslated i18n key leaked in overview: ${ovRaw}`);

  // ── 1b. Slack inbound -> auto-route -> fake claude -> chat_post -> mock Slack + entries ──
  slack.pushEvent("env-slack-1", {
    type: "app_mention",
    channel: "C1",
    user: "U42",
    ts: "1700000000.000100",
    text: "<@UB> hello from slack",
  });
  await given("Slack envelope acknowledged", () => slack.acks.some((x) => x.envelope_id === "env-slack-1"), a.err);
  const slackPost = await given(
    "Slack chat.postMessage from fake claude",
    () => slack.asked.find((x) => x.m === "chat.postMessage" && x.form.channel === "C1" && x.form.thread_ts === "1700000000.000100" && x.form.text?.includes("posted by fake claude")),
    () => `asked=${JSON.stringify(slack.asked.map((x) => [x.m, x.form]))}; stderr=${a.err()}`,
  );
  assert.equal(slackPost.auth, "Bearer xoxb-1");

  const slackKey = "c1:C1:1700000000.000100";
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    const slackSession = await given("Slack session turn completed", () => {
      const s = store.getSession(slackKey);
      const t = s ? store.lastTurn(slackKey) : null;
      return t && t.endedAt !== null ? { s, t } : null;
    }, a.err);
    assert.equal(slackSession.t.outcome, "completed");
    assert.equal(slackSession.t.ending, "all_done");

    const slackThread = store.threadAt("slack:T1", "C1", "1700000000.000100");
    assert.ok(slackThread !== null, "Slack thread recorded in store");
    const slackEntriesRes = await ask(door, `/admin-api/threads/${slackThread!.id}/entries`);
    assert.equal(slackEntriesRes.status, 200, slackEntriesRes.body);
    const slackEntries = JSON.parse(slackEntriesRes.body).entries as any[];
    assert.ok(slackEntries.some((e) => e.kind === "message" && e.authorKind === "person" && String(e.text).includes("hello from slack")), JSON.stringify(slackEntries));
    assert.ok(slackEntries.some((e) => e.kind === "message" && e.authorKind === "agent" && String(e.text).includes("posted by fake claude")), JSON.stringify(slackEntries));

    // ── 1c. Slack chat_leave -> subsequent normal thread message (no @) does NOT start a new turn ──
    const left = await tool(door, slackSession.s!.token, "chat_leave", { to: "C1/1700000000.000100" });
    assert.equal(left.error, false, left.text);
    slack.pushEvent("env-slack-after-leave", {
      type: "message",
      channel: "C1",
      user: "U42",
      thread_ts: "1700000000.000100",
      ts: "1700000005.000100",
      text: "just chatting after leave without mention",
    });
    await given("post-leave Slack event acknowledged", () => slack.acks.some((x) => x.envelope_id === "env-slack-after-leave"), a.err);
    // Give the station a brief window to route if it erroneously would, while verifying via a Feishu turn next.

    // ── 1d. Feishu inbound -> auto-route -> fake claude -> chat_post -> FakeFeishu + entries ──
    const feishuFrame = feishu.message({ id: "om_100", chat: "oc_g", user: "ou_ada", text: "hello from feishu", at: true });
    await given("Feishu inbound acknowledged", () => feishu.ack(feishuFrame) !== undefined, a.err);
    const feishuPost = await given(
      "Feishu outbound post from fake claude",
      () => feishu.seen.find((x) => (x.path === "/open-apis/im/v1/messages" || x.path.endsWith("/reply")) && x.method === "POST" && JSON.stringify(x.body).includes("posted by fake claude")),
      () => `seen=${JSON.stringify(feishu.seen.map((x) => [x.method, x.path, x.body]))}; stderr=${a.err()}`,
    );
    assert.equal(feishuPost.auth, "t-cli_test");

    const feishuSession = await given("Feishu session and completed turn", () => {
      const s = store.listSessions().find((x) => x.connect === "f1");
      if (!s) return null;
      const t = store.lastTurn(s.key);
      return t && t.endedAt !== null ? { s, t } : null;
    }, a.err);
    assert.equal(feishuSession.t.outcome, "completed");
    assert.equal(feishuSession.t.ending, "all_done");

    // Confirm Slack still only has 1 turn after the non-@ message post chat_leave
    assert.equal(store.listTurns(slackKey).length, 1, "Slack thread after chat_leave must not trigger a new turn on non-@ message");

    const feishuThread = store.sessionThreads(feishuSession.s.key)[0]?.thread;
    assert.ok(feishuThread !== undefined, "Feishu thread recorded in store");
    const feishuEntriesRes = await ask(door, `/admin-api/threads/${feishuThread!.id}/entries`);
    assert.equal(feishuEntriesRes.status, 200, feishuEntriesRes.body);
    const feishuEntries = JSON.parse(feishuEntriesRes.body).entries as any[];
    assert.ok(feishuEntries.some((e) => e.kind === "message" && e.authorKind === "person" && String(e.text).includes("hello from feishu")), JSON.stringify(feishuEntries));
    assert.ok(feishuEntries.some((e) => e.kind === "message" && e.authorKind === "agent" && String(e.text).includes("posted by fake claude")), JSON.stringify(feishuEntries));

    // ── 1e. Manual archive (manuallyArchived) -> follow-up message does NOT trigger new turn ──
    const archived = await ask(door, `/admin-api/sessions/${encodeURIComponent(feishuSession.s.key)}/archive`, { method: "POST", body: {} });
    assert.equal(archived.status, 200, archived.body);
    assert.equal(store.getSession(feishuSession.s.key)?.archivedBy, "manual");

    const feishuFrame2 = feishu.message({ id: "om_101", chat: "oc_g", user: "ou_ada", text: "after manual archive", at: true, parent: "om_100", root: "om_100" });
    await given("Feishu post-archive event acknowledged", () => feishu.ack(feishuFrame2) !== undefined, a.err);
    // Station notifies or ignores the archived thread, and MUST NOT start a second turn.
    await given(
      "archived notice sent or processed",
      () => feishu.seen.filter((x) => (x.path === "/open-apis/im/v1/messages" || x.path.endsWith("/reply")) && x.method === "POST").length >= 2 || store.getSession(feishuSession.s.key)?.archivedBy === "manual",
      a.err,
    );
    assert.equal(store.listTurns(feishuSession.s.key).length, 1, "manually archived thread must not receive follow-up turns");
  } finally {
    store.close();
  }

  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

// ── Test 3 & 4: Presets CRUD + Search multi-kind + Usage pricing/reprice + Station Move contract ──

test("presets CRUD + chat_create inheritance, MCP search across chat/message/job/skill, usage pricing/reprice (#7366, #7281), and station_move contract", { skip }, async () => {
  const peerId = "b".repeat(64);
  const plane = await controlPlane([{ id: peerId, name: "other" }]);
  const binDir = toolsPath();
  installFakeClaude(binDir);
  const outDir = fresh("out2");

  const { data, app } = makeStation(plane.origin, {
    language: "en",
    updateChannel: "stable",
    maxNudges: 1,
    profiles: [
      { id: "cc", name: "Claude", runtime: "claude", home: "homes/cc", models: ["claude-opus-5-5", "claude-sonnet-4-6"] },
      { id: "ag", name: "Agy", runtime: "agy", home: "homes/ag", models: ["gemini-4-carbon"] },
    ],
  }, [{ id: peerId, name: "other" }]);
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  mkdirSync(join(data, "homes", "ag"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");

  // Seed a skill for MCP search (kind: "skill")
  const skillDir = join(data, "agent", "skills", "obsidian-forge");
  mkdirSync(skillDir, { recursive: true });
  chmodSync(join(data, "agent", "skills"), 0o755);
  chmodSync(skillDir, 0o755);
  writeFileSync(join(skillDir, "SKILL.md"), "---\nname: obsidian-forge\ndescription: Obsidian forge ritual guide\n---\n\nUse obsidian-forge for deterministic builds.\n");
  chmodSync(join(skillDir, "SKILL.md"), 0o644);

  // Seed sessions, searchable chat/message, and usage calls (Gemini initially unpriced + Claude)
  const work = fresh("work");
  const seed = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  const now = Date.now();
  seed.insertSession({ key: "chat:c-main", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t-main", createdAt: now, lastActiveAt: now, title: "Quantum Zebra Chat" } as never);
  const mainThread = seed.openThread("ember", "CHAT", "1790000000.000001", "Quantum Zebra Chat", "ada@example.test");
  seed.joinThread(mainThread.id, "chat:c-main", "ember");
  seed.insertMessage({ thread: mainThread.id, ts: "1790000000.000002", author: "ada@example.test", authorKind: "person", text: "Unique pineapple nebula payload" });

  seed.insertSession({ key: "s-gem", connect: "ember", runtime: "agy", profile: "ag", workspace: work, token: "t-gem", createdAt: now, lastActiveAt: now } as never);
  seed.insertSession({ key: "s-cc", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t-cc", createdAt: now, lastActiveAt: now } as never);
  seed.recordUsage("/s-gem", { session: "s-gem", offset: 1, model: "gemini-4-carbon" }, "agy", [[{
    id: "call-gem-1", at: now, model: "gemini-4-carbon", subagent: false, fast: false,
    input: 1_000_000, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1_000_000, calls: 1, context: null, window: null,
  }, { turn: null, thread: null, person: "ada@example.test", profile: "ag" }]]);
  seed.recordUsage("/s-cc", { session: "s-cc", offset: 1, model: "claude-opus-5-5" }, "claude", [[{
    id: "call-cc-1", at: now, model: "claude-opus-5-5", subagent: false, fast: false,
    input: 1_000_000, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 0, calls: 1, context: null, window: null,
  }, { turn: null, thread: null, person: "ada@example.test", profile: "cc" }]]);
  keepUsage(seed, "s-gem", true);
  keepUsage(seed, "s-cc", true);
  seed.close();

  const a = await launch(data, app, binDir, outDir);
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp door", (m) => m.serving === "mcp")).port as number;
  await given("presence online", () => readJson(join(data, "run", "presence.json"))?.online === true, a.err);
  await given("initial catalog fetched", () => readJson(join(data, "model-catalog.json"))?.etag === '"cat-1"', a.err);

  // ── 3a. Presets CRUD via Admin API + chat_create inheritance ──
  const presetDir = fresh("proj");
  writeFileSync(join(presetDir, "AGENTS.md"), "# Preset Project\n");

  const createdRes = await ask(door, "/admin-api/presets", {
    method: "POST",
    body: {
      name: "Parity Preset",
      dirs: [presetDir],
      instructions: "Always run parity checks.",
      model: { model: "claude-opus-5-5", runtime: "claude", effort: "high" },
    },
  });
  assert.equal(createdRes.status, 200, createdRes.body);
  const createdPreset = JSON.parse(createdRes.body);
  assert.equal(createdPreset.name, "Parity Preset");
  assert.equal(createdPreset.instructions, "Always run parity checks.");
  assert.deepEqual(createdPreset.model, { model: "claude-opus-5-5", runtime: "claude", effort: "high" });

  const listRes = await ask(door, "/admin-api/presets");
  assert.equal(listRes.status, 200, listRes.body);
  const listedPresets = JSON.parse(listRes.body);
  assert.ok(Array.isArray(listedPresets.presets) && listedPresets.presets.some((p: any) => p.id === createdPreset.id), listRes.body);
  assert.ok(Array.isArray(listedPresets.candidates));
  assert.ok(Array.isArray(listedPresets.clones));

  const updatedRes = await ask(door, `/admin-api/presets/${createdPreset.id}`, {
    method: "PUT",
    body: {
      name: "Parity Preset Updated",
      dirs: [presetDir],
      instructions: "Updated parity instructions.",
      model: { model: "claude-opus-5-5", runtime: "claude", effort: "medium" },
    },
  });
  assert.equal(updatedRes.status, 200, updatedRes.body);
  const updatedPreset = JSON.parse(updatedRes.body);
  assert.equal(updatedPreset.name, "Parity Preset Updated");
  assert.equal(updatedPreset.instructions, "Updated parity instructions.");
  assert.equal(updatedPreset.model?.effort, "medium");

  // chat_create by preset name inherits preset's runtime/model/effort and copies preset into workspace
  const childRes = await tool(door, "t-main", "chat_create", {
    for: "me",
    key: "preset-inherited-child",
    text: "Run with preset",
    preset: "Parity Preset Updated",
  });
  assert.equal(childRes.error, false, childRes.text);
  const childKeyMatch = childRes.text.match(/its agent is (chat:[^\s.;)]+)/);
  assert.ok(childKeyMatch !== null, `chat_create must report created agent key: ${childRes.text}`);
  const childKey = childKeyMatch![1]!;

  const checkStore = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    const childRow = checkStore.getSession(childKey);
    assert.ok(childRow !== null, `created child session ${childKey} must exist`);
    assert.equal(childRow!.runtime, "claude");
    assert.equal(childRow!.model, "claude-opus-5-5");
    assert.equal(childRow!.effort, "medium");
    const presetCopy = readJson(join(childRow!.workspace, ".stillfail-preset.json")) ?? readJson(join(childRow!.workspace, "..", "preset.json"));
    assert.ok(presetCopy !== null, `preset copy must be written for ${childKey} (workspace=${childRow!.workspace})`);
    assert.equal(presetCopy.name, "Parity Preset Updated");
    assert.equal(presetCopy.instructions, "Updated parity instructions.");
  } finally {
    checkStore.close();
  }

  const deletedRes = await ask(door, `/admin-api/presets/${createdPreset.id}`, { method: "DELETE" });
  assert.equal(deletedRes.status, 200, deletedRes.body);
  assert.deepEqual(JSON.parse(deletedRes.body), { ok: true });
  const afterDel = JSON.parse((await ask(door, "/admin-api/presets")).body);
  assert.equal(afterDel.presets.some((p: any) => p.id === createdPreset.id), false, "deleted preset must not remain in list");

  // ── 3b. MCP search across kinds: chat, message, job, skill ──
  const jobStarted = await tool(door, "t-main", "job_start", { name: "cobalt-quartz-worker", command: "echo cobalt-ready" });
  assert.equal(jobStarted.error, false, jobStarted.text);
  const jobObj = JSON.parse(jobStarted.text);

  const searchChat = await tool(door, "t-main", "search", { query: "Quantum Zebra", kinds: ["chat"] });
  assert.equal(searchChat.error, false, searchChat.text);
  assert.match(searchChat.text, /### chat/);
  assert.match(searchChat.text, /Quantum Zebra Chat/);
  assert.match(searchChat.text, /\/o\/w1\//);

  const searchMsg = await tool(door, "t-main", "search", { query: "pineapple nebula", kinds: ["message"] });
  assert.equal(searchMsg.error, false, searchMsg.text);
  assert.match(searchMsg.text, /### message/);
  assert.match(searchMsg.text, /Unique pineapple nebula payload/);
  assert.match(searchMsg.text, /\/o\/w1\//);

  const searchJob = await tool(door, "t-main", "search", { query: "cobalt-quartz-worker", kinds: ["job"] });
  assert.equal(searchJob.error, false, searchJob.text);
  assert.match(searchJob.text, /### job/);
  assert.match(searchJob.text, new RegExp(`job ${jobObj.id}`));

  const searchSkill = await tool(door, "t-main", "search", { query: "Obsidian forge", kinds: ["skill"] });
  assert.equal(searchSkill.error, false, searchSkill.text);
  assert.match(searchSkill.text, /### skill/);
  assert.match(searchSkill.text, /obsidian-forge/);
  assert.match(searchSkill.text, /skill_read/);

  // ── 3c. Usage pricing & reprice from model catalog (#7366, #7281) ──
  const allRuntimes = { "stillfail-runtimes": "claude,codex,dsh,grok,cursor,devin,hermes,agy,pi" };
  const gemBeforeRes = await ask(door, "/admin-api/sessions/s-gem", { headers: allRuntimes });
  assert.equal(gemBeforeRes.status, 200, gemBeforeRes.body);
  const gemBefore = JSON.parse(gemBeforeRes.body)?.session?.usage;
  assert.equal(gemBefore?.cost, 0, `s-gem should start unpriced: ${gemBeforeRes.body}`);
  assert.equal(gemBefore?.unpricedCalls, 1, JSON.stringify(gemBefore));

  const usageBefore = JSON.parse((await ask(door, "/admin-api/usage")).body);
  assert.equal(usageBefore.rows.find((r: any) => r.model === "gemini-4-carbon")?.cost, null);
  assert.equal(usageBefore.rows.find((r: any) => r.model === "claude-opus-5-5")?.cost, 4);

  // Push model catalog update with Gemini + Claude prices
  plane.catalog.etag = '"cat-2"';
  plane.catalog.models = {
    "gemini-4-carbon": { name: "Gemini 4 Carbon", cost: { input: 2, output: 10, cacheRead: 0.1 } },
    "claude-opus-5-5": { name: "Claude Opus 5.5", cost: { input: 4, output: 20, cacheRead: 0.4 } },
  };
  plane.push({ type: "models", etag: '"cat-2"' });
  await given("model-catalog.json updated to cat-2", () => readJson(join(data, "model-catalog.json"))?.etag === '"cat-2"', a.err);

  // Usage page prices Gemini (1M input * $2 + 1M output * $10 = $12) and Claude (1M input * $4 = $4)
  const usageAfter = await given("GET /admin-api/usage prices Gemini accurately", async () => {
    const r = await ask(door, "/admin-api/usage");
    if (r.status !== 200) return null;
    const j = JSON.parse(r.body);
    const gem = j.rows?.find((x: any) => x.model === "gemini-4-carbon");
    const cc = j.rows?.find((x: any) => x.model === "claude-opus-5-5");
    return gem?.cost === 12 && cc?.cost === 4 ? j : null;
  }, a.err);
  assert.equal(usageAfter.rows.find((r: any) => r.model === "gemini-4-carbon")?.cost, 12);
  assert.equal(usageAfter.rows.find((r: any) => r.model === "claude-opus-5-5")?.cost, 4);

  // Main-process session_usage repriced automatically (#7366)
  const gemAfter = await given("s-gem session_usage repriced to $12 with unpricedCalls=0", async () => {
    const r = await ask(door, "/admin-api/sessions/s-gem", { headers: allRuntimes });
    if (r.status !== 200) return null;
    const u = JSON.parse(r.body)?.session?.usage;
    return u?.cost === 12 && u?.unpricedCalls === 0 ? u : null;
  }, a.err);
  assert.equal(gemAfter.cost, 12);
  assert.equal(gemAfter.unpricedCalls, 0);

  // ── 4. Station Move route & MCP tool contract (stable refused vs beta enabled) ──
  const listTools = async () => (await mcpCall(door, "t-main", "tools/list")).result.tools.map((t: any) => t.name as string);

  // On stable channel: station_move not offered, POST /admin-api/move refused (409)
  assert.equal((await listTools()).includes("station_move"), false, "station_move must not be offered on stable");
  const ovStable = JSON.parse((await ask(door, "/admin-api/overview")).body);
  assert.equal(ovStable.move?.offered, false);
  const moveRefused = await ask(door, "/admin-api/move", { method: "POST", body: { to: "other", all: true } });
  assert.equal(moveRefused.status, 409, `POST /admin-api/move must be refused on stable: ${moveRefused.body}`);

  // Switch to beta channel via run/channel-ask + hup
  writeFileSync(join(data, "run", "channel-ask"), "beta\n");
  a.tell({ op: "hup" });
  await given("channel switched to beta", () => existsSync(join(data, "run", "channel-answer")), a.err);
  assert.equal(readFileSync(join(data, "run", "channel-answer"), "utf8"), "ok beta\n");

  assert.equal((await listTools()).includes("station_move"), true, "station_move must be offered on beta");
  const ovBeta = JSON.parse((await ask(door, "/admin-api/overview")).body);
  assert.equal(ovBeta.move?.offered, true);
  assert.ok(Array.isArray(ovBeta.features) && ovBeta.features.includes("stationMove"), JSON.stringify(ovBeta.features));

  // Admin API GET /admin-api/move?to=<peer>
  const movePlanApi = await ask(door, `/admin-api/move?to=${peerId}`);
  assert.equal(movePlanApi.status, 200, movePlanApi.body);
  const planBody = JSON.parse(movePlanApi.body);
  assert.equal(planBody.ws, "w1");
  assert.equal(planBody.to, peerId);
  assert.ok(Array.isArray(planBody.modules) && planBody.modules.length > 0, movePlanApi.body);
  for (const mod of planBody.modules) {
    assert.equal(typeof mod.id, "string");
    assert.ok(Array.isArray(mod.needs));
    assert.equal(typeof mod.done, "number");
    assert.equal(typeof mod.total, "number");
    assert.equal(typeof mod.cannot, "number");
    assert.ok(Array.isArray(mod.items));
  }
  assert.ok(Array.isArray(planBody.stopped));

  // MCP station_move plan & status summary structure
  const movePlanTool = await tool(door, "t-main", "station_move", { action: "plan", to: "other" });
  assert.equal(movePlanTool.error, false, movePlanTool.text);
  const planToolJson = JSON.parse(movePlanTool.text);
  assert.equal(typeof planToolJson.say, "string");
  assert.equal(typeof planToolJson.summary, "object");
  assert.equal(typeof planToolJson.summary.items, "number");
  assert.equal(typeof planToolJson.summary.modules, "object");
  assert.ok(planToolJson.summary.modules.chats !== undefined, JSON.stringify(planToolJson.summary.modules));
  assert.equal(typeof planToolJson.summary.modules.chats.here, "number");
  assert.equal(typeof planToolJson.summary.modules.chats.cannot, "number");
  assert.ok(Array.isArray(planToolJson.summary.cannot));
  assert.ok(Array.isArray(planToolJson.summary.wouldStop));
  assert.ok(Array.isArray(planToolJson.summary.lent));
  assert.ok(Array.isArray(planToolJson.summary.stopped));
  // room space stats object when present
  if (planToolJson.summary.room !== undefined) {
    assert.equal(typeof planToolJson.summary.room, "object");
  }

  const moveStatusTool = await tool(door, "t-main", "station_move", { action: "status", to: "other" });
  assert.equal(moveStatusTool.error, false, moveStatusTool.text);
  const statusToolJson = JSON.parse(moveStatusTool.text);
  assert.equal(typeof statusToolJson.say, "string");
  assert.equal(typeof statusToolJson.summary, "object");
  assert.equal(typeof statusToolJson.summary.modules, "object");
  assert.ok(Array.isArray(statusToolJson.summary.cannot));

  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});
