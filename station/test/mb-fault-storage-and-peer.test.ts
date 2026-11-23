// Faults and edges of the station's storage, its runners, its peers and its accounts as the MoonBit program runs them
// (station/mb src/station_main), held through the program itself and never the TypeScript station: `stillfail-reader
// run` with the launcher's descriptors, its agents' runners the real `stillfail-runner`, two stations on loopback iroh,
// every program run with a PATH that names no Node. What the TypeScript's own tests hold of these, held here of the
// program: cold storage's round trip of a workspace (modes, links, files sent in its chat, what can be made again let
// go) and of its transcript, and a cut or broken archive refused with nothing lost (cold-archive.test.ts,
// cold-hub.test.ts, cold-compat.test.ts); runners nobody holds ended at the start, the one a session holds kept, files
// of runners gone swept and a pid reused never killed (orphan-runners.test.ts, runner-sweep.test.ts); megabytes through
// `/peer/` and `peer_forward` at a slow reader's pace, both closed at once as the other station stops mid-stream, and
// a peer's call to one killed found gone by its check, then dialed anew (peer-http.test.ts, peer-forward.test.ts,
// peer-gone.test.ts); profiles refused in words, paused and taken up
// again whole, withheld from a joined workspace (accounts-routes.test.ts, accounts-config.test.ts); and a chat's
// workspace limit kept over a restart, what is not a limit refused (workspace-size.test.ts).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { createSocket } from "node:dgram";
import {
  chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, statSync,
  symlinkSync, truncateSync, writeFileSync,
} from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, connect as tcpConnect, createServer as tcpServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";

const binary = mbStationBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32" ? "the launcher's descriptors and signals are Unix's"
  : false;
const skipRunner = skip !== false ? skip : runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)" : false;

const dirs: string[] = [];
// (short: a runner's and the status's Unix sockets are at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfs-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
const pids: number[] = [];
after(async () => {
  for (const c of closers.splice(0)) {
    try { c(); } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const p of pids) {
    try { process.kill(-p, "SIGKILL"); } catch {}
    try { process.kill(p, "SIGKILL"); } catch {}
  }
  // (what a failed run left: the station, its front and runners, by what their files say)
  for (const d of dirs) {
    for (const f of ["run/station.json", "run/front.pid"]) {
      try {
        const text = readFileSync(join(d, f), "utf8");
        const pid = Number(text.trim().startsWith("{") ? JSON.parse(text).pid : text.trim());
        if (pid > 0 && pid !== process.pid) process.kill(pid, "SIGKILL");
      } catch {}
    }
    const runners = join(d, "run", "runners");
    if (existsSync(runners)) {
      for (const f of readdirSync(runners).filter((n) => n.endsWith(".json"))) {
        try {
          const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
          if (pids.includes(info.runner)) continue;
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

/// What comes true within `ms` (a real process's end, a file the station writes, a socket's close: nothing here is told
/// of them).
async function within<T>(what: string, ms: number, look: () => Promise<T | null | undefined | false> | T | null | undefined | false, detail: () => string = () => ""): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const got = await look();
      if (got !== null && got !== undefined && got !== false) return got;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`not within ${ms} ms: ${what}${last ? ` (${(last as Error).message})` : ""}; ${detail()}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

/// The commands the station and its jobs run, each linked into a directory of its own: its PATH, so no Node is.
const TOOLS = ["sh", "ps", "mv", "cat", "sleep", "echo", "printf", "env", "kill", "sed", "tr", "head", "rm", "mkdir", "ls", "uname", "lsof", "id", "curl"];
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
const sleepBin = ["/bin/sleep", "/usr/bin/sleep"].find((p) => existsSync(p)) ?? "sleep";
const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

const freeUdpPort = async () => {
  const s = createSocket("udp4");
  await new Promise<void>((r) => s.bind(0, "127.0.0.1", () => r()));
  const port = s.address().port;
  await new Promise<void>((r) => s.close(() => r()));
  return port;
};
const freeTcpPort = () => new Promise<number>((resolve) => {
  const s = tcpServer();
  s.listen(0, "127.0.0.1", () => {
    const port = (s.address() as AddressInfo).port;
    s.close(() => resolve(port));
  });
});

type Launched = { child: ChildProcess; door: number; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string; stop: () => Promise<void> };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fourth's pipe, ready
/// and serving its agents' door.
async function launch(data: string, env: Record<string, string> = {}, build = "9800"): Promise<Launched> {
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), `${build}\n`);
  const listener = () => new Promise<Server>((resolve) => {
    const s = tcpServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: { PATH: toolsPath(), HOME: data, TMPDIR: tmpdir(), STILLFAIL_RUNNER: runner, STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_AGENT_NICE: "0", STILLFAIL_NO_DISCOVERY: "1", ...env },
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
    const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err.slice(-4000)}`)), 30_000);
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
  const tell = (m: unknown) => channel.write(`${JSON.stringify(m)}\n`);
  const stop = async () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    tell({ op: "stop" });
    assert.equal(await ended, 0, err.slice(-4000));
  };
  return { child, door, tell, ended, err: () => err, stop };
}

type Answer = { status: number; headers: Record<string, unknown>; body: Buffer; json: any };
function http(port: number, path: string, o: { method?: string; body?: unknown; headers?: Record<string, string> } = {}): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const body = o.body === undefined ? undefined : Buffer.isBuffer(o.body) ? o.body : Buffer.from(JSON.stringify(o.body));
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (body === undefined ? "GET" : "POST"), headers: { "content-type": "application/json", ...(o.headers ?? {}) }, agent: false }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (d) => chunks.push(d));
      res.on("end", () => {
        const all = Buffer.concat(chunks);
        let json: any = null;
        try { json = JSON.parse(all.toString()); } catch {}
        resolve({ status: res.statusCode!, headers: res.headers, body: all, json });
      });
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end(body);
  });
}

/// A tool of the agents' door, as session `token`'s agent calls it.
async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const r = await http(port, "/mcp", { body: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, headers: { authorization: `Bearer ${token}` } });
  assert.equal(r.status, 200, r.body.toString());
  assert.equal(r.json.error, undefined, r.body.toString());
  return { text: r.json.result.content[0].text, error: r.json.result.isError === true };
}

function openStore(data: string) {
  return Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
}

/// A row of the live store, read on a connection of its own (the station writes it meanwhile).
function row<T>(data: string, sql: string, ...args: (string | number)[]): T | undefined {
  const db = new DatabaseSync(join(data, "stillfail.db"));
  try {
    db.exec("PRAGMA busy_timeout = 5000;");
    return db.prepare(sql).get(...args) as T | undefined;
  } finally {
    db.close();
  }
}

/// A station's data directory in workspace `W1`, as the control plane last said it.
function enrolled(data: string, place: Record<string, unknown> = {}) {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9/", station: "abc", workspace: "W1", workspace_name: "Dev", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [], ...place,
  }));
}

/// The whole of a tree as bytes, modes and links: what a round trip must give back as it was.
function tree(root: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (rel: string) => {
    const at = join(root, rel);
    for (const name of readdirSync(at).sort()) {
      const r = rel === "" ? name : join(rel, name);
      const st = lstatSync(join(root, r));
      if (st.isSymbolicLink()) out[r] = `link ${readlinkSync(join(root, r))}`;
      else if (st.isDirectory()) {
        out[r] = `dir ${(st.mode & 0o777).toString(8)}`;
        walk(r);
      } else out[r] = `file ${(st.mode & 0o777).toString(8)} ${sha256(readFileSync(join(root, r)))}`;
    }
  };
  walk("");
  return out;
}

// ── cold storage (cold-archive.test.ts, cold-hub.test.ts, cold-compat.test.ts) ──

test("cold storage: a workspace and its transcript packed and given back byte for byte (modes, links, files sent in its chat), what can be made again let go; a cut or broken archive refused with nothing lost and the station serving", { skip }, async () => {
  const data = fresh("cold");
  enrolled(data);
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }], maxNudges: 0 }));
  const a = await launch(data, { STILLFAIL_LOCAL_ADMIN: "1" });
  const store = openStore(data);
  const key = "chat:c-cold";
  const room = join(data, "sessions", "chat", "c-cold");
  const workspace = join(room, "workspace");
  const archive = join(room, "workspace.tar.zst");
  const path = `/admin-api/sessions/${encodeURIComponent(key)}/archive`;
  try {
    mkdirSync(workspace, { recursive: true });
    store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace, token: "t0", createdAt: Date.now(), lastActiveAt: Date.now(), title: "cold" } as never);
    const thread = store.openThread("ember", "CHAT", "1790000000.000001", "cold", "ada@x.com");
    store.joinThread(thread.id, key, "ember");
    // What is kept: an edit not committed anywhere, a script with its own mode, a read-only file, a file sent in the
    // chat, links (relative, to a directory, dangling), an empty file and an empty directory, a long name.
    const big = Buffer.concat(Array.from({ length: 64 }, (_, i) => createHash("sha512").update(`piece ${i}`).digest()));
    mkdirSync(join(workspace, "project", "deep", "er"), { recursive: true });
    writeFileSync(join(workspace, "project", "uncommitted.rs"), Buffer.concat([Buffer.alloc(200_000, "x"), big]));
    writeFileSync(join(workspace, "script.sh"), "#!/bin/sh\ntrue\n");
    chmodSync(join(workspace, "script.sh"), 0o751);
    writeFileSync(join(workspace, "project", "deep", "er", "read-only.txt"), "not to be written\n");
    chmodSync(join(workspace, "project", "deep", "er", "read-only.txt"), 0o444);
    mkdirSync(join(workspace, "uploads"), { recursive: true });
    writeFileSync(join(workspace, "uploads", "evidence.bin"), randomBytes(70_000));
    symlinkSync(join("project", "uncommitted.rs"), join(workspace, "link"));
    symlinkSync("project", join(workspace, "dir-link"));
    symlinkSync("nowhere/at/all", join(workspace, "dangling"));
    writeFileSync(join(workspace, "empty"), "");
    mkdirSync(join(workspace, "empty-dir"));
    writeFileSync(join(workspace, `${"n".repeat(120)}.txt`), "a long name\n");
    // What can be made again (cold.ts `cleanRebuildable`): known by what is beside it, never put in the archive.
    writeFileSync(join(workspace, "package.json"), "{}\n");
    mkdirSync(join(workspace, "node_modules", "x"), { recursive: true });
    writeFileSync(join(workspace, "node_modules", "x", "index.js"), "module.exports = 1;\n");
    const kept = tree(workspace);
    delete kept["node_modules"];
    delete kept[join("node_modules", "x")];
    delete kept[join("node_modules", "x", "index.js")];
    // Its transcript where Claude keeps it (its project named after the workspace as the system resolves it).
    const runtimeId = "0b1c2d3e-4f50-4a61-8b72-93a4b5c6d7e8";
    store.setRuntimeSessionId(key, runtimeId);
    const project = join(data, "homes", "cc", "projects", realpathSync(workspace).replace(/[^a-zA-Z0-9]/g, "-"));
    const transcript = join(project, `${runtimeId}.jsonl`);
    mkdirSync(project, { recursive: true });
    const history = Array.from({ length: 4_000 }, (_, i) => JSON.stringify({ type: i % 2 ? "assistant" : "user", sessionId: runtimeId, n: i, message: { role: "user", content: `turn ${i} 中文 ✓` } })).join("\n") + "\n";
    writeFileSync(transcript, history);

    const pack = async () => {
      const archived = await http(a.door, path, { method: "POST", body: {} });
      assert.equal(archived.status, 200, `${archived.body}\n${a.err().slice(-3000)}`);
      await within("the room put in cold storage", 20_000, () => existsSync(join(room, "cold")) && existsSync(archive) && !existsSync(join(room, "workspace.retiring")) && readdirSync(workspace).length === 0 && existsSync(`${transcript}.zst`) && !existsSync(transcript), () => `${existsSync(workspace) ? readdirSync(workspace) : "none"}; ${a.err().slice(-3000)}`);
    };
    await pack();
    assert.ok(statSync(archive).size < 100_000, `the archive is compressed: ${statSync(archive).size} bytes`);

    // ── a cut archive, then a broken one: unarchiving returns 200 immediately while background restore refuses the
    // broken archive, logs the failure, keeps the archive and what came meanwhile, leaves the room cold, and keeps
    // the station serving ──
    const good = readFileSync(archive);
    writeFileSync(join(workspace, "sent-while-archived.txt"), "a file sent while it was archived\n");
    for (const [what, spoil] of [
      ["cut short", () => truncateSync(archive, Math.floor(good.length / 2))],
      ["not an archive", () => writeFileSync(archive, "broken archive")],
    ] as const) {
      spoil();
      const spoiled = readFileSync(archive);
      const beforeErrLen = a.err().length;
      const unarchived = await within(`unarchiving with the archive ${what} answered`, 20_000, () => http(a.door, path, { method: "DELETE" }), () => a.err().slice(-3000));
      assert.equal(unarchived.status, 200, `${what}: ${unarchived.status} ${unarchived.body}`);
      await within(`background restore failure logged for ${what}`, 20_000, () => a.err().slice(beforeErrLen).includes("an archived session's files not restored in background"), () => a.err().slice(-3000));
      assert.deepEqual(readFileSync(archive), spoiled, `${what}: the archive left as it was`);
      assert.equal(readFileSync(join(workspace, "sent-while-archived.txt"), "utf8"), "a file sent while it was archived\n", `${what}: what came meanwhile kept`);
      assert.equal(existsSync(join(workspace, "project")), false, `${what}: nothing restored short`);
      assert.ok(existsSync(join(room, "cold")), `${what}: still cold`);
      assert.equal(row<{ archived_at: number | null }>(data, "SELECT archived_at FROM sessions WHERE key = ?", key)?.archived_at ?? null, null, `${what}: unarchived immediately in store`);
      assert.equal(a.child.exitCode, null, `${what}: the station runs: ${a.err().slice(-3000)}`);
      assert.equal((await http(a.door, "/admin-api/overview")).status, 200, `${what}: the station serves`);
    }

    // ── its archive whole again: given back as it was, byte for byte, the file that came meanwhile beside it ──
    writeFileSync(archive, good);
    const back = await http(a.door, path, { method: "DELETE" });
    assert.equal(back.status, 200, `${back.body}\n${a.err().slice(-3000)}`);
    await within("the workspace restored", 20_000, () => existsSync(join(workspace, "project")) && !existsSync(archive) && !existsSync(join(room, "cold")) && existsSync(transcript), () => a.err().slice(-3000));
    const now = tree(workspace);
    assert.equal(now["sent-while-archived.txt"]?.startsWith("file "), true);
    delete now["sent-while-archived.txt"];
    assert.deepEqual(now, kept);
    assert.equal(readlinkSync(join(workspace, "link")), join("project", "uncommitted.rs"));
    assert.deepEqual(readFileSync(join(workspace, "link")), readFileSync(join(workspace, "project", "uncommitted.rs")));
    assert.equal(statSync(join(workspace, "script.sh")).mode & 0o777, 0o751);
    assert.equal(existsSync(join(workspace, "node_modules")), false, "what can be made again is not brought back");
    assert.equal(readFileSync(transcript, "utf8"), history, "the transcript read back whole");
    assert.equal(existsSync(`${transcript}.zst`), false);
    for (const left of ["workspace.restoring", "workspace.retiring", "workspace.restored-old"]) assert.equal(existsSync(join(room, left)), false, left);
    assert.equal(row<{ archived_at: number | null }>(data, "SELECT archived_at FROM sessions WHERE key = ?", key)?.archived_at ?? null, null, "shown again");
    // ── and archived again from what it is now: the same round trip ──
    await pack();
    assert.equal((await http(a.door, path, { method: "DELETE" })).status, 200);
    await within("restored again", 20_000, () => existsSync(join(workspace, "project")) && !existsSync(archive));
    const again = tree(workspace);
    delete again["sent-while-archived.txt"];
    assert.deepEqual(again, kept);
  } finally {
    store.close();
  }
  await a.stop();
});

// ── runners nobody holds (orphan-runners.test.ts, runner-sweep.test.ts) ──

/// runnerId (agents/process.ts): the runtime and the key's part (sandbox-name.ts `keyPart`).
function runnerId(kind: string, key: string): string {
  const clean = key.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 24);
  return `${kind}-${clean === key ? clean : `${clean}-${createHash("sha256").update(key).digest("hex").slice(0, 10)}`}`;
}

/// A real runner of `id` in `dir`, hosting `sleep 600` in a group of its own, as a station before left it.
async function hosted(dir: string, id: string, cwd: string) {
  const proc = spawn(runner, ["--id", id, "--dir", dir, "--cwd", cwd, "--", sleepBin, "600"], { stdio: "ignore", detached: true });
  proc.unref();
  const info = await within(`runner ${id} written`, 10_000, () => {
    try {
      const i = JSON.parse(readFileSync(join(dir, `${id}.json`), "utf8"));
      return typeof i.runner === "number" && typeof i.pid === "number" ? i : null;
    } catch {
      return null;
    }
  });
  pids.push(info.runner, info.pgid);
  return info as { runner: number; pid: number; pgid: number; startedAt: number };
}

test("runners at the start: one whose session is gone ended with its agent, the one a session holds taken up and kept; files of runners gone swept, and a pid reused or a person's terminal never killed", { skip: skipRunner, timeout: 90_000 }, async () => {
  const data = fresh("orph");
  const work = fresh("work");
  enrolled(data);
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }], maxNudges: 0 }));
  const dir = join(data, "run", "runners");
  mkdirSync(dir, { recursive: true });
  // (the session that holds its runner, there before the station starts)
  const store = openStore(data);
  const owned = "chat:c-own";
  try {
    store.insertSession({ key: owned, connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t-own", createdAt: Date.now(), lastActiveAt: Date.now(), title: "own" } as never);
    store.setRuntimeSessionId(owned, "11111111-2222-4333-8444-555555555555");
  } finally {
    store.close();
  }
  const [ownedId, goneId] = [runnerId("claude", owned), runnerId("claude", "chat:c-gone")];
  const [kept, gone] = [await hosted(dir, ownedId, work), await hosted(dir, goneId, work)];
  for (const r of [kept, gone]) assert.ok(alive(r.runner) && alive(r.pid), JSON.stringify(r));
  // A runner's files whose process ended (killed with its agent: nothing removed them).
  const dead = spawnSync(sleepBin, ["0"]).pid!;
  for (const ext of ["out", "err", "sock"]) writeFileSync(join(dir, `claude-dead-1.${ext}`), "x");
  writeFileSync(join(dir, "claude-dead-1.json"), JSON.stringify({ id: "claude-dead-1", runner: dead, pid: dead, pgid: dead, startedAt: Date.now() - 60_000, program: "claude", args: [], socket: join(dir, "claude-dead-1.sock") }));
  // A pid reused: a process of another's, alive, started long after its runner said it had (a year before).
  const stranger = spawn(sleepBin, ["600"], { stdio: "ignore", detached: true });
  stranger.unref();
  pids.push(stranger.pid!);
  for (const ext of ["out", "err"]) writeFileSync(join(dir, `claude-reused-2.${ext}`), "x");
  writeFileSync(join(dir, "claude-reused-2.json"), JSON.stringify({ id: "claude-reused-2", runner: stranger.pid, pid: stranger.pid, pgid: stranger.pid, startedAt: Date.now() - 365 * 86_400_000, program: "claude", args: [], socket: join(dir, "claude-reused-2.sock") }));
  // A person's terminal (term-…): never an agent's to end.
  const terminal = spawn(sleepBin, ["600"], { stdio: "ignore", detached: true });
  terminal.unref();
  pids.push(terminal.pid!);
  writeFileSync(join(dir, "term-3.json"), JSON.stringify({ id: "term-3", runner: terminal.pid, pid: terminal.pid, pgid: terminal.pid, startedAt: Date.now(), program: "sh", args: [], socket: join(dir, "term-3.sock") }));

  const a = await launch(data, { STILLFAIL_PARTS_DOOR: "1" });
  const detail = () => `${readdirSync(dir).join(",")}; ${a.err().slice(-3000)}`;
  // The one nobody holds: ended at the start, its agent's group with it.
  await within("the runner of a session gone ended, its agent too", 20_000, () => !alive(gone.runner) && !alive(gone.pid) && !alive(gone.pgid, true), detail);
  // Upkeep's sweep (asked now, not on its ten minutes): the files of runners gone, and of the one whose pid is
  // another's, go; nothing that is not a runner of this station's is killed.
  const kept1 = await http(a.door, "/parts/ask/upkeep", { method: "POST", body: {} });
  assert.equal(kept1.status, 200, `${kept1.body}\n${detail()}`);
  await within("the files of runners gone swept", 10_000, () => !existsSync(join(dir, "claude-dead-1.json")) && !existsSync(join(dir, "claude-reused-2.json")) && !existsSync(join(dir, `${goneId}.json`)), detail);
  for (const f of ["claude-dead-1.out", "claude-dead-1.err", "claude-dead-1.sock", "claude-reused-2.out", "claude-reused-2.err"]) assert.equal(existsSync(join(dir, f)), false, f);
  assert.equal(alive(stranger.pid!), true, "a process whose pid a runner's file names, started after it: not killed");
  assert.equal(alive(terminal.pid!), true, "a person's terminal: not killed");
  assert.equal(existsSync(join(dir, "term-3.json")), true, "a terminal's file kept while it runs");
  // The one its session holds: taken up, kept through the start and the sweep, its file there.
  assert.ok(alive(kept.runner) && alive(kept.pid), `the held runner kept: ${detail()}`);
  assert.equal(existsSync(join(dir, `${ownedId}.json`)), true, detail());
  // Again: nothing more ended.
  assert.equal((await http(a.door, "/parts/ask/upkeep", { method: "POST", body: {} })).status, 200);
  assert.ok(alive(kept.runner) && alive(kept.pid) && alive(stranger.pid!) && alive(terminal.pid!), detail());
  await a.stop();
});

// ── peers: /peer/ and peer_forward on loopback iroh, a peer stopped and one killed (peer-http.test.ts, peer-forward.test.ts, peer-gone.test.ts) ──

/// The control plane of the test's, its presence socket saying both stations are of one workspace.
async function controlPlane(state: (station: string) => Record<string, unknown>) {
  const sockets: WebSocket[] = [];
  const server = httpServer((_req, res) => void res.writeHead(200, { "content-type": "application/json" }).end("{}"));
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    const st = String(req.headers["x-stillfail-station"] ?? "");
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...state(st) }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

/// The data's station key, as the program says it.
const stationId = (data: string) => {
  const r = spawnSync(binary!, ["id", "--data", data], { env: { PATH: "/usr/bin:/bin", HOME: data }, encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
};

/// Reads `res` a piece at a time, pausing between pieces: a reader slower than what it reads.
function slowly(stream: NodeJS.ReadableStream & { pause(): unknown; resume(): unknown }, onEnd: (b: Buffer) => void, onError: (e: Error) => void, pauseMs = 3) {
  const parts: Buffer[] = [];
  stream.on("data", (d: Buffer) => {
    parts.push(d);
    stream.pause();
    setTimeout(() => stream.resume(), pauseMs);
  });
  stream.on("end", () => onEnd(Buffer.concat(parts)));
  stream.on("error", onError);
}

/// The TCP connections process `pid` has open to or from `port` (lsof's, as the machine says them).
function tcpOf(pid: number, port: number): string[] {
  const r = spawnSync("lsof", ["-nP", "-a", "-p", String(pid), `-iTCP:${port}`], { encoding: "utf8" });
  return r.stdout.split("\n").slice(1).filter((l) => l.trim() !== "");
}

test("peers: megabytes through /peer/ and peer_forward both ways at a slow reader's pace, byte for byte; the other station stopped mid-stream closes both at once, nothing kept open; killed, a peer's call found gone by its check and dialed anew once it is back", { skip: skip !== false ? skip : spawnSync("lsof", ["-v"]).error ? "no lsof here" : false, timeout: 120_000 }, async (t) => {
  const [dataA, dataB] = [fresh("pa"), fresh("pb")];
  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: idA, name: "alpha", ips: [`127.0.0.1:${portA}`] }, { id: idB, name: "beta", ips: [`127.0.0.1:${portB}`] }];
  const placeOf = (st: string) => ({ workspace: "w1", workspace_name: "Team", name: st === idA ? "alpha" : "beta", peers, grant_keys: null });
  const origin = await controlPlane(placeOf);
  for (const [data, id] of [[dataA, idA], [dataB, idB]] as const) {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin, station: id, relay_url: "", relay_urls: [], revocations: [], ...placeOf(id) }));
  }
  const env = (port: number) => ({ STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${port}`, HOME: process.env.HOME ?? tmpdir() });
  const a = await launch(dataA, env(portA), "9810");
  let b = await launch(dataB, env(portB), "9810");
  const store = openStore(dataA);
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: fresh("wa"), token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  } finally {
    store.close();
  }
  await within("alpha reaches beta", 30_000, async () => {
    const r = await tool(a.door, "t1", "station_list", { station: "beta" });
    return !r.error && JSON.parse(r.text).tasks === true;
  }, () => `${a.err().slice(-2000)}\n${b.err().slice(-2000)}`);

  // ── services on beta's machine: an HTTP one that takes a body slowly and says its hash, gives megabytes, and
  // streams for as long as it is read; a TCP one that echoes at a slow pace and one that streams for good ──
  const MiB = 1024 * 1024;
  const big = Buffer.concat(Array.from({ length: 4 * MiB / 64 }, (_, i) => createHash("sha512").update(`b${i}`).digest()));
  const streams = { open: 0, closed: 0 };
  const web = httpServer((req, res) => {
    if (req.url === "/upload") {
      slowly(req, (body) => void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ bytes: body.length, sha: sha256(body) })), () => {}, 2);
    } else if (req.url === "/big") {
      res.writeHead(200, { "content-type": "application/octet-stream" });
      let at = 0;
      const more = () => {
        while (at < big.length) {
          const piece = big.subarray(at, at + 65_536);
          at += piece.length;
          if (!res.write(piece)) return void res.once("drain", more);
        }
        res.end();
      };
      more();
    } else if (req.url === "/forever") {
      streams.open++;
      res.on("close", () => streams.closed++);
      res.writeHead(200, { "content-type": "application/octet-stream" });
      const piece = Buffer.alloc(16_384, "f");
      const tick = setInterval(() => (res.destroyed ? clearInterval(tick) : res.write(piece)), 10);
      res.on("close", () => clearInterval(tick));
    } else res.writeHead(404).end();
  });
  await new Promise<void>((r) => web.listen(0, "127.0.0.1", () => r()));
  closers.push(() => { web.closeAllConnections(); web.close(); });
  const webPort = (web.address() as AddressInfo).port;
  const echo = tcpServer({ allowHalfOpen: true }, (socket) => {
    socket.on("error", () => {});
    // (echoes what it reads, reading the next only once the last is written: a peer as slow as its writes drain)
    socket.on("data", (d) => {
      if (!socket.write(d)) {
        socket.pause();
        socket.once("drain", () => socket.resume());
      }
    });
    socket.on("end", () => socket.end());
  });
  await new Promise<void>((r) => echo.listen(0, "127.0.0.1", () => r()));
  closers.push(() => echo.close());
  const echoPort = (echo.address() as AddressInfo).port;
  const flood = { open: 0, closed: 0 };
  const forever = tcpServer((socket) => {
    flood.open++;
    socket.on("error", () => {});
    socket.on("close", () => flood.closed++);
    const piece = Buffer.alloc(16_384, "g");
    const tick = setInterval(() => (socket.destroyed ? clearInterval(tick) : socket.write(piece)), 10);
    socket.on("close", () => clearInterval(tick));
  });
  await new Promise<void>((r) => forever.listen(0, "127.0.0.1", () => r()));
  closers.push(() => forever.close());
  const foreverPort = (forever.address() as AddressInfo).port;

  // ── /peer/: 4 MiB up, taken slowly there; 4 MiB down, read slowly here ──
  const upload = randomBytes(4 * MiB + 13);
  const up = await http(a.door, `/peer/beta/${webPort}/upload`, { method: "POST", body: upload, headers: { "content-type": "application/octet-stream" } });
  assert.equal(up.status, 200, up.body.toString().slice(0, 500));
  assert.deepEqual(up.json, { bytes: upload.length, sha: sha256(upload) });
  const down = await new Promise<Buffer>((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port: a.door, path: `/peer/beta/${webPort}/big`, agent: false }, (res) => {
      assert.equal(res.statusCode, 200);
      slowly(res, resolve, reject);
    });
    req.on("error", reject);
    req.end();
  });
  assert.equal(down.length, big.length);
  assert.equal(sha256(down), sha256(big));

  // ── peer_forward: 4 MiB each way through beta's echo, written all at once and read slowly here ──
  const opened = await tool(a.door, "t1", "peer_forward", { station: "beta", port: echoPort });
  assert.equal(opened.error, false, opened.text);
  const local = Number(JSON.parse(opened.text).local.split(":")[1]);
  const sent = randomBytes(4 * MiB + 7);
  const echoed = await new Promise<Buffer>((resolve, reject) => {
    const sock = tcpConnect({ host: "127.0.0.1", port: local, allowHalfOpen: true });
    slowly(sock, resolve, reject);
    sock.once("connect", () => {
      sock.write(sent);
      sock.end();
    });
  });
  assert.equal(echoed.length, sent.length);
  assert.equal(sha256(echoed), sha256(sent));

  // ── beta stopped (its process told to stop, as a person or an update stops it) while a /peer/ answer and a forward
  // stream: both closed at once on alpha, nothing of them left open there ──
  const toFlood = JSON.parse((await tool(a.door, "t1", "peer_forward", { station: "beta", port: foreverPort })).text);
  const floodLocal = Number(toFlood.local.split(":")[1]);
  const ending = () => ({ bytes: 0, ended: null as null | string, at: 0 });
  const viaPeer = ending();
  const viaForward = ending();
  const ended = (e: ReturnType<typeof ending>, how: string) => {
    e.ended ??= how;
    e.at ||= Date.now();
  };
  const req = request({ host: "127.0.0.1", port: a.door, path: `/peer/beta/${webPort}/forever`, agent: false }, (res) => {
    res.on("data", (d: Buffer) => (viaPeer.bytes += d.length));
    res.on("end", () => ended(viaPeer, "end"));
    res.on("error", (e) => ended(viaPeer, `error ${e.message}`));
    res.on("close", () => ended(viaPeer, "close"));
  });
  req.on("error", (e) => ended(viaPeer, `error ${e.message}`));
  req.end();
  const fsock = tcpConnect({ host: "127.0.0.1", port: floodLocal });
  fsock.on("data", (d: Buffer) => (viaForward.bytes += d.length));
  fsock.on("error", (e) => ended(viaForward, `error ${e.message}`));
  fsock.on("close", () => ended(viaForward, "close"));
  closers.push(() => fsock.destroy());
  await within("both streaming from beta", 15_000, () => viaPeer.bytes > 64 * 1024 && viaForward.bytes > 64 * 1024 && streams.open === 1 && flood.open === 1, () => JSON.stringify({ viaPeer, viaForward, streams, flood }));
  assert.ok(tcpOf(a.child.pid!, a.door).some((l) => /ESTABLISHED/.test(l)), "the /peer/ request open on alpha's door");
  const stoppedAt = Date.now();
  await b.stop();
  const STOP_MS = 5_000;
  await within("the /peer/ answer ended as beta stopped", STOP_MS, () => viaPeer.ended !== null, () => JSON.stringify({ viaPeer, ms: Date.now() - stoppedAt }));
  await within("the forward's connection closed as beta stopped", STOP_MS, () => viaForward.ended !== null, () => JSON.stringify({ viaForward, ms: Date.now() - stoppedAt }));
  await within("alpha let go of the connections it served for beta", STOP_MS, () => tcpOf(a.child.pid!, floodLocal).every((l) => /LISTEN/.test(l)) && !tcpOf(a.child.pid!, a.door).some((l) => /ESTABLISHED/.test(l)), () => `${tcpOf(a.child.pid!, floodLocal).join("\n")}\n${tcpOf(a.child.pid!, a.door).join("\n")}`);
  // (beta's services here let go too: nothing of the stream kept open on beta's side)
  await within("beta's side of both streams closed", STOP_MS, () => streams.closed === 1 && flood.closed === 1, () => JSON.stringify({ streams, flood }));
  for (const p of [local, floodLocal]) assert.equal((await tool(a.door, "t1", "peer_forward", { close: p })).error, false);

  // ── a peer's call (peer.ts `peerCall`, gate/peer.mbt) on the connection kept, beta killed (SIGKILL: gone without a
  // word): the next call found gone by its check (CHECK_MS + HEARD_MS), not left to the connection's ten minutes;
  // beta started again with its key, the next dialed anew and answered ──
  const describe = () => tool(a.door, "t1", "station_list", { station: "beta" });
  const reached = (r: { text: string; error: boolean }) => {
    if (r.error) return false;
    try {
      return JSON.parse(r.text).tasks === true;
    } catch {
      return false;
    }
  };
  b = await launch(dataB, env(portB), "9810");
  await within("alpha reaches beta started again", 30_000, async () => reached(await describe()), () => b.err().slice(-2000));
  assert.ok(reached(await describe()), "a call on the connection kept");
  b.child.kill("SIGKILL");
  await b.ended;
  const killedAt = Date.now();
  const lost = await describe();
  const took = Date.now() - killedAt;
  assert.equal(reached(lost), false, `a call to beta killed answered as if it were there: ${lost.text}`);
  assert.match(lost.text, /gone|offline|reach|answer|connect|unavailable/i, lost.text);
  assert.ok(took < 15_000, `the call to beta killed came back ${took} ms after it was asked`);
  t.diagnostic(`beta killed: the next call came back in ${took} ms: ${lost.text}`);
  b = await launch(dataB, env(portB), "9810");
  await within("the next call dialed anew and answered", 30_000, async () => reached(await describe()), () => b.err().slice(-2000));
  // Alpha the same process throughout, serving its door.
  assert.equal(a.child.exitCode, null, a.err().slice(-3000));
  assert.equal((await tool(a.door, "t1", "peer_forward", {})).text, "No forwarded ports.");
  await Promise.all([a.stop(), b.stop()]);
});

// ── accounts (accounts-routes.test.ts, accounts-config.test.ts) ──

test("accounts: what cannot run refused in words with config.json untouched; a key paused and used again with its key and models; one withheld from a joined workspace kept so through other edits; the station serving throughout", { skip, timeout: 60_000 }, async () => {
  const data = fresh("acc");
  enrolled(data, { joined: [{ workspace: "W2", workspace_name: "Two", name: "here", peers: [], revocations: [] }, { workspace: "W3", workspace_name: "Three", name: "here", peers: [], revocations: [] }] });
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }, { id: "cx", runtime: "codex", home: "homes/cx" }] }));
  const a = await launch(data, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_ANTHROPIC_API: "http://127.0.0.1:9", STILLFAIL_OPENAI_API: "http://127.0.0.1:9" });
  const cfg = () => JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
  const profileOf = (id: string) => cfg().profiles.find((p: any) => p.id === id);
  const put = (id: string, body: unknown) => http(a.door, `/admin-api/profiles/${id}`, { method: "PUT", body });
  const views = async () => {
    const r = await within("the accounts ready", 15_000, async () => {
      const v = await http(a.door, "/admin-api/profiles");
      return v.status === 200 ? v : null;
    }, () => a.err().slice(-2000));
    return r.json as any[];
  };
  const view = async (id: string) => (await views()).find((p) => p.id === id);
  await views();

  // ── what cannot run: refused in words, config.json as it was, byte for byte ──
  const before = readFileSync(join(data, "config.json"), "utf8");
  for (const [what, id, body, words] of [
    ["an id not of lowercase letters, digits and dashes", "Bad_Id", { runtime: "claude", access: { kind: "anthropic-api", key: "sk-1" } }, /lowercase|id/i],
    ["a key's kind with no key", "nokey", { runtime: "claude", access: { kind: "opencode-go" } }, /key/i],
    ["a provider not known", "noprov", { access: { kind: "api-provider", provider: "nope", key: "k" } }, /provider/i],
    ["enabled not a boolean", "cc", { enabled: "no" }, /enabled must be a boolean/],
    ["a workspace that is a path", "cc", { workspaces: ["../x"] }, /workspace/i],
  ] as const) {
    const r = await put(id, body);
    assert.ok(r.status >= 400 && r.status < 500, `${what}: ${r.status} ${r.body}`);
    assert.match(String(r.json?.error ?? r.body), words, `${what}: ${r.body}`);
    assert.equal(readFileSync(join(data, "config.json"), "utf8"), before, `${what}: config.json untouched`);
  }
  const unknown = await http(a.door, "/admin-api/profiles/nope", { method: "DELETE" });
  assert.equal(unknown.status, 400, unknown.body.toString());
  assert.match(String(unknown.json?.error), /unknown profile nope/);
  assert.equal(readFileSync(join(data, "config.json"), "utf8"), before);
  assert.equal(a.child.exitCode, null, a.err().slice(-3000));

  // ── an API key paused and used again: its key and models kept; paused, not checked ──
  assert.equal((await put("key", { runtime: "claude", access: { kind: "anthropic-api", key: "sk-my-secret" }, models: ["opus"] })).status, 200);
  await within("the key profile made", 10_000, async () => (await view("key"))?.enabled === true);
  assert.ok(!JSON.stringify(await views()).includes("sk-my-secret"), "a key is never shown");
  assert.equal((await put("key", { enabled: false })).status, 200);
  await within("the key paused", 10_000, async () => (await view("key"))?.enabled === false);
  assert.equal(profileOf("key").access.key, "sk-my-secret");
  assert.deepEqual(profileOf("key").models, ["opus"]);
  const check = await http(a.door, "/admin-api/profiles/key/check", { method: "POST", body: {} });
  assert.equal(check.status, 409, check.body.toString());
  assert.equal((await put("key", { name: "Backup" })).status, 200);
  assert.equal(profileOf("key").enabled, false, "other edits keep it paused");
  assert.equal(profileOf("key").name, "Backup");
  assert.equal((await put("key", { enabled: true })).status, 200);
  await within("the key used again", 10_000, async () => (await view("key"))?.enabled === true);
  assert.equal(profileOf("key").access.key, "sk-my-secret");
  assert.deepEqual(profileOf("key").models, ["opus"]);
  assert.equal(profileOf("key").name, "Backup");

  // ── withheld from a joined workspace: kept through other edits, given back whole; null keeps it home's alone ──
  assert.deepEqual((await view("cc"))?.workspaces, ["W2", "W3"], "by default every joined workspace");
  assert.equal((await put("cc", { workspaces: ["W3", "W3"] })).status, 200);
  assert.deepEqual(profileOf("cc").withheld, ["W2"]);
  await within("cc no longer serving W2", 10_000, async () => JSON.stringify((await view("cc"))?.workspaces) === JSON.stringify(["W3"]));
  assert.equal((await put("cc", { name: "Claude" })).status, 200);
  assert.deepEqual(profileOf("cc").withheld, ["W2"], "kept through another edit");
  assert.deepEqual((await view("cx"))?.workspaces, ["W2", "W3"], "the others untouched");
  assert.equal((await put("cc", { workspaces: null })).status, 200);
  assert.deepEqual(profileOf("cc").withheld, ["W2", "W3"]);
  await within("cc serving none of the joined", 10_000, async () => JSON.stringify((await view("cc"))?.workspaces) === "[]");
  assert.equal((await put("cc", { workspaces: ["W2", "W3"] })).status, 200);
  assert.equal(profileOf("cc").withheld, undefined, "all given back takes it back");

  // the station the same process, serving
  assert.equal((await http(a.door, "/admin-api/overview")).status, 200);
  assert.equal(a.child.exitCode, null);
  await a.stop();
});

// ── a chat's workspace limit (workspace-size.test.ts) ──

test("workspace_limit: set and kept over a restart, its chat's own; what is not a positive whole number of GiB, or a station that is no path to one, refused", { skip, timeout: 60_000 }, async () => {
  const data = fresh("wsl");
  enrolled(data, { station: "st-here", peers: [{ id: "st-here", name: "here" }] });
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [] }));
  const insert = () => {
    const store = openStore(data);
    try {
      for (const [k, t] of [["s1", "t1"], ["s2", "t2"]] as const) {
        if (store.getSession(k) === undefined || store.getSession(k) === null) store.insertSession({ key: k, connect: "ember", runtime: "claude", profile: "cc", workspace: fresh(`w${k}`), token: t, createdAt: Date.now(), lastActiveAt: Date.now() });
      }
    } finally {
      store.close();
    }
  };
  let a = await launch(data, { STILLFAIL_PARTS_DOOR: "1" });
  insert();
  const limit = async (token: string, args: unknown = {}) => {
    const r = await tool(a.door, token, "workspace_limit", args);
    return r.error ? r : JSON.parse(r.text);
  };
  assert.deepEqual(await limit("t1"), { station: "this station", limit_gib: 10 });
  assert.deepEqual(await limit("t1", { limit_gib: 25 }), { station: "this station", limit_gib: 25 });
  assert.deepEqual(await limit("t2"), { station: "this station", limit_gib: 10 }, "another chat's own");
  // (a number given as its text is read as the number it says, as the TypeScript's door reads it: tools/mcp.ts `typed`)
  assert.deepEqual(await limit("t2", { limit_gib: "20" }), { station: "this station", limit_gib: 20 });
  for (const bad of [0, -3, 1.5, "twenty", "1.5", 1e300, true, {}]) {
    const r = await tool(a.door, "t1", "workspace_limit", { limit_gib: bad });
    assert.equal(r.error, true, `${JSON.stringify(bad)}: ${r.text}`);
    assert.match(r.text, /positive whole|whole number|limit/i, `${JSON.stringify(bad)}: ${r.text}`);
  }
  for (const station of ["../../etc", "/etc/passwd", "st-other", "a\u0000b"]) {
    const r = await tool(a.door, "t1", "workspace_limit", { station, limit_gib: 5 });
    assert.equal(r.error, true, `${JSON.stringify(station)}: ${r.text}`);
  }
  assert.deepEqual(await limit("t1"), { station: "this station", limit_gib: 25 }, "nothing refused was kept");
  assert.equal((await http(a.door, "/parts/ask/workspaceWatch.limit", { method: "POST", body: ["s1", ""] })).json, 25 * 1024 ** 3);
  // Kept over a restart: the next process reads it as it was set.
  await a.stop();
  a = await launch(data, { STILLFAIL_PARTS_DOOR: "1" });
  assert.deepEqual(await limit("t1"), { station: "this station", limit_gib: 25 });
  assert.deepEqual(await limit("t2"), { station: "this station", limit_gib: 20 });
  assert.equal((await http(a.door, "/parts/ask/workspaceWatch.limit", { method: "POST", body: ["s1", ""] })).json, 25 * 1024 ** 3);
  assert.equal(a.child.exitCode, null);
  await a.stop();
});
