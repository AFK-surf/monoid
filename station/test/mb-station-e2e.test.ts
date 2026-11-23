// The whole station as the MoonBit program runs it itself, with no Node and no main.js (station/mb/src/station_main,
// run by stillfail-reader as `stillfail-reader <command>`). station_main is frozen for new TypeScript features
// (station/AGENTS.md), so nothing here holds it to the living TypeScript, its hooks, the mesh addon or the catalog:
// only to itself and to what does not move (node:os, Date). Its parts' registry, its channel, its previews, what
// sys.c says of the machine, its children and locks, and `run` under a launcher of the test's (ops/launcher.ts's channel
// on a descriptor): ready, serving, its heartbeat, the loopback port, the status socket, the agents' door, a handover to
// a second process with what it carries, and a stop that leaves no process behind. Every program is run with a PATH
// that names no directory with a Node in it.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, createPublicKey, verify } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer, type Server } from "node:net";
import { createServer as httpServer, request } from "node:http";
import os, { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { deflateSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
/// (the tests' program, its harness: the station's own commands are the reader's)
const harnessProgram = mbHarnessBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : harnessProgram === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
// (short: a Unix socket's path is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sf-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// The launcher's control channel handed to `run` (its fd 5).
const controlPipe = (c: ChildProcess) => (c.stdio as readonly unknown[])[5] as import("node:net").Socket;

/// An environment with no Node: an empty PATH of its own, HOME and TMPDIR as given.
const noNode = (more: Record<string, string> = {}) => ({ PATH: fresh("path"), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), ...more });

/// The program run to its end.
function run(args: string[], o: { env?: Record<string, string>; input?: string } = {}) {
  const r = spawnSync(binary!, args, { env: o.env ?? noNode(), input: o.input ?? "", encoding: "utf8", timeout: 60_000 });
  return { code: r.status, out: r.stdout, err: r.stderr };
}

// ── the harness ──

let harnessProc: { send: (op: string, a?: Record<string, unknown>) => Promise<any> } | null = null;
function harness() {
  if (harnessProc !== null) return harnessProc;
  const child = spawn(harnessProgram!, ["--builder", "harness-station-main", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "pipe"], env: noNode() });
  children.push(child);
  let seq = 0;
  const waiting = new Map<number, (v: any) => void>();
  let stderr = "";
  child.stderr!.on("data", (d) => (stderr += d));
  createInterface({ input: child.stdout! }).on("line", (line) => {
    const m = JSON.parse(line);
    waiting.get(m.id)?.(m);
    waiting.delete(m.id);
  });
  child.on("exit", (code) => {
    for (const w of waiting.values()) w({ error: `the harness ended (${code}): ${stderr}` });
  });
  harnessProc = {
    send: (op, a = {}) =>
      new Promise((resolve) => {
        seq += 1;
        waiting.set(seq, resolve);
        child.stdin!.write(`${JSON.stringify({ id: seq, op, ...a })}\n`);
      }),
  };
  return harnessProc;
}
const ok = async (op: string, a: Record<string, unknown> = {}) => {
  const said = await harness().send(op, a);
  assert.equal(said.error, undefined, `${op}: ${said.error}`);
  return said.ok;
};

// ── the commands ──

/// A control plane of the test's (cloud/provider.ts's paths): each enroll and join answered as `answer` says, what was
/// asked of it kept.
async function plane(answer: (path: string, body: any) => { status: number; body: unknown }) {
  const asked: { path: string; body: any }[] = [];
  const server = httpServer((req, res) => {
    let text = "";
    req.on("data", (d) => (text += d));
    req.on("end", () => {
      const body = JSON.parse(text);
      asked.push({ path: req.url!, body });
      const a = answer(req.url!, body);
      res.writeHead(a.status, { "content-type": "application/json" }).end(JSON.stringify(a.body));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  after(() => server.close());
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, asked };
}

/// Whether `signature` is the station's (its id, the Ed25519 key's public half) over `message`.
function signedBy(id: string, message: string, signature: string): boolean {
  const key = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(id, "hex")]), format: "der", type: "spki" });
  return verify(null, Buffer.from(message), key, Buffer.from(signature, "hex"));
}

/// The program run to its end without holding this process (the control plane of the test's answers meanwhile).
function runSoon(args: string[]): Promise<{ code: number | null; out: string; err: string }> {
  return new Promise((resolve) => {
    const child = spawn(binary!, args, { env: noNode(), stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    let out = "";
    let err = "";
    child.stdout!.on("data", (d) => (out += d));
    child.stderr!.on("data", (d) => (err += d));
    child.on("close", (code) => resolve({ code, out, err }));
  });
}

test("enroll and --join: the proof the plane is asked for is the station's own Ed25519 signature, and its place is written", { skip }, async () => {
  const p = await plane((path, body) => {
    if (path.endsWith("/join")) return { status: 200, body: { workspace: `w-${body.token}`, workspace_name: `团队 ${body.token}`, name: "mac" } };
    return { status: 200, body: { workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: null } };
  });
  const data = fresh("enroll");
  const id = run(["id", "--data", data]).out.trim();
  assert.match(id, /^[0-9a-f]{64}$/);
  const said = await runSoon(["enroll", `${p.origin}/`, "t1", "--data", data]);
  assert.equal(said.code, 0, said.err);
  const asked = p.asked.at(-1)!;
  assert.equal(asked.path, "/v1/stations/enroll");
  assert.ok(signedBy(id, `stillfail-station-enroll-v1:${p.origin}:t1:${id}`, asked.body.signature), "its proof is the station's");
  assert.ok(!signedBy(id, `stillfail-station-enroll-v1:${p.origin}:t2:${id}`, asked.body.signature), "over its own token alone");
  const place = JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8"));
  assert.deepEqual([place.station, place.workspace, place.origin], [id, "w1", p.origin]);
  const joined = await runSoon(["enroll", p.origin, "t2", "--join", "--data", data]);
  assert.equal(joined.code, 0, joined.err);
  const join_ = p.asked.at(-1)!;
  assert.equal(join_.path, "/v1/stations/join");
  assert.ok(signedBy(id, `stillfail-station-enroll-v1:${p.origin}:t2:${id}`, join_.body.signature), "its join's proof is the station's");
});

test("the parts' registry (parts.mbt): tools offered, what is carried over and taken up, door places, cards, streams", { skip }, async () => {
  assert.deepEqual(await ok("parts"), {
    tools: ["always", "offered"],
    toolsOff: ["always"],
    carried: { a: { n: 1 }, b: "two" },
    tookEarly: { late: { kept: true } },
    tookNow: { a: { n: 2 } },
    door: ["/peer", "/peer/x", null, null],
    card: ["retire", null],
    stream: [true, false],
    twice: ["a is carried over twice", "the overview's f is said twice"],
    mayView: [true, false],
    overview: { f: "zh:me" },
    ended: ["s1"],
    connected: 2,
    doorUrl: "http://127.0.0.1:1/mcp",
  });
});

test("channel: said, set on the config when no station takes the ask, said again", { skip }, () => {
  const data = fresh("data");
  const app = fresh("app");
  assert.equal(run(["channel", "--app", app, "--data", data]).out.trim(), "stable");
  const set = run(["channel", "beta", "--app", app, "--data", data]);
  assert.equal(set.code, 0, set.err);
  assert.equal(set.out.trim(), "beta");
  assert.equal(JSON.parse(readFileSync(join(data, "config.json"), "utf8")).updateChannel, "beta");
  assert.equal(run(["channel", "--app", app, "--data", data]).out.trim(), "beta");
  const bad = run(["channel", "nightly", "--app", app, "--data", data]);
  assert.equal(bad.code, 1);
  assert.match(bad.err, /nightly/);
  assert.equal(run(["channel", "a", "b", "--data", data]).code, 2);
  // update: in no workspace, refused with its words
  const update = run(["update", "--app", app, "--data", data]);
  assert.equal(update.code, 1);
  assert.match(update.err, /^Error: \S/);
  assert.equal(run(["update", "--data", data]).code, 2);
});

test("the program's times in ISO 8601, as Date says them", { skip }, async () => {
  for (const ms of [0, 1_794_925_142_744, 951_782_400_000, -86_400_001]) assert.equal(await ok("iso", { ms }), new Date(ms).toISOString());
});

// ── the images ──

/// A PNG of `w`×`h` (RGBA), stripes and a gradient, clear on its left third where `clear`.
function png(w: number, h: number, clear = false): Buffer {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const i = y * (w * 4 + 1) + 1 + x * 4;
      raw[i] = Math.floor((x * 255) / w);
      raw[i + 1] = Math.floor((y * 255) / h);
      raw[i + 2] = (Math.floor(x / 7) + Math.floor(y / 5)) % 2 === 0 ? 200 : 30;
      raw[i + 3] = clear && x < w / 3 ? 64 : 255;
    }
  }
  const crc = (b: Buffer) => {
    let c = ~0;
    for (const byte of b) {
      c ^= byte;
      for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
    }
    return ~c >>> 0;
  };
  const chunk = (type: string, body: Buffer) => {
    const t = Buffer.concat([Buffer.from(type), body]);
    const len = Buffer.alloc(4);
    len.writeUInt32BE(body.length);
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(t));
    return Buffer.concat([len, t, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr.set([8, 6, 0, 0, 0], 8);
  // (stored, level 0: far over 24 KiB, as a screenshot of a large screen is)
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 0 })), chunk("IEND", Buffer.alloc(0))]);
}

test("the program's previews: none for a small image, a JPEG of a large one kept and asked again, a kept WebP taken", { skip }, async () => {
  const dir = fresh("thumbs");
  const size = (b: Buffer) => (b[0] === 0x89 ? [b.readUInt32BE(16), b.readUInt32BE(20)] : jpegSize(b));
  // preview: <= 300 KiB returns null; large PNG makes <id>.p.jpg and hits cache; pre-existing <id>.p.webp hits cache
  const smallPreview = join(dir, "small-preview.png");
  writeFileSync(smallPreview, png(200, 200));
  assert.ok(readFileSync(smallPreview).length <= 300 * 1024);
  assert.equal(await ok("preview", { image: smallPreview, dir: join(dir, "mb-preview") }), null);

  const bigPreview = join(dir, "big-preview.png");
  writeFileSync(bigPreview, png(2400, 1400));
  assert.ok(readFileSync(bigPreview).length > 300 * 1024);
  const previewDir = join(dir, "mb-preview");
  const bigId = createHash("sha256").update(bigPreview).digest("hex").slice(0, 32);
  const prev1 = await ok("preview", { image: bigPreview, dir: previewDir });
  assert.ok(prev1 !== null);
  assert.equal(prev1.type, "image/jpeg");
  assert.equal(prev1.path, join(previewDir, `${bigId}.p.jpg`));
  assert.ok(readFileSync(prev1.path).length * 2 < readFileSync(bigPreview).length);
  const [pw, ph] = size(readFileSync(prev1.path));
  assert.ok(pw <= 2048 && ph <= 2048);
  assert.deepEqual(await ok("preview", { image: bigPreview, dir: previewDir }), prev1);

  const webpCached = join(dir, "webp-cached.png");
  writeFileSync(webpCached, png(2400, 1400));
  const webpId = createHash("sha256").update(webpCached).digest("hex").slice(0, 32);
  const webpPath = join(previewDir, `${webpId}.p.webp`);
  writeFileSync(webpPath, Buffer.from("RIFF0000WEBP"));
  assert.deepEqual(await ok("preview", { image: webpCached, dir: previewDir }), { path: webpPath, type: "image/webp" });
});

function jpegSize(b: Buffer): [number, number] {
  let i = 2;
  while (i < b.length) {
    const marker = b[i + 1]!;
    const len = b.readUInt16BE(i + 2);
    if (marker >= 0xc0 && marker <= 0xc2) return [b.readUInt16BE(i + 7), b.readUInt16BE(i + 5)];
    i += 2 + len;
  }
  return [0, 0];
}

// ── the machine ──

test("what sys.c says of the machine, as node:os says it", { skip }, async () => {
  const m = await ok("machine");
  assert.equal(m.cpus.length, os.cpus().length);
  assert.equal(m.totalmem, os.totalmem());
  assert.ok(m.freemem > 0 && m.freemem <= m.totalmem);
  assert.ok(m.rss > 0);
  assert.ok(m.cpus.every((c: any) => c.times.user >= 0 && c.times.idle > 0) && m.cpus.some((c: any) => c.times.user > 0));
  assert.equal(m.loadavg.length, 3);
  assert.ok(Math.abs(m.uptime - os.uptime()) < 5);
  assert.equal(await ok("hostname"), os.hostname());
  assert.equal(await ok("homedir"), os.homedir());
  assert.equal(await ok("tmpdir"), os.tmpdir());
  assert.deepEqual(await ok("platform"), { platform: process.platform, arch: process.arch });
  assert.ok(Math.abs((await ok("wallMs")) - Date.now()) < 5_000);
  const lan = await ok("lanAddrs");
  const nodeLan = Object.values(os.networkInterfaces()).flat().filter((a) => a !== undefined && !a.internal).map((a) => a!.address);
  for (const a of lan) assert.ok(nodeLan.some((n) => n.split("%")[0] === a.address.split("%")[0]), `${a.address} is one node:os names`);
  const disk = await ok("diskOf", { path: tmpdir() });
  assert.ok(disk.total > 0 && disk.free > 0 && disk.free <= disk.total);
  assert.equal(await ok("diskOf", { path: "/no/such/place" }), null);
  await ok("envSet", { name: "SF_E2E", value: "值 1" });
  assert.equal(await ok("env", { name: "SF_E2E" }), "值 1");
  assert.equal(await ok("env", { name: "SF_NONE" }), null);
  const usage = await ok("processUsage", { pids: [process.pid, 999_999_9] });
  if (process.platform === "darwin") assert.ok(usage[0].cpuNs > 0 && usage[0].footprint > 0);
  else assert.equal(usage[0], null);
  assert.equal(usage[1], null);
});

test("children started, followed to their end, given input and signals; a lock of a file held between two processes", { skip }, async () => {
  const dir = fresh("procs");
  const echo = await ok("spawn", { program: "/bin/sh", args: ["-c", 'printf "%s|%s" "$SF_X" "$(pwd)"; printf err >&2; exit 3'], env: { SF_X: "x 值" }, cwd: dir });
  assert.deepEqual([echo.code, echo.signal, echo.stdout, echo.stderr], [3, null, `x 值|${(await import("node:fs")).realpathSync(dir)}`, "err"]);
  const cat = await ok("spawn", { program: "cat", args: [], env: { PATH: "/bin:/usr/bin" }, input: "given on stdin\n" });
  assert.equal(cat.stdout, "given on stdin\n");
  const appended = join(dir, "out.log");
  await ok("spawn", { program: "/bin/sh", args: ["-c", "echo one"], stdout: appended });
  await ok("spawn", { program: "/bin/sh", args: ["-c", "echo two"], stdout: appended });
  assert.equal(readFileSync(appended, "utf8"), "one\ntwo\n");
  const missing = await harness().send("spawn", { program: "/no/such/program", args: [] });
  assert.match(missing.error, /^ENOENT/);
  // a group of its own, ended with its children
  const sleeper = await ok("spawn", { program: "/bin/sh", args: ["-c", "sleep 30 & sleep 30 & wait"], env: { PATH: "/bin:/usr/bin" }, group: true, detach: true });
  const group = () => spawnSync("pgrep", ["-g", String(sleeper.pid)], { encoding: "utf8" }).stdout.trim().split("\n").filter((p) => p !== "");
  try {
    assert.equal(await ok("pidAlive", { pid: sleeper.pid }), true);
    // (both children in its group before the group is signalled: a child the shell forks as the signal walks the group
    // is not in it yet, takes no signal pending on the shell, and is left sleeping in the group once the shell ends)
    for (let i = 0; i < 100 && group().length < 3; i++) await new Promise((r) => setTimeout(r, 20));
    assert.equal(group().length, 3, "the shell and both its children in its group");
    assert.equal(await ok("kill", { pid: sleeper.pid, signal: "SIGTERM", group: true }), true);
    for (let i = 0; i < 100 && (await ok("pidAlive", { pid: sleeper.pid })); i++) await new Promise((r) => setTimeout(r, 20));
    // (a zombie until it is waited for: the program's thread waits for it)
    // (its children, orphaned as it ended, reaped by the system a moment after)
    for (let i = 0; i < 100 && group().length > 0; i++) await new Promise((r) => setTimeout(r, 20));
    assert.deepEqual(group(), [], "nothing of its group left");
  } finally {
    // (what a failed assertion leaves of the group, not left sleeping past the test)
    try {
      process.kill(-sleeper.pid, "SIGKILL");
    } catch {}
  }
  assert.equal(await ok("parentPid"), process.pid);
  // the lock: taken, then a second process waits for it until it is let go
  const lock = join(dir, "pack.lock");
  const held = await ok("fileLock", { path: lock });
  const other = spawn(harnessProgram!, ["--builder", "harness-station-main", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "inherit"], env: noNode() });
  children.push(other);
  const lines = createInterface({ input: other.stdout! });
  const got: string[] = [];
  lines.on("line", (l) => got.push(l));
  other.stdin!.write(`${JSON.stringify({ id: 1, op: "fileLock", path: lock })}\n`);
  await new Promise((r) => setTimeout(r, 300));
  assert.deepEqual(got, [], "the second waits while the first holds it");
  assert.equal(await ok("fileUnlock", held), true);
  for (let i = 0; i < 200 && got.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
  assert.deepEqual(JSON.parse(got[0]!), { id: 1, ok: { handle: 1 } });
  other.stdin!.end();
  if (other.exitCode === null && other.signalCode === null) await new Promise<void>((r) => other.once("exit", () => r()));
  assert.equal((readFileSync(lock).length), 0, "never written");
});

test("stdin writes are non-blocking, drain multi-chunk input, and kill stalled children past STILLFAIL_STDIN_MOST", { skip }, async () => {
  const r = await ok("stdinBackpressure");
  assert.equal(r.catOk, true, "multi-chunk write to cat drains cleanly and closes with EOF");
  assert.equal(r.rejected, true, "writing past STILLFAIL_STDIN_MOST returns false");
  assert.ok(r.writeMs < 2_000, `writes must not block the event loop (took ${r.writeMs}ms)`);
  assert.ok(r.totalMs < 5_000, `stalled child must be killed promptly (took ${r.totalMs}ms)`);
  assert.equal(r.stalledCode, null);
  assert.equal(r.stalledSignal, "SIGKILL");
  assert.equal(r.stalledAlive, false, "no orphan process left alive");
  assert.equal(r.quickCode, 0);
  assert.equal(r.quickSignal, null);
  assert.equal(r.lateWrite, false, "exited child without end_input cleans up stdin handle");
});

test("flooding child stdout stays backpressured and respects @effect.timeout", { skip }, async () => {
  const r = await ok("stdoutBackpressure");
  assert.equal(r.timedOut, true, `expected timeout, got ${JSON.stringify(r)}`);
  assert.equal(r.truncated, true, `expected truncated output, got ${JSON.stringify(r)}`);
  assert.equal(r.keptBytes, 1048576, `expected 1 MiB kept, got ${JSON.stringify(r)}`);
  assert.ok(r.elapsedMs >= 1200 && r.elapsedMs < 5000, `expected timeout near 1500ms, took ${r.elapsedMs}ms`);
  assert.ok(r.rssBefore > 0, `expected rssBefore > 0, got ${r.rssBefore}`);
  assert.ok(r.rssPeak - r.rssBefore < 128 * 1024 * 1024, `RSS grew too much: before=${r.rssBefore} peak=${r.rssPeak} after=${r.rssAfter}`);
  assert.equal(r.alive, false, "child process group must be killed and reaped");
});

// ── run, under a launcher of the test's ──

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; heard: (what: string, text: string) => Promise<void>; stderr: () => string };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts): its two listeners bound here and handed down
/// (closed here once it has them), its control channel the fourth's pipe.
async function launch(data: string, app: string, more: string[] = []): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat", ...more], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300" }),
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = controlPipe(child);
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  const errWaiters: (() => void)[] = [];
  child.stderr!.on("data", (d) => {
    err += d;
    for (const w of errWaiters.splice(0)) w();
  });
  const heard = (what: string, text: string) =>
    new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never heard: ${what}; stderr ${err}`)), 15_000);
      const look = () => {
        if (err.includes(text)) {
          clearTimeout(timer);
          resolve();
        } else errWaiters.push(look);
      };
      look();
    });
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 15_000);
      const look = () => {
        const found = said.find(ok);
        if (found !== undefined) {
          clearTimeout(timer);
          resolve(found);
        } else waiters.push(look);
      };
      look();
    });
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, heard, stderr: () => err };
}

function get(port: number | { socket: string }, path: string, body?: string, token?: string): Promise<{ status: number; body: string; headers: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = { "content-type": "application/json", ...(token !== undefined ? { authorization: `Bearer ${token}` } : {}) };
    const req = request({ ...(typeof port === "number" ? { host: "127.0.0.1", port } : { socketPath: port.socket }), path, method: body === undefined ? "GET" : "POST", headers }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text, headers: res.headers }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

test("run: ready, serving, its heartbeat, the loopback port, the status socket, the agents' door; a handover with what it carries; a stop that leaves nothing", { skip }, async () => {
  const data = fresh("run");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9400\n");
  const a = await launch(data, app);
  assert.deepEqual(await a.next("ready", (m) => m.ready === true), { ready: true, version: "0.1.9400" });
  const admin = await a.next("admin", (m) => m.serving === "admin");
  const mcp = await a.next("mcp", (m) => m.serving === "mcp");
  await a.next("a heartbeat", (m) => m.heartbeat === true);
  // what it wrote of itself
  assert.deepEqual(JSON.parse(readFileSync(join(data, "run", "ports.json"), "utf8")), { admin: admin.port });
  assert.deepEqual(JSON.parse(readFileSync(join(data, "run", "mcp.json"), "utf8")), { port: mcp.port });
  assert.equal(JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, a.child.pid);
  const health = JSON.parse(readFileSync(join(data, "run", "health.json"), "utf8"));
  assert.equal(health.pid, a.child.pid);
  assert.ok(Math.abs(health.updatedAt - Date.now()) < 5_000);
  // its descriptors and resident memory, from the system's own counters
  assert.ok(Number.isInteger(health.openFds) && health.openFds > 0, `openFds ${health.openFds}`);
  assert.ok(Number.isInteger(health.rssBytes) && health.rssBytes > 0, `rssBytes ${health.rssBytes}`);
  // the loopback port
  assert.equal((await get(admin.port, "/healthz")).status, 200);
  const unjoined = await get(admin.port, "/admin");
  assert.equal(unjoined.status, 404);
  // the agents' door: a session's bearer token or nothing (tools/mcp.ts `McpEndpoint`)
  const anonymous = await get(mcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }));
  assert.equal(anonymous.status, 401);
  assert.deepEqual(JSON.parse(anonymous.body), { error: "unknown session token" });
  assert.equal((await get(mcp.port, "/health")).status, 200);
  // the store it opened, the schema made: a session the TypeScript's store writes there is the status socket's
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: data, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  store.setRunning("s1", true);
  // its token is the door's bearer: the endpoint's methods, and the agents' tools
  const init = JSON.parse((await get(mcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }), "t1")).body);
  assert.equal(init.result.serverInfo.name, "still.fail");
  const tools = JSON.parse((await get(mcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }), "t1")).body).result.tools.map((t: { name: string }) => t.name);
  for (const core of ["chat_post", "chat_state", "chat_history", "chat_list", "chat_read", "session_send", "chat_create", "chat_archive", "chat_configure", "job_start", "job_list", "job_log", "job_stop", "station_list", "station_task", "station_file", "search", "skill_read", "workspace_limit", "secret_list", "feishu_api", "slack_api"]) assert.ok(tools.includes(core), `${core} listed: ${tools.join(",")}`);
  for (const hidden of ["station_retire", "adb_devices", "phone_use", "secret_reask"]) assert.ok(!tools.includes(hidden), `${hidden} hidden: ${tools.join(",")}`);
  const running = store.runningSessions();
  const status = JSON.parse((await get({ socket: join(data, "run", "status.sock") }, "/v1/status")).body);
  assert.equal(status.version, "0.1.9400");
  assert.equal(status.enrolled, false);
  assert.deepEqual(status.agents, { busy: 1, warm: 0, total: 1 });
  assert.equal(status.tasks[0].session, "s1");
  assert.deepEqual([status.tasks[0].title, status.tasks[0].since], [running[0]!.title, running[0]!.lastActiveAt]);
  assert.equal((await get({ socket: join(data, "run", "status.sock") }, "/healthz")).body, "ok\n");
  store.close();
  // `stillfail status` while it runs (the launcher's station.json, as the launcher writes it)
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: a.child.pid, version: "0.1.9400" }));
  const running_ = run(["status", "--data", data]);
  assert.equal(running_.code, 0, running_.err);
  assert.match(running_.out, /0\.1\.9400/);
  // a second process of its own, no launcher: refused, the station held
  const second = run(["run", "--app", app, "--data", data]);
  assert.equal(second.code, 3);
  rmSync(join(data, "run", "station.json"));
  // `stillfail heap`: asked of the running station, its answer's file said
  const heap = run(["heap", "--data", data]);
  assert.equal(heap.code, 0, heap.err);
  const snapshot = JSON.parse(readFileSync(heap.out.trim(), "utf8"));
  assert.equal(snapshot.pid, a.child.pid);

  // a handover: the next process started beside it waits for it to go
  const b = await launch(data, app);
  await b.next("ready", (m) => m.ready === true);
  await b.next("taking, while the one before is there", (m) => m.taking === true);
  assert.equal(b.said.some((m) => m.serving === "mcp"), false, "its door not open while the one before holds the sessions");
  a.tell({ op: "handover" });
  const carry = await a.next("carry", (m) => m.carry !== undefined);
  assert.deepEqual(Object.keys(carry.carry).sort(), ["live.plans", "live.tails", "vault"], "what its parts carry, by part (where the live view read each checklist and transcript to; the vault's grants and boxes waiting)");
  assert.ok(Array.isArray(carry.carry["live.plans"]) && Array.isArray(carry.carry["live.tails"]), JSON.stringify(carry.carry));
  assert.equal(typeof carry.carry.vault, "object");
  assert.notEqual(carry.carry.vault, null);
  assert.equal(await a.ended, 0);
  assert.equal(existsSync(join(data, "run", "hub.json")) && JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid === a.child.pid, false, "its sessions' file let go");
  b.tell({ op: "carried", carried: carry.carry });
  const bMcp = await b.next("serving the agents' door", (m) => m.serving === "mcp");
  const bAdmin = b.said.find((m) => m.serving === "admin");
  assert.equal(JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, b.child.pid);
  assert.equal(existsSync(join(data, "run", "handover.json")), false, "the handover taken up");
  assert.equal((await get(bAdmin.port, "/healthz")).status, 200);
  assert.equal((await get(bMcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }))).status, 401);
  assert.deepEqual(JSON.parse((await get(bMcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }), "t1")).body).result, {});
  b.tell({ op: "drain" });
  assert.deepEqual(await b.next("drained", (m) => m.drained !== undefined), { drained: "idle" });
  b.tell({ op: "hup" });
  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0);
  for (const p of [a.child.pid!, b.child.pid!]) assert.throws(() => process.kill(p, 0), "no process left");
  assert.equal(existsSync(join(data, "run", "hub.json")), false);
});

test("run: a stop lets go of run/hub.json only once its sessions are let go, so a station started meanwhile waits for it", { skip: skip || (process.platform === "win32" ? "its children held by SIGSTOP" : false) }, async () => {
  const data = fresh("held");
  const app = fresh("app");
  const a = await launch(data, app);
  await a.next("ready", (m) => m.ready === true);
  await a.next("mcp", (m) => m.serving === "mcp");
  assert.equal(JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, a.child.pid);
  // its winding down held: its processes (the sessions' program, the readers) stopped, so letting go of them waits
  // (one that ended since `ps` looked, a short command of its own, is left out); `copies.start()` spawns
  // `--builder replica-export` only after `door_ready`, and it is the one `wait_live_p5_5_closed()` awaits on stop: wait for it
  let rows: string[][] = [];
  for (let i = 0; i < 250; i++) {
    rows = spawnSync("ps", ["-A", "-o", "pid=,ppid=,command="], { encoding: "utf8" }).stdout.split("\n").map((l) => l.trim().split(/\s+/)).filter((r) => r[1] === String(a.child.pid));
    if (rows.some((r) => r.includes("replica-export"))) break;
    await new Promise((r) => setTimeout(r, 20));
  }
  assert.ok(rows.some((r) => r.includes("replica-export")), `its processes (waiting for replica-export): ${JSON.stringify(rows)}`);
  const kids = rows.map((r) => Number(r[0])).filter((k) => {
    try {
      process.kill(k, "SIGSTOP");
      return true;
    } catch {
      return false;
    }
  });
  assert.ok(kids.length > 0, `its processes: ${JSON.stringify(rows)}`);
  a.tell({ op: "stop" });
  await a.heard("stopping", "stopping");
  // still winding down: its sessions' file still names it (the next station's `held_by_hub`)
  assert.equal(a.child.exitCode, null, "still there");
  assert.equal(existsSync(join(data, "run", "hub.json")) && JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, a.child.pid, "its sessions' file kept while it winds down");
  // a station started now waits for it instead of taking the sessions (and the runners) up beside it
  const b = await launch(data, app);
  await b.next("ready", (m) => m.ready === true);
  await b.next("taking, while the one before winds down", (m) => m.taking === true);
  assert.equal(b.said.some((m) => m.serving === "mcp"), false, "its door not open while the one before holds the sessions");
  for (const k of kids) {
    try {
      process.kill(k, "SIGCONT");
    } catch {}
  }
  assert.equal(await a.ended, 0);
  await b.next("serving the agents' door once the one before is gone", (m) => m.serving === "mcp");
  assert.equal(JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, b.child.pid);
  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0);
  assert.equal(existsSync(join(data, "run", "hub.json")), false, "let go of as it ends");
});

test("run: a database already at this version opens while another process holds its write lock", { skip }, async () => {
  const data = fresh("locked");
  const app = fresh("app");
  // the database as a station that ran here left it (every part's tables made)
  const a = await launch(data, app);
  await a.next("ready", (m) => m.ready === true);
  await a.next("mcp", (m) => m.serving === "mcp");
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0);
  // a process of the station before (a backfill, one held by SIGSTOP) mid-write: the next station opens it all the same
  const holder = new DatabaseSync(join(data, "stillfail.db"));
  holder.exec("BEGIN IMMEDIATE");
  let b: Launched;
  try {
    b = await launch(data, app);
    await b.next("ready", (m) => m.ready === true);
    assert.equal(b.stderr().includes("database is locked"), false, b.stderr());
  } finally {
    holder.exec("ROLLBACK");
    holder.close();
  }
  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0);
});

test("run on its own: SIGTERM stops it; a launcher gone stops it", { skip }, async () => {
  const data = fresh("own");
  const app = fresh("app");
  const own = spawn(binary!, ["run", "--app", app, "--data", data], { stdio: ["ignore", "ignore", "pipe"], env: noNode() });
  children.push(own);
  for (let i = 0; i < 300 && !existsSync(join(data, "run", "mcp.json")); i++) await new Promise((r) => setTimeout(r, 20));
  const port = JSON.parse(readFileSync(join(data, "run", "ports.json"), "utf8")).admin;
  assert.equal((await get(port, "/healthz")).status, 200);
  own.kill("SIGTERM");
  assert.equal(await new Promise((r) => own.on("exit", r)), 0);
  const launched = await launch(fresh("gone"), app);
  await launched.next("ready", (m) => m.ready === true);
  controlPipe(launched.child).destroy();
  assert.equal(await launched.ended, 0, "the launcher's channel closed: it stops");
});
