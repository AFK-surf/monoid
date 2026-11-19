// The updates in MoonBit (station/mb/src/updates, `stillfail-reader-harness --builder harness-updates`) held to the TypeScript they
// replace (src/updates: versions.ts, signed.ts, keys.ts, holds.ts, delta.ts, release.ts, runtimes.ts, codex-repair.ts,
// agy-download.ts, channel.ts, command.ts, updates.ts). Each case is run by both, each against a world of its own made
// alike: what each answered (a function's result, or what it threw: its class and fields), every call either made of
// the world (its files, the network, the machine's processes and platform, the log, the config, what it told), and
// the world's files at the end must be the same.
//
// The world is the test's: files in memory (`Vfs`, so a stat's inode and time are the same for both), HTTP answered by
// route, processes answered by script, the platform's functions answered by the case. The TypeScript reaches it through
// module mocks (node:test `mock.module`: node:fs, node:fs/promises, node:crypto's randomBytes, node:os' tmpdir,
// node:child_process' spawn, the platform, the log, the shell's PATH, the processes, the cloud's transport, Cursor's
// SDK, the config file, the fibers' wall) and a global fetch; the program through its harness's asks. Time is a clock
// of the test's on both sides (`advance`: each timer due taken in turn, what it set going done before the next); the
// machine's own timers (`wall`) come due only as a case says (`fireWall`). Nothing sleeps.
//
// Where a step sets several reads going at once (Updates' reading of every runtime), the two runtimes interleave them
// each its own way: such a step compares what was asked of the world as a whole, not in order (`loose`).
//
// What is not compared: `stillfail-station channel` waiting with no answer (channel.ts `answerIn` looks every 100 ms on
// Effect's own clock, the machine's; the program on its part's). The functions that only read and write files are run
// once more on the machine's own (`on real files`): the TypeScript through node:fs, the program through the shell
// (host_io.mbt).
//
// Looking into a case: MB_UPDATES_ONLY=<part of its name> runs only those, MB_UPDATES_SHOW=ts|mb prints what one side
// answered and asked at each step, MB_UPDATES_DEBUG=1 every line to and from the program.
//
// Module mocks need `--experimental-test-module-mocks`: run without it (as `pnpm test` runs a file), this file runs
// itself again with it, and fails as that run fails.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, posix } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { createHash, generateKeyPairSync, createPublicKey, sign } from "node:crypto";
import { deflateRawSync } from "node:zlib";
import { mock, test } from "node:test";
import { childGone } from "./child-gone.ts";
import { mbHarnessBinary } from "./mb-harness.ts";

const self = fileURLToPath(import.meta.url);
const station = fileURLToPath(new URL("..", import.meta.url));
const root = fileURLToPath(new URL("../..", import.meta.url));
const src = (p: string) => new URL(`../src/${p}`, import.meta.url).href;

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

// ---------------------------------------------------------------------------------------------------------------
// The world

/// A refusal the world throws: its class's name and its fields.
class Thrown {
  readonly kind: string;
  readonly fields: Record<string, Json>;
  constructor(kind: string, fields: Record<string, Json>) {
    this.kind = kind;
    this.fields = fields;
  }
}
const errno = (code: string, syscall: string, path: string) => {
  const what: Record<string, string> = {
    ENOENT: "no such file or directory", EEXIST: "file already exists", ENOTDIR: "not a directory", EISDIR: "illegal operation on a directory",
    EACCES: "permission denied", ENOTEMPTY: "directory not empty", EINVAL: "invalid argument",
  };
  return new Thrown("Error", { message: `${code}: ${what[code] ?? code}, ${syscall} '${path}'`, code });
};

type Node =
  | { kind: "file"; data: Buffer; mode: number; ino: number; mtimeMs: number }
  | { kind: "dir"; mode: number; ino: number; mtimeMs: number }
  | { kind: "link"; target: string; mode: number; ino: number; mtimeMs: number };

/// Files in memory, as the station sees them through node:fs: paths are POSIX, links followed where Node follows them.
class Vfs {
  nodes = new Map<string, Node>();
  ino = 100;
  time = 1_700_000_000_000;
  constructor() {
    this.nodes.set("/", { kind: "dir", mode: 0o755, ino: 1, mtimeMs: this.time });
  }
  private made(): { ino: number; mtimeMs: number } {
    return { ino: ++this.ino, mtimeMs: (this.time += 1000) };
  }
  dir(p: string, mode = 0o755) {
    const parts = posix.normalize(p).split("/").filter(Boolean);
    let at = "/";
    for (const part of parts) {
      at = posix.join(at, part);
      if (!this.nodes.has(at)) this.nodes.set(at, { kind: "dir", mode, ...this.made() });
    }
    return this;
  }
  file(p: string, data: string | Buffer, mode = 0o644) {
    this.dir(posix.dirname(p));
    this.nodes.set(posix.normalize(p), { kind: "file", data: Buffer.from(data), mode, ...this.made() });
    return this;
  }
  link(p: string, target: string) {
    this.dir(posix.dirname(p));
    this.nodes.set(posix.normalize(p), { kind: "link", target, mode: 0o777, ...this.made() });
    return this;
  }
  /// The path with every link in it followed (the last one too when `last`): its real path, or the ENOENT it gives.
  resolve(p: string, last: boolean, syscall: string, depth = 0): string {
    if (depth > 40) throw new Thrown("Error", { message: `ELOOP: too many symbolic links encountered, ${syscall} '${p}'`, code: "ELOOP" });
    const parts = posix.normalize(posix.resolve("/", p)).split("/").filter(Boolean);
    let at = "/";
    for (let i = 0; i < parts.length; i++) {
      const next = posix.join(at, parts[i]!);
      const n = this.nodes.get(next);
      if (n === undefined) {
        if (i === parts.length - 1) return next;
        throw errno("ENOENT", syscall, p);
      }
      if (n.kind === "link" && (i < parts.length - 1 || last)) {
        const target = posix.resolve(at, n.target);
        at = this.resolve(target, true, syscall, depth + 1);
        continue;
      }
      if (n.kind === "file" && i < parts.length - 1) throw errno("ENOTDIR", syscall, p);
      at = next;
    }
    return at;
  }
  get(p: string, follow: boolean, syscall: string): [string, Node] {
    const at = this.resolve(p, follow, syscall);
    const n = this.nodes.get(at);
    if (n === undefined) throw errno("ENOENT", syscall, p);
    return [at, n];
  }
  statOf(n: Node): Json {
    const size = n.kind === "file" ? n.data.length : n.kind === "link" ? n.target.length : 64;
    return { size, file: n.kind === "file", dir: n.kind === "dir", symlink: n.kind === "link", dev: 1, ino: n.ino, mtimeMs: n.mtimeMs };
  }
  children(dir: string): string[] {
    const pre = dir === "/" ? "/" : `${dir}/`;
    return [...this.nodes.keys()].filter((k) => k !== dir && k.startsWith(pre) && !k.slice(pre.length).includes("/"));
  }
  remove(at: string) {
    for (const k of [...this.nodes.keys()]) if (k === at || k.startsWith(`${at}/`)) this.nodes.delete(k);
  }
  write(p: string, data: Buffer, syscall = "open") {
    const at = this.resolve(p, true, syscall);
    const parent = this.nodes.get(posix.dirname(at));
    if (parent?.kind !== "dir") throw errno("ENOENT", syscall, p);
    const had = this.nodes.get(at);
    if (had?.kind === "dir") throw errno("EISDIR", syscall, p);
    if (had?.kind === "file") {
      had.data = data;
      had.mtimeMs = this.time += 1000;
    } else this.nodes.set(at, { kind: "file", data, mode: 0o644, ...this.made() });
  }
  /// What it holds, for the end of a case: each path and what it is.
  dump(): Json {
    const out: Record<string, Json> = {};
    for (const [k, n] of [...this.nodes.entries()].sort(([a], [b]) => (a < b ? -1 : 1))) {
      out[k] = n.kind === "file" ? { file: createHash("sha256").update(n.data).digest("hex").slice(0, 16), size: n.data.length } : n.kind === "link" ? { link: n.target } : "dir";
    }
    return out;
  }
}

type Spec = { status?: number; headers?: Record<string, string>; body?: string | Buffer | null; chunks?: (string | Buffer)[]; breaks?: Thrown };
type Events = Json[];
type Handler = (args: any[], w: World) => any;

const bytesJ = (b: Uint8Array): Json => ({ $bytes: Buffer.from(b).toString("base64") });
const fromBytesJ = (j: any): Buffer => (typeof j === "string" ? Buffer.from(j) : Buffer.from(j?.$bytes ?? "", "base64"));

/// What the TypeScript and the program alone ask: answered, not compared.
const UNRECORDED = new Set(["$json.error", "$deflate"]);

class World {
  log: [string, Json][] = [];
  vfs = new Vfs();
  routes = new Map<string, Spec | ((args: any[], w: World) => Spec | Thrown)>();
  handlers = new Map<string, Handler>();
  procs: ((program: string, args: string[], opts: any) => Events | null)[] = [];
  watches = 0;
  walls = 0;
  fds = new Map<number, string>();
  nextFd = 10;
  random = 0;
  answered = 0;

  on(name: string, h: Handler) {
    this.handlers.set(name, h);
    return this;
  }
  is(name: string, v: any) {
    return this.on(name, () => v);
  }
  route(url: string, s: Spec | ((args: any[], w: World) => Spec | Thrown)) {
    this.routes.set(url, s);
    return this;
  }
  /// How the machine's processes go: the one given last is asked first (a case's own before its world's).
  proc(f: (program: string, args: string[], opts: any) => Events | null) {
    this.procs.unshift(f);
    return this;
  }
  answer(name: string, args: Json[]): Json {
    this.answered++;
    if (!UNRECORDED.has(name)) this.log.push([name, args]);
    const h = this.handlers.get(name);
    let v: any;
    if (h !== undefined) v = h(args, this);
    else v = this.builtin(name, args);
    if (v instanceof Thrown) throw v;
    return v === undefined ? null : v;
  }

  private stat(p: string, follow: boolean, syscall: string): Json {
    return this.vfs.statOf(this.vfs.get(p, follow, syscall)[1]);
  }
  private builtin(name: string, a: any[]): any {
    const v = this.vfs;
    switch (name) {
      case "fs.readFile":
      case "fs.readFileSync": {
        const [, n] = v.get(a[0], true, "open");
        if (n.kind === "dir") return errno("EISDIR", "read", a[0]);
        if (n.kind !== "file") return errno("ENOENT", "open", a[0]);
        return a[1] === "utf8" ? n.data.toString("utf8") : bytesJ(n.data);
      }
      case "fs.writeFile":
        v.write(a[0], Buffer.from(a[1]));
        return null;
      case "fs.createReadStream": {
        const [, n] = v.get(a[0], true, "open");
        if (n.kind !== "file") return errno("EISDIR", "read", a[0]);
        return bytesJ(n.data);
      }
      case "fs.createWriteStream":
        return null;
      case "fs.writeStream.end":
        v.write(a[0], fromBytesJ(a[1]));
        return null;
      case "fs.mkdir": {
        const at = posix.normalize(a[0]);
        const recursive = a[1]?.recursive === true;
        if (v.nodes.has(at)) return recursive && v.nodes.get(at)!.kind === "dir" ? null : errno("EEXIST", "mkdir", a[0]);
        if (!recursive && v.nodes.get(posix.dirname(at))?.kind !== "dir") return errno("ENOENT", "mkdir", a[0]);
        v.dir(at, typeof a[1]?.mode === "number" ? a[1].mode : 0o755);
        return null;
      }
      case "fs.rm":
      case "fs.rmSync": {
        const at = posix.normalize(a[0]);
        const n = v.nodes.get(at);
        if (n === undefined) return a[1]?.force ? null : errno("ENOENT", "rm", a[0]);
        if (n.kind === "dir" && !a[1]?.recursive) return new Thrown("Error", { message: `Path is a directory: rm returned EISDIR (is a directory) ${a[0]}`, code: "ERR_FS_EISDIR" });
        v.remove(at);
        return null;
      }
      case "fs.unlinkSync": {
        const at = posix.normalize(a[0]);
        const n = v.nodes.get(at);
        if (n === undefined) return errno("ENOENT", "unlink", a[0]);
        if (n.kind === "dir") return errno("EISDIR", "unlink", a[0]);
        v.nodes.delete(at);
        return null;
      }
      case "fs.rename":
      case "fs.renameSync": {
        const from = posix.normalize(a[0]);
        const to = posix.normalize(a[1]);
        if (!v.nodes.has(from)) return errno("ENOENT", "rename", `${a[0]}' -> '${a[1]}`);
        if (v.nodes.get(posix.dirname(to))?.kind !== "dir") return errno("ENOENT", "rename", `${a[0]}' -> '${a[1]}`);
        v.remove(to);
        for (const k of [...v.nodes.keys()]) {
          if (k === from || k.startsWith(`${from}/`)) {
            const n = v.nodes.get(k)!;
            v.nodes.delete(k);
            v.nodes.set(to + k.slice(from.length), n);
          }
        }
        return null;
      }
      case "fs.stat":
      case "fs.statSync":
        return this.stat(a[0], true, "stat");
      case "fs.lstat":
        return this.stat(a[0], false, "lstat");
      case "fs.lstatSync":
        try {
          return this.stat(a[0], false, "lstat");
        } catch (e) {
          if (a[1]?.throwIfNoEntry === false && e instanceof Thrown && e.fields.code === "ENOENT") return null;
          throw e;
        }
      case "fs.realpath":
      case "fs.realpathSync": {
        const [at] = v.get(a[0], true, "realpath");
        return at;
      }
      case "fs.access":
      case "fs.accessSync": {
        const [, n] = v.get(a[0], true, "access");
        const mode = typeof a[1] === "number" ? a[1] : 0;
        if ((mode & 1 && !(n.mode & 0o111)) || (mode & 2 && !(n.mode & 0o222))) return errno("EACCES", "access", a[0]);
        return null;
      }
      case "fs.existsSync":
        try {
          v.get(a[0], true, "stat");
          return true;
        } catch {
          return false;
        }
      case "fs.readdir":
      case "fs.readdirSync": {
        const [at, n] = v.get(a[0], true, "scandir");
        if (n.kind !== "dir") return errno("ENOTDIR", "scandir", a[0]);
        return v.children(at).map((k) => posix.basename(k));
      }
      case "fs.readlinkSync": {
        const n = v.nodes.get(posix.normalize(a[0]));
        if (n === undefined) return errno("ENOENT", "readlink", a[0]);
        if (n.kind !== "link") return errno("EINVAL", "readlink", a[0]);
        return n.target;
      }
      case "fs.symlinkSync": {
        const at = posix.normalize(a[1]);
        if (v.nodes.has(at)) return errno("EEXIST", "symlink", `${a[0]}' -> '${a[1]}`);
        v.link(at, a[0]);
        return null;
      }
      case "fs.linkSync": {
        const from = posix.normalize(a[0]);
        const to = posix.normalize(a[1]);
        const n = v.nodes.get(from);
        if (n === undefined) return errno("ENOENT", "link", `${a[0]}' -> '${a[1]}`);
        if (v.nodes.has(to)) return errno("EEXIST", "link", `${a[0]}' -> '${a[1]}`);
        v.nodes.set(to, n);
        return null;
      }
      case "fs.open": {
        const [, n] = v.get(a[0], true, "open");
        if (n.kind !== "file") return errno("EISDIR", "open", a[0]);
        return null;
      }
      case "fh.stat":
        return this.stat(a[0], true, "fstat");
      case "fh.read": {
        const [, n] = v.get(a[0], true, "read");
        const data = n.kind === "file" ? n.data : Buffer.alloc(0);
        const got = data.subarray(a[3], a[3] + a[2]);
        return { bytesRead: got.length, buffer: bytesJ(got) };
      }
      case "fh.close":
        return null;
      case "fs.openSync": {
        v.write(a[0], Buffer.alloc(0));
        const fd = this.nextFd++;
        this.fds.set(fd, posix.normalize(a[0]));
        return fd;
      }
      case "fs.writeSync": {
        const p = this.fds.get(a[0]);
        if (p === undefined) return new Thrown("Error", { message: "EBADF: bad file descriptor, write", code: "EBADF" });
        const n = v.nodes.get(p);
        const b = fromBytesJ(a[1]);
        if (n?.kind === "file") n.data = Buffer.concat([n.data, b]);
        return b.length;
      }
      case "fs.closeSync":
        this.fds.delete(a[0]);
        return null;
      case "fs.watch":
        return ++this.watches;
      case "wall.after":
        return ++this.walls;
      case "crypto.randomBytes": {
        const out = Buffer.alloc(a[0]);
        for (let i = 0; i < out.length; i++) out[i] = (++this.random * 37 + i) & 255;
        return bytesJ(out);
      }
      case "os.tmpdir":
        return "/tmp";
      case "fetch":
      case "cloud.fetch": {
        const r = this.routes.get(a[0]) ?? this.routes.get(`${a[1]?.method ?? "GET"} ${a[0]}`);
        if (r === undefined) return new Thrown("TypeError", { message: "fetch failed" });
        const spec = typeof r === "function" ? r(a, this) : r;
        if (spec instanceof Thrown) return spec;
        const chunks = spec.chunks ?? (spec.body === null || spec.body === undefined ? [] : [spec.body]);
        return {
          status: spec.status ?? 200,
          headers: spec.headers ?? {},
          ...(spec.body === null ? { body: null } : {}),
          chunks: chunks.map((c) => bytesJ(Buffer.from(c))),
          ...(spec.breaks ? { breaks: { kind: spec.breaks.kind, fields: spec.breaks.fields } } : {}),
        };
      }
      case "processes.startCommand":
      case "child_process.spawn": {
        for (const p of this.procs) {
          const events = p(a[0], a[1], a[2]);
          if (events !== null) return { $child: events };
        }
        return { $child: [["error", `spawn ${a[0]} ENOENT`]] };
      }
      case "$json.error":
        try {
          JSON.parse(a[0]);
          return "";
        } catch (e) {
          return (e as Error).message;
        }
      case "$deflate":
        return bytesJ(deflateRawSync(fromBytesJ(a[0]), { level: 6 }));
      case "platform.findCommandSoon":
        return null;
      case "platform.nodeBuild":
        return null;
      case "shellPath.withShellCommand":
        return a[1];
      default:
        return null;
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The TypeScript side's way to it

let current: World | null = null;
const KIND = Symbol("kind");
let realFs: any;
let realFsPromises: any;

function asError(e: unknown): unknown {
  if (!(e instanceof Thrown)) return e;
  const proto = e.kind === "TypeError" ? TypeError.prototype : e.kind === "SyntaxError" ? SyntaxError.prototype : Error.prototype;
  const err = Object.create(proto);
  for (const [k, v] of Object.entries(e.fields)) if (k !== "message") err[k] = v;
  Object.defineProperty(err, "message", { value: String(e.fields.message ?? ""), enumerable: false, writable: true });
  Object.defineProperty(err, "stack", { value: `${e.kind}: ${e.fields.message}`, enumerable: false, writable: true });
  Object.defineProperty(err, KIND, { value: e.kind, enumerable: false });
  return err;
}

function encode(v: unknown): Json {
  if (v === undefined || typeof v === "function") return null;
  if (v === null || typeof v === "boolean" || typeof v === "string" || typeof v === "number") return v;
  if (Buffer.isBuffer(v) || v instanceof Uint8Array) return bytesJ(v);
  if (typeof AbortSignal !== "undefined" && v instanceof AbortSignal) return { $signal: true };
  if (v instanceof Map) return [...v.entries()].map(([k, x]) => [encode(k), encode(x)]);
  if (Array.isArray(v)) return v.map(encode);
  const out: Record<string, Json> = {};
  for (const [k, x] of Object.entries(v as object)) if (x !== undefined && typeof x !== "function") out[k] = encode(x);
  return out;
}

/// A call of the TypeScript's on the world: its answer, or what it threw (thrown here as JavaScript throws it).
function W(name: string, args: unknown[]): any {
  const w = current!;
  try {
    return w.answer(name, args.map(encode));
  } catch (e) {
    throw asError(e);
  }
}
const WA = (name: string, args: unknown[]): Promise<any> => {
  try {
    return Promise.resolve(W(name, args));
  } catch (e) {
    return Promise.reject(e);
  }
};

const toStats = (s: any) => s === null ? undefined : ({ ...s, isFile: () => s.file === true, isDirectory: () => s.dir === true, isSymbolicLink: () => s.symlink === true });

/// The world's process, as Node's ChildProcess: its events given out one a turn of the loop.
function fakeChild(program: string, events: Events, stdoutStrings: boolean): any {
  const child: any = new EventEmitter();
  const stream = () => Object.assign(new EventEmitter(), { setEncoding: () => {} });
  child.stdout = stream();
  child.stderr = stream();
  child.pid = 4242;
  child.program = program;
  const data = (s: string) => (stdoutStrings ? s : Buffer.from(s));
  const list = [...events] as any[];
  const step = () => {
    const ev = list.shift();
    if (ev === undefined) return;
    const [kind, value, sig] = ev;
    if (kind === "stdout") child.stdout.emit("data", data(value));
    else if (kind === "stderr") child.stderr.emit("data", data(value));
    else if (kind === "error") return void child.emit("error", new Error(value));
    else if (kind === "close") {
      child.stdout.emit("end");
      child.stderr.emit("end");
      child.emit("close", value, sig ?? null);
      return;
    } else if (kind === "hang") return;
    setImmediate(step);
  };
  setImmediate(step);
  return child;
}

function fakeResponse(r: any): any {
  const chunks: Buffer[] = (r.chunks ?? []).map(fromBytesJ);
  const text = Buffer.concat(chunks).toString("utf8");
  const headers = r.headers ?? {};
  return {
    status: r.status,
    ok: r.status >= 200 && r.status <= 299,
    headers: { get: (k: string) => (headers[k.toLowerCase()] === undefined ? null : String(headers[k.toLowerCase()])) },
    json: async () => JSON.parse(text),
    text: async () => text,
    body: r.body === null ? null : {
      async *[Symbol.asyncIterator]() {
        for (const c of chunks) yield new Uint8Array(c);
        if (r.breaks) throw asError(new Thrown(r.breaks.kind, r.breaks.fields));
      },
    },
  };
}
const worldFetch = (via: string) => async (url: string, init?: any) => {
  const r = W(via, [url, init]);
  return fakeResponse(r);
};

// The machine as both sides are told it.
const MACHINE = {
  buildOs: "darwin",
  arch: "arm64",
  installerExt: "sh",
  codexStandalone: true,
  claudeInstall: { program: "/bin/sh", args: ["-c", "curl -fsSL https://claude.ai/install.sh | bash"] },
  agyInstall: { program: "/bin/sh", args: ["-c", "curl -fsSL https://antigravity.google/cli/install.sh | bash"] },
  devinInstall: { program: "/bin/sh", args: ["-c", "curl -fsSL https://static.devin.ai/cli/setup.sh | bash"] },
};
const PLATFORM_ASYNC = new Set(["isLauncher", "askLauncher", "startInstaller", "agyBuild", "shimUpdate", "linkCommand", "findCommandSoon"]);
const fakePlatform: any = new Proxy(
  {
    os: "darwin",
    buildOs: MACHINE.buildOs,
    installerExt: MACHINE.installerExt,
    codexStandalone: MACHINE.codexStandalone,
    claudeInstall: MACHINE.claudeInstall,
    agyInstall: MACHINE.agyInstall,
    devinInstall: MACHINE.devinInstall,
    exe: (n: string) => n,
    home: (env: any) => env.HOME,
    pathOf: (env: any) => env.PATH ?? "",
    prependPath: (env: any, dir: string) => ({ ...env, PATH: `${dir}:${env.PATH ?? ""}` }),
    appendPath: (env: any, dir: string) => {
      const path = env.PATH ?? "";
      if (path.split(":").includes(dir)) return;
      env.PATH = path === "" ? dir : `${path}:${dir}`;
    },
    paths: { separator: "/", within: (p: string, d: string) => d === "/" || p === d || p.startsWith(`${d}/`) },
  } as Record<string, any>,
  {
    get: (t, k) => {
      if (typeof k === "symbol" || k in t) return (t as any)[k];
      return (...a: unknown[]) => (PLATFORM_ASYNC.has(k) ? WA(`platform.${k}`, a) : W(`platform.${k}`, a));
    },
  },
);

/// The test's clock (Effect's Clock), moved by `advance`.
class VClock {
  now = 1_800_000_000_000;
  seq = 0;
  timers: { due: number; seq: number; resume: () => void }[] = [];
  clock: any;
  constructor(Effect: any, Duration: any) {
    const nanos = () => BigInt(this.now) * 1_000_000n;
    this.clock = {
      currentTimeMillisUnsafe: () => this.now,
      currentTimeMillis: Effect.sync(() => this.now),
      currentTimeNanosUnsafe: nanos,
      currentTimeNanos: Effect.sync(nanos),
      monotonicTimeNanosUnsafe: nanos,
      monotonicTimeNanos: Effect.sync(nanos),
      sleep: (d: any) =>
        Effect.callback((resume: any) => {
          const ms = Duration.toMillis(d);
          if (ms <= 0) return void resume(Effect.void);
          const t = { due: this.now + ms, seq: ++this.seq, resume: () => resume(Effect.void) };
          this.timers.push(t);
          return Effect.sync(() => {
            const i = this.timers.indexOf(t);
            if (i >= 0) this.timers.splice(i, 1);
          });
        }),
    };
  }
  async advance(ms: number) {
    const target = this.now + ms;
    await settle();
    for (;;) {
      let best: (typeof this.timers)[number] | undefined;
      for (const t of this.timers) if (t.due <= target && (best === undefined || t.due < best.due || (t.due === best.due && t.seq < best.seq))) best = t;
      if (best === undefined) break;
      this.timers.splice(this.timers.indexOf(best), 1);
      if (best.due > this.now) this.now = best.due;
      best.resume();
      await settle();
    }
    this.now = target;
  }
}

/// Until nothing set going asks the world any more (the TypeScript's side of `sync`).
async function settle() {
  for (let quiet = 0; quiet < 40; ) {
    const before = current?.answered ?? 0;
    await new Promise((r) => setImmediate(r));
    quiet = (current?.answered ?? 0) !== before ? 0 : quiet + 1;
  }
}

// The wall's timers (ops/fibers.ts `wall`): armed on the world, come due as a case says.
let walls: [number, () => void][] = [];
const fakeWall = {
  now: () => W("wall.now", []),
  sleep: (ms: number) => WA("wall.sleep", [ms]).then(() => undefined),
  after: (ms: number, f: () => void) => {
    const id = W("wall.after", [ms]);
    walls.push([id, f]);
    return () => void (walls = walls.filter(([i]) => i !== id));
  },
  every: (ms: number, f: () => void) => fakeWall.after(ms, f),
  within: <A>(_ms: number, p: Promise<A>) => p,
};

/// Each module the updates import from outside them, as the world answers it.
const MOCKED: [string, string][] = [
  ["platform/index.ts", "platform"],
  ["ops/log.ts", "log"],
  ["ops/shell-path.ts", "shellPath"],
  ["ops/processes.ts", "processes"],
  ["cloud/transport.ts", "cloud"],
  ["agents/cursor.ts", "cursor"],
  ["ops/config.ts", "config"],
  ["ops/fibers.ts", "fibers"],
];

function exportsOf(): Record<string, Record<string, { kind: string; value?: unknown }>> {
  const code = `
    const out = {};
    for (const p of ${JSON.stringify(MOCKED.map(([p]) => src(p)))}) {
      const m = await import(p);
      const e = {};
      for (const [k, v] of Object.entries(m)) {
        const isClass = typeof v === "function" && /^class[\\s{]/.test(Function.prototype.toString.call(v));
        if (isClass) e[k] = { kind: "class" };
        else if (typeof v === "function") e[k] = { kind: "function" };
        else { try { e[k] = { kind: "value", value: JSON.parse(JSON.stringify(v ?? null)) }; } catch { e[k] = { kind: "other" }; } }
      }
      out[p] = e;
    }
    process.stdout.write(JSON.stringify(out));`;
  const run = spawnSync(process.execPath, ["--no-warnings", "--input-type=module", "-e", code], { cwd: station, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (run.status !== 0) throw new Error(`the modules' exports were not read: ${run.stderr}`);
  return JSON.parse(run.stdout);
}

async function installMocks(Effect: any, Duration: any, Exit: any, Fiber: any, FiberSet: any, Scope: any): Promise<void> {
  const exported = exportsOf();
  // A copy of ops/fibers.ts' Fibers (its own module is mocked for its `wall`): the same Effect runtime on a part's clock.
  class Fibers {
    readonly clock: any;
    readonly #what: string;
    readonly #scope: any;
    readonly #run: (effect: any) => any;
    #closed = false;
    constructor(what: string, clock?: any) {
      this.#what = what;
      this.clock = clock;
      this.#scope = Effect.runSync(Scope.make());
      const runtime = Effect.runSync(Scope.provide(FiberSet.makeRuntime(), this.#scope));
      const c = this.clock;
      const { Clock } = effectModule;
      this.#run = (effect) => runtime(effect.pipe(Effect.provideService(Clock.Clock, c)));
    }
    now(): number {
      return this.clock.currentTimeMillisUnsafe();
    }
    fork(effect: any) {
      return this.#run(effect);
    }
    run(effect: any) {
      return Effect.runPromise(effect.pipe(Effect.provideService(effectModule.Clock.Clock, this.clock)));
    }
    sleep(ms: number): Promise<void> {
      return Effect.runPromise(this.clock.sleep(Duration.millis(Math.max(0, ms))));
    }
    spawn(f: () => Promise<unknown>): void {
      if (this.#closed) return;
      this.#run(this.#guarded(f));
    }
    after(ms: number, f: () => unknown): () => void {
      if (this.#closed) return () => {};
      return this.#cancel(this.#run(Effect.andThen(Effect.sleep(Duration.millis(Math.max(0, ms))), this.#guarded(f))));
    }
    every(ms: number, f: () => unknown): () => void {
      if (this.#closed) return () => {};
      return this.#cancel(this.#run(Effect.forever(Effect.andThen(Effect.sleep(Duration.millis(ms)), this.#guarded(f)))));
    }
    async close(): Promise<void> {
      if (this.#closed) return;
      this.#closed = true;
      await Effect.runPromise(Scope.close(this.#scope, Exit.void));
    }
    #guarded(f: () => unknown) {
      return Effect.promise(async () => {
        try {
          await f();
        } catch (e) {
          W("log.warn", [this.#what, "background work failed", { error: (e as Error)?.message ?? String(e) }]);
        }
      });
    }
    #cancel(fiber: any): () => void {
      return () => void Effect.runFork(Fiber.interrupt(fiber));
    }
  }
  const OVERRIDES: Record<string, Record<string, any>> = {
    platform: { platform: fakePlatform, WINDOWS: false },
    log: { log: { info: (...a: unknown[]) => void W("log.info", a), warn: (...a: unknown[]) => void W("log.warn", a), error: (...a: unknown[]) => void W("log.error", a), debug: () => {} } },
    shellPath: {
      withShellCommand: (name: string, env: any) => WA("shellPath.withShellCommand", [name, env]),
      forgetShellPaths: () => void W("shellPath.forgetShellPaths", []),
    },
    processes: {
      startCommand: (program: string, args: string[], opts: any) => fakeChild(program, W("processes.startCommand", [program, args, opts]).$child, true),
      endCommand: (child: any, sig: string) => void W("processes.endCommand", [child.program, sig]),
    },
    cloud: {
      CLOUD_ORIGIN: "https://app.still.fail",
      cloudEntry: () => null,
      CloudTransport: class {
        constructor() {
          W("CloudTransport.new", []);
        }
        fetch = worldFetch("cloud.fetch");
        async close() {
          W("CloudTransport.close", []);
        }
      },
    },
    cursor: {
      SDK_PACKAGE: "@cursor/sdk",
      sdkPrefix: (data: string) => join(data, "runtimes", "cursor"),
      sdkVersionSoon: (data: string) => WA("cursor.sdkVersionSoon", [data]),
    },
    config: {
      ConfigFile: class {
        readonly data: string;
        constructor(data: string) {
          this.data = data;
          W("ConfigFile.new", [data]);
        }
        raw() {
          return W("ConfigFile.raw", [this.data]);
        }
        update(edit: (raw: any) => void) {
          const raw = structuredClone(W("ConfigFile.raw", [this.data]) ?? {});
          edit(raw);
          W("ConfigFile.update", [this.data, raw]);
          return raw;
        }
      },
    },
    fibers: { Fibers, wall: fakeWall, within: (_c: unknown, _ms: number, p: Promise<unknown>) => p, liveClock: {} },
  };
  for (const [path, prefix] of MOCKED) {
    const url = src(path);
    const exports: Record<string, unknown> = {};
    for (const [name, e] of Object.entries(exported[url] ?? {})) {
      if (OVERRIDES[prefix]?.[name] !== undefined) exports[name] = OVERRIDES[prefix]![name];
      else if (e.kind === "function") exports[name] = (...args: unknown[]) => W(`${prefix}.${name}`, args);
      else if (e.kind === "class") exports[name] = class extends Error {};
      else exports[name] = e.value;
    }
    for (const [name, v] of Object.entries(OVERRIDES[prefix] ?? {})) exports[name] ??= v;
    mock.module(url, { exports } as never);
  }
  const builtin = async (name: string, over: Record<string, unknown>) => {
    const real = { ...(await import(name)) } as Record<string, unknown>;
    delete real.default;
    const exports = { ...real, ...over };
    mock.module(name, { exports: { ...exports, default: { ...exports } } } as never);
    return real;
  };
  realFs = { ...(await import("node:fs")) };
  realFsPromises = { ...(await import("node:fs/promises")) };
  const worldOr = (name: string, real: (...a: any[]) => any, wrap: (v: any) => any = (v) => v) => (...a: any[]) => (current === null ? real(...a) : wrap(W(name, a)));
  const worldOrAsync = (name: string, real: (...a: any[]) => any, wrap: (v: any) => any = (v) => v) => (...a: any[]) => (current === null ? real(...a) : WA(name, a).then(wrap));
  await builtin("node:fs", {
    readFileSync: worldOr("fs.readFileSync", realFs.readFileSync, (v) => (typeof v === "string" ? v : fromBytesJ(v))),
    existsSync: worldOr("fs.existsSync", realFs.existsSync),
    lstatSync: worldOr("fs.lstatSync", realFs.lstatSync, toStats),
    statSync: worldOr("fs.statSync", realFs.statSync, toStats),
    realpathSync: worldOr("fs.realpathSync", realFs.realpathSync),
    accessSync: worldOr("fs.accessSync", realFs.accessSync),
    readdirSync: worldOr("fs.readdirSync", realFs.readdirSync),
    readlinkSync: worldOr("fs.readlinkSync", realFs.readlinkSync),
    unlinkSync: worldOr("fs.unlinkSync", realFs.unlinkSync),
    renameSync: worldOr("fs.renameSync", realFs.renameSync),
    symlinkSync: worldOr("fs.symlinkSync", realFs.symlinkSync),
    linkSync: worldOr("fs.linkSync", realFs.linkSync),
    openSync: worldOr("fs.openSync", realFs.openSync),
    closeSync: worldOr("fs.closeSync", realFs.closeSync),
    rmSync: worldOr("fs.rmSync", realFs.rmSync),
    writeSync: (fd: number, b: Uint8Array, off = 0) => (current === null ? realFs.writeSync(fd, b, off) : W("fs.writeSync", [fd, Buffer.from(b).subarray(off)])),
    watch: (dir: string, ...rest: any[]) => {
      if (current === null) return realFs.watch(dir, ...rest);
      const cb = rest.find((r) => typeof r === "function");
      const id = W("fs.watch", [dir]);
      const watcher: any = new EventEmitter();
      watcher.close = () => {
        if (watchers.has(id)) W("fs.watch.close", [dir]);
        watchers.delete(id);
      };
      watchers.set(id, { dir, cb });
      return watcher;
    },
    createReadStream: (p: string) => {
      if (current === null) return realFs.createReadStream(p);
      const s: any = new EventEmitter();
      setImmediate(() => {
        try {
          s.emit("data", fromBytesJ(W("fs.createReadStream", [p])));
          s.emit("end");
        } catch (e) {
          s.emit("error", e);
        }
      });
      return s;
    },
    createWriteStream: (p: string) => {
      if (current === null) return realFs.createWriteStream(p);
      W("fs.createWriteStream", [p]);
      const got: Buffer[] = [];
      return {
        write: (c: Uint8Array) => (got.push(Buffer.from(c)), true),
        once: () => {},
        end: (cb?: (e?: Error | null) => void) => {
          try {
            W("fs.writeStream.end", [p, Buffer.concat(got)]);
            cb?.(null);
          } catch (e) {
            cb?.(e as Error);
          }
        },
      };
    },
  });
  const handle = (p: string) => ({
    stat: async () => toStats(W("fh.stat", [p])),
    read: async (buf: Buffer, off: number, len: number, pos: number) => {
      const got = W("fh.read", [p, off, len, pos]);
      const b = fromBytesJ(got.buffer);
      b.copy(buf, off, 0, got.bytesRead);
      return { bytesRead: got.bytesRead, buffer: buf };
    },
    close: async () => void W("fh.close", [p]),
  });
  await builtin("node:fs/promises", {
    readFile: worldOrAsync("fs.readFile", realFsPromises.readFile, (v) => (typeof v === "string" ? v : fromBytesJ(v))),
    writeFile: worldOrAsync("fs.writeFile", realFsPromises.writeFile),
    mkdir: worldOrAsync("fs.mkdir", realFsPromises.mkdir),
    rm: worldOrAsync("fs.rm", realFsPromises.rm),
    rename: worldOrAsync("fs.rename", realFsPromises.rename),
    stat: worldOrAsync("fs.stat", realFsPromises.stat, toStats),
    lstat: worldOrAsync("fs.lstat", realFsPromises.lstat, toStats),
    realpath: worldOrAsync("fs.realpath", realFsPromises.realpath),
    access: worldOrAsync("fs.access", realFsPromises.access),
    readdir: worldOrAsync("fs.readdir", realFsPromises.readdir),
    open: (p: string, flags: string) => (current === null ? realFsPromises.open(p, flags) : WA("fs.open", [p, flags]).then(() => handle(p))),
  });
  const realCrypto = await import("node:crypto");
  await builtin("node:crypto", { randomBytes: (n: number) => (current === null ? realCrypto.randomBytes(n) : fromBytesJ(W("crypto.randomBytes", [n]))) });
  const realOs = await import("node:os");
  await builtin("node:os", { tmpdir: () => (current === null ? realOs.tmpdir() : W("os.tmpdir", [])) });
  const realCp = await import("node:child_process");
  await builtin("node:child_process", {
    spawn: (cmd: string, args: string[], opts: any) => (current === null ? realCp.spawn(cmd, args, opts) : fakeChild(cmd, W("child_process.spawn", [cmd, args, opts]).$child, false)),
  });
}

const watchers = new Map<number, { dir: string; cb: (event: string, name: string | null) => void }>();
let effectModule: any;

// ---------------------------------------------------------------------------------------------------------------
// The program

type Msg = any;
let program: { send: (c: Msg) => Promise<Msg>; stderr: () => string; end: () => void; close: () => Promise<void> } | null = null;

function harness() {
  if (program !== null) return program;
  const shell = mkdtempSync(join(tmpdir(), "mb-updates-shell-"));
  const child = spawn(mbHarnessBinary()!, ["--builder", "harness-updates", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
  // (ended once the tests are done, `closeProgram`; and with this process, where they never got there)
  process.on("exit", () => {
    child.kill();
    rmSync(shell, { recursive: true, force: true });
  });
  const close = async () => {
    await childGone(child);
    rmSync(shell, { recursive: true, force: true });
  };
  let seq = 0;
  const waiting = new Map<number, (m: Msg) => void>();
  let stderr = "";
  child.stderr.on("data", (d) => {
    stderr += d;
    if (process.env.MB_UPDATES_DEBUG) process.stderr.write(`!! ${d}`);
  });
  createInterface({ input: child.stdout }).on("line", (line) => {
    if (process.env.MB_UPDATES_DEBUG) process.stderr.write(`<- ${line.slice(0, 300)}\n`);
    const m = JSON.parse(line);
    if (typeof m.ask === "number") {
      let reply: Msg;
      try {
        reply = { answer: m.ask, result: current!.answer(m.name, m.args) };
      } catch (e) {
        if (!(e instanceof Thrown)) throw e;
        reply = { answer: m.ask, threw: { kind: e.kind, fields: e.fields } };
      }
      child.stdin.write(`${JSON.stringify(reply)}\n`);
      return;
    }
    if (typeof m.say === "string") {
      try {
        current!.answer(m.say, m.args);
      } catch {}
      return;
    }
    waiting.get(m.re)?.(m);
    waiting.delete(m.re);
  });
  child.on("exit", (code) => {
    for (const w of waiting.values()) w({ err: { kind: "exit", fields: { message: `the program ended (${code}): ${stderr}` } } });
  });
  program = {
    stderr: () => stderr,
    end: () => child.stdin.end(),
    close,
    send: (c) =>
      new Promise((resolve) => {
        seq += 1;
        waiting.set(seq, resolve);
        if (process.env.MB_UPDATES_DEBUG) process.stderr.write(`-> ${JSON.stringify({ ...c, seq }).slice(0, 300)}\n`);
        child.stdin.write(`${JSON.stringify({ ...c, seq })}\n`);
      }),
  };
  return program;
}

/// Until the program has nothing it can go on with before the world answers, and asked nothing since.
async function syncMb() {
  for (;;) {
    const before = current!.answered;
    await harness().send({ op: "sync" });
    await settle();
    if (current!.answered === before) return;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// One case, run by each side

type Outcome = { ok: Json } | { err: { kind: string; fields: Json } };
const errJ = (e: any): { kind: string; fields: Json } => {
  const kind = e?.[KIND] ?? e?.constructor?.name ?? "Error";
  const fields: Record<string, Json> = { message: String(e?.message ?? e) };
  for (const [k, v] of Object.entries(e ?? {})) if (k !== "message" && k !== "stack") fields[k] = encode(v);
  return { kind, fields };
};

/// What a case does, the same for both sides.
interface Side {
  name: "ts" | "mb";
  fn(name: string, ...args: any[]): Promise<Outcome>;
  /// A function set going and not waited for (what it waits on comes as the case moves the clock or the world).
  begin(name: string, ...args: any[]): Promise<() => Promise<Outcome>>;
  /// A method of the Updates set going and not waited for.
  beginCall(method: string, ...args: any[]): Promise<() => Promise<Outcome>>;
  updates(opts: any): Promise<Outcome>;
  call(method: string, ...args: any[]): Promise<Outcome>;
  set(o: { origin?: string | null; running?: number }): Promise<void>;
  configSet(raw: any): Promise<void>;
  advance(ms: number): Promise<void>;
  fireWall(): Promise<void>;
  watch(dir: string, name: string | null): Promise<void>;
  hold(id: string): Promise<void>;
  letGo(id: string): Promise<void>;
  sync(): Promise<void>;
  /// A case begins: nothing of the one before goes on (its timers, its watches, its Updates).
  reset(): Promise<void>;
}

type Step = { what: string; out?: Outcome; calls: [string, Json][]; loose: boolean };
type Run = { steps: Step[]; files: Json };
type StepFn = (what: string, f: () => Promise<Outcome | void>, loose?: boolean) => Promise<Outcome | void>;
type Case = { name: string; world: () => World; run: (s: Side, step: StepFn, w: World) => Promise<void> };

/// Both sides' runs of `c`, compared step by step.
async function runCase(c: Case, tsSide: () => Side, mbSide: () => Side) {
  const runs: Run[] = [];
  for (const make of [tsSide, mbSide]) {
    const w = c.world();
    current = w;
    walls = [];
    watchers.clear();
    const side = make();
    await side.reset();
    const steps: Step[] = [];
    const step = async (what: string, f: () => Promise<Outcome | void>, loose = false) => {
      if (process.env.MB_UPDATES_DEBUG) process.stderr.write(`${side.name} ${c.name} / ${what}\n`);
      const from = w.log.length;
      const out = await f();
      await side.sync();
      steps.push({ what, out: out ?? undefined, calls: w.log.slice(from), loose });
      return out;
    };
    try {
      await c.run(side, step, w);
      await side.sync();
    } finally {
      current = null;
    }
    runs.push({ steps, files: w.vfs.dump() });
  }
  const [ts, mb] = runs as [Run, Run];
  // (MB_UPDATES_SHOW: what the TypeScript answered and asked at each step, when looking into a case)
  if (process.env.MB_UPDATES_SHOW) for (const st of (process.env.MB_UPDATES_SHOW === "mb" ? mb : ts).steps) process.stderr.write(`## ${st.what}\n${JSON.stringify(st.out)}\n${st.calls.map((x) => `  ${JSON.stringify(x).slice(0, 400)}`).join("\n")}\n`);
  assert.equal(mb.steps.length, ts.steps.length, `${c.name}: the steps`);
  for (let i = 0; i < ts.steps.length; i++) {
    const [a, b] = [ts.steps[i]!, mb.steps[i]!];
    const where = `${c.name} / ${a.what}`;
    assert.deepStrictEqual(norm(b.out), norm(a.out), `${where}: what it answered`);
    if (a.loose) {
      const sorted = (x: [string, Json][]) => x.map((y) => JSON.stringify(y)).sort();
      assert.deepStrictEqual(sorted(b.calls), sorted(a.calls), `${where}: what it asked of the world (in any order)`);
    } else assert.deepStrictEqual(b.calls, a.calls, `${where}: what it asked of the world`);
  }
  assert.deepStrictEqual(mb.files, ts.files, `${c.name}: the files`);
}

const norm = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

// ---------------------------------------------------------------------------------------------------------------

async function main() {
  effectModule = await import("effect");
  const { Effect, Duration, Exit, Fiber, FiberSet, Scope } = effectModule;
  await installMocks(Effect, Duration, Exit, Fiber, FiberSet, Scope);
  const realFetch = globalThis.fetch;
  globalThis.fetch = ((url: string, init?: any) => (current === null ? realFetch(url, init) : worldFetch("fetch")(url, init))) as typeof fetch;
  const realKill = process.kill;
  process.kill = ((pid: number, sig: any) => (current === null ? realKill(pid, sig) : W("process.kill", [pid, sig]))) as typeof process.kill;
  // (the machine the program is told it is on, the TypeScript's too: versions.ts reads process.arch, x64 on CI's Linux)
  const realArch = process.arch;
  Object.defineProperty(process, "arch", { value: MACHINE.arch, configurable: true });
  const realLog = console.log;
  const realError = console.error;
  console.log = (...a: unknown[]) => (current === null ? realLog(...a) : void W("console.log", a));
  console.error = (...a: unknown[]) => (current === null ? realError(...a) : void W("console.error", a));
  process.on("exit", () => {
    globalThis.fetch = realFetch;
    process.kill = realKill;
    Object.defineProperty(process, "arch", { value: realArch, configurable: true });
    console.log = realLog;
    console.error = realError;
  });

  const { setStationLang } = await import(src("ops/i18n.ts"));
  setStationLang("zh");
  const versions = await import(src("updates/versions.ts"));
  const signed = await import(src("updates/signed.ts"));
  const delta = await import(src("updates/delta.ts"));
  const release = await import(src("updates/release.ts"));
  const runtimes = await import(src("updates/runtimes.ts"));
  const codexRepair = await import(src("updates/codex-repair.ts"));
  const agy = await import(src("updates/agy-download.ts"));
  const channel = await import(src("updates/channel.ts"));
  const command = await import(src("updates/command.ts"));
  const holds = await import(src("updates/holds.ts"));
  const updatesMod = await import(src("updates/updates.ts"));
  const deltaScripts = await import(new URL("../../scripts/delta.ts", import.meta.url).href);
  const zh = JSON.parse(readFileSync(join(root, "client/i18n/catalog/zh/station.json"), "utf8"));
  const en = JSON.parse(readFileSync(join(root, "client/i18n/catalog/en/station.json"), "utf8"));

  // The regex codex-repair.ts reads `codex features list` by, taken from its source as it is.
  const usesHostSource = readFileSync(join(station, "src/updates/codex-repair.ts"), "utf8");
  const usesHostRe = new RegExp(/\/(\^code_mode_host[^\n]*?\$)\/m\.test/.exec(usesHostSource)![1]!, "m");

  const mb = harness();
  const setup = await mb.send({
    op: "setup",
    zh,
    en,
    lang: "zh",
    sep: "/",
    releaseKeys: process.env.STILLFAIL_RELEASE_KEYS ?? null,
    configEnv: process.env.STILLFAIL_CONFIG ?? null,
    pid: process.pid,
    now: 1_800_000_000_000,
    machine: { ...MACHINE, execPath: process.execPath, applier: join(root, "scripts/delta.ts") },
  });
  assert.deepStrictEqual(setup, { re: setup.re, ok: null }, `the program's setup: ${mb.stderr()}`);

  // ---- the TypeScript side ----

  const outcome = async (f: () => unknown): Promise<Outcome> => {
    try {
      return { ok: encode(await f()) };
    } catch (e) {
      return { err: errJ(e) };
    }
  };
  const trustedMap = (j: any) => (j === null || j === undefined ? undefined : new Map(j as [string, string][]));
  const tsFns = (clock: VClock): Record<string, (...a: any[]) => unknown> => {
    const fibers = () => (tsFibers ??= new (updatesFibers())("updates", clock.clock));
    let tsFibers: any;
    const updatesFibers = () => (globalThis as any).__FibersForTests;
    const wait = (yes: boolean) => (yes ? (ms: number) => fibers().sleep(ms) : undefined);
    return {
      channelOfId: versions.channelOfId,
      feed: versions.feed,
      newer: versions.newer,
      versionIn: versions.versionIn,
      offer: versions.offer,
      curlPercent: versions.curlPercent,
      tail: versions.tail,
      stepOf: versions.stepOf,
      downloading: versions.downloading,
      say: versions.say,
      sameWords: versions.sameWords,
      platform: versions.platform,
      channelFrom: versions.channelFrom,
      releaseChannel: versions.releaseChannel,
      releaseChannelSoon: versions.releaseChannelSoon,
      channelOf: versions.channelOf,
      channelOfSoon: versions.channelOfSoon,
      stationVersion: versions.stationVersion,
      stationVersionSoon: versions.stationVersionSoon,
      stationDownloadPercent: versions.stationDownloadPercent,
      keyId: signed.keyId,
      trustedKeys: (keys: string | null) => signed.trustedKeys(keys === null ? {} : { STILLFAIL_RELEASE_KEYS: keys }),
      verifySigned: (s: any, t: any) => signed.verifySigned(s, trustedMap(t)),
      verifyFeed: (s: any, t: any) => signed.verifyFeed(s, trustedMap(t)),
      allowed: signed.allowed,
      expected: signed.expected,
      sha256: (b: any) => signed.sha256(fromBytesJ(b)),
      checkPath: delta.checkPath,
      parseHeader: (b: any) => delta.parseHeader(fromBytesJ(b)),
      apply: (old: any, d: any) => {
        const db = fromBytesJ(d);
        const out: Buffer[] = [];
        const sinks: number[] = [];
        delta.apply(delta.parseHeader(db), fromBytesJ(old), db, (b: Uint8Array) => (out.push(Buffer.from(b)), sinks.push(b.length)));
        return { made: Buffer.concat(out), sinks };
      },
      readOld: (from: any, path: string) => delta.readOld(delta.parseHeader(fromBytesJ(W("fs.readFileSync", [path]))), from),
      applyFile: (from: any, d: string, out: string) => delta.applyFile(from, d, out),
      readFeed: (ch: string, base: string, via: string, retries: boolean) => release.readFeed(ch, base, 15_000, via === "cloud.fetch" ? worldFetch("cloud.fetch") : fetch, wait(retries)),
      verifiedOrNull: (said: any, t: any) => release.verifiedOrNull(said, trustedMap(t) ?? signed.trustedKeys()),
      bundledInstaller: release.bundledInstaller,
      deltaFor: release.deltaFor,
      planUpdate: (o: any) => release.planUpdate({ ...o, trusted: trustedMap(o.trusted), request: o.request === "cloud.fetch" ? worldFetch("cloud.fetch") : fetch, wait: wait(o.wait === true) }),
      earlierIn: (said: any, t: any) => release.earlierIn(said, trustedMap(t) ?? signed.trustedKeys()),
      backTo: release.backTo,
      archiveUrl: release.archiveUrl,
      planBack: (o: any) => release.planBack({ ...o, trusted: trustedMap(o.trusted), request: o.request === "cloud.fetch" ? worldFetch("cloud.fetch") : fetch, wait: wait(o.wait === true) }),
      takeArchive: (back: any, o: any) => {
        const ac = new AbortController();
        if (o.aborted) ac.abort(new DOMException("timed out", "TimeoutError"));
        return release.takeArchive(back, { signal: ac.signal, progress: (p: number) => void W("takeArchive.progress", [p]), request: o.request === "cloud.fetch" ? worldFetch("cloud.fetch") : fetch, wait: wait(o.wait === true) });
      },
      takeDelta: (plan: any, o: any) => {
        const ac = new AbortController();
        if (o.aborted) ac.abort(new DOMException("timed out", "TimeoutError"));
        return release.takeDelta(plan, {
          app: o.app,
          apply: o.apply === "apart" ? release.applyApart : async (app: string, d: string, out: string) => delta.applyFile({ dir: app }, d, out),
          signal: ac.signal,
          progress: (p: number) => void W("takeDelta.progress", [p]),
          request: o.request === "cloud.fetch" ? worldFetch("cloud.fetch") : fetch,
          wait: wait(o.wait === true),
        });
      },
      kindName: runtimes.kindName,
      kindCommand: runtimes.kindCommand,
      kindPackage: runtimes.kindPackage,
      ownNode: runtimes.ownNode,
      putOwnNodes: (env: any, data: string) => (runtimes.putOwnNodes(env, data), env),
      putOwnNodesSoon: async (env: any, data: string) => (await runtimes.putOwnNodesSoon(env, data), env),
      removeOwnNodeLinks: runtimes.removeOwnNodeLinks,
      pinNpmVersion: runtimes.pinNpmVersion,
      findCommandSoon: runtimes.findCommandSoon,
      howToUpdateSoon: runtimes.howToUpdateSoon,
      howToInstallSoon: (k: string, env: any, node: any) => runtimes.howToInstallSoon(k, env, node),
      npmInstallSoon: runtimes.npmInstallSoon,
      isNpmInstall: runtimes.isNpmInstall,
      linkBesideNpm: runtimes.linkBesideNpm,
      runLines: (p: string, a: string[], env: any, ms: number, lang?: string) => runtimes.runLines(p, a, env, ms, (l: string) => void W("runLines.line", [l]), lang ?? "zh"),
      run: (p: string, a: string[], env: any, ms: number, lang?: string) => runtimes.run(p, a, env, ms, lang ?? "zh"),
      hasCodexHostSoon: codexRepair.hasCodexHostSoon,
      codexBinarySoon: codexRepair.codexBinarySoon,
      missingCodexHost: (f: any, env: any) => codexRepair.missingCodexHost(f, env),
      findMissingCodexHost: codexRepair.findMissingCodexHost,
      usesCodexHost: (t: string) => usesHostRe.test(t),
      canSwitchCodex: codexRepair.canSwitchCodex,
      canSwitchCodexSoon: codexRepair.canSwitchCodexSoon,
      switchCodex: async (found: any, launcher: string, env: any) => {
        const c = await codexRepair.captureCodexSoon(found, env);
        return c === null ? null : codexRepair.switchCodex(c, launcher, env);
      },
      restoreCodex: codexRepair.restoreCodex,
      watchAgyDownload: (o: any) => {
        agyStop = agy.watchAgyDownload({
          manifests: o.manifests,
          build: () => WA("agy.build", []),
          staging: (url: string) => W("agy.staging", [url]),
          after: (ms: number, f: () => void) => fibers().after(ms, f),
          said: (v: string, got: number, total: number) => void W("agy.said", [v, got, total]),
        });
        return null;
      },
      stopAgy: () => (agyStop?.(), null),
      setChannelIn: channel.setChannelIn,
      setChannel: (data: string, ch: string, ms: number) => channel.setChannel(data, ch, ms),
      channelCommand: channel.channelCommand,
      writeWhole: updatesMod.writeWhole,
      answerChannelAsk: (runDir: string) => updatesMod.answerChannelAsk(runDir, async (c: string) => void W("answer.set", [c])),
      releaseBaseIn: command.releaseBaseIn,
      updateCommand: (args: string[], data: string, t: any) => command.updateCommand(args, data, trustedMap(t)),
      holding: holds.holding,
    };
  };
  let agyStop: (() => void) | undefined;

  const tsSide = (): Side => {
    const clock = new VClock(Effect, Duration);
    const fns = tsFns(clock);
    let u: any = null;
    const state = { origin: null as string | null, running: 0, raw: {} as any, listeners: new Set<(raw: any) => void>() };
    const heldTs = new Map<string, () => void>();
    const callTs = (method: string, ...a: any[]) =>
      outcome(async () => {
        switch (method) {
          case "check": return u.check(a[0] ?? true);
          case "installed": return u.installed;
          case "tried": return u.tried;
          case "poke": return u.poke(a[0], (i: any) => Object.assign(i, a[1]));
          case "updateOldCodex": return u.updateOldCodex(a[0], a[1]);
          default: return u[method](...a);
        }
      });
    return {
      name: "ts",
      fn: (name, ...args) => outcome(() => fns[name]!(...args)),
      begin: async (name, ...args) => {
        const p = outcome(() => fns[name]!(...args));
        await settle();
        return () => p;
      },
      beginCall: async (method, ...args) => {
        const p = callTs(method, ...args);
        await settle();
        return () => p;
      },
      updates: (o) =>
        outcome(() => {
          state.raw = o.config ?? {};
          state.origin = o.origin ?? null;
          const config = {
            raw: () => state.raw,
            listen: (l: (raw: any) => void) => (state.listeners.add(l), () => state.listeners.delete(l)),
            updateSoon: async (edit: (raw: any) => void) => {
              const next = structuredClone(state.raw);
              edit(next);
              state.raw = next;
              for (const l of [...state.listeners]) l(next);
              W("config.updateSoon", [next]);
              return next;
            },
          };
          u = new updatesMod.Updates({
            app: o.app, data: o.data, config, origin: () => state.origin, env: { ...o.env }, registry: o.registry, devinManifest: o.devinManifest,
            claudeReleases: o.claudeReleases, agyManifests: o.agyManifests, nodeDist: o.nodeDist, running: () => state.running,
            stationOnly: o.stationOnly, timing: o.timing, clock: clock.clock, trusted: trustedMap(o.trusted),
            ...(o.launcherInstaller === true ? { launcherInstaller: (script: string, env: Record<string, string>) => void W("opts.launcherInstaller", [script, env]) } : {}),
          });
          u.onRuntimeChanged((k: string, i: boolean, r: boolean) => void W("opts.runtimeChanged", [k, i, r]));
          u.changes(() => void W("listener.changed", []));
          return null;
        }),
      call: (method, ...a) => callTs(method, ...a),
      set: async (o) => {
        if (o.origin !== undefined) state.origin = o.origin;
        if (o.running !== undefined) state.running = o.running;
      },
      configSet: async (raw) => {
        state.raw = raw;
        for (const l of [...state.listeners]) l(raw);
      },
      advance: (ms) => clock.advance(ms),
      fireWall: async () => {
        const due = walls;
        walls = [];
        for (const [, f] of due) f();
      },
      watch: async (dir, name) => {
        for (const w of [...watchers.values()]) if (w.dir === dir) w.cb("rename", name);
      },
      hold: async (id) => void heldTs.set(id, holds.hold()),
      letGo: async (id) => heldTs.get(id)?.(),
      sync: () => settle(),
      reset: async () => {},
    };
  };
  // (ops/fibers.ts' Fibers as the mocks made it, for the functions given a part's clock)
  (globalThis as any).__FibersForTests = (await import(src("ops/fibers.ts"))).Fibers;

  const mbSide = (): Side => {
    const send = async (c: Msg): Promise<Outcome> => {
      const m = await harness().send(c);
      return "err" in m ? { err: m.err } : { ok: m.ok };
    };
    return {
      name: "mb",
      fn: (name, ...args) => send({ op: "fn", name, args: args.map(encode) }),
      begin: async (name, ...args) => {
        const p = send({ op: "fn", name, args: args.map(encode) });
        await syncMb();
        return () => p;
      },
      beginCall: async (method, ...args) => {
        const p = send({ op: "updates.call", method, args: args.map(encode) });
        await syncMb();
        return () => p;
      },
      updates: (o) => send({ op: "updates.new", opts: encode(o) }),
      call: (method, ...args) => send({ op: "updates.call", method, args: args.map(encode) }),
      set: async (o) => void (await send({ op: "set", ...o })),
      configSet: async (raw) => void (await send({ op: "config.set", raw })),
      advance: async (ms) => void (await send({ op: "advance", ms })),
      fireWall: async () => void (await send({ op: "wall.fire" })),
      watch: async (dir, name) => void (await send({ op: "watch", dir, name })),
      hold: async (id) => void (await send({ op: "hold", id })),
      letGo: async (id) => void (await send({ op: "letgo", id })),
      sync: () => syncMb(),
      reset: async () => void (await send({ op: "reset", now: 1_800_000_000_000 })),
    };
  };

  for (const c of cases({ deltaScripts, signedKeys: KEYS })) {
    // (MB_UPDATES_ONLY: the cases whose name has it, when looking into one)
    if (process.env.MB_UPDATES_ONLY && !c.name.includes(process.env.MB_UPDATES_ONLY)) continue;
    await test(c.name, () => runCase(c, tsSide, mbSide));
  }
  // On the machine's own files: the TypeScript through node:fs as it is, the program through the shell (host_io.mbt).
  await test("on real files: a delta applied, a release's build and channel, a download's percentage, Codex's binary", async () => {
    const dir = realFs.realpathSync(mkdtempSync(join(tmpdir(), "mb-updates-real-")));
    try {
      const D = deltaScripts;
      const app = join(dir, "app");
      mkdirSync(join(app, "lib"), { recursive: true });
      const a = programBytes(70_000, 5);
      const b = programBytes(30_000, 6);
      writeFileSync(join(app, "a.js"), a);
      writeFileSync(join(app, "lib", "b.bin"), b);
      writeFileSync(join(app, "BUILD"), "77\n");
      writeFileSync(join(app, "CHANNEL"), "beta\n");
      const made = Buffer.concat([a.subarray(0, 40_000), Buffer.from("the next build"), b, a.subarray(40_000)]);
      writeFileSync(join(dir, "d.delta"), D.makeDelta(Buffer.concat([readFileSync(join(app, "BUILD")), readFileSync(join(app, "CHANNEL")), a, b]), made, ["BUILD", "CHANNEL", "a.js", "lib/b.bin"], [], []));
      writeFileSync(join(dir, "update.log"), `${"x".repeat(6000)}\n####   12.5%\r######## 61.0%`);
      writeFileSync(join(dir, "codex"), Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 9]));
      // Codex where the host is beside it and runs, and where it is there but does not (no execute bit).
      mkdirSync(join(dir, "home", "bin"), { recursive: true });
      mkdirSync(join(dir, "home", "noexec"), { recursive: true });
      writeFileSync(join(dir, "home", "bin", "codex"), Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 9]), { mode: 0o755 });
      writeFileSync(join(dir, "home", "bin", "codex-code-mode-host"), "host", { mode: 0o755 });
      writeFileSync(join(dir, "home", "noexec", "codex"), Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 9]), { mode: 0o755 });
      writeFileSync(join(dir, "home", "noexec", "codex-code-mode-host"), "host", { mode: 0o644 });
      realFs.symlinkSync(join(dir, "home", "bin", "codex"), join(dir, "home", "codex-link"));
      writeFileSync(join(dir, "big.tar"), programBytes(3_500_000, 8));
      const home = { HOME: join(dir, "home"), PATH: "/usr/bin" };
      const inHome = { onPath: join(dir, "home", "codex-link"), real: join(dir, "home", "bin", "codex") };
      const calls: [string, any[]][] = [
        ["applyFile", [{ dir: app }, join(dir, "d.delta"), join(dir, "made")]],
        ["applyFile", [{ dir: join(dir, "nope") }, join(dir, "d.delta"), join(dir, "made2")]],
        ["stationVersionSoon", [app]],
        ["releaseChannelSoon", [join(dir, "app")]],
        ["stationDownloadPercent", [join(dir, "update.log")]],
        ["codexBinarySoon", [{ onPath: join(dir, "codex"), real: join(dir, "codex") }]],
        ["readOld", [{ dir: app }, join(dir, "d.delta")]],
        ["hasCodexHostSoon", [join(dir, "home", "bin", "codex")]],
        ["hasCodexHostSoon", [join(dir, "home", "noexec", "codex")]],
        ["hasCodexHostSoon", [join(dir, "nothing", "codex")]],
        ["canSwitchCodexSoon", [inHome, home]],
        ["canSwitchCodex", [inHome, home]],
        ["canSwitchCodexSoon", [inHome, { HOME: join(dir, "app") }]],
        ["canSwitchCodexSoon", [{ ...inHome, real: join(dir, "elsewhere") }, home]],
        ["hashFile", [join(dir, "big.tar")]],
        ["hashFile", [join(dir, "app")]],
        ["hashFile", [join(dir, "none.tar")]],
      ];
      const fnsReal: Record<string, (...a: any[]) => unknown> = {
        applyFile: (from: any, d: string, out: string) => delta.applyFile(from, d, out),
        stationVersionSoon: versions.stationVersionSoon,
        releaseChannelSoon: versions.releaseChannelSoon,
        stationDownloadPercent: versions.stationDownloadPercent,
        codexBinarySoon: codexRepair.codexBinarySoon,
        readOld: (from: any, path: string) => delta.readOld(delta.parseHeader(realFs.readFileSync(path)), from),
        hasCodexHostSoon: codexRepair.hasCodexHostSoon,
        canSwitchCodexSoon: codexRepair.canSwitchCodexSoon,
        canSwitchCodex: codexRepair.canSwitchCodex,
        // (release.ts' hashFile, as it reads: a stream, its sha256 and size)
        hashFile: (path: string) =>
          new Promise((resolve, reject) => {
            const hash = createHash("sha256");
            let size = 0;
            realFs.createReadStream(path).on("data", (b: Buffer) => (hash.update(b), (size += b.length))).on("end", () => resolve({ sha256: hash.digest("hex"), size })).on("error", reject);
          }),
      };
      for (const [name, args] of calls) {
        current = null;
        const ts = await outcome(() => fnsReal[name]!(...args));
        const tsMade = existsSync(join(dir, "made")) ? readFileSync(join(dir, "made")) : null;
        rmSync(join(dir, "made"), { force: true });
        current = new World();
        const m = await harness().send({ op: "host.fn", name, args: args.map(encode) });
        current = null;
        const mb: Outcome = "err" in m ? { err: m.err } : { ok: m.ok };
        const mbMade = existsSync(join(dir, "made")) ? readFileSync(join(dir, "made")) : null;
        rmSync(join(dir, "made"), { force: true });
        // (a system error's own errno, syscall and path are Node's: its message and code are what both say)
        const said = (o: any) => ("err" in o ? { err: { kind: o.err.kind, message: o.err.fields.message, code: o.err.fields.code ?? null } } : norm(o));
        assert.deepStrictEqual(said(mb), said(ts), `${name}(${JSON.stringify(args).slice(0, 120)}): what it answered`);
        assert.deepStrictEqual(mbMade, tsMade, `${name}: what it made`);
        if (name === "applyFile" && tsMade !== null) assert.deepStrictEqual(tsMade, made);
      }
    } finally {
      realFs.rmSync(dir, { recursive: true, force: true });
    }
  });
  harness().end();
}

// ---------------------------------------------------------------------------------------------------------------
// The tests' keys and releases (as scripts/release-sign.ts signs them)

const pair = () => {
  const { privateKey } = generateKeyPairSync("ed25519");
  const raw = Buffer.from(createPublicKey(privateKey).export({ format: "jwk" }).x as string, "base64url").toString("base64");
  return { privateKey, raw };
};
const keyIdOf = (raw: string) => createHash("sha256").update(Buffer.from(raw, "base64")).digest("hex").slice(0, 16);
const KEY = pair();
const OTHER = pair();
const KEYS = { KEY, OTHER };
const TRUSTED: [string, string][] = [[keyIdOf(KEY.raw), KEY.raw]];
const signedBy = (words: unknown, key = KEY) => {
  const bytes = Buffer.from(typeof words === "string" ? words : JSON.stringify(words));
  return { release: bytes.toString("base64"), signature: sign(null, bytes, key.privateKey).toString("base64"), key: keyIdOf(key.raw) };
};
const SHA_A = "a".repeat(64);
const SHA_B = "b".repeat(64);
const PLATFORM = "darwin-arm64";
const words = (build: number, b: Record<string, unknown> = {}) => ({
  kind: "stillfail-station-release",
  version: `0.1.${build}`,
  build,
  commit: "0".repeat(40),
  node: "24.21.0",
  builds: { [PLATFORM]: { sha256: SHA_A, size: 1000, nodeSha256: SHA_B, ...b } },
});
const feedOf = (build: number, b: Record<string, unknown> = {}, key = KEY) => ({ version: `0.1.${build}`, build, commit: "0".repeat(40), ...signedBy(words(build, b), key) });
const shaHex = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
const programBytes = (n: number, seed = 1) => {
  const out = Buffer.alloc(n);
  for (let i = 0; i < n; i++) {
    seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
    out[i] = 32 + ((seed >>> 16) % 95);
  }
  return out;
};

// ---------------------------------------------------------------------------------------------------------------
// The cases

/// A case that only calls functions, each a step.
const calls = (name: string, world: () => World, list: [string, ...unknown[]][]): Case => ({
  name,
  world,
  run: async (s, step) => {
    for (const [fn, ...args] of list) await step(`${fn}(${JSON.stringify(args).slice(1, 80)})`, () => s.fn(fn, ...args));
  },
});
const empty = () => new World();

function cases(o: { deltaScripts: any; signedKeys: typeof KEYS }): Case[] {
  const out: Case[] = [];
  // ---- versions.ts ----
  out.push(calls("versions: newer, versionIn, offer", empty, [
    ...([["2.1.9", "2.1.10"], ["2.1.10", "2.1.9"], ["1.0", "1.0.0"], ["1.0.0", "1.0"], ["0.46.0", "0.46.0"], ["v1.2", "1.3"], ["1.2-beta", "1.2"], ["", "1"], ["99999999999999999999.1", "99999999999999999999.2"], ["007", "7"], ["a.b", "c"]] as const).map(([a, b]) => ["newer", a, b] as [string, ...unknown[]]),
    ...["2.1.284 (Claude Code)", "codex-cli 0.46.0", "vv1.2.3", "version: 1.2", "(1.2.3)", "1.", "x.1", "1..2", "nothing here", "a 3.x.1 1.2.3", "1.2\u00a03"].map((t) => ["versionIn", t] as [string, ...unknown[]]),
    ...([["0.1.5", "0.1.6", "stable", "stable"], ["0.1.6", "0.1.5", "stable", "beta"], ["0.1.6", "0.1.5", "beta", "beta"], ["0.1.6", "0.2.6", "stable", "beta"], [null, "0.1.6", "stable", "stable"], ["0.1.5", "", "stable", "stable"], ["0.1.10", "0.1.9", "stable", "beta"], ["x", "0.1.1", "stable", "stable"]] as const).map((a) => ["offer", ...a] as [string, ...unknown[]]),
  ]));
  out.push(calls("versions: curl's percentage, a command's tail, its steps", empty, [
    ["curlPercent", "##########                    33.3%\r######## 50%"],
    ["curlPercent", "######## 50.0%\n####### 101%"],
    ["curlPercent", "no bar here\n### 12%\nsome text"],
    ["curlPercent", "###   45"],
    ["curlPercent", "  12%"],
    ["curlPercent", "### .5%\r### 1e1%\r### +7%"],
    ["curlPercent", "### 99.9%   "],
    ["curlPercent", ""],
    ["tail", "", "zh"],
    ["tail", "\n\n  \n", "en"],
    ["tail", "one\ntwo\nthree\nfour\nfive\nsix", "zh"],
    ["tail", "\u001b[31mred\u001b[0m\nbar 10%\rbar 50%\rbar 100%\r\n", "en"],
    ["tail", "x".repeat(700) + "\n" + "😀".repeat(650), "zh"],
    ["stepOf", "==> Downloading https://x"],
    ["stepOf", "  ==> Pouring codex"],
    ["stepOf", "Setting up Claude Code..."],
    ["stepOf", "something else"],
    ["downloading", "2.1.0", 1_500_000, 3_000_000],
    ["downloading", "2.1.0", 4_000_000, 3_000_000],
    ["downloading", "2.1.0", 2_500_000, null],
    ["downloading", "2.1.0", 2_500_000, 0],
    ["channelOfId", " beta\n"],
    ["channelOfId", "Beta"],
    ["feed", "stable", "https://o"],
    ["feed", "beta", "https://o"],
    ["channelFrom", { updateChannel: "beta" }, "stable"],
    ["channelFrom", { updateChannel: "nightly" }, "beta"],
    ["channelFrom", null, null],
    ["say", { key: "station.updates.draining", args: { n: 3 } }, "zh"],
    ["say", { key: "station.updates.draining", args: { n: 1 } }, "en"],
    ["say", { text: "as said" }, "en"],
    ["sameWords", { key: "a" }, { key: "a" }],
    ["sameWords", { key: "a", args: {} }, { key: "a" }],
    ["platform"],
  ]));

  // ---- versions.ts, its files ----
  out.push(calls("versions: the release's channel and build, the installer's download", () => {
    const w = new World();
    w.vfs.file("/rel/a/CHANNEL", "beta\n").file("/rel/a/BUILD", "1234\n").file("/rel/b/BUILD", "x1").file("/rel/f/CHANNEL", "nightly");
    w.vfs.file("/data/run/update.log", `${"x".repeat(5000)}\n######## 41.5%\r###########   62.0%`);
    w.vfs.file("/data/run/short.log", "### 7%");
    return w;
  }, [
    ["releaseChannel", "/rel/a"], ["releaseChannel", "/rel/a"], ["releaseChannelSoon", "/rel/b"], ["releaseChannelSoon", "/rel/f"],
    ["channelOf", { updateChannel: "stable" }, "/rel/d"], ["channelOf", {}, "/rel/a2"], ["channelOfSoon", {}, "/rel/e"], ["channelOfSoon", { updateChannel: "beta" }, "/rel/e2"],
    ["stationVersion", "/rel/a"], ["stationVersion", "/rel/b"], ["stationVersionSoon", "/rel/a"], ["stationVersionSoon", "/rel/c"],
    ["stationDownloadPercent", "/data/run/update.log"], ["stationDownloadPercent", "/data/run/short.log"], ["stationDownloadPercent", "/nope"],
  ]));

  // ---- signed.ts, keys.ts ----
  const OTHER = o.signedKeys.OTHER;
  out.push(calls("signed: keys, feeds, what is allowed", empty, [
    ["keyId", KEY.raw], ["keyId", "vJeYSXYJW04ANrn49w+I7nzS/8NFsh1MKwRCiJ8PVPI="], ["trustedKeys", null], ["trustedKeys", ` ${KEY.raw} , ,${OTHER.raw},${KEY.raw}`],
    ["verifyFeed", feedOf(5), TRUSTED],
    ["verifyFeed", feedOf(5, {}, OTHER), TRUSTED],
    ["verifyFeed", {}, TRUSTED],
    ["verifyFeed", { ...feedOf(5), key: null }, TRUSTED],
    ["verifyFeed", { ...feedOf(5), key: 7 }, TRUSTED],
    ["verifyFeed", { ...feedOf(5), signature: feedOf(6).signature }, TRUSTED],
    ["verifyFeed", { ...feedOf(5), signature: "AAAA" }, TRUSTED],
    ["verifyFeed", { version: "0.1.5", ...signedBy("not json") }, TRUSTED],
    ["verifyFeed", { ...signedBy({ kind: "something else" }) }, TRUSTED],
    ["verifyFeed", { ...signedBy(5) }, TRUSTED],
    ["verifyFeed", { ...feedOf(5), version: "0.1.6" }, TRUSTED],
    ["verifyFeed", { ...feedOf(5), version: 5 }, TRUSTED],
    ["verifyFeed", { ...signedBy({ ...words(5), version: "0.7.5" }) }, TRUSTED],
    ["verifyFeed", { ...signedBy({ ...words(5), version: "0.1.6" }) }, TRUSTED],
    ["verifyFeed", { ...signedBy({ ...words(5), build: 5.5 }) }, TRUSTED],
    ["verifyFeed", { ...signedBy({ ...words(5), builds: null }) }, TRUSTED],
    ["verifyFeed", { ...signedBy({ ...words(5), builds: [{ sha256: SHA_A, size: 1, nodeSha256: SHA_B }] }) }, TRUSTED],
    ["verifyFeed", { ...signedBy({ ...words(5), builds: { x: { sha256: "A".repeat(64), size: 1, nodeSha256: SHA_B } } }) }, TRUSTED],
    ["verifyFeed", { ...signedBy({ ...words(5), builds: { x: { sha256: [SHA_A], size: 1, nodeSha256: SHA_B } } }) }, TRUSTED],
    ["verifyFeed", { ...signedBy(words(5, { rawSha256: SHA_A })) }, TRUSTED],
    ["verifyFeed", { ...signedBy(words(5, { rawSha256: SHA_A, rawSize: -1 })) }, TRUSTED],
    ["verifyFeed", { ...signedBy(words(5, { rawSha256: SHA_A, rawSize: 10 })) }, TRUSTED],
    ["verifyFeed", { ...signedBy(words(5, { rawSize: null })) }, TRUSTED],
    ["verifySigned", feedOf(9), TRUSTED],
    ["allowed", words(5), null, "stable", null], ["allowed", words(5), 6, "stable", "stable"], ["allowed", words(5), 6, "stable", "beta"], ["allowed", words(5), 6, "beta", "beta"], ["allowed", words(6), 6, "beta", "stable"],
    ["expected", words(5), PLATFORM], ["expected", words(5), "linux-x64"], ["expected", words(5), null],
    ["sha256", bytesJ(Buffer.from("hello"))],
  ]));

  // ---- delta.ts ----
  const D = o.deltaScripts;
  const chunkOf = (raw: Buffer) => {
    const p = deflateRawSync(raw);
    const b = Buffer.alloc(8);
    b.writeUInt32LE(raw.length, 0);
    b.writeUInt32LE(p.length, 4);
    return Buffer.concat([b, p]);
  };
  const END8 = Buffer.alloc(8);
  const rec = (x: number, y: number, z: number) => {
    const b = Buffer.alloc(24);
    b.writeBigInt64LE(BigInt(x), 0);
    b.writeBigInt64LE(BigInt(y), 8);
    b.writeBigInt64LE(BigInt(z), 16);
    return b;
  };
  const headed = (h: any) => D.encodeHeader({ files: [], inflate: [], deflate: [], ...h });
  const oldBlob = Buffer.concat([programBytes(3000, 3), programBytes(2000, 4)]);
  const madeBlob = Buffer.concat([programBytes(1500, 3), Buffer.from("changed in the middle"), programBytes(3000, 4), programBytes(500, 9)]);
  const goodDelta: Buffer = D.makeDelta(oldBlob, madeBlob, ["a.js", "lib/b.bin"], [], []);
  const bigOld = programBytes(2_400_000, 11);
  const bigMade = Buffer.concat([bigOld.subarray(0, 1_000_000), Buffer.from("x"), bigOld.subarray(1_000_000)]);
  const bigDelta: Buffer = D.makeDelta(bigOld, bigMade, ["big"], [], []);
  const manual = (oldB: Buffer, made: number, payload: Buffer[], deflate: any[] = []) => Buffer.concat([headed({ files: ["f"], oldSize: oldB.length, oldSha256: shaHex(oldB), deflate, madeSize: made }), ...payload]);
  const old16 = Buffer.from("0123456789abcdef");
  out.push(calls("delta: headers refused or read", empty, [
    ...["", "/abs", "C:x", "c:", "a\\b", "a\u0000b", "a//b", "a/../b", "ok/file", "..", "./a", "a/", "é/ü"].map((p) => ["checkPath", p] as [string, ...unknown[]]),
    ["parseHeader", bytesJ(goodDelta)],
    ["parseHeader", bytesJ(Buffer.from("SFDELTA0"))],
    ["parseHeader", bytesJ(Buffer.from("SFDELTA1"))],
    ["parseHeader", bytesJ(goodDelta.subarray(0, 40))],
    ["parseHeader", bytesJ(Buffer.concat([Buffer.from("SFDELTA1"), Buffer.from([0, 0, 0, 0, 1, 0, 0, 0]), Buffer.alloc(8, 0), Buffer.from([0, 0, 0, 0, 0, 0, 0x40, 0])]))],
    ["parseHeader", bytesJ(headed({ inflate: [{ at: 10, len: 5 }, { at: 12, len: 1 }], oldSize: 1, oldSha256: SHA_A, madeSize: 1 }))],
    ["parseHeader", bytesJ(headed({ files: ["x"], inflate: [{ at: 1, len: 1 }], oldSize: 1, oldSha256: SHA_A, madeSize: 1 }))],
    ["parseHeader", bytesJ(headed({ deflate: [{ at: 0, len: 10 }], oldSize: 1, oldSha256: SHA_A, madeSize: 5 }))],
    ["parseHeader", bytesJ(headed({ files: ["../up"], oldSize: 1, oldSha256: SHA_A, madeSize: 1 }))],
    ["parseHeader", bytesJ(Buffer.concat([Buffer.from("SFDELTA1"), Buffer.from([1, 0, 0, 0, 2, 0, 0xff, 0xfe])]))],
    ["parseHeader", bytesJ(Buffer.concat([Buffer.from("SFDELTA1"), Buffer.from([1, 0, 0, 0, 4, 0, 0xef, 0xbb, 0xbf, 0x61])]))],
  ]));
  out.push(calls("delta: applied (bsdiff, chunks, deflate ranges)", empty, [
    ["apply", bytesJ(oldBlob), bytesJ(goodDelta)],
    ["apply", bytesJ(bigOld), bytesJ(bigDelta)],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 20, [chunkOf(Buffer.concat([rec(4, 16, -2), Buffer.from([1, 1, 1, 1]), programBytes(16)])), END8]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 20, [chunkOf(Buffer.concat([rec(4, 4, 30), Buffer.from([0, 0, 0, 0]), Buffer.from("tail")])), chunkOf(Buffer.concat([rec(12, 0, 0), Buffer.alloc(12, 2)])), END8]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 20, [chunkOf(rec(4, 0, 0))]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 4, [chunkOf(Buffer.concat([rec(4, 0, 0), Buffer.alloc(4)])), END8, Buffer.from([1])]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 4, [chunkOf(Buffer.concat([rec(-1, 0, 0)])), END8]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 4, [chunkOf(Buffer.concat([rec(5, 0, 0)])), END8]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 4, [chunkOf(Buffer.concat([rec(2, 1, 0), Buffer.alloc(3), Buffer.alloc(10)])), END8]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 4, [Buffer.from([4, 0, 0, 0, 3, 0, 0, 0, 1, 2, 3]), END8]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 4, [Buffer.from([0, 0, 0x20, 0, 3, 0, 0, 0, 1, 2, 3]), END8]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 4, [Buffer.from([4, 0, 0, 0, 30, 0, 0, 0, 1, 2, 3])]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 4, [chunkOf(Buffer.concat([rec(0, 4, 0), Buffer.from("abcd")])), END8, END8]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 30, [chunkOf(Buffer.concat([rec(0, 30, 0), programBytes(30, 5)])), END8], [{ at: 2, len: 10 }, { at: 12, len: 0 }, { at: 20, len: 10 }]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 30, [chunkOf(Buffer.concat([rec(0, 25, 0), programBytes(25, 5)])), chunkOf(Buffer.concat([rec(0, 5, 0), programBytes(5, 6)])), END8], [{ at: 20, len: 10 }]))],
    ["apply", bytesJ(old16), bytesJ(manual(old16, 30, [chunkOf(Buffer.concat([rec(0, 30, 0), programBytes(30, 5)])), END8], [{ at: 30, len: 0 }]))],
  ]));
  const deltaWorld = () => {
    const w = new World();
    w.vfs.file("/inst/a.js", oldBlob.subarray(0, 3000)).file("/inst/lib/b.bin", oldBlob.subarray(3000)).file("/inst/other", "not in the delta");
    w.vfs.file("/d/good.delta", goodDelta);
    w.vfs.file("/short/a.js", oldBlob.subarray(0, 2999)).file("/short/lib/b.bin", oldBlob.subarray(3000));
    w.vfs.file("/swap/a.js", Buffer.concat([oldBlob.subarray(1, 3000), Buffer.from("z")])).file("/swap/lib/b.bin", oldBlob.subarray(3000));
    w.vfs.dir("/nofile/lib").file("/nofile/a.js", oldBlob.subarray(0, 3000));
    // An apk: deflated entries inflated in place make the old blob.
    const inner = programBytes(800, 21);
    const packed = deflateRawSync(inner, { level: 6 });
    const apk = Buffer.concat([Buffer.from("PK-head"), packed, Buffer.from("PK-tail")]);
    const blob = Buffer.concat([Buffer.from("PK-head"), inner, Buffer.from("PK-tail")]);
    const apkMade = Buffer.concat([Buffer.from("PK-head2"), inner, Buffer.from("PK-tail")]);
    w.vfs.file("/apk/old.apk", apk);
    w.vfs.file("/d/apk.delta", D.makeDelta(blob, apkMade, [], [{ at: 7, len: packed.length }], [{ at: 8, len: 800 }]));
    w.vfs.file("/d/apkbad.delta", D.makeDelta(blob, apkMade, [], [{ at: 7, len: packed.length + 50 }], []));
    w.vfs.file("/d/apkpast.delta", D.makeDelta(blob, apkMade, [], [{ at: 7, len: 5000 }], []));
    w.vfs.file("/d/garbage.delta", "not a delta at all");
    w.vfs.dir("/out");
    return w;
  };
  out.push(calls("delta: applied to what is installed, its files", deltaWorld, [
    ["applyFile", { dir: "/inst" }, "/d/good.delta", "/out/made"],
    ["readOld", { dir: "/inst" }, "/d/good.delta"],
    ["applyFile", { dir: "/short" }, "/d/good.delta", "/out/short"],
    ["applyFile", { dir: "/swap" }, "/d/good.delta", "/out/swap"],
    ["applyFile", { dir: "/nofile" }, "/d/good.delta", "/out/nofile"],
    ["applyFile", { dir: "/inst" }, "/d/garbage.delta", "/out/garbage"],
    ["applyFile", { dir: "/inst" }, "/d/missing.delta", "/out/missing"],
    ["applyFile", { apk: "/apk/old.apk" }, "/d/good.delta", "/out/apk1"],
    ["applyFile", { dir: "/inst" }, "/d/apk.delta", "/out/apk2"],
    ["applyFile", { apk: "/apk/old.apk" }, "/d/apk.delta", "/out/apk3"],
    ["applyFile", { apk: "/apk/old.apk" }, "/d/apkbad.delta", "/out/apk4"],
    ["applyFile", { apk: "/apk/old.apk" }, "/d/apkpast.delta", "/out/apk5"],
    ["applyFile", { dir: "/inst" }, "/d/good.delta", "/nowhere/made"],
  ]));
  // ---- release.ts ----
  const feedWorld = () => {
    const w = new World();
    let busy = 0;
    let broke = 0;
    w.route("https://o/releases/station.json", { body: JSON.stringify(feedOf(6)) });
    w.route("https://o/releases/station-beta.json", () => (++busy <= 1 ? { status: 503, body: "busy" } : { body: JSON.stringify(feedOf(7)) }));
    w.route("https://bad/releases/station.json", { body: "{not json" });
    w.route("https://gone/releases/station.json", { status: 404, body: "no" });
    w.route("https://flaky/releases/station.json", () => (++broke <= 4 ? new Thrown("TypeError", { message: "fetch failed" }) : { body: "{}" }));
    w.route("https://slow/releases/station.json", () => new Thrown("DOMException", { message: "The operation was aborted due to timeout", name: "TimeoutError" }));
    return w;
  };
  out.push({
    name: "release: the feed read, tried again on the way",
    world: feedWorld,
    run: async (s, step) => {
      await step("stable", () => s.fn("readFeed", "stable", "https://o", "fetch", false));
      await step("by the cloud's transport", () => s.fn("readFeed", "stable", "https://o", "cloud.fetch", false));
      await step("not JSON", () => s.fn("readFeed", "stable", "https://bad", "fetch", true));
      await step("refused, not tried again", () => s.fn("readFeed", "stable", "https://gone", "fetch", true));
      await step("503 without a wait", () => s.fn("readFeed", "beta", "https://o", "fetch", false));
      const beta = await s.begin("readFeed", "beta", "https://o", "fetch", true);
      await step("503, then a wait", async () => {});
      await step("the wait over", async () => s.advance(1000));
      await step("read", () => beta());
      const flaky = await s.begin("readFeed", "stable", "https://flaky", "fetch", true);
      await step("waits", async () => s.advance(999));
      await step("each wait", async () => s.advance(1 + 2000 + 4000));
      await step("given up", () => flaky());
      const slow = await s.begin("readFeed", "stable", "https://slow", "fetch", true);
      await step("its deadline, tried again", async () => s.advance(7000));
      await step("given up", () => slow());
    },
  });
  const raw = programBytes(4000, 31);
  const rawSha = shaHex(raw);
  const appOld = { "BUILD": "5\n", "station/main.js": programBytes(2500, 41), "bin/install.zh.sh": "#!/bin/sh\necho installing\n" };
  const appBlob = Buffer.concat(Object.keys(appOld).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b))).map((k) => Buffer.from((appOld as any)[k])));
  const appFiles = Object.keys(appOld).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  const stationDelta: Buffer = D.makeDelta(appBlob, raw, appFiles, [], []);
  const deltaSha = shaHex(stationDelta);
  const withDeltas = (feed: any, deltas: any[]) => ({ ...feed, deltas: { [PLATFORM]: deltas } });
  const rawBuild = { size: 50_000, rawSha256: rawSha, rawSize: raw.length };
  const planWorld = () => {
    const w = new World();
    const app = (dir: string, build = "5\n", installer = true) => {
      for (const [k, v] of Object.entries(appOld)) if (k !== "bin/install.zh.sh" || installer) w.vfs.file(`${dir}/${k}`, k === "BUILD" ? build : v);
    };
    app("/app5");
    app("/app9", "9\n");
    app("/noinst", "5\n", false);
    app("/nobuild", "x\n");
    w.route("https://o/releases/station.json", { body: JSON.stringify(withDeltas(feedOf(6, rawBuild), [{ from: 4, file: "x.delta", sha256: SHA_A, size: 10 }, { from: 5, file: "station/5-6.delta", sha256: deltaSha, size: stationDelta.length }])) });
    w.route("https://o/releases/station-beta.json", { body: JSON.stringify(feedOf(6, {}, OTHER)) });
    w.route("https://c/releases/station.json", { body: JSON.stringify(feedOf(6, { sha256: SHA_B })) });
    w.route("https://nox/releases/station.json", { body: JSON.stringify(withDeltas({ ...feedOf(6), ...signedBy({ ...words(6), builds: { "linux-x64": { sha256: SHA_A, size: 1, nodeSha256: SHA_B } } }) }, [])) });
    let n = 0;
    w.route("https://retry/releases/station.json", () => (++n === 1 ? { status: 502, body: "" } : { body: JSON.stringify(feedOf(6)) }));
    return w;
  };
  out.push({
    name: "release: verified, what a delta is, the plan",
    world: planWorld,
    run: async (s, step) => {
      for (const [said, t] of [[feedOf(6), TRUSTED], [feedOf(6, {}, OTHER), TRUSTED], [{}, null], [feedOf(6), null]] as const) await step("verifiedOrNull", () => s.fn("verifiedOrNull", said, t));
      await step("bundledInstaller", () => s.fn("bundledInstaller", "/app5", "en"));
      const build = { sha256: SHA_A, size: 50_000, nodeSha256: SHA_B, rawSha256: rawSha, rawSize: 4000 };
      const good = { from: 5, file: "station/5-6.delta", sha256: deltaSha, size: 900 };
      for (const [said, b, p, cur] of [
        [withDeltas({}, [good]), build, PLATFORM, 5], [withDeltas({}, [good]), build, null, 5], [withDeltas({}, [good]), build, PLATFORM, null],
        [withDeltas({}, [good]), { ...build, rawSha256: undefined }, PLATFORM, 5], [{ deltas: { [PLATFORM]: "x" } }, build, PLATFORM, 5],
        [withDeltas({}, [null, { from: 4 }, good]), build, PLATFORM, 5], [withDeltas({}, [{ ...good, file: "../x" }]), build, PLATFORM, 5],
        [withDeltas({}, [{ ...good, file: "a/./b" }]), build, PLATFORM, 5], [withDeltas({}, [{ ...good, file: "a b" }]), build, PLATFORM, 5],
        [withDeltas({}, [{ ...good, sha256: "nope" }]), build, PLATFORM, 5], [withDeltas({}, [{ ...good, size: 0 }]), build, PLATFORM, 5],
        [withDeltas({}, [{ ...good, size: 50_000 }]), build, PLATFORM, 5], [withDeltas({}, [{ ...good, size: 1.5 }]), build, PLATFORM, 5],
        [withDeltas({}, [{ ...good, from: "5" }]), build, PLATFORM, 5],
      ] as const) await step("deltaFor", () => s.fn("deltaFor", said, b, p, cur, "https://o"));
      const plan = (o: any) => s.fn("planUpdate", { base: "https://o", channel: "stable", app: "/app5", installed: "stable", lang: "zh", trusted: TRUSTED, request: "fetch", ...o });
      await step("with a delta", () => plan({}));
      await step("unverified", () => plan({ channel: "beta", lang: "en" }));
      await step("older", () => plan({ app: "/app9" }));
      await step("older, back to stable", () => plan({ app: "/app9", installed: "beta" }));
      await step("no build here", () => plan({ base: "https://nox" }));
      await step("no installer", () => plan({ app: "/noinst" }));
      await step("no version of its own", () => plan({ app: "/nobuild", base: "https://c" }));
      await step("by the cloud", () => plan({ base: "https://c", request: "cloud.fetch" }));
      const later = await s.begin("planUpdate", { base: "https://retry", channel: "stable", app: "/app5", installed: "stable", lang: "zh", trusted: TRUSTED, request: "fetch", wait: true });
      await step("a gateway that could not reach it", async () => s.advance(1000));
      await step("then read", () => later());
    },
  });
  const takeWorld = () => {
    const w = planWorld();
    let broken = 0;
    w.route("https://o/releases/station/5-6.delta", { headers: { "content-length": String(stationDelta.length) }, chunks: [stationDelta.subarray(0, 100), stationDelta.subarray(100)] });
    w.route("https://o/releases/long.delta", { headers: { "content-length": "12" }, body: stationDelta });
    w.route("https://o/releases/more.delta", { body: Buffer.concat([stationDelta, Buffer.from("x")]) });
    w.route("https://o/releases/sum.delta", { body: Buffer.concat([stationDelta.subarray(0, -1), Buffer.from("x")]) });
    w.route("https://o/releases/broke.delta", () => (++broken <= 1 ? { chunks: [stationDelta.subarray(0, 50)] } : { body: stationDelta }));
    w.route("https://o/releases/cut.delta", { chunks: [stationDelta.subarray(0, 50)], breaks: new Thrown("TypeError", { message: "terminated" }) });
    w.route("https://o/releases/busy.delta", { status: 503, body: "" });
    w.route("https://o/releases/nobody.delta", { status: 200, body: null });
    w.proc((program, args) => (args.includes("--apply-delta") || args.includes("apply") ? (args.includes("/fail") ? [["stderr", "Error: first\nError: it failed\n"], ["close", 1]] : args.includes("/sig") ? [["close", null, "SIGKILL"]] : [["close", 0]]) : null));
    return w;
  };
  const planOf = (file: string, size = stationDelta.length, sum = deltaSha, rawSum = rawSha) => ({
    release: words(6), script: "/app5/bin/install.zh.sh", env: { STILLFAIL_ORIGIN: "https://o" },
    delta: { from: 5, url: `https://o/releases/${file}`, sha256: sum, size, rawSha256: rawSum, rawSize: raw.length },
  });
  out.push({
    name: "release: a delta taken, or let go",
    world: takeWorld,
    run: async (s, step) => {
      const take = (plan: any, o: any = {}) => s.fn("takeDelta", plan, { app: "/app5", request: "fetch", ...o });
      await step("none", () => take({ ...planOf("x"), delta: null }));
      await step("made", () => take(planOf("station/5-6.delta")));
      await step("its length not the feed's", () => take(planOf("long.delta")));
      await step("more than the feed's", () => take(planOf("more.delta")));
      await step("its sha256 not the feed's", () => take(planOf("sum.delta")));
      await step("cut short, no wait", () => take(planOf("cut.delta")));
      await step("busy", () => take(planOf("busy.delta")));
      await step("no body", () => take(planOf("nobody.delta")));
      await step("not the raw archive", () => take(planOf("station/5-6.delta", stationDelta.length, deltaSha, SHA_B)));
      await step("its deadline passed", () => take(planOf("station/5-6.delta"), { aborted: true }));
      await step("applied apart", () => take(planOf("station/5-6.delta"), { apply: "apart" }));
      await step("applied apart, failing", () => take({ ...planOf("station/5-6.delta"), delta: { ...planOf("station/5-6.delta").delta } }, { apply: "apart", app: "/fail" }));
      await step("applied apart, killed", () => take(planOf("station/5-6.delta"), { apply: "apart", app: "/sig" }));
      const again = await s.begin("takeDelta", planOf("broke.delta"), { app: "/app5", request: "fetch", wait: true });
      await step("broke off, tried again", async () => s.advance(1000));
      await step("made at last", () => again());
    },
  });

  // Going back: the feed's earlier releases, verified; the plan; the archive taken.
  const archive4 = Buffer.from("the archive of build 4, as it was put");
  const built4 = { sha256: shaHex(archive4), size: archive4.length };
  const withEarlier = (feed: any, earlier: any[]) => ({ ...feed, earlier: earlier.map((f) => ({ version: f.version, release: f.release, signature: f.signature, key: f.key })) });
  const earlier = [
    feedOf(9), feedOf(4, built4), feedOf(7, {}, OTHER), { ...feedOf(6), ...signedBy({ ...words(6), builds: { "linux-x64": { sha256: SHA_A, size: 1, nodeSha256: SHA_B } } }) },
    feedOf(4), { version: "0.1.3", release: 1, signature: "x", key: "k" }, feedOf(8),
  ];
  const backWorld = () => {
    const w = planWorld();
    w.vfs.dir("/tmp");
    w.route("https://back/releases/station.json", { body: JSON.stringify(withEarlier(feedOf(10), earlier)) });
    w.route("https://bare/releases/station.json", { body: JSON.stringify(feedOf(10)) });
    let broken = 0;
    const kept = `https://back/releases/station/archive/stable/4-${built4.sha256}-${PLATFORM}.tar.gz`;
    w.route(kept, { headers: { "content-length": String(archive4.length) }, chunks: [archive4.subarray(0, 10), archive4.subarray(10)] });
    w.route("https://back/releases/long.tar.gz", { headers: { "content-length": "3" }, body: archive4 });
    w.route("https://back/releases/sum.tar.gz", { body: Buffer.concat([archive4.subarray(0, -1), Buffer.from("x")]) });
    w.route("https://back/releases/busy.tar.gz", { status: 503, body: "" });
    w.route("https://back/releases/broke.tar.gz", () => (++broken <= 1 ? { chunks: [archive4.subarray(0, 5)] } : { body: archive4 }));
    return w;
  };
  out.push({
    name: "release: going back, the releases before the latest verified, the plan, the archive",
    world: backWorld,
    run: async (s, step) => {
      const feed = withEarlier(feedOf(10), earlier);
      for (const [said, t] of [[feed, TRUSTED], [feed, null], [feedOf(10), TRUSTED], [{ earlier: "x" }, TRUSTED], [{ earlier: [null, 1] }, TRUSTED]] as const) {
        await step("earlierIn", () => s.fn("earlierIn", said, t));
      }
      const verified = [words(9), words(8), words(6), { ...words(4), builds: { [PLATFORM]: { sha256: SHA_A, size: 1000, nodeSha256: SHA_B } } }];
      for (const [cur, p] of [[9, PLATFORM], [10, PLATFORM], [4, PLATFORM], [9, null], [null, PLATFORM], [9, "linux-x64"]] as const) {
        await step("backTo", () => s.fn("backTo", verified, cur, p));
      }
      await step("archiveUrl", () => s.fn("archiveUrl", "https://o", "beta", words(4), PLATFORM));
      await step("archiveUrl on Windows", () => s.fn("archiveUrl", "https://o", "stable", { ...words(4), builds: { "win32-x64": { sha256: SHA_B } } }, "win32-x64"));
      const plan = (o: any) => s.fn("planBack", { base: "https://back", channel: "stable", app: "/app9", to: "0.1.4", lang: "zh", trusted: TRUSTED, request: "fetch", ...o });
      await step("planned", () => plan({}));
      await step("not named", () => plan({ to: "0.1.5", lang: "en" }));
      await step("not verified", () => plan({ to: "0.1.7" }));
      await step("not older", () => plan({ to: "0.1.9" }));
      await step("not older, in English", () => plan({ app: "/app5", to: "0.1.8", lang: "en" }));
      await step("no build here", () => plan({ to: "0.1.6" }));
      await step("no installer", () => plan({ app: "/noinst" }));
      await step("no version of its own", () => plan({ app: "/nobuild" }));
      await step("a feed naming none", () => plan({ base: "https://bare" }));
      await step("by the cloud", () => plan({ request: "cloud.fetch" }));
      const backOf = (url: string, sha = built4.sha256, size = built4.size) => ({
        release: words(4, built4), script: "/app9/bin/install.zh.sh", env: { STILLFAIL_ORIGIN: "https://back" }, delta: null,
        archive: { url, sha256: sha, size },
      });
      const take = (back: any, o: any = {}) => s.fn("takeArchive", back, { request: "fetch", ...o });
      await step("taken", () => take(backOf(`https://back/releases/station/archive/stable/4-${built4.sha256}-${PLATFORM}.tar.gz`)));
      await step("its length not its words'", () => take(backOf("https://back/releases/long.tar.gz")));
      await step("its sha256 not its words'", () => take(backOf("https://back/releases/sum.tar.gz")));
      await step("busy, no wait", () => take(backOf("https://back/releases/busy.tar.gz")));
      await step("not there", () => take(backOf("https://back/releases/gone.tar.gz")));
      const again = await s.begin("takeArchive", backOf("https://back/releases/broke.tar.gz"), { request: "fetch", wait: true });
      await step("broke off, tried again", async () => s.advance(1000));
      await step("taken at last", () => again());
    },
  });

  // ---- runtimes.ts ----
  const runtimeWorld = () => {
    const w = new World();
    const commands: Record<string, any> = {
      brew: { onPath: "/opt/homebrew/bin/brew", real: "/opt/homebrew/bin/brew" },
      npm: { onPath: "/usr/local/bin/npm", real: "/usr/local/lib/node_modules/npm/bin/npm-cli.js" },
      vp: { onPath: "/v/bin/vp", real: "/v/real/vp" },
    };
    w.on("platform.findCommandSoon", ([name, env]) => (env?.PATH === "/none" ? null : commands[name] ?? null));
    w.on("platform.shimUpdate", ([found]) => (found.real.includes("/winget/") ? { program: "winget", args: ["upgrade", "x"], noUpdate: 2316632107 } : found.real.includes("/nonpm/") ? "no-npm" : null));
    w.vfs.file("/n1/lib/node_modules/@anthropic-ai/claude-code/cli.js", "x").file("/n1/bin/npm", "npm", 0o755);
    w.vfs.file("/n2/bin/npm", "npm", 0o755).file("/n2/lib/node_modules/@openai/codex/bin/codex.js", "x");
    w.vfs.file("/v/real/vp", "vp", 0o755).link("/v/bin/vp", "/v/real/vp").link("/w/bin/vp", "/elsewhere/vp");
    w.vfs.file("/home/u/.local/bin/npm", "npm", 0o755);
    return w;
  };
  const found = (onPath: string, real = onPath) => ({ onPath, real });
  const env = { PATH: "/usr/bin", HOME: "/home/u" };
  const noPath = { PATH: "/none", HOME: "/home/u" };
  const node = { version: "24.1.0", build: { dist: "node-v24.1.0-darwin-arm64", archive: "node-v24.1.0-darwin-arm64.tar.gz", bin: "bin", npm: "npm", tar: "tar" }, at: "/d/node/node-v24.1.0-darwin-arm64", bin: "/d/node/node-v24.1.0-darwin-arm64/bin" };
  out.push(calls("runtimes: how each is updated or installed", runtimeWorld, [
    ["howToUpdateSoon", "station", found("/x"), env],
    ["howToUpdateSoon", "agy", found("/a/agy"), env],
    ["howToUpdateSoon", "hermes", found("/h"), env],
    ["howToUpdateSoon", "devin", found("/l/devin", "/home/u/.local/share/devin/cli/_versions/1.2/devin"), env],
    ["howToUpdateSoon", "devin", found("/l/devin", "/opt/devin"), env],
    ["howToUpdateSoon", "pi", found("/l/pi", "/opt/pi/pi"), env],
    ["howToUpdateSoon", "pi", found("/l/pi", "/n9/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"), noPath],
    ["howToUpdateSoon", "claude", found("/usr/local/bin/claude", "/opt/homebrew/Caskroom/claude-code/2.1.0/claude"), env],
    ["howToUpdateSoon", "codex", found("/usr/local/bin/codex", "/opt/homebrew/Cellar/codex/0.4/bin/codex"), noPath],
    ["howToUpdateSoon", "dsh", found("/usr/local/bin/dsh", "/opt/homebrew/Cellar/dsh/1/bin/dsh"), env],
    ["howToUpdateSoon", "claude", found("/l/claude", "/n1/lib/node_modules/@anthropic-ai/claude-code/cli.js"), env],
    ["howToUpdateSoon", "codex", found("/n2/bin/codex", "/n2/lib/node_modules/@openai/codex/bin/codex.js"), env],
    ["howToUpdateSoon", "grok", found("/home/u/.local/bin/grok", "/n3/lib/node_modules/@xai-official/grok/cli.js"), env],
    ["howToUpdateSoon", "grok", found("/q/grok", "/n3/lib/node_modules/@xai-official/grok/cli.js"), noPath],
    ["howToUpdateSoon", "codex", found("/q/codex", "/x/node_modules/@openai/codex/bin/codex.js"), env],
    ["howToUpdateSoon", "claude", found("/q/claude", "/home/u/.local/share/claude/versions/2.1"), env],
    ["howToUpdateSoon", "dsh", found("/q/dsh", "/opt/dsh"), env],
    ["howToUpdateSoon", "codex", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0-aarch64/bin/codex"), env],
    ["howToUpdateSoon", "codex", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/codex"), env],
    ["howToUpdateSoon", "codex", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/other"), env],
    ["howToUpdateSoon", "codex", found("/home/u/.codex/packages/standalone/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/codex"), env],
    ["howToUpdateSoon", "codex", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0"), env],
    ["howToUpdateSoon", "codex", found("/q/codex", "/opt/codex"), env],
    ["howToUpdateSoon", "claude", found("/v/bin/claude", "/v/real/vp"), env],
    ["howToUpdateSoon", "codex", found("/w/bin/codex", "/v/real/vp"), env],
    ["howToUpdateSoon", "codex", found("/w/bin/codex", "/v/real/vp"), noPath],
    ["howToUpdateSoon", "codex", found("/q/codex", "/winget/codex.exe"), env],
    ["howToUpdateSoon", "dsh", found("/q/dsh", "/nonpm/dsh"), env],
    ["howToInstallSoon", "station", env, null], ["howToInstallSoon", "hermes", env, null], ["howToInstallSoon", "claude", env, null], ["howToInstallSoon", "agy", env, null], ["howToInstallSoon", "devin", env, null],
    ["howToInstallSoon", "dsh", env, null], ["howToInstallSoon", "grok", noPath, node], ["howToInstallSoon", "pi", noPath, null], ["howToInstallSoon", "pi", noPath, node],
    ["howToInstallSoon", "codex", env, null], ["howToInstallSoon", "codex", noPath, node],
    ["npmInstallSoon", noPath, node, ["install", "-g", "--prefix", "/p", "x@latest"], "X"],
    ["pinNpmVersion", { program: "npm", args: ["install", "-g", "@openai/codex@latest", "--prefix", "/p"], noUpdate: 3 }, "@openai/codex", "0.47.0"],
    ...[["npm", "install"], ["/a/npm.cmd", "install"], ["/a/NPM", "install"], ["/a/npx", "install"], ["npm", "update"], ["npm"]].map(([p, a]) => ["isNpmInstall", { program: p, args: a === undefined ? [] : [a] }] as [string, ...unknown[]]),
    ["kindName", "station"], ["kindName", "dsh"], ["kindCommand", "station"], ["kindPackage", "pi"], ["kindPackage", "devin"],
  ]));
  out.push(calls("runtimes: the station's own Nodes", () => {
    const w = runtimeWorld();
    w.on("platform.nodeBuild", ([v]) => ({ dist: `node-v${v}-darwin-arm64`, archive: `node-v${v}-darwin-arm64.tar.gz`, bin: "bin", npm: "npm", tar: "tar" }));
    w.vfs.file("/d/node/node-v22.1.0-darwin-arm64/bin/npm", "x").file("/d/node/node-v24.1.0-darwin-arm64/bin/npm", "x").dir("/d/node/node-v9-darwin-arm64/bin").file("/d/node/other", "x");
    w.vfs.link("/home/u/.local/bin/node", "/d/node/node-v24.1.0-darwin-arm64/bin/node").link("/home/u/.local/bin/codex", "/d/node/node-v24.1.0-darwin-arm64/bin/codex").link("/home/u/.local/bin/claude", "/opt/claude").file("/home/u/.local/bin/npx", "x");
    return w;
  }, [
    ["ownNode", "/d", "24.1.0"],
    ["putOwnNodes", { PATH: "/usr/bin", HOME: "/home/u" }, "/d"],
    ["putOwnNodes", { PATH: "/d/node/node-v24.1.0-darwin-arm64/bin" }, "/d"],
    ["putOwnNodesSoon", {}, "/d"],
    ["putOwnNodesSoon", {}, "/nothing"],
    ["removeOwnNodeLinks", { HOME: "/home/u" }, "/d"],
    ["removeOwnNodeLinks", {}, "/d"],
  ]));
  out.push({
    name: "runtimes: running a command",
    world: () => {
      const w = runtimeWorld();
      w.proc((p, a) => {
        if (p === "lines") return [["stdout", "one\ntw"], ["stderr", "err1\n"], ["stdout", "o\r\nthree"], ["stderr", "carried"], ["close", 3]];
        if (p === "signed") return [["stdout", "x"], ["close", -5]];
        if (p === "killed") return [["stdout", "x\n"], ["close", null, "SIGTERM"]];
        if (p === "gone") return [["error", "spawn gone ENOENT"]];
        if (p === "hangs") return [["stdout", "started\n"], ["hang"]];
        if (p.endsWith("npm") && a[0] === "prefix") return [["stdout", "something\n/pre\n"], ["close", 0]];
        if (p === "/failnpm" && a[0] === "prefix") return [["close", 1]];
        return [["close", 0]];
      });
      w.on("platform.findCommandSoon", ([name, e]) => (e?.PATH === "/pre/bin" && name === "dsh" ? { onPath: "/pre/bin/dsh", real: "/pre/lib/dsh.js" } : null));
      w.is("platform.linkCommand", true);
      w.on("shellPath.withShellCommand", ([name, e]) => ({ ...e, SHELL_FOR: name }));
      return w;
    },
    run: async (s, step) => {
      await step("its lines", () => s.fn("runLines", "lines", ["a"], env, 1000));
      await step("stdout then stderr", () => s.fn("run", "lines", [], env, 1000, "en"));
      await step("a negative code, unsigned", () => s.fn("runLines", "signed", [], env, 1000));
      await step("a signal", () => s.fn("runLines", "killed", [], env, 1000));
      await step("not there", () => s.fn("run", "gone", [], env, 1000));
      const hung = await s.begin("runLines", "hangs", [], env, 5000, "en");
      await step("its deadline", async () => s.fireWall());
      await step("not finished", () => hung());
      await step("linked beside npm", () => s.fn("linkBesideNpm", "dsh", { program: "/usr/local/bin/npm", args: ["install", "-g", "@deepseek-ai/dsh@latest"] }, env));
      await step("not when npm was given a prefix", () => s.fn("linkBesideNpm", "dsh", { program: "/usr/local/bin/npm", args: ["install", "-g", "--prefix", "/p"] }, env));
      await step("not when npm says no prefix", () => s.fn("linkBesideNpm", "dsh", { program: "/failnpm", args: ["install"] }, env));
      await step("nothing found there", () => s.fn("linkBesideNpm", "grok", { program: "/usr/local/bin/npm", args: ["install"] }, env));
    },
  });

  // ---- codex-repair.ts ----
  const MACH = Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3]);
  const codexWorld = () => {
    const w = new World();
    const rel = "/home/u/.codex/packages/standalone/releases/0.50.0/bin";
    w.vfs.file(`${rel}/codex`, MACH, 0o755).link("/home/u/.local/bin/codex", `${rel}/codex`);
    w.vfs.file("/home/u/.codex2/bin/codex", MACH, 0o755).file("/home/u/.codex2/bin/codex-code-mode-host", MACH, 0o755).link("/home/u/.local/bin/codex2", "/home/u/.codex2/bin/codex");
    w.vfs.file("/opt/n/lib/node_modules/@openai/codex/bin/codex.js", "#!/usr/bin/env node", 0o755).link("/opt/n/bin/codex", "../lib/node_modules/@openai/codex/bin/codex.js");
    w.vfs.file("/opt/n/lib/node_modules/@openai/codex-darwin-arm64/package.json", "{}").file("/opt/n/lib/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex", MACH, 0o755);
    w.vfs.file("/opt/s/codex", "#!/bin/sh\n", 0o755);
    w.vfs.file("/home/u/ro/codex", MACH, 0o755);
    w.vfs.nodes.get("/home/u/ro")!.mode = 0o555;
    w.vfs.file("/new/bin/codex", "launcher", 0o755);
    w.proc((p, a) => (a[0] === "features" ? (p.includes("codex2") ? [["stdout", "code_mode_host  stable  true\n"], ["close", 0]] : p.includes("old") ? [["close", 1]] : [["stdout", "unified_exec  stable  true\ncode_mode_host  under development  true\n"], ["close", 0]]) : null));
    return w;
  };
  const home = { HOME: "/home/u", PATH: "/usr/bin" };
  out.push(calls("codex-repair: binaries, hosts, a switch and its way back", codexWorld, [
    ["codexBinarySoon", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/codex")],
    ["codexBinarySoon", found("/opt/n/bin/codex", "/opt/n/lib/node_modules/@openai/codex/bin/codex.js")],
    ["codexBinarySoon", found("/opt/s/codex")],
    ["codexBinarySoon", found("/nope")],
    ["hasCodexHostSoon", "/home/u/.codex2/bin/codex"],
    ["hasCodexHostSoon", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/codex"],
    ["missingCodexHost", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/codex"), home],
    ["missingCodexHost", found("/home/u/.local/bin/codex2", "/home/u/.codex2/bin/codex"), home],
    ["missingCodexHost", found("/opt/old/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/codex"), home],
    ["findMissingCodexHost", "/home/u/.local/bin/codex", home],
    ["findMissingCodexHost", "/no/such", home],
    ["findMissingCodexHost", "./codex", home],
    ["findMissingCodexHost", "codex", home],
    ...["code_mode_host  under development  true", "code_mode_host true", "code_mode_host  true", "code_mode_host removed true", "code_mode_host\tremoved\ttrue", "code_mode_host  removed  true", "code_mode_host removedx  true", "code_mode_host x true \t", "code_mode_host x false", "x\r\ncode_mode_host a true\r\n", "code_mode_hostx a true"].map((t) => ["usesCodexHost", t] as [string, ...unknown[]]),
    ["canSwitchCodex", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/codex"), home],
    ["canSwitchCodexSoon", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/codex"), home],
    ["canSwitchCodexSoon", found("/opt/n/bin/codex", "/opt/n/lib/node_modules/@openai/codex/bin/codex.js"), home],
    ["canSwitchCodexSoon", found("/home/u/ro/codex"), home],
    ["canSwitchCodexSoon", found("codex"), home],
    ["canSwitchCodexSoon", found("/home/u/.local/bin/codex", "/elsewhere"), home],
    ["canSwitchCodexSoon", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/codex"), { PATH: "/x" }],
    ["switchCodex", found("/home/u/.local/bin/codex", "/home/u/.codex/packages/standalone/releases/0.50.0/bin/codex"), "/new/bin/codex", home],
    ["restoreCodex", "/home/u/.local/bin/codex", "/other/launcher", "/home/u/.local/bin/codex.stillfail-backup-x"],
    ["restoreCodex", "/home/u/.local/bin/codex", "/new/bin/codex", "/home/u/.local/bin/codex.stillfail-backup-262c3d4e5f60718"],
    ["switchCodex", found("/home/u/.local/bin/codex", "/elsewhere"), "/new/bin/codex", home],
  ]));

  // ---- agy-download.ts ----
  out.push({
    name: "agy-download: the installer's download looked at",
    world: () => {
      const w = new World();
      w.is("agy.build", "darwin-arm64").is("agy.staging", "/tmp/agy/build.bin");
      w.route("https://m/darwin-arm64.json", { body: JSON.stringify({ version: "1.2.3", url: "https://dl/agy.tgz" }) });
      w.route("HEAD https://dl/agy.tgz", { headers: { "content-length": "3000" } });
      w.route("https://dl/agy.tgz", { headers: { "content-length": "3000" } });
      w.route("https://m2/darwin-arm64.json", { status: 500, body: "" });
      w.route("https://m3/darwin-arm64.json", { body: "null" });
      return w;
    },
    run: async (s, step, w) => {
      await step("asked before the download began", () => s.fn("watchAgyDownload", { manifests: "https://m" }));
      w.vfs.file("/tmp/agy/build.bin", Buffer.alloc(1000));
      await step("a third in", async () => s.advance(500));
      w.vfs.file("/tmp/agy/build.bin", Buffer.alloc(3000));
      await step("all of it", async () => s.advance(500));
      await step("not looked at again", async () => s.advance(5000));
      await step("a manifest refused", () => s.fn("watchAgyDownload", { manifests: "https://m2" }));
      await step("a manifest of nothing", () => s.fn("watchAgyDownload", { manifests: "https://m3" }));
      await step("stopped", () => s.fn("watchAgyDownload", { manifests: "https://m" }));
      await step("stopped at once", () => s.fn("stopAgy"));
      await step("nothing after", async () => s.advance(2000));
    },
  });

  // ---- channel.ts ----
  const channelWorld = () => {
    const w = new World();
    w.vfs.file("/c1/run/station.json", JSON.stringify({ pid: 77, channel: 1 })).file("/c1/config.json", JSON.stringify({ updateChannel: "beta" }));
    w.vfs.file("/c2/run/station.json", JSON.stringify({ pid: 78, channel: 1 })).file("/c2/config.json", "{}");
    w.vfs.file("/c3/run/station.json", JSON.stringify({ pid: 79, channel: 1 }));
    w.vfs.file("/c4/run/station.json", JSON.stringify({ pid: 80, channel: 1 }));
    w.vfs.file("/c5/run/station.json", JSON.stringify({ pid: 81, channel: 1 }));
    w.vfs.file("/c6/run/station.json", JSON.stringify({ pid: 82, channel: 2 }));
    w.vfs.file("/c7/run/station.json", JSON.stringify({ pid: 83, channel: 1 }));
    w.vfs.file("/c8/run/station.json", "{not json");
    w.vfs.file("/bad/config.json", "{nope").dir("/isdir/config.json");
    w.is("ConfigFile.raw", { language: "en" });
    w.on("process.kill", ([pid]) => (pid === 83 ? new Thrown("Error", { message: "kill ESRCH", code: "ESRCH" }) : pid === 82 ? new Thrown("Error", { message: "kill EPERM", code: "EPERM" }) : true));
    w.is("platform.isLauncher", true);
    w.on("platform.askLauncher", ([pid], ww) => {
      const dir = { 78: "/c2", 79: "/c3", 80: "/c4" }[pid as number];
      if (pid === 81) return new Thrown("Error", { message: "no launcher here" });
      if (dir) ww.vfs.file(`${dir}/run/channel-answer`, pid === 78 ? "ok beta\n" : pid === 79 ? "error not on this one\n" : "something\n");
      return null;
    });
    w.vfs.file("/runs/a/channel-ask", "beta\n").file("/runs/b/channel-ask", "nightly").dir("/runs/c").file("/runs/d/channel-ask", "stable");
    w.on("answer.set", ([c]) => (c === "stable" ? new Thrown("Error", { message: "refused here" }) : null));
    return w;
  };
  out.push(calls("channel: the channel set here, or asked of the station", channelWorld, [
    ["setChannelIn", "/c0", "beta"],
    ["setChannel", "/c0", "stable", 1000],
    ["setChannel", "/c1", "beta", 1000],
    ["setChannel", "/c2", "beta", 1000],
    ["setChannel", "/c3", "beta", 1000],
    ["setChannel", "/c4", "beta", 1000],
    ["setChannel", "/c5", "beta", 1000],
    ["setChannel", "/c6", "beta", 1000],
    ["setChannel", "/c7", "beta", 1000],
    ["setChannel", "/c8", "beta", 1000],
    ["channelCommand", ["channel"], "/c1"],
    ["channelCommand", ["--data", "/x", "channel", "--app", "/rel/ch1"], "/c0"],
    ["channelCommand", ["channel", "nightly"], "/c0"],
    ["channelCommand", ["channel", "a", "b"], "/c0"],
    ["channelCommand", ["channel", "stable"], "/c2"],
    ["channelCommand", ["channel"], "/bad"],
    ["channelCommand", ["channel"], "/isdir"],
    ["channelCommand", ["--port", "3", "channel"], "/c0"],
    ["answerChannelAsk", "/runs/a"], ["answerChannelAsk", "/runs/b"], ["answerChannelAsk", "/runs/c"], ["answerChannelAsk", "/runs/d"],
    ["writeWhole", "/runs/c/x", "text"],
    ["writeWhole", "/nowhere/x", "text"],
  ]));

  // ---- command.ts ----
  const commandWorld = () => {
    const w = planWorld();
    w.vfs.file("/s1/mesh/cloud.json", JSON.stringify({ origin: "https://o///" })).file("/s2/mesh/cloud.json", JSON.stringify({ origin: "https://c", provider: "comma" }));
    w.vfs.file("/s3/mesh/cloud.json", "{bad").file("/s4/mesh/cloud.json", JSON.stringify({ origin: "" })).dir("/s5/mesh/cloud.json");
    w.vfs.file("/s6/mesh/cloud.json", JSON.stringify({ origin: "https://app.still.fail" })).file("/s6/config.json", JSON.stringify({ updateChannel: "stable" }));
    w.vfs.file("/s7/mesh/cloud.json", JSON.stringify({ origin: "https://o" })).file("/s7/config.json", "{bad");
    w.route("https://c/stations/releases/station.json", { body: JSON.stringify(feedOf(6)) });
    w.route("https://app.still.fail/releases/station.json", { body: JSON.stringify(feedOf(6)) });
    w.route("https://o/releases/station/5-6.delta", { headers: { "content-length": String(stationDelta.length) }, body: stationDelta });
    w.vfs.file("/d/apply.delta", stationDelta);
    w.vfs.dir("/out");
    return w;
  };
  out.push(calls("command: where the releases are, what to run", commandWorld, [
    ["releaseBaseIn", "/s0"], ["releaseBaseIn", "/s1"], ["releaseBaseIn", "/s2"], ["releaseBaseIn", "/s3"], ["releaseBaseIn", "/s4"], ["releaseBaseIn", "/s5"],
    ["updateCommand", ["update"], "/s1", TRUSTED],
    ["updateCommand", ["update", "--app", "/app5", "--beta", "--stable"], "/s1", TRUSTED],
    ["updateCommand", ["update", "--app", "/app5", "extra"], "/s1", TRUSTED],
    ["updateCommand", ["update", "--app", "/app5"], "/s0", TRUSTED],
    ["updateCommand", ["update", "--app", "/app5"], "/s1", TRUSTED],
    ["updateCommand", ["update", "--app", "/app5", "--data", "/s2"], "/s2", TRUSTED],
    ["updateCommand", ["update", "--app", "/app5"], "/s6", TRUSTED],
    ["updateCommand", ["update", "--app", "/app5"], "/s7", TRUSTED],
    ["updateCommand", ["update", "--app", "/app9"], "/s1", TRUSTED],
    ["updateCommand", ["update", "--apply-delta", "--app", "/app5", "--delta", "/d/apply.delta", "--out", "/out/made"], "/s1", null],
    ["updateCommand", ["update", "--apply-delta", "--app", "/app9", "--delta", "/d/apply.delta", "--out", "/out/made9"], "/s1", null],
    ["updateCommand", ["update", "--apply-delta", "--app", "/app5"], "/s1", null],
  ]));
  // ---- updates.ts: the Updates ----
  const NODE_BUILD = { dist: "node-v24.1.0-darwin-arm64", archive: "node-v24.1.0-darwin-arm64.tar.gz", bin: "bin", npm: "npm", tar: "tar" };
  type StationWorld = World & { state: Record<string, any> };
  const stationWorld = (o: { feed?: any; app?: string; claude?: boolean; codex?: "npm" | "standalone" | null } = {}): StationWorld => {
    const w = new World() as StationWorld;
    const state: Record<string, any> = { claude: o.claude === false ? null : "2.1.0", codex: o.codex === null ? null : "0.46.0", dsh: null, devin: null, linked: false, grokFails: true };
    w.state = state;
    const app = o.app ?? "/st/app";
    for (const [k, v] of Object.entries(appOld)) w.vfs.file(`${app}/${k}`, v);
    if (app !== "/st/app") w.vfs.dir("/st/app");
    w.vfs.file(`${app}/NODE_VERSION`, "24.1.0\n");
    w.vfs.dir("/st/run").dir("/tmp");
    w.route("https://o/releases/station.json", { body: JSON.stringify(o.feed ?? feedOf(6)) });
    w.route("https://o/releases/station-beta.json", { body: JSON.stringify(feedOf(7)) });
    const reg = (pkg: string, version: string) => w.route(`https://reg/${pkg}/latest`, { body: JSON.stringify({ version }) });
    reg("@anthropic-ai/claude-code", "2.1.300");
    reg("@openai/codex", "0.47.0");
    reg("@deepseek-ai/dsh", "1.0.0");
    reg("@cursor/sdk", "1.2.0");
    reg("@earendil-works/pi-coding-agent", "0.9.0");
    w.route("https://reg/@xai-official/grok/latest", { status: 500, body: "" });
    w.route("https://devin/manifest.json", { body: JSON.stringify({ version: "3.0.0" }) });
    w.route("https://reg/@openai/codex/0.47.0-darwin-arm64", { body: JSON.stringify({ dist: { tarball: "https://reg/codex.tgz" } }) });
    w.route("https://reg/codex.tgz", { headers: { "content-length": "3000000" }, chunks: [Buffer.alloc(1_000_000, 1), Buffer.alloc(1_000_000, 2), Buffer.alloc(1_000_000, 3)] });
    w.vfs.file("/usr/local/bin/npm", "npm", 0o755).file("/usr/local/lib/node_modules/@openai/codex/bin/codex.js", "#!/usr/bin/env node\n", 0o755);
    w.on("platform.findCommandSoon", ([name, env]) => {
      if (env?.PATH === "/none") return null;
      if (name === "claude" && state.claude) return { onPath: "/usr/local/bin/claude", real: "/opt/homebrew/Caskroom/claude-code/2.1.0/claude" };
      if (name === "codex" && state.codex) return o.codex === "standalone"
        ? (() => { try { return { onPath: "/home/u/.local/bin/codex", real: w.vfs.resolve("/home/u/.local/bin/codex", true, "realpath") }; } catch { return null; } })()
        : { onPath: "/usr/local/bin/codex", real: "/usr/local/lib/node_modules/@openai/codex/bin/codex.js" };
      if (name === "dsh" && (state.dsh || (env?.PATH ?? "").includes("/pre/bin") || state.linked)) return { onPath: "/usr/local/bin/dsh", real: "/pre/lib/dsh.js" };
      if (name === "devin" && state.devin) return { onPath: "/home/u/.local/bin/devin", real: "/home/u/.local/share/devin/cli/_versions/3/devin" };
      if (name === "brew") return { onPath: "/opt/homebrew/bin/brew", real: "/opt/homebrew/bin/brew" };
      if (name === "npm" && !state.noNpm) return { onPath: "/usr/local/bin/npm", real: "/usr/local/lib/node_modules/npm/bin/npm-cli.js" };
      return null;
    });
    w.is("platform.nodeBuild", NODE_BUILD);
    w.is("cursor.sdkVersionSoon", "1.0.0");
    w.is("platform.startInstaller", true);
    w.is("platform.agyBuild", null);
    w.on("platform.linkCommand", () => ((state.linked = true), true));
    w.proc((p, a) => {
      const v = (said: string | null) => (said === null ? [["stderr", "not found\n"], ["close", 127]] : [["stdout", `${said}\n`], ["close", 0]]);
      if (a[0] === "--version") {
        if (p.endsWith("claude")) return v(state.claude === null ? null : `${state.claude} (Claude Code)`);
        if (p.endsWith("codex")) return v(state.codex === null ? null : `codex-cli ${state.codex}`);
        if (p.endsWith("dsh")) return v("dsh 1.0.0");
        if (p.endsWith("devin")) return v(state.devin);
        return v(null);
      }
      if (p.endsWith("brew")) {
        state.claude = "2.1.300";
        return [["stdout", "==> Downloading claude-code\n==> Pouring claude-code\n"], ["close", 0]];
      }
      if (p.endsWith("npm") && a[0] === "cache") return [["close", 0]];
      if (p.endsWith("npm") && a[0] === "prefix") return [["stdout", "/pre\n"], ["close", 0]];
      if (p.endsWith("npm") && a.includes("@openai/codex@0.47.0")) {
        state.codex = "0.47.0";
        return [["stdout", "added 1 package\n"], ["close", 0]];
      }
      if (p.endsWith("npm") && a.includes("@deepseek-ai/dsh@latest")) return [["stdout", "added 1 package\n"], ["close", 0]];
      if (p.endsWith("npm") && a.includes("@xai-official/grok@latest")) return [["stdout", "npm ERR! code E404\n"], ["stderr", "npm ERR! not found\n"], ["close", 1]];
      if (p === "/bin/sh" && a.join(" ").includes("devin")) {
        state.devin = "2.9.0";
        return [["stdout", "installed\n"], ["close", 0]];
      }
      return [["close", 0]];
    });
    return w;
  };
  const OPTS = {
    app: "/st/app", data: "/st", config: {}, origin: "https://o", env: { PATH: "/usr/bin", HOME: "/home/u" }, registry: "https://reg", devinManifest: "https://devin/manifest.json",
    claudeReleases: "https://claude-rel", agyManifests: "https://agy", nodeDist: "https://nodejs", timing: { followLook: 5000 }, trusted: TRUSTED, nodeVersion: process.versions.node,
  };
  const pages = async (s: Side, step: StepFn, what: string) => {
    await step(`${what}: zh`, () => s.call("get", "zh"));
    await step(`${what}: en`, () => s.call("get", "en"));
  };
  out.push({
    name: "updates: what the pages show, read",
    world: () => stationWorld(),
    run: async (s, step) => {
      await step("made", () => s.updates(OPTS), true);
      await pages(s, step, "before a reading");
      await step("read", () => s.call("check"), true);
      await pages(s, step, "read");
      await step("read again (the runtimes)", () => s.call("check", false), true);
      await step("as if 0.1.9 were out", () => s.call("stationWith", "0.1.9", "en"));
      for (const m of ["channel", "auto", "installed", "toUpdateTo", "tried"]) await step(m, () => s.call(m));
      await step("closed", () => s.call("close"));
      await step("refused once closed", () => s.call("update", "claude", "en"));
    },
  });
  out.push({
    name: "updates: a station of tasks only, not installed by the installer",
    world: () => stationWorld({ app: "/elsewhere.app/Contents/app" }),
    run: async (s, step) => {
      await step("made", () => s.updates({ ...OPTS, app: "/elsewhere.app/Contents/app", stationOnly: true, origin: null }), true);
      await step("read", () => s.call("check"), true);
      await pages(s, step, "read");
      await step("not updated here", () => s.call("update", "station", "en"));
      await step("not set to update itself", () => s.call("setAuto", true, "zh"));
      await step("nor put on a channel", () => s.call("setChannel", "beta", "en"));
      await step("closed", () => s.call("close"));
    },
  });
  const followSteps = async (s: Side, step: StepFn, w: World, end: "0" | "1" | null, build = "6\n") => {
    w.vfs.file("/st/run/update.step", "download\n").file("/st/run/update.log", "#####       42.0%");
    await step("downloading", async () => (await s.watch("/st/run", "update.step"), await s.advance(50)), true);
    await pages(s, step, "downloading");
    w.vfs.file("/st/run/update.step", "drain\n");
    await step("draining", async () => (await s.set({ running: 2 }), await s.watch("/st/run", null), await s.advance(50)), true);
    await pages(s, step, "draining");
    await step("a turn ended", async () => (await s.set({ running: 1 }), await s.advance(5000)), true);
    await pages(s, step, "a turn ended");
    if (end === null) return;
    if (end === "0") w.vfs.file("/st/app/BUILD", build);
    else w.vfs.file("/st/run/update.log", "unpacking\nError: the archive is not the one signed\n");
    w.vfs.file("/st/run/update.exit", `${end}\n`);
    await step("ended", async () => (await s.watch("/st/run", "update.exit"), await s.advance(50)), true);
    await pages(s, step, "ended");
  };
  out.push({
    name: "updates: updating itself, followed to its end",
    world: () => stationWorld(),
    run: async (s, step, w) => {
      await step("made", () => s.updates({ ...OPTS, config: { autoUpdate: true } }), true);
      await step("started", () => s.call("start"), true);
      await step("its first look", async () => s.advance(0), true);
      await pages(s, step, "installer started");
      await followSteps(s, step, w, "0");
      await step("done shown a while", async () => s.advance(600_000), true);
      await pages(s, step, "later");
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: a failed update tried once more",
    world: () => stationWorld(),
    run: async (s, step, w) => {
      await step("made", () => s.updates({ ...OPTS, config: { autoUpdate: true } }), true);
      await step("started", () => s.call("start"), true);
      await step("its first look", async () => s.advance(0), true);
      await followSteps(s, step, w, "1");
      w.route("https://o/releases/station.json", { status: 503, body: "" });
      for (const f of ["update.exit", "update.log", "update.step"]) w.vfs.remove(`/st/run/${f}`);
      await step("tried again after a minute: the feed not read", async () => s.advance(60_000), true);
      await pages(s, step, "not read");
      w.route("https://o/releases/station.json", { body: JSON.stringify(feedOf(6)) });
      await step("backed off", async () => s.advance(120_000), true);
      await pages(s, step, "the retry");
      await followSteps(s, step, w, "1");
      await step("not again", async () => s.advance(1_000_000), true);
      await step("tried", () => s.call("tried"));
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: asked from a page, with a delta, past its time",
    world: () => {
      const w = stationWorld({ feed: withDeltas(feedOf(6, rawBuild), [{ from: 5, file: "station/5-6.delta", sha256: deltaSha, size: stationDelta.length }]) });
      w.route("https://o/releases/station/5-6.delta", { headers: { "content-length": String(stationDelta.length) }, chunks: [stationDelta.subarray(0, 300), stationDelta.subarray(300)] });
      w.proc((_p, a) => {
        if (!a.includes("--apply-delta") && a[1] !== "apply") return null;
        const out = a[a.indexOf("--out") + 1]!;
        w.vfs.write(out, raw);
        return [["close", 0]];
      });
      return w;
    },
    run: async (s, step, w) => {
      await step("made", () => s.updates(OPTS), true);
      await step("read", () => s.call("check"), true);
      await step("asked", () => s.call("update", "station", "en"), true);
      await pages(s, step, "its delta taken");
      await step("asked again", () => s.call("update", "station", "zh"));
      await step("a runtime meanwhile", () => s.call("update", "claude", "en"));
      await followSteps(s, step, w, null);
      await step("past its time", async () => s.advance(20 * 60_000), true);
      await pages(s, step, "timed out");
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: the installer not started, the feed refused",
    world: () => stationWorld({ feed: feedOf(6, {}, OTHER) }),
    run: async (s, step, w) => {
      await step("made", () => s.updates(OPTS), true);
      await step("read", () => s.call("check"), true);
      await pages(s, step, "not verified");
      await step("asked", () => s.call("update", "station", "zh"), true);
      w.route("https://o/releases/station.json", { body: JSON.stringify(feedOf(6)) });
      w.is("platform.startInstaller", false);
      await step("not started", () => s.call("update", "station", "en"), true);
      await pages(s, step, "not started");
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: the installer not started here, the launcher starts it",
    world: () => {
      const w = stationWorld({ feed: feedOf(6, {}, OTHER) });
      for (const lang of ["zh", "en"]) w.vfs.file(`/st/app/bin/install.${lang}.sh`, "#!/bin/sh\necho installing\n", 0o755);
      return w;
    },
    run: async (s, step, w) => {
      await step("made", () => s.updates({ ...OPTS, launcherInstaller: true }), true);
      await step("read", () => s.call("check"), true);
      await step("asked", () => s.call("update", "station", "zh"), true);
      w.route("https://o/releases/station.json", { body: JSON.stringify(feedOf(6)) });
      w.is("platform.startInstaller", false);
      await step("started by the launcher", () => s.call("update", "station", "en"), true);
      await pages(s, step, "started by the launcher");
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: gone back to a release before, updating by itself held until a newer one",
    world: () => {
      const w = stationWorld({ feed: withEarlier(feedOf(6), [feedOf(5), feedOf(4, built4), feedOf(3, {}, OTHER)]) });
      w.route(`https://o/releases/station/archive/stable/4-${built4.sha256}-${PLATFORM}.tar.gz`, { headers: { "content-length": String(archive4.length) }, chunks: [archive4.subarray(0, 10), archive4.subarray(10)] });
      return w;
    },
    run: async (s, step, w) => {
      await step("made", () => s.updates(OPTS), true);
      await step("read", () => s.call("check"), true);
      await pages(s, step, "what it can go back to");
      await step("refused: not named", () => s.call("update", "station", "zh", "0.1.3"));
      await step("refused: not older", () => s.call("update", "station", "en", "0.1.5"));
      await step("refused: a runtime", () => s.call("update", "claude", "zh", "0.1.4"));
      await step("updating by itself on", () => s.call("setAuto", true, "zh"), true);
      await step("asked", () => s.call("update", "station", "en", "0.1.4"), true);
      await pages(s, step, "gone back");
      for (const m of ["auto", "autoAfter", "toUpdateTo", "tried"]) await step(m, () => s.call(m));
      await followSteps(s, step, w, "0", "4\n");
      await step("as if 0.1.5 were out", () => s.call("stationWith", "0.1.5", "zh"));
      await step("not past the release left", () => s.call("resumeAutoForTests"), true);
      await step("as if 0.1.7 were out", () => s.call("stationWith", "0.1.7", "zh"));
      await step("past it", () => s.call("resumeAutoForTests"), true);
      for (const m of ["auto", "autoAfter", "toUpdateTo"]) await step(m, () => s.call(m));
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: going back, its archive not the one signed",
    world: () => {
      const w = stationWorld({ feed: withEarlier(feedOf(6), [feedOf(4, built4)]) });
      w.route(`https://o/releases/station/archive/stable/4-${built4.sha256}-${PLATFORM}.tar.gz`, { body: Buffer.from("something else entirely") });
      return w;
    },
    run: async (s, step) => {
      await step("made", () => s.updates({ ...OPTS, config: { autoUpdate: false } }), true);
      await step("read", () => s.call("check"), true);
      await step("asked", () => s.call("update", "station", "zh", "0.1.4"), true);
      await pages(s, step, "not gone back");
      await step("set to update itself, nothing kept of before", () => s.call("setAuto", false, "en"), true);
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: the runtimes updated and installed",
    world: () => {
      const w = stationWorld({ claude: true });
      w.vfs.dir("/tmp");
      return w;
    },
    run: async (s, step, w) => {
      await step("made", () => s.updates(OPTS), true);
      await step("read", () => s.call("check"), true);
      await step("Claude Code by Homebrew", () => s.call("update", "claude", "en"), true);
      await pages(s, step, "Claude Code");
      await step("Codex by npm, its build fetched first", () => s.call("update", "codex", "zh"), true);
      await pages(s, step, "Codex");
      await step("DeepSeek Harness installed, linked beside npm", () => s.call("update", "dsh", "en"), true);
      await pages(s, step, "dsh");
      await step("Grok Build refused by npm", () => s.call("update", "grok", "en"), true);
      await step("Devin installed, not the latest", () => s.call("update", "devin", "en"), true);
      await pages(s, step, "all");
      await step("Hermes, not here", () => s.call("update", "hermes", "en"));
      await step("no such", () => s.call("update", "nope", "zh"));
      await step("Cursor's SDK", () => s.call("update", "cursor", "en"), true);
      void w;
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: a Node installed for npm, a runtime that hangs",
    world: () => {
      const w = stationWorld();
      w.state.noNpm = true;
      const archive = Buffer.from("node's archive");
      w.route("https://nodejs/v24.1.0/SHASUMS256.txt", { body: `${SHA_A}  node-v24.1.0-linux-x64.tar.gz\n${shaHex(archive)}  node-v24.1.0-darwin-arm64.tar.gz\n` });
      w.route("https://nodejs/v24.1.0/node-v24.1.0-darwin-arm64.tar.gz", { body: archive });
      w.proc((p, a) => {
        if (p === "tar") {
          w.vfs.file(`${a[3]}/node-v24.1.0-darwin-arm64/bin/npm`, "npm", 0o755);
          return [["close", 0]];
        }
        if (p.endsWith("/bin/npm") && a.includes("@deepseek-ai/dsh@latest")) return [["stdout", "installing\n"], ["hang"]];
        return null;
      });
      return w;
    },
    run: async (s, step) => {
      await step("made", () => s.updates(OPTS), true);
      await step("read", () => s.call("check"), true);
      await pages(s, step, "read");
      await step("DeepSeek Harness on the station's own Node", () => s.call("update", "dsh", "en"), true);
      await pages(s, step, "installing");
      await step("its deadline", async () => s.fireWall(), true);
      await pages(s, step, "timed out");
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: settings, refusals, the channel asked",
    world: () => {
      const w = stationWorld();
      w.vfs.file("/st/run/channel-ask", "beta\n");
      return w;
    },
    run: async (s, step, w) => {
      await step("made", () => s.updates(OPTS), true);
      await step("started", () => s.call("start"), true);
      await step("its first look", async () => s.advance(0), true);
      await step("on by itself", () => s.call("setAuto", true, "en"), true);
      await step("held back", async () => s.hold("vault"), true);
      await step("not while held", () => s.call("toUpdateTo"));
      await step("let go: it goes", async () => s.letGo("vault"), true);
      await pages(s, step, "updating");
      await step("refused while it updates", () => s.call("update", "codex", "en"));
      await step("refused: Codex not installed", () => s.call("update", "station", "en"));
      w.vfs.file("/st/run/update.exit", "0\n");
      await step("ended", async () => (await s.watch("/st/run", "update.exit"), await s.advance(50)), true);
      await step("off", () => s.call("setAuto", false, "zh"), true);
      await step("on beta", () => s.call("setChannel", "beta", "zh"), true);
      await pages(s, step, "beta");
      await step("kept beta", () => s.call("keepChannel", "beta"), true);
      await step("edited elsewhere", async () => s.configSet({ updateChannel: "stable" }), true);
      await step("asked by the command", () => s.call("answerChannelAsk"), true);
      await step("asked with nothing asked", () => s.call("answerChannelAsk"), true);
      await pages(s, step, "asked");
      await step("a runtime updating", () => s.call("poke", "claude", { updating: 5 }));
      await step("refused: a runtime updates", () => s.call("update", "station", "zh"));
      await step("refused: already", () => s.call("update", "claude", "en"));
      await step("a while on", async () => s.advance(6 * 3_600_000), true);
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: an update started before this process, one long gone",
    world: () => {
      const w = stationWorld();
      w.vfs.file("/st/run/update.started", JSON.stringify({ at: 1_800_000_000_000 - 1000, from: "0.1.5" })).file("/st/run/update.step", "handoff\n");
      return w;
    },
    run: async (s, step, w) => {
      await step("made", () => s.updates(OPTS), true);
      await step("started: it follows", () => s.call("start"), true);
      await pages(s, step, "followed");
      w.vfs.file("/st/app/BUILD", "6\n").file("/st/run/update.exit", "0\n");
      await step("the slow look", async () => s.advance(5000), true);
      await pages(s, step, "handed over");
      w.vfs.file("/st/run/update.started", JSON.stringify({ at: 1_800_000_000_000 - 30 * 60_000, from: "0.1.5" }));
      await step("one long gone", () => s.call("followStarted"), true);
      w.vfs.file("/st/run/update.started", "{nope");
      await step("not JSON", () => s.call("followStarted"), true);
      w.vfs.file("/st/run/update.started", JSON.stringify({ at: "x" }));
      await step("no time", () => s.call("followStarted"), true);
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: Codex too old for the app-server, a runtime gone",
    world: () => stationWorld(),
    run: async (s, step, w) => {
      await step("made", () => s.updates(OPTS), true);
      await step("read", () => s.call("check"), true);
      await step("newer than installed", () => s.call("updateOldCodex", "0.48.0", "en"), true);
      await step("updated for it", () => s.call("updateOldCodex", "0.46.0", "en"), true);
      await pages(s, step, "updated");
      await step("no newer", () => s.call("updateOldCodex", "0.47.0", "zh"), true);
      (w as StationWorld).state.claude = null;
      await step("Claude Code gone", () => s.call("missing", "claude"), true);
      await pages(s, step, "gone");
      await step("not repairable", () => s.call("repairCodex", "en"), true);
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: an incomplete Codex repaired",
    world: () => {
      const w = stationWorld({ codex: "standalone" });
      const rel = "/home/u/.codex/packages/standalone/releases/0.46.0/bin";
      w.vfs.file(`${rel}/codex`, MACH, 0o755).link("/home/u/.local/bin/codex", `${rel}/codex`);
      w.proc((p, a) => {
        if (a[0] === "features") return [["stdout", "code_mode_host  stable  true\n"], ["close", 0]];
        if (p.endsWith("npm") && a.includes("--prefix") && a.includes("@openai/codex@0.47.0")) {
          const prefix = a[a.indexOf("--prefix") + 1]!;
          const pkg = `${prefix}/lib/node_modules/@openai`;
          w.vfs.file(`${pkg}/codex/bin/codex.js`, "#!/usr/bin/env node\n", 0o755).link(`${prefix}/bin/codex`, `${pkg}/codex/bin/codex.js`);
          w.vfs.file(`${pkg}/codex-darwin-arm64/package.json`, "{}").file(`${pkg}/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`, MACH, 0o755).file(`${pkg}/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex-code-mode-host`, MACH, 0o755);
          return [["stdout", "added 1 package\n"], ["close", 0]];
        }
        if (p.includes("/st/runtimes/codex/") && a[0] === "--version") return [["stdout", "codex-cli 0.47.0\n"], ["close", 0]];
        if (p.endsWith("codex-code-mode-host")) return [["close", 0]];
        return null;
      });
      return w;
    },
    run: async (s, step) => {
      await step("made", () => s.updates(OPTS), true);
      await step("read", () => s.call("check"), true);
      await pages(s, step, "missing its host");
      await step("repaired", () => s.call("repairCodex", "en"), true);
      await pages(s, step, "repaired");
      await step("closed", () => s.call("close"));
    },
  });
  out.push({
    name: "updates: Claude Code's and the Antigravity CLI's own installers, their downloads looked at",
    world: () => {
      const w = stationWorld({ claude: false });
      w.route("https://claude-rel/latest", { body: "2.1.300\n" });
      w.route("https://claude-rel/2.1.300/manifest.json", { body: JSON.stringify({ platforms: { "darwin-arm64": { size: 2_000_000 } } }) });
      w.route("https://claude-rel/2.1.300/manifest.zst.json", { status: 404, body: "" });
      w.route("https://agy/darwin-arm64.json", { body: JSON.stringify({ version: "1.4.0", url: "https://dl/agy.tgz" }) });
      w.route("HEAD https://dl/agy.tgz", { headers: { "content-length": "4000000" } });
      w.is("platform.agyBuild", "darwin-arm64").is("platform.agyStaging", "/tmp/agy.bin");
      w.proc((p, a) => (p === "/bin/sh" && /claude\.ai|antigravity/.test(a.join(" ")) ? [["stdout", "Downloading\n"], ["hang"]] : null));
      return w;
    },
    run: async (s, step, w) => {
      await step("made", () => s.updates(OPTS), true);
      await step("read", () => s.call("check"), true);
      await step("Claude Code installed by its own installer", () => s.call("update", "claude", "en"), true);
      w.vfs.file("/home/u/.claude/downloads/claude-2.1.300-darwin-arm64", Buffer.alloc(500_000));
      await step("a quarter in", async () => s.advance(500), true);
      await pages(s, step, "a quarter");
      w.vfs.file("/home/u/.claude/downloads/claude-2.1.300-darwin-arm64.zst", Buffer.alloc(10));
      await step("its zstd one, of no known size", async () => s.advance(500), true);
      await pages(s, step, "zstd");
      await step("its deadline", async () => s.fireWall(), true);
      await pages(s, step, "timed out");
      await step("the Antigravity CLI by its own", () => s.call("update", "agy", "zh"), true);
      w.vfs.file("/tmp/agy.bin", Buffer.alloc(1_000_000));
      await step("some in", async () => s.advance(500), true);
      await pages(s, step, "some");
      w.vfs.file("/tmp/agy.bin", Buffer.alloc(4_000_000));
      await step("all in", async () => s.advance(500), true);
      await pages(s, step, "all");
      await step("its deadline", async () => s.fireWall(), true);
      await step("closed", () => s.call("close"));
    },
  });
  return out;
}

if (!process.execArgv.includes("--experimental-test-module-mocks")) {
  const skip = mbHarnessBinary() === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;
  test("the MoonBit updates answer as the TypeScript ones (run with module mocks)", { skip }, async () => {
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT;
    const run = spawnSync(process.execPath, ["--experimental-test-module-mocks", "--no-warnings", "--import", join(station, "test/setup-env.mjs"), self], {
      cwd: station,
      env,
      encoding: "utf8",
      maxBuffer: 256 * 1024 * 1024,
    });
    if (run.status !== 0) assert.fail(`${run.stdout}\n${run.stderr}`.split("\n").slice(-400).join("\n"));
  });
} else {
  // (the program gone before this process ends, not only told to: the file's process looks for what it left running)
  try {
    await main();
  } finally {
    await closeProgram();
  }
}

/// The program waited for as it ends.
async function closeProgram(): Promise<void> {
  await program?.close();
}
