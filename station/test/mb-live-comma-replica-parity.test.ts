// Live parity tests for the pure MoonBit station (`stillfail-reader run` with no Node on PATH,
// `stillfail-runner`, fake `claude`, and `STILLFAIL_LOCAL_ADMIN=1`) covering four previously
// uncovered live business domains:
// 1. Comma channel end-to-end closed loop: outbound WS connect to local mock Comma server,
//    task.invite -> task.put -> fake claude turn -> task.post reply + declared state,
//    disconnect/reconnect re-sync (task.hello + stats.index/task.index + post-reconnect task.put),
//    and task.read / task.say / task.leave.
// 2. Cold storage packing (`--builder packed`) & footprint measurement (`--builder footprint`)
//    live closed loop: archive session -> rebuildable cleanup + workspace.tar.zst + transcript.zst,
//    archived history & uploaded file read routes while cold, footprint accuracy, and clean wake/restore
//    with continuation turn.
// 3. Replica export/restore + two-station live `station_move` closed loop over real iroh mesh:
//    replica export & cross-station copy + restore consistency into a fresh station; two pure MoonBit
//    stations on beta channel executing `station_move` (plan -> move single chat -> readable &
//    continuable on target -> move back -> history preserved on source).
// 4. Accounts admin routes & model catalog live closed loop: `/admin-api/profiles` CRUD, secret
//    masking, enable/disable, default model switching, `/admin-api/stars` merge & persistence across
//    restart, and `/v1/models` catalog propagation into overview.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createSocket } from "node:dgram";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer as netServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { type WebSocket, WebSocketServer } from "ws";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";

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
// Short paths so Unix sockets (runner, status.sock) stay within macOS's 104-byte limit.
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfcr-${what}-`));
  dirs.push(dir);
  return dir;
};

const children: ChildProcess[] = [];
const closers: (() => void)[] = [];

after(async () => {
  for (const c of closers.splice(0)) {
    try {
      c();
    } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(
      left.map((c) =>
        c.exitCode === null && c.signalCode === null
          ? new Promise<void>((r) => c.once("exit", () => r()))
          : undefined,
      ),
    ),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (!existsSync(runners)) continue;
    for (const name of readdirSync(runners)) {
      if (!name.endsWith(".json")) continue;
      try {
        const info = JSON.parse(readFileSync(join(runners, name), "utf8"));
        if (typeof info.pgid === "number") {
          try {
            process.kill(-info.pgid, "SIGKILL");
          } catch {}
        }
        if (typeof info.runner === "number") {
          try {
            process.kill(info.runner, "SIGKILL");
          } catch {}
        }
      } catch {}
    }
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

const TOOLS = [
  "sh",
  "ps",
  "mv",
  "cat",
  "curl",
  "sleep",
  "echo",
  "printf",
  "env",
  "git",
  "ls",
  "find",
  "sort",
  "rm",
  "mkdir",
  "cp",
  "dirname",
  "basename",
  "sed",
  "tr",
  "head",
  "wc",
  "uname",
];

function binOf(name: string): string {
  const search = [
    ...(process.env.PATH ?? "").split(":").filter((d) => d !== ""),
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
    "/usr/local/bin",
    "/opt/homebrew/bin",
  ];
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
  assert.equal(existsSync(join(dir, "node")), false, "no Node on PATH");
  return dir;
}

/// Fake Claude Code CLI (pure /bin/sh + curl, no Node) that extracts `thread="..."` and posts `all_done`.
function installFakeClaude(binDir: string, replyPrefix = "fake-claude-reply") {
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
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"Live Parity Chat","text":"${replyPrefix}-'"$n"'","kind":"all_done","done":"replied turn '"$n"'"}}}' > "$FAKE_OUT/post-$sid-$n.json"
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"posted"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"posted"}'
done
`;
  writeFileSync(join(binDir, "claude"), claude);
  chmodSync(join(binDir, "claude"), 0o755);
}

async function given<T>(
  what: string,
  f: () => T | null | undefined | false | Promise<T | null | undefined | false>,
  detail: () => string | Promise<string> = () => "",
  ms = 40_000,
): Promise<T> {
  const end = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > end) {
      throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}; ${await detail()}`);
    }
    await new Promise((r) => setTimeout(r, 50));
  }
}

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

type Launched = {
  child: ChildProcess;
  door: number;
  said: any[];
  tell: (m: unknown) => void;
  stop: () => Promise<void>;
  err: () => string;
};

async function launchStation(
  data: string,
  app: string,
  binDir: string,
  outDir: string,
  env: Record<string, string> = {},
): Promise<Launched> {
  const listener = () =>
    new Promise<Server>((resolve) => {
      const s = netServer();
      s.listen(0, "127.0.0.1", () => resolve(s));
    });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(
    binary!,
    ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"],
    {
      stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
      env: {
        PATH: binDir,
        HOME: fresh("home"),
        TMPDIR: tmpdir(),
        FAKE_OUT: outDir,
        STILLFAIL_RUNNER: runner,
        STILLFAIL_LOCAL_ADMIN: "1",
        STILLFAIL_NO_DISCOVERY: "1",
        STILLFAIL_AGENT_NICE: "0",
        STILLFAIL_HELD_EVERY_MS: "200",
        ...env,
      },
    },
  );
  children.push(child);
  mcp.close();
  loop.close();

  const said: any[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => {
    try {
      said.push(JSON.parse(line));
    } catch {}
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));

  await given("station ready", () => said.some((m) => m.ready === true), () => `said=${JSON.stringify(said)}; stderr=${err.slice(-2000)}`);
  const mcpMsg = await given("mcp door", () => said.find((m) => m.serving === "mcp"), () => `said=${JSON.stringify(said)}; stderr=${err.slice(-2000)}`);
  const door = mcpMsg.port as number;

  const stop = async () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    channel.write(`${JSON.stringify({ op: "stop" })}\n`);
    const code = await Promise.race([
      ended,
      new Promise<number | null>((r) => setTimeout(() => r(null), 15_000)),
    ]);
    if (code === null && child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
      await ended;
    }
  };

  return { child, door, said, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), stop, err: () => err };
}

function makeStationDir(config: object, build = "9700"): { data: string; app: string; id: string } {
  const data = fresh("data");
  const app = fresh("app");
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "BUILD"), `${build}\n`);
  const made = spawnSync(binary!, ["id", "--data", data], {
    env: { PATH: fresh("empty"), HOME: data, TMPDIR: tmpdir() },
    encoding: "utf8",
  });
  assert.equal(made.status, 0, made.stderr);
  const id = made.stdout.trim();
  assert.match(id, /^[0-9a-f]{64}$/);
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  writeFileSync(join(data, "config.json"), JSON.stringify(config));
  return { data, app, id };
}

function httpReq(
  port: number,
  path: string,
  o: { method?: string; body?: unknown; token?: string } = {},
): Promise<{ status: number; headers: Record<string, string | string[] | undefined>; text: string; json: any }> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = {};
    if (o.body !== undefined) headers["content-type"] = "application/json";
    if (o.token !== undefined) headers.authorization = `Bearer ${o.token}`;
    const req = request(
      {
        host: "127.0.0.1",
        port,
        path,
        method: o.method ?? (o.body === undefined ? "GET" : "POST"),
        headers,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (d) => chunks.push(d as Buffer));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json: any = null;
          try {
            json = text === "" ? null : JSON.parse(text);
          } catch {}
          resolve({ status: res.statusCode!, headers: res.headers, text, json });
        });
      },
    );
    req.on("error", reject);
    req.end(o.body === undefined ? undefined : JSON.stringify(o.body));
  });
}

function mcpCall(port: number, token: string, name: string, args: Record<string, unknown>) {
  return httpReq(port, "/mcp", {
    method: "POST",
    token,
    body: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } },
  });
}

// ── Mock Control Plane (presence WS + /v1/models catalog) ──

async function startControlPlane(opts: {
  workspace?: string;
  peers?: Array<{ id: string; name: string; ips?: string[] }>;
  models?: Record<string, unknown>;
} = {}) {
  const workspace = opts.workspace ?? "w1";
  const peers = opts.peers ?? [];
  const catalog = {
    etag: '"cat-v1"',
    models: opts.models ?? {
      "claude-opus-5-5": { name: "Claude Opus 5.5", provider: "anthropic", input: 15, output: 75 },
      "claude-sonnet-4-6": { name: "Claude Sonnet 4.6", provider: "anthropic", input: 3, output: 15 },
      "gpt-6.1-sol": { name: "GPT-6.1 Sol", provider: "openai", input: 5, output: 20 },
    },
  };
  const sockets: WebSocket[] = [];
  const askedUrls: string[] = [];

  const server = httpServer((req, res) => {
    const url = req.url ?? "";
    askedUrls.push(url);
    req.resume();
    req.on("end", () => {
      if (url.startsWith("/v1/models")) {
        res.writeHead(200, { "content-type": "application/json", etag: catalog.etag });
        res.end(JSON.stringify({ models: catalog.models }));
        return;
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
      const stationId = new URL(req.url ?? "/", "http://127.0.0.1").searchParams.get("station") ?? "";
      const me = peers.find((p) => p.id === stationId);
      ws.send(
        JSON.stringify({
          type: "state",
          workspace,
          workspace_name: "Parity Team",
          name: me?.name ?? "station",
          peers,
          relay_urls: [],
        }),
      );
    });
  });

  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });

  return {
    origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    sockets,
    askedUrls,
    catalog,
    push(msg: unknown) {
      const payload = JSON.stringify(msg);
      for (const s of sockets) if (s.readyState === 1) s.send(payload);
    },
  };
}

// ── Mock Comma Connector Server ──

async function startMockComma() {
  const sockets: WebSocket[] = [];
  const auths: string[] = [];
  const frames: any[] = [];
  const asked: any[] = [];
  const replies = new Map<string, any>();
  const statsHeld: { epoch: string | null; through: number; rows: Map<string, any> } = {
    epoch: null,
    through: 0,
    rows: new Map(),
  };
  const tasksHeld: { epoch: string | null; through: number; rows: Map<string, any> } = {
    epoch: null,
    through: 0,
    rows: new Map(),
  };
  let postSeq = 10;
  let reqSeq = 0;

  const applyIndexPage = (
    target: { epoch: string | null; through: number; rows: Map<string, any> },
    params: any,
  ) => {
    if (params && typeof params === "object" && typeof params.epoch === "string") {
      if (params.reset) target.rows.clear();
      if (Array.isArray(params.rows)) {
        for (const r of params.rows) {
          if (r.removed) target.rows.delete(r.key);
          else target.rows.set(r.key, r);
        }
      }
      target.epoch = params.epoch;
      if (typeof params.through === "number") {
        target.through = params.reset ? params.through : Math.max(target.through, params.through);
      }
    }
    return { epoch: target.epoch, through: target.through };
  };

  const server = httpServer((_req, res) => res.writeHead(404).end());
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    auths.push(String(req.headers.authorization ?? ""));
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (data) => {
        const f = JSON.parse(String(data));
        frames.push(f);
        if (f.type === "request") {
          asked.push(f);
          let result: any = {};
          if (f.method === "task.post") {
            result = { seq: ++postSeq };
          } else if (f.method === "stats.index") {
            result = applyIndexPage(statsHeld, f.params);
          } else if (f.method === "task.index") {
            result = applyIndexPage(tasksHeld, f.params);
          }
          ws.send(JSON.stringify({ id: f.id, type: "response", result }));
        } else if (f.type === "response" || f.type === "error") {
          replies.set(f.id, f);
        }
      });
      ws.send(JSON.stringify({ type: "connected", connector_run_id: `run_${sockets.length}`, device_id: "dev_1" }));
    });
  });

  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });

  const active = () => sockets.filter((s) => s.readyState === 1).at(-1) ?? null;

  return {
    base: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    sockets,
    auths,
    frames,
    asked,
    statsHeld,
    tasksHeld,
    active,
    posts: () => asked.filter((f) => f.method === "task.post").map((f) => f.params),
    hellos: () => asked.filter((f) => f.method === "task.hello").map((f) => f.params),
    async request(method: string, params: Record<string, unknown>) {
      const ws = active();
      assert.ok(ws !== null, "no active Comma WebSocket");
      const id = `req-${++reqSeq}`;
      ws.send(JSON.stringify({ id, type: "request", method, params }));
      return given(`Comma response for ${method} (${id})`, () => replies.get(id));
    },
  };
}

// ══════════════════════════════════════════════════════════════════════════════
// 1. Comma Channel End-to-End Closed Loop
// ══════════════════════════════════════════════════════════════════════════════

test(
  "Comma channel e2e: outbound connect, task.invite/put -> agent turn -> task.post, disconnect/reconnect re-sync, task.read/say/leave",
  { skip, timeout: 120_000 },
  async () => {
    const binDir = toolsPath();
    installFakeClaude(binDir, "comma-reply");
    const outDir = fresh("out");
    const comma = await startMockComma();
    const { data, app, id } = makeStationDir({
      language: "en",
      profiles: [
        {
          id: "cc",
          name: "Claude",
          runtime: "claude",
          home: "homes/cc",
          access: { kind: "anthropic-api", key: "sk-ant-comma-test-key" },
          models: ["claude-opus-5-5"],
        },
      ],
      connects: [],
      maxNudges: 1,
    });
    const plane = await startControlPlane({ workspace: "w1", peers: [{ id, name: "comma-host" }] });
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(
      join(data, "mesh", "cloud.json"),
      JSON.stringify({
        origin: plane.origin,
        station: id,
        workspace: "w1",
        workspace_name: "Parity Team",
        name: "comma-host",
        relay_url: "",
        relay_urls: [],
        grant_keys: null,
        peers: [{ id, name: "comma-host" }],
        revocations: [],
      }),
    );

    const st = await launchStation(data, app, binDir, outDir);
    try {
      // Wait for control plane presence online so workspace scope is active for task.read/stats.index.
      await given(
        "control plane socket connected",
        () => plane.sockets.length >= 1,
        () => st.err().slice(-2000),
      );

      // Invalid Comma connect line returns 400.
      const bad = await httpReq(st.door, "/admin-api/comma/connects", {
        method: "POST",
        body: { line: "not-a-valid-comma-line", bind: { runtime: "claude", profile: "cc" } },
      });
      assert.equal(bad.status, 400, bad.text);

      // Create Comma connect via admin API route.
      const created = await httpReq(st.door, "/admin-api/comma/connects", {
        method: "POST",
        body: {
          line: `comma ${comma.base} salix_conn_live_test_1234`,
          bind: { runtime: "claude", profile: "cc" },
        },
      });
      assert.equal(created.status, 200, `${created.text}\n${st.err().slice(-2000)}`);
      assert.equal(created.json.id, "comma");

      // Wait for outbound WS connect, auth header, metadata, task.hello, and index syncs.
      await given(
        "Comma WS connected and sent task.hello",
        () => comma.hellos().length >= 1,
        () => `sockets=${comma.sockets.length} asked=${JSON.stringify(comma.asked.map((a) => a.method))} err=${st.err().slice(-2000)}`,
      );
      assert.equal(comma.auths[0], "Bearer salix_conn_live_test_1234");
      const meta = comma.frames.find((f) => f.type === "metadata");
      assert.ok(meta, `missing metadata frame: ${JSON.stringify(comma.frames)}`);
      assert.equal(meta.capabilities.tasks, 2);

      // Overview reports comma: true and connect state "connected".
      await given(
        "overview reports comma connect connected",
        async () => {
          const ov = await httpReq(st.door, "/admin-api/overview");
          const c = ov.json?.connects?.find((x: any) => x.id === "comma");
          return ov.status === 200 && ov.json?.comma === true && c?.connection?.state === "connected" ? ov.json : null;
        },
        () => st.err().slice(-2000),
      );

      // Heartbeat echo works.
      comma.active()!.send(JSON.stringify({ type: "heartbeat" }));
      await given("heartbeat echoed", () => comma.frames.some((f) => f.type === "heartbeat"));

      // task.invite -> returns session & thread.
      const invited = await comma.request("task.invite", {
        task: "cnv_live_1",
        start: { requester: "u_ada", runtime: "claude" },
      });
      assert.equal(invited.type, "response", JSON.stringify(invited));
      const { session: taskSession, thread: taskThread } = invited.result;
      assert.ok(typeof taskSession === "string" && taskSession.startsWith("comma:TASK:"), JSON.stringify(invited.result));
      assert.ok(typeof taskThread === "string" && taskThread.startsWith("TASK/"), JSON.stringify(invited.result));

      // task.status before messages -> idle.
      const stIdle = await comma.request("task.status", { task: "cnv_live_1" });
      assert.equal(stIdle.result?.state, "idle", JSON.stringify(stIdle));

      // task.put -> inbound messages trigger fake claude turn -> chat_post -> task.post back to Comma!
      const put1 = await comma.request("task.put", {
        task: "cnv_live_1",
        through: 2,
        messages: [
          { seq: 1, author: { kind: "agent", id: "router", name: "Router" }, text: "Please inspect login" },
          {
            seq: 2,
            author: { kind: "person", id: "u_ada", name: "Ada", email: "ada@example.test" },
            text: "And run the check",
          },
        ],
      });
      assert.deepEqual(put1.result, { through: 2 }, JSON.stringify(put1));

      await given(
        "Comma received agent task.post reply",
        () => comma.posts().some((p) => p.task === "cnv_live_1" && typeof p.text === "string" && p.text.includes("comma-reply-1")),
        () => `posts=${JSON.stringify(comma.posts())} err=${st.err().slice(-2000)}`,
      );
      await given(
        "Comma received declared all_done state",
        () => comma.posts().some((p) => p.task === "cnv_live_1" && p.declared === "all_done"),
        () => `posts=${JSON.stringify(comma.posts())}`,
      );

      // Verify stats.index and task.index were pushed to Comma (and cover our chat).
      await given(
        "stats.index and task.index synced",
        () =>
          comma.asked.some((a) => a.method === "stats.index") &&
          comma.asked.some((a) => a.method === "task.index"),
        () => `asked=${JSON.stringify(comma.asked.map((a) => a.method))}`,
      );

      // Create an ordinary chat so we can also test task.read & task.say over the Comma WS.
      const madeChat = await httpReq(st.door, "/admin-api/sessions", {
        method: "POST",
        body: { runtime: "claude", profile: "cc" },
      });
      assert.equal(madeChat.status, 200, madeChat.text);
      const chatThreadId = String(madeChat.json.thread?.id ?? madeChat.json.thread?.thread?.id);
      const saidViaComma = await comma.request("task.say", {
        task: chatThreadId,
        text: "hello from comma router",
        key: "rk-1",
        requester_name: "RouterBot",
      });
      assert.equal(saidViaComma.type, "response", JSON.stringify(saidViaComma));
      const readViaComma = await comma.request("task.read", {
        task: chatThreadId,
        after: 0,
        limit: 20,
      });
      assert.equal(readViaComma.type, "response", JSON.stringify(readViaComma));
      assert.ok(
        Array.isArray(readViaComma.result?.messages) &&
          readViaComma.result.messages.some((m: any) => m.text === "hello from comma router"),
        JSON.stringify(readViaComma.result),
      );

      // ── Disconnect & Reconnect: verify automatic reconnect, task.hello carries `through`, and new turn succeeds ──
      const socketsBefore = comma.sockets.length;
      const hellosBefore = comma.hellos().length;
      comma.active()!.close(1001, "simulated drop");

      await given(
        "Comma station reconnected and sent task.hello again",
        () => comma.sockets.length > socketsBefore && comma.hellos().length > hellosBefore,
        () => `sockets=${comma.sockets.length} hellos=${comma.hellos().length} err=${st.err().slice(-2000)}`,
      );
      const helloAfter = comma.hellos().at(-1);
      const knownTask = helloAfter?.tasks?.find((t: any) => t.task === "cnv_live_1");
      assert.ok(knownTask !== undefined, `reconnected task.hello missing cnv_live_1: ${JSON.stringify(helloAfter)}`);
      assert.equal(knownTask.fetched, 2, JSON.stringify(knownTask));

      // Post-reconnect task.put (simulating held/missed message delivery after reconnect) runs turn 2!
      const put2 = await comma.request("task.put", {
        task: "cnv_live_1",
        through: 12,
        messages: [
          { seq: 12, author: { kind: "person", id: "u_ada", name: "Ada" }, text: "after reconnect message" },
        ],
      });
      assert.deepEqual(put2.result, { through: 12 }, JSON.stringify(put2));
      await given(
        "Comma received post-reconnect agent reply",
        () => comma.posts().filter((p) => p.task === "cnv_live_1" && typeof p.text === "string" && p.text.includes("comma-reply-")).length >= 2,
        () => `posts=${JSON.stringify(comma.posts())} err=${st.err().slice(-2000)}`,
      );

      // task.leave -> status becomes gone, further task.put returns { gone: true }.
      const left = await comma.request("task.leave", { task: "cnv_live_1" });
      assert.equal(left.type, "response", JSON.stringify(left));
      assert.equal((await comma.request("task.status", { task: "cnv_live_1" })).result?.state, "gone");
      assert.deepEqual((await comma.request("task.put", { task: "cnv_live_1", messages: [] })).result, { gone: true });
    } finally {
      await st.stop();
    }
  },
);

// ══════════════════════════════════════════════════════════════════════════════
// 2. Cold Storage Packing (`--builder packed`) & Footprint (`--builder footprint`)
// ══════════════════════════════════════════════════════════════════════════════

test(
  "Cold storage (--builder packed) & footprint (--builder footprint) live parity: archive, read archived history & uploads while cold, footprint check, wake & continue",
  { skip, timeout: 120_000 },
  async () => {
    const binDir = toolsPath();
    installFakeClaude(binDir, "cold-wake-reply");
    const outDir = fresh("out");
    const { data, app, id } = makeStationDir({
      language: "en",
      profiles: [
        {
          id: "cc",
          name: "Claude",
          runtime: "claude",
          home: "homes/cc",
          access: { kind: "anthropic-api", key: "sk-ant-cold-test-key" },
          models: ["claude-opus-5-5"],
        },
      ],
      maxNudges: 1,
    });
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(
      join(data, "mesh", "cloud.json"),
      JSON.stringify({
        origin: "http://127.0.0.1:9",
        station: id,
        workspace: "w1",
        workspace_name: "Parity Team",
        name: "cold-host",
        relay_url: "",
        relay_urls: [],
        grant_keys: null,
        peers: [{ id, name: "cold-host" }],
        revocations: [],
      }),
    );

    const st = await launchStation(data, app, binDir, outDir);
    try {
      // Create session via admin API and run an initial turn so thread history is real.
      const made = await httpReq(st.door, "/admin-api/sessions", {
        method: "POST",
        body: { runtime: "claude", profile: "cc" },
      });
      assert.equal(made.status, 200, made.text);
      const key: string = made.json.key;
      const threadId: number = made.json.thread?.id ?? made.json.thread?.thread?.id;

      const sent1 = await httpReq(st.door, `/admin-api/threads/${threadId}/messages`, {
        method: "POST",
        body: { text: "initial message before cold archive" },
      });
      assert.ok(sent1.status >= 200 && sent1.status < 300, sent1.text);

      // Wait for turn 1 to finish all_done.
      const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), {
        currentTimeMillisUnsafe: () => Date.now(),
      } as never);
      closers.push(() => {
        try {
          store.close();
        } catch {}
      });
      await given(
        "turn 1 finished all_done",
        () => store.listTurns(key).some((t) => t.summary.ending === "all_done"),
        () => st.err().slice(-2000),
      );

      // Populate workspace with kept files, uploads, rebuildable node_modules, and a transcript file.
      const sessRow = store.getSession(key)!;
      const workspace = sessRow.workspace;
      const room = join(workspace, "..");
      const token = sessRow.token;
      mkdirSync(join(workspace, "uploads", "sub"), { recursive: true });
      writeFileSync(join(workspace, "keep.txt"), "precious workspace content\n");
      writeFileSync(join(workspace, "uploads", "note.txt"), "kept in the archive");
      writeFileSync(join(workspace, "uploads", "sub", "deeper.txt"), "nested attachment");
      mkdirSync(join(workspace, "app", "node_modules", "bigpkg"), { recursive: true });
      const rebuildablePayload = Buffer.alloc(64 * 1024, 0x61);
      writeFileSync(join(workspace, "app", "node_modules", "bigpkg", "index.js"), rebuildablePayload);

      const runtimeId = "11223344-5566-7788-99aa-bbccddeeff00";
      store.setRuntimeSessionId(key, runtimeId);
      const projectDir = join(data, "homes", "cc", "projects", realpathSync(workspace).replace(/[^a-zA-Z0-9]/g, "-"));
      const transcript = join(projectDir, `${runtimeId}.jsonl`);
      mkdirSync(projectDir, { recursive: true });
      const transcriptBody = `${JSON.stringify({ type: "user", sessionId: runtimeId, message: { role: "user", content: "hi cold" } })}\n`;
      writeFileSync(transcript, transcriptBody);

      // Measure workspace footprint via `--builder footprint` before archiving.
      const measureFootprint = (dir: string) => {
        const res = spawnSync(binary!, ["--builder", "footprint", "--sep", "/"], {
          input: `${JSON.stringify({ path: dir, finding: true })}\n`,
          encoding: "utf8",
          env: { PATH: binDir, HOME: data, TMPDIR: tmpdir() },
        });
        assert.equal(res.status, 0, res.stderr);
        return JSON.parse(res.stdout.trim());
      };
      const fpBefore = measureFootprint(workspace);
      assert.equal(fpBefore.error, undefined, JSON.stringify(fpBefore));
      assert.equal(fpBefore.complete, true, JSON.stringify(fpBefore));
      assert.ok(
        Array.isArray(fpBefore.rebuild) &&
          fpBefore.rebuild.some((r: any) => Array.isArray(r) && String(r[0]).endsWith("node_modules") && Number(r[1]) >= 64 * 1024),
        `expected node_modules in footprint before archive: ${JSON.stringify(fpBefore)}`,
      );

      // Archive the session -> triggers cold storage (--builder packed + --builder footprint cleanup).
      const archRes = await httpReq(st.door, `/admin-api/sessions/${encodeURIComponent(key)}/archive`, {
        method: "POST",
        body: {},
      });
      assert.equal(archRes.status, 200, `${archRes.text}\n${st.err().slice(-2000)}`);

      await given(
        "room packed into cold storage",
        () =>
          existsSync(join(room, "cold")) &&
          existsSync(join(room, "workspace.tar.zst")) &&
          !existsSync(join(workspace, "keep.txt")) &&
          !existsSync(join(workspace, "uploads", "note.txt")) &&
          !existsSync(join(workspace, "app", "node_modules")),
        () => st.err().slice(-2000),
      );
      await given(
        "transcript compressed to .jsonl.zst",
        () => existsSync(`${transcript}.zst`) && !existsSync(transcript),
        () => st.err().slice(-2000),
      );

      // While cold: archived chat history is still readable in full via read routes.
      const archivedChats = await httpReq(st.door, "/admin-api/chats?archived=1");
      assert.equal(archivedChats.status, 200, archivedChats.text);
      const chatList = Array.isArray(archivedChats.json) ? archivedChats.json : archivedChats.json?.chats ?? [];
      assert.ok(
        chatList.some((c: any) => c.id === key || c.thread === threadId || c.thread?.id === threadId),
        `archived chat missing from /chats?archived=1: ${archivedChats.text.slice(0, 600)}`,
      );

      const msgsWhileCold = await httpReq(st.door, `/admin-api/threads/${threadId}/entries`);
      assert.equal(msgsWhileCold.status, 200, msgsWhileCold.text);
      const entries = Array.isArray(msgsWhileCold.json) ? msgsWhileCold.json : msgsWhileCold.json?.entries ?? msgsWhileCold.json?.messages ?? [];
      assert.ok(
        entries.some((m: any) => m.text === "initial message before cold archive") &&
          entries.some((m: any) => typeof m.text === "string" && m.text.includes("cold-wake-reply-1")),
        `archived thread history incomplete: ${msgsWhileCold.text.slice(0, 800)}`,
      );

      // While cold: uploaded file is read directly out of workspace.tar.zst via /sessions/:key/files.
      const fileWhileCold = await httpReq(
        st.door,
        `/admin-api/sessions/${encodeURIComponent(key)}/files?name=${encodeURIComponent("note.txt")}`,
      );
      assert.equal(fileWhileCold.status, 200, fileWhileCold.text);
      assert.equal(fileWhileCold.text, "kept in the archive");

      const missingFile = await httpReq(
        st.door,
        `/admin-api/sessions/${encodeURIComponent(key)}/files?name=${encodeURIComponent("does-not-exist.txt")}`,
      );
      assert.equal(missingFile.status, 404, missingFile.text);
      assert.deepEqual(missingFile.json, { error: "station.files.notFound" });

      // Footprint after packing: rebuildable is gone, workspace dir has 0 rebuildable bytes.
      const fpCold = measureFootprint(workspace);
      assert.deepEqual(fpCold.rebuild ?? [], [], JSON.stringify(fpCold));

      // Also verify workspace_limit MCP tool reads footprint/limit cleanly on the live station.
      const wl = await mcpCall(st.door, token, "workspace_limit", {});
      assert.equal(wl.status, 200, wl.text);
      assert.notEqual(wl.json?.result?.isError, true, wl.text);

      // Unarchive / wake the session -> restores workspace & transcript without corruption.
      const unarch = await httpReq(st.door, `/admin-api/sessions/${encodeURIComponent(key)}/archive`, {
        method: "DELETE",
      });
      assert.equal(unarch.status, 200, `${unarch.text}\n${st.err().slice(-2000)}`);

      await given(
        "workspace and transcript restored from cold storage",
        () =>
          existsSync(join(workspace, "keep.txt")) &&
          existsSync(join(workspace, "uploads", "note.txt")) &&
          existsSync(join(workspace, "uploads", "sub", "deeper.txt")) &&
          existsSync(transcript) &&
          !existsSync(join(room, "workspace.tar.zst")) &&
          !existsSync(join(room, "cold")),
        () => st.err().slice(-2000),
      );
      assert.equal(readFileSync(join(workspace, "keep.txt"), "utf8"), "precious workspace content\n");
      assert.equal(readFileSync(join(workspace, "uploads", "note.txt"), "utf8"), "kept in the archive");
      assert.equal(readFileSync(join(workspace, "uploads", "sub", "deeper.txt"), "utf8"), "nested attachment");
      assert.equal(readFileSync(transcript, "utf8"), transcriptBody);
      assert.equal(existsSync(join(workspace, "app", "node_modules")), false, "rebuildable stays cleaned");

      // Send a new message to the woken session and verify agent continuation works cleanly.
      const sent2 = await httpReq(st.door, `/admin-api/threads/${threadId}/messages`, {
        method: "POST",
        body: { text: "continue after wake" },
      });
      assert.ok(sent2.status >= 200 && sent2.status < 300, sent2.text);
      await given(
        "turn 2 after wake finished all_done",
        () => store.listTurns(key).filter((t) => t.summary.ending === "all_done").length >= 2,
        () => `${JSON.stringify(store.listTurns(key).map((t) => t.summary))}\n${st.err().slice(-2000)}`,
      );
    } finally {
      await st.stop();
    }
  },
);

// ══════════════════════════════════════════════════════════════════════════════
// 3. Replica Export/Restore + Two-Station Live `station_move` Closed Loop
// ══════════════════════════════════════════════════════════════════════════════

test(
  "Replica export/restore & two-station live station_move parity: cross-station replica copy + restore, plan -> move chat -> continue on target -> move back",
  { skip, timeout: 180_000 },
  async () => {
    const binDir = toolsPath();
    installFakeClaude(binDir, "moved-chat-reply");
    const outA = fresh("outA");
    const outB = fresh("outB");

    const portA = await freeUdpPort();
    const portB = await freeUdpPort();

    // Both stations on beta channel so `station_move` is enabled, with matching keyed profile `cc`
    // so chats on `cc` are usable on both stations without needing account transfer.
    const sharedProfiles = [
      {
        id: "cc",
        name: "Claude Shared",
        runtime: "claude",
        home: "homes/cc",
        access: { kind: "anthropic-api", key: "sk-ant-parity-shared-key" },
        models: ["claude-opus-5-5"],
      },
    ];
    const stAInfo = makeStationDir({
      language: "en",
      updateChannel: "beta",
      profiles: sharedProfiles,
      maxNudges: 1,
    });
    const stBInfo = makeStationDir({
      language: "en",
      updateChannel: "beta",
      profiles: sharedProfiles,
      maxNudges: 1,
    });

    const peers = [
      { id: stAInfo.id, name: "station-a", ips: [`127.0.0.1:${portA}`] },
      { id: stBInfo.id, name: "station-b", ips: [`127.0.0.1:${portB}`] },
    ];
    const plane = await startControlPlane({ workspace: "w1", peers });

    for (const [info, name] of [
      [stAInfo, "station-a"],
      [stBInfo, "station-b"],
    ] as const) {
      mkdirSync(join(info.data, "mesh"), { recursive: true });
      writeFileSync(
        join(info.data, "mesh", "cloud.json"),
        JSON.stringify({
          origin: plane.origin,
          station: info.id,
          workspace: "w1",
          workspace_name: "Parity Team",
          name,
          relay_url: "",
          relay_urls: [],
          grant_keys: null,
          peers,
          revocations: [],
        }),
      );
    }

    const stA = await launchStation(stAInfo.data, stAInfo.app, binDir, outA, {
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portA}`,
    });
    const stB = await launchStation(stBInfo.data, stBInfo.app, binDir, outB, {
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portB}`,
    });

    try {
      await given(
        "both stations connected to control plane",
        () => plane.sockets.length >= 2,
        () => `A=${stA.err().slice(-1000)} B=${stB.err().slice(-1000)}`,
      );

      // Create a chat on station A, run a turn, and write a workspace file + upload.
      const made = await httpReq(stA.door, "/admin-api/sessions", {
        method: "POST",
        body: { runtime: "claude", profile: "cc" },
      });
      assert.equal(made.status, 200, made.text);
      const chatKey: string = made.json.key;
      const threadIdA: number = made.json.thread?.id ?? made.json.thread?.thread?.id;

      const sent1 = await httpReq(stA.door, `/admin-api/threads/${threadIdA}/messages`, {
        method: "POST",
        body: { text: "origin message on station A" },
      });
      assert.ok(sent1.status >= 200 && sent1.status < 300, sent1.text);

      const storeA = Store.open(join(stAInfo.data, "stillfail.db"), join(stAInfo.data, "archive"), {
        currentTimeMillisUnsafe: () => Date.now(),
      } as never);
      const storeB = Store.open(join(stBInfo.data, "stillfail.db"), join(stBInfo.data, "archive"), {
        currentTimeMillisUnsafe: () => Date.now(),
      } as never);
      closers.push(() => {
        try {
          storeA.close();
        } catch {}
        try {
          storeB.close();
        } catch {}
      });

      await given(
        "station A turn 1 finished all_done",
        () => storeA.listTurns(chatKey).some((t) => t.summary.ending === "all_done"),
        () => stA.err().slice(-2000),
      );

      const wsA = storeA.getSession(chatKey)!.workspace;
      const tokenA = storeA.getSession(chatKey)!.token;
      writeFileSync(join(wsA, "carried-note.txt"), "hello from station A workspace\n");
      mkdirSync(join(wsA, "uploads"), { recursive: true });
      writeFileSync(join(wsA, "uploads", "evidence.txt"), "replica attachment bytes");

      // ── Part 3A: Replica export on station A -> kept copy on station B over real iroh mesh -> restore into fresh station C ──
      const keptGenDir = await given(
        "station A replica exported and replicated to station B",
        () => {
          const base = join(stBInfo.data, "replicas", "w1", stAInfo.id);
          if (!existsSync(base)) return null;
          for (const g of readdirSync(base)) {
            const headPath = join(base, g, "head.json");
            if (existsSync(headPath)) {
              const head = JSON.parse(readFileSync(headPath, "utf8"));
              if (head.chats >= 1) return { dir: join(base, g), head, gen: g };
            }
          }
          return null;
        },
        () => `A=${stA.err().slice(-1500)} B=${stB.err().slice(-1500)}`,
        45_000,
      );
      assert.ok(keptGenDir.head.chats >= 1, JSON.stringify(keptGenDir.head));

      // Verify `--builder replica-restore` restores station A's kept copy into a fresh station C cleanly!
      const dataC = fresh("restoreC");
      const restoreCopyDir = join(dataC, "restore", "copy");
      const restoreGenDir = join(restoreCopyDir, keptGenDir.gen);
      mkdirSync(join(restoreGenDir, "log"), { recursive: true });
      mkdirSync(join(restoreCopyDir, "files"), { recursive: true });
      writeFileSync(join(restoreGenDir, "head.json"), readFileSync(join(keptGenDir.dir, "head.json")));
      const keptLogDir = join(keptGenDir.dir, "log");
      if (existsSync(keptLogDir)) {
        for (const f of readdirSync(keptLogDir)) {
          writeFileSync(join(restoreGenDir, "log", f), readFileSync(join(keptLogDir, f)));
        }
      }
      const keptFilesDir = join(stBInfo.data, "replicas", "w1", stAInfo.id, "files");
      if (existsSync(keptFilesDir)) {
        for (const f of readdirSync(keptFilesDir)) {
          writeFileSync(join(restoreCopyDir, "files", f), readFileSync(join(keptFilesDir, f)));
        }
      }
      writeFileSync(
        join(dataC, "restore", "ready.json"),
        JSON.stringify({
          origin: stAInfo.id,
          workspace: "w1",
          gen: keptGenDir.gen,
          name: "station-a",
          from: stBInfo.id,
        }),
      );
      Store.open(join(dataC, "stillfail.db"), join(dataC, "archive"), {
        currentTimeMillisUnsafe: () => Date.now(),
      } as never).close();
      const restoreRes = spawnSync(
        binary!,
        ["--builder", "replica-restore", "--db", join(dataC, "stillfail.db"), "--data", dataC, "--now", "1000", "--sep", "/"],
        {
          encoding: "utf8",
          env: { PATH: binDir, HOME: dataC, TMPDIR: tmpdir() },
        },
      );
      assert.equal(restoreRes.status, 0, restoreRes.stderr);
      const restoreJson = JSON.parse(restoreRes.stdout.trim().split("\n").at(-1)!);
      assert.equal(restoreJson.error, undefined, JSON.stringify(restoreJson));
      assert.equal(restoreJson.ready?.origin, stAInfo.id, JSON.stringify(restoreJson));
      const storeC = Store.open(join(dataC, "stillfail.db"), join(dataC, "archive"), {
        currentTimeMillisUnsafe: () => Date.now(),
      } as never);
      try {
        const outcomePath = join(dataC, "replica", "restored.json");
        const outcome = existsSync(outcomePath) ? readFileSync(outcomePath, "utf8") : "no restored.json";
        const restoredSession = storeC.getSession(chatKey);
        assert.ok(restoredSession !== null, `restored DB should contain station A's session; outcome=${outcome}`);
        const restoredThreads = storeC.sessionThreads(chatKey);
        assert.ok(restoredThreads.length >= 1, `restored DB should contain session thread; outcome=${outcome}`);
      } finally {
        storeC.close();
      }

      // ── Part 3B: Two-station live `station_move`: plan -> move chat A->B -> read & continue on B -> move back B->A ──
      // Wait for GET /admin-api/move?to=<idB> plan to show chatKey as movable ("here", no `cannot`).
      const planPage = await given(
        "station A move plan sees chatKey movable to station B",
        async () => {
          const r = await httpReq(stA.door, `/admin-api/move?to=${encodeURIComponent(stBInfo.id)}`);
          if (r.status !== 200 || !Array.isArray(r.json?.modules)) return null;
          const chatsMod = r.json.modules.find((m: any) => m.id === "chats");
          const item = chatsMod?.items?.find((x: any) => x.id === chatKey);
          if (!item || item.state !== "here" || item.cannot !== undefined) return null;
          return r.json;
        },
        () => `A=${stA.err().slice(-1500)} B=${stB.err().slice(-1500)}`,
        30_000,
      );
      assert.equal(planPage.to, stBInfo.id);

      // Also verify `station_move` MCP tool `plan` works live on beta station A.
      const mcpPlan = await mcpCall(stA.door, tokenA, "station_move", { action: "plan", to: stBInfo.id });
      assert.equal(mcpPlan.status, 200, mcpPlan.text);
      assert.notEqual(mcpPlan.json?.result?.isError, true, mcpPlan.text);

      // Move the single chat from A -> B (withNeeds: true in case account needs lending/matching).
      const moveStart = await httpReq(stA.door, "/admin-api/move", {
        method: "POST",
        body: { to: stBInfo.id, module: "chats", item: chatKey, withNeeds: true },
      });
      assert.equal(moveStart.status, 202, `${moveStart.text}\nA=${stA.err().slice(-1500)}\nB=${stB.err().slice(-1500)}`);

      // Wait until station A reports chatKey state === "there" and no active `moving`.
      await given(
        "chatKey moved to station B (state === 'there')",
        async () => {
          const r = await httpReq(stA.door, `/admin-api/move?to=${encodeURIComponent(stBInfo.id)}`);
          const chatsMod = r.json?.modules?.find((m: any) => m.id === "chats");
          const item = chatsMod?.items?.find((x: any) => x.id === chatKey);
          return r.json?.moving === null && item?.state === "there" ? item : null;
        },
        async () => {
          const r = await httpReq(stA.door, `/admin-api/move?to=${encodeURIComponent(stBInfo.id)}`);
          return `move=${JSON.stringify(r.json)} A=${stA.err().slice(-1200)} B=${stB.err().slice(-1200)}`;
        },
        45_000,
      );

      // Verify on station B: session exists, workspace file arrived intact, chat history readable via admin API.
      const sessB = await given(
        "moved session visible in station B store",
        () => storeB.getSession(chatKey),
        () => stB.err().slice(-1500),
      );
      assert.equal(
        readFileSync(join(sessB.workspace, "carried-note.txt"), "utf8"),
        "hello from station A workspace\n",
      );
      const threadIdB = storeB.sessionThreads(chatKey)[0]!.thread.id;
      const msgsOnB = await httpReq(stB.door, `/admin-api/threads/${threadIdB}/entries`);
      assert.equal(msgsOnB.status, 200, msgsOnB.text);
      const entriesB = Array.isArray(msgsOnB.json) ? msgsOnB.json : msgsOnB.json?.entries ?? msgsOnB.json?.messages ?? [];
      assert.ok(
        entriesB.some((m: any) => m.text === "origin message on station A"),
        `station B missing moved history: ${msgsOnB.text.slice(0, 600)}`,
      );

      // Continue the chat on station B: send a new message and verify fake claude completes a turn on B!
      const sentOnB = await httpReq(stB.door, `/admin-api/threads/${threadIdB}/messages`, {
        method: "POST",
        body: { text: "continuation message on station B" },
      });
      assert.ok(sentOnB.status >= 200 && sentOnB.status < 300, sentOnB.text);
      await given(
        "continuation turn finished all_done on station B",
        async () => {
          if (!storeB.listTurns(chatKey).some((t) => t.summary.ending === "all_done" && t.summary.endedAt != null)) {
            return false;
          }
          const r = await httpReq(stB.door, `/admin-api/threads/${threadIdB}/entries`);
          const es = Array.isArray(r.json) ? r.json : r.json?.entries ?? r.json?.messages ?? [];
          return es.filter((m: any) => typeof m.text === "string" && m.text.includes("moved-chat-reply")).length >= 2;
        },
        () => stB.err().slice(-1500),
      );

      // Move the chat BACK from B -> A (`POST /admin-api/move/back` with `{ from: stBInfo.id, ... }`).
      const backStart = await httpReq(stA.door, "/admin-api/move/back", {
        method: "POST",
        body: { from: stBInfo.id, module: "chats", item: chatKey },
      });
      assert.equal(backStart.status, 202, `${backStart.text}\nA=${stA.err().slice(-1500)}\nB=${stB.err().slice(-1500)}`);

      await given(
        "chatKey moved back to station A (state === 'here')",
        async () => {
          const r = await httpReq(stA.door, `/admin-api/move?to=${encodeURIComponent(stBInfo.id)}`);
          const chatsMod = r.json?.modules?.find((m: any) => m.id === "chats");
          const item = chatsMod?.items?.find((x: any) => x.id === chatKey);
          return r.json?.moving === null && item?.state === "here" ? item : null;
        },
        async () => {
          const r = await httpReq(stA.door, `/admin-api/move?to=${encodeURIComponent(stBInfo.id)}`);
          return `move=${JSON.stringify(r.json)} A=${stA.err().slice(-1200)} B=${stB.err().slice(-1200)}`;
        },
        45_000,
      );

      // Verify on station A: the message written on station B is now present in station A's thread history!
      const msgsBackOnA = await httpReq(stA.door, `/admin-api/threads/${threadIdA}/entries`);
      assert.equal(msgsBackOnA.status, 200, msgsBackOnA.text);
      const entriesBackA = Array.isArray(msgsBackOnA.json) ? msgsBackOnA.json : msgsBackOnA.json?.entries ?? msgsBackOnA.json?.messages ?? [];
      assert.ok(
        entriesBackA.some((m: any) => m.text === "origin message on station A") &&
          entriesBackA.some((m: any) => m.text === "continuation message on station B"),
        `station A missing messages after move back: ${msgsBackOnA.text.slice(0, 800)}`,
      );
    } finally {
      await Promise.all([stA.stop(), stB.stop()]);
    }
  },
);

// ══════════════════════════════════════════════════════════════════════════════
// 4. Accounts Admin Routes, Model Catalog & Starred Models Persistence Parity
// ══════════════════════════════════════════════════════════════════════════════

test(
  "Accounts admin routes, model catalog & starred models persistence parity: profile CRUD, secret masking, enable/disable, default model switch, stars merge + restart persistence",
  { skip, timeout: 120_000 },
  async () => {
    const binDir = toolsPath();
    installFakeClaude(binDir, "acct-reply");
    const outDir = fresh("out");
    const { data, app, id } = makeStationDir({
      language: "en",
      profiles: [
        {
          id: "cc",
          name: "Primary Claude",
          runtime: "claude",
          home: "homes/cc",
          models: ["claude-opus-5-5", "claude-sonnet-4-6"],
          model: "claude-opus-5-5",
          env: { ANTHROPIC_API_KEY: "sk-very-secret-value", CUSTOM_BASE: "https://example.test" },
        },
        {
          id: "cx",
          name: "Primary Codex",
          runtime: "codex",
          home: "homes/cx",
          models: ["gpt-6.1-sol"],
          model: "gpt-6.1-sol",
        },
      ],
      maxNudges: 1,
    });

    const plane = await startControlPlane({
      workspace: "w1",
      peers: [{ id, name: "acct-host" }],
      models: {
        "claude-opus-5-5": { name: "Claude Opus 5.5", provider: "anthropic", input: 15, output: 75 },
        "claude-sonnet-4-6": { name: "Claude Sonnet 4.6", provider: "anthropic", input: 3, output: 15 },
        "gpt-6.1-sol": { name: "GPT-6.1 Sol", provider: "openai", input: 5, output: 20 },
      },
    });
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(
      join(data, "mesh", "cloud.json"),
      JSON.stringify({
        origin: plane.origin,
        station: id,
        workspace: "w1",
        workspace_name: "Parity Team",
        name: "acct-host",
        relay_url: "",
        relay_urls: [],
        grant_keys: null,
        peers: [{ id, name: "acct-host" }],
        revocations: [],
      }),
    );

    const st1 = await launchStation(data, app, binDir, outDir);
    try {
      // Wait for overview & model catalog load.
      const ov0 = await given(
        "overview with profiles and model catalog",
        async () => {
          const r = await httpReq(st1.door, "/admin-api/overview");
          if (r.status !== 200 || !Array.isArray(r.json?.profiles) || r.json.profiles.length < 2) return null;
          return r.json;
        },
        () => st1.err().slice(-2000),
      );

      // Verify multi-profile list fields align with TS contract (id, name, runtime, enabled, models, env masking, home).
      const ccView = ov0.profiles.find((p: any) => p.id === "cc");
      const cxView = ov0.profiles.find((p: any) => p.id === "cx");
      assert.ok(ccView && cxView, JSON.stringify(ov0.profiles));
      assert.equal(ccView.runtime, "claude");
      assert.equal(ccView.name, "Primary Claude");
      assert.equal(ccView.enabled, true);
      assert.deepEqual(ccView.models, ["claude-opus-5-5", "claude-sonnet-4-6"]);
      assert.equal(ccView.model, "claude-opus-5-5");
      assert.ok(typeof ccView.home === "string" && ccView.home.length > 0);
      // Secret env key is masked (`sk-ve…alue`), non-secret is plain.
      const maskedKey = ccView.env?.find((e: any) => e.key === "ANTHROPIC_API_KEY");
      assert.deepEqual(maskedKey, { key: "ANTHROPIC_API_KEY", secret: true, value: "sk-ve…alue" });
      const plainEnv = ccView.env?.find((e: any) => e.key === "CUSTOM_BASE");
      assert.deepEqual(plainEnv, { key: "CUSTOM_BASE", secret: false, value: "https://example.test" });

      // Model catalog fetched from control plane (/v1/models).
      await given(
        "control plane /v1/models fetched",
        () => plane.askedUrls.some((u) => u.startsWith("/v1/models")),
        () => `askedUrls=${JSON.stringify(plane.askedUrls)}`,
      );

      // Create new keyed profile via PUT /admin-api/profiles/:id.
      const putNew = await httpReq(st1.door, "/admin-api/profiles/backup-key", {
        method: "PUT",
        body: {
          runtime: "claude",
          name: "Backup Key",
          access: { kind: "anthropic-api", key: "sk-my-backup-secret-key" },
          models: ["claude-opus-5-5", "claude-sonnet-4-6"],
          model: "claude-opus-5-5",
        },
      });
      assert.equal(putNew.status, 200, putNew.text);
      const bkView = putNew.json.profiles?.find((p: any) => p.id === "backup-key");
      assert.ok(bkView, JSON.stringify(putNew.json.profiles));
      assert.equal(bkView.enabled, true);
      assert.equal(bkView.model, "claude-opus-5-5");

      // Switch default model on `backup-key` and verify env update + null deletion + invalid env refusal.
      const switched = await httpReq(st1.door, "/admin-api/profiles/backup-key", {
        method: "PUT",
        body: { model: "claude-sonnet-4-6", env: { EXTRA_OPT: "yes" } },
      });
      assert.equal(switched.status, 200, switched.text);
      assert.equal(switched.json.profiles.find((p: any) => p.id === "backup-key").model, "claude-sonnet-4-6");

      const badEnv = await httpReq(st1.door, "/admin-api/profiles/backup-key", {
        method: "PUT",
        body: { env: { "BAD NAME": "1" } },
      });
      assert.equal(badEnv.status, 400, badEnv.text);

      // Disable profile -> enabled: false, key & models preserved, POST /check returns 409, re-enable -> enabled: true.
      const disabled = await httpReq(st1.door, "/admin-api/profiles/backup-key", {
        method: "PUT",
        body: { enabled: false },
      });
      assert.equal(disabled.status, 200, disabled.text);
      assert.equal(disabled.json.profiles.find((p: any) => p.id === "backup-key").enabled, false);

      const checkDisabled = await httpReq(st1.door, "/admin-api/profiles/backup-key/check", {
        method: "POST",
        body: {},
      });
      assert.equal(checkDisabled.status, 409, checkDisabled.text);

      const reenabled = await httpReq(st1.door, "/admin-api/profiles/backup-key", {
        method: "PUT",
        body: { enabled: true },
      });
      assert.equal(reenabled.status, 200, reenabled.text);
      assert.equal(reenabled.json.profiles.find((p: any) => p.id === "backup-key").enabled, true);

      // GET /admin-api/profiles/pace returns 200.
      const pace = await httpReq(st1.door, "/admin-api/profiles/pace");
      assert.equal(pace.status, 200, pace.text);

      // DELETE profile -> removed; deleting unknown profile -> 400.
      const delOk = await httpReq(st1.door, "/admin-api/profiles/backup-key", { method: "DELETE" });
      assert.equal(delOk.status, 200, delOk.text);
      assert.equal(delOk.json.profiles.find((p: any) => p.id === "backup-key"), undefined);

      const delMissing = await httpReq(st1.door, "/admin-api/profiles/no-such-profile", { method: "DELETE" });
      assert.equal(delMissing.status, 400, delMissing.text);

      // Starred models: GET -> PUT -> merge semantics (newer rev/timestamp wins, older ignored).
      const stars0 = await httpReq(st1.door, "/admin-api/stars");
      assert.equal(stars0.status, 200, stars0.text);
      assert.deepEqual(stars0.json, { stars: {} });

      const stars1 = await httpReq(st1.door, "/admin-api/stars", {
        method: "PUT",
        body: {
          stars: {
            "claude-opus-5-5": { on: true, rev: 2, at: 1000 },
            "gpt-6.1-sol": { on: true, rev: 1, at: 2000 },
          },
        },
      });
      assert.equal(stars1.status, 200, stars1.text);
      assert.deepEqual(stars1.json.stars, {
        "claude-opus-5-5": { on: true, rev: 2, at: 1000 },
        "gpt-6.1-sol": { on: true, rev: 1, at: 2000 },
      });

      // Lower rev for claude-opus-5-5 must NOT overwrite; higher rev for gpt-6.1-sol MUST update.
      const stars2 = await httpReq(st1.door, "/admin-api/stars", {
        method: "PUT",
        body: {
          stars: {
            "claude-opus-5-5": { on: false, rev: 1, at: 500 },
            "gpt-6.1-sol": { on: false, rev: 2, at: 3000 },
          },
        },
      });
      assert.equal(stars2.status, 200, stars2.text);
      assert.deepEqual(stars2.json.stars, {
        "claude-opus-5-5": { on: true, rev: 2, at: 1000 },
        "gpt-6.1-sol": { on: false, rev: 2, at: 3000 },
      });
    } finally {
      await st1.stop();
    }

    // Restart the station on the same data directory and verify starred models & profile edits persisted!
    const st2 = await launchStation(data, app, binDir, outDir);
    try {
      const starsAfterRestart = await httpReq(st2.door, "/admin-api/stars");
      assert.equal(starsAfterRestart.status, 200, starsAfterRestart.text);
      assert.deepEqual(starsAfterRestart.json.stars, {
        "claude-opus-5-5": { on: true, rev: 2, at: 1000 },
        "gpt-6.1-sol": { on: false, rev: 2, at: 3000 },
      });
    } finally {
      await st2.stop();
    }
  },
);
