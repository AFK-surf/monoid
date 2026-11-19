// The screens and still.fail Helper's parts in MoonBit (station/mb src/screens: reader `--builder harness-screens`)
// held to the TypeScript they are a port of (src/screens/, src/helper/): each scenario is played twice, on two worlds
// made alike, once by the TypeScript and once by the program, and what each answered, what it did in its world (every
// child process started, written to, ended and killed, every connection opened, written to and let go, every timer
// armed and let go, every line logged and every callback told, in order) and the files it left are compared.
// The world is the test's alone (`World`): the clock (ms and process.hrtime's µs), child processes, connections to Unix
// sockets and ports of 127.0.0.1, the files, a folder's watch, random bytes; nothing real runs, waits or is read. What
// the world does (a process's output, a socket's answer, a timer due) is queued and given the side as the scenario
// says, each step played out until neither side nor the world has anything left to do (`settle`). The TypeScript is
// given it through module mocks (node:child_process, node:net, node:fs, node:fs/promises, node:os, node:crypto,
// node:zlib, mesh/lan.ts) and the station's own objects (`wall`, `log`, `platform`, process.hrtime); the program asks
// it of the test over its harness, a JSON line a message (harness_world.mbt says how).
// PNG pictures are compared by their pixels: the program deflates them as MoonBit's zlib does, Node as its own does.
//
// Module mocks need `--experimental-test-module-mocks`: run without it (as `pnpm test` runs a file), this file runs
// itself again with it, and fails as that run fails.
import assert from "node:assert/strict";
import { spawn as realSpawn, spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import * as realFs from "node:fs";
import { existsSync, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { after, mock, test } from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import * as realZlib from "node:zlib";
import { tmpdir as realTmpdir } from "node:os";
import { createHash } from "node:crypto";
import { join } from "node:path";

type Json = any;

// (a local time read, `ps`'s, is read in UTC by both: the program's machine has no zone of its own in this world)
process.env.TZ = "UTC";

const station = fileURLToPath(new URL("..", import.meta.url));
const self = fileURLToPath(import.meta.url);
const ROOT = join(station, "..");
const ZH = JSON.parse(readFileSync(join(ROOT, "client/i18n/catalog/zh/station.json"), "utf8"));
const EN = JSON.parse(readFileSync(join(ROOT, "client/i18n/catalog/en/station.json"), "utf8"));
const SCREENS_DIR = join(station, "src/screens");

function readerBinary(): string | null {
  const candidates = [process.env.STILLFAIL_MB_READER, join(station, "mb/_build/stillfail-reader-darwin-arm64"), join(station, "mb/_build/stillfail-reader-linux-x64"), join(station, "mb/_build/stillfail-reader-linux-arm64")];
  return candidates.find((p) => p !== undefined && p !== "" && existsSync(p)) ?? null;
}

const b64 = (b: Uint8Array | Buffer) => Buffer.from(b).toString("base64");
const unb64 = (s: string) => Buffer.from(s, "base64");

// ---------------------------------------------------------------------------------------------------------------
// The world

/// What a child process is in the world, and what the scenario makes of it.
class WChild {
  readonly world: World;
  readonly deliver: (ev: Json) => void;
  readonly id: number;
  readonly file: string;
  readonly args: string[];
  readonly env: Json;
  readonly group: boolean;
  closed = false;
  stdin: Buffer[] = [];
  ended = false;
  onWrite: (data: Buffer) => void = () => {};
  onEnd: () => void = () => {};
  onKill: (signal: string) => void = () => {};
  constructor(world: World, id: number, file: string, args: string[], env: Json, group: boolean, deliver: (ev: Json) => void) {
    this.world = world;
    this.deliver = deliver;
    this.id = id;
    this.file = file;
    this.args = args;
    this.env = env;
    this.group = group;
  }
  out(data: string | Buffer) { this.world.post(() => !this.closed && this.deliver({ kind: "out", data: b64(Buffer.from(data)) })); }
  err(data: string | Buffer) { this.world.post(() => !this.closed && this.deliver({ kind: "err", data: b64(Buffer.from(data)) })); }
  error(message: string, started = false) { this.world.post(() => !this.closed && this.deliver({ kind: "error", message, started })); }
  close(code: number | null, signal: string | null = null) {
    this.world.post(() => {
      if (this.closed) return;
      this.closed = true;
      this.deliver({ kind: "close", code, signal });
    });
  }
  /// A program that says `out` and ends with `code`.
  says(out: string | Buffer, code = 0, err = "") {
    if (out.length > 0) this.out(out);
    if (err !== "") this.err(err);
    this.close(code);
  }
}

/// A connection in the world, from the side's end (`deliver`) to the server's (`onData`, `send`, `close`).
class WConn {
  closed = false;
  onData: (data: Buffer) => void = () => {};
  onEnd: () => void = () => {};
  onGone: () => void = () => {};
  readonly world: World;
  readonly id: number;
  readonly target: Json;
  readonly deliver: (ev: Json) => void;
  constructor(world: World, id: number, target: Json, deliver: (ev: Json) => void) {
    this.world = world;
    this.id = id;
    this.target = target;
    this.deliver = deliver;
  }
  open() { this.world.post(() => !this.closed && this.deliver({ kind: "connect" })); }
  send(data: string | Buffer) { this.world.post(() => !this.closed && this.deliver({ kind: "data", data: b64(Buffer.from(data)) })); }
  fail(message: string) { this.world.post(() => !this.closed && this.deliver({ kind: "error", message })); }
  close() {
    this.world.post(() => {
      if (this.closed) return;
      this.closed = true;
      this.deliver({ kind: "close" });
    });
  }
}

type FsNode = { kind: "dir" } | { kind: "file"; data: Buffer; mode: number | null; mtime: number } | { kind: "link"; to: string };
type ExecRule = (file: string, args: string[], opts: Json) => { stdout?: string; error?: Json } | "pending" | undefined;

/// A message of still.fail Helper's view wire: a kind byte, the payload's length, the payload.
export function hm(kind: number, payload: Buffer | string = Buffer.alloc(0)): Buffer {
  const body = Buffer.from(payload);
  const head = Buffer.alloc(5);
  head[0] = kind;
  head.writeUInt32BE(body.length, 1);
  return Buffer.concat([head, body]);
}

class World {
  now = 1_800_000_000_000;
  us = 5_000_000;
  readonly trace: Json[] = [];
  readonly queue: (() => void)[] = [];
  readonly timers = new Map<number, { at: number; fire: () => void }>();
  readonly fs = new Map<string, FsNode>();
  readonly children: WChild[] = [];
  readonly conns: WConn[] = [];
  readonly watches = new Map<number, { dir: string; deliver: (ev: Json) => void }>();
  readonly servers = new Map<string, (conn: WConn) => void>();
  readonly spawnRules: ((child: WChild) => boolean | void)[] = [];
  readonly execRules: ExecRule[] = [];
  mounts: string[] = [];
  reach: string | null = null;
  random = 0;
  #next = 0;

  id() { return ++this.#next; }
  post(f: () => void) { this.queue.push(f); }
  note(entry: Json) { this.trace.push(entry); }

  // the clock
  arm(ms: number, fire: () => void): number {
    const id = this.id();
    this.timers.set(id, { at: this.now + Math.max(0, ms), fire });
    this.note({ t: "after", timer: id, ms });
    return id;
  }
  cancel(id: number) {
    if (!this.timers.delete(id)) return;
    this.note({ t: "cancel", timer: id });
  }
  /// The clock moved on `ms`, each timer due fired in its turn (the next only once what it set going is done: `settle`).
  async advance(ms: number, settle: () => Promise<void>) {
    const until = this.now + ms;
    for (;;) {
      let next: [number, { at: number; fire: () => void }] | undefined;
      for (const e of this.timers) if (e[1].at <= until && (next === undefined || e[1].at < next[1].at)) next = e;
      if (next === undefined) break;
      this.now = Math.max(this.now, next[1].at);
      this.us += 1000;
      this.timers.delete(next[0]);
      this.note({ t: "fire", timer: next[0] });
      next[1].fire();
      await settle();
    }
    this.now = until;
  }

  // child processes
  spawned(file: string, args: string[], env: Json, group: boolean, stdio: string[], verbatim: boolean, deliver: (ev: Json) => void): WChild {
    const child = new WChild(this, this.id(), file, args, env, group, deliver);
    this.children.push(child);
    this.note({ t: "spawn", child: child.id, file, args: [...args], env: env === undefined || env === null ? null : JSON.parse(JSON.stringify(env)), group, stdio, verbatim });
    for (const rule of this.spawnRules) if (rule(child) === true) break;
    return child;
  }
  exec(file: string, args: string[], opts: Json, answer: (r: { stdout?: string; error?: Json }) => void) {
    // (its environment as it was given: the caller may change its object after)
    this.note({ t: "exec", file, args: [...args], env: opts?.env ? JSON.parse(JSON.stringify(opts.env)) : null, timeout: opts?.timeout ?? null, maxBuffer: opts?.maxBuffer ?? null });
    for (const rule of this.execRules) {
      const r = rule(file, args, opts);
      if (r === "pending") return;
      if (r !== undefined) return this.post(() => answer(r));
    }
    this.post(() => answer({ error: { message: `spawn ${file} ENOENT`, code: "ENOENT", signal: null, stdout: "", stderr: "" } }));
  }

  // connections
  connected(target: Json, deliver: (ev: Json) => void): WConn {
    const conn = new WConn(this, this.id(), target, deliver);
    this.conns.push(conn);
    this.note({ t: "conn", conn: conn.id, ...target });
    const key = target.unix ?? `tcp:${target.port}`;
    const server = this.servers.get(key);
    if (server === undefined) {
      conn.fail(target.unix ? `connect ENOENT ${target.unix}` : `connect ECONNREFUSED 127.0.0.1:${target.port}`);
      conn.close();
    } else {
      conn.open();
      server(conn);
    }
    return conn;
  }

  // files
  dir(path: string) {
    const parts = path.split("/").filter(Boolean);
    for (let i = 0; i <= parts.length; i++) {
      const p = `/${parts.slice(0, i).join("/")}`;
      if (!this.fs.has(p)) this.fs.set(p, { kind: "dir" });
    }
  }
  file(path: string, data: string | Buffer, mode: number | null = null) {
    this.dir(path.slice(0, path.lastIndexOf("/")) || "/");
    this.fs.set(path, { kind: "file", data: Buffer.from(data), mode, mtime: this.now });
  }
  /// The files as they are: every path, its kind and bytes (what both sides left).
  files(): Json {
    const out: Json = {};
    for (const [p, n] of [...this.fs].sort(([a], [b]) => (a < b ? -1 : 1))) out[p] = n.kind === "file" ? { data: b64(n.data), mode: n.mode } : n.kind === "link" ? { link: n.to } : null;
    return out;
  }
  /// The files as the program reads them before it serves (node:fs's sync calls).
  snapshot(): Json {
    const out: Json = {};
    for (const [p, n] of this.fs) out[p] = n.kind === "file" ? b64(n.data) : null;
    return out;
  }
  fsError(code: string, op: string, path: string, dest?: string): Json {
    const words: Record<string, string> = { ENOENT: "no such file or directory", EEXIST: "file already exists", ENOTDIR: "not a directory", EISDIR: "illegal operation on a directory", ENOTEMPTY: "directory not empty", EACCES: "permission denied" };
    return { kind: "FsFailed", code, message: `${code}: ${words[code] ?? code}, ${op} '${path}'${dest ? ` -> '${dest}'` : ""}` };
  }
  parentOk(path: string): boolean {
    const parent = path.slice(0, path.lastIndexOf("/")) || "/";
    return this.fs.get(parent)?.kind === "dir";
  }
  /// One file operation as fs/promises does it: its answer, or its failure (`FsFailed`).
  fsOp(op: string, a: Json): Json {
    const node = (p: string) => this.fs.get(p);
    const fail = (code: string, path = a.path, dest?: string) => { throw this.fsError(code, op === "readAt" ? "read" : op, path, dest); };
    switch (op) {
      case "read": {
        const n = node(a.path);
        if (n === undefined) fail("ENOENT", a.path, undefined);
        if (n!.kind !== "file") fail("EISDIR");
        return b64((n as { data: Buffer }).data);
      }
      case "write": {
        if (!this.parentOk(a.path)) fail("ENOENT", a.path, undefined);
        if (node(a.path)?.kind === "dir") fail("EISDIR");
        this.fs.set(a.path, { kind: "file", data: unb64(a.data), mode: a.mode ?? null, mtime: this.now });
        return null;
      }
      case "access": {
        const n = node(a.path);
        if (n === undefined) fail("ENOENT");
        if (a.mode === 1 && (n!.kind !== "file" || !(((n as { mode: number | null }).mode ?? 0o644) & 0o111))) fail("EACCES");
        return true;
      }
      case "readdir": {
        const n = node(a.path);
        if (n === undefined) fail("ENOENT", a.path, undefined);
        if (n!.kind !== "dir") fail("ENOTDIR");
        const prefix = a.path === "/" ? "/" : `${a.path}/`;
        const names: Json[] = [];
        for (const [p, m] of this.fs) if (p.startsWith(prefix) && p !== a.path && !p.slice(prefix.length).includes("/")) names.push({ name: p.slice(prefix.length), dir: m.kind === "dir" });
        return names;
      }
      case "mkdir": {
        if (node(a.path)?.kind === "dir") {
          if (a.recursive) return null;
          fail("EEXIST");
        }
        if (node(a.path) !== undefined) fail("EEXIST");
        if (!a.recursive && !this.parentOk(a.path)) fail("ENOENT");
        this.dir(a.path);
        return null;
      }
      case "mkdtemp": {
        const path = `${a.prefix}${String(this.id()).padStart(6, "0")}`;
        if (!this.parentOk(path)) fail("ENOENT", `${a.prefix}XXXXXX`);
        this.fs.set(path, { kind: "dir" });
        return path;
      }
      case "rename": {
        if (node(a.from) === undefined) fail("ENOENT", a.from, a.to);
        if (!this.parentOk(a.to)) fail("ENOENT", a.from, a.to);
        const moved = [...this.fs].filter(([p]) => p === a.from || p.startsWith(`${a.from}/`));
        for (const [p] of [...this.fs]) if (p === a.to || p.startsWith(`${a.to}/`)) this.fs.delete(p);
        for (const [p] of moved) this.fs.delete(p);
        for (const [p, n] of moved) this.fs.set(a.to + p.slice(a.from.length), n);
        return null;
      }
      case "rm": {
        const n = node(a.path);
        if (n === undefined) { if (a.force) return null; fail("ENOENT"); }
        if (n!.kind === "dir" && !a.recursive) fail("EISDIR");
        for (const [p] of [...this.fs]) if (p === a.path || p.startsWith(`${a.path}/`)) this.fs.delete(p);
        return null;
      }
      case "unlink": {
        const n = node(a.path);
        if (n === undefined) fail("ENOENT");
        if (n!.kind === "dir") fail("EISDIR");
        this.fs.delete(a.path);
        return null;
      }
      case "stat":
      case "lstat": {
        let n = node(a.path);
        if (n === undefined) fail("ENOENT");
        const link = n!.kind === "link";
        if (op === "stat" && link) {
          n = node((n as { to: string }).to);
          if (n === undefined) fail("ENOENT");
        }
        return { dir: n!.kind === "dir", file: n!.kind === "file", link: op === "lstat" && link, size: n!.kind === "file" ? n!.data.length : 0, mtimeMs: n!.kind === "file" ? n!.mtime : 0 };
      }
      case "copyTree": {
        if (node(a.from) === undefined) fail("ENOENT", a.from, a.to);
        for (const [p, n] of [...this.fs]) if (p === a.from || p.startsWith(`${a.from}/`)) this.fs.set(a.to + p.slice(a.from.length), n.kind === "file" ? { ...n } : n);
        return null;
      }
      case "readAt": {
        const n = node(a.path);
        if (n === undefined) fail("ENOENT");
        const data = (n as { data: Buffer }).data;
        return b64(data.subarray(Math.min(a.offset, data.length), Math.min(a.offset + a.length, data.length)));
      }
      case "writeAt": {
        const n = node(a.path) as { kind: "file"; data: Buffer; mode: number | null; mtime: number } | undefined;
        if (n === undefined) fail("ENOENT");
        const add = unb64(a.data);
        const end = Math.max(n!.data.length, a.offset + add.length);
        const out = Buffer.alloc(end);
        n!.data.copy(out);
        add.copy(out, a.offset);
        n!.data = out;
        return null;
      }
      case "create": {
        if (node(a.path) !== undefined) fail("EEXIST", a.path);
        if (!this.parentOk(a.path)) fail("ENOENT", a.path);
        this.fs.set(a.path, { kind: "file", data: Buffer.alloc(0), mode: null, mtime: this.now });
        return null;
      }
      case "append": {
        const n = node(a.path) as { kind: "file"; data: Buffer } | undefined;
        if (n === undefined) fail("ENOENT");
        n!.data = Buffer.concat([n!.data, unb64(a.data)]);
        return null;
      }
    }
    throw new Error(`no fs op ${op}`);
  }

  /// A file operation as fs/promises fails one: an Error with its code.
  fsOpThrows(op: string, a: Json): Json {
    try {
      return this.fsOp(op, a);
    } catch (e) {
      const f = e as Json;
      if (f?.kind === "FsFailed") throw Object.assign(new Error(f.message), { code: f.code });
      throw e;
    }
  }

  // what is random: the same bytes for both
  randomBytes(n: number): Buffer {
    const out = Buffer.alloc(n);
    for (let i = 0; i < n; i++) out[i] = (++this.random * 29 + 7) & 0xff;
    return out;
  }
  randomInt(lo: number, hi: number): number {
    this.random++;
    return lo + ((this.random * 7919) % (hi - lo));
  }

  // a folder's change
  watchChanged(dir: string, name: string | null) {
    for (const [, w] of this.watches) if (w.dir === dir) this.post(() => w.deliver({ name }));
  }
}

/// What a side (the TypeScript, or the program) is given to play a scenario on: commands, and the world's events.
interface Side {
  readonly world: World;
  /// A command: `pure`, `worldly`, `new`, `call`; its answer once it comes (`done`).
  cmd(cmd: string, j: Json): { done: boolean; ok?: Json; err?: Json; promise: Promise<void> };
  /// Until neither the side nor the world has anything left to do.
  settle(): Promise<void>;
  close(): Promise<void>;
}

// ---------------------------------------------------------------------------------------------------------------
// The TypeScript's side: its world through module mocks

let current: World | null = null;
const world = () => current!;

/// A readable end of a fake child or socket: its 'data' told as Buffers, or strings once an encoding is set.
class FakeReadable extends EventEmitter {
  encoding: BufferEncoding | null = null;
  setEncoding(e: BufferEncoding) { this.encoding = e; return this; }
  push(b: Buffer) { this.emit("data", this.encoding ? b.toString(this.encoding) : b); }
}

/// A child process of the world, as node's ChildProcess is to the station's code.
class FakeChild extends EventEmitter {
  readonly stdout: FakeReadable | null;
  readonly stderr: FakeReadable | null;
  readonly stdin: (EventEmitter & { write(d: Buffer | string, cb?: (e?: Error | null) => void): boolean; end(d?: Buffer | string): void; destroy(): void; destroyed: boolean; writableEnded: boolean }) | null;
  pid: number | undefined;
  exitCode: number | null = null;
  signalCode: string | null = null;
  readonly w: WChild;
  constructor(file: string, args: string[], opts: Json, group: boolean) {
    super();
    const stdio: string[] = Array.isArray(opts?.stdio) ? opts.stdio : ["pipe", "pipe", "pipe"];
    this.stdout = stdio[1] === "pipe" ? new FakeReadable() : null;
    this.stderr = stdio[2] === "pipe" ? new FakeReadable() : null;
    const me = this;
    this.w = world().spawned(file, args, opts?.env ?? null, group, stdio, opts?.windowsVerbatimArguments === true, (ev) => me.#ev(ev));
    this.pid = this.w.id;
    if (stdio[0] === "pipe") {
      const stdin = Object.assign(new EventEmitter(), {
        destroyed: false,
        writableEnded: false,
        write(d: Buffer | string, cb?: (e?: Error | null) => void) {
          const data = Buffer.from(d);
          world().note({ t: "child.write", child: me.w.id, data: b64(data) });
          me.w.stdin.push(data);
          me.w.onWrite(data);
          if (cb) world().post(() => cb(null));
          return true;
        },
        end(d?: Buffer | string) {
          stdin.writableEnded = true;
          world().note({ t: "child.end", child: me.w.id, ...(d !== undefined ? { data: b64(Buffer.from(d)) } : {}) });
          if (d !== undefined) me.w.onWrite(Buffer.from(d));
          me.w.ended = true;
          me.w.onEnd();
        },
        destroy() {
          stdin.destroyed = true;
          world().note({ t: "child.destroy", child: me.w.id });
          me.w.onEnd();
        },
      });
      this.stdin = stdin;
    } else this.stdin = null;
  }
  #ev(ev: Json) {
    switch (ev.kind) {
      case "out": this.stdout?.push(unb64(ev.data)); return;
      case "err": this.stderr?.push(unb64(ev.data)); return;
      case "error": if (!ev.started) this.pid = undefined; this.emit("error", new Error(ev.message)); return;
      case "close":
        this.exitCode = ev.code;
        this.signalCode = ev.signal;
        this.emit("exit", ev.code, ev.signal);
        this.emit("close", ev.code, ev.signal);
        return;
    }
  }
  kill(signal: string = "SIGTERM") {
    world().note({ t: "child.kill", child: this.w.id, signal, group: false });
    this.w.onKill(signal);
    return true;
  }
}

/// A connection of the world, as node:net's Socket is to the station's code.
class FakeSocket extends EventEmitter {
  destroyed = false;
  #closed = false;
  #paused = false;
  #kept: Buffer[] = [];
  #encoding: BufferEncoding | null = null;
  readonly w: WConn;
  constructor(target: Json) {
    super();
    this.w = world().connected(target, (ev) => this.#ev(ev));
    this.on("newListener", (event) => {
      if (event === "data") queueMicrotask(() => this.#flow());
    });
  }
  #ev(ev: Json) {
    switch (ev.kind) {
      case "connect": this.emit("connect"); return;
      case "data": {
        if (this.destroyed) return;
        const b = unb64(ev.data);
        if (this.#paused || this.listenerCount("data") === 0) this.#kept.push(b);
        else this.emit("data", this.#encoding ? b.toString(this.#encoding) : b);
        return;
      }
      case "error": this.emit("error", Object.assign(new Error(ev.message), { code: ev.message.split(" ")[1] })); return;
      case "close":
        this.#closed = true;
        this.destroyed = true;
        this.emit("close", false);
        return;
    }
  }
  #flow() {
    while (!this.#paused && !this.destroyed && this.listenerCount("data") > 0 && this.#kept.length > 0) {
      const b = this.#kept.shift()!;
      this.emit("data", this.#encoding ? b.toString(this.#encoding) : b);
    }
  }
  setEncoding(e: BufferEncoding) { this.#encoding = e; return this; }
  pause() { this.#paused = true; return this; }
  resume() { this.#paused = false; queueMicrotask(() => this.#flow()); return this; }
  write(d: Buffer | string) {
    if (this.destroyed) return false;
    world().note({ t: "conn.write", conn: this.w.id, data: b64(Buffer.from(d)) });
    this.w.onData(Buffer.from(d));
    return true;
  }
  end() { world().note({ t: "conn.end", conn: this.w.id }); this.w.onEnd(); return this; }
  destroy() {
    if (this.destroyed || this.#closed) return this;
    this.destroyed = true;
    world().note({ t: "conn.destroy", conn: this.w.id });
    this.w.onGone();
    this.w.close();
    return this;
  }
}

function fakeExecFile(file: string, args: string[], opts: Json, cb?: (e: Error | null, out: string, err: string) => void) {
  if (typeof opts === "function") { cb = opts; opts = {}; }
  world().exec(file, args ?? [], opts ?? {}, (r) => {
    if (r.error) {
      const e = Object.assign(new Error(r.error.message), { code: r.error.code, signal: r.error.signal ?? null, stdout: r.error.stdout ?? "", stderr: r.error.stderr ?? "" });
      cb?.(e, r.error.stdout ?? "", r.error.stderr ?? "");
    } else cb?.(null, r.stdout ?? "", "");
  });
  // (what it returns, nobody here reads: the world's exec is no child of the world's)
  return Object.assign(new EventEmitter(), { kill: () => true });
}
(fakeExecFile as Json)[promisify.custom] = (file: string, args: string[], opts: Json) =>
  new Promise((resolve, reject) => {
    world().exec(file, args ?? [], opts ?? {}, (r) => {
      if (r.error) reject(Object.assign(new Error(r.error.message), { code: r.error.code, signal: r.error.signal ?? null, stdout: r.error.stdout ?? "", stderr: r.error.stderr ?? "" }));
      else resolve({ stdout: r.stdout ?? "", stderr: "" });
    });
  });

const fsp = {
  async readFile(path: string, enc?: Json) {
    const b = unb64(world().fsOpThrows("read", { path }));
    return enc === "utf8" || enc?.encoding === "utf8" ? b.toString("utf8") : b;
  },
  async writeFile(path: string, data: string | Buffer, o?: Json) { world().fsOpThrows("write", { path, data: b64(Buffer.from(data)), mode: o?.mode ?? null }); },
  async access(path: string, mode = 0) { world().fsOpThrows("access", { path, mode }); },
  async readdir(path: string, o?: Json) {
    const entries = world().fsOpThrows("readdir", { path }) as Json[];
    return o?.withFileTypes ? entries.map((e) => ({ name: e.name, isDirectory: () => e.dir })) : entries.map((e) => e.name);
  },
  async mkdir(path: string, o?: Json) { world().fsOpThrows("mkdir", { path, recursive: o?.recursive === true, mode: o?.mode ?? null }); },
  async mkdtemp(prefix: string) { return world().fsOpThrows("mkdtemp", { prefix }); },
  async rename(from: string, to: string) { world().fsOpThrows("rename", { from, to }); },
  async rm(path: string, o?: Json) { world().fsOpThrows("rm", { path, recursive: o?.recursive === true, force: o?.force === true }); },
  async unlink(path: string) { world().fsOpThrows("unlink", { path }); },
  async stat(path: string) { return statObj(world().fsOpThrows("stat", { path })); },
  async lstat(path: string) { return statObj(world().fsOpThrows("lstat", { path })); },
  async cp(from: string, to: string) { world().fsOpThrows("copyTree", { from, to }); },
  async open(path: string, flags: string) {
    if (flags === "wx") world().fsOpThrows("create", { path });
    else world().fsOpThrows("stat", { path });
    return {
      async stat() { return statObj(world().fsOpThrows("stat", { path })); },
      async read(b: Buffer, off: number, len: number, pos: number) {
        const got = unb64(world().fsOpThrows("readAt", { path, offset: pos, length: len }));
        got.copy(b, off);
        return { bytesRead: got.length, buffer: b };
      },
      async write(b: Buffer, off: number, len: number, pos?: number) {
        const data = b.subarray(off, off + len);
        if (pos === undefined) world().fsOpThrows("append", { path, data: b64(data) });
        else world().fsOpThrows("writeAt", { path, offset: pos, data: b64(data) });
        return { bytesWritten: data.length, buffer: b };
      },
      async close() {},
    };
  },
};
const statObj = (s: Json) => ({ isDirectory: () => s.dir, isFile: () => s.file, isSymbolicLink: () => s.link, size: s.size, mtimeMs: s.mtimeMs });


/// A builtin's own exports but `constants` (which a CommonJS consumer's mock cannot define again).
/// The machine's own files as fs/promises takes them, by Node's own (the program's are the shell's: `host_io`).
function nodeFs(ops: Json[]): Json[] {
  const st = (s: realFs.Stats) => ({ dir: s.isDirectory(), file: s.isFile(), link: s.isSymbolicLink(), size: s.isFile() || s.isSymbolicLink() ? s.size : s.isDirectory() ? s.size : 0, mtimeMs: s.mtimeMs });
  return ops.map((o) => {
    try {
      switch (o.op) {
        case "read": return b64(realFs.readFileSync(o.path));
        case "write": realFs.writeFileSync(o.path, unb64(o.data), o.mode ? { mode: o.mode } : {}); return null;
        case "access": try { realFs.accessSync(o.path, o.mode); return true; } catch { return false; }
        case "readdir": return realFs.readdirSync(o.path, { withFileTypes: true }).map((e) => ({ name: e.name, dir: e.isDirectory() }));
        case "mkdir": realFs.mkdirSync(o.path, { recursive: o.recursive === true }); return null;
        case "mkdtemp": { const made = realFs.mkdtempSync(o.prefix); return made.startsWith(o.prefix) && made.length === o.prefix.length + 6; }
        case "rename": realFs.renameSync(o.from, o.to); return null;
        case "rm": realFs.rmSync(o.path, { recursive: o.recursive === true, force: o.force === true }); return null;
        case "unlink": realFs.unlinkSync(o.path); return null;
        case "stat": return st(realFs.statSync(o.path));
        case "lstat": return st(realFs.lstatSync(o.path));
        case "copyTree": realFs.cpSync(o.from, o.to, { recursive: true, verbatimSymlinks: true }); return null;
        case "readAt": { const fd = realFs.openSync(o.path, "r"); const b = Buffer.alloc(o.length); const n = realFs.readSync(fd, b, 0, o.length, o.offset); realFs.closeSync(fd); return b64(b.subarray(0, n)); }
        case "writeAt": { const fd = realFs.openSync(o.path, "r+"); realFs.writeSync(fd, unb64(o.data), 0, unb64(o.data).length, o.offset); realFs.closeSync(fd); return null; }
        case "create": realFs.closeSync(realFs.openSync(o.path, "wx")); return null;
        case "append": realFs.appendFileSync(o.path, unb64(o.data)); return null;
        case "exists": return realFs.existsSync(o.path);
        case "readSync": try { return realFs.readFileSync(o.path, "utf8"); } catch { return null; }
      }
    } catch (e) {
      return { err: (e as Json).code ?? "?" };
    }
    return null;
  });
}

const own = (m: Json) => Object.fromEntries(Object.entries(m).filter(([k]) => k !== "constants" && k !== "default"));

async function installMocks() {
  // (the station's own objects, theirs before what they import is mocked: they are given the world by their methods)
  const { wall } = await import("../src/ops/fibers.ts");
  const { log } = await import("../src/ops/log.ts");
  const { platform } = await import("../src/platform/index.ts");
  const { setStationLang } = await import("../src/ops/i18n.ts");
  const lan = await import("../src/mesh/lan.ts");
  const realFsp = await import("node:fs/promises");
  const cp = await import("node:child_process");
  mock.module("node:child_process", {
    namedExports: {
      ...own(cp),
      spawn: (file: string, args: string[], opts: Json) => new FakeChild(file, args ?? [], opts ?? {}, opts?.detached === true),
      execFile: fakeExecFile,
    },
  } as never);
  // (`execFile` as `promisify` takes it: its custom form)
  const net = {
    createConnection: (path: string) => new FakeSocket({ unix: path }),
    connect: (port: number) => new FakeSocket({ port }),
  };
  mock.module("node:net", { defaultExport: net, namedExports: net } as never);
  const realFs = await import("node:fs");
  mock.module("node:fs", {
    namedExports: {
      ...own(realFs),
      constants: { ...realFs.constants },
      existsSync: (p: string) => world().fs.has(p),
      readFileSync: (p: string, enc?: Json) => {
        const n = world().fs.get(p);
        if (n?.kind !== "file") throw Object.assign(new Error(`ENOENT: no such file or directory, open '${p}'`), { code: "ENOENT" });
        return enc ? n.data.toString("utf8") : n.data;
      },
      watch: (dir: string, listener: (event: string, name: string | null) => void) => {
        if (world().fs.get(dir)?.kind !== "dir") throw Object.assign(new Error(`ENOENT: no such file or directory, watch '${dir}'`), { code: "ENOENT" });
        const id = world().id();
        const w = Object.assign(new EventEmitter(), {
          close: () => {
            if (!world().watches.delete(id)) return;
            world().note({ t: "unwatch", watch: id });
          },
        });
        world().watches.set(id, { dir, deliver: (ev) => (ev.error ? w.emit("error", new Error("watch failed")) : listener("rename", ev.name)) });
        world().note({ t: "watch", watch: id, dir });
        return w;
      },
    },
  } as never);
  mock.module("node:fs/promises", { namedExports: { ...own(realFsp), ...fsp } } as never);
  const os = await import("node:os");
  mock.module("node:os", { namedExports: { ...own(os), hostname: () => "box.local", tmpdir: () => "/tmp", homedir: () => "/home/me" } } as never);
  const crypto = await import("node:crypto");
  mock.module("node:crypto", { namedExports: { ...own(crypto), randomBytes: (n: number) => world().randomBytes(n), randomInt: (lo: number, hi: number) => world().randomInt(lo, hi) } } as never);
  // (deflated as Node does, inflated as it does: done at once, given back after a turn as the thread pool would)
  const wrap = (f: (b: Buffer) => Buffer) => (b: Buffer, cb: (e: Error | null, r?: Buffer) => void) => {
    let r: Buffer | undefined, err: Error | null = null;
    try { r = f(b); } catch (e) { err = e as Error; }
    queueMicrotask(() => cb(err, r));
  };
  mock.module("node:zlib", { namedExports: { ...own(realZlib), inflate: wrap((b) => realZlib.inflateSync(b)), deflate: wrap((b) => realZlib.deflateSync(b)) } } as never);
  mock.module(new URL("../src/mesh/lan.ts", import.meta.url).href, { namedExports: { ...lan, lanReach: async () => { const r = await worldCall("reach"); return r; } } } as never);
  mock.method(wall, "now", () => world().now);
  mock.method(wall, "after", (ms: number, f: () => void) => {
    const id = world().arm(ms, f);
    return () => world().cancel(id);
  });
  mock.method(log, "info", (part: string, message: string, fields?: Json) => world().note({ t: "log", level: "info", part, message, fields: plain(fields) }));
  mock.method(log, "warn", (part: string, message: string, fields?: Json) => world().note({ t: "log", level: "warn", part, message, fields: plain(fields) }));
  mock.method(platform, "runnable", (file: string, args: string[]) => ({ file, args }));
  mock.method(platform, "runnableSoon", async (file: string, args: string[]) => ({ file, args }));
  mock.method(platform, "mountsSoon", async () => worldCall("mounts"));
  mock.method(platform, "grouped", (program: string, args: string[]) => [program, args]);
  mock.method(platform, "signalChildGroup", (child: FakeChild, signal: string) => {
    world().note({ t: "child.kill", child: child.w.id, signal, group: true });
    child.w.onKill(signal);
  });
  mock.method(process.hrtime, "bigint", () => BigInt(world().us) * 1000n);
  setStationLang("en");
}

/// What both sides ask of the world that only the world answers (the disks mounted, the LAN reached): at once.
async function worldCall(op: string): Promise<Json> {
  if (op === "mounts") return [...world().mounts];
  if (op === "reach") return world().reach;
  throw new Error(`no world call ${op}`);
}

/// A value as both sides are compared by: bytes as base64, what is undefined left out.
function plain(v: unknown): Json {
  const walk = (x: unknown): unknown => {
    if (x instanceof Uint8Array) return b64(x);
    if (Array.isArray(x)) return x.map(walk);
    if (x !== null && typeof x === "object") {
      const out: Record<string, unknown> = {};
      for (const [k, val] of Object.entries(x)) if (val !== undefined && typeof val !== "function") out[k] = walk(val);
      return out;
    }
    return x;
  };
  return v === undefined ? null : JSON.parse(JSON.stringify(walk(v)));
}

/// An error as both sides are compared by: its kind, its message, and what it carries.
function errorShape(e: Json): Json {
  if (e?.constructor?.name === "ScreenRefused") return plain({ kind: "ScreenRefused", message: e.message, status: e.status, key: e.key, args: e.args, access: e.access });
  if (e?.constructor?.name === "GrantRefused") return { kind: "GrantRefused", message: e.message, key: e.key };
  return plain({ kind: "Error", message: e?.message ?? String(e), code: typeof e?.code === "string" ? e.code : undefined });
}

// ---------------------------------------------------------------------------------------------------------------
// The TypeScript's side: its parts made and asked as the harness's commands make and ask the program's

let M: Json = null;

async function loadModules() {
  M = {
    net: (await import("node:net")).default,
    effect: await import("effect"),
    source: await import("../src/screens/source.ts"),
    hub: await import("../src/screens/hub.ts"),
    ui: await import("../src/screens/ui.ts"),
    desktop: await import("../src/screens/desktop.ts"),
    mac: await import("../src/screens/mac-input.ts"),
    win: await import("../src/screens/win-desktop.ts"),
    winInput: await import("../src/screens/win-input.ts"),
    sim: await import("../src/screens/simulator.ts"),
    simInput: await import("../src/screens/sim-input.ts"),
    simDebug: await import("../src/screens/sim-debug.ts"),
    simChrome: await import("../src/screens/sim-chrome.ts"),
    simMask: await import("../src/screens/sim-mask.ts"),
    android: await import("../src/screens/android.ts"),
    x11: await import("../src/screens/x11-desktop.ts"),
    portal: await import("../src/screens/linux-portal.ts"),
    session: await import("../src/screens/linux-session.ts"),
    tools: await import("../src/screens/linux-tools.ts"),
    linux: await import("../src/screens/linux-desktop.ts"),
    app: await import("../src/helper/app.ts"),
    grants: await import("../src/helper/grants.ts"),
    files: await import("../src/helper/files.ts"),
  };
}

const sz = (s: Json) => ({ width: s.width, height: s.height });
const frameJ = (f: Json) => (f === null ? null : plain({ ...(f.config ? { config: f.config } : {}), key: f.key, ts: f.ts, data: f.data }));
const input = (e: Json) => e;

class TsSide implements Side {
  readonly world = new World();
  readonly insts = new Map<string, Json>();
  readonly #pending = new Set<Promise<void>>();

  constructor() {
    current = this.world;
  }

  #cb(name: string) {
    return () => world().note({ t: "cb", cb: name, value: null });
  }
  #cbWith(name: string, v: Json) {
    world().note({ t: "cb", cb: name, value: plain(v) });
  }

  #helperClock() {
    // (the helper's clock, the world's: its sleeps the world's timers)
    return {
      currentTimeMillisUnsafe: () => world().now,
      sleep: (d: Json) => (M.effect.Effect.promise(() => new Promise<void>((r) => { const id = world().arm(M.effect.Duration.toMillis(d), r); void id; }))),
    };
  }

  #fakeSource(spec: Json) {
    const id = spec.id ?? "fake";
    const has = (k: string) => spec[k] === true;
    const act = (name: string) => async () => this.#cbWith(`${id}.${name}`, null);
    const me = this;
    const src: Json = {
      id,
      kind: spec.kind ?? "desktop",
      title: () => spec.title ?? id,
      size: () => ({ width: spec.width ?? 0, height: spec.height ?? 0 }),
      async open(o: Json) {
        me.#cbWith(`${id}.open`, { maxWidth: o.maxWidth, maxHeight: o.maxHeight });
        let ended = false;
        return {
          next: async () => (me.#cbWith(`${id}.next`, null), null),
          keyframe: () => me.#cbWith(`${id}.keyframe`, null),
          input: async (e: Json) => me.#cbWith(`${id}.input`, e),
          close: () => { if (!ended) { ended = true; me.#cbWith(`${id}.close`, null); } },
        };
      },
    };
    if (spec.access) src.access = () => ({ capture: spec.access.capture === true, control: spec.access.control === true, ...(spec.access.unsupported ? { unsupported: spec.access.unsupported } : {}), ...(spec.access.reason ? { reason: spec.access.reason } : {}), ...(spec.access.app ? { app: spec.access.app } : {}), ...(spec.access.path ? { path: spec.access.path } : {}), ...(spec.access.asking ? { asking: true } : {}) });
    if (spec.clipboard) src.clipboard = () => spec.clipboard;
    if (has("reveal")) src.reveal = true;
    if (has("peek")) src.peek = true;
    if (has("farview")) src.farview = true;
    if (spec.openedBy !== undefined) src.openedBy = () => spec.openedBy;
    if (has("userTab")) src.userTab = true;
    if (spec.sleeping !== undefined) src.sleeping = () => spec.sleeping === true;
    if (spec.site !== undefined) src.site = () => spec.site;
    if (has("openUrl")) src.openUrl = async (u: string) => this.#cbWith(`${id}.openUrl`, u);
    for (const k of ["reload", "back", "forward", "sleep", "discard"]) if (has(k)) src[k] = act(k);
    if (spec.since !== undefined) src.since = () => spec.since;
    if (has("poses")) src.poses = true;
    if (spec.panels) src.panels = spec.panels;
    return src;
  }

  #watcher(spec: Json) {
    const label = spec.label ?? spec.name;
    return {
      name: spec.name,
      control: spec.control === true,
      tell: (state: Json) => this.#cbWith(`${label}.tell`, state),
      ...(spec.device !== undefined ? { device: spec.device } : {}),
      ...(spec.self !== undefined ? { self: spec.self } : {}),
      ...(spec.client !== undefined ? { client: spec.client } : {}),
      ...(spec.app !== undefined ? { app: spec.app } : {}),
      ...(spec.agent ? { agent: true } : {}),
      ...(spec.end ? { end: (by: string) => this.#cbWith(`${label}.end`, by) } : {}),
      ...(spec.watchOnly ? { watchOnly: (by?: string) => this.#cbWith(`${label}.watchOnly`, by ?? null) } : {}),
    };
  }

  #keep(a: Json, v: Json) {
    if (a.as === undefined) return null;
    this.insts.set(a.as, v);
    return a.as;
  }

  #make(kind: string, a: Json): Json {
    const name = a.inst;
    const helper = a.helper !== undefined ? this.insts.get(a.helper) : undefined;
    switch (kind) {
      case "hub": return new M.hub.ScreenHub("drop" in a ? { drop: () => a.drop } : {});
      case "fakeSource": return this.#fakeSource(a.spec ?? {});
      case "helperView": {
        const socket = M.net.createConnection(a.path ?? "/view.sock");
        const inputOps = a.input === "win" ? new M.winInput.WinInput() : a.input === "sim" ? new M.simInput.SimInput() : new M.mac.MacInput();
        const view = new M.desktop.HelperView(a.codec ?? "h264", socket, this.#cb(`${name}.gone`), inputOps, a.capture ?? "ScreenCaptureKit", a.audio === true);
        // (asked for by the scenario when it asks, not as the station's own opener does at once)
        view.ready.catch(() => {});
        return view;
      }
      case "helper": return new M.app.HelperApp({ app: a.app, dir: a.dir, clock: this.#helperClock(), ...(a.onBack ? { onBack: this.#cb(`${name}.back`) } : {}) });
      case "grants": return new M.grants.HelperGrants({ helper, folders: a.folders !== false, ...(a.volumes ? { volumes: a.volumes } : {}) });
      case "files": return new M.files.HelperFiles({ helper, changed: this.#cb(`${name}.changed`), ...(a.grants ? { grants: this.insts.get(a.grants) } : {}) });
      case "desktop": return new M.desktop.Desktop({ supported: a.supported === true, helper: helper ?? null, ...(a.grants ? { grants: this.insts.get(a.grants) } : {}), changed: this.#cb(`${name}.changed`), ...(a.title !== undefined ? { title: () => a.title } : {}), ...(a.lang !== undefined ? { lang: () => a.lang } : {}), ...(a.synthetic !== undefined ? { synthetic: a.synthetic } : {}) });
      case "windows": return new M.win.WindowsDesktop({ binary: a.binary ?? null, ui: a.ui ?? null, changed: this.#cb(`${name}.changed`), ...(a.title !== undefined ? { title: () => a.title } : {}) });
      case "simulators": return new M.sim.Simulators({ screens: this.insts.get(a.hub ?? "hub"), helper: helper ?? null, ...(a.devices !== undefined ? { devices: a.devices } : {}) });
      case "androids": {
        const hub = this.insts.get(a.hub ?? "hub");
        return new M.android.AndroidScreens({ screens: hub, adb: () => a.adb ?? null, ...(a.file !== undefined ? { file: a.file } : {}), ...(a.lookAgain !== undefined ? { lookAgain: a.lookAgain } : {}) });
      }
      case "tools": return new M.tools.LinuxScreenTools(a.data);
      case "x11": return new M.x11.X11Desktop({ changed: this.#cb(`${name}.changed`), ...(a.title !== undefined ? { title: () => a.title } : {}), ...(a.tools ? { tools: this.insts.get(a.tools) } : {}), ...(a.env ? { env: { ...a.env } } : {}), ...(a.ffmpeg ? { ffmpeg: a.ffmpeg } : {}), ...(a.xdotool ? { xdotool: a.xdotool } : {}), ...(a.prepareWaitMs !== undefined ? { prepareWaitMs: a.prepareWaitMs } : {}) });
      case "gst": return new M.portal.LinuxGstDesktop({ changed: this.#cb(`${name}.changed`), env: { ...(a.env ?? process.env) }, ...(a.mode ? { mode: a.mode } : {}), ...(a.title !== undefined ? { title: () => a.title } : {}), ...(a.python ? { python: a.python } : {}), ...(a.helper ? { helper: a.helper } : {}), ...(a.consentWaitMs !== undefined ? { consentWaitMs: a.consentWaitMs } : {}) });
      case "linux": return new M.linux.LinuxDesktop({ data: a.data, changed: this.#cb(`${name}.changed`), ...(a.title !== undefined ? { title: () => a.title } : {}), ...(a.env ? { env: { ...a.env } } : {}) });
      case "macInput": return new M.mac.MacInput();
      case "winInput": return new M.winInput.WinInput();
      case "simInput": return new M.simInput.SimInput();
      case "androidInput": return new M.android.AndroidInput();
      case "scrcpy": return new M.android.ScrcpyStream((s: Json) => this.#cbWith(`${name}.session`, s), (p: Json) => this.#cbWith(`${name}.packet`, { config: p.config, key: p.key, pts: String(p.pts), data: b64(p.data) }));
      case "peeks": return new M.android.PeekCount(a.most);
    }
    throw new Error(`no part ${kind}`);
  }

  async #sourceCall(s: Json, f: string, a: Json): Promise<Json> {
    switch (f) {
      case "id": return s.id;
      case "kind": return s.kind;
      case "title": return s.title();
      case "size": return sz(s.size());
      case "access": return s.access ? plain(s.access()) : null;
      case "clipboard": return s.clipboard ? s.clipboard() : null;
      case "flags": return plain({ reveal: s.reveal ? true : undefined, peek: s.peek ? true : undefined, poses: s.poses ? true : undefined, debug: s.debug ? true : undefined, discard: s.discard ? true : undefined, panels: s.panels, chrome: s.chrome?.map(M.simChrome.toldOf) });
      case "open": return this.#keep(a, await s.open(a.options ?? {}));
      case "discard": if (!s.discard) throw new Error("no discard"); await s.discard(); return null;
      case "since": return s.since ? (s.since() ?? null) : null;
      case "scale": if (!s.scale) throw new Error("no scale"); return plain(await s.scale());
      case "setScale": if (!s.setScale) throw new Error("no setScale"); return plain(await s.setScale(a.percent));
      case "resolution": if (!s.resolution) throw new Error("no resolution"); return plain(await s.resolution());
      case "setResolution": if (!s.setResolution) throw new Error("no setResolution"); return plain(await s.setResolution(a.width, a.height));
      case "ui": if (!s.ui) throw new Error("no ui"); return plain(await s.ui(a.args ?? []));
      case "debug": return s.debug ? this.#keep(a, s.debug) : null;
      case "chrome": return s.chrome?.[a.panel ?? 0] ? this.#keep(a, s.chrome[a.panel ?? 0]) : null;
    }
    throw new Error(`a source has no ${f}`);
  }

  async #viewCall(name: string, v: Json, f: string, a: Json): Promise<Json> {
    const need = (k: string) => { if (typeof v[k] !== "function") throw new Error(`no ${k}`); };
    switch (f) {
      case "next": return frameJ(await v.next());
      case "nextAudio": need("nextAudio"); return plain(await v.nextAudio());
      case "keyframe": v.keyframe(); return null;
      case "input": await v.input(input(a.event)); return null;
      case "rate": need("rate"); v.rate(a.bits); return null;
      case "bounds": need("bounds"); v.bounds(a.maxWidth, a.maxHeight, M.source.regionOf(a.region)); return null;
      case "regions": return typeof v.regions === "function" ? v.regions() : null;
      case "video": return typeof v.video === "function" ? plain(v.video()) : null;
      case "why": return typeof v.why === "function" ? (v.why() ?? null) : null;
      case "close": v.close(); return null;
      case "setClipboard": need("setClipboard"); await v.setClipboard(a.clip.type === "png" ? { type: "png", data: unb64(a.clip.data) } : a.clip, a.paste === true); return null;
      case "watchClipboard": need("watchClipboard"); this.insts.set(`${name}.unwatchClipboard`, { close: v.watchClipboard((c: Json) => this.#cbWith(`${name}.clipboard`, c)) }); return null;
      case "watchCursor": need("watchCursor"); this.insts.set(`${name}.unwatchCursor`, { close: v.watchCursor((c: Json) => this.#cbWith(`${name}.cursor`, c)) }); return null;
      case "watchTurn": need("watchTurn"); this.insts.set(`${name}.unwatchTurn`, { close: v.watchTurn((t: Json) => this.#cbWith(`${name}.turn`, t)) }); return null;
      case "watchWindows": need("watchWindows"); this.insts.set(`${name}.unwatchWindows`, { close: v.watchWindows((w: Json) => this.#cbWith(`${name}.windows`, w)) }); return null;
      case "window": need("window"); v.window(a.id ?? null); return null;
      case "reveal": need("reveal"); await v.reveal(a.path); return null;
      case "has": return Object.fromEntries(["nextAudio", "rate", "bounds", "video", "why", "setClipboard", "watchClipboard", "watchCursor", "watchWindows", "reveal"].map((k) => [k, typeof v[k] === "function"]));
    }
    throw new Error(`a view has no ${f}`);
  }

  async #call(name: string, f: string, a: Json): Promise<Json> {
    const o = this.insts.get(name);
    if (o === undefined) throw new Error(`no part named ${name}`);
    const kind = o.constructor?.name;
    if (o.close && Object.keys(o).length === 1 && f === "close") { o.close(); return null; }
    switch (kind) {
      case "ScreenHub": return this.#hubCall(o, f, a);
      case "HelperView": if (f === "ready") return plain(await o.ready); if (f === "hasAudio") return o.hasAudio(); return this.#viewCall(name, o, f, a);
      case "HelperApp": return this.#helperCall(name, o, f, a);
      case "HelperGrants": return this.#grantsCall(name, o, f, a);
      case "HelperFiles": return this.#filesCall(o, f, a);
      case "HelperFs": return this.#hfsCall(o, f, a);
      case "Desktop": case "WindowsDesktop": case "X11Desktop": case "LinuxGstDesktop": case "LinuxDesktop":
        if (f === "refresh") { await o.refresh(a.force === true); return null; }
        if (f === "helperBack") { await o.helperBack(); return null; }
        if (f === "close") { await o.close(); return null; }
        return this.#sourceCall(o, f, a);
      case "Simulators": case "AndroidScreens":
        if (f === "start" || f === "refresh") { await o[f](); return null; }
        if (f === "close") { o.close(); return null; }
        throw new Error(`no ${f}`);
      case "SimDebug": return this.#debugCall(o, f, a);
      case "LinuxScreenTools":
        if (f === "prepared") { const p = await o.prepared(a.env ?? process.env); return p === null ? null : plain(p); }
        if (f === "canPrepare") return await o.canPrepare(a.env ?? process.env);
        if (f === "prepare") { await o.prepare(a.env ?? process.env); return null; }
        if (f === "close") { o.close(); return null; }
        throw new Error(`no ${f}`);
      case "MacInput": return f === "ops" ? plain(o.ops(input(a.event), a.now)) : plain(o.release());
      case "WinInput": return f === "ops" ? plain(o.ops(input(a.event))) : plain(o.release());
      case "SimInput": return plain(o.ops(input(a.event)));
      case "AndroidInput": return o.messages(input(a.event), a.size).map((m: Buffer) => b64(m));
      case "ScrcpyStream": o.heard(unb64(a.data)); return null;
      case "PeekCount": if (f === "take") return o.take(); if (f === "free") { o.free(); return null; } return o.running;
      case "FakeSocket": if (f === "write") { o.write(unb64(a.data)); return null; } o.destroy(); return null;
    }
    if (typeof o.chrome === "undefined" && typeof o.key === "string" && typeof o.dir === "string") {
      if (f === "told") return plain(M.simChrome.toldOf(o));
      if (f === "source") return plain(o);
      if (f === "pictures") return plain(await M.simChrome.picturesOf(o, a.turn, { cache: a.cache, draw: M.simChrome.SIPS.draw }));
    }
    if (typeof o.id === "string" && typeof o.title === "function") return this.#sourceCall(o, f, a);
    if (typeof o.next === "function" || typeof o.close === "function") return this.#viewCall(name, o, f, a);
    throw new Error(`cannot call ${f} of ${name}`);
  }

  async #hubCall(hub: Json, f: string, a: Json): Promise<Json> {
    switch (f) {
      case "add": this.insts.set(`${a.source}.remove`, { close: hub.add(this.insts.get(a.source)) }); return null;
      case "remove": this.insts.get(`${a.source}.remove`)?.close(); return null;
      case "list": return hub.list().map((s: Json) => s.id);
      case "get": { const s = hub.get(a.id); return s === undefined ? null : this.#keep(a, s); }
      case "watch": hub.watch((list: Json[]) => this.#cbWith(`${a.inst ?? "hub"}.watch`, list.map((s) => s.id))); return null;
      case "onChange": hub.onChange(() => this.#cbWith(`${a.inst ?? "hub"}.change`, null)); return null;
      case "changed": hub.changed(); return null;
      case "refresher": hub.refresher(async () => this.#cbWith(`${a.label}.refresh`, null)); return null;
      case "refresh": await hub.refresh(); return null;
      case "people": return plain(hub.people(a.id));
      case "join": this.insts.set(a.as, { close: hub.join(a.id, this.#watcher(a.watcher)) }); return null;
      case "leave": this.insts.get(a.view)?.close(); return null;
      case "endView": hub.endView(a.id, a.view, a.by); return null;
      case "watchOnly": hub.watchOnly(a.id, a.view); return null;
      case "mayDrive": return hub.mayDrive(a.id, a.device, a.taken === true);
      case "drive": return plain(hub.drive(a.id, a.device, a.taken === true, a.by));
      case "takeControl": return hub.takeControl(a.id, a.by);
      case "endViews": return hub.endViews(a.id, a.by);
      case "openAs": return this.#keep(a, await hub.openAs(a.id, a.options ?? {}, { name: a.name, control: a.control === true }));
      case "whenStopping": hub.whenStopping(() => this.#cbWith(`${a.label}.stop`, null)); return null;
      case "close": hub.close(); return null;
      case "closeScreen": await hub.closeScreen(a.id); return null;
      case "setBrowser": hub.setBrowser(a.browser ? { available: () => a.browser.available === true, openUserTab: async (url: string, id?: string) => (this.#cbWith("browser.open", { url, id: id ?? null }), `browser:${id ?? "u_000000000000"}`) } : null); return null;
      case "openBrowser": return await hub.openBrowser(a.url, a.id);
      case "openUrl": await hub.openUrl(a.id, a.url); return null;
      case "reloadScreen": await hub.reloadScreen(a.id); return null;
      case "historyScreen": await hub.historyScreen(a.id, a.delta); return null;
      case "sleepScreen": await hub.sleepScreen(a.id); return null;
      case "debugOf": return this.#keep(a, hub.debugOf(a.id));
      case "chromeOf": return plain(await hub.chromeOf(a.id, a.panel, a.turn));
      case "listed": return plain(hub.listed(a.lang));
    }
    throw new Error(`a hub has no ${f}`);
  }

  async #helperCall(name: string, h: Json, f: string, a: Json): Promise<Json> {
    switch (f) {
      case "request": return plain(await h.request(a.op));
      case "connect": return this.#keep(a, await h.connect(a.op));
      case "pid": return await h.pid();
      case "restarted": await h.restarted(a.pid); return null;
      case "ensure": await h.ensure(); return null;
      case "back": await h.back(); return null;
      case "quit": await h.quit(); return null;
      case "listen": h.listen((e: Json) => this.#cbWith(`${name}.event`, e)); return null;
      case "onBack": h.onBack(this.#cb(`${name}.back`)); return null;
      case "ui": return plain(await M.ui.helperUi(h)(a.args ?? []));
    }
    throw new Error(`a helper has no ${f}`);
  }

  async #grantsCall(name: string, g: Json, f: string, a: Json): Promise<Json> {
    switch (f) {
      case "status": return plain(g.status());
      case "refresh": await g.refresh(a.force === true); return null;
      case "state": return g.state(a.grant);
      case "view": return plain(g.view());
      case "show": return await g.show(a.grant, a.words ?? {}, a.paths, a.again === true);
      case "request": return plain(await g.request(a.grant, a.words ?? {}, a.again === true));
      case "onChange": g.onChange(this.#cb(`${name}.change`)); return null;
    }
    throw new Error(`grants have no ${f}`);
  }

  async #filesCall(fl: Json, f: string, a: Json): Promise<Json> {
    switch (f) {
      case "known": return plain(fl.known(a.top));
      case "check": fl.check(a.tops); return null;
      case "ask": return await fl.ask(a.grant, a.top);
      case "search": return await fl.search(a.top, a.query, a.most, a.protect ?? []);
      case "request": return plain(await fl.request(a.op));
      case "fs": return this.#keep(a, fl.fs({ roots: a.roots ?? [], protect: a.protect ?? [] }));
    }
    throw new Error(`files have no ${f}`);
  }

  async #hfsCall(h: Json, f: string, a: Json): Promise<Json> {
    switch (f) {
      case "list": return plain(await h.list(a.dir, a.most));
      case "names": return await h.names(a.dir);
      case "stat": return plain(await h.stat(a.path));
      case "lstat": return plain(await h.lstat(a.path));
      case "real": return await h.real(a.path);
      case "read": { const r = await h.read(a.path, a.offset, a.length); return { bytes: b64(r.bytes), size: r.size, mtimeMs: r.mtimeMs }; }
      case "readAll": return b64(await h.readAll(a.path));
      case "copyTo": await h.copyTo(a.path, a.to); return null;
      case "write": return plain(await h.write(a.path, { create: a.w.create === true, offset: a.w.offset ?? 0, data: unb64(a.w.data ?? ""), ...(a.w.atLeast !== undefined ? { atLeast: a.w.atLeast } : {}), ...(a.w.truncate !== undefined ? { truncate: a.w.truncate } : {}), ...(a.w.sync ? { sync: true } : {}) }));
      case "rename": await h.rename(a.from, a.to); return null;
      case "mkdir": await h.mkdir(a.path, a.recursive === true); return null;
      case "remove": await h.remove(a.path); return null;
      case "trash": return await h.trash(a.path);
      case "unlink": await h.unlink(a.path); return null;
    }
    throw new Error(`an fs has no ${f}`);
  }

  async #debugCall(d: Json, f: string, a: Json): Promise<Json> {
    switch (f) {
      case "logs": return plain(d.logs(a.after ?? 0));
      case "apps": return plain(await d.apps());
      case "relaunch": return await d.relaunch(a.app);
      case "settings": return plain(await d.settings());
      case "setSetting": return await d.setSetting(a.name, a.value);
      case "openUrl": return await d.openUrl(a.url);
      case "location": return await d.location(a.at ?? null);
      case "statusBar": await d.statusBar(a.tidy === true); return null;
      case "push": return await d.push(a.app, a.text);
      case "installFolder": return d.installFolder();
      case "install": return await d.install(a.path);
      case "uninstall": return await d.uninstall(a.app);
      case "biometrics": return await d.biometrics(a.what);
      case "recordStart": await d.recordStart(a.panel ?? null); return null;
      case "recording": return d.recording;
      case "recordStop": return plain(await d.recordStop());
      case "screenshot": return b64(await d.screenshot());
      case "close": d.close(); return null;
    }
    throw new Error(`a debug has no ${f}`);
  }

  #pure(f: string, a: Json): Json {
    const S = M.source, H = M.hub, A = M.android, C = M.simChrome;
    const opts = (o: Json) => o ?? {};
    switch (f) {
      case "codecFor": return S.codecFor(opts(a.options), a.own) ?? null;
      case "regionOf": return S.regionOf(a.v);
      case "clipFits": return S.clipFits(a.clip.type === "png" ? { type: "png", data: unb64(a.clip.data) } : a.clip);
      case "windowsOf": return plain(S.windowsOf(a.v));
      case "userTab": return S.USER_TAB_ID.test(a.s);
      case "viewOn": return H.viewOn(a.v);
      case "accessShown": return plain(H.accessShown(a.access ?? undefined, a.lang));
      case "addressShown": return H.addressShown(a.address ?? undefined) ?? null;
      case "envelope": return plain(M.ui.envelope(a.out, Number(a.status)));
      case "treeText": return M.ui.treeText(a.tree);
      case "windowWords": return plain(M.desktop.windowWords(a.lang));
      case "filesWords": return plain(M.files.filesWords(a.lang));
      case "askWords": return plain(M.files.askWords(a.lang));
      case "helperClip": return b64(M.desktop.helperClip(a.clip.type === "png" ? { type: "png", data: unb64(a.clip.data) } : a.clip, a.flags));
      case "helperMessage": return b64(M.desktop.helperMessage(a.kind, unb64(a.payload ?? "")));
      case "localNetworkName": return M.grants.localNetworkName(a.execPath);
      case "grantState": return M.grants.grantState(a.s, a.grant);
      case "isGrant": return M.grants.isGrant(a.v);
      case "flagsOf": return M.mac.flagsOf(a.mods);
      case "bitrateOf": return A.bitrateOf(a.side);
      case "metaOf": return A.metaOf(a.mods);
      case "nalsOf": return A.nalsOf(unb64(a.data)).map((n: Uint8Array) => b64(n));
      case "avcCOf": { const r = A.avcCOf(a.nals.map(unb64)); return r === null ? null : b64(r); }
      case "avccOf": return b64(A.avccOf(a.nals.map(unb64)));
      case "sideOf": return A.sideOf(opts(a.options));
      case "viewArgs": return plain(A.viewArgs(opts(a.options)));
      case "startOf": return A.startOf(a.lines, a.port) ?? null;
      case "shownDevice": return A.shownDevice(a.serial);
      case "devicesOf": return A.devicesOf(a.lines);
      case "panelsOf": return plain(A.panelsOf(a.dumpsys));
      case "sizeOf": return A.sizeOf(a.wm);
      case "displaysOf": return plain(C.displaysOf(a.capabilities, a.profile));
      case "pageSize": return C.pageSize(unb64(a.pdf));
      case "turned": { const p = C.turned({ width: a.p.width, height: a.p.height, data: new Uint8Array(unb64(a.p.data)) }, a.turn); return { width: p.width, height: p.height, data: b64(p.data) }; }
      case "bootedOf": return plain(M.sim.bootedOf(a.listed));
      case "runtimeName": return M.sim.runtimeName(a.id);
      case "screenOf": return M.sim.screenOf(a.capabilities);
      case "turnOf": return M.simDebug.turnOf(a.said, a.panel);
      case "logOf": return plain(M.simDebug.logOf(a.line));
      case "appsOf": return plain(M.simDebug.appsOf(a.installed, a.launchctl));
      case "scaleOf": return plain(M.win.scaleOf(a.told));
      case "resolutionOf": return plain(M.win.resolutionOf(a.told));
      case "graphicalSession": return plain(M.session.graphicalSession(a.id, a.uid, a.text));
      case "keyTables": return { mac: M.mac.KEYCODES, win: Object.fromEntries(Object.entries(M.winInput.KEYS).map(([k, v]: [string, Json]) => [k, { scan: v.scan, ext: v.ext === true, vk: v.vk ?? 0 }])), sim: M.simInput.USAGES, android: A.KEYCODES, evdev: M.x11.EVDEV };
      case "localeCompare": return Math.sign(String(a.a).localeCompare(String(a.b)));
    }
    throw new Error(`no plain function ${f}`);
  }

  async #asyncPure(f: string, a: Json): Promise<Json> {
    const C = M.simChrome;
    switch (f) {
      case "panelOf": return plain(await M.simMask.panelOf(unb64(a.pdf)));
      case "decode": { const p = await C.decode(unb64(a.png)); return { width: p.width, height: p.height, data: b64(p.data) }; }
      case "encodeDecoded": { const p = await C.decode(await C.encode({ width: a.p.width, height: a.p.height, data: new Uint8Array(unb64(a.p.data)) })); return { width: p.width, height: p.height, data: b64(p.data) }; }
    }
    return this.#pure(f, a);
  }

  async #worldly(f: string, a: Json): Promise<Json> {
    switch (f) {
      case "turnMovie": return await M.simDebug.turnMovie(a.file, a.turn);
      case "desktopEnvironment": return plain(await M.session.desktopEnvironment(a.base ?? process.env));
      case "processUi": return plain(await M.ui.processUi(a.binary)(a.args ?? []));
      case "install": return plain(await M.app.install(a.app, a.dir));
      case "chromeOf": { const c = await M.simChrome.chromeOf(a.display, a.bundle, a.sensor ?? null, a.root, { cache: a.cache, draw: M.simChrome.SIPS.draw }); if (c && a.as) this.insts.set(a.as, c); return plain(c); }
      case "executable": return await M.tools.executable(a.name, a.env ?? process.env);
      case "emulatorStart": return (await M.android.emulatorStart(a.serial)) ?? null;
      case "helperApp": return M.app.helperApp(a.env ?? {});
      case "uiBinary": return M.ui.uiBinary(a.env ?? {});
      case "screenBinary": return M.win.screenBinary(a.env ?? {});
    }
    throw new Error(`no worldly ${f}`);
  }

  cmd(cmd: string, j: Json) {
    const handle: { done: boolean; ok?: Json; err?: Json; promise: Promise<void> } = { done: false, promise: Promise.resolve() };
    const run = async (): Promise<Json> => {
      switch (cmd) {
        case "pure": return this.#asyncPure(j.fn, j.args ?? {});
        case "worldly": return this.#worldly(j.fn, j.args ?? {});
        case "new": this.insts.set(j.args.inst, this.#make(j.kind, j.args)); return null;
        case "call": return this.#call(j.inst, j.fn, j.args ?? {});
      }
      throw new Error(`no command ${cmd}`);
    };
    const p = (async () => {
      try {
        handle.ok = plain(await run());
      } catch (e) {
        handle.err = errorShape(e);
      }
      handle.done = true;
    })();
    handle.promise = p;
    this.#pending.add(p);
    void p.finally(() => this.#pending.delete(p));
    return handle;
  }

  async settle() {
    for (;;) {
      let before = -1;
      while (before !== this.world.trace.length + this.world.queue.length) {
        before = this.world.trace.length + this.world.queue.length;
        await new Promise((r) => setImmediate(r));
        await new Promise((r) => setImmediate(r));
      }
      const next = this.world.queue.shift();
      if (next === undefined) return;
      next();
    }
  }

  async close() {}
}

// ---------------------------------------------------------------------------------------------------------------
// The program's side: the harness, its world the test's

class MbProgram {
  readonly child = realSpawn(readerBinary()!, ["--builder", "harness-screens", "--shell-dir", join(process.env.STILLFAIL_TEST_TMP ?? "/tmp", "mbscreens-shell")], { stdio: ["pipe", "pipe", "pipe"] });
  #next = 0;
  readonly #done = new Map<number, (m: Json) => void>();
  #stderr = "";
  side: MbSide | null = null;
  constructor() {
    createInterface({ input: this.child.stdout }).on("line", (line) => this.#line(line));
    this.child.stderr.on("data", (d) => (this.#stderr = (this.#stderr + d).slice(-4000)));
    this.child.on("exit", (code) => {
      for (const w of this.#done.values()) w({ err: { kind: "Error", message: `the program ended (${code}): ${this.#stderr}` } });
    });
  }
  send(j: Json) {
    const w = this.side?.world;
    this.child.stdin.write(`${JSON.stringify({ ...j, ...(w ? { now: w.now, us: w.us } : {}) })}\n`);
  }
  cmd(cmd: string, j: Json = {}): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve) => {
      this.#done.set(id, resolve);
      this.send({ cmd, id, ...j, ...(this.side ? { files: this.side.world.snapshot() } : {}) });
    });
  }
  #line(line: string) {
    const m = JSON.parse(line);
    if (typeof m.done === "number") {
      const w = this.#done.get(m.done);
      this.#done.delete(m.done);
      w?.(m);
      return;
    }
    this.side?.heard(m);
  }
  /// Its stdin ended: it ends, and is waited for (nothing of this file's is left running).
  close(): Promise<void> {
    if (this.child.exitCode !== null || this.child.signalCode !== null) return Promise.resolve();
    const gone = new Promise<void>((resolve) => this.child.once("exit", () => resolve()));
    this.child.stdin.end();
    return gone;
  }
}

class MbSide implements Side {
  readonly world = new World();
  readonly #timers = new Map<number, number>();
  readonly #children = new Map<number, WChild>();
  readonly #conns = new Map<number, WConn>();
  readonly #watches = new Map<number, number>();
  #told = 0;
  readonly program: MbProgram;
  constructor(program: MbProgram) {
    this.program = program;
    program.side = this;
    current = this.world;
  }
  async open() {
    await this.program.cmd("world", { os: { hostname: "box.local", tmpdir: "/tmp", homedir: "/home/me", arch: process.arch, os: process.platform === "darwin" ? "mac" : process.platform === "win32" ? "windows" : "linux", uid: process.getuid?.() ?? null, execPath: process.execPath, pid: process.pid, env: { ...process.env }, codeDir: SCREENS_DIR, cwd: process.cwd() }, zh: ZH, en: EN });
  }
  #ev(j: Json) {
    this.#told++;
    this.program.send(j);
  }
  heard(m: Json) {
    const w = this.world;
    if (typeof m.tell === "string") {
      switch (m.tell) {
        case "after": this.#timers.set(m.timer, w.arm(m.ms, () => this.#ev({ ev: "timer", timer: m.timer }))); return;
        case "cancel": { const id = this.#timers.get(m.timer); if (id !== undefined) w.cancel(id); return; }
        case "spawn": this.#children.set(m.child, w.spawned(m.file, m.args, m.env, m.group, m.stdio, m.verbatim, (ev) => this.#ev({ ev: "child", child: m.child, ...ev }))); return;
        case "child.write": {
          const c = this.#children.get(m.child)!;
          w.note({ t: "child.write", child: c.id, data: m.data });
          c.stdin.push(unb64(m.data));
          c.onWrite(unb64(m.data));
          if (m.cb !== undefined) w.post(() => this.#ev({ ev: "written", cb: m.cb, error: null }));
          return;
        }
        case "child.end": {
          const c = this.#children.get(m.child)!;
          w.note({ t: "child.end", child: c.id, ...(m.data !== undefined ? { data: m.data } : {}) });
          if (m.data !== undefined) c.onWrite(unb64(m.data));
          c.ended = true;
          c.onEnd();
          return;
        }
        case "child.destroy": { const c = this.#children.get(m.child)!; w.note({ t: "child.destroy", child: c.id }); c.onEnd(); return; }
        case "child.kill": { const c = this.#children.get(m.child)!; w.note({ t: "child.kill", child: c.id, signal: m.signal, group: m.group }); c.onKill(m.signal); return; }
        case "conn": this.#conns.set(m.conn, w.connected(m.unix !== undefined ? { unix: m.unix } : { port: m.port }, (ev) => this.#ev({ ev: "conn", conn: m.conn, ...ev }))); return;
        case "conn.write": { const c = this.#conns.get(m.conn)!; w.note({ t: "conn.write", conn: c.id, data: m.data }); c.onData(unb64(m.data)); return; }
        case "conn.end": { const c = this.#conns.get(m.conn)!; w.note({ t: "conn.end", conn: c.id }); c.onEnd(); return; }
        case "conn.destroy": { const c = this.#conns.get(m.conn)!; if (c.closed) return; w.note({ t: "conn.destroy", conn: c.id }); c.onGone(); c.close(); return; }
        case "watch": {
          const id = w.id();
          this.#watches.set(m.watch, id);
          w.watches.set(id, { dir: m.dir, deliver: (ev) => this.#ev({ ev: "watch", watch: m.watch, ...(ev.error ? { error: true } : { name: ev.name }) }) });
          w.note({ t: "watch", watch: id, dir: m.dir });
          return;
        }
        case "unwatch": { const id = this.#watches.get(m.watch)!; if (w.watches.delete(id)) w.note({ t: "unwatch", watch: id }); return; }
        case "log": w.note({ t: "log", level: m.level, part: m.part, message: m.message, fields: m.fields === undefined ? null : m.fields }); return;
        case "cb": w.note({ t: "cb", cb: m.cb, value: m.value ?? null }); return;
      }
      throw new Error(`the program told ${m.tell}`);
    }
    if (typeof m.call === "string") {
      const answer = (r: Json) => this.#ev({ re: m.id, ...r });
      if (m.call === "exec") {
        w.exec(m.file, m.args, { ...(m.env !== null ? { env: m.env } : {}), ...(m.timeout !== null ? { timeout: m.timeout } : {}), ...(m.maxBuffer !== null ? { maxBuffer: m.maxBuffer } : {}) }, (r) => answer(r.error ? { err: { kind: "ExecFailed", ...r.error } } : { ok: r.stdout ?? "" }));
        return;
      }
      if (m.call.startsWith("fs.")) {
        const { call: _c, id: _i, ...args } = m;
        try {
          answer({ ok: w.fsOp(m.call.slice(3), args) });
        } catch (e) {
          answer({ err: e as Json });
        }
        return;
      }
      void worldCall(m.call).then((ok) => answer({ ok }));
      return;
    }
  }
  cmd(cmd: string, j: Json) {
    const handle: { done: boolean; ok?: Json; err?: Json; promise: Promise<void> } = { done: false, promise: Promise.resolve() };
    handle.promise = this.program.cmd(cmd, j).then((m) => {
      if (m.err !== undefined) handle.err = m.err;
      else handle.ok = m.ok ?? null;
      handle.done = true;
    });
    return handle;
  }
  async #quiet() {
    do {
      this.#told = 0;
      await this.program.cmd("sync");
    } while (this.#told > 0);
  }
  async settle() {
    for (;;) {
      await this.#quiet();
      const next = this.world.queue.shift();
      if (next === undefined) return;
      next();
    }
  }
  async close() {}
}

// ---------------------------------------------------------------------------------------------------------------
// Scenarios: one script, played on each side, what each did compared

class Play {
  readonly results: Json[] = [];
  readonly #handles: { step: number; h: { done: boolean; ok?: Json; err?: Json }; seen: boolean }[] = [];
  #step = 0;
  readonly side: Side;
  constructor(side: Side) {
    this.side = side;
  }
  get w(): World { return this.side.world; }
  async settle() {
    await this.side.settle();
    for (const e of this.#handles) {
      if (e.seen || !e.h.done) continue;
      e.seen = true;
      this.results.push({ step: e.step, ...(e.h.err !== undefined ? { err: e.h.err } : { ok: e.h.ok }) });
    }
  }
  async #run(cmd: string, j: Json) {
    const step = ++this.#step;
    const h = this.side.cmd(cmd, j);
    this.#handles.push({ step, h, seen: false });
    await this.settle();
    return h;
  }
  new(kind: string, args: Json) { return this.#run("new", { kind, args }); }
  call(inst: string, fn: string, args: Json = {}) { return this.#run("call", { inst, fn, args }); }
  pure(fn: string, args: Json = {}) { return this.#run("pure", { fn, args }); }
  worldly(fn: string, args: Json = {}) { return this.#run("worldly", { fn, args }); }
  async advance(ms: number) {
    await this.w.advance(ms, () => this.settle());
    await this.settle();
  }
  done(): Json {
    for (const e of this.#handles) if (!e.seen) this.results.push({ step: e.step, pending: true });
    return { results: this.results, trace: this.w.trace, files: this.w.files(), timers: [...this.w.timers.keys()].sort((a, b) => a - b) };
  }
}

let program: MbProgram | null = null;

/// A PNG as its pixels: each side deflates as its zlib does, so a picture is compared by what it shows.
function pngKey(png: Buffer): string | null {
  if (png.length < 33 || png.toString("latin1", 1, 4) !== "PNG") return null;
  const [width, height] = [png.readUInt32BE(16), png.readUInt32BE(20)];
  if (png[24] !== 8 || png[25] !== 6) return null;
  const parts: Buffer[] = [];
  for (let at = 8; at + 8 <= png.length; ) {
    const n = png.readUInt32BE(at);
    if (png.toString("latin1", at + 4, at + 8) === "IDAT") parts.push(png.subarray(at + 8, at + 8 + n));
    at += 12 + n;
  }
  const raw = realZlib.inflateSync(Buffer.concat(parts));
  const stride = width * 4;
  const out = Buffer.alloc(stride * height);
  let prior = Buffer.alloc(stride);
  for (let y = 0; y < height; y++) {
    const f = raw[y * (stride + 1)]!;
    const row = Buffer.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (let i = 0; i < stride; i++) {
      const a = i >= 4 ? row[i - 4]! : 0, b = prior[i]!, c = i >= 4 ? prior[i - 4]! : 0;
      const p = a + b - c;
      const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      row[i] = (row[i]! + (f === 0 ? 0 : f === 1 ? a : f === 2 ? b : f === 3 ? (a + b) >> 1 : pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 0xff;
    }
    row.copy(out, y * stride);
    prior = row;
  }
  return `png ${width}x${height} ${createHash("sha1").update(out).digest("hex")}`;
}

/// What is compared, every PNG in it (as base64, or a file's bytes, or in a file's JSON) by its pixels.
function pictured(v: Json): Json {
  if (typeof v === "string" && v.startsWith("iVBORw0KGgo")) return pngKey(unb64(v)) ?? v;
  if (Array.isArray(v)) return v.map(pictured);
  if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, pictured(x)]));
  return v;
}
function picturedFiles(files: Json): Json {
  const out: Json = {};
  for (const [p, f] of Object.entries(files as Record<string, Json>)) {
    if (f === null || typeof f.data !== "string") { out[p] = f; continue; }
    const data = unb64(f.data);
    const png = pngKey(data);
    let json: Json = undefined;
    if (png === null) try { json = JSON.parse(data.toString("utf8")); } catch {}
    out[p] = { ...f, data: png ?? (json !== undefined ? pictured(json) : f.data) };
  }
  return out;
}

async function both(name: string, script: (s: Play) => Promise<void>) {
  const ts = new Play(new TsSide());
  await script(ts);
  const tsDone = ts.done();
  const mbSide = new MbSide(program!);
  await mbSide.open();
  const mb = new Play(mbSide);
  await script(mb);
  const mbDone = mb.done();
  current = null;
  if (process.env.MB_SCREENS_DUMP === name) console.log(JSON.stringify({ ts: tsDone, mb: mbDone }, null, 1));
  assert.deepStrictEqual(pictured(mbDone.results), pictured(tsDone.results), `${name}: what each answered`);
  assert.deepStrictEqual(mbDone.trace, tsDone.trace, `${name}: what each did in its world`);
  assert.deepStrictEqual(picturedFiles(mbDone.files), picturedFiles(tsDone.files), `${name}: the files each left`);
  assert.deepStrictEqual(mbDone.timers, tsDone.timers, `${name}: the timers each left armed`);
  return { ts: tsDone, mb: mbDone };
}

// ---------------------------------------------------------------------------------------------------------------
// What is compared

const PNG_RED = (w: number, h: number, rgba = [255, 0, 0, 255]) => {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) raw.set(rgba, y * (w * 4 + 1) + 1 + x * 4);
  const chunk = (type: string, body: Buffer) => {
    const out = Buffer.alloc(12 + body.length);
    out.writeUInt32BE(body.length, 0);
    out.write(type, 4, "latin1");
    body.copy(out, 8);
    out.writeUInt32BE(crc32(out.subarray(4, 8 + body.length)), 8 + body.length);
    return out;
  };
  const head = Buffer.alloc(13);
  head.writeUInt32BE(w, 0);
  head.writeUInt32BE(h, 4);
  head.set([8, 6, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", head), chunk("IDAT", realZlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
};
function crc32(b: Uint8Array): number {
  let c = 0xffffffff;
  for (const v of b) {
    c ^= v;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  return (c ^ 0xffffffff) >>> 0;
}

/// A mask's PDF as Apple's framebuffer masks are: a page and its shape, deflated or not.
function maskPdf(width: number, height: number, r: number, deflated = true, extra = "") {
  const k = r * 0.5523;
  const path = `q 1 0 0 1 0 0 cm ${r} 0 m ${width - r} 0 l ${width - r + k} 0 ${width} ${r - k} ${width} ${r} c ${width} ${height - r} l ${width} ${height - r + k} ${width - r + k} ${height} ${width - r} ${height} c ${r} ${height} l ${r - k} ${height} 0 ${height - r + k} 0 ${height - r} c 0 ${r} l 0 ${r - k} ${r - k} 0 ${r} 0 c h f Q`;
  const body = deflated ? realZlib.deflateSync(Buffer.from(path, "latin1")) : Buffer.from(path, "latin1");
  return Buffer.concat([Buffer.from(`%PDF-1.4\n1 0 obj << /Type /Page /MediaBox [0 0 ${width} ${height}] ${extra}>> endobj\n2 0 obj << /Length ${body.length} >>\nstream\n`, "latin1"), body, Buffer.from("\nendstream\nendobj\n%%EOF\n", "latin1")]);
}

const PURE: [string, Json][] = [
  ["codecFor", { options: { maxWidth: 1, maxHeight: 1, codecs: ["h264", "jpeg"] }, own: ["h265", "h264", "jpeg"] }],
  ["codecFor", { options: { maxWidth: 1, maxHeight: 1, codecs: ["h264", "jpeg"], peek: true }, own: ["h265", "h264", "jpeg"] }],
  ["codecFor", { options: { maxWidth: 1, maxHeight: 1, codecs: ["h264"], peek: true }, own: ["jpeg"] }],
  ["codecFor", { options: { maxWidth: 1, maxHeight: 1, codecs: ["h265"] }, own: ["h264", "jpeg"] }],
  ["regionOf", { v: { x: 0.1, y: 0.2, w: 0.3, h: 0.4 } }],
  ["regionOf", { v: { x: -1, y: 2, w: 0.001, h: 5 } }],
  ["regionOf", { v: { x: 0, y: 0, w: 0.99, h: 0.985 } }],
  ["regionOf", { v: { x: 0.123456789, y: 0.98765, w: 0.333333, h: 0.0199999 } }],
  ["regionOf", { v: { x: 0.1, y: 0.2, w: "0.3", h: 0.4 } }],
  ["regionOf", { v: null }],
  ["clipFits", { clip: { type: "text", text: "hello" } }],
  ["clipFits", { clip: { type: "text", text: "" } }],
  ["clipFits", { clip: { type: "png", data: b64(Buffer.alloc(10)) } }],
  ["clipFits", { clip: { type: "png", data: "" } }],
  ["windowsOf", { v: [{ id: 1, app: "Finder", title: "x".repeat(250) }, { id: 1.5, app: "no" }, { id: -1 }, null, { id: 7, app: 3, title: "t" }, "x"] }],
  ["windowsOf", { v: Array.from({ length: 70 }, (_, i) => ({ id: i + 1, app: `a${i}`, title: `t${i}` })) }],
  ["windowsOf", { v: { id: 1 } }],
  ["userTab", { s: "u_0123456789ab" }],
  ["userTab", { s: "u_0123456789aB" }],
  ["userTab", { s: "u_0123456789abc" }],
  ["viewOn", { v: { id: "v1", name: "A", control: true, at: 1_800_000_000_000 - 30_000, client: "still.fail for Mac", device: "0123456789abcdef0123" } }],
  ["viewOn", { v: { id: "v1", name: "A", control: true, at: 1_800_000_000_000 - 30 * 60_000 } }],
  ["viewOn", { v: { id: "v1", name: "A", control: true, at: 1_800_000_000_000 - 5 * 3600_000, device: "" } }],
  ["viewOn", { v: { id: "v1", name: "A", control: true, at: 1_800_000_000_000 + 600_000 } }],
  ["accessShown", { access: null, lang: "en" }],
  ["accessShown", { access: { capture: true, control: true }, lang: "en" }],
  ["accessShown", { access: { capture: false, control: false, unsupported: "platform" }, lang: "zh" }],
  ["accessShown", { access: { capture: false, control: false, unsupported: "helper" }, lang: "en" }],
  ["accessShown", { access: { capture: false, control: false, app: "Ghostty", path: "/Applications/Ghostty.app" }, lang: "en" }],
  ["accessShown", { access: { capture: true, control: false, asking: true }, lang: "zh" }],
  ["accessShown", { access: { capture: false, control: true }, lang: "en" }],
  ...["linuxNoDisplay", "linuxWayland", "linuxTools", "linuxToolsPreparing", "linuxToolsFailed", "linuxUnavailable", "linuxPortalConsent", "linuxPortalUnavailable", "linuxDesktopStarting", "linuxX11FallbackUnavailable"].map((reason): [string, Json] => ["accessShown", { access: { capture: false, control: false, reason, asking: reason === "linuxPortalConsent" }, lang: "en" }]),
  ["addressShown", { address: "https://example.com/a?b" }],
  ["addressShown", { address: "" }],
  ["addressShown", { address: `https://x/${"a".repeat(2100)}` }],
  ["addressShown", { address: null }],
  ["envelope", { out: '{"ok":true,"data":{"x":1}}', status: 0 }],
  ["envelope", { out: "", status: 3 }],
  ["envelope", { out: "nope", status: "x" }],
  ["treeText", { tree: { ref_id: "s1:e1", role: "window", name: "Main", children: [{ role: "group", children: [{ ref_id: "s1:e2", role: "button", name: " Save ", states: ["disabled", "focused"] }, { role: "text", name: "Main" }, { role: "text", name: "Other", value: "Other" }, { role: "field", name: "N", value: 42 }, { ref_id: "s1:e9", role: "list", children_count: 12 }, { role: "text", value: "x".repeat(205) }] }] } }],
  ["treeText", { tree: {} }],
  ["windowWords", { lang: "en" }],
  ["windowWords", { lang: "zh" }],
  ["filesWords", { lang: "en" }],
  ["askWords", { lang: "zh" }],
  ["helperClip", { clip: { type: "text", text: "héllo" } }],
  ["helperClip", { clip: { type: "png", data: b64(Buffer.from([1, 2, 3])) }, flags: 1 }],
  ["helperMessage", { kind: 7, payload: b64(Buffer.from([0, 0, 1, 0])) }],
  ["helperMessage", { kind: 1 }],
  ["localNetworkName", { execPath: "/Applications/still.fail.app/Contents/Resources/station/node" }],
  ["localNetworkName", { execPath: "/usr/local/bin/node" }],
  ["localNetworkName", { execPath: "/a/b.app/c/d.app/Contents/x" }],
  ["grantState", { s: { capture: true, control: false, files: { documents: "denied", desktop: "granted", downloads: "x" } }, grant: "capture" }],
  ["grantState", { s: { capture: true, control: false, files: { documents: "denied" } }, grant: "control" }],
  ["grantState", { s: { capture: true, files: { documents: "denied" } }, grant: "documents" }],
  ["grantState", { s: { files: { downloads: "x" } }, grant: "downloads" }],
  ["isGrant", { v: "localNetwork" }],
  ["isGrant", { v: "camera" }],
  ...[0, 1, 2, 4, 8, 15].map((mods): [string, Json] => ["flagsOf", { mods }]),
  ...[1, 480, 481, 720, 1080, 1081, 1440, 2560].map((side): [string, Json] => ["bitrateOf", { side }]),
  ...[0, 1, 2, 4, 8, 15].map((mods): [string, Json] => ["metaOf", { mods }]),
  ["nalsOf", { data: b64(Buffer.from([0, 0, 0, 1, 0x67, 1, 2, 3, 0, 0, 1, 0x68, 4, 0, 0, 0, 1, 0x65, 9, 9])) }],
  ["nalsOf", { data: b64(Buffer.from([1, 2, 3])) }],
  ["nalsOf", { data: b64(Buffer.from([0, 0, 1, 0, 0, 1, 7])) }],
  ["avcCOf", { nals: [b64(Buffer.from([0x67, 0x42, 0xc0, 0x1e, 9])), b64(Buffer.from([0x68, 0xce]))] }],
  ["avcCOf", { nals: [b64(Buffer.from([0x67, 1, 2])), b64(Buffer.from([0x68]))] }],
  ["avcCOf", { nals: [b64(Buffer.from([0x65]))] }],
  ["avccOf", { nals: [b64(Buffer.from([0x67, 1])), b64(Buffer.from([0x68, 2])), b64(Buffer.from([0x65, 3, 4])), b64(Buffer.alloc(0))] }],
  ...[{ maxWidth: 640, maxHeight: 480, codecs: ["h264"] }, { maxWidth: 3000, maxHeight: 100, codecs: ["h264"] }, { maxWidth: 333.7, maxHeight: 101, codecs: ["h264"], peek: true }, { maxWidth: 1920, maxHeight: 1080, codecs: ["h264"], fps: 30 }].flatMap((options): [string, Json][] => [["sideOf", { options }], ["viewArgs", { options }]]),
  ["startOf", { lines: "Fri Nov  6 16:34:52 2026 /opt/android/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -netdelay none -port 5554 -avd x\nFri Nov  6 16:30:00 2026 /bin/zsh -port 5554\n", port: "5554" }],
  ["startOf", { lines: "Fri Nov  6 16:34:52 2026 qemu-system-x86_64 -port 5556", port: "5554" }],
  ["startOf", { lines: "", port: "5554" }],
  ["shownDevice", { serial: "emulator-5554" }],
  ["shownDevice", { serial: "adb-R5C._adb-tls-connect._tcp" }],
  ["shownDevice", { serial: "127.0.0.1:40001" }],
  ["devicesOf", { lines: "emulator-5554\tdevice product:sdk model:x\nR5CT\toffline\n\n 192.168.1.2:5555   device\nZX\tunauthorized" }],
  ["panelsOf", { dumpsys: "  mBaseDisplayInfo=DisplayInfo{\"Built-in\", real 1080 x 2400, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=101, center=Point(101, 101)}, RoundedCorner{position=TopRight, radius=101}, RoundedCorner{position=BottomRight, radius=95}, RoundedCorner{position=BottomLeft, radius=95}]}, x}\n  mBaseDisplayInfo=DisplayInfo{real 1080 x 2400, roundedCorners RoundedCorners{[]}}\n  mBaseDisplayInfo=DisplayInfo{surreal 10 x 10, real 800 x 600, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=8}]}}\nother line real 1 x 1" }],
  ["sizeOf", { wm: "Physical size: 1080x2400\nOverride size: 720x1600\n" }],
  ["sizeOf", { wm: "Physical size: 1440x3120" }],
  ["sizeOf", { wm: "nothing" }],
  ["panelOf", { pdf: b64(maskPdf(390, 844, 55)) }],
  ["panelOf", { pdf: b64(maskPdf(1024, 1366, 18, false)) }],
  ["panelOf", { pdf: b64(Buffer.from("%PDF no box")) }],
  ["panelOf", { pdf: b64(maskPdf(100, 100, 80)) }],
  ["displaysOf", { capabilities: { capabilities: { displays: [{ displayType: "integrated", hasDigitizer: true, chromeIdentifier: "com.apple.dt.devicekit.chrome.phone12", framebufferMaskIdentifier: "framebufferMask", width: 1170, height: 2532, scale: 3 }, { displayType: "external", hasDigitizer: true, chromeIdentifier: "x", width: 1, height: 1 }, { displayType: "integrated", hasDigitizer: true, chromeIdentifier: "y", width: 0, height: 5 }] } }, profile: {} }],
  ["displaysOf", { capabilities: { capabilities: { ScreenDimensionsCapability: { "main-screen-width": 750, "main-screen-height": 1334, "main-screen-scale": 2 } } }, profile: { chromeIdentifier: "phone8", framebufferMask: "" } }],
  ["displaysOf", { capabilities: null, profile: null }],
  ["pageSize", { pdf: b64(Buffer.from("/CropBox [ 0 0 100.5 200 ] /MediaBox [0 0 1 1]")) }],
  ["pageSize", { pdf: b64(Buffer.from("/MediaBox [-10 -20 30 40] /Rotate 90")) }],
  ["pageSize", { pdf: b64(Buffer.from("/MediaBox [0 0 0 40]")) }],
  ["turned", { p: { width: 2, height: 3, data: b64(Buffer.from(Array.from({ length: 24 }, (_, i) => i))) }, turn: 1 }],
  ["turned", { p: { width: 2, height: 3, data: b64(Buffer.from(Array.from({ length: 24 }, (_, i) => i))) }, turn: 2 }],
  ["turned", { p: { width: 2, height: 3, data: b64(Buffer.from(Array.from({ length: 24 }, (_, i) => i))) }, turn: -1 }],
  ["decode", { png: b64(PNG_RED(3, 2, [10, 20, 30, 40])) }],
  ["encodeDecoded", { p: { width: 2, height: 2, data: b64(Buffer.from(Array.from({ length: 16 }, (_, i) => i * 13))) } }],
  ["bootedOf", { listed: { devices: { "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [{ state: "Booted", udid: "0123ABCD-0123-0123-0123-0123456789AB", name: "iPhone 17", deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", lastUsedAt: "2026-11-06T08:34:52Z" }, { state: "Shutdown", udid: "1123ABCD-0123-0123-0123-0123456789AB" }, { state: "Booted", udid: "bad" }], "com.apple.CoreSimulator.SimRuntime.xrOS-2-0": [{ state: "Booted", udid: "2123abcd-0123-0123-0123-0123456789ab", lastUsedAt: "not a date" }], x: "not a list" } } }],
  ["bootedOf", { listed: null }],
  ...["com.apple.CoreSimulator.SimRuntime.iOS-26-2", "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4", "com.apple.CoreSimulator.SimRuntime.xrOS-2-0", "com.apple.CoreSimulator.SimRuntime.watchOS-11", "plain", "SimRuntime.iOS-"].map((id): [string, Json] => ["runtimeName", { id }]),
  ["screenOf", { capabilities: { capabilities: { ScreenDimensionsCapability: { "main-screen-width": 1179, "main-screen-height": 2556 } } } }],
  ["screenOf", { capabilities: { capabilities: { ScreenDimensionsCapability: { "main-screen-width": 0 } } } }],
  ["turnOf", { said: "Device Name: primary-0\nUI Orientation: Portrait\n\nDevice Name: primary-1\nx\n  UI Orientation: Landscape Left \n", panel: "primary-1" }],
  ["turnOf", { said: "Device Name: primary-1\nUI Orientation: Landscape Right", panel: "primary-1" }],
  ["turnOf", { said: "Device Name: primary-1\nUI Orientation: Portrait Upside Down", panel: "primary-1" }],
  ["turnOf", { said: "nothing", panel: "primary-1" }],
  ["logOf", { line: '{"eventMessage":"hi","processImagePath":"/x/Containers/Bundle/Application/A/App.app/App","timestamp":"t","messageType":"Default"}' }],
  ["logOf", { line: "Filtering the log data using ..." }],
  ["logOf", { line: '{"eventMessage":3}' }],
  ["appsOf", { installed: { "com.b.zed": { ApplicationType: "User", CFBundleDisplayName: "Zed" }, "com.a.alpha": { ApplicationType: "User", CFBundleName: "alpha" }, "com.apple.x": { ApplicationType: "System" }, "com.c": { ApplicationType: "User", CFBundleDisplayName: "" } }, launchctl: "PID\tStatus\tLabel\n12\t0\tUIKitApplication:com.b.zed[7a3f][rb-legacy]\n-\t0\tUIKitApplication:com.none[1]\n" }],
  ["appsOf", { installed: null, launchctl: "" }],
  ["scaleOf", { told: { percent: 150, recommended: 125, steps: [100, 125, 150, 175] } }],
  ["scaleOf", { told: { percent: 150, recommended: 125, steps: [100, 99] } }],
  ["scaleOf", { told: "x" }],
  ["resolutionOf", { told: { width: 1920, height: 1080, modes: [{ width: 1920, height: 1080, extra: 1 }, { width: 1280, height: 720 }] } }],
  ["resolutionOf", { told: { width: 1920, height: 1080, modes: [{ width: 0, height: 1 }] } }],
  ["graphicalSession", { id: "2", uid: 1000, text: "User=1000\nType=x11\nClass=user\nActive=yes\nRemote=no\nDisplay=:0\n" }],
  ["graphicalSession", { id: "3", uid: 1000, text: "User=1000\nType=wayland\nClass=user\nActive=no\nRemote=yes\nDisplay=\n" }],
  ["graphicalSession", { id: "4", uid: 1000, text: "User=1001\nType=x11\nClass=user" }],
  ["graphicalSession", { id: "5", uid: 1000, text: "User=1000\nType=tty\nClass=user" }],
  ["keyTables", {}],
  ...[["Zed", "alpha"], ["apple", "Apple"], ["a", "b"], ["b2", "b10"], ["com.x", "com-y"], ["", "a"]].map(([a, b]): [string, Json] => ["localeCompare", { a, b }]),
];

const EV = {
  move: (x: number, y: number, buttons = 0) => ({ t: "pointer", kind: "move", x, y, buttons }),
  down: (x: number, y: number, buttons = 1) => ({ t: "pointer", kind: "down", x, y, buttons }),
  up: (x: number, y: number, buttons = 0) => ({ t: "pointer", kind: "up", x, y, buttons }),
  wheel: (x: number, y: number, dx: number, dy: number) => ({ t: "wheel", x, y, dx, dy }),
  key: (kind: "down" | "up", code: string, key: string, mods = 0) => ({ t: "key", kind, key, code, mods }),
  text: (text: string) => ({ t: "text", text }),
};

/// A run of input as people make it: clicks, double clicks, drags, the wheel, keys with and without modifiers, text.
const INPUTS: [Json, number][] = [
  [EV.move(0.1, 0.2), 0],
  [EV.down(0.1, 0.2), 10],
  [EV.up(0.1, 0.2), 20],
  [EV.down(0.105, 0.2), 300],
  [EV.up(0.105, 0.2), 310],
  [EV.down(0.105, 0.2), 900],
  [EV.up(0.105, 0.2), 910],
  [EV.down(0.5, 0.5, 2), 1000],
  [EV.move(0.6, 0.6, 2), 1010],
  [EV.up(0.6, 0.6, 0), 1020],
  [EV.down(0.3, 0.98, 1), 1100],
  [EV.move(0.3, 0.5, 1), 1110],
  [EV.up(0.3, 0.4, 0), 1120],
  [EV.down(0.4, 0.01, 1), 1130],
  [EV.up(0.4, 0.01, 0), 1140],
  [EV.wheel(0.5, 0.5, 30, -250), 1200],
  [EV.wheel(0.5, 0.5, 0, 0), 1210],
  [EV.wheel(0.5, 0.5, 51, 70), 1220],
  [EV.key("down", "ShiftLeft", "Shift", 8), 1300],
  [EV.key("down", "KeyA", "A", 8), 1310],
  [EV.key("up", "KeyA", "A", 8), 1320],
  [EV.key("up", "ShiftLeft", "Shift", 0), 1330],
  [EV.key("down", "KeyC", "c", 2), 1400],
  [EV.key("up", "KeyC", "c", 2), 1410],
  [EV.key("down", "KeyH", "h", 12), 1420],
  [EV.key("up", "KeyH", "h", 12), 1430],
  [EV.key("down", "KeyH", "h", 14), 1440],
  [EV.key("down", "KeyL", "l", 4), 1450],
  [EV.key("down", "KeyK", "k", 4), 1460],
  [EV.key("down", "ArrowLeft", "ArrowLeft", 0), 1470],
  [EV.key("down", "F5", "F5", 0), 1480],
  [EV.key("down", "Unknown", "é", 0), 1490],
  [EV.key("down", "Unknown", "é", 2), 1500],
  [EV.key("down", "Unknown", "ab", 0), 1510],
  [EV.key("down", "MetaLeft", "Meta", 4), 1520],
  [EV.key("down", "KeyV", "v", 4), 1530],
  [{ t: "text", text: "Hi there!\n\t~" }, 1540],
  [{ t: "text", text: "日本" }, 1550],
  [{ t: "text", text: "" }, 1560],
  [{ t: "pose", name: "book" }, 1570],
  [{ t: "device", name: "volume_up" }, 1580],
  [{ t: "device", name: "memory_warning" }, 1590],
  [{ t: "device", name: "rotate" }, 1600],
  [{ t: "button", page: 12, usage: 64, down: true }, 1610],
  [EV.down(0.2, 0.2, 5), 1700],
  [EV.up(0.2, 0.2, 4), 1710],
];

async function main() {
  await installMocks();
  await loadModules();
  program = new MbProgram();

  test("the plain functions answer as the TypeScript's", async () => {
    await both("pure", async (s) => {
      for (const [fn, args] of PURE) await s.pure(fn, args);
    });
  });

  test("input as each machine takes it: macOS's, Windows', an iOS Simulator's, scrcpy's; what a view holds let go", async () => {
    await both("inputs", async (s) => {
      for (const kind of ["macInput", "winInput", "simInput", "androidInput"]) await s.new(kind, { inst: kind });
      for (const [event, now] of INPUTS) {
        await s.call("macInput", "ops", { event, now });
        await s.call("winInput", "ops", { event });
        await s.call("simInput", "ops", { event });
        await s.call("androidInput", "messages", { event, size: { width: 1080, height: 2400 } });
      }
      await s.call("macInput", "ops", { event: EV.down(0.5, 0.5, 3), now: 5000 });
      await s.call("macInput", "ops", { event: EV.key("down", "AltLeft", "Alt", 1), now: 5001 });
      await s.call("macInput", "release");
      await s.call("winInput", "ops", { event: EV.down(0.5, 0.5, 3) });
      await s.call("winInput", "ops", { event: EV.key("down", "ControlRight", "Control", 2) });
      await s.call("winInput", "release");
      await s.call("winInput", "release");
    });
  });

  test("scrcpy's video stream: its device's words, sessions and packets as they come in pieces; a preview's count", async () => {
    await both("scrcpy", async (s) => {
      await s.new("scrcpy", { inst: "st" });
      const session = Buffer.alloc(12);
      session[0] = 0x80;
      session.writeUInt32BE(1080, 4);
      session.writeUInt32BE(2400, 8);
      const packet = (flags: number, pts: bigint, data: number[]) => {
        const head = Buffer.alloc(12);
        head.writeBigUInt64BE(pts | (BigInt(flags) << 56n), 0);
        head.writeUInt32BE(data.length, 8);
        return Buffer.concat([head, Buffer.from(data)]);
      };
      const all = Buffer.concat([Buffer.from([0]), Buffer.alloc(64, 65), Buffer.from("h264"), session, packet(0x40, 0n, [0, 0, 0, 1, 0x67, 1, 2, 3, 0, 0, 1, 0x68, 4]), packet(0x20, 1234567n, [0, 0, 1, 0x65, 7]), packet(0, 1240000n, [0, 0, 1, 0x41, 8, 8])]);
      for (let at = 0; at < all.length; at += 7) await s.call("st", "heard", { data: b64(all.subarray(at, at + 7)) });
      await s.new("peeks", { inst: "pk", most: 2 });
      for (const f of ["take", "take", "take", "running", "free", "free", "free", "running", "take"]) await s.call("pk", f);
    });
  });

  test("still.fail Helper's view: its info, configs and frames as they come in pieces, the part of the display each shows, its input, clipboard, pointer, windows, turn and sound; refused, or gone as it opens", async () => {
    await both("helperView", helperViewScenario);
  });

  test("still.fail Helper: installed and started, asked, watched, started again when it ends by itself, its new code put in", async () => {
    await both("helperApp", helperAppScenario);
  });

  test("the helper's grants: looked at, the window up for one once a while, a person's own ask, the LAN's, a disk's", async () => {
    await both("grants", grantsScenario);
  });

  test("a helper that cannot start (no one signed in to the Mac's desktop): tried again only SHOWN_MS after the last try as pages read the grants, at once when asked, its copy not compared again", async () => {
    const { ts, mb } = await both("grantsStuck", grantsStuckScenario);
    for (const side of [ts, mb]) {
      const opens = side.trace.filter((e: Json) => e.t === "exec" && e.file === "open").length;
      assert.equal(opens, 4, "started once at the first read, once SHOWN_MS after, once a refresh, once a request");
      assert.equal(Buffer.from(side.files[`/data/helper/${APP.slice(APP.lastIndexOf("/") + 1)}/Contents/MacOS/stillfail-helper`].data, "base64").toString(), "release Contents/MacOS/stillfail-helper");
    }
  });

  test("a helper LaunchServices will not start: why said once, not by the addresses in it, never with its token; again once the reason changes or it answered between", async () => {
    const { ts, mb } = await both("grantsRefused", grantsRefusedScenario);
    for (const side of [ts, mb]) {
      const tokens: string[] = side.trace.filter((e: Json) => e.t === "exec" && e.file === "open").flatMap((e: Json) => (e.args as string[]).filter((a) => a.startsWith("STILLFAIL_HELPER_TOKEN=")).map((a) => a.slice(a.indexOf("=") + 1)));
      assert.ok(tokens.length > 0 && tokens[0]!.length === 64, "the app was started with its token");
      const logs = side.trace.filter((e: Json) => e.t === "log");
      for (const token of new Set(tokens)) assert.ok(!JSON.stringify(logs).includes(token), "no log says the token");
      assert.ok(!JSON.stringify(logs).includes("--env"), "no log says the command line");
      const said = logs.filter((e: Json) => e.message === "still.fail Helper did not answer").map((e: Json) => e.fields.error);
      assert.deepEqual(said, [
        LS_REFUSED("0x7a68c38ff0"),
        "LSOpenURLsWithRole() failed with error -610",
        LS_REFUSED("0x7a68c3dff0"),
        "open was ended (SIGTERM)",
      ]);
    }
  });

  test("the Mac's desktop: its grants asked for, a view through the helper, started again for a grant, refused when it cannot be seen", async () => {
    await both("desktop", desktopScenario);
  });

  test("the drive's protected folders through the helper: grants learnt, refusals, streams read and written", async () => {
    await both("files", filesScenario);
  });

  test("Windows' desktop: stillfail-screen asked, a view that outlives its process, the display's scale and resolution set and put back", async () => {
    await both("windows", windowsScenario);
  });

  test("the iOS Simulators: listed as they boot and shut down, their case and buttons drawn, a view through the helper, their apps' logs, settings, installs, recordings", async () => {
    await both("simulators", simulatorsScenario);
  });

  test("a simulator's case from Xcode's DeviceKit: laid out, drawn turned and kept, a composite's or of pieces", async () => {
    await both("chrome", chromeScenario);
  });

  test("Android's devices on adb: followed as they come and go, looked at once booted, a view through scrcpy with its input, previews counted", async () => {
    await both("android", androidScenario);
  });

  test("the X11 desktop: its access, a JPEG view and an H.264 one with xdotool's input, what ends them said", async () => {
    await both("x11", x11Scenario);
  });

  test("the Linux screen tools: prepared from APT under the station's data, stopped as it closes; an X11 desktop that takes them as it opens", async () => {
    await both("linuxTools", linuxToolsScenario);
  });

  test("the Linux desktop: the user's session found through logind, its X11 or Wayland desktop taken", async () => {
    await both("session", sessionScenario);
  });

  test("the portal's desktop: a person's consent waited for, JPEG pictures, input in order, what ends it", async () => {
    await both("portal", portalScenario);
  });

  test("agent-desktop started by the station: its envelope, an error's, one that takes too long", async () => {
    await both("ui", uiScenario);
  });

  test("the station's own files through the shell's (host_io): as fs/promises takes them, on a real folder", async () => {
    const ops = (dir: string): Json[] => [
      { op: "write", path: `${dir}/a.txt`, data: b64(Buffer.from("hello world")), mode: 0o600 },
      { op: "read", path: `${dir}/a.txt` },
      { op: "read", path: `${dir}/none` },
      { op: "readAt", path: `${dir}/a.txt`, offset: 6, length: 100 },
      { op: "writeAt", path: `${dir}/a.txt`, offset: 6, data: b64(Buffer.from("there")) },
      { op: "append", path: `${dir}/a.txt`, data: b64(Buffer.from("!")) },
      { op: "read", path: `${dir}/a.txt` },
      { op: "create", path: `${dir}/b` },
      { op: "create", path: `${dir}/b` },
      { op: "access", path: `${dir}/a.txt`, mode: 4 },
      { op: "access", path: `${dir}/a.txt`, mode: 1 },
      { op: "access", path: `${dir}/none`, mode: 0 },
      { op: "mkdir", path: `${dir}/d/e`, recursive: true },
      { op: "mkdir", path: `${dir}/d`, recursive: false },
      { op: "write", path: `${dir}/d/e/f`, data: b64(Buffer.from("f")) },
      { op: "copyTree", from: `${dir}/d`, to: `${dir}/c` },
      { op: "readdir", path: `${dir}/c/e` },
      { op: "readdir", path: dir },
      { op: "readdir", path: `${dir}/none` },
      { op: "rename", from: `${dir}/b`, to: `${dir}/b2` },
      { op: "rename", from: `${dir}/none`, to: `${dir}/x` },
      { op: "lstat", path: `${dir}/b2` },
      { op: "stat", path: `${dir}/none` },
      { op: "unlink", path: `${dir}/b2` },
      { op: "unlink", path: `${dir}/b2` },
      { op: "rm", path: `${dir}/none`, force: true },
      { op: "rm", path: `${dir}/none` },
      { op: "rm", path: `${dir}/c`, recursive: true, force: true },
      { op: "mkdtemp", prefix: `${dir}/.apt-` },
      { op: "exists", path: `${dir}/a.txt` },
      { op: "exists", path: `${dir}/none` },
      { op: "readSync", path: `${dir}/a.txt` },
    ];
    const base = realFs.mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? realTmpdir(), "mbhostfs-"));
    realFs.mkdirSync(`${base}/ts`);
    realFs.mkdirSync(`${base}/mb`);
    const ts = nodeFs(ops(`${base}/ts`));
    const side = new MbSide(program!);
    await side.open();
    const mb = side.cmd("worldly", { fn: "hostFs", args: { ops: ops(`${base}/mb`) } });
    await mb.promise;
    current = null;
    // (the time a file was last written is the machine's, each its own)
    const timeless = (v: Json) => JSON.parse(JSON.stringify(v, (k, x) => (k === "mtimeMs" ? 0 : x)));
    assert.deepStrictEqual(timeless(mb.ok), timeless(ts));
    realFs.rmSync(base, { recursive: true, force: true });
  });

  test("the hub: sources listed in a person's words, who is on each, one person drives at a time, views ended and made to only look, the browser's tabs and what each source can do", async () => {
    await both("hub", hubScenario);
  });
}


// ---------------------------------------------------------------------------------------------------------------
// The stateful parts, each scenario its own world

const u32 = (...ns: number[]) => Buffer.concat(ns.map((n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; }));
const frameMsg = (key: boolean, ts: number, data: number[]) => { const b = Buffer.alloc(9); b[0] = key ? 1 : 0; b.writeBigUInt64BE(BigInt(ts), 1); return hm(3, Buffer.concat([b, Buffer.from(data)])); };
const audioMsg = (ts: number, n: number) => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(ts)); return hm(9, Buffer.concat([b, Buffer.alloc(n, 3)])); };
const j = (v: Json) => JSON.stringify(v);

async function helperViewScenario(s: Play) {
  s.w.servers.set("/view.sock", () => {});
  await s.new("helperView", { inst: "v", codec: "h265", audio: true, path: "/view.sock" });
  const c = () => s.w.conns[0]!;
  c().send(hm(1, j({ codec: "h264", width: 1920, height: 1080, encoder: "Apple VideoToolbox (H.264)", regions: true, windows: [{ id: 5, app: "Finder", title: "Home" }, { id: 0 }], window: null, audio: true })));
  await s.settle();
  for (const f of ["ready", "hasAudio", "video", "regions"]) await s.call("v", f);
  await s.call("v", "next");
  c().send(Buffer.concat([hm(2, Buffer.concat([u32(1920, 1080), Buffer.from([1, 2, 3])])), hm(7, j({ region: { x: 0.1, y: 0.1, w: 0.5, h: 0.5 } })), frameMsg(true, 1000, [9, 9])]));
  await s.settle();
  await s.call("v", "next");
  c().send(Buffer.concat([hm(7, j({ region: null })), frameMsg(false, 2000, [8])]).subarray(0, 7));
  await s.settle();
  c().send(Buffer.concat([hm(7, j({ region: null })), frameMsg(false, 2000, [8])]).subarray(7));
  await s.settle();
  await s.call("v", "next");
  c().send(frameMsg(false, 3000, [7]));
  await s.settle();
  await s.call("v", "rate", { bits: 2_000_000.6 });
  await s.call("v", "bounds", { maxWidth: 800.4, maxHeight: 600, region: { x: 0.2, y: 0.2, w: 0.3, h: 0.3 } });
  await s.call("v", "bounds", { maxWidth: 800, maxHeight: 600 });
  for (const [event, now] of INPUTS.slice(0, 8)) { s.w.now += now; await s.call("v", "input", { event }); }
  await s.call("v", "setClipboard", { clip: { type: "text", text: "copied" }, paste: true });
  await s.call("v", "watchClipboard");
  c().send(Buffer.concat([hm(5, Buffer.concat([Buffer.from([1]), Buffer.from("from the mac")])), hm(5, Buffer.from([2])), hm(5, Buffer.from([3, 1]))]));
  await s.settle();
  await s.call("v.unwatchClipboard", "close");
  await s.call("v", "watchCursor");
  c().send(Buffer.concat([hm(6, j({ x: 0.5, y: 0.25, shape: "pointer" })), hm(6, j({ x: 2, y: 0 })), hm(6, j({ x: 0.1, y: 0.1, shape: "Not A Shape" })), hm(6, "junk")]));
  await s.settle();
  await s.call("v", "watchWindows");
  c().send(Buffer.concat([hm(4, j({ windows: [{ id: 9, app: "Mail", title: "Inbox" }] })), hm(4, j({ window: 9 })), hm(4, j({ said: "a log line" }))]));
  await s.settle();
  await s.call("v", "window", { id: 9 });
  await s.call("v", "window", { id: 99 });
  await s.call("v", "window", {});
  await s.call("v", "watchTurn");
  c().send(Buffer.concat([hm(10, j({ turn: 1 })), hm(10, j({ turn: 5 }))]));
  await s.settle();
  await s.call("v", "reveal", { path: "/Users/me/Downloads/a.png" });
  await s.call("v", "nextAudio");
  await s.call("v", "nextAudio");
  c().send(Buffer.concat([hm(8, j({ codec: "opus", sampleRate: 48000, channels: 2 })), audioMsg(5000, 200)]));
  await s.settle();
  await s.call("v", "nextAudio");
  c().send(audioMsg(6000, 0));
  await s.settle();
  await s.call("v", "hasAudio");
  await s.call("v", "nextAudio");
  await s.call("v", "keyframe");
  await s.call("v", "next");
  await s.call("v", "close");
  await s.call("v", "next");
  await s.call("v", "close");
  // A view whose helper refuses it, and one whose helper goes as it opens.
  s.w.servers.set("/view2.sock", () => {});
  await s.new("helperView", { inst: "w", codec: "jpeg", input: "win", capture: "Windows.Graphics.Capture", path: "/view2.sock" });
  s.w.conns[1]!.send(hm(1, j({ error: "no display", code: "capture" })));
  await s.settle();
  await s.call("w", "ready");
  await s.call("w", "video");
  await s.call("w", "rate", { bits: 1 });
  await s.call("w", "close");
  s.w.servers.set("/view3.sock", () => {});
  await s.new("helperView", { inst: "x", codec: "jpeg", input: "sim", path: "/view3.sock" });
  await s.call("x", "next");
  await s.call("x", "nextAudio");
  s.w.conns[2]!.close();
  await s.settle();
  await s.call("x", "ready");
  await s.call("x", "next");
}

async function hubScenario(s: Play) {
  await s.new("hub", { inst: "hub", drop: "/home/me/Downloads" });
  await s.call("hub", "onChange", { inst: "hub" });
  await s.call("hub", "watch", { inst: "hub" });
  await s.new("fakeSource", { inst: "tab", spec: { id: "browser:t1", kind: "browser", title: "A tab", width: 1280, height: 800, peek: true, clipboard: ["text"], openedBy: "s1", site: "example.com", sleeping: false, openUrl: true, reload: true, back: true, sleep: true, discard: true, since: 1_799_999_000_000 } });
  await s.new("fakeSource", { inst: "desk", spec: { id: "desktop", title: "Mac", width: 3024, height: 1964, reveal: true, clipboard: ["text", "png"], access: { capture: false, control: true, app: "Ghostty", path: "/Applications/Ghostty.app", asking: true }, panels: [{ width: 1, height: 2, corners: [0.1, 0.1, 0.1, 0.1] }] } });
  await s.new("fakeSource", { inst: "mine", spec: { id: "browser:u_0123456789ab", kind: "browser", title: "Mine", userTab: true, farview: true, forward: true } });
  for (const src of ["tab", "desk", "mine"]) await s.call("hub", "add", { source: src });
  await s.call("hub", "list");
  await s.call("hub", "listed", { lang: "en" });
  await s.call("hub", "setBrowser", { browser: { available: true } });
  await s.call("hub", "listed", { lang: "zh" });
  await s.call("hub", "join", { id: "desktop", as: "a1", watcher: { name: "Alice", label: "a1", control: true, device: "devA", client: "still.fail for Mac", app: "mac", end: true, watchOnly: true } });
  s.w.now += 1000;
  await s.call("hub", "join", { id: "desktop", as: "b1", watcher: { name: "Bob", label: "b1", control: true, device: "devB", self: "mainB", end: true, watchOnly: true } });
  await s.call("hub", "join", { id: "desktop", as: "ag", watcher: { name: "agent: chat", label: "ag", control: true, agent: true } });
  await s.call("hub", "people", { id: "desktop" });
  await s.call("hub", "drive", { id: "desktop", device: "devC", taken: false, by: "Carol" });
  await s.call("hub", "drive", { id: "desktop", device: "devC", taken: true, by: "Carol" });
  await s.call("hub", "mayDrive", { id: "desktop", device: "devA", taken: false });
  s.w.now += 91_000;
  await s.call("hub", "mayDrive", { id: "desktop", device: "devA", taken: false });
  await s.call("hub", "drive", { id: "desktop", device: "devA", taken: false, by: "Alice" });
  await s.call("hub", "join", { id: "desktop", as: "a2", watcher: { name: "Alice", label: "a2", control: true, device: "devA", end: true, watchOnly: true } });
  await s.call("hub", "watchOnly", { id: "desktop", view: "v4" });
  await s.call("hub", "mayDrive", { id: "desktop", device: "devA", taken: true });
  await s.call("hub", "takeControl", { id: "desktop", by: "agent" });
  await s.call("hub", "endView", { id: "desktop", view: "v1", by: "Bob" });
  await s.call("hub", "endView", { id: "desktop", view: "v3", by: "Bob" });
  await s.call("hub", "endView", { id: "desktop", view: "v99", by: "Bob" });
  await s.call("hub", "endView", { id: "nothing", view: "v1", by: "Bob" });
  await s.call("hub", "endViews", { id: "desktop", by: "Dan" });
  await s.call("hub", "leave", { view: "b1" });
  await s.call("hub", "leave", { view: "b1" });
  await s.call("hub", "people", { id: "desktop" });
  await s.call("hub", "openAs", { id: "browser:t1", options: { maxWidth: 640, maxHeight: 480, codecs: ["jpeg"] }, name: "agent: x", control: true, as: "av" });
  await s.call("hub", "people", { id: "browser:t1" });
  await s.call("av", "next");
  await s.call("av", "input", { event: EV.text("hi") });
  await s.call("av", "keyframe");
  await s.call("av", "close");
  await s.call("hub", "openAs", { id: "browser:u_0123456789ab", options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] }, name: "agent", control: false });
  await s.call("hub", "openAs", { id: "nope", options: {}, name: "agent", control: false });
  await s.call("hub", "whenStopping", { label: "stop1" });
  await s.call("hub", "close");
  await s.call("hub", "closeScreen", { id: "browser:t1" });
  await s.call("hub", "closeScreen", { id: "desktop" });
  await s.call("hub", "openBrowser", { url: "https://a", id: "u_00000000000a" });
  await s.call("hub", "openUrl", { id: "browser:t1", url: "https://b" });
  await s.call("hub", "openUrl", { id: "desktop", url: "https://b" });
  await s.call("hub", "reloadScreen", { id: "browser:t1" });
  await s.call("hub", "reloadScreen", { id: "desktop" });
  await s.call("hub", "historyScreen", { id: "browser:t1", delta: -1 });
  await s.call("hub", "historyScreen", { id: "browser:t1", delta: 1 });
  await s.call("hub", "historyScreen", { id: "browser:u_0123456789ab", delta: 1 });
  await s.call("hub", "sleepScreen", { id: "browser:t1" });
  await s.call("hub", "sleepScreen", { id: "desktop" });
  await s.call("hub", "debugOf", { id: "desktop" });
  await s.call("hub", "chromeOf", { id: "desktop", panel: 0, turn: 0 });
  await s.call("hub", "refresher", { label: "r1" });
  await s.call("hub", "refresh");
  await s.call("hub", "changed");
  await s.call("hub", "setBrowser", { browser: null });
  await s.call("hub", "openBrowser", { url: "https://a" });
  await s.call("hub", "remove", { source: "tab" });
  await s.call("hub", "listed", { lang: "en" });
  await s.call("hub", "get", { id: "desktop", as: "got" });
  await s.call("got", "title");
  await s.call("got", "flags");
}


/// still.fail Helper as the world has it: its socket answering a JSON line a connection, the watch kept open, a view's
/// stream for the scenario to fill. `ops` answers an op (none: as Helper does by default); `views` are its streams.
class FakeHelper {
  status: Json = { capture: true, control: true, responsible: { pid: 1, path: "/Applications/Ghostty.app", name: "Ghostty" }, display: { id: 7, width: 3024, height: 1964 }, asking: false, asked: [], files: { documents: "unknown" } };
  pid = 4242;
  up = false;
  readonly watchers: WConn[] = [];
  readonly views: WConn[] = [];
  readonly asked: Json[] = [];
  ops: (op: Json, conn: WConn) => boolean = () => false;
  readonly w: World;
  readonly path: string;
  constructor(w: World, path: string) {
    this.w = w;
    this.path = path;
  }
  start() {
    this.up = true;
    this.w.servers.set(this.path, (conn) => {
      let got = Buffer.alloc(0);
      let first = true;
      conn.onData = (d) => {
        if (!first) return;
        got = Buffer.concat([got, d]);
        const at = got.indexOf(10);
        if (at < 0) return;
        first = false;
        const op = JSON.parse(got.subarray(0, at).toString());
        this.asked.push(op.op);
        this.#answer(op, conn);
      };
    });
  }
  stop() {
    this.up = false;
    this.w.servers.delete(this.path);
    for (const c of this.watchers.splice(0)) c.close();
  }
  line(conn: WConn, v: Json) { conn.send(`${JSON.stringify(v)}\n`); }
  #answer(op: Json, conn: WConn) {
    if (this.ops(op, conn)) return;
    switch (op.op) {
      case "hello": return this.line(conn, { ok: true, pid: this.pid });
      case "status": return this.line(conn, this.status);
      case "watch": this.watchers.push(conn); return this.line(conn, { ok: true });
      case "quit": this.line(conn, { ok: true }); return this.stop();
      case "permissions.show": this.status = { ...this.status, asking: true, asked: op.grants }; return this.line(conn, { ok: true });
      case "ui": return this.line(conn, { out: JSON.stringify({ ok: true, data: { args: op.args } }), status: 0 });
      case "files.access": return this.line(conn, { access: (op.paths as string[]).map((p) => ({ path: p, grant: p.startsWith("/Volumes/Net") ? "network" : p.startsWith("/Volumes") ? "removable" : "documents", state: "unknown" })) });
      case "screen.view":
      case "simulator.view":
        this.views.push(conn);
        return;
    }
    this.line(conn, { error: `no op ${op.op}`, code: "unknown" });
  }
}

const APP = "/rel/still.fail Helper.app";
function helperWorld(w: World) {
  for (const f of ["Contents/MacOS/stillfail-helper", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"]) w.file(`${APP}/${f}`, `release ${f}`);
  w.dir("/data/helper");
  const helper = new FakeHelper(w, "/data/helper/helper.sock");
  w.execRules.push((file, args) => {
    if (file !== "open" || args[0] !== "-n") return undefined;
    helper.start();
    return { stdout: "" };
  });
  return helper;
}

async function helperAppScenario(s: Play) {
  const helper = helperWorld(s.w);
  await s.new("helper", { inst: "h", app: APP, dir: "/data/helper", onBack: true });
  await s.call("h", "pid");
  await s.call("h", "listen");
  await s.call("h", "request", { op: { op: "hello" } });
  await s.call("h", "pid");
  await s.call("h", "request", { op: { op: "nope" } });
  helper.line(helper.watchers[0]!, { event: "grants" });
  helper.watchers[0]!.send("not json\n");
  await s.settle();
  // It ends by itself and comes back by itself; then it ends and does not, and is started again.
  helper.stop();
  await s.settle();
  await s.advance(250);
  helper.start();
  await s.advance(150);
  helper.stop();
  await s.settle();
  await s.advance(3500);
  await s.call("h", "pid");
  // A grant taken: it starts itself again as another process.
  await s.call("h", "restarted", { pid: 4242 });
  await s.advance(200);
  helper.pid = 5000;
  await s.advance(200);
  await s.call("h", "ui", { args: ["snapshot", "--app", "Finder"] });
  await s.call("h", "quit");
  await s.advance(5000);
  // The next process finds the app and its token; the release's code changed: the old one is quit and the new one started.
  s.w.file(`${APP}/Contents/Info.plist`, "release 2");
  helper.start();
  await s.new("helper", { inst: "h2", app: APP, dir: "/data/helper" });
  await s.call("h2", "ensure");
  await s.call("h2", "back");
  helper.stop();
  await s.call("h2", "connect", { op: { op: "screen.view", codec: "h264" }, as: "sock" });
  await s.advance(16_000);
  await s.worldly("install", { app: APP, dir: "/data/helper2" });
  await s.worldly("install", { app: APP, dir: "/data/helper2" });
}

async function grantsScenario(s: Play) {
  const helper = helperWorld(s.w);
  helper.start();
  s.w.reach = "denied";
  s.w.mounts = ["/Volumes/Disk", "/Users/me/OrbStack"];
  s.w.dir("/Volumes/Disk");
  s.w.dir("/Volumes/NetShare");
  s.w.fs.set("/Volumes/Macintosh HD", { kind: "link", to: "/" });
  s.w.file("/data/helper/token", "abc\n");
  await s.new("helper", { inst: "h", app: APP, dir: "/data/helper" });
  await s.new("grants", { inst: "g", helper: "h" });
  await s.call("g", "onChange");
  await s.call("g", "status");
  await s.call("g", "view");
  await s.call("g", "refresh");
  await s.call("g", "view");
  await s.call("g", "state", { grant: "documents" });
  await s.call("g", "state", { grant: "localNetwork" });
  await s.call("g", "refresh");
  s.w.now += 2500;
  helper.status = { ...helper.status, control: false };
  await s.call("g", "refresh");
  await s.call("g", "request", { grant: "capture", words: { title: "t" } });
  await s.call("g", "request", { grant: "control", words: { title: "t" } });
  await s.advance(150);
  await s.call("g", "request", { grant: "control", words: { title: "t" } });
  helper.status = { ...helper.status, asking: false, asked: [] };
  await s.call("g", "request", { grant: "control", words: { title: "t" } });
  await s.call("g", "request", { grant: "control", words: { title: "t" }, again: true });
  await s.advance(2100);
  await s.call("g", "request", { grant: "localNetwork", words: {} });
  await s.call("g", "request", { grant: "localNetwork", words: {} });
  await s.call("g", "request", { grant: "localNetwork", words: {}, again: true });
  await s.call("g", "request", { grant: "removable", words: {} });
  await s.call("g", "request", { grant: "network", words: {} });
  s.w.fs.delete("/Volumes/NetShare");
  s.w.mounts = [];
  await s.call("g", "request", { grant: "network", words: {} });
  s.w.now += 31_000;
  await s.call("g", "view");
  await s.settle();
  helper.line(helper.watchers[0] ?? helper.views[0] ?? ({ send() {} } as Json), { event: "grants" });
  await s.settle();
  await s.new("grants", { inst: "g2", helper: "h", folders: false });
  await s.call("g2", "request", { grant: "documents", words: {} });
  helper.stop();
  await s.new("grants", { inst: "g3", helper: "h" });
  await s.call("g3", "request", { grant: "documents", words: {} });
  await s.advance(16_000);
  await s.call("g3", "show", { grant: "desktop", words: {} });
}

async function grantsStuckScenario(s: Play) {
  helperWorld(s.w);
  // (LaunchServices refuses with no one signed in to the desktop: the app never comes up)
  s.w.execRules.unshift((file, args) => (file === "open" && args[0] === "-n" ? { error: { message: "LSOpenURLsWithRole() failed with error -610", code: 1, signal: null, stdout: "", stderr: "LSOpenURLsWithRole() failed with error -610\n" } } : undefined));
  await s.new("helper", { inst: "h", app: APP, dir: "/data/helper" });
  await s.new("grants", { inst: "g", helper: "h" });
  await s.call("g", "view");
  await s.settle();
  // The release's code changed meanwhile: the copy installed is started again as it is.
  s.w.file(`${APP}/Contents/MacOS/stillfail-helper`, "release 2");
  for (let i = 0; i < 5; i++) await s.call("g", "view");
  await s.settle();
  // (the desktop's screens listed refresh it, not forced: those wait SHOWN_MS after the last try too, as a page's read)
  for (let i = 0; i < 3; i++) await s.call("g", "refresh", { force: false });
  await s.settle();
  s.w.now += 29_999;
  await s.call("g", "view");
  await s.call("g", "refresh", { force: false });
  await s.settle();
  s.w.now += 1;
  await s.call("g", "view");
  await s.call("g", "view");
  await s.call("g", "refresh", { force: false });
  await s.settle();
  await s.call("g", "refresh", { force: true });
  await s.call("g", "request", { grant: "documents", words: {} });
  await s.call("g", "view");
  await s.settle();
}

/// What `open` says where no one is signed in to the desktop: an NSError at an address new at each try.
const LS_REFUSED = (at: string) =>
  `The application cannot be opened for an unexpected reason, error=Error Domain=RBSRequestErrorDomain Code=5 "Launch failed." UserInfo={NSLocalizedFailureReason=Launch failed., NSUnderlyingError=${at} {Error Domain=OSLaunchdErrorDomain Code=125 "Domain does not support specified action" UserInfo={NSLocalizedFailureReason=Domain does not support specified action}}}`;

async function grantsRefusedScenario(s: Play) {
  const helper = helperWorld(s.w);
  // (as Node's execFile fails: its message the command line, the token's `--env` in it, then what `open` said)
  let refusal: ((n: number) => Json) | null = (n) => ({ stderr: `${LS_REFUSED(`0x${(0x7a68c38ff0 + n * 0x1000).toString(16)}`)}\n` });
  let tries = 0;
  s.w.execRules.unshift((file, args) => {
    if (file !== "open" || args[0] !== "-n" || refusal === null) return undefined;
    const r = refusal(tries++);
    return { error: { message: `Command failed: open ${args.join(" ")}\n${r.stderr ?? ""}`, code: r.signal ? null : 1, signal: r.signal ?? null, stdout: "", stderr: r.stderr ?? "" } };
  });
  await s.new("helper", { inst: "h", app: APP, dir: "/data/helper" });
  await s.new("grants", { inst: "g", helper: "h" });
  // Refused again and again, each at an address of its own: said once.
  for (let i = 0; i < 3; i++) await s.call("g", "refresh", { force: true });
  // Another reason: said; and the first again after it.
  refusal = () => ({ stderr: "LSOpenURLsWithRole() failed with error -610\n" });
  await s.call("g", "refresh", { force: true });
  await s.call("g", "refresh", { force: true });
  refusal = (n) => ({ stderr: `${LS_REFUSED(`0x${(0x7a68c38ff0 + n * 0x1000).toString(16)}`)}\n` });
  await s.call("g", "refresh", { force: true });
  await s.call("g", "refresh", { force: true });
  // It started and answered; then it is refused again: said again.
  refusal = null;
  await s.call("g", "refresh", { force: true });
  await s.settle();
  refusal = () => ({ stderr: "", signal: "SIGTERM" });
  helper.stop();
  await s.settle();
  await s.advance(3500);
  await s.call("g", "refresh", { force: true });
  await s.call("g", "refresh", { force: true });
  await s.settle();
}

async function desktopScenario(s: Play) {
  const helper = helperWorld(s.w);
  helper.status = { ...helper.status, control: false };
  await s.new("helper", { inst: "h", app: APP, dir: "/data/helper" });
  await s.new("grants", { inst: "g", helper: "h" });
  await s.new("desktop", { inst: "d", supported: true, helper: "h", grants: "g", title: "My Mac", lang: "zh" });
  for (const f of ["title", "size", "clipboard", "access", "flags"]) await s.call("d", f);
  await s.call("d", "open", { options: { maxWidth: 1920, maxHeight: 1080, codecs: ["vp9"] } });
  await s.call("d", "open", { options: { maxWidth: 1920, maxHeight: 1080, codecs: ["h264", "jpeg"], bitrate: 2e6, fps: 30, audio: true, opus: true, gamut: "p3" }, as: "v" });
  await s.advance(200);
  const view = helper.views[0]!;
  view.send(hm(1, j({ codec: "h264", width: 3024, height: 1964, encoder: "software" })));
  await s.settle();
  await s.call("v", "video");
  await s.call("v", "next");
  view.send(Buffer.concat([hm(2, Buffer.concat([u32(1512, 982), Buffer.from([1])])), frameMsg(true, 10, [1])]));
  await s.settle();
  await s.call("v", "input", { event: EV.down(0.5, 0.5) });
  await s.call("v", "close");
  for (const f of ["size", "access"]) await s.call("d", f);
  // Refused: the helper restarts for a grant and comes back; then capture is off.
  await s.call("d", "open", { options: { maxWidth: 100, maxHeight: 100, codecs: ["jpeg"], peek: true, audio: true } });
  helper.views[1]!.send(hm(1, j({ error: "restart", code: "restart" })));
  await s.settle();
  await s.advance(100);
  helper.views[2]?.send(hm(1, j({ error: "capture off", code: "capture" })));
  await s.settle();
  await s.advance(100);
  helper.status = { ...helper.status, capture: false };
  await s.call("d", "open", { options: { maxWidth: 100, maxHeight: 100, codecs: ["jpeg"] } });
  await s.advance(2500);
  helper.status = { ...helper.status, capture: true, control: true };
  await s.call("d", "helperBack");
  await s.call("d", "open", { options: { maxWidth: 100, maxHeight: 100, codecs: ["jpeg"] }, as: "v2" });
  helper.views.at(-1)!.close();
  await s.settle();
  await s.call("d", "ui", { args: ["tree"] });
  await s.call("d", "close");
  await s.new("desktop", { inst: "d2", supported: false, helper: "h" });
  for (const f of ["access", "clipboard"]) await s.call("d2", f);
  await s.call("d2", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  await s.call("d2", "ui", { args: [] });
  await s.new("desktop", { inst: "d3", supported: true });
  for (const f of ["access", "clipboard", "title"]) await s.call("d3", f);
  await s.call("d3", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  await s.call("d3", "refresh", { force: true });
  await s.call("d3", "close");
}

async function filesScenario(s: Play) {
  const helper = helperWorld(s.w);
  helper.start();
  s.w.file("/data/helper/token", "abc");
  let restarted = false;
  helper.ops = (op, conn) => {
    switch (op.op) {
      case "files.access": helper.line(conn, { access: op.paths.map((p: string) => ({ path: p, grant: p.endsWith("Desktop") ? "desktop" : "documents", state: p.endsWith("Desktop") ? "denied" : "granted" })) }); return true;
      case "files.list":
        if (op.path === "/Users/me/Desktop") { helper.line(conn, { error: "not granted", code: "grant", grant: "desktop", state: "denied", top: "/Users/me/Desktop" }); return true; }
        if (op.path === "/Users/me/Documents/restart" && !restarted) { restarted = true; helper.line(conn, { error: "restart", code: "restart", pid: 4242 }); return true; }
        helper.line(conn, { entries: [{ name: "a.txt", size: "12", mtime: 5, file: true }, { name: "l", link: true, real: "/x", gone: true }, { name: "d", dir: true }], more: true }); return true;
      case "files.names": helper.line(conn, { names: ["a", "b"] }); return true;
      case "files.stat": helper.line(conn, { file: true, size: op.path.endsWith("big") ? 9 : 5, mtime: op.follow ? 10 : 11 }); return true;
      case "files.real": helper.line(conn, { path: `${op.path}/real` }); return true;
      case "files.read": {
        const all = op.path.endsWith("big") ? Buffer.from("123456789") : Buffer.from("hello");
        const part = all.subarray(op.offset, op.offset + op.length);
        conn.send(`${JSON.stringify({ length: op.path.endsWith("short") ? part.length + 3 : part.length, size: all.length, mtime: 10 })}\n`);
        if (part.length > 2) { conn.send(part.subarray(0, 2)); conn.send(part.subarray(2)); } else if (part.length > 0) conn.send(part);
        conn.close();
        return true;
      }
      case "files.write": {
        if (op.atLeast !== undefined) { helper.line(conn, { size: 1 }); return true; }
        helper.line(conn, { size: 0 });
        let got = 0;
        conn.onData = (d) => {
          got += d.length;
          if (got >= op.length) helper.line(conn, { size: op.offset + got });
        };
        return true;
      }
      case "files.trash": helper.line(conn, { to: "/Users/me/.Trash/x" }); return true;
      case "files.search": helper.line(conn, { paths: ["/a", 3, "/b"] }); return true;
      case "files.rename": case "files.mkdir": case "files.remove": case "files.unlink": helper.line(conn, { ok: true }); return true;
    }
    return false;
  };
  await s.new("helper", { inst: "h", app: APP, dir: "/data/helper" });
  // (the grants another helper's: a grant's change on this one's watch is the files' alone to look at again, not two
  // parts' at once, whose requests the two runtimes interleave each their own way)
  const other = new FakeHelper(s.w, "/data/helper2/helper.sock");
  other.start();
  s.w.file("/data/helper2/token", "def");
  for (const f of ["Contents/MacOS/stillfail-helper", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"]) s.w.file(`/data/helper2/still.fail Helper.app/${f}`, `release ${f}`);
  await s.new("helper", { inst: "h2", app: APP, dir: "/data/helper2" });
  await s.new("grants", { inst: "g", helper: "h2" });
  await s.new("files", { inst: "f", helper: "h", grants: "g" });
  await s.call("f", "known", { top: "/Users/me/Documents" });
  await s.call("f", "check", { tops: ["/Users/me/Documents", "/Users/me/Desktop"] });
  await s.call("f", "check", { tops: ["/Users/me/Documents"] });
  await s.call("f", "known", { top: "/Users/me/Documents" });
  await s.call("f", "known", { top: "/Users/me/Desktop" });
  await s.call("f", "fs", { roots: ["/Users/me/Documents"], protect: ["/Users/me/Documents/secret"], as: "fs" });
  await s.call("fs", "list", { dir: "/Users/me/Documents", most: 10 });
  await s.call("fs", "list", { dir: "/Users/me/Desktop", most: 10 });
  await s.call("f", "known", { top: "/Users/me/Desktop" });
  await s.call("fs", "list", { dir: "/Users/me/Documents/restart", most: 10 });
  await s.advance(300);
  for (const [f, a] of [["names", { dir: "/d" }], ["stat", { path: "/Users/me/Documents/a" }], ["lstat", { path: "/a" }], ["real", { path: "/a" }], ["read", { path: "/a", offset: 1, length: 3 }], ["read", { path: "/a/short", offset: 0, length: 5 }], ["readAll", { path: "/Users/me/Desktop/big" }], ["trash", { path: "/a" }], ["rename", { from: "/a", to: "/b" }], ["mkdir", { path: "/n", recursive: true }], ["remove", { path: "/n" }], ["unlink", { path: "/n" }]] as [string, Json][]) await s.call("fs", f, a);
  await s.call("f", "known", { top: "/Users/me/Desktop" });
  s.w.dir("/out");
  await s.call("fs", "copyTo", { path: "/big", to: "/out/big" });
  await s.call("fs", "copyTo", { path: "/big", to: "/out/big" });
  await s.call("fs", "copyTo", { path: "/x/short", to: "/out/short" });
  await s.call("fs", "write", { path: "/w", w: { create: true, offset: 0, data: b64(Buffer.alloc(300_000, 7)), truncate: 300_000, sync: true } });
  await s.call("fs", "write", { path: "/w", w: { create: false, offset: 4, data: b64(Buffer.from("ab")), atLeast: 10 } });
  await s.call("f", "search", { top: "/Users/me/Documents", query: "kMDItemFSName == '*'", most: 5, protect: [] });
  await s.call("f", "ask", { grant: "desktop", top: "/Users/me/Desktop" });
  await s.advance(150);
  helper.line(helper.watchers[0]!, { event: "grants" });
  await s.settle();
}


async function windowsScenario(s: Play) {
  const BIN = "/bin/stillfail-screen.exe";
  const views: WChild[] = [];
  let scale = 150, size = "2560x1440", capture = true;
  s.w.spawnRules.push((c) => {
    if (c.file === "/bin/agent-desktop.exe") { c.says(JSON.stringify({ ok: true, data: { args: c.args } }), 0); return true; }
    if (c.file !== BIN) return;
    const [what, arg] = c.args;
    if (what === "status") c.says(JSON.stringify({ display: { width: Number(size.split("x")[0]), height: Number(size.split("x")[1]) }, capture }));
    else if (what === "scale") { if (arg) scale = Number(arg); c.says(arg === "999" ? JSON.stringify({ error: "no such scale" }) : JSON.stringify({ percent: scale, recommended: 125, steps: [100, 125, 150, 175] })); }
    else if (what === "resolution") { if (arg) size = arg; c.says(JSON.stringify({ width: Number(size.split("x")[0]), height: Number(size.split("x")[1]), modes: [{ width: 2560, height: 1440 }, { width: 1920, height: 1080 }] })); }
    else if (what === "view") views.push(c);
    return true;
  });
  await s.new("windows", { inst: "w", binary: BIN, ui: "/bin/agent-desktop.exe", title: "PC" });
  for (const f of ["title", "size", "clipboard", "access", "flags"]) await s.call("w", f);
  await s.call("w", "refresh");
  await s.call("w", "size");
  await s.call("w", "refresh");
  s.w.now += 3000;
  await s.call("w", "open", { options: { maxWidth: 1280, maxHeight: 720, codecs: ["h265", "h264"], audio: true, opus: true, bitrate: 1.5e6 }, as: "v" });
  views[0]!.out(hm(1, j({ codec: "h265", width: 2560, height: 1440, encoder: "NVIDIA HEVC", audio: true })));
  await s.settle();
  for (const f of ["has", "video", "regions"]) await s.call("v", f);
  await s.call("v", "rate", { bits: 3e6 });
  await s.call("v", "bounds", { maxWidth: 1000, maxHeight: 500, region: { x: 0.5, y: 0.5, w: 0.25, h: 0.25 } });
  await s.call("v", "watchClipboard");
  await s.call("v", "watchCursor");
  await s.call("v", "next");
  views[0]!.out(Buffer.concat([hm(2, Buffer.concat([u32(1280, 720), Buffer.from([4, 5])])), frameMsg(true, 100, [1, 2]), hm(5, Buffer.concat([Buffer.from([1]), Buffer.from("win clip")])), hm(6, j({ x: 0.3, y: 0.4, shape: "text" }))]));
  await s.settle();
  await s.call("v", "input", { event: EV.key("down", "KeyC", "c", 2) });
  await s.call("v", "setClipboard", { clip: { type: "png", data: b64(Buffer.from([137, 80])) }, paste: false });
  await s.call("v", "reveal", { path: "C:\\Users\\me\\a.txt" });
  // Its process ends by itself: started again, the clipboard watched again, from a key frame with its config.
  await s.call("v", "next");
  views[0]!.close(0);
  await s.settle();
  views[1]!.out(hm(1, j({ codec: "h264", width: 2560, height: 1440, encoder: "Microsoft H.264 (software)" })));
  await s.settle();
  views[1]!.out(Buffer.concat([hm(2, Buffer.concat([u32(1000, 500), Buffer.from([6])])), frameMsg(true, 200, [3])]));
  await s.settle();
  await s.call("v", "video");
  await s.call("v", "nextAudio");
  await s.call("v", "scale");
  await s.call("w", "scale");
  await s.call("w", "setScale", { percent: 174.6 });
  await s.call("w", "setScale", { percent: 999 });
  await s.call("w", "resolution");
  await s.call("w", "setResolution", { width: 1920.4, height: 1080 });
  await s.call("w", "size");
  // It keeps ending: the view ends; the display put back as it was.
  for (let i = 1; i <= 4; i++) {
    await s.call("v", "next");
    if (!views[i]) break;
    views[i]!.close(1);
    await s.settle();
    if (views[i + 1]) { views[i + 1]!.out(hm(1, j({ codec: "h264", width: 1, height: 1 }))); await s.settle(); }
  }
  await s.call("v", "next");
  await s.advance(2500);
  await s.call("w", "scale");
  await s.call("w", "resolution");
  await s.call("w", "ui", { args: ["snapshot", "-i"] });
  // A view that does not start, and a Windows without the capture.
  await s.call("w", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  views.at(-1)!.close(1);
  await s.settle();
  await s.call("w", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["vp8"] } });
  capture = false;
  await s.new("windows", { inst: "w2", binary: BIN });
  await s.call("w2", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  await s.call("w2", "access");
  await s.call("w2", "title");
  await s.new("windows", { inst: "w3" });
  for (const f of ["access", "clipboard"]) await s.call("w3", f);
  await s.call("w3", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  await s.call("w3", "ui", { args: [] });
  await s.call("w", "close");
}

const UDID = "0123ABCD-0123-0123-0123-0123456789AB";
const SIMCTL = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl";

/// A device type's bundle, its device's case in Xcode's DeviceKit, `sips` drawing a page as a picture of its size.
function simWorld(w: World) {
  const bundle = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17.simdevicetype";
  const res = `${bundle}/Contents/Resources`;
  w.file(`${res}/framebufferMask.pdf`, maskPdf(390, 844, 55));
  w.file(`${res}/sensor_bar.pdf`, maskPdf(200, 30, 10, false));
  w.file(`${res}/framebufferMask2.pdf`, maskPdf(10, 10, 8));
  const chrome = "/Library/Developer/DeviceKit/Chrome/phone12.devicechrome/Contents/Resources";
  w.file(`${chrome}/chrome.json`, JSON.stringify({ images: { composite: "PhoneComposite", sizing: { leftWidth: 20, topHeight: 20, rightWidth: 20, bottomHeight: 20 }, devicePadding: { left: 4, top: 4, right: 4, bottom: 4 } }, inputs: [{ name: "lock", image: "Lock", imageDown: "LockDown", anchor: "right", align: "leading", offsets: { normal: { x: 1, y: 100 }, rollover: { x: 3, y: 100 } }, usagePage: 12, usage: 48 }, { name: "home", image: "Home", imageDown: "HomeDown", imageDownDrawMode: "compositeUnder", anchor: "bottom", align: "center", onTop: true, offsets: { normal: { x: 0, y: -50 } } }, { name: "volume", image: "Missing", anchor: "left" }] }));
  w.file(`${chrome}/PhoneComposite.pdf`, maskPdf(430, 884, 60));
  w.file(`${chrome}/Lock.pdf`, Buffer.from("%PDF /MediaBox [0 0 6 40]"));
  w.file(`${chrome}/LockDown.pdf`, Buffer.from("%PDF /MediaBox [0 0 6 40]"));
  w.file(`${chrome}/Home.pdf`, Buffer.from("%PDF /MediaBox [0 0 30 30] /Rotate 90"));
  w.file(`${chrome}/HomeDown.pdf`, Buffer.from("%PDF /MediaBox [0 0 30 30]"));
  w.dir("/tmp/cache");
  w.execRules.push((file, args) => {
    if (file !== "sips") return undefined;
    const from = args[args.length - 3]!, out = args[args.length - 1]!;
    const pdf = w.fs.get(from);
    if (pdf?.kind !== "file") return { error: { message: `sips: no ${from}`, code: 1, signal: null, stdout: "", stderr: "Error" } };
    const box = /\/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)/.exec(pdf.data.toString("latin1"));
    let [pw, ph] = box ? [Number(box[1]), Number(box[2])] : [10, 10];
    const z = args.indexOf("-Z");
    if (z >= 0) { const longest = Number(args[z + 1]); const k = longest / Math.max(pw, ph); pw = Math.round(pw * k); ph = Math.round(ph * k); }
    w.file(out, PNG_RED(Math.max(1, Math.round(pw)), Math.max(1, Math.round(ph)), from.includes("Composite") ? [0, 0, 0, 255] : [200, 100, 50, 128]));
    return { stdout: "" };
  });
  return { bundle, res };
}

async function simulatorsScenario(s: Play) {
  const helper = helperWorld(s.w);
  helper.start();
  s.w.file("/data/helper/token", "abc");
  const { bundle } = simWorld(s.w);
  const devices = "/home/me/Library/Developer/CoreSimulator/Devices";
  s.w.dir(`${devices}/${UDID}`);
  s.w.dir(`${devices}/not-a-device`);
  let booted = true;
  const listed = () => JSON.stringify({ devices: { "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [{ state: booted ? "Booted" : "Shutdown", udid: UDID, name: "iPhone 17", deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", lastUsedAt: "2026-11-06T08:34:52.120Z" }] } });
  const streams: WChild[] = [];
  const recorders: WChild[] = [];
  s.w.spawnRules.push((c) => {
    if (c.args.includes("stream")) { streams.push(c); return true; }
    if (c.args.includes("recordVideo")) {
      recorders.push(c);
      c.onKill = (sig) => {
        if (sig !== "SIGINT") return;
        const file = c.args.at(-1)!;
        const box = (kind: string, body: Buffer) => { const h = Buffer.alloc(8); h.writeUInt32BE(8 + body.length); h.write(kind, 4, "latin1"); return Buffer.concat([h, body]); };
        const tkhd = Buffer.alloc(84);
        tkhd.writeUInt32BE(1170 << 16, 76);
        tkhd.writeUInt32BE(2532 << 16, 80);
        const hdlr = Buffer.concat([Buffer.alloc(8), Buffer.from("vide"), Buffer.alloc(12)]);
        s.w.file(file, Buffer.concat([box("ftyp", Buffer.from("isom")), box("moov", Buffer.concat([box("mvhd", Buffer.alloc(100)), box("trak", Buffer.concat([box("tkhd", tkhd), box("mdia", box("hdlr", hdlr))]))]))]));
        c.close(0);
      };
      c.out("Recording started\n");
      return true;
    }
  });
  s.w.execRules.push((file, args) => {
    if (file === SIMCTL && args[0] === "list" && args[2] === "devices") return { stdout: listed() };
    if (file === SIMCTL && args[0] === "list" && args[2] === "devicetypes") return { stdout: JSON.stringify({ devicetypes: [{ identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", bundlePath: bundle }] }) };
    if (file === "plutil" && args.at(-1)!.endsWith("capabilities.plist")) return { stdout: JSON.stringify({ capabilities: { ScreenDimensionsCapability: { "main-screen-width": 1170, "main-screen-height": 2532, "main-screen-scale": 3 }, displays: [{ displayType: "integrated", hasDigitizer: true, chromeIdentifier: "com.apple.dt.devicekit.chrome.phone12", framebufferMaskIdentifier: "framebufferMask", width: 1170, height: 2532, scale: 3 }] } }) };
    if (file === "plutil" && args.at(-1)!.endsWith("profile.plist")) return { stdout: JSON.stringify({ sensorBarImage: "sensor_bar" }) };
    if (file === "plutil" && args.at(-1)!.endsWith("Info.plist")) return { stdout: JSON.stringify({ CFBundleIdentifier: "com.me.app" }) };
    if (file === "/bin/sh") return { stdout: JSON.stringify({ "com.me.app": { ApplicationType: "User", CFBundleDisplayName: "Mine" }, "com.apple.mobilesafari": { ApplicationType: "System" } }) };
    if (file === SIMCTL && args[0] === "spawn" && args[2] === "launchctl") return { stdout: "UIKitApplication:com.me.app[1a][rb]\n" };
    if (file === SIMCTL && args[0] === "ui") return { stdout: args[2] === "appearance" ? "dark\n" : "large\n" };
    if (file === SIMCTL && args[0] === "spawn" && args[2] === "notifyutil" && args[3] === "-g") return { error: { message: "notifyutil failed", code: 1, signal: null, stdout: "", stderr: "x" } };
    if (file === SIMCTL && args[0] === "io" && args[2] === "enumerate") return { stdout: "Device Name: primary-1\nUI Orientation: Landscape Left\n" };
    if (file === "ditto") {
      const out = args[3]!;
      if (args[2]!.includes("bad")) return { error: { message: "ditto: bad", code: 1, signal: null, stdout: "", stderr: "bad zip" } };
      s.w.dir(`${out}/Payload/Mine.app`);
      s.w.file(`${out}/Payload/Mine.app/Info.plist`, "plist");
      return { stdout: "" };
    }
    if (file === SIMCTL) return { stdout: "" };
    return undefined;
  });
  await s.new("hub", { inst: "hub" });
  await s.call("hub", "watch", { inst: "hub" });
  await s.new("helper", { inst: "h", app: APP, dir: "/data/helper" });
  await s.new("simulators", { inst: "sims", hub: "hub", helper: "h", devices });
  await s.call("sims", "start");
  await s.call("hub", "list");
  await s.call("hub", "listed", { lang: "en" });
  await s.call("hub", "get", { id: `simulator:${UDID}`, as: "sim" });
  for (const f of ["title", "size", "since", "flags"]) await s.call("sim", f);
  await s.call("hub", "chromeOf", { id: `simulator:${UDID}`, panel: 0, turn: 1 });
  await s.call("hub", "chromeOf", { id: `simulator:${UDID}`, panel: 0, turn: 1 });
  await s.call("hub", "chromeOf", { id: `simulator:${UDID}`, panel: 3, turn: 1 });
  await s.call("sim", "open", { options: { maxWidth: 1170, maxHeight: 2532, codecs: ["h264", "jpeg"], fps: 60 }, as: "sv" });
  await s.advance(200);
  helper.views[0]!.send(hm(1, j({ codec: "h264", width: 1170, height: 2532, encoder: "HEVC" })));
  await s.settle();
  for (const event of [EV.down(0.5, 0.99), EV.move(0.5, 0.5, 1), EV.up(0.5, 0.4), EV.key("down", "KeyH", "h", 12)]) await s.call("sv", "input", { event });
  await s.call("sv", "watchTurn");
  helper.views[0]!.send(hm(10, j({ turn: 3 })));
  await s.settle();
  await s.call("sv", "close");
  // Its apps' logs and debugging.
  await s.call("sim", "debug", { as: "dbg" });
  await s.call("dbg", "logs", { after: 0 });
  streams[0]!.out('{"eventMessage":"one","processImagePath":"/C/Containers/Bundle/Application/X/Mine.app/Mine","timestamp":"t1","messageType":"Default"}\nnot json\n{"eventMessage":"tw');
  streams[0]!.out('o","messageType":"Error"}\n');
  await s.settle();
  await s.call("dbg", "logs", { after: 0 });
  await s.call("dbg", "logs", { after: 1 });
  for (const [f, a] of [["apps", {}], ["relaunch", { app: "com.me.app" }], ["relaunch", { app: "com.not.there" }], ["relaunch", { app: "-bad" }], ["settings", {}], ["setSetting", { name: "appearance", value: "light" }], ["setSetting", { name: "textSize", value: "huge" }], ["openUrl", { url: "myapp://x?y=1" }], ["openUrl", { url: "not a url" }], ["location", { at: " 35.68 , 139.76 " }], ["location", { at: "91,0" }], ["location", { at: "1,2,3" }], ["location", {}], ["statusBar", { tidy: true }], ["statusBar", {}], ["push", { app: "com.me.app", text: "hello" }], ["push", { app: "com.me.app", text: " " }], ["installFolder", {}], ["uninstall", { app: "com.me.app" }], ["biometrics", { what: "enrol" }], ["biometrics", { what: "match" }], ["biometrics", { what: "dance" }]] as [string, Json][]) await s.call("dbg", f, a);
  s.w.file("/tmp/stillfail-sim-install/My.ipa", "zip");
  s.w.file("/tmp/stillfail-sim-install/bad.zip", "zip");
  await s.call("dbg", "install", { path: "/tmp/stillfail-sim-install/My.ipa" });
  await s.call("dbg", "install", { path: "/tmp/stillfail-sim-install/bad.zip" });
  await s.call("dbg", "install", { path: "/tmp/elsewhere/My.ipa" });
  await s.call("dbg", "install", { path: "/tmp/stillfail-sim-install/x.txt" });
  await s.call("dbg", "recordStart", { panel: "inner" });
  await s.call("dbg", "recording");
  await s.call("dbg", "recordStart", { panel: null });
  await s.call("dbg", "recordStop");
  await s.call("dbg", "recordStop");
  await s.call("dbg", "screenshot");
  await s.advance(200);
  helper.views.at(-1)!.send(Buffer.concat([hm(1, j({ codec: "jpeg", width: 1170, height: 2532 })), hm(2, u32(1170, 2532))]));
  await s.settle();
  helper.views.at(-1)!.send(frameMsg(true, 1, [0xff, 0xd8, 0xff, 0xd9]));
  await s.settle();
  s.w.execRules.unshift((file, args) => (file === "sips" && args.at(-1)!.endsWith(".png") && args.includes("format") && args[3]!.endsWith(".jpg") ? (s.w.file(args.at(-1)!, "a png"), { stdout: "" }) : undefined));
  await s.settle();
  await s.call("hub", "openUrl", { id: `simulator:${UDID}`, url: "https://still.fail" });
  await s.call("hub", "openUrl", { id: `simulator:${UDID}`, url: "nope" });
  await s.call("sim", "discard");
  // It shuts down: CoreSimulator rewrites its device.plist, and it leaves the list once that settles.
  booted = false;
  s.w.watchChanged(`${devices}/${UDID}`, "device.plist");
  s.w.watchChanged(`${devices}/${UDID}`, "data");
  await s.settle();
  await s.advance(100);
  s.w.watchChanged(devices, null);
  await s.settle();
  await s.advance(400);
  await s.call("hub", "list");
  await s.call("sims", "close");
  await s.advance(700_000);
}

async function chromeScenario(s: Play) {
  const { bundle, res } = simWorld(s.w);
  await s.worldly("chromeOf", { display: { chrome: "com.apple.dt.devicekit.chrome.phone12", mask: "framebufferMask", width: 1170, height: 2532, scale: 3 }, bundle: res, sensor: "sensor_bar", root: "/Library/Developer/DeviceKit/Chrome", cache: "/tmp/cache", as: "c" });
  await s.call("c", "told");
  for (const turn of [0, 2]) await s.call("c", "pictures", { turn, cache: "/tmp/cache" });
  await s.worldly("chromeOf", { display: { chrome: "bad/name", mask: null, width: 1, height: 1, scale: 1 }, bundle, sensor: null, root: "/Library/Developer/DeviceKit/Chrome", cache: "/tmp/cache" });
  await s.worldly("chromeOf", { display: { chrome: "phone13", mask: null, width: 1, height: 1, scale: 1 }, bundle, sensor: null, root: "/Library/Developer/DeviceKit/Chrome", cache: "/tmp/cache" });
  // A case of pieces, its sides stretched, no mask.
  const sliced = "/Library/Developer/DeviceKit/Chrome/tablet.devicechrome/Contents/Resources";
  const names = ["TL", "T", "TR", "R", "BR", "B", "BL", "L"];
  s.w.file(`${sliced}/chrome.json`, JSON.stringify({ images: { topLeft: "TL", top: "T", topRight: "TR", right: "R", bottomRight: "BR", bottom: "B", bottomLeft: "BL", left: "L", sizing: { leftWidth: 10, topHeight: 10, rightWidth: 10, bottomHeight: 10 } } }));
  for (const n of names) s.w.file(`${sliced}/${n}.pdf`, Buffer.from(`%PDF /MediaBox [0 0 10 10]`));
  await s.worldly("chromeOf", { display: { chrome: "tablet", mask: null, width: 60, height: 90, scale: 3 }, bundle, sensor: null, root: "/Library/Developer/DeviceKit/Chrome", cache: "/tmp/cache2", as: "t" });
  await s.call("t", "pictures", { turn: 3, cache: "/tmp/cache2" });
  await s.worldly("turnMovie", { file: "/nothing.mp4", turn: 1 });
}


async function androidScenario(s: Play) {
  const ADB = "/sdk/platform-tools/adb";
  const servers: WChild[] = [];
  let tracker: WChild | null = null;
  let phoneBooted = false;
  s.w.spawnRules.push((c) => {
    if (c.file !== ADB) return;
    const a = c.args;
    if (a[0] === "track-devices") { tracker = c; return true; }
    const serial = a[1], rest = a.slice(2);
    const cmd = rest.join(" ");
    if (cmd === "shell getprop sys.boot_completed") c.says(serial === "R5CT" && !phoneBooted ? "0\n" : "1\n");
    else if (cmd.startsWith("shell getprop ro.serialno")) c.says(serial === "R5CT" ? "R5CT\nSM-S938\n15\nMy Phone\n" : "EMULATOR36X\nsdk_gphone64_arm64\n16\nnull\n");
    else if (cmd === "emu avd name") c.says("Pixel_9_API_36\nOK\n");
    else if (cmd === "shell wm size") c.says(serial === "R5CT" ? "Physical size: 1440x3120\nOverride size: 1080x2340\n" : "Physical size: 1080x2400\n");
    else if (cmd === "shell dumpsys display") { if (serial === "R5CT") c.says("", 1, "dumpsys: not allowed"); else c.says("mBaseDisplayInfo=DisplayInfo{real 1080 x 2400, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=120}, RoundedCorner{position=TopRight, radius=120}, RoundedCorner{position=BottomRight, radius=120}, RoundedCorner{position=BottomLeft, radius=120}]}}\n"); }
    else if (rest[0] === "push") c.says("1 file pushed\n");
    else if (cmd === "forward tcp:0 localabstract:" + rest[2]?.split(":")[1]) c.says("40123\n");
    else if (rest[0] === "forward" && rest[1] === "tcp:0") c.says("40123\n");
    else if (rest[0] === "shell" && rest[1]?.startsWith("CLASSPATH=")) servers.push(c);
    else if (cmd === "emu kill") c.says("OK\n");
    else c.says("");
    return true;
  });
  s.w.execRules.push((file) => (file === "ps" ? { stdout: "Fri Nov  6 16:34:52 2026 /opt/emulator/qemu/qemu-system-aarch64 -port 5554 -avd Pixel\n" } : undefined));
  let accepted = 0;
  const video: WConn[] = [];
  s.w.servers.set("tcp:40123", (conn) => {
    accepted++;
    if (accepted === 1) { conn.close(); return; }
    video.push(conn);
  });
  await s.new("hub", { inst: "hub" });
  await s.call("hub", "watch", { inst: "hub" });
  await s.new("androids", { inst: "a", hub: "hub", adb: ADB, file: "/srv/scrcpy-server", lookAgain: 3000 });
  await s.call("a", "start");
  const say = (lines: string) => tracker!.out(`${lines.length.toString(16).padStart(4, "0")}${lines}`);
  say("emulator-5554\tdevice product:sdk_gphone64_arm64 model:x\nR5CT\tdevice usb:1\nadb-X._adb-tls-connect._tcp\tdevice\n");
  await s.settle();
  await s.call("hub", "list");
  await s.advance(3000);
  phoneBooted = true;
  await s.advance(3000);
  await s.call("hub", "listed", { lang: "en" });
  await s.call("a", "refresh");
  await s.call("hub", "get", { id: "android:emulator-5554", as: "emu" });
  for (const f of ["title", "size", "since", "flags"]) await s.call("emu", f);
  await s.call("emu", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  await s.call("emu", "open", { options: { maxWidth: 1080, maxHeight: 2400, codecs: ["h264"], fps: 30 }, as: "v" });
  await s.advance(100);
  const head = Buffer.concat([Buffer.from([0]), Buffer.alloc(64, 0x41), Buffer.from("h264")]);
  const session = Buffer.alloc(12);
  session[0] = 0x80;
  session.writeUInt32BE(1080, 4);
  session.writeUInt32BE(2400, 8);
  const packet = (flags: number, pts: bigint, data: number[]) => { const h = Buffer.alloc(12); h.writeBigUInt64BE(pts | (BigInt(flags) << 56n)); h.writeUInt32BE(data.length, 8); return Buffer.concat([h, Buffer.from(data)]); };
  video[0]!.send(head.subarray(0, 1));
  await s.settle();
  video[0]!.send(Buffer.concat([head.subarray(1), session, packet(0x40, 0n, [0, 0, 0, 1, 0x67, 0x42, 0, 0x1e, 0, 0, 1, 0x68, 1])]));
  await s.settle();
  await s.call("v", "next");
  video[0]!.send(packet(0x20, 1000n, [0, 0, 1, 0x65, 9]));
  await s.settle();
  video[0]!.send(packet(0, 900n, [0, 0, 1, 0x41, 8]));
  await s.settle();
  await s.call("v", "next");
  for (const event of [EV.down(0.5, 0.5), EV.move(0.6, 0.6, 1), EV.up(0.6, 0.6), EV.wheel(0.5, 0.5, 0, 300), EV.text("hi"), EV.key("down", "KeyH", "h", 12), { t: "device", name: "rotate" }]) await s.call("v", "input", { event });
  await s.call("v", "keyframe");
  await s.call("v", "video");
  // A turned picture: its shape as the listing has it.
  const turned = Buffer.alloc(12);
  turned[0] = 0x80;
  turned.writeUInt32BE(2400, 4);
  turned.writeUInt32BE(1080, 8);
  video[0]!.send(turned);
  await s.settle();
  await s.call("emu", "size");
  for (let i = 0; i < 32; i++) video[0]!.send(packet(0, BigInt(2000 + i), [0, 0, 1, 0x41, i]));
  await s.settle();
  await s.call("v", "next");
  await s.call("v", "close");
  await s.call("v", "next");
  // Previews: at most two at once.
  await s.call("hub", "get", { id: "android:R5CT", as: "phone" });
  for (const f of ["title", "size", "since", "flags"]) await s.call("phone", f);
  await s.call("phone", "open", { options: { maxWidth: 320, maxHeight: 640, codecs: ["h264"], peek: true }, as: "p1" });
  await s.call("phone", "open", { options: { maxWidth: 320, maxHeight: 640, codecs: ["h264"], peek: true }, as: "p2" });
  await s.call("phone", "open", { options: { maxWidth: 320, maxHeight: 640, codecs: ["h264"], peek: true }, as: "p3" });
  servers[1]?.close(0);
  await s.settle();
  await s.advance(16_000);
  await s.call("emu", "discard");
  // The phone leaves adb; then adb's tracking ends and is started again.
  say("emulator-5554\tdevice\n");
  await s.settle();
  await s.call("hub", "list");
  tracker!.close(0);
  await s.settle();
  await s.advance(5000);
  say("");
  await s.settle();
  await s.call("hub", "list");
  await s.advance(600_000);
  await s.call("a", "close");
  await s.call("hub", "list");
  await s.worldly("emulatorStart", { serial: "emulator-5554" });
  await s.worldly("emulatorStart", { serial: "R5CT" });
}

const ENV = { DISPLAY: ":0", PATH: "/usr/bin:/bin", HOME: "/home/me" };

function x11World(w: World) {
  w.file("/usr/bin/ffmpeg", "elf", 0o755);
  w.file("/usr/bin/xdotool", "elf", 0o755);
  w.file("/usr/bin/notexec", "x", 0o644);
  const captures: WChild[] = [];
  w.execRules.push((file, args) => {
    if (file.endsWith("xdotool") && args[0] === "getdisplaygeometry") return { stdout: "1920 1080\n" };
    if (file.endsWith("xdotool")) return { stdout: "" };
    if (file.endsWith("ffmpeg") && args.includes("-encoders")) return { stdout: " V....D libx264              libx264 H.264\n" };
    return undefined;
  });
  w.spawnRules.push((c) => {
    if (c.file.endsWith("ffmpeg")) { captures.push(c); return true; }
  });
  return captures;
}

const flvTag = (type: number, payload: Buffer) => { const h = Buffer.alloc(11); h[0] = type; h.writeUIntBE(payload.length, 1, 3); return Buffer.concat([h, payload, Buffer.alloc(4)]); };
const FLV_HEAD = Buffer.concat([Buffer.from("FLV"), Buffer.from([1, 1]), u32(9), u32(0)]);

async function x11Scenario(s: Play) {
  const ffmpegs = x11World(s.w);
  await s.new("x11", { inst: "x", env: { PATH: "/usr/bin" }, title: "Linux" });
  for (const f of ["access", "size", "title"]) await s.call("x", f);
  await s.call("x", "refresh");
  await s.call("x", "access");
  await s.new("x11", { inst: "x2", env: { DISPLAY: ":0", WAYLAND_DISPLAY: "wayland-0" } });
  await s.call("x2", "refresh", { force: true });
  await s.call("x2", "access");
  await s.call("x2", "open", { options: { maxWidth: 10, maxHeight: 10, codecs: ["jpeg"] } });
  await s.new("x11", { inst: "x3", env: { DISPLAY: ":0", PATH: "/nowhere" } });
  await s.call("x3", "refresh", { force: true });
  await s.call("x3", "access");
  await s.new("x11", { inst: "d", env: ENV });
  await s.call("d", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["vp9"] } });
  await s.call("d", "open", { options: { maxWidth: 1280, maxHeight: 800, codecs: ["jpeg"], fps: 60 }, as: "v" });
  await s.call("d", "size");
  const jpeg = (n: number) => Buffer.concat([Buffer.from([0xff, 0xd8]), Buffer.alloc(n, n), Buffer.from([0xff, 0xd9])]);
  ffmpegs[0]!.out(Buffer.concat([Buffer.from("junk"), jpeg(3).subarray(0, 3)]));
  await s.settle();
  ffmpegs[0]!.out(Buffer.concat([jpeg(3).subarray(3), jpeg(4), jpeg(5).subarray(0, 4)]));
  await s.settle();
  await s.call("v", "next");
  await s.call("v", "next");
  ffmpegs[0]!.out(jpeg(5).subarray(4));
  await s.settle();
  for (const f of ["video", "why", "has"]) await s.call("v", f);
  for (const event of [EV.move(0.5, 0.5), EV.down(0.5, 0.5, 1), EV.move(0.6, 0.6, 3), EV.up(0.6, 0.6, 0), EV.wheel(0.5, 0.5, -250, 2100), EV.key("down", "KeyC", "c", 2), EV.key("down", "ShiftLeft", "Shift", 8), EV.key("down", "KeyA", "A", 8), EV.key("up", "KeyA", "A", 8), EV.key("down", "Unknown", "é", 0), EV.text("hello wörld")]) await s.call("v", "input", { event });
  await s.call("v", "close");
  await s.call("v", "why");
  // One that ends by itself, saying why; one that never shows a picture.
  await s.call("d", "open", { options: { maxWidth: 640, maxHeight: 400, codecs: ["jpeg"] }, as: "v2" });
  ffmpegs[1]!.out(jpeg(1));
  await s.settle();
  ffmpegs[1]!.err("x11grab: cannot open display\n");
  ffmpegs[1]!.close(1);
  await s.settle();
  await s.call("v2", "next");
  await s.call("v2", "why");
  await s.call("d", "open", { options: { maxWidth: 640, maxHeight: 400, codecs: ["jpeg"] } });
  await s.advance(10_000);
  // H.264: the newest raw picture encoded when a frame is asked for.
  await s.call("d", "open", { options: { maxWidth: 64, maxHeight: 36, codecs: ["h264"], bitrate: 200_000 }, as: "h" });
  const raw = (v: number) => Buffer.alloc(64 * 36 * 1.5, v);
  const cap = ffmpegs[3]!;
  cap.out(raw(1).subarray(0, 1000));
  await s.settle();
  cap.out(Buffer.concat([raw(1).subarray(1000), raw(2).subarray(0, 10)]));
  await s.settle();
  const enc = ffmpegs[4]!;
  enc.out(Buffer.concat([FLV_HEAD, flvTag(18, Buffer.from("meta")), flvTag(9, Buffer.concat([Buffer.from([0x17, 0, 0, 0, 0]), Buffer.from([1, 0x42])])), flvTag(9, Buffer.concat([Buffer.from([0x17, 1, 0, 0, 0]), Buffer.from([0, 0, 0, 1, 0x65])]))]));
  await s.settle();
  await s.call("h", "next");
  await s.call("h", "next");
  cap.out(raw(2).subarray(10));
  await s.settle();
  enc.out(flvTag(9, Buffer.concat([Buffer.from([0x27, 1, 0, 0, 0]), Buffer.from([0, 0, 0, 1, 0x41])])));
  await s.settle();
  await s.call("h", "rate", { bits: 50_000_000 });
  await s.advance(5000);
  await s.call("h", "next");
  cap.out(raw(3));
  await s.settle();
  await s.call("h", "keyframe");
  for (const f of ["video", "why"]) await s.call("h", f);
  enc.close(0);
  ffmpegs[5]?.err("encoder failed");
  ffmpegs[5]?.close(1);
  await s.settle();
  await s.call("h", "why");
  await s.call("h", "close");
  // An ffmpeg without libx264: a view that takes only H.264 is refused; one that takes JPEG too has JPEG.
  s.w.execRules.unshift((file, args) => (file.endsWith("ffmpeg") && args.includes("-encoders") ? { stdout: "nothing\n" } : undefined));
  s.w.file("/opt/ff/ffmpeg", "elf", 0o755);
  await s.new("x11", { inst: "e", env: ENV, ffmpeg: "/opt/ff/ffmpeg", xdotool: "/usr/bin/xdotool" });
  await s.call("e", "open", { options: { maxWidth: 64, maxHeight: 36, codecs: ["h264"] } });
  await s.call("e", "close");
  await s.call("d", "close");
}

async function linuxToolsScenario(s: Play) {
  s.w.file("/usr/bin/apt-get", "elf", 0o755);
  s.w.file("/usr/bin/dpkg-deb", "elf", 0o755);
  s.w.dir("/data");
  let fail = false;
  s.w.spawnRules.push((c) => {
    const name = c.file.split("/").pop();
    if (name === "apt-get") {
      const archives = c.args.find((a) => a.startsWith("Dir::Cache::archives="))!.split("=")[1]!;
      if (fail) { c.onKill = () => c.close(null, "SIGKILL"); return true; }
      s.w.file(`${archives}/xdotool_1.deb`, "deb");
      s.w.file(`${archives}/ffmpeg_7.deb`, "deb");
      s.w.file(`${archives}/lock`, "x");
      c.out("Get:1 http://deb ffmpeg\n");
      c.close(0);
      return true;
    }
    if (name === "dpkg-deb") {
      const root = c.args[2]!;
      if (c.args[1]!.includes("ffmpeg")) s.w.file(`${root}/usr/bin/ffmpeg`, "elf", 0o755);
      else s.w.file(`${root}/usr/bin/xdotool`, "elf", 0o755);
      c.close(0);
      return true;
    }
    if (name === "ffmpeg" && c.args.includes("-devices")) { c.says("Devices:\n D  x11grab         X11 screen capture\n"); return true; }
    if (name === "xdotool" && c.args[0] === "--version") { c.says("xdotool version 3\n"); return true; }
  });
  s.w.execRules.push((file, args) => (file.endsWith("xdotool") && args[0] === "getdisplaygeometry" ? { stdout: "1280 800\n" } : file.endsWith("xdotool") ? { stdout: "" } : undefined));
  await s.new("tools", { inst: "t", data: "/data" });
  await s.call("t", "prepared", { env: ENV });
  await s.call("t", "canPrepare", { env: ENV });
  await s.call("t", "canPrepare", { env: { PATH: "/nowhere" } });
  await s.call("t", "prepare", { env: ENV });
  await s.call("t", "prepared", { env: { ...ENV, LD_LIBRARY_PATH: "/opt/lib" } });
  await s.call("t", "prepare", { env: ENV });
  await s.worldly("executable", { name: "ffmpeg", env: { PATH: "/data/screen-tools/apt/root/usr/bin:/usr/bin" } });
  await s.worldly("executable", { name: "/usr/bin/notexec", env: {} });
  // An X11 desktop whose machine has neither: the station's own pair prepared as it is first opened.
  s.w.fs.delete("/data/screen-tools/apt/ready");
  await s.new("tools", { inst: "t2", data: "/data" });
  await s.new("x11", { inst: "x", env: { DISPLAY: ":1", PATH: "/usr/bin" }, tools: "t2", prepareWaitMs: 1000 });
  await s.call("x", "refresh", { force: true });
  await s.call("x", "access");
  await s.call("x", "open", { options: { maxWidth: 640, maxHeight: 400, codecs: ["jpeg"] }, as: "v" });
  await s.call("x", "access");
  await s.call("v", "close");
  // A preparation that is stopped as the station closes.
  fail = true;
  s.w.fs.delete("/data/screen-tools/apt/ready");
  await s.new("tools", { inst: "t3", data: "/data" });
  await s.call("t3", "prepare", { env: ENV });
  await s.call("t3", "close");
  await s.settle();
  await s.call("t3", "prepare", { env: ENV });
  await s.advance(200_000);
}

async function sessionScenario(s: Play) {
  const uid = process.getuid?.() ?? 0;
  let kind = "x11";
  s.w.execRules.push((file, args) => {
    if (file === "loginctl" && args[0] === "list-sessions") return { stdout: `  c1 ${uid} me seat0 tty2\n  c2 ${uid + 1} other\n bad\n  c3 ${uid} me\n` };
    if (file === "loginctl" && args[0] === "show-session") return args[1] === "c1" ? { stdout: `User=${uid}\nType=${kind}\nClass=user\nActive=yes\nRemote=no\nDisplay=:1\n` } : { stdout: `User=${uid}\nType=x11\nClass=user\nActive=yes\nRemote=yes\n` };
    if (file === "systemctl") return kind === "x11" ? { stdout: "DISPLAY=:1\nXAUTHORITY=/run/user/x/auth\nWAYLAND_DISPLAY=w\n" } : { error: { message: "no systemd", code: 1, signal: null, stdout: "", stderr: "" } };
    return undefined;
  });
  s.w.dir(`/run/user/${uid}/bus`);
  await s.worldly("desktopEnvironment", { base: { DISPLAY: ":0", XAUTHORITY: "/old", WAYLAND_DISPLAY: "x", HOME: "/home/me" } });
  kind = "wayland";
  await s.worldly("desktopEnvironment", { base: { DISPLAY: ":0", XAUTHORITY: "/old", HOME: "/home/me" } });
  kind = "x11";
  s.w.execRules.unshift((file) => (file === "systemctl" ? { error: { message: "no", code: 1, signal: null, stdout: "", stderr: "" } } : undefined));
  s.w.file("/home/me/.Xauthority", "a");
  await s.worldly("desktopEnvironment", { base: { DISPLAY: ":0", HOME: "/home/me" } });
  s.w.execRules.unshift((file) => (file === "loginctl" ? { error: { message: "no logind", code: 1, signal: null, stdout: "", stderr: "" } } : undefined));
  await s.worldly("desktopEnvironment", { base: { DISPLAY: ":9" } });
  // The Linux desktop: its session found as it is asked for, X11's tools, else GStreamer's.
  s.w.execRules.shift();
  s.w.execRules.shift();
  x11World(s.w);
  await s.new("linux", { inst: "l", data: "/data", env: { DISPLAY: ":0", PATH: "/usr/bin" }, title: "Box" });
  for (const f of ["title", "access", "size"]) await s.call("l", f);
  await s.call("l", "refresh");
  for (const f of ["access", "size"]) await s.call("l", f);
  await s.call("l", "refresh");
  s.w.now += 3000;
  kind = "wayland";
  await s.call("l", "refresh");
  await s.call("l", "access");
  await s.call("l", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  await s.call("l", "close");
}

async function portalScenario(s: Play) {
  s.w.file("/srv/linux-portal.py", "py");
  const helpers: WChild[] = [];
  s.w.spawnRules.push((c) => {
    if (c.file === "/usr/bin/python3") { helpers.push(c); return true; }
  });
  const msg = (v: Json) => hm(1, j(v));
  await s.new("gst", { inst: "g", env: { WAYLAND_DISPLAY: "wayland-0" }, helper: "/srv/linux-portal.py", title: "Wayland" });
  for (const f of ["access", "size", "title"]) await s.call("g", f);
  await s.call("g", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["h264"] } });
  // The person has not answered the portal's question yet.
  await s.call("g", "open", { options: { maxWidth: 1280, maxHeight: 720, codecs: ["jpeg"] }, as: "v" });
  await s.call("g", "access");
  await s.advance(4000);
  await s.call("g", "access");
  helpers[0]!.out(msg({ type: "ready", width: 2560, height: 1440 }));
  await s.settle();
  await s.call("g", "size");
  await s.call("g", "open", { options: { maxWidth: 1280, maxHeight: 720, codecs: ["jpeg"], fps: 10 }, as: "v" });
  helpers[0]!.out(Buffer.concat([msg({ type: "picture", width: 1280, height: 720 }), hm(2, Buffer.from([0xff, 0xd8, 1, 0xff, 0xd9]))]));
  await s.settle();
  await s.call("v", "next");
  await s.call("v", "next");
  await s.call("v", "keyframe");
  helpers[0]!.out(Buffer.concat([msg({ type: "picture", width: 640, height: 360 }), hm(2, Buffer.from([0xff, 0xd8, 2, 0xff, 0xd9]))]));
  await s.settle();
  await s.call("v", "next");
  for (const event of [EV.down(0.5, 0.5), EV.key("down", "KeyC", "c", 2), EV.key("down", "ControlLeft", "Control", 2), EV.key("down", "KeyV", "v", 2), EV.key("up", "KeyV", "v", 2), EV.key("down", "Unknown", "ß", 0), EV.key("down", "Unknown", "ß", 4), EV.text("x")]) await s.call("v", "input", { event });
  for (const f of ["video", "why"]) await s.call("v", f);
  await s.call("v", "close");
  await s.call("v", "why");
  await s.advance(2000);
  // The portal refuses text; one fails; one never shows a picture.
  await s.call("g", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] }, as: "w" });
  helpers[1]!.out(msg({ type: "ready" }));
  await s.settle();
  helpers[1]!.out(Buffer.concat([msg({ type: "picture", width: 2, height: 2 }), hm(2, Buffer.from([1]))]));
  await s.settle();
  await s.call("w", "next");
  helpers[1]!.out(msg({ type: "input_error", code: "textUnsupported" }));
  await s.settle();
  await s.call("w", "next");
  await s.call("w", "why");
  await s.call("g", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  helpers[2]!.out(msg({ type: "error", message: "the person said no" }));
  await s.settle();
  await s.call("g", "access");
  await s.call("g", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  helpers[3]!.out(msg({ type: "ready", width: 1, height: 1 }));
  await s.settle();
  await s.advance(12_000);
  await s.call("g", "access");
  helpers[3]!.close(null, "SIGTERM");
  await s.call("g", "close");
  await s.advance(3000);
  await s.call("g", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  await s.new("gst", { inst: "x", env: { DISPLAY: ":0" }, mode: "x11", helper: "/srv/none.py", consentWaitMs: 100 });
  await s.call("x", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  s.w.file("/srv/none.py", "py");
  await s.call("x", "open", { options: { maxWidth: 1, maxHeight: 1, codecs: ["jpeg"] } });
  await s.call("x", "access");
  await s.advance(100);
  await s.call("x", "access");
  helpers.at(-1)!.out(Buffer.from([7, 0, 0, 0, 0]));
  await s.settle();
  await s.call("x", "access");
}

async function uiScenario(s: Play) {
  s.w.spawnRules.push((c) => {
    if (c.file === "/bin/ad") { c.says(c.args[0] === "bad" ? "" : '{"ok":true,"data":{"tree":{}}}', c.args[0] === "bad" ? 2 : 0); return true; }
    if (c.file === "/bin/slow") return true;
  });
  s.w.file(`${APP}/Contents/Info.plist`, "plist");
  s.w.file("/opt/ad.exe", "exe");
  s.w.file("/opt/screen.exe", "exe");
  await s.worldly("helperApp", { env: { STILLFAIL_HELPER: APP } });
  await s.worldly("helperApp", { env: { STILLFAIL_HELPER: "/nowhere" } });
  await s.worldly("uiBinary", { env: { STILLFAIL_AGENT_DESKTOP: "/opt/ad.exe" } });
  await s.worldly("uiBinary", { env: { STILLFAIL_AGENT_DESKTOP: "/opt/none.exe" } });
  await s.worldly("screenBinary", { env: { STILLFAIL_SCREEN: "/opt/screen.exe" } });
  s.w.fs.delete("/opt/screen.exe");
  await s.worldly("screenBinary", { env: { STILLFAIL_SCREEN: "/opt/screen.exe" } });
  await s.worldly("screenBinary", { env: {} });
  await s.worldly("processUi", { binary: "/bin/ad", args: ["snapshot"] });
  await s.worldly("processUi", { binary: "/bin/ad", args: ["bad"] });
  await s.worldly("processUi", { binary: "/bin/slow", args: [] });
  await s.advance(60_000);
  s.w.children.at(-1)!.close(null, "SIGTERM");
  await s.settle();
}

if (!process.execArgv.includes("--experimental-test-module-mocks")) {
  const skip = readerBinary() === null ? "the MoonBit program (stillfail-reader) is not built here" : false;
  test("the MoonBit screens answer as the TypeScript ones (run with module mocks)", { skip }, async () => {
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
  await main();
  after(() => program?.close());
}
