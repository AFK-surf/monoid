// The agents' tools in MoonBit (station/mb/src/mcp_tools, the reader's `--builder harness-mcp-tools`) held to the
// TypeScript they replace: the MCP endpoint (src/tools/mcp.ts), the agents' door (src/tools/http.ts), every tool of
// src/tools, src/devices/tool.ts, src/rigs/tool.ts, src/search/tool.ts and skills.ts, the device tools
// (src/device/tools.ts), the feedback part and its notice's report (src/feedback). Each case is asked of both, each
// against a world of its own made alike: every answer (an MCP reply's status and JSON, a door's status, headers and
// bytes, a function's result or what it threw) and every call either made of the station's parts must be the same.
//
// The station's parts are the test's world (`World`): a part's method (`hub.store.handedTo`, `jobs.start`) or a
// module's function (`sessions/conversations.chatPost`, `fs.realpath`) is a call the world answers from what it holds,
// as JSON (a part by reference `{"$ref"}`, bytes `{"$bytes"}`, undefined `{"$undef"}`, a call that never answers
// `{"$pending"}`), or a refusal it throws by its class's name. The TypeScript reaches it through module mocks (node:test
// `mock.module`) and through proxies given as the tools' parts; the program through its harness's calls on stdout.
// What only one side asks (`$source`, `$child.next`: what the TypeScript reads of an object it holds), what a view's
// frames come as and the timers' asks (scheduled as each runtime schedules) are answered but not compared.
//
// Module mocks need `--experimental-test-module-mocks`: run without it (as `pnpm test` runs a file), this file runs
// itself again with it, and fails as that run fails.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import * as pathModule from "node:path";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { after, mock, test } from "node:test";

const self = fileURLToPath(import.meta.url);
const station = fileURLToPath(new URL("..", import.meta.url));
const src = (p: string) => new URL(`../src/${p}`, import.meta.url).href;

// ---------------------------------------------------------------------------------------------------------------
// The world

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
type Handler = (args: any[], w: World, name: string) => any;

/// A refusal a part throws: its class's name and what it carries.
class Thrown {
  readonly kind: string;
  readonly fields: Record<string, any>;
  constructor(kind: string, fields: Record<string, any>) {
    this.kind = kind;
    this.fields = fields;
  }
}
const thrown = (kind: string, fields: Record<string, any>) => new Thrown(kind, fields);
const PENDING = { $pending: 1 };
const UNDEF = { $undef: 1 };
const bytes = (s: string) => ({ $bytes: Buffer.from(s).toString("base64") });

/// Calls not compared: what one side alone asks, frames as they come, the timers as each runtime schedules them.
const UNRECORDED = new Set(["$source", "$child.next", "$child.pid", "timers.later", "$child.script"]);
const UNRECORDED_RE = [/\.next$/];

/// What the station's parts hold and answer, for one side.
class World {
  log: [string, Json][] = [];
  readonly handlers = new Map<string, Handler>();
  readonly patterns: [RegExp, Handler][] = [];
  state: Record<string, any> = {};
  on(name: string, h: Handler) {
    this.handlers.set(name, h);
    return this;
  }
  is(name: string, value: any) {
    return this.on(name, () => value);
  }
  match(re: RegExp, h: Handler) {
    this.patterns.unshift([re, h]);
    return this;
  }
  answer(name: string, args: any[]): any {
    if (!UNRECORDED.has(name) && !UNRECORDED_RE.some((re) => re.test(name))) this.log.push([name, args as Json]);
    const h = this.handlers.get(name) ?? this.patterns.find(([re]) => re.test(name))?.[1];
    if (h === undefined) return UNDEF;
    const v = h(args, this, name);
    if (v instanceof Thrown) throw v;
    return v === undefined ? UNDEF : v;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The TypeScript side's way to it

let current: World | null = null;
const world = () => {
  if (current === null) throw new Error("no world");
  return current;
};

const PROXY_NAME = new WeakMap<object, string>();
const proxies = new Map<string, any>();
/// Objects of the test's taken for a part by its reference (a screen's source, a forwarded child).
const CUSTOM = new Map<string, () => any>();
const customs = new Map<string, any>();
function P(name: string): any {
  const made = CUSTOM.get(name);
  if (made !== undefined) {
    if (!customs.has(name)) customs.set(name, named(name, made()));
    return customs.get(name);
  }
  const had = proxies.get(name);
  if (had !== undefined) return had;
  const target = function () {};
  const proxy: any = new Proxy(target, {
    get(_t, prop) {
      if (typeof prop === "symbol" || prop === "then" || prop === "toJSON" || prop === "constructor") return undefined;
      return P(`${name}.${prop}`);
    },
    has: () => true,
    apply(_t, _this, args) {
      return callWorld(name, args);
    },
  });
  PROXY_NAME.set(proxy, name);
  proxies.set(name, proxy);
  return proxy;
}

function named<T extends object>(ref: string, o: T): T {
  PROXY_NAME.set(o, ref);
  return o;
}

/// Calls whose answer the TypeScript side takes as a promise.
const ASYNC = new Set([
  "sessions/review.reviewUndecided", "sessions/others.readAfar", "move.room", "move.scheduler.move", "deviceSessions.start",
  "deviceSessions.say",
]);
const ASYNC_RE: RegExp[] = [/^src:.*\.ui$/, /^platform\/index\.platform\./];
const KIND = Symbol("kind");

function callWorld(name: string, args: unknown[]): any {
  const w = world();
  const encoded = args.map((a) => encode(a, true));
  const isAsync = ASYNC.has(name) || ASYNC_RE.some((re) => re.test(name));
  let out: any;
  try {
    const raw = w.answer(name, encoded);
    if (raw !== null && typeof raw === "object" && "$pending" in raw) return new Promise(() => {});
    out = decode(raw);
  } catch (e) {
    if (isAsync) return Promise.reject(asError(e));
    throw asError(e);
  }
  return isAsync ? Promise.resolve(out) : out;
}

const ERRORS = new Map<string, () => object>();
function asError(e: unknown): unknown {
  if (!(e instanceof Thrown)) return e;
  const proto = ERRORS.get(e.kind)?.() ?? Error.prototype;
  const err = Object.create(proto);
  Object.assign(err, e.fields);
  Object.defineProperty(err, "message", { value: String(e.fields.message ?? ""), enumerable: false, writable: true });
  Object.defineProperty(err, "stack", { value: `${e.kind}: ${e.fields.message}`, enumerable: false, writable: true });
  Object.defineProperty(err, KIND, { value: e.kind, enumerable: false });
  return err;
}

function encode(v: unknown, top = false): Json {
  if (v === undefined) return top ? UNDEF : null;
  if (v !== null && typeof v === "object" && PROXY_NAME.has(v)) return { $ref: PROXY_NAME.get(v)! };
  if (v === null || typeof v === "boolean" || typeof v === "string" || typeof v === "number") return v;
  if (typeof v === "function") {
    const name = PROXY_NAME.get(v);
    return name !== undefined ? { $ref: name } : { $fn: true };
  }
  if (Buffer.isBuffer(v) || v instanceof Uint8Array) return { $bytes: Buffer.from(v).toString("base64") };
  if (v instanceof AbortSignal) return { $signal: true };
  if (Array.isArray(v)) return v.map((x) => encode(x));
  const out: Record<string, Json> = {};
  for (const [k, x] of Object.entries(v as object)) if (x !== undefined) out[k] = encode(x);
  return out;
}

function decode(v: any): any {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(decode);
  if ("$ref" in v && Object.keys(v).length === 1) return P(v.$ref);
  if ("$undef" in v && Object.keys(v).length === 1) return undefined;
  if ("$bytes" in v && Object.keys(v).length === 1) return Buffer.from(v.$bytes, "base64");
  const out: Record<string, any> = {};
  for (const [k, x] of Object.entries(v)) out[k] = decode(x);
  return out;
}

const toStats = (s: any) => ({ ...s, isFile: () => s.file === true, isDirectory: () => s.dir === true, isSymbolicLink: () => s.symlink === true });

/// node:fs/promises, as the world's files.
function fsPromises() {
  const call = (name: string) => async (...args: unknown[]) => callWorld(`fs.${name}`, args);
  const handle = (ref: string) => named(ref, {
    stat: async () => toStats(callWorld(`${ref}.stat`, [])),
    read: async (buf: Buffer, off: number, len: number, pos: number) => {
      const got = callWorld(`${ref}.read`, [off, len, pos]);
      Buffer.from(got.buffer).copy(buf, off, 0, got.bytesRead);
      return { bytesRead: got.bytesRead, buffer: buf };
    },
    close: async () => void callWorld(`${ref}.close`, []),
  });
  return {
    stat: async (p: string) => toStats(callWorld("fs.stat", [p])),
    lstat: async (p: string) => toStats(callWorld("fs.lstat", [p])),
    readdir: async (p: string) => callWorld("fs.readdir", [p]),
    open: async (p: string, flags: string) => handle(PROXY_NAME.get(callWorld("fs.open", [p, flags]))!),
    readFile: call("readFile"), writeFile: call("writeFile"), appendFile: call("appendFile"), mkdir: call("mkdir"),
    rename: call("rename"), access: call("access"), realpath: call("realpath"),
  };
}

/// What the world's children do, as the TypeScript's ChildProcess: their events read from the world one at a time.
let lastWallTimer: (() => void) | null = null;
const children: Promise<void>[] = [];
function fakeChild(ref: string): any {
  const child: any = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.stdin = {
    on: () => child.stdin,
    write: (buf: Buffer, cb: (e?: Error) => void) => {
      try {
        callWorld(`${ref}.stdin.write`, [buf]);
        cb();
      } catch (e) {
        cb(asError(e) as Error);
      }
      return true;
    },
  };
  const w = world();
  child.pid = decode(w.answer("$child.pid", [{ $ref: ref }]));
  named(ref, child);
  children.push(new Promise<void>((done) => {
    const step = () => {
      const ev = decode(w.answer("$child.next", [{ $ref: ref }]));
      if (ev === null || ev === undefined) return done();
      const [kind, data] = ev as [string, any];
      if (kind === "stdout") child.stdout.emit("data", Buffer.from(data, "base64"));
      else if (kind === "stderr") child.stderr.emit("data", Buffer.from(data, "base64"));
      else if (kind === "error") child.emit("error", new Error(data));
      else if (kind === "close") child.emit("close", data);
      else if (kind === "timeout") lastWallTimer?.();
      setImmediate(step);
    };
    setImmediate(step);
  }));
  return child;
}

/// Each module the tools import from outside what they are, as the world answers it.
const MOCKED: [string, string][] = [
  ["sessions/conversations.ts", "sessions/conversations"],
  ["sessions/messages.ts", "sessions/messages"],
  ["sessions/opened.ts", "sessions/opened"],
  ["sessions/chat-archive.ts", "sessions/chat-archive"],
  ["sessions/others.ts", "sessions/others"],
  ["sessions/review.ts", "sessions/review"],
  ["sessions/archive-policy.ts", "sessions/archive-policy"],
  ["screens/hub.ts", "screens/hub"],
  ["screens/ui.ts", "screens/ui"],
  ["jobs/jobs.ts", "jobs/jobs"],
  ["ops/paths.ts", "ops/paths"],
  ["mesh/ways.ts", "mesh/ways"],
  ["helper/files.ts", "helper/files"],
  ["helper/grants.ts", "helper/grants"],
  ["ops/telemetry.ts", "ops/telemetry"],
  ["cloud/signed.ts", "cloud/signed"],
  ["ops/version.ts", "ops/version"],
  ["ops/agent-env.ts", "ops/agent-env"],
  ["ops/log.ts", "ops/log"],
  ["ops/fibers.ts", "ops/fibers"],
  ["ops/processes.ts", "ops/processes"],
  ["ops/shell-path.ts", "ops/shell-path"],
  ["updates/runtimes.ts", "updates/runtimes"],
  ["updates/versions.ts", "updates/versions"],
  ["agents/machine-logins.ts", "agents/machine-logins"],
  ["platform/index.ts", "platform/index"],
];

/// What of a mocked module stays its own: what the program has as its own too.
/// The station's homes taken out of a line of its log, as the world does it (ops/telemetry.ts `scrubPaths`'s part).
const realScrub = (text: string, home: string) => (home !== "" && home !== "/" ? text.split(home).join("~") : text);
const fibersAfter: (() => void)[] = [];

const GRANT_IDS = ["capture", "control", "documents", "desktop", "downloads", "removable", "network", "localNetwork"];
const OVERRIDES: Record<string, Record<string, any>> = {
  "helper/grants": { isGrant: (v: unknown) => typeof v === "string" && GRANT_IDS.includes(v) },
  "ops/fibers": {
    wall: {
      now: () => callWorld("ops/fibers.wall.now", []),
      after: (ms: number, f: () => void) => {
        callWorld("ops/fibers.wall.after", [ms]);
        lastWallTimer = f;
        return () => {};
      },
      within: (_ms: number, p: Promise<unknown>) => p,
    },
    Fibers: class {
      after(ms: number, f: () => void) {
        callWorld("ops/fibers.Fibers.after", [ms, f]);
        fibersAfter.push(f);
      }
      async close() {}
    },
  },
  "ops/processes": {
    startCommand: (sh: string, args: string[], opts: unknown) => {
      const got = callWorld("ops/processes.startCommand", [sh, args, opts]);
      return fakeChild(PROXY_NAME.get(got)!);
    },
  },
};

const isClass = (f: unknown) => typeof f === "function" && /^class[\s{]/.test(Function.prototype.toString.call(f));
const hasFunctions = (o: object) => Object.values(o).some((x) => typeof x === "function");

/// What each mocked module exports, read in a process of its own: importing one here would load the modules under
/// test with the real ones before they are mocked.
type Exported = Record<string, { kind: "function" | "class" | "part" | "value" | "other"; value?: unknown }>;
function exportsOf(): { modules: Record<string, Exported>; runtimes: string[]; stationLang: string } {
  const code = `
    const out = {};
    for (const p of ${JSON.stringify(MOCKED.map(([p]) => src(p)))}) {
      const m = await import(p);
      const e = {};
      for (const [k, v] of Object.entries(m)) {
        const isClass = typeof v === "function" && /^class[\\s{]/.test(Function.prototype.toString.call(v));
        if (isClass) e[k] = { kind: "class" };
        else if (typeof v === "function") e[k] = { kind: "function" };
        else if (v !== null && typeof v === "object" && !Array.isArray(v) && Object.values(v).some((x) => typeof x === "function")) e[k] = { kind: "part" };
        else { try { e[k] = { kind: "value", value: JSON.parse(JSON.stringify(v ?? null)) }; } catch { e[k] = { kind: "other" }; } }
      }
      out[p] = e;
    }
    const { RUNTIME_KINDS } = await import(${JSON.stringify(src("agents/runtime.ts"))});
    const { stationLang } = await import(${JSON.stringify(src("ops/i18n.ts"))});
    process.stdout.write(JSON.stringify({ modules: out, runtimes: RUNTIME_KINDS, stationLang: stationLang() }));`;
  const run = spawnSync(process.execPath, ["--no-warnings", "--input-type=module", "-e", code], { cwd: station, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (run.status !== 0) throw new Error(`the modules' exports were not read: ${run.stderr}`);
  return JSON.parse(run.stdout);
}

/// What the program is as the station finds it (src/read/mb-reader.ts `mbReaderBinary`, said again: importing it
/// here would load what it imports before the mocks).
function readerBinary(): string | null {
  const exe = process.platform === "win32" ? "stillfail-reader.exe" : "stillfail-reader";
  const candidates = [process.env.STILLFAIL_MB_READER, fileURLToPath(new URL(`../src/read/${exe}`, import.meta.url)), fileURLToPath(new URL("../mb/_build/stillfail-reader-darwin-arm64", import.meta.url))];
  return candidates.find((p) => p !== undefined && p !== "" && existsSync(p)) ?? null;
}

async function installMocks(exported: Record<string, Exported>): Promise<void> {
  for (const [path, prefix] of MOCKED) {
    const url = src(path);
    const exports: Record<string, unknown> = {};
    for (const [name, e] of Object.entries(exported[url] ?? {})) {
      if (OVERRIDES[prefix]?.[name] !== undefined) {
        exports[name] = OVERRIDES[prefix]![name];
        continue;
      }
      if (prefix === "platform/index" && name === "platform") {
        const os = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "darwin" : "linux";
        exports[name] = new Proxy({ os, exe: (n: string) => (process.platform === "win32" ? `${n}.exe` : n), paths: pathModule }, {
          get: (t: any, k) => (typeof k === "symbol" || k in t ? t[k] : (...a: unknown[]) => callWorld(`platform/index.platform.${k}`, a)),
        });
        continue;
      }
      if (e.kind === "class") {
        const made = { [name]: class extends Error {} }[name]!;
        exports[name] = made;
        ERRORS.set(name, () => made.prototype);
      } else if (e.kind === "function") exports[name] = (...args: unknown[]) => callWorld(`${prefix}.${name}`, args);
      else if (e.kind === "part") exports[name] = P(`${prefix}.${name}`);
      else exports[name] = e.value;
    }
    mock.module(url, { exports } as never);
  }
  const builtin = async (name: string, over: Record<string, unknown>) => {
    const real = { ...(await import(name)) } as Record<string, unknown>;
    delete real.default;
    const exports = { ...real, ...over };
    mock.module(name, { exports: { ...exports, default: { ...exports } } } as never);
  };
  await builtin("node:crypto", { randomBytes: (n: number) => callWorld("crypto.randomBytes", [n]) });
  await builtin("node:fs", { readFileSync: (p: string, enc: string) => callWorld("fs.readFileSync", [p, enc]) });
  await builtin("node:fs/promises", fsPromises());
  await builtin("node:os", { hostname: () => callWorld("os.hostname", []) });
  await builtin("node:child_process", {
    execFile: (file: string, args: string[], opts: unknown, cb: (e: Error | null, out: string) => void) => {
      try {
        cb(null, callWorld("child_process.execFile", [file, args, opts]));
      } catch (e) {
        cb(asError(e) as Error, "");
      }
    },
  });
  await builtin("node:http", { createServer: (h: unknown) => fakeServer(h) });
}

// ---------------------------------------------------------------------------------------------------------------
// The door's server, without a socket

let doorHandler: ((req: any, res: any) => Promise<void>) | null = null;
let doorUpgrade: ((req: any, socket: any, head: Buffer) => void) | null = null;
function fakeServer(handler: unknown): any {
  doorHandler = handler as never;
  const server: any = new EventEmitter();
  server.on("upgrade", (h: never) => (doorUpgrade = h));
  server.listen = () => setImmediate(() => server.emit("listening"));
  server.address = () => ({ port: 4000 });
  server.close = () => {};
  server.closeIdleConnections = () => {};
  server.closeAllConnections = () => {};
  const on = server.on.bind(server);
  server.on = (ev: string, h: any) => {
    if (ev === "upgrade") doorUpgrade = h;
    return on(ev, h);
  };
  return server;
}

type Asked = { method: string; url: string; headers?: Record<string, string>; body?: string | Buffer };

async function doorTs(a: Asked): Promise<Json> {
  const body = a.body === undefined ? Buffer.alloc(0) : Buffer.from(a.body);
  const req: any = Readable.from(body.length === 0 ? [] : [body]);
  req.method = a.method;
  req.url = a.url;
  req.headers = Object.fromEntries(Object.entries(a.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
  let status = 0;
  let headers: Record<string, string> = {};
  const chunks: Buffer[] = [];
  const res: any = new EventEmitter();
  res.destroyed = false;
  res.headersSent = false;
  res.writableEnded = false;
  res.writeHead = (s: number, h?: Record<string, string>) => {
    status = s;
    headers = h ?? {};
    res.headersSent = true;
    return res;
  };
  res.end = (b?: Buffer | string) => {
    if (b !== undefined) chunks.push(Buffer.from(b));
    res.writableEnded = true;
    return res;
  };
  res.destroy = () => (res.destroyed = true);
  await doorHandler!(req, res);
  return { status, headers, body: Buffer.concat(chunks).toString("base64"), destroyed: res.destroyed };
}

async function upgradeTs(a: Asked): Promise<Json> {
  const req: any = { method: a.method, url: a.url, headers: Object.fromEntries(Object.entries(a.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v])) };
  let ended: Buffer | null = null;
  let destroyed = false;
  const socket: any = { on: () => socket, end: (b: Buffer) => (ended = b), destroy: () => (destroyed = true) };
  doorUpgrade!(req, socket, Buffer.alloc(0));
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
  if (ended !== null) return { refused: (ended as Buffer).toString("base64") };
  if (destroyed) return { destroyed: true };
  return { routed: true };
}

// ---------------------------------------------------------------------------------------------------------------
// The program's side

class Program {
  #proc;
  #waiting = new Map<string, (said: any) => void>();
  #world: World | null = null;
  #next = 0;
  readonly failed: string[] = [];
  constructor(binary: string, shellDir: string) {
    this.#proc = spawn(binary, ["--builder", "harness-mcp-tools", "--shell-dir", shellDir], { stdio: ["pipe", "pipe", "pipe"] });
    this.#proc.stderr.on("data", (b) => this.failed.push(String(b)));
    createInterface({ input: this.#proc.stdout }).on("line", (line) => this.#told(line));
  }
  #told(line: string) {
    const said = JSON.parse(line);
    if ("call" in said) {
      let reply: Record<string, unknown>;
      try {
        reply = { ret: said.call, value: this.#world!.answer(said.name, said.args) };
      } catch (e) {
        if (!(e instanceof Thrown)) throw e;
        reply = { ret: said.call, throw: { kind: e.kind, ...e.fields } };
      }
      this.#proc.stdin.write(`${JSON.stringify(reply)}\n`);
      return;
    }
    const key = "ans" in said ? `ans:${said.ans}` : Object.keys(said)[0]!;
    const w = this.#waiting.get(key);
    if (w) {
      this.#waiting.delete(key);
      w(said);
    }
  }
  #wait(key: string): Promise<any> {
    return new Promise((resolve) => this.#waiting.set(key, resolve));
  }
  use(w: World) {
    this.#world = w;
  }
  async setup(setup: Record<string, unknown>) {
    const ready = this.#wait("ready");
    this.#proc.stdin.write(`${JSON.stringify({ setup })}\n`);
    await ready;
  }
  async ask(kind: string, q: Record<string, unknown>): Promise<any> {
    const id = ++this.#next;
    const got = this.#wait(`ans:${id}`);
    this.#proc.stdin.write(`${JSON.stringify({ [kind]: { ...q, id } })}\n`);
    const said = await got;
    const drained = this.#wait("drained");
    this.#proc.stdin.write(`${JSON.stringify({ drain: true })}\n`);
    await drained;
    const { ans: _, ...rest } = said;
    return rest;
  }
  close() {
    this.#proc.stdin.end();
    this.#proc.kill();
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The base world both sides start each case from

const FRAME = (w: number, h: number, codec = "jpeg") => ({ config: { width: w, height: h, codec }, data: bytes(`frame ${w}x${h}`) });

type Source = { id: string; title: string; size: { width: number; height: number }; userTab?: boolean; access?: any; ui?: (cmd: string[], w: World) => any; frame?: any };
const SOURCES: Source[] = [
  {
    id: "desktop", title: "Desktop", size: { width: 2560, height: 1600 }, access: { capture: true, control: true }, frame: FRAME(1280, 800),
    ui: (cmd) => {
      if (cmd[0] === "list-apps") return { ok: true, data: { apps: [{ name: "Finder", presentation: "foreground" }, { name: "Dock", presentation: "background" }, { name: "Finder", presentation: "foreground" }, { name: "Mail" }] } };
      if (cmd[0] === "snapshot") return { ok: true, data: { snapshot_id: "s7", app: cmd.includes("--app") ? cmd[cmd.indexOf("--app") + 1] : "Finder", window: { id: "w1", title: "Docs" }, complete: !cmd.includes("--skeleton"), tree: { role: "window", cmd } } };
      if (cmd[0] === "type" && cmd[2] === "fail") return { ok: false, error: { code: "STALE_REF", message: "the ref is old", suggestion: "read the tree again", details: { windows: ["w1", "w2"] }, disposition: { retry: "safe" } } };
      if (cmd[0] === "press" && cmd[1] === "x") return { ok: false, error: { disposition: { retry: "unsafe" } } };
      return { ok: true };
    },
  },
  { id: "browser:t1", title: "Docs — Chrome", size: { width: 1366, height: 768 }, frame: FRAME(1280, 720) },
  { id: "browser:png", title: "PNG", size: { width: 800, height: 600 }, frame: FRAME(800, 600, "png") },
  { id: "browser:mine", title: "Mine", size: { width: 800, height: 600 }, userTab: true },
  { id: "simulator:s1", title: "iPhone", size: { width: 0, height: 0 }, access: { capture: true, control: false }, frame: FRAME(390, 844) },
  { id: "simulator:dark", title: "Dark", size: { width: 390, height: 844 } },
  { id: "desktop:locked", title: "Locked", size: { width: 100, height: 100 }, access: { capture: false, control: false }, ui: () => ({ ok: true }) },
];
const sourceOf = (ref: string) => SOURCES.find((s) => `src:${s.id}` === ref);
for (const s of SOURCES) {
  CUSTOM.set(`src:${s.id}`, () => ({
    id: s.id,
    userTab: s.userTab,
    size: (...a: unknown[]) => callWorld(`src:${s.id}.size`, a),
    title: (...a: unknown[]) => callWorld(`src:${s.id}.title`, a),
    ...(s.access !== undefined ? { access: (...a: unknown[]) => callWorld(`src:${s.id}.access`, a) } : {}),
    ...(s.ui !== undefined ? { ui: (...a: unknown[]) => callWorld(`src:${s.id}.ui`, a) } : {}),
  }));
}
CUSTOM.set("ways", () => ({ view: (ws: string) => callWorld("ways.view", [ws]), cloud: P("ways.cloud") }));
CUSTOM.set("ways.cloud", () => ({ get state() { return callWorld("ways.cloud.state", []); } }));
CUSTOM.set("plane.state", () => ({ removed: () => callWorld("plane.state.removed", []), get state() { return callWorld("plane.state.state", []); } }));

const SESSION = { key: "s1", connect: "c1", runtime: "claude", profile: "default", model: "opus", ws: "w1" };
const PLAN = {
  modules: [{ id: "chats" }, { id: "jobs" }, { id: "accounts" }],
  items: [
    { module: "chats", id: "s1", label: "First chat", state: "here", needs: [{ module: "accounts", id: "a1" }], wouldStop: [{ module: "jobs", id: "j1" }], progress: "50%" },
    { module: "chats", id: "s2", label: "A chat whose label is long enough to be cut short at eighty characters, as the summary says", state: "there", needs: [], wouldStop: [], lentTo: "st2" },
    { module: "chats", id: "s3", label: "Third", state: "failed", needs: [], wouldStop: [], error: "disk full", cannot: "it is running" },
    { module: "jobs", id: "j1", label: "build", state: "moving", needs: [], wouldStop: [], waitsFor: { module: "chats", id: "s1" } },
    { module: "accounts", id: "a1", label: "claude", state: "stopped", needs: [], wouldStop: [], cannot: "it is running", leaves: "a copy" },
    { module: "extra", id: "x1", label: "odd", state: "weird", needs: [], wouldStop: [] },
  ],
};
const OUTCOME = {
  done: [{ module: "chats", id: "s1" }],
  refused: [{ item: { module: "chats", id: "s3" }, why: "it is running" }, { item: { module: "jobs", id: "j2" }, why: "it is running" }],
  stopped: [{ item: { module: "jobs", id: "j1" }, waitsFor: { module: "chats", id: "s1" } }],
  resumed: [{ module: "jobs", id: "j3" }],
  failures: [{ item: { module: "accounts", id: "a1" }, error: "x".repeat(100) }],
  returned: [{ module: "chats", id: "s4" }],
  lent: [],
  failed: { item: { module: "accounts", id: "a1" }, error: "x".repeat(100) },
};

function baseWorld(): World {
  const w = new World();
  w.state.views = 0;
  w.state.served = new Set<string>();
  w.state.children = new Map<string, any[]>();
  w.on("mcp.resolve", ([t]) => ({ t1: "s1", t2: "s2", t3: "s3", t4: "s4", t5: "s5", t6: "s6" } as any)[t])
    .is("mcp.gate", UNDEF).is("mcp.listing", UNDEF)
    .on("timers.later", ([ms]) => ms !== 10000 && ms !== 60000)
    .on("$source", ([r]) => {
      const s = sourceOf(r.$ref)!;
      return { id: s.id, userTab: s.userTab === true, access: s.access !== undefined, ui: s.ui !== undefined };
    })
    .on("screens.get", ([id]) => (SOURCES.some((s) => s.id === id) ? { $ref: `src:${id}` } : UNDEF))
    .on("screens.list", () => SOURCES.map((s) => ({ id: s.id })))
    .on("screens.listed", () => ({ screens: SOURCES.map((s) => ({ id: s.id, title: s.title, userTab: s.userTab === true, views: s.id === "desktop" ? [{ id: "v1", name: "Ann", control: true, agent: false, at: 0 }, { id: "v2", name: "agent: x", control: false, agent: true, at: 0 }] : [], ...(s.access && !s.access.control ? { access: { message: "Accessibility is off" } } : {}) })) }))
    .on("screens.people", ([id]) => w.state.people?.[id] ?? { views: [], viewers: [] })
    .on("screens.openAs", ([id]) => ({ $ref: `view:${id}:${++w.state.views}` }))
    .match(/^view:.*\.next$/, (_a, w2, name) => {
      if (w2.state.served.has(name)) return PENDING;
      w2.state.served.add(name);
      return SOURCES.find((s) => name.startsWith(`view:${s.id}:`))?.frame ?? PENDING;
    })
    .match(/^src:.*\.(size|title|access|ui)$/, (a, _w, name) => {
      const s = sourceOf(name.slice(0, name.lastIndexOf(".")))!;
      const what = name.slice(name.lastIndexOf(".") + 1);
      return what === "size" ? s.size : what === "title" ? s.title : what === "access" ? s.access : s.ui!(a[0], _w);
    })
    .on("agentName", ([s]) => `agent: ${s}`)
    .is("base", "https://app.example/w/w1/s/st1")
    .on("screens/hub.viewOn", ([v]) => `still.fail for Mac, opened just now (${v.name})`)
    .on("screens/hub.accessShown", ([a]) => (a !== null && typeof a === "object" && "capture" in a && !(a.capture && a.control) ? { message: `the screen: capture ${a.capture}, control ${a.control}` } : UNDEF))
    .on("screens/ui.treeText", ([t]) => `TREE ${JSON.stringify(t)}`)
    .on("screens.takeControl", () => 2).on("screens.endViews", () => 3)
    .on("hub.store.handedTo", () => null)
    .on("sessions/others.elsewhere", () => null)
    .on("sessions/others.linkedSession", () => null)
    .on("sessions/others.scopeOf", () => ({ workspace: "w1" }))
    .on("sessions/others.chatRead", ([, , a]) => `read ${JSON.stringify(a)}`)
    .on("sessions/others.readAfar", ([, , st, tool, a]) => `afar ${JSON.stringify(st)} ${tool} ${JSON.stringify(a)}`)
    .on("sessions/others.sessionHistory", ([, a]) => `history ${JSON.stringify(a)}`)
    .on("sessions/others.chatList", () => "chats")
    .on("sessions/conversations.target", () => ({ thread: { surface: "slack" }, connect: "c9" }))
    .on("sessions/conversations.unheld", ([, , a]) => ({ args: a }))
    .on("sessions/conversations.mayStage", () => false)
    .on("sessions/conversations.chatPost", ([, , a]) => `posted ${JSON.stringify(a)}`)
    .on("sessions/conversations.chatState", () => "state kept")
    .on("sessions/conversations.chatLeave", () => "left")
    .on("sessions/conversations.chatHistory", () => "history")
    .on("sessions/conversations.slackApi", (a) => `slack ${JSON.stringify(a.slice(2))}`)
    .on("sessions/messages.sessionSend", ([, , a]) => `sent ${JSON.stringify(a)}`)
    .on("sessions/opened.chatCreate", ([, , a]) => `created ${JSON.stringify(a)}`)
    .on("sessions/chat-archive.chatArchive", () => "archived")
    .on("sessions/review.policyWs", () => "w1")
    .on("sessions/archive-policy.currentPolicy", () => ({ policy: "Archive what is done.", options: [{ id: "done", name: "Done", rubric: "finished", archive: true }] }))
    .on("sessions/archive-policy.savePolicy", () => "policy, options")
    .on("remote.tool", ([name, s, a]) => ({ tool: name, session: s, args: a }))
    .on("remote.workspaceStation", ([, n]) => n)
    .on("workspaceWatch.limit", () => 10 * 1024 ** 3)
    .on("jobs.workspace", ([k]) => (k === "s1" || k === "s2" ? `/work/${k}` : null))
    .on("ops/paths.joinPath", ([a, b]) => (b.startsWith("/") ? b : `${a}/${b}`))
    .on("jobs.start", ([, name, cmd, cwd, port, watch, looked]) => ({ id: "job1", name, cmd, cwd, port, watch, looked, sessionKey: "s1", state: "running", log: "/logs/job1" }))
    .on("jobs.view", ([j]) => ({ id: j.id, name: j.name, state: j.state }))
    .on("jobs.store.listJobs", ([k]) => (k === "s1" ? [{ id: "job1", name: "a", state: "running" }, { id: "job2", name: "b", state: "exited" }] : []))
    .on("jobs.store.getJob", ([id]) => (id === "job1" ? { id: "job1", name: "build", port: null, sessionKey: "s1", log: "/logs/job1", state: "running" } : id === "job9" ? { id: "job9", name: "x", port: 3000, sessionKey: "s9" } : null))
    .on("jobs/jobs.tail", ([, n]) => (n === 3 ? "" : `last ${n} lines`))
    .on("jobs/jobs.named", ([j]) => `Job "${j.name}" (${j.id})`)
    .on("jobs.stop", () => ({ id: "job1", name: "build", port: null, state: "stopped" }))
    .on("forwards.list", ([s]) => (s === "s1" ? [{ local: 5432, station: "st2", port: 5432 }] : []))
    .on("forwards.remove", ([, l]) => ({ local: l, station: "st2", port: 22 }))
    .on("forwards.open", (a) => ({ opened: a }))
    .on("retireAsks.tool", ([s, a]) => ({ session: s, args: a }))
    .on("devices.list", ([s]) => (s === "s1" ? [{ id: "d1", name: "Pixel", kind: "adb" }] : []))
    .on("devices.use", (a) => `use ${JSON.stringify(a)}`).on("devices.done", (a) => `done ${JSON.stringify(a)}`)
    .on("rigUse.ask", (a) => `ask ${JSON.stringify(a)}`).on("rigUse.done", (a) => `done ${JSON.stringify(a)}`)
    .on("store.getSession", ([k]) => (k === "s1" ? SESSION : k === "s2" ? { ...SESSION, key: "s2", model: null, ws: null } : null))
    .on("feedback.link", ([k]) => (k === "s1" ? "https://app.example/o/w1/st1/s1" : null))
    .is("feedback.send", { $ref: "feedbackSender" }).is("feedback.reply", { $ref: "feedbackReplier" })
    .on("feedbackSender", () => ({ number: 12 })).on("feedbackReplier", () => ({ id: "r1" }))
    .on("relays.meshList", () => [{ node: "a".repeat(64), name: "office" }])
    .on("relays.enroll", ([workspace, name, by]) => ({ workspace, name, by, token: "private-once" }))
    .on("relays.revoke", ([workspace, node]) => ({ workspace, node, revoked: true }))
    .on("relays.ways", () => ({ $ref: "ways" })).on("relays.workspaceOf", () => "w1").on("relays.by", () => "chat One")
    .on("ways.view", () => ({ relays: [{ url: "https://r1.example/", by: "x" }], off: [] }))
    .on("ways.cloud.state", () => ({ origin: "https://app.still.fail" }))
    .on("mesh/ways.stillFails", () => ["https://euw1-1.relay.still.fail./"])
    .on("mesh/ways.relayUrl", ([u]) => (u.startsWith("https://") ? (u.endsWith("/") ? u : `${u}/`) : null))
    .on("fetch", ([u]) => ({ status: u.endsWith("/relay") ? 426 : 200 }))
    .on("ops/fibers.wall.now", () => (w.state.now = (w.state.now ?? 1000) + 7))
    .on("grants.view", () => ({ grants: [{ grant: "capture", state: "granted" }, { grant: "control", state: "denied" }, { grant: "localNetwork", state: "denied" }, { grant: "documents", state: "unknown" }], asking: ["control"], screen: true, localNetworkName: "stillfail-station" }))
    .on("grants.request", ([g]) => ({ window: g === "documents" ? "granted" : g === "desktop" ? "closed" : g === "removable" ? "none" : "up", screen: g !== "control" }))
    .is("os.hostname", "studio.local")
    .on("helper/files.askWords", ([l]) => ({ lang: l }))
    .on("move.here", () => "st1").on("move.wsOf", ([s]) => (s === "s9" ? null : "w1"))
    .on("move.roster", () => [{ id: "st1", name: "Here" }, { id: "st2xxxxxxxx", name: "Tokyo" }, { id: "st3yyyyyyyy", name: "Office" }])
    .on("move.scheduler.planShown", () => PLAN).on("move.scheduler.plan", () => PLAN)
    .on("move.scheduler.stopped", () => [{ item: { module: "jobs", id: "j1" }, waitsFor: { module: "chats", id: "s1" } }])
    .on("move.scheduler.move", () => OUTCOME).on("move.scheduler.back", () => ({ ...OUTCOME, failures: undefined, refused: [] }))
    .on("move.scheduler.stopTurn", ([s]) => s === "s1")
    .on("move.room", () => ({ sends: "2 GB", known: 1, of: 2, measuring: 1, freeThere: "100 GB", floorThere: "10 GB" }))
    .on("move.refusal", ([, st]) => (st === "st3yyyyyyyy" ? "moving is off on Office" : null))
    .on("move.ask", (a) => ({ asked: a })).on("move.told.asked", (a) => ({ told: a }))
    .on("move.cards.post", () => ({ thread: 7, ts: "1.5" }))
    .on("crypto.randomBytes", ([n]) => ({ $bytes: Buffer.alloc(n, 0xab).toString("base64") }))
    .on("searchDeps.workspaceOf", ([s]) => (s === "s1" ? { workspace: "w1", home: true } : s === "s2" ? { workspace: "w2", home: false } : null))
    .on("searchDeps.readSkill", (a) => `skill ${JSON.stringify(a)}`)
    .on("searchDeps.stations", () => [{ id: "st1", name: "Here", here: true }, { id: "st2", name: "Tokyo", here: false }, { id: "st3", name: "tokyo", here: false }])
    .on("searchDeps.ask", ([st, q]) => (q.method === "skill.read" ? { text: `remote skill ${st}` } : st === "st3" ? thrown("Error", { message: "peer request timed out" }) : { groups: [{ kind: "message", hits: [{ title: "", text: "  remote\n hit  ", chat: "s7", seq: 3 }], more: true }] }))
    .on("searchDeps.search.query", () => ({ groups: [
      { kind: "chat", hits: [{ title: "T", text: "a ".repeat(150), chat: "s1", chatTitle: "Chat One", at: 1794883181032, archived: true }, { title: "U", text: "x", chat: "s9" }] },
      { kind: "skill", hits: [{ title: "stillfail", text: "a skill", skill: "stillfail", path: "skills/stillfail/SKILL.md" }], left: 3 },
      { kind: "job", hits: [{ title: "build", text: "j", job: "job1", port: 3000, index: 4 }] },
    ], building: false }))
    .on("searchDeps.link", ([s]) => (s === "s1" ? "https://app.example/o/w1/st1/s1" : undefined))
    .on("door.peers", () => ({ $ref: "mesh" }))
    .is("door.parts", ["browser"])
    .on("door.peer.request", ([q, t]) => ({ status: 200, headers: { "content-type": "text/html" }, body: Buffer.from(`peer ${q.url} ${t.station}:${t.port}${t.path}`).toString("base64") }))
    .on("door.part.request", ([q, p]) => ({ status: 201, headers: { "x-part": p }, body: Buffer.from(`part ${q.url}`).toString("base64") }))
    .on("door.notified", ([a, b]) => ({ status: 200, body: { auth: a ?? null, said: Buffer.from(b.$bytes, "base64").toString() } }))
    .on("door.screened", () => ({ status: 404, body: { error: "no screen here" } }))
    .on("ops/telemetry.scrubPaths", ([t, h]) => realScrub(t, h))
    .on("device.protect", () => ["/home/u/.stillfail", "/home/u/link"])
    .on("fs.realpath", ([p]) => (p === "/home/u/link" ? "/data/real" : p.startsWith("/home/u/via") ? `/home/u/.stillfail${p.slice("/home/u/via".length)}` : p.startsWith("/gone") ? thrown("Error", { message: "ENOENT", code: "ENOENT" }) : p))
    .is("platform/index.platform.posixShellSoon", "/bin/sh")
    .on("ops/processes.startCommand", (_a, w2) => ({ $ref: `child${(w2.state.child = (w2.state.child ?? 0) + 1)}` }))
    .on("$child.pid", ([r]) => 1000 + Number(r.$ref.slice(5)))
    .on("$child.next", ([r], w2) => {
      const left: any[] = w2.state.children.get(r.$ref) ?? w2.state.script?.(r.$ref) ?? [["stdout", "aGk="], ["close", 0]];
      w2.state.children.set(r.$ref, left);
      return left.length === 0 ? null : left.shift();
    })
    .is("device.now", 1794883181000)
    .on("ops/shell-path.withShellCommand", ([k, env]) => ({ ...env, SHELL_FOR: k }))
    .on("updates/runtimes.findCommandSoon", ([k]) => (k === "claude" ? { onPath: "/usr/local/bin/claude", real: "/opt/claude/bin/claude" } : { onPath: "/usr/local/bin/codex", real: "/opt/codex" }))
    .on("platform/index.platform.runnableSoon", ([f, a]) => ({ file: f, args: a }))
    .on("child_process.execFile", ([f]) => `${f} 2.1.0 (Claude Code)`)
    .on("updates/versions.versionIn", ([s]) => s.split(" ")[1])
    .on("agents/machine-logins.codexAuthFile", () => "/home/u/.codex/auth.json")
    .on("agents/machine-logins.claudeCredentialsFile", () => "/home/u/.claude/.credentials.json")
    .on("fs.access", () => thrown("Error", { message: "ENOENT", code: "ENOENT" }))
    .on("fs.readFile", () => '{"accessToken":"x"}')
    .on("fs.stat", () => ({ file: true, size: 11, mtimeMs: 5.5 }))
    .on("fs.lstat", ([p]) => (p.endsWith("gone") ? thrown("Error", { message: "ENOENT", code: "ENOENT" }) : { file: p.endsWith(".txt"), dir: p.endsWith("dir"), symlink: p.endsWith("ln"), size: 3, mtimeMs: 1794883181000.7, mode: 0o100644 }))
    .on("fs.readdir", ([p]) => (p.endsWith("denied") ? thrown("Error", { message: "EACCES: permission denied", code: "EACCES" }) : ["b.txt", "a dir", "B.ln", "gone", "Z"]))
    .on("fs.open", ([p]) => (p.endsWith("missing") ? thrown("Error", { message: `ENOENT: no such file, open '${p}'`, code: "ENOENT" }) : { $ref: "fh1" }))
    .on("fh1.stat", () => ({ size: 26 }))
    .on("fh1.read", ([, len, pos]) => ({ bytesRead: len, buffer: { $bytes: Buffer.from("abcdefghijklmnopqrstuvwxyz".slice(pos, pos + len)).toString("base64") } }))
    .on("deviceSessions.start", ([a]) => (a.prompt === "fail" ? thrown("Error", { message: "no model", code: "no_model" }) : { session: "s8", thread: "CHAT/8" }))
    .on("deviceSessions.status", ([t]) => (t === "CHAT/8" ? { state: "running" } : null))
    .on("ops/version.version", () => "0.1.9200")
    .on("store.getThread", ([id]) => (id === 7 ? { id: 7, channel: "CHAT", threadTs: "1.0" } : null))
    .on("store.entriesBetween", ([, n]) => (n === 3 ? [{ n: 3, at: 1794883181032, authorKind: "station", text: "⚠️  The turn failed: rate limited.\nTry again." }] : n === 4 ? [{ n: 4, at: 1, authorKind: "user", text: "⚠️ hi" }] : []))
    .on("store.threadSessions", () => [{ session: "s1" }, { session: "s0" }])
    .on("store.failedTurnsNear", ([k]) => (k === "s1" ? [{ summary: { outcome: "failed", endedAt: 1794883180000, startedAt: 1794883100000, kind: "prompt", detail: "API Error: 429 rate limited\nmore" } }, { summary: { outcome: "done", endedAt: 1794883181000 } }] : []))
    .on("store.runtimeSessions", () => ["rt-abc"])
    .on("reportDeps.logTail", () => [
      "2026-11-17T02:38:00.000Z INFO agents::claude session s1 started",
      "2026-11-17T02:39:00.000Z WARN agents::claude rate limited for /Users/ann/x",
      "2026-11-17T02:39:01.000Z WARN agents::claudex not this one",
      "2026-11-17T02:39:02.000Z INFO other rt-abc said hi",
      "not a date s1",
      "2026-11-17T03:39:00.000Z INFO s1 too late",
      "2026-11-17T02:39:03.000Z INFO profile=default here",
    ].join("\n"))
    .on("reportDeps.versions", () => ({ station: "0.1.9200", claude: "2.1.0" }))
    .on("reportDeps.envNames", () => ["ANTHROPIC_BASE_URL", "PATH"])
    .on("reportDeps.link", ([k]) => `https://app.example/o/w1/st1/${k}`)
    .on("feedback.sendReport", ([r]) => (r.key === "fail" ? thrown("Error", { message: "offline" }) : { number: 41, duplicate: true }))
    .on("readCatalog", ([ws]) => ({ skills: [{ name: "stillfail", text: `main of ${ws ?? "home"}`, files: [{ name: "more.md", text: "more" }] }] }))
    .is("agents.updates.channel", "stable").is("plane.spec", { feedback: true })
    .is("plane.state.removed", false).is("plane.state.state", { workspace: "w1" })
    .on("cloud/signed.signedPost", ([, , path, , body]) => (path === "/v1/feedback/fixed" ? { fixed: body.told.length > 0 ? [] : [{ id: "f1", session: "s1", number: 3, title: "T", version: 9100, parts: ["station"], thread: "C/1" }, { id: "f2" }, { session: "s2" }] } : { number: 77 }))
    .is("paths.data", "/data")
    .on("agents.pageOf", ([k]) => (k === "s1" ? "https://app.example/o/w1/st1/s1" : undefined))
    .on("agents.updates.get", () => [{ id: "station", installed: true, version: "0.1.9200" }, { id: "codex", installed: false, version: "1" }, { id: "claude", installed: true, version: "2.1.0" }])
    .on("ops/agent-env.agentEnv", () => ({ PATH: "/bin", ANTHROPIC_BASE_URL: "x" }));
  return w;
}

// ---------------------------------------------------------------------------------------------------------------
// The cases

type Case = { name: string; kind: "mcp" | "door" | "upgrade" | "fn"; q: any; world?: (w: World) => void; unordered?: boolean };
const CASES: Case[] = [];
const call = (name: string, tool: string, args: unknown, token = "t1", world?: (w: World) => void, unordered = false) =>
  CASES.push({ name, kind: "mcp", q: { method: "POST", authorization: `Bearer ${token}`, body: JSON.stringify({ jsonrpc: "2.0", id: CASES.length, method: "tools/call", params: { name: tool, arguments: args } }) }, world, unordered });
const rpc = (name: string, body: unknown, more: { method?: string; authorization?: string | null; world?: (w: World) => void } = {}) =>
  CASES.push({ name, kind: "mcp", q: { method: more.method ?? "POST", authorization: more.authorization === null ? undefined : more.authorization ?? "Bearer t1", body: typeof body === "string" ? body : JSON.stringify(body) }, world: more.world });
const fn = (name: string, f: string, args: unknown[], world?: (w: World) => void, unordered = false) => CASES.push({ name, kind: "fn", q: { name: f, args }, world, unordered });
const door = (name: string, q: Asked, world?: (w: World) => void) => CASES.push({ name, kind: "door", q, world });
const upgrade = (name: string, q: Asked, world?: (w: World) => void) => CASES.push({ name, kind: "upgrade", q, world });

function defineCases() {
  // ── the endpoint
  rpc("not a POST", {}, { method: "GET" });
  rpc("no authorization", {}, { authorization: null });
  rpc("an empty bearer", {}, { authorization: "Bearer   " });
  rpc("a lower-case bearer", { jsonrpc: "2.0", id: 1, method: "ping" }, { authorization: "bearer t1" });
  rpc("an unknown token", { jsonrpc: "2.0", id: 1, method: "ping" }, { authorization: "Bearer nope" });
  rpc("a token alone", { jsonrpc: "2.0", id: 1, method: "ping" }, { authorization: "t2" });
  rpc("not JSON", "{nope");
  rpc("empty", "");
  rpc("a notification", { jsonrpc: "2.0", method: "notifications/initialized" });
  rpc("an array", [1, 2]);
  rpc("null", "null");
  rpc("initialize", { jsonrpc: "2.0", id: "a", method: "initialize", params: { protocolVersion: "2025-03-26" } });
  rpc("initialize, no version", { jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: 5 } });
  rpc("initialize, params not an object", { jsonrpc: "2.0", id: 3, method: "initialize", params: "x" });
  rpc("ping", { jsonrpc: "2.0", id: null, method: "ping" });
  rpc("an unknown method", { jsonrpc: "2.0", id: 4, method: "resources/list" });
  rpc("no method", { jsonrpc: "2.0", id: 5 });
  rpc("a method that is a number", { jsonrpc: "2.0", id: 6, method: 7 });
  rpc("tools/list", { jsonrpc: "2.0", id: 7, method: "tools/list" });
  rpc("tools/list, loaded", { jsonrpc: "2.0", id: 8, method: "tools/list" }, { world: (w) => w.is("mcp.listing", { loaded: { "anthropic/alwaysLoad": true } }) });
  for (const budget of [0, 3000, 12000, 20000, 30000, 45000, 1_000_000])
    rpc(`tools/list within ${budget} bytes`, { jsonrpc: "2.0", id: 9, method: "tools/list" }, { world: (w) => w.is("mcp.listing", { budget }) });
  rpc("tools/list within a budget, loaded", { jsonrpc: "2.0", id: 10, method: "tools/list" }, { world: (w) => w.is("mcp.listing", { budget: 20000, loaded: { x: 1 } }) });
  call("an unknown tool", "nope", {});
  call("no tool named", "", {});
  rpc("tools/call with arguments not an object", { jsonrpc: "2.0", id: 11, method: "tools/call", params: { name: "chat_state", arguments: [1] } });
  rpc("tools/call, no params", { jsonrpc: "2.0", id: 12, method: "tools/call" });
  call("station_tool, nothing named", "station_tool", {});
  call("station_tool, a number named", "station_tool", { name: 5 });
  call("station_tool, an unknown tool", "station_tool", { name: "nope" });
  call("station_tool, a declaration", "station_tool", { name: "relays" });
  call("station_tool, arguments null", "station_tool", { name: "job_list", arguments: null });
  call("station_tool, arguments an array", "station_tool", { name: "job_list", arguments: [] });
  call("station_tool, arguments a string", "station_tool", { name: "job_list", arguments: "x" });
  call("station_tool, run", "station_tool", { name: "job_list", arguments: {} });
  call("station_tool, an outward one refused", "station_tool", { name: "job_start", arguments: { command: "ls" } }, "t1", (w) => w.is("mcp.gate", "out of the workspace"));
  call("an outward tool refused", "chat_post", { to: "C/1", text: "hi" }, "t1", (w) => w.is("mcp.gate", "Refused: no workspace"));
  call("an outward tool let through", "station_list", {}, "t1", (w) => w.is("mcp.gate", UNDEF));
  call("typed arguments", "job_start", { command: "ls", port: " 3000 ", watch: "true", cwd: "sub" });
  call("typed, not what it says", "job_start", { command: "ls", port: "3e3", watch: "yes" });
  call("typed, a negative decimal", "chat_history", { to: "C/1", limit: "-1.5" });
  call("a failing tool", "chat_state", { kind: "all_done" }, "t1", (w) => w.on("sessions/conversations.chatState", () => thrown("Error", { message: "done is required" })));

  // ── chat
  call("chat_post", "chat_post", { to: "C/1", text: "hello", kind: "all_done", done: "merged" });
  call("chat_post, a notice mark", "chat_post", { to: "C/1", text: "a⁣b⁣", kind: "final" });
  call("chat_post, not posted", "chat_post", { to: "C/1", text: "x", kind: "all_done" }, "t1", (w) => w.is("sessions/conversations.chatPost", "Not posted: no"));
  call("chat_post, target refused", "chat_post", { text: "x" }, "t1", (w) => w.on("sessions/conversations.target", () => thrown("Error", { message: "no thread" })));
  call("chat_post, a still.fail chat staged", "chat_post", { to: "E/1", text: "see /Users/a/Desktop/x.png", files: ["/Users/a/Desktop/y.png"] }, "t1", (w) => w
    .is("sessions/conversations.target", { thread: { surface: "ember" } })
    .is("sessions/conversations.mayStage", true)
    .on("sessions/conversations.staged", ([, , a]) => ({ args: { ...a, files: ["/tmp/y.png"] }, done: { $ref: "stagedDone" } })));
  call("chat_post, staged, failing", "chat_post", { to: "E/1", send: "h1" }, "t1", (w) => w
    .is("sessions/conversations.mayStage", 1)
    .on("sessions/conversations.unheld", () => ({ args: { to: "E/1", text: "held" }, held: "h1" }))
    .on("sessions/conversations.staged", ([, , a]) => ({ args: a, done: { $ref: "stagedDone" } }))
    .on("sessions/conversations.chatPost", () => thrown("Error", { message: "too large" })));
  call("slack_api", "slack_api", { method: " chat.postMessage ", params: { channel: "C1" }, to: "C1/2", bot: " B1 ", save_files: true });
  call("slack_api, odd arguments", "slack_api", { method: { a: 1 }, params: [1], to: "", bot: "  " });
  call("slack_api, a null method", "slack_api", { method: null });
  call("slack_api, no method", "slack_api", {});
  call("chat_state", "chat_state", { kind: "waiting", for: "CI", seconds: "60", watch: "false" });
  call("chat_leave", "chat_leave", { to: "C/1" });
  call("chat_history", "chat_history", { to: "C/1", before: "3", limit: 5 });
  call("chat_list", "chat_list", { query: "x" });
  call("chat_read here", "chat_read", { chat: " C/1 " });
  call("chat_read, not a string", "chat_read", { chat: 5 });
  call("chat_read on another station", "chat_read", { chat: "https://app.example/o/w1/st2/s7" }, "t1", (w) => w.is("sessions/others.elsewhere", "st2"));
  call("chat_read, handed away", "chat_read", { chat: "https://x/chats/s7", limit: 3 }, "t1", (w) => w.is("sessions/others.linkedSession", ["s7", "w1"]).is("hub.store.handedTo", { station: "st3", at: 1 }));
  call("chat_read, a link to nothing", "chat_read", { chat: "https://x/chats/" }, "t1", (w) => w.is("sessions/others.linkedSession", [null]));
  call("session_send", "session_send", { to: "s2", text: "hi", files: ["/a"] });
  call("session_send, staged", "session_send", { to: "s2", text: "hi", files: ["/Users/a/Documents/b"] }, "t1", (w) => w.is("sessions/conversations.mayStage", true).on("sessions/conversations.staged", ([, , a]) => ({ args: a, done: { $ref: "stagedDone" } })));
  call("chat_create", "chat_create", { for: "me", key: "k1", text: "go", speed: "ultrafast", fast: "true", context: "200000" });
  call("chat_archive", "chat_archive", { chat: "s2" });
  call("session_history", "session_history", { chat: "s2", before: "4", max_chars: 200 });
  call("session_history afar", "session_history", { chat: "https://app.example/o/w1/st2/s7?history=s7&entry=3" }, "t1", (w) => w.is("sessions/others.elsewhere", "st2"));

  // ── small tools
  call("archive_policy read", "archive_policy", {});
  call("archive_policy changed", "archive_policy", { policy: "New." });
  call("archive_policy options, policy null", "archive_policy", { policy: null, options: [{ name: "A", rubric: "a", archive: true }] });
  call("archive_policy unchanged", "archive_policy", { policy: "x" }, "t1", (w) => w.is("sessions/archive-policy.savePolicy", null));
  call("archive_policy, its review failing", "archive_policy", { policy: "x" }, "t1", (w) => w.on("sessions/review.reviewUndecided", () => thrown("Error", { message: "x" })));
  call("station_list", "station_list", { station: "Tokyo" });
  call("station_task", "station_task", { station: "Tokyo", action: "start", key: "k", lines: "20", small: "true" });
  call("station_file, nothing", "station_file", { station: "a", key: "k", direction: "upload", path: "p", local: "l" }, "t1", (w) => w.is("remote.tool", null));
  call("station_task refused", "station_task", { station: "x", action: "get" }, "t1", (w) => w.on("remote.tool", () => thrown("Refused", { message: "no station x" })));
  call("workspace_limit", "workspace_limit", {});
  call("workspace_limit set", "workspace_limit", { station: " Tokyo ", limit_gib: "20" });
  call("workspace_limit bad", "workspace_limit", { limit_gib: "x" });
  call("workspace_limit null", "workspace_limit", { limit_gib: null });
  call("job_start", "job_start", { command: "make", name: "build" });
  call("job_start in a directory", "job_start", { command: "make", cwd: " /abs/dir ", port: 8080, watch: true }, "t2");
  call("job_start, no session", "job_start", { command: "make" }, "t3");
  call("job_start, bad port", "job_start", { command: "make", port: 70000 });
  call("job_start, port null", "job_start", { command: "make", port: null });
  call("job_start, port a fraction", "job_start", { command: "make", port: 1.5 });
  call("job_list", "job_list", {});
  call("job_list none", "job_list", {}, "t2");
  call("job_log", "job_log", { id: " job1 ", lines: 5000 });
  call("job_log, nothing written", "job_log", { id: "job1", lines: 3 });
  call("job_log, few lines", "job_log", { id: "job1", lines: 0 });
  call("job_log, another's", "job_log", { id: "job9" });
  call("job_log, none", "job_log", { id: "nope" });
  call("job_stop", "job_stop", { id: "job1" });
  call("peer_forward list", "peer_forward", {});
  call("peer_forward list none", "peer_forward", {}, "t2");
  call("peer_forward open", "peer_forward", { station: " tokyo ", port: 5432, local_port: 15432, job: " job1 " });
  call("peer_forward open, defaults", "peer_forward", { station: "tokyo", port: "22" });
  call("peer_forward close", "peer_forward", { close: 5432 });
  call("peer_forward close with a station", "peer_forward", { close: 5432, station: "x" });
  call("peer_forward bad port", "peer_forward", { station: "x", port: 0 });
  call("peer_forward bad local", "peer_forward", { station: "x", port: 1, local_port: "a" });
  call("peer_forward half", "peer_forward", { port: 22 });
  call("station_retire", "station_retire", { action: "preview", to: "Tokyo" });
  call("device_list", "device_list", {});
  call("device_list none", "device_list", {}, "t2");
  call("device_use", "device_use", { device: " Pixel ", reason: "test", timeout: { kind: "idle", seconds: 60 } });
  call("device_use done", "device_use", { done: true });
  call("station_use", "station_use", { station: " Mac ", reason: "build", timeout: { kind: "fixed", seconds: 600, extra: 1 } });
  call("station_use, timeout an array", "station_use", { station: "Mac", timeout: [1] });
  call("station_use done", "station_use", { done: "true", station: "Mac" });
  call("station_use, nothing named", "station_use", { reason: "x" });

  // ── screen
  call("screen list", "screen", {});
  call("screen list, no pages", "screen", { action: "list" }, "t1", (w) => w.is("base", null));
  call("screen one", "screen", { id: "browser:t1" });
  call("screen unknown", "screen", { id: "nope" });
  call("screen of a person's own tab", "screen", { id: "browser:mine" });
  call("screen none", "screen", {}, "t1", (w) => w.is("screens.listed", { screens: [] }));
  call("screen take_control", "screen", { action: "take_control", id: "desktop" });
  call("screen disconnect", "screen", { action: "disconnect", id: "desktop", view: "v1" });
  call("screen disconnect, no view", "screen", { action: "disconnect", id: "desktop" });
  call("screen watch_only", "screen", { action: "watch_only", id: "desktop", view: "v1" });
  call("screen disconnect_all", "screen", { action: "disconnect_all", id: "desktop" });
  call("screen, no id", "screen", { action: "take_control" });
  call("screen, a person's own tab", "screen", { action: "take_control", id: "browser:mine" });
  call("screen, an unknown action", "screen", { action: "jump", id: "desktop" });
  call("screen, refused", "screen", { action: "watch_only", id: "desktop", view: "v9" }, "t1", (w) => w.on("screens.watchOnly", () => thrown("ScreenRefused", { message: "no", key: "station.screen.userOnly", args: {} })));

  // ── permissions
  call("permissions", "permissions", {});
  call("permissions, helper silent", "permissions", { request: "" }, "t1", (w) => w.is("grants.view", null));
  call("permissions, an unknown grant", "permissions", { request: "camera" });
  call("permissions, a grant null", "permissions", { request: null });
  call("permissions, granted", "permissions", { request: "documents" });
  call("permissions, closed", "permissions", { request: "desktop" });
  call("permissions, none", "permissions", { request: "removable" });
  call("permissions, up", "permissions", { request: "capture" });
  call("permissions, up, no screen", "permissions", { request: "control" });
  call("permissions, up, no pages", "permissions", { request: "capture" }, "t1", (w) => w.is("base", null));
  call("permissions, local network", "permissions", { request: "localNetwork" });
  call("permissions, local network, no screen", "permissions", { request: "localNetwork" }, "t1", (w) => w.on("grants.request", () => ({ window: "up", screen: false })).is("grants.view", null));
  call("permissions, refused", "permissions", { request: "network" }, "t1", (w) => w.on("grants.request", () => thrown("GrantRefused", { message: "no", key: "station.screen.userOnly" })));
  fn("permissions with no helper", "noHelper", ["s1", { request: "capture" }]);

  // ── computer
  call("computer, unknown action", "computer", { action: "fly", screen: "desktop" });
  call("computer, no screen", "computer", {});
  call("computer, an unknown screen", "computer", { screen: "nope" });
  call("computer screenshot", "computer", { screen: "desktop" });
  call("computer screenshot again", "computer", { action: "screenshot", screen: "desktop" });
  call("computer screenshot, people on it", "computer", { screen: "browser:t1" }, "t2", (w) => {
    w.state.people = { "browser:t1": { views: [{ name: "agent: s2", control: true, agent: true }], viewers: ["Ann", "agent: s2"] } };
    w.on("agentName", ([s]) => `agent: ${s}`);
  });
  call("computer click", "computer", { action: "click", screen: "desktop", x: 640, y: 400, double: true, button: "right", wait: 0 });
  call("computer click, outside", "computer", { action: "click", screen: "desktop", x: 1281, y: 400 });
  call("computer click, no point", "computer", { action: "click", screen: "desktop", x: "a" });
  call("computer click, a bad button", "computer", { action: "click", screen: "desktop", x: 1, y: 1, button: "back" });
  call("computer move, no screenshot", "computer", { action: "move", screen: "desktop", x: 0, y: 800, screenshot: false });
  call("computer drag", "computer", { action: "drag", screen: "desktop", from: [10, 10], to: [1270, 790], wait: 30 });
  call("computer drag, no to", "computer", { action: "drag", screen: "desktop", from: [10, 10] });
  call("computer scroll", "computer", { action: "scroll", screen: "desktop", x: 5, y: 5, dy: 20000, dx: -3, screenshot: false });
  call("computer scroll, nothing", "computer", { action: "scroll", screen: "desktop", x: 5, y: 5 });
  call("computer type", "computer", { action: "type", screen: "desktop", text: `line one\r\nline two ${"y".repeat(1500)}`, screenshot: false });
  call("computer type, nothing", "computer", { action: "type", screen: "desktop", text: "" });
  call("computer key", "computer", { action: "key", screen: "desktop", key: " cmd+shift+t ", mods: ["alt", 3], screenshot: false });
  call("computer key, an unknown key", "computer", { action: "key", screen: "desktop", key: "ctrl+Hyper" });
  call("computer key, no modifier", "computer", { action: "key", screen: "desktop", key: "hyper+a" });
  call("computer key, none", "computer", { action: "key", screen: "desktop", key: "  " });
  call("computer wait", "computer", { action: "wait", screen: "desktop", ms: 40000 });
  call("computer wait, default", "computer", { action: "wait", screen: "desktop", ms: "x" }, "t1", (w) => {
    w.on("timers.later", ([ms]) => ms < 10000 || ms === 1000);
  });
  call("computer, someone controlling", "computer", { action: "click", screen: "desktop", x: 1, y: 1 }, "t1", (w) => {
    w.state.people = { desktop: { views: [{ name: "Ann", control: true, agent: false }, { name: "Bob", control: true, agent: false }, { name: "agent: x", control: true, agent: true }], viewers: [] } };
  });
  call("computer, watch-only access", "computer", { action: "click", screen: "simulator:s1", x: 1, y: 1 });
  call("computer, watch-only screenshot", "computer", { screen: "simulator:s1" });
  call("computer, not JPEG", "computer", { screen: "browser:png" });
  call("computer, nothing shown", "computer", { screen: "simulator:dark" }, "t3", (w) => w.on("timers.later", ([ms]) => ms !== 60000));
  call("computer, refused as it opens", "computer", { screen: "browser:t1" }, "t4", (w) => w.on("screens.openAs", () => thrown("ScreenRefused", { message: "no", status: 403, key: "station.screen.userOnly", args: {}, access: { capture: false, control: false } })));
  call("computer, refused, no JPEG", "computer", { screen: "browser:t1" }, "t4", (w) => w.on("screens.openAs", () => thrown("ScreenRefused", { message: "no", status: 415, key: "x" })));
  call("computer, refused in words", "computer", { screen: "browser:t1" }, "t4", (w) => w.on("screens.openAs", () => thrown("ScreenRefused", { message: "no", status: 409, key: "station.screen.userOnly", args: {} })).is("base", null));
  call("computer, failing as it opens", "computer", { screen: "browser:t1" }, "t4", (w) => w.on("screens.openAs", () => thrown("Error", { message: "boom" })));
  call("computer, gone as it opened", "computer", { screen: "browser:t1" }, "t5", (w) => {
    let n = 0;
    w.on("screens.get", ([id]) => (++n === 1 ? { $ref: `src:${id}` } : UNDEF));
  });
  call("computer tree, the apps", "computer", { action: "tree", screen: "desktop" });
  call("computer tree, an app", "computer", { action: "tree", screen: "desktop", app: " Mail ", window: "w2" });
  call("computer tree, a part", "computer", { action: "tree", screen: "desktop", ref: "e3", skeleton: true });
  call("computer tree, a qualified part", "computer", { action: "tree", screen: "desktop", ref: "@s1:e3", app: "Finder" });
  call("computer click by ref", "computer", { action: "click", screen: "desktop", ref: "e12", double: true, wait: 0 });
  call("computer right-click by ref", "computer", { action: "click", screen: "desktop", ref: "e12", button: "right", tree: false });
  call("computer click by ref, middle", "computer", { action: "click", screen: "desktop", ref: "e12", button: "middle" });
  call("computer type by ref", "computer", { action: "type", screen: "desktop", ref: "e2", text: "z".repeat(90) });
  call("computer type by ref, failing", "computer", { action: "type", screen: "desktop", ref: "e2", text: "fail" });
  call("computer set", "computer", { action: "set", screen: "desktop", ref: "e2", text: "" });
  call("computer set, no ref", "computer", { action: "set", screen: "desktop", text: "a" });
  call("computer set, a bad ref", "computer", { action: "set", screen: "desktop", ref: "x2", text: "a" });
  call("computer scroll by ref", "computer", { action: "scroll", screen: "desktop", ref: "e5", dx: 260, dy: -100 });
  call("computer scroll by ref, a lot", "computer", { action: "scroll", screen: "desktop", ref: "e5", dy: 99999 });
  call("computer scroll by ref, nothing", "computer", { action: "scroll", screen: "desktop", ref: "e5" });
  call("computer key with an app", "computer", { action: "key", screen: "desktop", app: "Mail", key: "cmd+n", mods: ["shift"] });
  call("computer key with the latest app", "computer", { action: "key", screen: "desktop", app: "Finder", key: "x" });
  call("computer key with an app, none", "computer", { action: "key", screen: "desktop", app: "Mail" });
  call("computer move by ref", "computer", { action: "move", screen: "desktop", ref: "e1" });
  call("computer tree, no tree read", "computer", { action: "click", screen: "desktop", ref: "e1" }, "t2");
  call("computer tree, not the desktop", "computer", { action: "tree", screen: "browser:t1" });
  call("computer tree, cannot be driven", "computer", { action: "tree", screen: "desktop:locked" });
  call("computer tree, refused", "computer", { action: "tree", screen: "desktop" }, "t1", (w) => w.on("src:desktop.ui", () => thrown("ScreenRefused", { message: "helper gone", access: { capture: true, control: true } })));
  call("computer tree, failing", "computer", { action: "tree", screen: "desktop", app: "X" }, "t1", (w) => w.on("src:desktop.ui", () => thrown("Error", { message: "agent-desktop missing" })));
  call("computer tree, unanswered", "computer", { action: "tree", screen: "desktop" }, "t1", (w) => w.on("src:desktop.ui", () => ({ ok: false })));
  fn("computer as text", "computerRun", ["s1", { screen: "desktop", action: "wait", ms: 5 }]);
  fn("computer as text, failing", "computerRun", ["s1", { screen: "nope" }]);
  fn("computer views", "computerOpen", []);
  fn("computer session closed", "computerCloseSession", ["s2"]);
  fn("computer views after", "computerOpen", []);

  // ── relays
  call("relays list", "relays", { action: "list" });
  call("relays enroll", "relays", { action: "enroll", name: "office" });
  call("relays enroll empty name", "relays", { action: "enroll", name: "" });
  call("relays enroll missing name", "relays", { action: "enroll" });
  call("relays enroll non-string name", "relays", { action: "enroll", name: 42 });
  call("relays enroll refused", "relays", { action: "enroll", name: "office" }, "t1", (w) => w.on("relays.enroll", () => thrown("Error", { message: "issuer unavailable" })));
  call("relays revoke", "relays", { action: "revoke", node: "a".repeat(64) });
  for (const node of [undefined, 42, "a".repeat(63), "a".repeat(65), "A".repeat(64), "g".repeat(64)]) {
    call(`relays revoke invalid ${node}`, "relays", { action: "revoke", node });
  }
  call("relays revoke refused", "relays", { action: "revoke", node: "a".repeat(64) }, "t1", (w) => w.on("relays.revoke", () => thrown("Error", { message: "issuer offline" })));
  fn("relays list without mesh", "relaysWithoutMesh", ["t1", { action: "list" }]);
  fn("relays enroll unavailable", "relaysWithoutMesh", ["t1", { action: "enroll" }]);
  fn("relays revoke unavailable", "relaysWithoutMesh", ["t1", { action: "revoke" }]);
  call("relays, no ways", "relays", { action: "list" }, "t1", (w) => w.is("relays.ways", null));
  call("relays, no workspace", "relays", { action: "list" }, "t1", (w) => w.is("relays.workspaceOf", ""));
  call("relays add", "relays", { action: "add", url: "https://relay.example" });
  call("relays add, a bad url", "relays", { action: "add", url: "ftp://x" });
  call("relays add, not a relay", "relays", { action: "add", url: "https://web.example" }, "t1", (w) => w.on("fetch", () => ({ status: 404 })));
  call("relays add, refused", "relays", { action: "add", url: "https://relay.example" }, "t1", (w) => w.on("mesh/ways.addRelay", () => thrown("WaysRefusal", { message: "at most 4" })));
  call("relays add, failing", "relays", { action: "add", url: "https://relay.example" }, "t1", (w) => w.on("mesh/ways.addRelay", () => thrown("Error", { message: "disk" })));
  call("relays remove", "relays", { action: "remove", url: "https://r1.example" });
  call("relays remove, not one", "relays", { action: "remove", url: "nope" }, "t1", (w) => w.on("mesh/ways.removeRelay", () => thrown("WaysRefusal", { message: "not there" })));
  call("relays, an unknown action", "relays", { action: "rename" });
  call("relays, a local cloud", "relays", { action: "add", url: "https://relay.example" }, "t1", (w) => w.is("ways.cloud.state", { origin: "http://localhost:8787" }));
  fn("probeRelay", "probeRelay", ["https://relay.example///"]);
  fn("probeRelay, not answering", "probeRelay", ["https://relay.example"], (w) => w.on("fetch", () => thrown("TypeError", { message: "fetch failed", cause: { code: "ECONNREFUSED" } })));
  fn("probeRelay, a cause in words", "probeRelay", ["https://relay.example"], (w) => w.on("fetch", () => thrown("TypeError", { message: "fetch failed", cause: { message: "certificate has expired" } })));
  fn("probeRelay, no cause", "probeRelay", ["https://relay.example"], (w) => w.on("fetch", () => thrown("Error", { message: "aborted" })));
  fn("probeRelay, a web server", "probeRelay", ["https://relay.example"], (w) => w.on("fetch", () => ({ status: 200 })));

  // ── feedback
  call("feedback_send", "feedback_send", { to: " C/1 ", title: " It broke ", body: "When x", area: "desktop", desktopPlatform: "windows", reporter: "Ann", logs: "line" });
  call("feedback_send, odd area", "feedback_send", { title: "t", body: "b", area: "moon" }, "t2");
  call("feedback_send, no session", "feedback_send", { title: "t", body: "b" }, "t3");
  call("feedback_send, no title", "feedback_send", { title: " ", body: "b" });
  call("feedback_send, not connected", "feedback_send", { title: "t", body: "b" }, "t1", (w) => w.is("feedback.send", null));
  call("feedback_send, failing", "feedback_send", { title: "t", body: "b" }, "t1", (w) => w.on("feedbackSender", () => thrown("Error", { message: "502" })));
  call("feedback_send, no number", "feedback_send", { title: "t", body: "b" }, "t1", (w) => w.is("feedbackSender", { number: -1 }));
  call("feedback_send, nothing", "feedback_send", { title: "t", body: "b" }, "t1", (w) => w.is("feedbackSender", undefined));
  call("feedback_send, duplicate", "feedback_send", { title: "t", body: "b" }, "t1", (w) => w.is("feedbackSender", { number: 3, duplicate: true }));
  call("feedback_reply", "feedback_reply", { number: 12, text: " thanks " });
  call("feedback_reply, no session", "feedback_reply", { number: 12, text: "x" }, "t3");
  call("feedback_reply, bad number", "feedback_reply", { number: 0, text: "x" });
  call("feedback_reply, no text", "feedback_reply", { number: 2, text: "" });
  call("feedback_reply, not connected", "feedback_reply", { number: 2, text: "x" }, "t1", (w) => w.is("feedback.reply", null));
  call("feedback_reply, not ours", "feedback_reply", { number: 2, text: "x" }, "t1", (w) => w.on("feedbackReplier", () => thrown("Error", { message: "404 feedback_not_found" })));
  call("feedback_reply, failing", "feedback_reply", { number: 2, text: "x" }, "t1", (w) => w.on("feedbackReplier", () => thrown("Error", { message: "500" })));
  fn("report", "report", [SESSION, { title: "t", body: "b", to: "C/2" }, null]);
  fn("report, no model", "report", [{ ...SESSION, model: undefined }, { title: "t", body: "b", logs: " " }, "https://l"]);
  fn("report, nothing said", "report", [SESSION, { body: "b" }, null]);
  for (const [n, r, s] of [
    ["fixed, live", { number: 3, title: "T", parts: [] }, null],
    ["fixed, cloud", { number: 3, title: "T", parts: ["cloud"], thread: "C/1" }, "0.1.9000"],
    ["fixed, station has it", { number: 3, title: "T", version: 9100, parts: ["station", "cloud", 5] }, "0.1.9200"],
    ["fixed, station lacks it", { number: 3, title: "T", version: 9300, parts: ["station"] }, "0.1.9200"],
    ["fixed, station's version odd", { number: 3, title: "T", version: 9300, parts: ["station"] }, "dev"],
    ["fixed, apps", { number: 3.5, title: 4, version: -1, parts: ["web", "android", "desktop"] }, "0.1.9200"],
  ] as const) fn(n, "fixedNotice", [r, s]);
  fn("tellFixed", "tellFixed", [], (w) => w.on("feedback.fixed", ([told]) => (told.length > 0 ? {} : { station: "0.1.9200", fixed: [{ id: "f1", session: "s1", number: 3, title: "T", version: 9100, parts: ["station"] }, { id: 5 }, { id: "f3" }, { id: "f4", session: "s9" }] })).on("feedback.notify", ([s]) => (s === "s9" ? thrown("Error", { message: "gone" }) : undefined)));
  fn("tellFixed, none", "tellFixed", [], (w) => w.is("feedback.fixed", { fixed: [] }));
  fn("feedback live", "feedbackLive", []);
  fn("feedback live's overview", "feedbackOverview", []);
  fn("feedback live's overview, no state", "feedbackOverview", [], (w) => w.is("plane.state.state", null));
  for (const [m, p] of [["POST", "/threads/7/report"], ["POST", "//threads//7//report"], ["GET", "/threads/7/report"], ["POST", "/threads/7/report/x"]] as const) fn(`feedback viewer may ${m} ${p}`, "feedbackViewerMay", [m, p]);
  fn("feedback live tells", "feedbackTell", []);
  fn("feedback live tells, removed", "feedbackTell", [], (w) => w.is("plane.state.removed", true));
  fn("feedback live tells, failing", "feedbackTell", [], (w) => w.on("cloud/signed.signedPost", () => thrown("Error", { message: "401" })));
  call("feedback live's feedback_send", "feedback_send", { title: "t", body: "b" }, "t6", (w) => w.on("mcp.resolve", () => "s1"));
  call("feedback live's feedback_send, no ws", "feedback_send", { title: "t", body: "b" }, "t6", (w) => w.on("mcp.resolve", () => "s2"));
  call("feedback live's feedback_send, removed", "feedback_send", { title: "t", body: "b" }, "t6", (w) => w.on("mcp.resolve", () => "s1").is("plane.state.removed", true));
  call("feedback live's feedback_reply", "feedback_reply", { number: 4, text: "x" }, "t6", (w) => w.on("mcp.resolve", () => "s1"));
  call("feedback live's feedback_reply, no cloud", "feedback_reply", { number: 4, text: "x" }, "t6", (w) => w.on("mcp.resolve", () => "s1").is("plane.state.state", null));
  fn("feedback live's route", "feedbackRoute", [{ path: "/threads/7/report", body: Buffer.from(JSON.stringify({ n: 3 })).toString("base64"), lang: "zh", viewer: { name: "Ann", email: "ann@example.com" } }]);

  // ── the notice's report
  for (const s of ["2026-11-17T02:39:41.107Z", "2026-11-17T02:39:41Z", "2026-11-17T02:39Z", "2026-11-17", "2026-11", "2026", "+002026-11-17T00:00:00.000Z", "2026-11-17T02:39:41.1234567Z", "2026-11-17T10:39:41+08:00", "2026-02-29T00:00:00Z", "2024-02-29T00:00:00Z", "2026-11-17T24:00:00Z", "2026-11-17T25:00:00Z", "2026-13-01", "nope", "", "2026-11-17t02:39:41z"]) fn(`Date.parse ${JSON.stringify(s)}`, "parseIso", [s]);
  for (const ms of [0, 1794883181032, -1, 86399999, 253402300799999]) fn(`toISOString ${ms}`, "isoString", [ms]);
  fn("logLines", "logLines", [["2026-11-17T02:39:00.000Z WARN agents::claude x /Users/ann/y", "2026-11-17T02:39:00.000Z  ERROR agents::claude-x z", "2026-11-17T02:39:00.000Z WARN agents::claude_x no", "nodate", "2026-11-17T02:39:00.000Z INFO s1", "2026-11-17T01:00:00.000Z INFO s1 early"].join("\n"), Date.parse("2026-11-17T02:00:00Z"), Date.parse("2026-11-17T03:00:00Z"), ["s1"], "cla.ude", "/Users/ann"]);
  fn("logLines, too many", "logLines", [Array.from({ length: 700 }, (_, i) => `2026-11-17T02:39:00.000Z INFO s1 ${"w".repeat(i % 3 === 0 ? 300 : 40)} ${i}`).join("\n"), 0, Date.parse("2027-01-01"), ["s1"], "claude", ""]);
  fn("logLines, no runtime", "logLines", ["2026-11-17T02:39:00.000Z WARN agents::x y", 0, Date.parse("2027-01-01"), [], "", "/"]);
  fn("failedTurnOf", "failedTurnOf", [7, 1794883181032]);
  fn("failedTurnOf, unbounded", "failedTurnOf", [7, 0.5], (w) => w.on("store.listTurns", () => [{ summary: { outcome: "failed", endedAt: 0, startedAt: 0 } }]));
  fn("failedTurnOf, none", "failedTurnOf", [7, 5], (w) => w.is("store.threadSessions", []));
  fn("failedTurnOf, no failed turn", "failedTurnOf", [7, 5], (w) => w.is("store.failedTurnsNear", []));
  fn("readTail", "readTail", ["/data/stillfail.log", 10]);
  fn("readTail whole", "readTail", ["/data/stillfail.log", 100]);
  fn("readTail, none", "readTail", ["/data/missing", 10]);
  fn("noticeReport", "noticeReport", [{ id: 7, channel: "CHAT", threadTs: "1.0" }, { n: 3, at: 1794883181032, text: "⚠️  The turn failed.\n\nAgain." }, { name: "Ann", email: "ann@example.com" }]);
  fn("noticeReport, no turn", "noticeReport", [{ id: 7, channel: "CHAT", threadTs: "1.0" }, { n: 3, at: 1794883181032, text: "⚠️" }, { name: "Ann", email: "a@x" }], (w) => w.is("store.failedTurnsNear", []).is("reportDeps.logTail", null).on("store.getSession", ([k]) => (k === "s1" ? { ...SESSION, model: null, ws: "" } : null)));
  fn("noticeReport, no session", "noticeReport", [{ id: 7, channel: "C", threadTs: "2" }, { n: 1, at: 5, text: null }, {}], (w) => w.is("store.threadSessions", []));
  const route = (name: string, path: string, body: unknown, world?: (w: World) => void, lang = "en") =>
    fn(name, "reportRoute", [{ path, body: Buffer.from(typeof body === "string" ? body : JSON.stringify(body)).toString("base64"), lang, viewer: { name: "Ann", email: "ann@example.com" } }], world);
  route("report route", "/threads/7/report", { n: 3 });
  route("report route, zh", "/threads/7/report", { n: 3 }, (w) => w.on("feedback.sendReport", () => ({ number: 5 })), "zh");
  route("report route, unknown thread", "/threads/8/report", { n: 3 });
  route("report route, not a number", "/threads/x7/report", { n: 3 });
  route("report route, bad JSON", "/threads/7/report", "{");
  route("report route, no body", "/threads/7/report", "");
  route("report route, bad n", "/threads/7/report", { n: 1.5 });
  route("report route, n an array", "/threads/7/report", [3]);
  route("report route, not a notice", "/threads/7/report", { n: 4 });
  route("report route, no entry", "/threads/7/report", { n: 9 });
  route("report route, not sent", "/threads/7/report", { n: 3 }, (w) => w.on("feedback.sendReport", () => thrown("Error", { message: "offline" })));
  route("report route, no number", "/threads/7/report", { n: 3 }, (w) => w.is("feedback.sendReport", undefined));

  // ── move
  call("station_move, no workspace", "station_move", { action: "plan", to: "Tokyo" }, "t1", (w) => w.is("move.wsOf", null));
  call("station_move plan", "station_move", { action: "plan", to: "tokyo" });
  call("station_move plan, no room", "station_move", { action: "plan", to: "st2xxxxxxxx", wait: false }, "t1", (w) => w.on("move.room", () => thrown("Error", { message: "x" })));
  call("station_move plan, by a prefix", "station_move", { action: "plan", to: "st3yyyyy" });
  call("station_move plan, a short prefix", "station_move", { action: "plan", to: "st3" });
  call("station_move plan, here", "station_move", { action: "plan", to: "Here" });
  call("station_move plan, no to", "station_move", { action: "plan" });
  call("station_move status", "station_move", { action: "status" });
  call("station_move status, an item", "station_move", { action: "status", item: "a1" });
  call("station_move plan, an item of a module", "station_move", { action: "plan", to: "Tokyo", module: "chats", item: "s1" });
  call("station_move plan, no item", "station_move", { action: "plan", to: "Tokyo", module: "jobs", item: "s1" });
  call("station_move plan, a page", "station_move", { action: "plan", to: "Tokyo", module: "chats", limit: 1 });
  call("station_move plan, the next page", "station_move", { action: "plan", to: "Tokyo", module: "chats", after: "s1", limit: 0.5 });
  call("station_move plan, an empty module", "station_move", { action: "plan", to: "Tokyo", module: "accounts", after: "nope", limit: 500 });
  call("station_move plan, no module", "station_move", { action: "plan", to: "Tokyo", module: "nope" });
  call("station_move move", "station_move", { action: "move", to: "Tokyo", module: "chats", item: "s1", withNeeds: true, arriveStopped: "true" });
  call("station_move move a job", "station_move", { action: "move", to: "Tokyo", module: "jobs", item: "j1" });
  call("station_move move, refused there", "station_move", { action: "move", to: "Office", module: "chats", item: "s1" });
  call("station_move move, nothing named", "station_move", { action: "move", to: "Tokyo" });
  call("station_move move all", "station_move", { action: "move", to: "Tokyo", all: true });
  call("station_move move all again", "station_move", { action: "move", to: "Office" , all: true }, "t1", (w) => w.is("move.refusal", null));
  call("station_move back", "station_move", { action: "back", to: "Tokyo", module: "chats", item: "s1" });
  call("station_move back all", "station_move", { action: "back", to: "Tokyo", module: "chats", all: true });
  call("station_move back, nothing named", "station_move", { action: "back", to: "Tokyo" });
  call("station_move stop", "station_move", { action: "stop" });
  call("station_move stop, nothing running", "station_move", { action: "stop" }, "t2");
  call("station_move, an unknown action", "station_move", { action: "go" });
  call("station_move on another station", "station_move", { action: "plan", station: " Tokyo ", to: "Here" });
  call("station_move on another station, a move", "station_move", { action: "move", station: "Tokyo", to: "Here", module: "chats", item: "s9" });
  call("station_move on another station, all", "station_move", { action: "move", station: "Tokyo", all: true });
  call("station_move on another station, unknown", "station_move", { action: "plan", station: "Mars" });
  call("station_move on this station", "station_move", { action: "status", station: "Here" });
  fn("move answer", "moveAnswer", ["st2", "w1", { args: { action: "status" } }]);
  fn("move answer, told", "moveAnswer", ["st2", "w1", { args: { action: "back", to: "Tokyo", module: "chats", item: "s1" }, told: "tool:back:1" }]);
  fn("move answer, all", "moveAnswer", ["st2", "w1", { args: { action: "move", to: "Tokyo", all: true } }]);
  fn("move answer, nothing", "moveAnswer", ["st2", "w1", null]);
  fn("move may", "moveMay", [{ role: "owner", workspace: "w1", email: "a@x" }, { move: { ask: "m_abababababab" } }, { thread: 7, ts: "1.5" }]);
  fn("move may, a member", "moveMay", [{ role: "member", workspace: "w1", email: "a@x" }, { move: { ask: "m_abababababab" } }, { thread: 7, ts: "1.5" }]);
  fn("move may, another workspace", "moveMay", [{ role: "admin", workspace: "w2", email: "a@x" }, { move: { ask: "m_abababababab" } }, { thread: 7, ts: "1.5" }]);
  fn("move may, another card", "moveMay", [{ role: "owner", workspace: "w1", email: "a@x" }, { move: { ask: "m_abababababab" } }, { thread: 8, ts: "1.5" }]);
  fn("move chosen, declined", "moveChosen", [{ email: "a@x" }, { move: { ask: "m_abababababab" } }, " 取消 ", { thread: 7, ts: "1.5" }], undefined, true);
  fn("move chosen again", "moveChosen", [{ email: "a@x" }, { move: { ask: "m_abababababab" } }, "x", { thread: 7, ts: "1.5" }]);
  call("station_move move all, asked anew", "station_move", { action: "move", to: "Tokyo", all: true });
  fn("move chosen, confirmed", "moveChosen", [{ email: "a@x" }, { move: { ask: "m_abababababab" } }, " 开始迁移 ", { thread: 7, ts: "1.5" }], undefined, true);
  call("station_move move all, asked once more", "station_move", { action: "move", to: "Tokyo", all: true });
  fn("move chosen, confirmed, not begun", "moveChosen", [{ email: "a@x" }, { move: { ask: "m_abababababab" } }, "开始迁移", { thread: 7, ts: "1.5" }], (w) => w.on("move.scheduler.move", () => thrown("Error", { message: "busy" })), true);
  fn("summaryOf", "summaryOf", [PLAN, [{ item: { module: "jobs", id: "j1" }, waitsFor: { module: "chats", id: "s1" } }]]);
  fn("summaryOf, many reasons", "summaryOf", [{ modules: [{ id: "chats" }, { id: "chats" }], items: Array.from({ length: 30 }, (_, i) => ({ module: "chats", id: `c${i}`, label: `chat ${i}`, state: "here", needs: [], wouldStop: Array.from({ length: i % 5 }, (_, j) => ({ module: "jobs", id: `j${j}` })), cannot: `reason ${i % 23}` })) }, []]);
  fn("planWords", "planWords", [PLAN, "Tokyo", false]);
  fn("planWords, status", "planWords", [PLAN, "", true]);
  fn("planWords, many reasons", "planWords", [{ modules: [], items: Array.from({ length: 30 }, (_, i) => ({ module: "chats", id: `c${i}`, label: `chat ${i}`, state: "here", needs: [], wouldStop: [{ module: "jobs", id: "j" }], cannot: `reason ${i}` })) }, "X", false]);
  fn("planWords, empty", "planWords", [{ modules: [], items: [] }, "X", false]);
  fn("outcomeOf", "outcomeOf", [OUTCOME]);
  fn("outcomeOf, long", "outcomeOf", [{ ...OUTCOME, done: Array.from({ length: 60 }, (_, i) => ({ module: "chats", id: `c${i}` })), failures: undefined, failed: null, returned: undefined, lent: undefined }]);
  fn("roomWords", "roomWords", [{ sends: "1 GB", known: 2, of: 2, measuring: 0 }]);
  fn("roomWords, there", "roomWords", [{ sends: "1 GB", known: 1, of: 2, measuring: 1, freeThere: "9 GB", floorThere: "1 GB" }]);
  fn("outcomeWords", "outcomeWords", [OUTCOME, "moved to", "Tokyo"]);
  fn("outcomeWords, nothing", "outcomeWords", [{ done: [], refused: [], stopped: [], resumed: [], failed: null }, "back here from", "Tokyo"]);
  fn("outcomeWords, one failed", "outcomeWords", [{ done: Array.from({ length: 25 }, (_, i) => ({ module: "chats", id: `c${i}` })), refused: [], stopped: [], resumed: [], failed: { item: { module: "a", id: "b" }, error: "e" } }, "moved to", "X"]);

  // ── search and skills
  call("skill_read", "skill_read", { name: "stillfail" });
  call("skill_read, a file", "skill_read", { name: "stillfail", file: "more.md", station: " This Station " }, "t2");
  call("skill_read, no name", "skill_read", { name: " " });
  call("skill_read, a bad file", "skill_read", { name: "x", file: "" });
  call("skill_read, no session", "skill_read", { name: "x" }, "t3");
  call("skill_read on another station", "skill_read", { name: "x", station: "st2" });
  call("skill_read here by name", "skill_read", { name: "x", station: "here" });
  call("skill_read, ambiguous", "skill_read", { name: "x", station: "tokyo" });
  call("skill_read, no station", "skill_read", { name: "x", station: "mars" });
  call("skill_read, nothing back", "skill_read", { name: "x", station: "st2" }, "t1", (w) => w.is("searchDeps.ask", { nope: 1 }));
  call("search", "search", { query: " a  b ", kinds: ["chat", 5], limit: 2.7 });
  call("search, one station", "search", { query: "x", station: "TOKYO", limit: 500 }, "t1", (w) => w.is("searchDeps.stations", [{ id: "st2", name: "Tokyo", here: false }]));
  call("search, no stations", "search", { query: "x" }, "t1", (w) => w.on("searchDeps.stations", () => thrown("Error", { message: "no mesh" })));
  call("search, no station so named", "search", { query: "x", station: "mars" });
  call("search, nothing", "search", { query: "x", station: "Here" }, "t2", (w) => w.is("searchDeps.search.query", { groups: [] }));
  call("search, failing here", "search", { query: "x", station: "here" }, "t1", (w) => w.on("searchDeps.search.query", () => thrown("Error", { message: "index building" })));
  call("search, no query", "search", { query: "  " });
  call("search, too long", "search", { query: "q".repeat(201) });
  call("search, no session", "search", { query: "x" }, "t3");
  fn("formatSkill", "formatSkill", [{ skills: [{ name: "a", text: "A", files: [{ name: "b.md", text: "B" }, { name: "c.md" }] }] }, "a", "b.md"]);
  fn("formatSkill, no skill", "formatSkill", [{ skills: [] }, "a", "SKILL.md"]);
  fn("formatSkill, no file", "formatSkill", [{ skills: [{ name: "a", text: "A", files: [{ name: "c.md" }] }] }, "a", "c.md"]);
  fn("skillForPeer", "skillForPeer", [{ name: "stillfail", file: "more.md" }, "w2", "w1"]);
  fn("skillForPeer, home", "skillForPeer", [{ name: "stillfail" }, "w1", "w1"]);
  fn("skillForPeer, no name", "skillForPeer", [null, null, null]);
  fn("searchForPeer", "searchForPeer", [{ query: "x", kinds: ["job"], limit: 9 }, "w2", "w1"]);
  fn("searchForPeer, home", "searchForPeer", [{}, null, "w1"]);
  fn("searchForPeer, nothing", "searchForPeer", [null, null, null]);

  // ── the device tools
  const op = (name: string, o: string, args: unknown, access = "full", world?: (w: World) => void, context: unknown = { user_email: "ann@example.com" }) => fn(name, "device", [o, args, context, access], world);
  op("device, an unknown op", "fs.move", {});
  op("device, off", "fs.read", {}, "off");
  op("device, read only", "exec", {}, "read");
  op("device exec", "exec", { command: "echo hi", env: { A: "1" }, cwd: "proj", timeout_ms: 9e9 });
  op("device exec, its output", "exec", { command: "x" }, "full", (w) => (w.state.script = () => [["stdout", Buffer.from("o".repeat(700000)).toString("base64")], ["stderr", Buffer.from("é").toString("base64")], ["stdout", Buffer.from("p".repeat(700000)).toString("base64")], ["close", null]]));
  op("device exec, timed out", "exec", { command: "sleep 9", timeout_ms: 5 }, "full", (w) => (w.state.script = () => [["timeout"], ["close", 137]]));
  op("device exec, failing", "exec", { command: "x" }, "full", (w) => (w.state.script = () => [["error", "spawn ENOENT"]]));
  op("device exec, not started", "exec", { command: "x" }, "full", (w) => w.on("ops/processes.startCommand", () => thrown("Error", { message: "EMFILE" })));
  op("device exec, no shell", "exec", { command: "x" }, "full", (w) => w.on("platform/index.platform.posixShellSoon", () => thrown("Error", { message: "no sh: install Git" })));
  op("device exec, no command", "exec", { command: "" });
  op("device exec, bad env", "exec", { command: "x", env: { A: 1 } });
  op("device exec, protected", "exec", { command: "x", cwd: "/home/u/.stillfail/run" });
  op("device exec, protected through a link", "exec", { command: "x", cwd: "/home/u/via/keys" });
  op("device exec, protected by its link", "exec", { command: "x", cwd: "/data/real/x" });
  op("device read", "fs.read", { path: "notes.txt", offset: 3, length: 5 }, "read");
  op("device read, past the end", "fs.read", { path: "/x/notes.txt", offset: 30 }, "read");
  op("device read, missing", "fs.read", { path: "/x/missing" }, "read");
  op("device read, no path", "fs.read", {}, "read");
  op("device read, a path not there yet", "fs.read", { path: "/gone/deeper/file" }, "read");
  op("device write", "fs.write", { path: "/x/out.txt", content_base64: "aGk=" });
  op("device write, appended", "fs.write", { path: "/x/out.txt", content_base64: "aGk=", append: true });
  op("device write, no content", "fs.write", { path: "/x/out.txt" });
  op("device write, refused", "fs.write", { path: "/x/out.txt", content_base64: "" }, "full", (w) => w.on("fs.writeFile", () => thrown("Error", { message: "EPERM: operation not permitted", code: "EPERM" })));
  op("device list", "fs.list", { path: "/x" }, "read");
  op("device list, denied", "fs.list", { path: "/x/denied" }, "read");
  op("device stat", "fs.stat", { path: "/x/a dir" }, "read");
  op("device stat, a link", "fs.stat", { path: "/x/B.ln" }, "read");
  op("device process start", "process.start", { command: "server", env: { P: "1" } }, "full", (w) => (w.state.script = () => [["stdout", Buffer.from("ready\n").toString("base64")], ["stderr", Buffer.from("warn\n").toString("base64")]]));
  op("device process list", "process.list", {}, "read");
  op("device process tail", "process.tail", { process_id: "p1", since: 2 }, "read");
  op("device process write", "process.write", { process_id: "p1", data_base64: "cQo=" });
  op("device process write, refused", "process.write", { process_id: "p1", data_base64: "cQo=" }, "full", (w) => w.match(/\.stdin\.write$/, () => thrown("Error", { message: "EPIPE" })));
  op("device process write, no data", "process.write", { process_id: "p1" });
  op("device process write, none", "process.write", { process_id: "p9", data_base64: "" });
  op("device process stop", "process.stop", { process_id: "p1" });
  op("device process start, ending", "process.start", { command: "once" }, "full", (w) => (w.state.script = () => [["stdout", Buffer.from("x").toString("base64")], ["error", "killed"], ["close", 1]]));
  op("device process tail, ended", "process.tail", { process_id: "p2" }, "read");
  op("device process stop, ended", "process.stop", { process_id: "p2" });
  op("device process write, ended", "process.write", { process_id: "p2", data_base64: "" });
  op("device process list again", "process.list", {}, "read");
  op("device runtime probe", "runtime.probe", {}, "read");
  op("device runtime probe, signed in by key", "runtime.probe", {}, "read", (w) => w.on("ops/shell-path.withShellCommand", ([k, env]) => ({ ...env, ANTHROPIC_API_KEY: "k", SHELL_FOR: k })).on("fs.access", () => undefined).on("updates/runtimes.findCommandSoon", ([k]) => (k === "codex" ? null : { onPath: "/c", real: "/c" })));
  op("device session start", "session.start", { prompt: "go", title: "T" });
  op("device session start, refused", "session.start", { prompt: "fail", requester_email: "b@x" });
  op("device session start, no requester", "session.start", { prompt: "go" }, "full", undefined, {});
  op("device session start, no prompt", "session.start", {});
  op("device session say", "session.say", { thread: "CHAT/8", text: "more" });
  op("device session status", "session.status", { thread: "CHAT/8" }, "read");
  op("device session status, none", "session.status", { thread: "CHAT/9" }, "read");
  op("device session status, no thread", "session.status", {}, "read");
  for (const raw of [{ tools: { access: "read" } }, { tools: { access: "all" } }, null, { tools: 1 }]) fn(`accessOf ${JSON.stringify(raw)}`, "accessOf", [raw]);
  fn("device close", "deviceClose", []);

  // ── the endpoint's pieces
  for (const [a, s] of [
    [{ watch: "true", port: "8080", limit: " 3 ", cmd: "1" }, { properties: { watch: { type: "boolean" }, port: { type: "integer" }, limit: { type: "number" }, cmd: { type: "string" } } }],
    [{ a: "false", b: "1.", c: ".5", d: "TRUE" }, { properties: { a: { type: "boolean" }, b: { type: "number" }, c: { type: "number" }, d: { type: "boolean" } } }],
    [{ a: "1" }, null],
    [{ a: "1" }, { properties: null }],
    [{ a: "1" }, "schema"],
    [{ a: 1, b: "2" }, { properties: { a: { type: "number" }, b: { type: ["number"] } } }],
  ] as const) fn(`typed ${JSON.stringify(a)}`, "typed", [a, s]);
  for (const b of [0, 5000, 9000, 15000, 25000, 40000, 100000]) fn(`fitted ${b}`, "fitted", [b]);
  fn("weights", "weights", []);
  fn("indirectTool", "indirectTool", [["relays", "computer", "search", "station_move"]]);
  for (const m of ["chat.postMessage", "chat.update.x", "assistant.threads.setStatus", "conversations.history", "chat.startStream", "reactions.get"]) {
    fn(`isSlackWrite ${m}`, "isSlackWrite", [m]);
    fn(`speaksInSlack ${m}`, "speaksInSlack", [m]);
  }
  for (const u of ["http://127.0.0.1:4000/mcp", "http://127.0.0.1:4000/mcpx"]) fn(`peerHttpBase ${u}`, "peerHttpBase", [u]);
  for (const u of ["/peer/Tokyo/3000/api?x=1", "/peer/Tokyo/3000", "/peer/Tokyo/3000?x", "/peer/To%20kyo/80/a", "/peer/%E0%A4%A/80/a", "/peer//80/a", "/peer/x/0/a", "/peer/x/65536/", "/peer/x/123456/", "/peer/x/80x/", "/peer/x", "/other", "/peer/x/00080/a"]) fn(`peerTarget ${u}`, "peerTarget", [u]);
  for (const [h, p] of [
    [{ host: "127.0.0.1:4000" }, [4000]],
    [{ host: "LOCALHOST:4000" }, [5000, 4000]],
    [{ host: "[::1]:4000", origin: "null" }, [4000]],
    [{ host: "[::1]:4000", origin: "null", "sec-fetch-site": "cross-site" }, [4000]],
    [{ host: "[::1]:4000", origin: "null", "sec-fetch-site": "none" }, [4000]],
    [{ host: "127.0.0.1:4000", origin: "https://evil.example" }, [4000]],
    [{ host: "evil.example:4000" }, [4000]],
    [{ host: "127.0.0.1:4001" }, [4000]],
    [{}, []],
  ] as const) fn(`notFromHere ${JSON.stringify(h)}`, "notFromHere", [h, p]);
  for (const [s, t] of [[403, "no"], [404, ""], [503, "wait"], [418, "tea"]] as const) fn(`refuseUpgrade ${s}`, "refuseUpgrade", [s, t]);
  for (const u of ["/mcp", "/mcp?x=1#y", "/a/../health", "/./jobs/notify", "//host/mcp", "/a b/<c>", "/é", "/%2e%2E/mcp", "", "http://other:9/mcp?z", "mcp", "\t/mc\np ", "/a/b/..", "/a/.", "\\mcp"]) fn(`URL pathname ${JSON.stringify(u)}`, "urlPathname", [u]);
  for (const a of [[640, 400, 1280, 800], [-5, 900, 1280, 800], [5, 5, 0, 0]]) fn(`toUnit ${a}`, "toUnit", a);
  for (const [c, e] of [["Enter", []], ["cmd+shift+t", []], ["+", ["ctrl"]], ["cmd++", []], ["?", []], ["A", ["shift"]], ["F12", []], ["f21", []], ["F0", []], ["é", []], ["ctrl+Left", ["CMD", "ctrl"]], ["⌘+⌥+⇧+⌃+k", []], ["ctrl+", []], ["hyper+x", []], ["Page", []], ["space", ["win"]], ["1", ["shift"]], ["!", []], ["\"", []]] as const) fn(`keyPresses ${JSON.stringify(c)} ${JSON.stringify(e)}`, "keyPresses", [c, e]);
  for (const t of ["hi", "a\nb\r\nc\rd", "", "\n", "x".repeat(2500)]) fn(`typing ${JSON.stringify(t.slice(0, 10))}`, "typing", [t]);
  fn("clicking", "clicking", [0.5, 0.25, "middle", true]);
  fn("clicking once", "clicking", [0, 1, "left", false]);
  fn("dragging", "dragging", [0.1, 0.2, 0.9, 0.3, "right"]);
  fn("reachedAt adb", "reachedAt", [{ name: "Pixel", kind: "adb", target: "emulator-5554" }, 15037]);
  fn("reachedAt serial", "reachedAt", [{ name: "Board", kind: "serial", target: "/dev/ttyUSB0" }, 15038]);
  fn("reachedAt serial with a baud", "reachedAt", [{ name: "Board", kind: "serial", target: "/dev/ttyUSB0", baud: 9600 }, 15038]);
  fn("reachedAt tcp", "reachedAt", [{ name: "Router", kind: "tcp", target: "192.168.1.1:80" }, 15039]);
  fn("described", "described", ["https://app.example/w/w1/s/st1"]);
  fn("described, one", "described", [null, "desktop"]);
  fn("letGo", "letGo", ["agent: s1", "desktop", "take_control"]);

  // ── the door
  const local = { host: "127.0.0.1:4000" };
  door("health", { method: "GET", url: "/health" });
  door("health with a query", { method: "GET", url: "/health?x=1" });
  door("health, dotted", { method: "GET", url: "/a/../health" });
  door("notify", { method: "POST", url: "/jobs/notify", headers: { Authorization: "Bearer job" }, body: "milestone" });
  door("notify, no authorization", { method: "POST", url: "/jobs/notify", body: "x" });
  door("notify, too long", { method: "POST", url: "/jobs/notify", body: "x".repeat(64 * 1024 + 1) });
  door("notify, at the limit", { method: "POST", url: "/jobs/notify", body: "x".repeat(64 * 1024) });
  door("notify, a GET", { method: "GET", url: "/jobs/notify" });
  door("notify, no body answered", { method: "POST", url: "/jobs/notify", body: "x" }, (w) => w.is("door.notified", { status: 204 }));
  door("notify, failing", { method: "POST", url: "/jobs/notify", body: "x" }, (w) => w.on("door.notified", () => thrown("Error", { message: "jobs gone" })));
  door("screen", { method: "POST", url: "/jobs/screen", body: "take 123" });
  door("screen, too long", { method: "POST", url: "/jobs/screen", body: "t".repeat(65) });
  door("screen answered", { method: "POST", url: "/jobs/screen", body: "take 1" }, (w) => w.is("door.screened", { status: 200, body: { taken: true } }));
  door("mcp", { method: "POST", url: "/mcp", headers: { authorization: "Bearer t1" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "chat_state", arguments: { kind: "all_done", done: "x" } } }) });
  door("mcp, a GET", { method: "GET", url: "/mcp?session=1" });
  door("mcp, a notification", { method: "POST", url: "/mcp", headers: { authorization: "Bearer t1" }, body: JSON.stringify({ jsonrpc: "2.0", method: "x" }) });
  door("mcp, no token", { method: "POST", url: "/mcp", body: "{}" });
  door("nothing there", { method: "GET", url: "/nope" });
  door("peer", { method: "GET", url: "/peer/Tokyo/3000/api?x=1", headers: local });
  door("peer, bare", { method: "GET", url: "/peer", headers: local });
  door("peer, not from here", { method: "GET", url: "/peer/Tokyo/3000/", headers: { host: "evil.example" } });
  door("peer, a web page", { method: "GET", url: "/peer/Tokyo/3000/", headers: { ...local, origin: "https://evil.example" } });
  door("peer, not a target", { method: "GET", url: "/peer/Tokyo/x", headers: local });
  door("peer, no mesh", { method: "GET", url: "/peer/Tokyo/3000/", headers: local }, (w) => w.is("door.peers", null));
  door("peer, failing", { method: "GET", url: "/peer/Tokyo/3000/", headers: local }, (w) => w.on("door.peer.request", () => thrown("Error", { message: "reset" })));
  door("a part", { method: "GET", url: "/browser/tabs", headers: local });
  door("a part, its query", { method: "GET", url: "/browser?x", headers: local });
  door("a part, bare", { method: "GET", url: "/browser", headers: local });
  door("not a part", { method: "GET", url: "/browsers", headers: local });
  door("a part, not from here", { method: "GET", url: "/browser/tabs", headers: { host: "x:4000" } });
  door("a part, failing", { method: "GET", url: "/browser/tabs", headers: local }, (w) => w.on("door.part.request", () => thrown("Error", { message: "gone" })));
  door("no parts", { method: "GET", url: "/browser/tabs", headers: local }, (w) => w.is("door.parts", []));
  upgrade("upgrade a part", { method: "GET", url: "/browser/ws", headers: local });
  upgrade("upgrade a part, not from here", { method: "GET", url: "/browser/ws", headers: { host: "a:1" } });
  upgrade("upgrade a part, failing", { method: "GET", url: "/browser/ws", headers: local }, (w) => w.on("door.part.upgrade", () => thrown("Error", { message: "x" })));
  upgrade("upgrade something else", { method: "GET", url: "/mcp", headers: local });
  upgrade("upgrade a peer", { method: "GET", url: "/peer/Tokyo/3000/ws", headers: local });
  upgrade("upgrade a peer, not from here", { method: "GET", url: "/peer/Tokyo/3000/ws", headers: { host: "a" } });
  upgrade("upgrade a peer, no mesh", { method: "GET", url: "/peer/Tokyo/3000/ws", headers: local }, (w) => w.is("door.peers", null));
  upgrade("upgrade a peer, failing", { method: "GET", url: "/peer/Tokyo/3000/ws", headers: local }, (w) => w.on("door.peer.upgrade", () => thrown("Error", { message: "x" })));
}

// ---------------------------------------------------------------------------------------------------------------
// The TypeScript side

type Side = {
  mcp: (q: any) => Promise<Json>;
  fn: (q: any) => Promise<Json>;
  door: (q: Asked) => Promise<Json>;
  upgrade: (q: Asked) => Promise<Json>;
};

const errorOf = (e: any, ToolError: any, MeshRefused: any): Json => {
  const kind = e?.[KIND] ?? (e instanceof ToolError ? "ToolError" : e instanceof MeshRefused ? "Refused" : "Error");
  return { kind, message: String(e?.message ?? e), ...(e instanceof ToolError ? { code: e.code } : {}) };
};

async function typescriptSide(): Promise<Side & { setup: [string, Json][] }> {
  // (what the modules do as they load is no case's: answered, not compared)
  current = new World();
  const m = (p: string) => import(src(p));
  const { McpEndpoint, typed, fitted, weight, indirectTool, isSlackWrite, speaksInSlack } = await m("tools/mcp.ts");
  const { openAgentsDoor, peerHttpBase, peerTarget, notFromHere, refuseUpgrade } = await m("tools/http.ts");
  const { chatTools } = await m("tools/chat.ts");
  const { archiveTools } = await m("tools/archive.ts");
  const { remoteTools } = await m("tools/remote.ts");
  const { workspaceSizeTools } = await m("tools/workspace-size.ts");
  const { jobTools } = await m("tools/jobs.ts");
  const { screenTools, described, letGo } = await m("tools/screen.ts");
  const { permissionTools } = await m("tools/permissions.ts");
  const { Computer, computerTools, toUnit, keyPresses, typing, clicking, dragging } = await m("tools/computer.ts");
  const { forwardTools } = await m("tools/forward.ts");
  const { relayTools, probeRelay } = await m("tools/relays.ts");
  const { feedbackTools, report, fixedNotice, tellFixed } = await m("tools/feedback.ts");
  const { MoveAsks, moveTools, summaryOf, planWords, outcomeOf, roomWords, outcomeWords } = await m("tools/move.ts");
  const { retireTools } = await m("tools/retire.ts");
  const { deviceTools, reachedAt } = await m("devices/tool.ts");
  const { rigTools } = await m("rigs/tool.ts");
  const { searchTools, searchForPeer } = await m("search/tool.ts");
  const { formatSkillFromCatalog, skillForPeer } = await m("search/skills.ts");
  const { DeviceTools, accessOf, ToolError } = await m("device/tools.ts");
  const { logLines, failedTurnOf, readTail, noticeReport, reportRoutes } = await m("feedback/notice.ts");
  const { FeedbackLive } = await m("feedback/module.ts");
  const { Refused: MeshRefused } = await m("mesh/bus.ts");
  const { Effect, Layer, Exit, Cause } = await import("effect");
  const services = await m("services.ts");
  const { Agents } = await m("sessions/agents.ts");

  const setupWorld = baseWorld();
  current = setupWorld;
  const timers = {
    later(ms: number, f: () => void) {
      const fire = callWorld("timers.later", [ms]);
      let off = false;
      if (fire) setImmediate(() => !off && f());
      return () => (off = true);
    },
  };
  const computer = new Computer({ hub: P("screens"), base: () => callWorld("base", []), name: (s: string) => callWorld("agentName", [s]), timers });
  const moves = new MoveAsks({
    data: "/data", scheduler: P("move.scheduler"), here: () => callWorld("move.here", []), wsOf: (s: string) => callWorld("move.wsOf", [s]),
    roster: (ws: string) => callWorld("move.roster", [ws]), cards: P("move.cards"), notify: (s: string, t: string) => callWorld("move.notify", [s, t]),
    ask: (st: string, req: unknown) => callWorld("move.ask", [st, req]), setWait: (w: boolean) => callWorld("move.setWait", [w]),
    refusal: async (ws: string, st: string) => callWorld("move.refusal", [ws, st]), room: (ws: string, st: string, ids: string[]) => callWorld("move.room", [ws, st, ids]),
    told: { asked: async (to: string, key: string, make: () => unknown) => callWorld("move.told.asked", [to, key, make()]), run: (o: string, key: string, work: () => Promise<unknown>) => (callWorld("move.told.run", [o, key]), work()) },
  });
  const device = new DeviceTools({ home: "/home/u", env: { PATH: "/bin", HOME: "/home/u" }, protect: () => callWorld("device.protect", []), sessions: P("deviceSessions"), now: () => callWorld("device.now", []) });
  const searchDeps = {
    search: P("searchDeps.search"), readSkill: (ws: string | undefined, n: string, f: string) => callWorld("searchDeps.readSkill", [ws, n, f]),
    workspaceOf: (s: string) => callWorld("searchDeps.workspaceOf", [s]), link: (s: string) => callWorld("searchDeps.link", [s]),
    stations: async (ws: string) => callWorld("searchDeps.stations", [ws]), ask: async (st: string, q: unknown) => callWorld("searchDeps.ask", [st, q]),
  };
  const tools = [
    ...chatTools(P("hub")), ...archiveTools(P("hub")), ...remoteTools(P("remote")), ...workspaceSizeTools(P("workspaceWatch"), P("remote")),
    ...jobTools(P("jobs"), (k: string) => callWorld("jobs.workspace", [k]), P("places")),
    ...screenTools(P("screens"), () => callWorld("base", []), (s: string) => callWorld("agentName", [s])),
    ...permissionTools(P("grants"), () => callWorld("base", [])), ...computerTools(computer), ...forwardTools(P("forwards")),
    ...relayTools({ ways: () => callWorld("relays.ways", []), workspaceOf: (s: string) => callWorld("relays.workspaceOf", [s]), by: (s: string) => callWorld("relays.by", [s]), meshList: (w: string) => callWorld("relays.meshList", [w]), enroll: (w: string, n: string, b: string) => callWorld("relays.enroll", [w, n, b]), revoke: async (w: string, n: string) => callWorld("relays.revoke", [w, n]) }),
    ...feedbackTools(P("store"), (k: string) => callWorld("feedback.link", [k]), () => callWorld("feedback.send", []), () => callWorld("feedback.reply", [])),
    ...moveTools(moves), ...retireTools(P("retireAsks")), ...deviceTools(P("devices")), ...rigTools(P("rigUse")), ...searchTools(searchDeps),
  ];
  let live: { tools: any[]; routes: any[]; overview: () => boolean; viewerMay: (r: any) => boolean } | null = null;
  // (the feedback part's tools, once it is made, in place of those made without it)
  const listed = () => (live === null ? tools : [...live.tools, ...tools.filter((t: any) => !live!.tools.some((l: any) => l.name === t.name))]);
  const endpoint = new McpEndpoint((t: string) => callWorld("mcp.resolve", [t]), listed, (s: string) => callWorld("mcp.gate", [s]), (s: string) => callWorld("mcp.listing", [s]));
  const noHelper = permissionTools(null, () => callWorld("base", []));
  const reportDeps = {
    logTail: async (most: number) => callWorld("reportDeps.logTail", [most]), versions: () => callWorld("reportDeps.versions", []),
    envNames: () => callWorld("reportDeps.envNames", []), link: (k: string) => callWorld("reportDeps.link", [k]), home: "/Users/ann",
  };
  const routeAnswer = async (routes: any[], q: any) => {
    const r = { method: "POST", path: q.path, body: Buffer.from(q.body, "base64"), lang: q.lang, viewer: q.viewer };
    for (const route of routes) {
      const found = route.pattern.exec(q.path);
      if (found) {
        const a = await route.handle(r, found.slice(1));
        return { status: a.status, headers: a.headers, body: Buffer.from(a.body).toString("base64") };
      }
    }
    return null;
  };
  const doorReady = openAgentsDoor({ port: 0 }, endpoint, (auth: string | undefined, body: Buffer) => callWorld("door.notified", [auth, body]),
    () => {
      const v = callWorld("door.peers", []);
      if (v === null || v === undefined) return null;
      return {
        request: async (req: any, res: any, target: unknown) => {
          const a = callWorld("door.peer.request", [{ method: req.method, url: req.url }, target]);
          res.writeHead(a.status, a.headers).end(Buffer.from(a.body ?? "", "base64"));
        },
        upgrade: async (req: any, _s: unknown, _h: unknown, target: unknown) => void callWorld("door.peer.upgrade", [{ method: req.method, url: req.url }, target]),
      };
    },
    () => (callWorld("door.parts", []) ?? []).map((prefix: string) => ({
      prefix,
      request: async (req: any, res: any) => {
        const a = callWorld("door.part.request", [{ method: req.method, url: req.url }, prefix]);
        res.writeHead(a.status, a.headers).end(Buffer.from(a.body ?? "", "base64"));
      },
      upgrade: async (req: any) => void callWorld("door.part.upgrade", [{ method: req.method, url: req.url }, prefix]),
    })),
    (auth: string | undefined, body: Buffer) => callWorld("door.screened", [auth, body]));
  await doorReady;

  const buildLive = async () => {
    const captured: any = { tools: [], routes: [], overview: () => false, viewerMay: () => false };
    const parts = {
      tools: (t: any[]) => captured.tools.push(...t), routes: (r: any[]) => captured.routes.push(...r),
      viewerMay: (f: any) => (captured.viewerMay = f), overview: (_n: string, f: any) => (captured.overview = f),
    };
    const agents = { updates: P("agents.updates"), hub: P("agents.hub"), pageOf: (k: string) => callWorld("agents.pageOf", [k]) };
    const plane = { state: P("plane.state"), spec: () => callWorld("plane.spec", []), told: (what: string, f: unknown) => callWorld("plane.told", [what, f]) };
    const paths = { get data() { return callWorld("paths.data", []); } };
    const layer = FeedbackLive.pipe(Layer.provide(Layer.mergeAll(
      Layer.succeed(services.ControlPlane, plane as never), Layer.succeed(services.Key, P("key")), Layer.succeed(services.Store, P("store")),
      Layer.succeed(Agents, agents as never), Layer.succeed(services.Parts, parts as never), Layer.succeed(services.Paths, paths as never),
    )));
    const exit = await Effect.runPromiseExit(Effect.scoped(Layer.build(layer)));
    if (Exit.isFailure(exit)) throw Cause.squash(exit.cause);
    return captured.tools.length === 0 ? null : captured;
  };

  const F: Record<string, (...a: any[]) => unknown> = {
    typed: (a, s) => typed(a, s),
    fitted: (b) => {
      const all = listed();
      const { declared, indirect } = fitted(all, b);
      return { declared: declared.map((t: any) => t.name), indirect: indirect.map((t: any) => t.name) };
    },
    indirectTool: (names: string[]) => {
      const t = indirectTool(tools.filter((x: any) => names.includes(x.name)));
      return { name: t.name, description: t.description, inputSchema: t.inputSchema };
    },
    weights: () => Object.fromEntries(listed().map((t: any) => [t.name, weight(t)])),
    isSlackWrite: (s) => isSlackWrite(s), speaksInSlack: (s) => speaksInSlack(s),
    peerHttpBase: (u) => peerHttpBase(u), peerTarget: (u) => peerTarget(u), notFromHere: (h, p) => notFromHere(h, p),
    refuseUpgrade: (s, t) => {
      let out: Buffer = Buffer.alloc(0);
      refuseUpgrade({ on: () => {}, end: (b: Buffer) => (out = b) } as never, s, t);
      return out.toString("base64");
    },
    urlPathname: (u) => new URL(u, "http://agents").pathname,
    toUnit: (x, y, w, h) => toUnit({ x, y }, { width: w, height: h }),
    keyPresses: (c, e) => keyPresses(c, e), typing: (t) => typing(t),
    clicking: (x, y, b, d) => clicking({ x, y }, b, d), dragging: (fx, fy, tx, ty, b) => dragging({ x: fx, y: fy }, { x: tx, y: ty }, b),
    computerRun: (s, a) => tools.find((t: any) => t.name === "computer").run(s, a),
    computerOpen: () => computer.open(), computerCloseSession: (s) => (computer.closeSession(s), null), computerCloseAll: () => (computer.closeAll(), null),
    described: (base, id) => described(P("screens"), base, id),
    letGo: (by, id, action, view) => letGo(P("screens"), by, id, action, view),
    probeRelay: (u) => probeRelay(u),
    relaysWithoutMesh: (s, a) => relayTools({ ways: () => callWorld("relays.ways", []), workspaceOf: (s: string) => callWorld("relays.workspaceOf", [s]), by: (s: string) => callWorld("relays.by", [s]) })[0].run(s, a),
    noHelper: (s, a) => noHelper[0].run(s, a),
    report: (s, a, l) => report(s, a, l), fixedNotice: (r, s) => fixedNotice(r, s),
    tellFixed: () => tellFixed(async (told: string[]) => callWorld("feedback.fixed", [told]), (s: string, t: string) => callWorld("feedback.notify", [s, t])),
    reachedAt: (e, p) => reachedAt(e, p), summaryOf: (p, s) => summaryOf(p, s), planWords: (p, t, s) => planWords(p, t, s),
    outcomeOf: (o) => outcomeOf(o), roomWords: (r) => roomWords(r), outcomeWords: (o, h, s) => outcomeWords(o, h, s),
    moveTool: (s, a) => moves.tool(s, a), moveAnswer: (p, ws, r) => moves.answer(p, ws, r),
    moveMay: (v, c, at) => moves.may(v, c, at),
    moveChosen: async (v, c, o, at) => (moves.chosen(v, c, o, at), await moves.settle(), await new Promise((r) => setImmediate(r)), null),
    parseIso: (s) => {
      const v = Date.parse(s);
      return Number.isNaN(v) ? null : v;
    },
    isoString: (ms) => new Date(ms).toISOString(),
    logLines: (t, f, to, n, r, h) => logLines(t, f, to, n, r, h),
    failedTurnOf: (thread, at) => {
      const r = failedTurnOf(P("store"), thread, at);
      return r === null ? null : { session: r.session, turn: r.turn };
    },
    readTail: (p, most) => readTail(p, most),
    noticeReport: (t, e, v) => noticeReport(P("store"), t, e, v, reportDeps),
    reportRoute: (q) => routeAnswer(reportRoutes(P("store"), reportDeps, async (r: unknown) => callWorld("feedback.sendReport", [r])), q),
    formatSkill: (c, n, f) => formatSkillFromCatalog(c, n, f),
    skillForPeer: (r, ws, home) => skillForPeer(async (w: string | undefined) => callWorld("readCatalog", [w]), r, ws, home),
    searchForPeer: (r, ws, home) => searchForPeer(searchDeps, r, ws, home),
    device: (op, a, c, access) => Effect.runPromise(device.run(op, a, c, access)),
    deviceClose: () => (device.close(), null),
    accessOf: (r) => accessOf(r),
    feedbackLive: async () => {
      live = await buildLive();
      return live === null ? null : { tools: live.tools.map((t: any) => t.name), after: 300000 };
    },
    feedbackOverview: () => (live === null ? null : live.overview()),
    feedbackViewerMay: (m, p) => live!.viewerMay({ method: m, path: p }),
    feedbackTell: async () => {
      if (live === null) return null;
      for (const f of fibersAfter.slice(-1)) f();
      for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r));
      return null;
    },
    feedbackRoute: (q) => (live === null ? null : routeAnswer(live.routes, q)),
  };

  return {
    setup: setupWorld.log,
    mcp: async (q) => {
      const reply = await endpoint.handle(q.method, q.authorization, Buffer.from(q.body), new AbortController().signal);
      return { status: reply.status, body: reply.body === undefined ? null : JSON.parse(JSON.stringify(reply.body)) };
    },
    fn: async (q) => {
      try {
        const out = await F[q.name]!(...q.args.map(decode));
        return { ok: out === undefined ? null : (JSON.parse(JSON.stringify(out)) as Json) } as Json;
      } catch (e) {
        return { error: errorOf(e, ToolError, MeshRefused) } as Json;
      }
    },
    door: (q) => doorTs(q),
    upgrade: (q) => upgradeTs(q),
  };
}

// ---------------------------------------------------------------------------------------------------------------

/// What a door's answer is compared by: its status, its content type, its bytes and whether it was destroyed (Node's
/// own headers, its date and length, are the socket's).
const doorShown = (a: any): Json => ({ status: a.status, type: a.headers?.["content-type"] ?? null, extra: Object.fromEntries(Object.entries(a.headers ?? {}).filter(([k]) => k !== "content-type")) as Json, body: a.body, destroyed: a.destroyed === true });
const sorted = (log: [string, Json][]) => [...log].map((x) => JSON.stringify(x)).sort();

async function main() {
  const binary = readerBinary();
  const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;
  const zh = (await import("../../client/i18n/catalog/zh/station.json", { with: { type: "json" } })).default;
  const en = (await import("../../client/i18n/catalog/en/station.json", { with: { type: "json" } })).default;
  process.env.TZ = "UTC";
  const exported = exportsOf();
  await installMocks(exported.modules);
  globalThis.fetch = (async (url: string) => {
    const a = callWorld("fetch", [url]);
    return { ok: a.status >= 200 && a.status <= 299, status: a.status, arrayBuffer: async () => new ArrayBuffer(0) };
  }) as never;
  const RUNTIME_KINDS = exported.runtimes;
  const stationLang = () => exported.stationLang;
  defineCases();

  const shellDir = mkdtempSync(join(tmpdir(), "mb-mcp-tools-"));
  after(() => rmSync(shellDir, { recursive: true, force: true }));

  test("the MoonBit tools answer every case as the TypeScript ones, and ask the station's parts the same", { skip }, async () => {
    const program = new Program(binary!, shellDir);
    after(() => program.close());
    // (each side made in a world of its own: what it asks as it starts compared too)
    const ts = await typescriptSide();
    const tsSetup = ts.setup;
    const mbSetupWorld = baseWorld();
    program.use(mbSetupWorld);
    await program.setup({
      zh, en, product: "still.fail", data: "/data", ports: [4000],
      consts: { runtimes: RUNTIME_KINDS, stationLang: stationLang(), os: process.platform === "win32" ? "windows" : process.platform === "darwin" ? "darwin" : "linux", arch: process.arch, home: "/Users/ann" },
      move: { ask: true, setWait: true, refusal: true, room: true, told: true },
      device: { home: "/home/u", env: { PATH: "/bin", HOME: "/home/u" }, sessions: "deviceSessions" },
    });
    assert.deepEqual(mbSetupWorld.log, tsSetup, "what each asks as it is made");

    const failures: string[] = [];
    // (MB_TOOLS_DUMP=<file>: each case that differs written there whole, both answers and both calls)
    const dumped: unknown[] = [];
    const tools = new Set<string>();
    for (const c of CASES) {
      if (c.kind === "mcp") {
        let body: any = null;
        try {
          body = JSON.parse(c.q.body ?? "null");
        } catch {}
        if (body?.method === "tools/call" && typeof body.params?.name === "string") tools.add(body.params.name === "station_tool" ? body.params.arguments?.name : body.params.name);
      }
      const tsWorld = baseWorld();
      const mbWorld = baseWorld();
      c.world?.(tsWorld);
      c.world?.(mbWorld);
      current = tsWorld;
      children.length = 0;
      let tsOut: Json;
      if (c.kind === "mcp") tsOut = await ts.mcp(c.q);
      else if (c.kind === "door") tsOut = doorShown(await ts.door(c.q));
      else if (c.kind === "upgrade") tsOut = await ts.upgrade(c.q);
      else tsOut = await ts.fn(c.q);
      await Promise.all(children);
      for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
      program.use(mbWorld);
      const kind = c.kind;
      const q = c.kind === "mcp" ? { ...c.q, body: Buffer.from(c.q.body).toString("base64") } : c.kind === "door" || c.kind === "upgrade" ? { ...c.q, body: Buffer.from(c.q.body ?? "").toString("base64") } : c.q;
      let mbOut: any = await program.ask(kind, q);
      if (c.kind === "door") mbOut = doorShown(mbOut);
      const tsLog = tsWorld.log;
      const mbLog = mbWorld.log;
      try {
        assert.deepEqual(mbOut, tsOut, "the answer");
        if (c.unordered) assert.deepEqual(sorted(mbLog), sorted(tsLog), "the calls, in any order");
        else assert.deepEqual(mbLog, tsLog, "the calls");
      } catch (e) {
        failures.push(`${c.name}: ${(e as Error).message}`);
        if (process.env.MB_TOOLS_DUMP) dumped.push({ name: c.name, ts: tsOut, mb: mbOut, tsLog, mbLog });
      }
    }
    if (process.env.MB_TOOLS_DUMP) writeFileSync(process.env.MB_TOOLS_DUMP, dumped.map((d) => JSON.stringify(d)).join("\n"));
    if (program.failed.length > 0) failures.push(`the program said: ${program.failed.join("")}`);
    // (every tool called through the endpoint)
    const all = (await ts.mcp({ method: "POST", authorization: "Bearer t1", body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) })) as any;
    for (const t of all.body.result.tools) if (!tools.has(t.name)) failures.push(`no case calls ${t.name}`);
    assert.deepEqual(failures, [], `${failures.length} of ${CASES.length} cases differ`);
  });
}

// ---------------------------------------------------------------------------------------------------------------

if (!process.execArgv.includes("--experimental-test-module-mocks")) {
  const skip = readerBinary() === null ? "the MoonBit program (stillfail-reader) is not built here" : false;
  test("the MoonBit tools answer as the TypeScript ones (run with module mocks)", { skip }, async () => {
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
}
