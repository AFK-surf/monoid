// Live parity tests for the pure MoonBit station (`stillfail-reader run` with no Node on PATH,
// real `stillfail-runner`, fake `claude`, `/mcp`, and `STILLFAIL_LOCAL_ADMIN=1`) covering:
// 1. Web Service (`job_start` with `port`) full lifecycle: listening on `$PORT`, returned preview `link`,
//    proxying through both `/preview/<port>/...` and `/admin-api/preview/<port>/...` with status/headers/body
//    passthrough and framing header stripping, automatic restart on unexpected exit (`restarts` increments and
//    preview recovers with new PID), and `job_stop` preventing any further restart.
// 2. Watch Job (`job_start` with `watch: true`), `job_log` tail truncation, `job_list`, `stillfail-job notify`,
//    `watching` exposure in chats/jobs APIs, and session archive stopping all running jobs/services of that
//    session without disturbing other sessions.
// 3. `workspace_limit` (default read, write, validation, persistence across archive vs cleanup on delete),
//    `upkeep` & `disk.low` / `relieve` (#7559 thresholds), and `expireArchived` cold workspace cleanup.
// 4. Archive Policy (Admin API `PUT /archiving` & `PUT /automatic-decisions/policy` + MCP `archive_policy`
//    read/write/idempotency/validation), Autoarchive (archives overdue idle sessions while skipping active
//    watch and running-job sessions, then archives once watch stops), and Awake (holds machine awake while
//    a non-service job runs and releases on station stop).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { type AddressInfo, createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";

const binary = mbStationBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32" ? "the launcher's descriptors are Unix's"
  : runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)"
  : !existsSync("/usr/bin/curl") ? "no /usr/bin/curl for the fake runtime"
  : false;

const python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].find(
  (p) => existsSync(p) && spawnSync(p, ["-c", "import http.server"]).status === 0,
) ?? null;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfjo-${what}-`));
  dirs.push(dir);
  return dir;
};

const children: ChildProcess[] = [];
const jobGroups: number[] = [];

after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const pgid of jobGroups) {
    if (pgid > 0) try { process.kill(-pgid, "SIGKILL"); } catch {}
  }
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (!existsSync(runners)) continue;
    for (const f of readdirSync(runners)) {
      if (!f.endsWith(".json")) continue;
      try {
        const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
        if (typeof info.pgid === "number") try { process.kill(-info.pgid, "SIGKILL"); } catch {}
        if (typeof info.runner === "number") try { process.kill(info.runner, "SIGKILL"); } catch {}
      } catch {}
    }
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

const TOOLS = ["sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "python3", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "tail", "wc", "uname"];

function binOf(name: string): string {
  const search = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"];
  for (const d of search) {
    const at = join(d, name);
    if (existsSync(at)) return at;
  }
  return "";
}

function makeNoNodeBin(dir: string): void {
  for (const t of TOOLS) {
    const found = binOf(t);
    if (found !== "" && !found.includes("node") && !existsSync(join(dir, t))) {
      symlinkSync(found, join(dir, t));
    }
  }
  assert.equal(existsSync(join(dir, "node")), false, "no node on test PATH");
}

function installFakeClaude(binDir: string): void {
  makeNoNodeBin(binDir);
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
n=0
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  n=$((n+1))
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  say '{"type":"system","subtype":"status","status":"requesting","session_id":"'"$sid"'"}'
  to=$(printf '%s' "$line" | sed -n 's/.*thread=\\"\([^\\]*\)\\".*/\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-$sid"; else to=$(cat "$FAKE_OUT/to-$sid" 2>/dev/null); fi
  curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","text":"ok","kind":"all_done","done":"done"}}}' > /dev/null
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"ok"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"ok"}'
done
`;
  writeFileSync(join(binDir, "claude"), claude);
  chmodSync(join(binDir, "claude"), 0o755);
}

function installFakeAwake(binDir: string): void {
  const stub = String.raw`#!/bin/sh
trap 'printf "RELEASED\n" >> "$FAKE_OUT/awake.log"; exit 0' TERM INT
printf 'HELD %s %s\n' "$(basename "$0")" "$*" >> "$FAKE_OUT/awake.log"
sleep 600 &
pid=$!
wait "$pid"
`;
  for (const name of ["caffeinate", "systemd-inhibit"]) {
    const p = join(binDir, name);
    writeFileSync(p, stub);
    chmodSync(p, 0o755);
  }
}

type Launched = {
  child: ChildProcess;
  door: number;
  data: string;
  outDir: string;
  said: any[];
  tell: (m: unknown) => void;
  stop: () => Promise<void>;
  err: () => string;
};

async function launchStation(opts: {
  tag: string;
  config?: Record<string, unknown>;
  env?: Record<string, string>;
  withAwakeStub?: boolean;
  preSeed?: (store: Store, data: string) => void;
}): Promise<Launched> {
  const data = fresh(opts.tag);
  const app = fresh("app");
  const binDir = fresh("bin");
  const outDir = fresh("out");
  installFakeClaude(binDir);
  if (opts.withAwakeStub) installFakeAwake(binDir);
  writeFileSync(join(app, "BUILD"), "10460\n");
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin: "https://app.still.fail",
      station: "st-here",
      workspace: "w1",
      workspace_name: "TestWS",
      name: "here",
      relay_url: "",
      relay_urls: [],
      grant_keys: null,
      peers: [{ id: "st-here", name: "here" }],
      revocations: [],
    }),
  );
  writeFileSync(
    join(data, "config.json"),
    JSON.stringify({
      profiles: [{ id: "cc", name: "Claude", home: "homes/cc", runtime: "claude", access: { kind: "subscription" } }],
      ...(opts.config ?? {}),
    }),
  );
  if (opts.preSeed) {
    const s = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
    try {
      opts.preSeed(s, data);
    } finally {
      s.close();
    }
  }
  const listener = () =>
    new Promise<Server>((resolve) => {
      const s = createServer();
      s.listen(0, "127.0.0.1", () => resolve(s));
    });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: {
      PATH: binDir,
      HOME: process.env.HOME ?? tmpdir(),
      TMPDIR: tmpdir(),
      STILLFAIL_RUNNER: runner,
      STILLFAIL_LOCAL_ADMIN: "1",
      STILLFAIL_PARTS_DOOR: "1",
      STILLFAIL_HELD_EVERY_MS: "200",
      FAKE_OUT: outDir,
      ...(opts.env ?? {}),
    },
  });
  children.push(child);
  mcp.close();
  loop.close();

  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => {
    try {
      said.push(JSON.parse(line));
    } catch {}
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 20_000);
      const look = () => {
        const found = said.find(ok);
        if (found !== undefined) {
          clearTimeout(timer);
          resolve(found);
        } else {
          waiters.push(look);
        }
      };
      look();
    });
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  await next("ready", (m) => m.ready === true);
  const door = (await next("mcp", (m) => m.serving === "mcp")).port as number;
  const tell = (m: unknown) => {
    if (channel.writable) channel.write(`${JSON.stringify(m)}\n`);
  };
  return {
    child,
    door,
    data,
    outDir,
    said,
    tell,
    stop: async () => {
      if (child.exitCode !== null || child.signalCode !== null) return;
      tell({ op: "stop" });
      const code = await Promise.race([ended, new Promise<null>((r) => setTimeout(() => r(null), 15_000))]);
      if (code === null && child.exitCode === null) child.kill("SIGKILL");
      assert.equal(code, 0, `station exited cleanly; stderr:\n${err}`);
    },
    err: () => err,
  };
}

function httpRaw(
  port: number,
  path: string,
  o: { method?: string; body?: string; headers?: Record<string, string> } = {},
): Promise<{ status: number; headers: Record<string, string | string[] | undefined>; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        host: "127.0.0.1",
        port,
        path,
        method: o.method ?? (o.body === undefined ? "GET" : "POST"),
        headers: { ...(o.body !== undefined ? { "content-type": "application/json" } : {}), ...(o.headers ?? {}) },
      },
      (res) => {
        let text = "";
        res.on("data", (d) => (text += d));
        res.on("end", () => resolve({ status: res.statusCode!, headers: res.headers, body: text }));
      },
    );
    req.on("error", reject);
    req.end(o.body);
  });
}

async function httpJson(port: number, path: string, method = "GET", body?: unknown): Promise<{ status: number; body: any }> {
  const r = await httpRaw(port, path, { method, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return { status: r.status, body: r.body === "" ? null : JSON.parse(r.body) };
}

async function mcp(port: number, token: string, method: string, params: unknown = {}): Promise<any> {
  const r = await httpRaw(port, "/mcp", {
    method: "POST",
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  });
  assert.equal(r.status, 200, r.body);
  return JSON.parse(r.body);
}

async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const said = await mcp(port, token, "tools/call", { name, arguments: args });
  assert.equal(said.error, undefined, JSON.stringify(said));
  return { text: said.result.content[0].text, error: said.result.isError === true };
}

async function parts(port: number, method: string, path: string, body?: unknown): Promise<{ status: number; body: any }> {
  return httpJson(port, `/parts${path}`, method, body);
}

async function within<T>(
  what: string,
  ms: number,
  look: () => Promise<T | null | undefined | false> | T | null | undefined | false,
  detail: () => string = () => "",
): Promise<T> {
  const until = Date.now() + ms;
  let lastErr = "";
  for (;;) {
    try {
      const got = await look();
      if (got !== null && got !== undefined && got !== false) return got as T;
    } catch (e) {
      lastErr = (e as Error).message;
    }
    if (Date.now() > until) throw new Error(`not within ${ms} ms: ${what}${lastErr ? ` (last error: ${lastErr})` : ""}; ${detail()}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

const alive = (pid: number, group = false) => {
  try {
    process.kill(group ? -pid : pid, 0);
    return true;
  } catch {
    return false;
  }
};

const freePort = () =>
  new Promise<number>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => {
      const port = (s.address() as AddressInfo).port;
      s.close(() => resolve(port));
    });
  });

function seedSession(
  store: Store,
  data: string,
  opts: {
    key: string;
    token: string;
    ts: string;
    title?: string;
    createdBy?: string;
    lastActiveAt?: number;
    createdAt?: number;
  },
): { threadId: number; workspace: string } {
  const slug = opts.key.startsWith("chat:") ? opts.key.slice(5) : opts.key;
  const workspace = join(data, "sessions", "chat", slug, "workspace");
  mkdirSync(workspace, { recursive: true });
  const now = Date.now();
  const createdAt = opts.createdAt ?? now;
  const lastActiveAt = opts.lastActiveAt ?? now;
  store.insertSession({
    key: opts.key,
    connect: "ember",
    runtime: "claude",
    profile: "cc",
    model: "claude-sonnet-4-6",
    createdBy: opts.createdBy ?? "ada@x.com",
    workspace,
    token: opts.token,
    createdAt,
    lastActiveAt,
    title: opts.title ?? `chat ${opts.key}`,
  } as never);
  const thread = store.openThreadOf("ember", "CHAT", opts.ts, opts.title ?? `chat ${opts.key}`, opts.createdBy ?? "ada@x.com", opts.key);
  store.joinThread(thread.id, opts.key, "ember");
  return { threadId: thread.id, workspace };
}

test(
  "web service (job_start with port): preview link, proxy header/body/status passthrough, auto-restart on crash, and job_stop stays stopped",
  { skip: skip || (python === null ? "no python3 with http.server" : false) },
  async () => {
    const st = await launchStation({ tag: "websvc" });
    const store = Store.open(join(st.data, "stillfail.db"), join(st.data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
    try {
      const { workspace } = seedSession(store, st.data, { key: "chat:c-svc", token: "tok-svc", ts: "1700000001.000001", title: "Service Chat" });
      const port = await freePort();
      const pidsFile = join(workspace, "service-pids.log");
      const serverScript = join(workspace, "srv.py");
      writeFileSync(
        serverScript,
        `import http.server, json, os, sys
port = int(os.environ["PORT"])
with open(${JSON.stringify(pidsFile)}, "a") as f:
    f.write(f"{os.getpid()}\\n")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path.startswith("/crash"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"crashing")
            self.wfile.flush()
            os._exit(1)
        body = json.dumps({"method": "GET", "path": self.path, "pid": os.getpid(), "req": self.headers.get("x-req-test", "")}).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Service-Pid", str(os.getpid()))
        self.send_header("X-Echo-Req", self.headers.get("x-req-test", ""))
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n).decode("utf-8")
        body = json.dumps({"method": "POST", "path": self.path, "echo": raw, "pid": os.getpid()}).encode()
        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Service-Pid", str(os.getpid()))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
class S(http.server.HTTPServer):
    allow_reuse_address = True
S(("127.0.0.1", port), H).serve_forever()
`,
      );

      const started = await tool(st.door, "tok-svc", "job_start", {
        name: "demo-web",
        command: `exec ${python} ${serverScript}`,
        port,
      });
      assert.equal(started.error, false, started.text);
      const svc = JSON.parse(started.text);
      assert.equal(svc.port, port);
      assert.equal(svc.state, "running");
      assert.equal(typeof svc.link, "string", `expected preview link in ${started.text}`);
      assert.ok(svc.link.includes(`?service=${encodeURIComponent(svc.id)}`), `link should carry ?service=<id>: ${svc.link}`);

      // Wait until the service port answers and station marks it ready.
      const readySvc = await within("service ready", 15_000, async () => {
        const list = JSON.parse((await tool(st.door, "tok-svc", "job_list")).text);
        const found = list.find((j: any) => j.id === svc.id);
        return found?.ready === true ? found : null;
      });
      assert.equal(readySvc.state, "running");
      assert.equal(readySvc.restarts ?? 0, 0);

      const firstPgid = store.getJob(svc.id)!.pgid!;
      jobGroups.push(firstPgid);

      // Proxy via MCP door `/preview/<port>/...`
      const doorRes = await httpRaw(st.door, `/preview/${port}/echo?foo=bar`, {
        method: "GET",
        headers: { "x-req-test": "door-hdr" },
      });
      assert.equal(doorRes.status, 201, doorRes.body);
      const doorBody = JSON.parse(doorRes.body);
      assert.equal(doorBody.path, "/echo?foo=bar");
      assert.equal(doorBody.req, "door-hdr");
      assert.equal(doorRes.headers["x-echo-req"], "door-hdr");
      assert.equal(doorRes.headers["x-service-pid"], String(doorBody.pid));
      assert.equal(doorRes.headers["x-frame-options"], undefined, "framing headers stripped by preview proxy");
      assert.equal(doorRes.headers["content-security-policy"], undefined, "CSP framing header stripped by preview proxy");

      // Proxy via Admin API `/admin-api/preview/<port>/...` (GET + POST body passthrough)
      const adminGet = await httpRaw(st.door, `/admin-api/preview/${port}/echo?via=admin`, {
        method: "GET",
        headers: { "x-req-test": "admin-hdr" },
      });
      assert.equal(adminGet.status, 201, adminGet.body);
      assert.equal(adminGet.headers["x-echo-req"], "admin-hdr");
      assert.equal(JSON.parse(adminGet.body).pid, doorBody.pid);

      const adminPost = await httpRaw(st.door, `/admin-api/preview/${port}/submit`, {
        method: "POST",
        body: "hello-preview-payload",
        headers: { "content-type": "text/plain" },
      });
      assert.equal(adminPost.status, 202, adminPost.body);
      assert.equal(JSON.parse(adminPost.body).echo, "hello-preview-payload");

      // Duplicate port on another service is refused.
      const conflict = await tool(st.door, "tok-svc", "job_start", { name: "dup", command: "sleep 60", port });
      assert.equal(conflict.error, true);
      assert.match(conflict.text, new RegExp(`port ${port} is Service "demo-web"`));

      // Trigger unexpected exit -> station auto-restarts service (restarts increments, new PID serves requests).
      const crashed = await httpRaw(st.door, `/preview/${port}/crash`, { method: "GET" }).catch(() => null);
      if (crashed) assert.equal(crashed.status, 200);

      const restarted = await within("service auto-restarted and ready", 15_000, async () => {
        const row = store.getJob(svc.id);
        if (!row || row.state !== "running" || (row.restarts ?? 0) < 1) return null;
        const list = JSON.parse((await tool(st.door, "tok-svc", "job_list")).text);
        const found = list.find((j: any) => j.id === svc.id);
        return found?.ready === true ? { row, found } : null;
      });
      assert.equal(restarted.row.restarts, 1);
      jobGroups.push(restarted.row.pgid!);

      const afterCrash = await httpRaw(st.door, `/admin-api/preview/${port}/echo?after=crash`, {
        method: "GET",
        headers: { "x-req-test": "post-restart" },
      });
      assert.equal(afterCrash.status, 201, afterCrash.body);
      const afterBody = JSON.parse(afterCrash.body);
      assert.notEqual(afterBody.pid, doorBody.pid, "restarted service must have a new PID");
      assert.equal(afterCrash.headers["x-echo-req"], "post-restart");

      const pidsBeforeStop = readFileSync(pidsFile, "utf8").trim().split("\n");
      assert.equal(pidsBeforeStop.length, 2, `expected 2 launches, got ${JSON.stringify(pidsBeforeStop)}`);

      // job_stop stops the service and prevents any further auto-restart.
      const stopRes = await tool(st.door, "tok-svc", "job_stop", { id: svc.id });
      assert.equal(stopRes.error, false, stopRes.text);
      assert.equal(stopRes.text, `Service "demo-web" (${svc.id}, port ${port}) is stopped.`);
      await within("restarted service group dead", 10_000, () => (!alive(restarted.row.pgid!, true) ? true : null));

      // Wait longer than the initial 1 s restart backoff to prove it stays stopped.
      await new Promise((r) => setTimeout(r, 1800));
      const finalRow = store.getJob(svc.id)!;
      assert.equal(finalRow.state, "stopped");
      assert.equal(finalRow.restarts, 1);
      assert.equal(readFileSync(pidsFile, "utf8").trim().split("\n").length, 2, "stopped service must not restart");

      const deadRes = await httpRaw(st.door, `/admin-api/preview/${port}/echo`, { method: "GET" });
      assert.ok(deadRes.status >= 500, `stopped service preview should fail with 5xx, got ${deadRes.status}`);
    } finally {
      store.close();
      await st.stop();
    }
  },
);

test(
  "watch job: watch+port rejection, job_list/admin/chats watching exposure, stillfail-job notify, job_log tail truncation, and archive cleanup",
  { skip: skip || (python === null ? "no python3 with http.server" : false) },
  async () => {
    const st = await launchStation({ tag: "watch" });
    const store = Store.open(join(st.data, "stillfail.db"), join(st.data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
    try {
      const s1 = seedSession(store, st.data, { key: "chat:c-watch1", token: "tok-w1", ts: "1700000010.000001", title: "Watch Chat" });
      seedSession(store, st.data, { key: "chat:c-other", token: "tok-w2", ts: "1700000011.000001", title: "Other Chat" });

      // watch: true cannot be combined with port.
      const badPort = await freePort();
      const watchWithPort = await tool(st.door, "tok-w1", "job_start", {
        name: "bad-watch",
        command: "sleep 60",
        port: badPort,
        watch: true,
      });
      assert.equal(watchWithPort.error, true);
      assert.equal(watchWithPort.text, "a watch is a job, not a web service: give it no port");

      // Start a watch job that prints 60 numbered lines, sends a notify, and stays alive.
      const watchStarted = await tool(st.door, "tok-w1", "job_start", {
        name: "ci-monitor",
        command: `i=1; while [ "$i" -le 60 ]; do echo "watch-line-$i"; i=$((i + 1)); done; stillfail-job notify "ci check green"; sleep 600`,
        watch: true,
      });
      assert.equal(watchStarted.error, false, watchStarted.text);
      const watchJob = JSON.parse(watchStarted.text);
      assert.equal(watchJob.watch, true);
      assert.equal(watchJob.state, "running");

      // Also start a web service in s1 and a normal job in s2.
      const svcPort = await freePort();
      const svcStarted = await tool(st.door, "tok-w1", "job_start", {
        name: "s1-svc",
        command: `exec ${python} -m http.server "$PORT" --bind 127.0.0.1`,
        port: svcPort,
      });
      assert.equal(svcStarted.error, false, svcStarted.text);
      const svcJob = JSON.parse(svcStarted.text);

      const otherStarted = await tool(st.door, "tok-w2", "job_start", {
        name: "s2-bg",
        command: "sleep 600",
      });
      assert.equal(otherStarted.error, false, otherStarted.text);
      const otherJob = JSON.parse(otherStarted.text);

      // Wait for notify to land and process groups to be recorded.
      await within("watch job notice and pgids recorded", 15_000, () => {
        const notices = store.jobNotices(watchJob.id, 5);
        const wRow = store.getJob(watchJob.id);
        const sRow = store.getJob(svcJob.id);
        const oRow = store.getJob(otherJob.id);
        return notices.some((n) => n.text === "ci check green") && wRow?.pgid && sRow?.pgid && oRow?.pgid ? true : null;
      });
      const watchPgid = store.getJob(watchJob.id)!.pgid!;
      const svcPgid = store.getJob(svcJob.id)!.pgid!;
      const otherPgid = store.getJob(otherJob.id)!.pgid!;
      jobGroups.push(watchPgid, svcPgid, otherPgid);

      // job_list exposes watch: true.
      const listed = JSON.parse((await tool(st.door, "tok-w1", "job_list")).text);
      const listedWatch = listed.find((j: any) => j.id === watchJob.id);
      assert.equal(listedWatch.watch, true);
      assert.equal(listedWatch.state, "running");

      // job_log tail truncation via MCP and Admin API.
      const tail3 = await tool(st.door, "tok-w1", "job_log", { id: watchJob.id, lines: 3 });
      assert.equal(tail3.error, false, tail3.text);
      assert.equal(tail3.text, "watch-line-58\nwatch-line-59\nwatch-line-60");

      const adminLog = await httpJson(st.door, `/admin-api/jobs/${encodeURIComponent(watchJob.id)}/log?lines=2`);
      assert.equal(adminLog.status, 200, JSON.stringify(adminLog));
      assert.equal(adminLog.body.text, "watch-line-59\nwatch-line-60");

      // Admin API GET /jobs/:id exposes notices & outputAt.
      const adminJob = await httpJson(st.door, `/admin-api/jobs/${encodeURIComponent(watchJob.id)}`);
      assert.equal(adminJob.status, 200, JSON.stringify(adminJob));
      assert.equal(adminJob.body.watch, true);
      assert.ok(Array.isArray(adminJob.body.notices) && adminJob.body.notices.some((n: any) => n.text === "ci check green"), JSON.stringify(adminJob.body));
      assert.equal(typeof adminJob.body.outputAt, "number");

      // Admin API GET /jobs lists open jobs including watchJob.
      const openJobs = await httpJson(st.door, "/admin-api/jobs");
      assert.equal(openJobs.status, 200, JSON.stringify(openJobs));
      const openArr = Array.isArray(openJobs.body) ? openJobs.body : openJobs.body?.jobs ?? [];
      assert.ok(openArr.some((j: any) => j.id === watchJob.id && j.watch === true), JSON.stringify(openJobs.body));

      // Admin API GET /chats exposes `agents[].watch` for s1 and not s2.
      const chatsRes = await httpJson(st.door, "/admin-api/chats");
      assert.equal(chatsRes.status, 200, JSON.stringify(chatsRes));
      const chatRows: any[] = Array.isArray(chatsRes.body) ? chatsRes.body : chatsRes.body?.chats ?? [];
      const row1 = chatRows.find((r) => r.id === s1.threadId || r.agents?.some((a: any) => a.key === "chat:c-watch1"));
      assert.ok(row1, `s1 chat should be in /admin-api/chats: ${JSON.stringify(chatRows)}`);
      const agent1 = row1.agents?.find((a: any) => a.key === "chat:c-watch1");
      assert.deepEqual(agent1?.watch?.names, ["ci-monitor"], JSON.stringify(row1));
      assert.equal(typeof agent1?.watch?.since, "number");
      assert.equal(typeof agent1?.watch?.at, "number");
      const row2 = chatRows.find((r) => r.agents?.some((a: any) => a.key === "chat:c-other"));
      assert.equal(row2?.agents?.find((a: any) => a.key === "chat:c-other")?.watch, undefined, "non-watch chat has no watch badge");

      // Archive s1 -> stops BOTH the watch job and the web service of s1, leaving s2's job untouched.
      const archRes = await httpJson(st.door, `/admin-api/sessions/${encodeURIComponent("chat:c-watch1")}/archive`, "POST", {});
      assert.equal(archRes.status, 200, JSON.stringify(archRes));

      await within("s1 watch job and service stopped on archive", 15_000, () => {
        const w = store.getJob(watchJob.id);
        const s = store.getJob(svcJob.id);
        if (w?.state !== "stopped" || s?.state !== "stopped" || alive(watchPgid, true) || alive(svcPgid, true)) return null;
        // `Jobs::stopAll` appends the note after the stop itself: wait for it too
        return readFileSync(w.log, "utf8").includes("[still.fail] stopped: its chat ended") &&
          readFileSync(s.log, "utf8").includes("[still.fail] stopped: its chat ended")
          ? true
          : null;
      });
      // stopAll marks a job stopped before it appends the note to its log: wait for both notes too.
      const ended = /\[still\.fail\] stopped: its chat ended/;
      const logOf = (id: string): string => {
        try {
          return readFileSync(store.getJob(id)!.log, "utf8");
        } catch {
          return "";
        }
      };
      await within("s1 job logs note the chat ended", 15_000, () =>
        ended.test(logOf(watchJob.id)) && ended.test(logOf(svcJob.id)) ? true : null,
      );
      assert.match(logOf(watchJob.id), ended);
      assert.match(logOf(svcJob.id), ended);

      // s2's job is still running and alive.
      assert.equal(store.getJob(otherJob.id)!.state, "running");
      assert.equal(alive(otherPgid, true), true);
      assert.equal((await tool(st.door, "tok-w2", "job_stop", { id: otherJob.id })).error, false);
    } finally {
      store.close();
      await st.stop();
    }
  },
);

test(
  "workspace_limit (read/write/validation/archive-retention/delete-cleanup), upkeep/relieve (#7559 disk.low), and expireArchived",
  { skip },
  async () => {
    const st = await launchStation({
      tag: "wslimit",
      config: { archivedWorkspaceDays: 7 },
    });
    const store = Store.open(join(st.data, "stillfail.db"), join(st.data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
    try {
      const s1 = seedSession(store, st.data, { key: "chat:c-lim1", token: "tok-lim1", ts: "1700000020.000001", title: "Limit One" });
      seedSession(store, st.data, { key: "chat:c-lim2", token: "tok-lim2", ts: "1700000021.000001", title: "Limit Two" });
      writeFileSync(join(s1.workspace, "artifact.txt"), "cold-archive-payload\n");

      // Default limit is 10 GiB.
      const def = await tool(st.door, "tok-lim1", "workspace_limit", {});
      assert.equal(def.error, false, def.text);
      assert.deepEqual(JSON.parse(def.text), { station: "this station", limit_gib: 10 });

      // Invalid values are rejected.
      for (const bad of [0, -3, 1.5]) {
        const r = await tool(st.door, "tok-lim1", "workspace_limit", { limit_gib: bad });
        assert.equal(r.error, true, `expected error for limit_gib=${bad}, got ${r.text}`);
        assert.match(r.text, /positive whole number of GiB/);
      }

      // Unknown remote station is rejected.
      const remoteErr = await tool(st.door, "tok-lim1", "workspace_limit", { station: "st-nonexistent" });
      assert.equal(remoteErr.error, true);
      assert.equal(remoteErr.text, "this chat has no remote workspace on that station");

      // Set custom limits for both sessions and check persistence files.
      const set1 = await tool(st.door, "tok-lim1", "workspace_limit", { limit_gib: 4 });
      assert.equal(set1.error, false, set1.text);
      assert.deepEqual(JSON.parse(set1.text), { station: "this station", limit_gib: 4 });
      const set2 = await tool(st.door, "tok-lim2", "workspace_limit", { limit_gib: 6 });
      assert.equal(set2.error, false, set2.text);

      const limitFile = (key: string) => join(st.data, "workspace-limits", `${createHash("sha256").update(key).digest("hex")}.json`);
      assert.equal(existsSync(limitFile("chat:c-lim1")), true);
      assert.equal(existsSync(limitFile("chat:c-lim2")), true);
      assert.equal((await parts(st.door, "POST", "/ask/workspaceWatch.limit", ["chat:c-lim1", ""])).body, 4 * 1024 ** 3);

      // Archiving s1 must KEEP its custom workspace_limit (only deleting forgets it).
      const arch1 = await httpJson(st.door, `/admin-api/sessions/${encodeURIComponent("chat:c-lim1")}/archive`, "POST", {});
      assert.equal(arch1.status, 200, JSON.stringify(arch1));
      await new Promise((r) => setTimeout(r, 300));
      assert.equal(existsSync(limitFile("chat:c-lim1")), true, "archived chat must keep its workspace-limits file");
      assert.equal(
        (await parts(st.door, "POST", "/ask/workspaceWatch.limit", ["chat:c-lim1", ""])).body,
        4 * 1024 ** 3,
        "archived chat must keep its custom workspace_limit",
      );

      // Deleting s2 MUST forget its workspace_limit and remove its file.
      const del2 = await httpJson(st.door, `/admin-api/sessions/${encodeURIComponent("chat:c-lim2")}`, "DELETE");
      assert.equal(del2.status, 200, JSON.stringify(del2));
      await within("deleted chat workspace-limits file removed", 10_000, () => (!existsSync(limitFile("chat:c-lim2")) ? true : null));
      assert.equal((await parts(st.door, "POST", "/ask/workspaceWatch.limit", ["chat:c-lim2", ""])).body, 10 * 1024 ** 3);

      // Upkeep & relieve (#7559 disk.low threshold parity: min(20 GiB, total/10), soft max(30 GiB, total/10)).
      const up = await parts(st.door, "POST", "/ask/upkeep");
      assert.equal(up.status, 200, JSON.stringify(up));
      assert.ok(up.body.free > 0 && up.body.total > 0, JSON.stringify(up.body));

      const rel = await parts(st.door, "POST", "/ask/relieve");
      assert.equal(rel.status, 200, JSON.stringify(rel));
      const { free, total, tier } = rel.body;
      const diskLow = Math.min(20 * 1024 ** 3, total / 10);
      const diskSoft = Math.max(30 * 1024 ** 3, total / 10);
      const expectedTier = free < diskLow ? "low" : free < diskSoft ? "soft" : "ok";
      assert.equal(tier, expectedTier, JSON.stringify(rel.body));

      // Backdate s1's archived_at past archivedWorkspaceDays (7d) and verify cold workspace expiry empties it
      // on the next lifecycle pass (after restart so lifecycle runs immediately without waiting 1h).
      const oldArchivedAt = Date.now() - 8 * 86_400_000;
      store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(oldArchivedAt, "chat:c-lim1");
      store.close();
      await st.stop();

      // Re-launch on same data dir: P52::lifecycle runs expire_archived immediately once taken up.
      const app = fresh("app2");
      const binDir = fresh("bin2");
      installFakeClaude(binDir);
      writeFileSync(join(app, "BUILD"), "10460\n");
      const listener = () =>
        new Promise<Server>((resolve) => {
          const s = createServer();
          s.listen(0, "127.0.0.1", () => resolve(s));
        });
      const [mcpSock, loopSock] = [await listener(), await listener()];
      const fd = (s: Server) => (s as any)._handle.fd as number;
      const child2 = spawn(binary!, ["run", "--app", app, "--data", st.data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
        stdio: ["ignore", "pipe", "pipe", fd(mcpSock), fd(loopSock), "pipe"],
        env: {
          PATH: binDir,
          HOME: process.env.HOME ?? tmpdir(),
          TMPDIR: tmpdir(),
          STILLFAIL_RUNNER: runner,
          STILLFAIL_LOCAL_ADMIN: "1",
          STILLFAIL_PARTS_DOOR: "1",
          FAKE_OUT: st.outDir,
        },
      });
      children.push(child2);
      mcpSock.close();
      loopSock.close();
      const ch2 = (child2.stdio as readonly unknown[])[5] as import("node:net").Socket;
      const ended2 = new Promise<number | null>((resolve) => child2.on("exit", (c) => resolve(c)));
      try {
        await within(
          "archived workspace expired and emptied by lifecycle",
          20_000,
          () => (!existsSync(join(s1.workspace, "artifact.txt")) ? true : null),
        );
      } finally {
        if (ch2.writable) ch2.write(`${JSON.stringify({ op: "stop" })}\n`);
        await Promise.race([ended2, new Promise((r) => setTimeout(r, 10_000))]);
      }
      return;
    } finally {
      try { store.close(); } catch {}
      await st.stop();
    }
  },
);

test(
  "archive_policy (Admin API + MCP), autoarchive (skips watch & running, archives overdue idle), and awake (holds machine awake for running job)",
  { skip },
  async () => {
    // autoArchiveDays = 0.00002 (~1.73 s) and pre-seed a fresh active chat so P52::lifecycle
    // computes a ~1.7 s next-due wakeup instead of sleeping for 1 hour on an empty database.
    const st = await launchStation({
      tag: "policy-awake",
      config: { autoArchiveDays: 0.00002, slackArchiveDays: 0, autoArchiveReviewed: false, autoArchiveKeep: 0 },
      withAwakeStub: true,
      preSeed: (s, data) => {
        seedSession(s, data, { key: "chat:c-policy", token: "tok-pol", ts: "1700000030.000001", title: "Policy Chat" });
      },
    });
    const store = Store.open(join(st.data, "stillfail.db"), join(st.data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
    try {
      const old = Date.now() - 2 * 86_400_000;
      // Seed sessions:
      // - s_watch: starts fresh until watch job is up, then backdated to overdue (must be skipped until watch stops)
      // - s_idle: overdue idle chat with a completed all_done turn and no jobs (must be auto-archived)
      // - s_ticker: future-dated active chat so P52::lifecycle always schedules another ~2 s pass
      seedSession(store, st.data, { key: "chat:c-wskip", token: "tok-wskip", ts: "1700000031.000001", title: "Watch Skip" });
      seedSession(store, st.data, { key: "chat:c-idle", token: "tok-idle", ts: "1700000032.000001", title: "Overdue Idle", createdAt: old, lastActiveAt: old });
      seedSession(store, st.data, { key: "chat:c-ticker", token: "tok-tick", ts: "1700000033.000001", title: "Lifecycle Ticker", lastActiveAt: Date.now() + 5_000 });
      store.startTurn("turn-idle-1", "chat:c-idle", "done");
      store.endTurn("turn-idle-1", "completed", null, "all_done", null);
      store.startTurn("turn-wskip-1", "chat:c-wskip", "watching");
      store.endTurn("turn-wskip-1", "completed", null, "all_done", null);
      // Start watch job BEFORE backdating c-wskip so an in-flight autoarchive pass cannot race it.
      const wJob = JSON.parse((await tool(st.door, "tok-wskip", "job_start", { name: "hold-watch", command: "sleep 600", watch: true })).text);
      const rJob = JSON.parse((await tool(st.door, "tok-pol", "job_start", { name: "awake-work", command: "sleep 600" })).text);
      await within("both jobs have pgids", 10_000, () => (store.getJob(wJob.id)?.pgid && store.getJob(rJob.id)?.pgid ? true : null));
      jobGroups.push(store.getJob(wJob.id)!.pgid!, store.getJob(rJob.id)!.pgid!);
      // Ensure last_active_at is overdue for c-idle, c-wskip, and c-policy (proving watch & running jobs protect them).
      store.db.prepare("UPDATE sessions SET last_active_at = ? WHERE key IN ('chat:c-idle', 'chat:c-wskip', 'chat:c-policy')").run(old);

      // ── Archive Policy: Admin API PUT /archiving validation & update ──
      const badArch = await httpJson(st.door, "/admin-api/archiving", "PUT", { days: -1, slackDays: 1, reviewed: false });
      assert.equal(badArch.status, 400, JSON.stringify(badArch));

      const okArch = await httpJson(st.door, "/admin-api/archiving", "PUT", { days: 0.00002, slackDays: 7, reviewed: false });
      assert.equal(okArch.status, 200, JSON.stringify(okArch));
      assert.equal(okArch.body.archiving?.days, 0.00002, JSON.stringify(okArch.body.archiving));
      assert.equal(okArch.body.archiving?.slackDays, 7);
      assert.equal(okArch.body.archiving?.reviewed, false);

      // ── Archive Policy: Admin API PUT /automatic-decisions/policy validation & save ──
      const badPolicy = await httpJson(st.door, "/admin-api/automatic-decisions/policy", "PUT", { policy: "", options: [] });
      assert.equal(badPolicy.status, 400, JSON.stringify(badPolicy));

      const customOptions = [
        { id: "done", name: "Done", rubric: "All requested work finished", archive: true },
        { id: "open", name: "Open", rubric: "Still needs work or reply", archive: false },
      ];
      const putPolicy = await httpJson(st.door, "/admin-api/automatic-decisions/policy", "PUT", {
        policy: "Archive chats once all work is finished.",
        options: customOptions,
      });
      assert.equal(putPolicy.status, 200, JSON.stringify(putPolicy));

      // ── Archive Policy: MCP `archive_policy` read, write, idempotency ──
      const readPol = await tool(st.door, "tok-pol", "archive_policy", {});
      assert.equal(readPol.error, false, readPol.text);
      const parsedPol = JSON.parse(readPol.text);
      assert.equal(parsedPol.policy, "Archive chats once all work is finished.");
      assert.equal(parsedPol.options.length, 2);

      const updPol = await tool(st.door, "tok-pol", "archive_policy", { policy: "Archive finished chats after review." });
      assert.equal(updPol.error, false, updPol.text);
      assert.match(updPol.text, /^Saved \(/);

      const samePol = await tool(st.door, "tok-pol", "archive_policy", { policy: "Archive finished chats after review." });
      assert.equal(samePol.error, false, samePol.text);
      assert.equal(samePol.text, "Nothing changed: the policy is already so.");

      const ov = await httpJson(st.door, "/admin-api/overview");
      assert.equal(ov.status, 200);
      assert.equal(ov.body.automaticDecisions?.policy?.text, "Archive finished chats after review.", JSON.stringify(ov.body.automaticDecisions));

      // ── Autoarchive: overdue idle chat is archived, while watch-job and running-job chats are skipped ──
      await within("overdue idle session auto-archived", 15_000, () => {
        const row = store.getSession("chat:c-idle");
        return row?.archivedAt != null ? row : null;
      });
      assert.equal(store.getSession("chat:c-idle")!.archivedBy, "auto");
      assert.equal(store.getSession("chat:c-wskip")!.archivedAt, null, "watch job must protect session from autoarchive");
      assert.equal(store.getSession("chat:c-policy")!.archivedAt, null, "running job must protect session from autoarchive");

      // Stop the watch job on s_watch -> next autoarchive sweep archives s_watch!
      assert.equal((await tool(st.door, "tok-wskip", "job_stop", { id: wJob.id })).error, false);
      store.db.prepare("UPDATE sessions SET last_active_at = ? WHERE key = 'chat:c-wskip'").run(old);
      await within("former watch session auto-archived after watch stopped", 15_000, () => {
        const row = store.getSession("chat:c-wskip");
        return row?.archivedAt != null ? row : null;
      });
      assert.equal(store.getSession("chat:c-wskip")!.archivedBy, "auto");

      // ── Awake: awake timer (20 s) holds the machine awake while rJob is running ──
      const awakeLog = join(st.outDir, "awake.log");
      await within(
        "awake holder spawned for running job",
        30_000,
        () => (existsSync(awakeLog) && readFileSync(awakeLog, "utf8").includes("HELD ") ? true : null),
        () => `stillfail.log: ${existsSync(join(st.data, "stillfail.log")) ? readFileSync(join(st.data, "stillfail.log"), "utf8").slice(-800) : "missing"}`,
      );
      const stLog = existsSync(join(st.data, "stillfail.log")) ? readFileSync(join(st.data, "stillfail.log"), "utf8") : st.err();
      assert.match(stLog, /holding the machine awake while agents work/);

      // Stop the background job and stop the station -> awake holder is released.
      assert.equal((await tool(st.door, "tok-pol", "job_stop", { id: rJob.id })).error, false);
    } finally {
      store.close();
      await st.stop();
    }
    const awakeLogAfter = join(st.outDir, "awake.log");
    await within("awake holder released on station stop", 5_000, () =>
      existsSync(awakeLogAfter) && readFileSync(awakeLogAfter, "utf8").includes("RELEASED") ? true : null,
    );
  },
);
