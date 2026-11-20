// Faults and edges of the station's life as the MoonBit program runs it (station/mb src/station_main), held through
// the program itself and never the TypeScript station: `stillfail-reader run` under a launcher of the test's (its
// descriptors) or the real one (`stillfail-station run`, its SIGUSR2 handover), its agents under the real
// `stillfail-runner`, every program run with a PATH that names no Node. What the TypeScript's own tests hold of these
// (loopback.test.ts, preview.test.ts and preview-redirect.test.ts, jobs.test.ts and active-jobs-upgrade-integration.test.ts,
// agent-start-errors.test.ts, vault-once-handover.test.ts and vault-schema-handover.test.ts), held here of the program:
// the loopback port's answers; a service's preview through the agents' door (its redirects, a large answer whole, a
// slow one let go when its client goes); a job's whole group stopped, a member ignoring SIGTERM too; a runtime that is
// missing or ends at once leaving its session to be prompted again; and a handover keeping a service and a job up while
// the store is written from another connection, the process before gone and nothing of it left.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { type AddressInfo, connect, createServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
const launcher = process.env.STILLFAIL_LAUNCHER ?? "";
const runner = process.env.STILLFAIL_RUNNER ?? "";
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32" ? "the launcher's descriptors and signals are Unix's"
  : runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)"
  : false;
const skipLauncher = skip !== false ? skip : launcher === "" || !existsSync(launcher) ? "no stillfail-station launcher (run under scripts/native.ts run launcher)" : false;
const python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].find((p) => existsSync(p) && spawnSync(p, ["-c", "import http.server"]).status === 0) ?? null;

const dirs: string[] = [];
// (short: a runner's and the status's Unix sockets are at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sff-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const servers: Server[] = [];
const groups: number[] = [];
after(async () => {
  for (const s of servers) s.close();
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const g of groups) if (alive(g, true)) try { process.kill(-g, "SIGKILL"); } catch {}
  // (what a failed run left: the station, its front and runners, by what their files say)
  for (const d of dirs) {
    for (const f of ["run/station.json", "run/front.pid"]) {
      try {
        const text = readFileSync(join(d, f), "utf8");
        const pid = f.endsWith(".json") ? Number(JSON.parse(text).pid) : Number(text.trim());
        if (pid > 0 && pid !== process.pid) process.kill(pid, "SIGKILL");
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
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const alive = (pid: number, group = false) => {
  try {
    process.kill(group ? -pid : pid, 0);
    return true;
  } catch {
    return false;
  }
};

/// What comes true within `ms` (a real process's end or a socket's close, which nothing here is told of).
async function within<T>(what: string, ms: number, look: () => Promise<T | null | undefined | false> | T | null | undefined | false, detail: () => string = () => ""): Promise<T> {
  const until = Date.now() + ms;
  for (;;) {
    const got = await look();
    if (got !== null && got !== undefined && got !== false) return got;
    if (Date.now() > until) throw new Error(`not within ${ms} ms: ${what}; ${detail()}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

/// The commands a job of the test and its fakes run, each linked into a directory of its own: what is on the
/// station's PATH, so no Node is.
const TOOLS = ["sh", "ps", "mv", "cat", "sleep", "echo", "printf", "env", "kill", "sed", "tr", "head", "rm", "mkdir", "ls", "uname", "lsof"];
function toolsPath(): string {
  const dir = fresh("path");
  const look = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  for (const t of TOOLS) {
    const found = look.map((d) => join(d, t)).find((p) => existsSync(p));
    if (found !== undefined && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false);
  return dir;
}

const freePort = () => new Promise<number>((resolve) => {
  const s = createServer();
  s.listen(0, "127.0.0.1", () => {
    const port = (s.address() as AddressInfo).port;
    s.close(() => resolve(port));
  });
});

/// A station's data directory in workspace `W1` (named `Dev`, its station `abc`), as the control plane last said it.
function enrolled(data: string, place: Record<string, unknown> = {}) {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9/", station: "abc", workspace: "W1", workspace_name: "Dev", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [], ...place,
  }));
}

type Launched = { child: ChildProcess; door: number; loop: number; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fourth's pipe, ready
/// and serving its door and loopback port.
async function launch(data: string, path: string, env: Record<string, string> = {}): Promise<Launched> {
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9800\n");
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: { PATH: path, HOME: data, TMPDIR: tmpdir(), STILLFAIL_RUNNER: runner, STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_AGENT_NICE: "0", STILLFAIL_NO_DISCOVERY: "1", ...env },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  const next = (what: string, ok: (m: any) => boolean) => new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err.slice(-4000)}`)), 20_000);
    const look = () => {
      const found = said.find(ok);
      if (found !== undefined) {
        clearTimeout(timer);
        resolve(found);
      } else waiters.push(look);
    };
    look();
  });
  await next("ready", (m) => m.ready === true);
  const door = (await next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const loopPort = (await next("the loopback port", (m) => m.serving === "admin")).port as number;
  return { child, door, loop: loopPort, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

async function stopped(a: Launched) {
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err().slice(-4000));
}

type Answer = { status: number; headers: Record<string, string | string[] | undefined>; body: Buffer };
function http(port: number, path: string, o: { method?: string; body?: string; headers?: Record<string, string> } = {}): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers: o.headers ?? {}, agent: false }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (d) => chunks.push(d));
      res.on("end", () => resolve({ status: res.statusCode!, headers: res.headers, body: Buffer.concat(chunks) }));
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end(o.body);
  });
}

/// A tool of the agents' door, as session `token`'s agent calls it.
async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const r = await http(port, "/mcp", { body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }), headers: { "content-type": "application/json", authorization: `Bearer ${token}` } });
  assert.equal(r.status, 200, r.body.toString());
  const said = JSON.parse(r.body.toString());
  assert.equal(said.error, undefined, JSON.stringify(said));
  return { text: said.result.content[0].text, error: said.result.isError === true };
}

function openStore(data: string) {
  return Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
}

// ── the loopback port (loopback.test.ts) ──

test("the loopback port: old links go to the cloud's page, no admin API nor page served, and out of a workspace it says so and how to join", { skip }, async () => {
  const path = toolsPath();
  const [inData, removedData, noneData] = [fresh("lin"), fresh("lrm"), fresh("lno")];
  enrolled(inData);
  enrolled(removedData, { removed_at: 1_790_000_000 });
  const [inside, removed, none] = await Promise.all([launch(inData, path), launch(removedData, path), launch(noneData, path)]);
  const zh = { "accept-language": "zh-CN,en;q=0.8" };
  const at = async (p: string) => {
    const r = await http(inside.loop, p, { headers: zh });
    assert.equal(r.status, 302, `${p}: ${r.body}`);
    assert.equal(r.headers["cache-control"], "no-store", p);
    return r.headers.location;
  };
  const [w, s] = ["http://127.0.0.1:9/w/W1", "http://127.0.0.1:9/w/W1/s/abc"];
  assert.equal(await at("/admin/chats/chat%3Ac-1?history=k&entry=3"), `${s}/chats/chat%3Ac-1?history=k&entry=3`);
  assert.equal(await at("/admin/chats/chat%3Ac-1"), `${s}/chats/chat%3Ac-1`);
  assert.equal(await at("/admin/services/j1"), `${s}/services/j1`);
  assert.equal(await at("/admin/connects/c1"), `${s}/connects/c1`);
  assert.equal(await at("/admin/bots/c1"), `${s}/connects/c1`);
  assert.equal(await at("/admin/settings/accounts"), `${s}/settings/accounts`);
  assert.equal(await at("/admin/settings/accounts/p1"), `${s}/settings/accounts/p1`);
  for (const page of ["connects", "memory", "appearance", "shortcuts"]) assert.equal(await at(`/admin/settings/${page}`), `${w}/settings/${page}`);
  assert.equal(await at("/admin/settings/device"), `${w}/settings/stations`);
  assert.equal(await at("/admin/new"), `${w}/new`);
  assert.equal(await at("/admin/archive"), `${w}/archive`);
  for (const p of ["/admin/", "/admin", "/", "/admin/chats", "/admin/whatever/else"]) assert.equal(await at(p), `${w}/`, p);

  // Never the admin API, nor a page of its own, nor a preview: only the old links' way out.
  for (const p of ["/admin/api/overview", "/admin/api/events", "/admin/api/preview/5180/", "/admin/api", "/preview/5180/", "/mcp"]) {
    const r = await http(inside.loop, p, { headers: zh });
    assert.equal(r.status, 404, p);
    assert.equal(r.headers.location, undefined, p);
  }
  const posted = await http(inside.loop, "/admin/api/overview", { method: "POST", body: "{}", headers: { "content-type": "application/json" } });
  assert.equal(posted.status, 404);
  assert.equal((await http(inside.loop, "/assets/index.js")).status, 404);
  assert.equal((await http(inside.loop, "/healthz")).status, 200);

  // In no workspace, and removed from one: said, with the way to join one, and no redirect.
  const never = await http(none.loop, "/admin/chats/k", { headers: zh });
  assert.equal(never.status, 404);
  assert.equal(never.headers.location, undefined);
  assert.ok(never.body.toString().includes("尚未加入 workspace") && never.body.toString().includes("stillfail station enroll"), never.body.toString());
  const gone = await http(removed.loop, "/admin/chats/k", { headers: zh });
  assert.equal(gone.status, 404);
  assert.equal(gone.headers.location, undefined);
  assert.ok(gone.body.toString().includes("已被移出 workspace「Dev」") && gone.body.toString().includes("2026-09-21T"), gone.body.toString());

  await Promise.all([stopped(inside), stopped(removed), stopped(none)]);
});

// ── a service's preview (preview.test.ts, preview-redirect.test.ts) ──

/// A service of the test's on 127.0.0.1: `/seen` echoes what it was asked in x-seen (and forbids framing), `/go?to=`
/// redirects to what `to` says, `/big` answers `big` chunked, `/slow` answers chunks for as long as its client reads.
async function service(big: Buffer) {
  const sockets = new Set<Socket>();
  let slowClosed = 0;
  let slowOpen = 0;
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    let got = Buffer.alloc(0);
    socket.on("data", function onData(chunk) {
      got = Buffer.concat([got, chunk]);
      const end = got.indexOf("\r\n\r\n");
      if (end < 0) return;
      const head = got.subarray(0, end).toString();
      const header = (name: string) => head.split("\r\n").map((l) => l.split(/:(.*)/s)).find(([k]) => k!.toLowerCase() === name)?.[1]?.trim();
      const length = Number(header("content-length") ?? 0);
      if (got.length < end + 4 + length) return;
      socket.off("data", onData);
      const body = got.subarray(end + 4).toString();
      const [method, target] = head.split("\r\n")[0]!.split(" ");
      const url = new URL(target!, "http://x");
      if (url.pathname === "/go") {
        socket.end(`HTTP/1.1 302 Found\r\nLocation: ${url.searchParams.get("to")}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n`);
      } else if (url.pathname === "/big") {
        socket.write("HTTP/1.1 200 OK\r\ncontent-type: application/octet-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n");
        for (let i = 0; i < big.length; i += 65_536) {
          const piece = big.subarray(i, i + 65_536);
          socket.write(`${piece.length.toString(16)}\r\n`);
          socket.write(piece);
          socket.write("\r\n");
        }
        socket.end("0\r\n\r\n");
      } else if (url.pathname === "/slow") {
        slowOpen++;
        socket.on("close", () => slowClosed++);
        socket.write("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n");
        const piece = Buffer.alloc(4096, "s");
        const tick = setInterval(() => {
          if (socket.destroyed) return clearInterval(tick);
          socket.write(`${piece.length.toString(16)}\r\n`);
          socket.write(piece);
          socket.write("\r\n");
        }, 20);
        socket.on("close", () => clearInterval(tick));
      } else {
        const seen = `${method} ${target} ${header("host") ?? ""} ${header("traceparent") ?? "-"} ${header("x-stillfail-mesh") ?? "-"} ${body}`;
        const text = "hello from the service";
        socket.end(`HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nx-frame-options: DENY\r\ncontent-security-policy: frame-ancestors 'none'\r\nx-seen: ${seen}\r\ncontent-length: ${text.length}\r\nconnection: close\r\n\r\n${text}`);
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  servers.push(server);
  return {
    port: (server.address() as AddressInfo).port,
    sockets,
    slow: () => ({ open: slowOpen, closed: slowClosed }),
    stop: async () => {
      for (const s of sockets) s.destroy();
      await new Promise((r) => server.close(r));
    },
  };
}

test("a service's preview: as it answers, framing allowed; redirects kept on the service or whole; a large answer whole; a slow one let go when its client goes; one gone said", { skip }, async () => {
  const data = fresh("prv");
  enrolled(data);
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "zh" }));
  const a = await launch(data, toolsPath());
  const big = createHash("sha512").update("seed").digest();
  const large = Buffer.concat(Array.from({ length: 8 * 1024 * 1024 / big.length }, (_, i) => { const b = Buffer.from(big); b.writeUInt32BE(i, 0); return b; }));
  const s = await service(large);
  const port = s.port;

  // As it answers: the path and query as asked, the service's own host, none of still.fail's headers, framing allowed.
  const got = await http(a.door, `/preview/${port}/a/b?q=1`, { method: "POST", body: "x=1", headers: { "content-type": "text/plain", traceparent: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", "x-stillfail-mesh": "secret" } });
  assert.equal(got.status, 200, got.body.toString());
  assert.equal(got.headers["x-seen"], `POST /a/b?q=1 localhost:${port} - - x=1`);
  assert.deepEqual([got.headers["x-frame-options"], got.headers["content-security-policy"]], [undefined, undefined]);
  assert.equal(got.body.toString(), "hello from the service");

  // A redirect to this service keeps its path, query and fragment; one elsewhere its complete address.
  const redirect = async (to: string) => {
    const r = await http(a.door, `/preview/${port}/go?to=${encodeURIComponent(to)}`);
    assert.equal(r.status, 302, `${to}: ${r.body}`);
    return r.headers.location;
  };
  for (const origin of [`http://localhost:${port}`, `https://127.0.0.1:${port}`, `http://[::1]:${port}`]) {
    for (const [suffix, want] of [["/new?x=1#part", "/new?x=1#part"], ["", "/"], ["?x=1", "/?x=1"], ["#part", "/#part"]] as const) {
      assert.equal(await redirect(origin + suffix), want, origin + suffix);
    }
  }
  for (const to of [`http://localhost:${port + 1}/login`, `https://127.0.0.1:${port}0/login`, `http://[::1]:${port + 1}/login`, `http://localhost:${port}@example.test/login`, "https://example.test/login", "/new?x=1", "../login"]) {
    assert.equal(await redirect(to), to);
  }

  // A large answer comes through whole, in order.
  const whole = await http(a.door, `/preview/${port}/big`);
  assert.equal(whole.status, 200);
  assert.equal(whole.body.length, large.length);
  assert.equal(createHash("sha256").update(whole.body).digest("hex"), createHash("sha256").update(large).digest("hex"));

  // A slow answer whose client goes away mid-way: the station lets the service's connection go too.
  const client = connect(a.door, "127.0.0.1");
  client.on("error", () => {});
  await new Promise<void>((r) => client.once("connect", () => r()));
  client.write(`GET /preview/${port}/slow HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n`);
  let read = 0;
  await within("the slow answer's first chunks", 10_000, () => new Promise<boolean>((r) => client.once("data", (d) => r((read += d.length) > 16_384))));
  assert.deepEqual(s.slow(), { open: 1, closed: 0 });
  client.destroy();
  await within("the service's connection let go after its client went", 5_000, () => s.slow().closed === 1, () => `${JSON.stringify(s.slow())}; ${spawnSync("lsof", ["-nP", "-a", "-p", String(a.child.pid), "-iTCP"], { encoding: "utf8" }).stdout}`);
  // and the door still answers
  assert.equal((await http(a.door, `/preview/${port}/seen`)).status, 200);

  // The service gone: said, with its port.
  await s.stop();
  const none = await http(a.door, `/preview/${port}/`);
  assert.equal(none.status, 502);
  assert.ok(none.body.toString().includes(`localhost:${port} 无响应`), none.body.toString());
  await stopped(a);
});

// ── a job's whole group stopped (jobs.test.ts) ──

test("a job stopped: its whole group ends, members ignoring SIGTERM too, and nothing of it is left", { skip }, async () => {
  const data = fresh("job");
  const work = fresh("work");
  enrolled(data);
  const a = await launch(data, toolsPath());
  const store = openStore(data);
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
    // a member ignoring SIGTERM, a shell ignoring it with a child of its own, and a plain one
    const command = `(trap '' TERM; exec sleep 600) & echo $! > p1; sh -c 'trap "" TERM; sleep 600 & echo $! > p3; wait' & echo $! > p2; sleep 600 & echo $! > p4; wait`;
    const job = JSON.parse((await tool(a.door, "t1", "job_start", { name: "stubborn", command })).text);
    const pgid = await within("its group recorded", 5_000, () => store.getJob(job.id)?.pgid ?? null);
    groups.push(pgid);
    const pids = await within("its members started", 5_000, () => {
      const ps = ["p1", "p2", "p3", "p4"].map((f) => (existsSync(join(work, f)) ? Number(readFileSync(join(work, f), "utf8").trim()) : 0));
      return ps.every((p) => p > 0) ? ps : null;
    });
    for (const p of pids) assert.ok(alive(p), `${p} runs`);
    assert.equal((await tool(a.door, "t1", "job_stop", { id: job.id })).text, `Job "stubborn" (${job.id}) is stopped.`);
    await within("its group ended", 10_000, () => !alive(pgid, true), () => a.err().slice(-2000));
    // (each reaped: one ended with its parent is a zombie a moment, until launchd or init takes it)
    await within("each of its members ended", 5_000, () => pids.every((p) => !alive(p)), () => spawnSync("ps", ["-o", "pid,ppid,pgid,stat,command", "-p", pids.join(",")], { encoding: "utf8" }).stdout);
    assert.equal(store.getJob(job.id)!.state, "stopped");
    const listed = JSON.parse((await tool(a.door, "t1", "job_list")).text);
    assert.deepEqual(listed.map((j: any) => [j.id, j.state]), [[job.id, "stopped"]]);
  } finally {
    store.close();
  }
  await stopped(a);
});

// ── a runtime that cannot start (agent-start-errors.test.ts) ──

/// A fake Claude Code of /bin/sh and curl: each prompt posts all_done through the door, then ends its turn.
const workingClaude = `#!/bin/sh
case " $* " in *" -p "*) ;; *) exit 9 ;; esac
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
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  /usr/bin/curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \\
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","text":"back again","kind":"all_done","done":"answered after its runtime came back"}}}' > /dev/null
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"posted"}'
done
`;

test("a runtime missing, or ending as it starts: said in its chat as such, the session not left running, and once the runtime is there it answers", { skip: skip !== false ? skip : !existsSync("/usr/bin/curl") ? "no /usr/bin/curl for the fake runtime" : false }, async () => {
  const data = fresh("ase");
  const bin = fresh("bin");
  enrolled(data);
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }], maxNudges: 0 }));
  // (no claude on the station's PATH yet: its directory is the fakes', and nothing else)
  const a = await launch(data, bin);
  const store = openStore(data);
  try {
    const session = (key: string, token: string, ts: string) => {
      const workspace = join(data, "sessions", "chat", key.slice(5), "workspace");
      mkdirSync(workspace, { recursive: true });
      store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace, token, createdAt: Date.now(), lastActiveAt: Date.now(), title: key } as never);
      const thread = store.openThread("ember", "CHAT", ts, key, "ada@x.com");
      store.joinThread(thread.id, key, "ember");
      return thread;
    };
    session("chat:c-from", "t0", "1790000000.000001");
    const thread = session("chat:c-to", "t1", "1790000000.000002");
    const turns = () => store.listTurns("chat:c-to");
    const notices = () => store.messagesBefore(thread.id, null, 50).filter((m) => m.authorKind === "station").map((m) => m.text);
    const detail = () => `${JSON.stringify(turns().map((t) => t.summary))}; ${JSON.stringify(notices())}; ${a.err().slice(-3000)}`;
    /// `text` sent to the session; once it is not running, what the station said in its thread (a notice) since.
    const ask = async (text: string, said: (n: string[]) => boolean) => {
      const before = notices().length;
      const sent = await tool(a.door, "t0", "session_send", { to: "chat:c-to", text });
      assert.equal(sent.error, false, sent.text);
      await within(`what "${text}" came to`, 20_000, () => said(notices().slice(before)) && store.getSession("chat:c-to")!.running !== true && turns().every((t) => t.summary.endedAt != null), detail);
      return notices().slice(before);
    };

    // Missing: no claude to be found. Said as its runtime not installed here (actor_run.mbt `start_turn`'s `missing`,
    // as mb-actor.ts `errorOf` tells it of runner.ts `CommandMissing`), not as an agent that failed to start.
    const missing = await ask("are you there?", (n) => n.length > 0);
    assert.deepEqual(missing, ["⚠️ 无法启动 agent：此 station 尚未安装 Claude Code"], detail());
    // (a person's word in between: session_send's letter writes nothing in the thread, so the notice above would stay
    // the station's last word there, and a start failure saying the same prefix is not said again (actor_run.mbt))
    store.insertMessage({ thread: thread.id, ts: "1790000000.000003", authorKind: "person", author: "ada@x.com", text: "installed, trying again" });

    // Ending as it starts, saying why on its standard error: said, and not left running.
    writeFileSync(join(bin, "claude"), "#!/bin/sh\necho 'claude: cannot start here' >&2\nexit 3\n");
    chmodSync(join(bin, "claude"), 0o755);
    await ask("and now?", (n) => n.length > 0);
    assert.ok(turns().every((t) => t.summary.ending !== "all_done"), detail());

    // There at last: the same session answers.
    writeFileSync(join(bin, "claude"), workingClaude);
    chmodSync(join(bin, "claude"), 0o755);
    await ask("once more", () => store.messagesBefore(thread.id, null, 20).some((m) => m.authorKind === "agent"));
    const last = turns().at(-1)!.summary;
    assert.deepEqual([last.outcome, last.ending], ["completed", "all_done"], detail());
    assert.deepEqual(store.messagesBefore(thread.id, null, 20).filter((m) => m.authorKind === "agent").map((m) => m.text), ["back again"]);
  } finally {
    store.close();
  }
  await stopped(a);
});

// ── a handover under the real launcher (jobs.test.ts, active-jobs-upgrade-integration.test.ts, vault-*-handover.test.ts) ──

test("a handover (SIGUSR2): a service and a job go on, their port reached throughout, the store written from another connection meanwhile; the process before ends and nothing is left", { skip: skipLauncher !== false ? skipLauncher : python === null ? "no python3 with http.server for the service" : false, timeout: 120_000 }, async () => {
  const app = fresh("app");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(binary!, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  copyFileSync(runner, join(app, "station", "stillfail-runner"));
  chmodSync(join(app, "station", "stillfail-runner"), 0o755);
  writeFileSync(join(app, "BUILD"), "9801\n");
  const data = fresh("hnd");
  const work = fresh("work");
  enrolled(data);
  const mcpPort = await freePort();
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en", http: { port: mcpPort } }));
  const path = toolsPath();
  symlinkSync(python!, join(path, "python3"));
  const loopPort = await freePort();
  const station = spawn(launcher, ["run", "--app", app, "--data", data, "--port", String(loopPort)], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { PATH: path, HOME: data, TMPDIR: tmpdir(), STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_AGENT_NICE: "0", STILLFAIL_NO_DISCOVERY: "1" },
  });
  children.push(station);
  let err = "";
  station.stdout!.on("data", (d) => (err += d));
  station.stderr!.on("data", (d) => (err += d));
  const tail = () => err.slice(-5000);
  const ended = new Promise<number | null>((resolve) => station.on("exit", (code) => resolve(code)));
  const takenOver = () => [...err.matchAll(/Node (\d+) has taken over/g)].map((m) => Number(m[1]));
  const first = await within("the station taken over", 30_000, () => takenOver()[0], tail);
  const doorUp = async () => {
    try {
      return (await http(mcpPort, "/mcp", { body: "{}", headers: { "content-type": "application/json" } })).status === 401;
    } catch {
      return false;
    }
  };
  await within("the agents' door", 20_000, doorUp, tail);
  const ours = () => spawnSync("ps", ["-axo", "pid=,ppid=,command="], { encoding: "utf8" }).stdout.split("\n")
    .map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter((m) => m !== null && m[3]!.includes(data))
    .map((m) => ({ pid: Number(m![1]), ppid: Number(m![2]), command: m![3]! }));
  const sessionsPrograms = () => ours().filter((p) => p.command.includes("--sessions"));

  const store = openStore(data);
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
    const port = await freePort();
    writeFileSync(join(work, "index.html"), "<h1>kept up</h1>\n");
    const svc = JSON.parse((await tool(mcpPort, "t1", "job_start", { name: "site", command: `exec python3 -m http.server "$PORT" --bind 127.0.0.1`, port })).text);
    const job = JSON.parse((await tool(mcpPort, "t1", "job_start", { name: "keeper", command: "sleep 600" })).text);
    const servicePgid = await within("the service's group", 5_000, () => store.getJob(svc.id)?.pgid ?? null);
    const jobPgid = await within("the job's group", 5_000, () => store.getJob(job.id)?.pgid ?? null);
    groups.push(servicePgid, jobPgid);
    await within("the service answers", 15_000, async () => JSON.parse((await tool(mcpPort, "t1", "job_list")).text).find((j: any) => j.id === svc.id)?.ready === true);
    const page = async () => {
      try {
        const r = await http(port, "/index.html");
        return r.status === 200 && r.body.toString() === "<h1>kept up</h1>\n";
      } catch {
        return false;
      }
    };
    assert.ok(await page());
    const before = sessionsPrograms();
    assert.equal(before.length, 1, JSON.stringify(ours()));

    // The handover, while another connection writes the store and the service is asked again and again.
    let writing = true;
    let written = 0;
    const misses: string[] = [];
    const writer = (async () => {
      while (writing) {
        try {
          store.insertSession({ key: `w${written}`, connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: `tw${written}`, createdAt: Date.now(), lastActiveAt: Date.now() });
          written++;
        } catch (e) {
          misses.push(`write: ${String(e)}`);
        }
        await new Promise((r) => setTimeout(r, 5));
      }
    })();
    let asking = true;
    let asked = 0;
    const asker = (async () => {
      while (asking) {
        if (await page()) asked++;
        else misses.push(`the service missed at ${Date.now()}`);
        await new Promise((r) => setTimeout(r, 20));
      }
    })();
    station.kill("SIGUSR2");
    const next = await within("the next process took over", 30_000, () => takenOver().find((p) => p !== first), tail);
    await within("the process before gone", 15_000, () => !alive(first), tail);
    assert.ok(alive(next), "the next one runs");
    await within("the door served by the next process", 15_000, doorUp, tail);
    // jobs started through the next process meanwhile: recorded, not refused as busy
    const during = await Promise.all([1, 2, 3].map((i) => tool(mcpPort, "t1", "job_start", { name: `after-${i}`, command: "true" })));
    for (const d of during) assert.equal(d.error, false, d.text);
    writing = false;
    asking = false;
    await Promise.all([writer, asker]);
    assert.deepEqual(misses, [], tail());
    assert.ok(written > 0 && asked > 0, `${written} written, ${asked} asked`);
    for (const d of during) {
      const id = JSON.parse(d.text).id as string;
      await within(`${id} ended`, 10_000, () => store.getJob(id)?.state === "exited");
    }

    // The service and the job went on: their groups the same, followed by the next process, never started again.
    assert.ok(alive(servicePgid, true) && alive(jobPgid, true));
    assert.ok(await page());
    assert.equal((await http(mcpPort, `/preview/${port}/index.html`)).body.toString(), "<h1>kept up</h1>\n");
    const listed = await within("the jobs listed by the next process", 15_000, async () => {
      const v = JSON.parse((await tool(mcpPort, "t1", "job_list")).text);
      const mine = Array.isArray(v) ? v.filter((j: any) => j.id === svc.id || j.id === job.id) : [];
      return mine.length === 2 && mine.every((j: any) => j.state === "running") ? mine : null;
    }, tail);
    assert.equal(listed.length, 2);
    for (const [id, pgid] of [[svc.id, servicePgid], [job.id, jobPgid]] as const) {
      const row = store.getJob(id)!;
      assert.deepEqual([row.state, row.pgid, row.restarts ?? 0], ["running", pgid, 0], id);
    }
    // never two sessions' programs on one data directory; the one before's gone
    const after = await within("one sessions' program", 15_000, () => {
      const now = sessionsPrograms();
      return now.length === 1 ? now : null;
    }, () => JSON.stringify(ours()));
    if (after[0]!.pid !== before[0]!.pid) assert.equal(alive(before[0]!.pid), false);
    assert.ok(!/SQLITE_BUSY|database is locked/i.test(err), tail());

    // Stopped through the next process: the groups they ran in from the start end.
    assert.equal((await tool(mcpPort, "t1", "job_stop", { id: svc.id })).error, false);
    assert.equal((await tool(mcpPort, "t1", "job_stop", { id: job.id })).error, false);
    await within("their groups ended", 10_000, () => !alive(servicePgid, true) && !alive(jobPgid, true), tail);
    assert.equal(await page(), false);
  } finally {
    store.close();
  }

  // A stop: the launcher, the station and every process of theirs gone.
  station.kill("SIGTERM");
  assert.equal(await ended, 0, tail());
  await within("nothing of the station left", 15_000, () => ours().length === 0, () => JSON.stringify(ours()));
});
