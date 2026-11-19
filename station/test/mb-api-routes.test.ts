// The admin API in MoonBit (station/mb/src/api_routes, the reader's `--builder harness-api-routes`) held to the
// TypeScript one it replaces (src/api/admin.ts and every module of src/api/routes) on the same requests against the
// same station: each request is asked of both, and each answer's status, headers and bytes, and every call either
// made of the station's parts with what it gave them, must be the same.
//
// The station's parts are one world of the test's (`World`): a part's method (`store.getSession`, `hub.stop`) or a
// module's function (`sessions/lifecycle.newSession`, `fs.stat`) is a call the world answers from what it holds, as
// JSON (a part by reference `{"$ref"}`, bytes `{"$bytes"}`, undefined `{"$undef"}`), or a refusal it throws by its
// class's name. The TypeScript routes reach it through module mocks (node:test `mock.module`: every module a route
// imports from outside src/api, but the words, the paths and the credential's checks, which the program has as its
// own) and through proxies given the Admin as its parts; the program through its harness's calls on stdout. Two
// worlds made alike answer the two, so what either does to its world is its own.
//
// Module mocks need `--experimental-test-module-mocks`: run without it (as `pnpm test` runs a file), this file runs
// itself again with it, and fails as that run fails.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { after, mock, test } from "node:test";

const self = fileURLToPath(import.meta.url);
const station = fileURLToPath(new URL("..", import.meta.url));
const src = (p: string) => new URL(`../src/${p}`, import.meta.url).href;

// ---------------------------------------------------------------------------------------------------------------
// The world

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
type Handler = (args: any[], w: World) => any;

/// A refusal a part throws: its class's name and what it carries.
class Thrown {
  readonly kind: string;
  readonly fields: Record<string, Json>;
  constructor(kind: string, fields: Record<string, Json>) {
    this.kind = kind;
    this.fields = fields;
  }
}
const thrown = (kind: string, fields: Record<string, Json>) => new Thrown(kind, fields);

/// What the station's parts hold and answer, for one side.
class World {
  log: [string, Json][] = [];
  /// The files of the machine, by path: a file's bytes and mtime, or a directory.
  files = new Map<string, { bytes: Buffer; mtimeMs: number } | "dir">();
  state: Record<string, any> = {};
  counter = 0;
  readonly handlers: Map<string, Handler>;
  readonly patterns: [RegExp, Handler][];
  constructor(handlers: Map<string, Handler>, patterns: [RegExp, Handler][]) {
    this.handlers = handlers;
    this.patterns = patterns;
  }
  answer(name: string, args: any[]): any {
    if (!UNRECORDED.has(name) && !UNRECORDED_RE.some((re) => re.test(name))) this.log.push([name, args as Json]);
    const h = this.handlers.get(name) ?? this.patterns.find(([re]) => re.test(name))?.[1];
    if (h === undefined) return { $undef: 1 };
    const v = h(args, this);
    return v === undefined ? { $undef: 1 } : v;
  }
}

/// Calls not compared: a constant read, a stream read on.
const UNRECORDED = new Set(["ops/version.version", "$stream.next", "os.homedir"]);
const UNRECORDED_RE: RegExp[] = [];

// ---------------------------------------------------------------------------------------------------------------
// The TypeScript side's way to it: proxies for parts, module mocks for functions

let current: World | null = null;
const world = () => {
  if (current === null) throw new Error("no world");
  return current;
};

const PROXY_NAME = new WeakMap<object, string>();
const proxies = new Map<string, any>();
/// A part by its name: every field a part too (`hub.store`), every call a call of the world.
function P(name: string): any {
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

/// Calls whose answer the TypeScript side takes as a promise (it chains it or does not wait for it).
const ASYNC = new Set([
  "hub.warm", "sessions/cc.cc", "accounts.check", "copies.restore", "slack.refreshIdentity", "sessions/review.reviewUndecided",
  "secrets.preparePending",
]);
/// Calls whose answer is the same object while it is the same value (a lock the station keeps).
const SAME = new Set(["vault.lock"]);
const sameKept = new Map<string, [string, unknown]>();
const ASYNC_RE: RegExp[] = [/^fs\./];

function callWorld(name: string, args: unknown[]): any {
  const w = world();
  const encoded = args.map((a) => encode(a, true));
  const isAsync = ASYNC.has(name) || ASYNC_RE.some((re) => re.test(name));
  let out: any;
  try {
    const raw = w.answer(name, encoded);
    if (SAME.has(name)) {
      const text = JSON.stringify(raw);
      const had = sameKept.get(name);
      out = had !== undefined && had[0] === text ? had[1] : decode(raw);
      sameKept.set(name, [text, out]);
    } else out = decode(raw);
  } catch (e) {
    if (isAsync) return Promise.reject(asError(e));
    throw asError(e);
  }
  return isAsync ? Promise.resolve(out) : out;
}

/// What the TypeScript side throws for a world's refusal.
const ERRORS = new Map<string, () => object>();
function asError(e: unknown): unknown {
  if (!(e instanceof Thrown)) return e;
  const proto = ERRORS.get(e.kind)?.() ?? Error.prototype;
  const err = Object.create(proto);
  Object.assign(err, e.fields);
  Object.defineProperty(err, "message", { value: String(e.fields.message ?? ""), enumerable: false, writable: true });
  Object.defineProperty(err, "stack", { value: `${e.kind}: ${e.fields.message}`, enumerable: false, writable: true });
  return err;
}

let OMIT: symbol | undefined;

function encode(v: unknown, top = false): Json {
  if (v === undefined) return top ? { $undef: 1 } : null;
  if (v !== null && typeof v === "object" && PROXY_NAME.has(v)) return { $ref: PROXY_NAME.get(v)! };
  if (v === null || typeof v === "boolean" || typeof v === "string") return v;
  if (typeof v === "number") return v;
  if (typeof v === "bigint") return { $bigint: String(v) };
  if (typeof v === "symbol") return v === OMIT ? { $omit: 1 } : { $symbol: String(v.description) };
  if (typeof v === "function") {
    const name = PROXY_NAME.get(v);
    return name !== undefined ? { $ref: name } : { $fn: true };
  }
  if (Buffer.isBuffer(v) || v instanceof Uint8Array) return { $bytes: Buffer.from(v).toString("base64") };
  if (v instanceof AbortSignal) return { $signal: true };
  if (v instanceof Set) return { $set: [...v].map((x) => encode(x)) };
  if (v instanceof Map) return { $map: [...v].map(([k, x]) => [encode(k), encode(x)]) };
  if (v instanceof Error) return { $error: { message: v.message, ...(encode({ ...v }) as object) } };
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
  if ("$omit" in v && Object.keys(v).length === 1) return OMIT;
  if ("$bytes" in v && Object.keys(v).length === 1) return Buffer.from(v.$bytes, "base64");
  if ("$set" in v && Object.keys(v).length === 1) return new Set(decode(v.$set));
  if ("$map" in v && Object.keys(v).length === 1) return new Map(decode(v.$map));
  if ("$stream" in v && Object.keys(v).length === 1) {
    const id = v.$stream;
    const w = world();
    return {
      async *[Symbol.asyncIterator]() {
        for (;;) {
          const piece = decode(w.answer("$stream.next", [id]));
          if (piece === null || piece === undefined) return;
          yield piece;
        }
      },
    };
  }
  const out: Record<string, any> = {};
  for (const [k, x] of Object.entries(v)) out[k] = decode(x);
  return out;
}

/// An object of the test's taken for the part `ref` (a file's handle): given back by reference.
function named<T extends object>(ref: string, o: T): T {
  PROXY_NAME.set(o, ref);
  return o;
}

const toStats = (s: any) => ({ ...s, isFile: () => s.file === true, isDirectory: () => s.dir === true });

/// node:fs/promises, as the world's files.
function fsPromises() {
  const call = (name: string) => (...args: unknown[]) => callWorld(`fs.${name}`, args);
  const handle = (ref: string) => named(ref, {
    stat: async () => toStats(callWorld(`${ref}.stat`, [])),
    read: async (buf: Buffer, off: number, len: number, pos: number) => {
      const got = callWorld(`${ref}.read`, [buf, off, len, pos]);
      Buffer.from(got.buffer).copy(buf, off, 0, got.bytesRead);
      return { bytesRead: got.bytesRead, buffer: buf };
    },
    close: async () => void callWorld(`${ref}.close`, []),
  });
  return {
    stat: async (p: string) => toStats(await callWorld("fs.stat", [p])),
    lstat: async (p: string) => toStats(await callWorld("fs.lstat", [p])),
    readdir: async (p: string, opts?: { withFileTypes?: boolean }) => {
      const got = await callWorld("fs.readdir", opts === undefined ? [p] : [p, opts]);
      return opts?.withFileTypes ? got.map((d: any) => ({ name: d.name, isDirectory: () => d.dir === true, isFile: () => d.dir !== true })) : got;
    },
    open: async (p: string, flags: string) => handle(PROXY_NAME.get(await callWorld("fs.open", [p, flags]))!),
    readFile: call("readFile"), writeFile: call("writeFile"), appendFile: call("appendFile"), mkdir: call("mkdir"),
    rename: call("rename"), rm: call("rm"), copyFile: call("copyFile"), statfs: call("statfs"), access: call("access"),
    unlink: call("unlink"), realpath: call("realpath"), readlink: call("readlink"), chmod: call("chmod"), symlink: call("symlink"),
    cp: call("cp"), mkdtemp: call("mkdtemp"), truncate: call("truncate"), utimes: call("utimes"),
  };
}

/// Each module a route imports from outside src/api, as the world answers it: a function its call, an object of
/// functions a part, a class and a constant as they are.
const MOCKED: [string, string][] = [
  ["../../client/core-ts/src/cache-policy.ts", "core/cache-policy"],
  ["../../client/core-ts/src/model-speed.ts", "core/model-speed"],
  ["../../client/core-ts/src/preset-records.ts", "core/preset-records"],
  ["accounts/index.ts", "accounts/index"],
  ["agents/runtime.ts", "agents/runtime"],
  ["cli.ts", "cli"],
  ["cloud/lock.ts", "cloud/lock"],
  ["comma/index.ts", "comma/index"],
  ["device/tools.ts", "device/tools"],
  ["drive/drive.ts", "drive/drive"],
  ["drive/fs.ts", "drive/fs"],
  ["drive/grants.ts", "drive/grants"],
  ["drive/posters.ts", "drive/posters"],
  ["drive/thumbs.ts", "drive/thumbs"],
  ["drive/transfers.ts", "drive/transfers"],
  ["drive/watch.ts", "drive/watch"],
  ["feishu/surface.ts", "feishu/surface"],
  ["feishu/web.ts", "feishu/web"],
  ["helper/files.ts", "helper/files"],
  ["helper/grants.ts", "helper/grants"],
  ["jobs/jobs.ts", "jobs/jobs"],
  ["jobs/preview.ts", "jobs/preview"],
  ["links/preview.ts", "links/preview"],
  ["logins/index.ts", "logins/index"],
  ["mesh/bus.ts", "mesh/bus"],
  ["mesh/settings.ts", "mesh/settings"],
  ["ops/agent-env.ts", "ops/agent-env"],
  ["ops/fibers.ts", "ops/fibers"],
  ["ops/log.ts", "ops/log"],
  ["ops/restart.ts", "ops/restart"],
  ["ops/version.ts", "ops/version"],
  ["platform/index.ts", "platform/index"],
  ["read/machine.ts", "read/machine"],
  ["read/runtime-view.ts", "runtimeView"],
  ["read/sessions.ts", "read/sessions"],
  ["read/views.ts", "read/views"],
  ["resources/watch.ts", "resources/watch"],
  ["screens/hub.ts", "screens/hub"],
  ["screens/source.ts", "screens/source"],
  ["sessions/archive-policy.ts", "sessions/archive-policy"],
  ["sessions/archive.ts", "sessions/archive"],
  ["sessions/cc.ts", "sessions/cc"],
  ["sessions/clones.ts", "sessions/clones"],
  ["sessions/config.ts", "sessions/config"],
  ["sessions/context-cap.ts", "sessions/context-cap"],
  ["sessions/footprint.ts", "sessions/footprint"],
  ["sessions/image-size.ts", "sessions/image-size"],
  ["sessions/lifecycle.ts", "sessions/lifecycle"],
  ["sessions/presets.ts", "sessions/presets"],
  ["sessions/regenerate-title.ts", "sessions/regenerate-title"],
  ["sessions/relay.ts", "sessions/relay"],
  ["sessions/review.ts", "sessions/review"],
  ["slack/index.ts", "slack/index"],
  ["store/rows.ts", "rows"],
  ["updates/versions.ts", "updates/versions"],
  ["vault/crypto.ts", "vault/crypto"],
  ["vault/plain.ts", "vault/plain"],
  ["vault/store.ts", "vault/store"],
];

/// What of a mocked module stays its own: what the program has as its own too (a constant's value, a pure check).
const KEPT: Record<string, string[]> = {
  "rows": ["STILLFAIL_SURFACE", "handedWs", "sees", "seesMissing", "remoteWs", "STILLFAIL_CONNECT"],
  "jobs/preview": ["previewTarget"],
};

/// Functions given a callback, as the world sees them: what they hold around it said before and after.
const OVERRIDES: Record<string, Record<string, any>> = {
  "drive/watch": {
    FolderWatches: class {
      changed(dir: string, id: string) {
        return callWorld("drive/watch.changed", [dir, id]);
      }
      follow(dir: string, told: () => void) {
        return callWorld("drive/watch.follow", [dir, told]);
      }
    },
  },
  "sessions/archive": {
    withLock: async (room: string, f: () => Promise<unknown>) => {
      callWorld("sessions/archive.withLock.enter", [room]);
      try {
        return await f();
      } finally {
        callWorld("sessions/archive.withLock.exit", [room]);
      }
    },
  },
};

const isClass = (f: unknown) => typeof f === "function" && /^class[\s{]/.test(Function.prototype.toString.call(f));
const hasFunctions = (o: object) => Object.values(o).some((x) => typeof x === "function");

async function installMocks(): Promise<void> {
  for (const [path, prefix] of MOCKED) {
    const url = src(path);
    const real = await import(url);
    const exports: Record<string, unknown> = {};
    for (const [name, value] of Object.entries(real)) {
      if (OVERRIDES[prefix]?.[name] !== undefined) {
        exports[name] = OVERRIDES[prefix]![name];
        continue;
      }
      if (KEPT[prefix]?.includes(name) || isClass(value)) exports[name] = value;
      else if (typeof value === "function") exports[name] = (...args: unknown[]) => callWorld(`${prefix}.${name}`, args);
      else if (value !== null && typeof value === "object" && !Array.isArray(value) && !(value instanceof RegExp) && hasFunctions(value)) exports[name] = P(`${prefix}.${name}`);
      else exports[name] = value;
      if (isClass(value)) ERRORS.set(`${prefix}.${name}`, () => (value as { prototype: object }).prototype);
    }
    if (prefix === "runtimeView") OMIT = real.OMIT;
    // (`exports`: node 24's own, which its types from before do not say yet)
    mock.module(url, { exports } as never);
  }
  const builtin = async (name: string, over: Record<string, unknown>) => {
    const real = { ...(await import(name)) } as Record<string, unknown>;
    delete real.default;
    const exports = { ...real, ...over };
    mock.module(name, { exports: { ...exports, default: { ...exports } } } as never);
  };
  await builtin("node:crypto", { randomBytes: (n: number) => callWorld("crypto.randomBytes", [n]), createHash: (alg: string) => callWorld("crypto.createHash", [alg]) });
  await builtin("node:fs", { createReadStream: (p: string, opts: unknown) => callWorld("fs.createReadStream", [p, opts]) });
  await builtin("node:fs/promises", fsPromises());
  await builtin("node:os", { cpus: () => callWorld("os.cpus", []), totalmem: () => callWorld("os.totalmem", []), homedir: () => callWorld("os.homedir", []) });
}

// ---------------------------------------------------------------------------------------------------------------
// The program's side

class Program {
  #proc;
  #waiting = new Map<number | string, (said: any) => void>();
  #world: World | null = null;
  #next = 0;
  #lines: string[] = [];
  readonly failed: string[] = [];
  constructor(binary: string, shellDir: string) {
    this.#proc = spawn(binary, ["--builder", "harness-api-routes", "--shell-dir", shellDir], { stdio: ["pipe", "pipe", "pipe"] });
    this.#proc.stderr.on("data", (b) => this.failed.push(String(b)));
    createInterface({ input: this.#proc.stdout }).on("line", (line) => this.#told(line));
  }
  #told(line: string) {
    const said = JSON.parse(line);
    if ("call" in said) {
      let reply: Record<string, unknown>;
      try {
        const value = this.#world!.answer(said.name, said.args);
        reply = { ret: said.call, value };
      } catch (e) {
        if (!(e instanceof Thrown)) throw e;
        reply = { ret: said.call, throw: { kind: e.kind, ...e.fields } };
      }
      this.#proc.stdin.write(`${JSON.stringify(reply)}\n`);
      return;
    }
    const key = "ans" in said ? `ans:${said.ans}` : "claimed" in said ? `claim:${said.claimed}` : "settled" in said ? `settled:${said.settled}` : Object.keys(said)[0]!;
    const w = this.#waiting.get(key);
    if (w) {
      this.#waiting.delete(key);
      w(said);
    } else this.#lines.push(line);
  }
  #wait(key: string): Promise<any> {
    return new Promise((resolve) => this.#waiting.set(key, resolve));
  }
  async start(setup: Record<string, unknown>) {
    const ready = this.#wait("ready");
    this.#proc.stdin.write(`${JSON.stringify({ setup })}\n`);
    await ready;
  }
  use(w: World) {
    this.#world = w;
  }
  async ask(req: Record<string, unknown>): Promise<any> {
    const id = ++this.#next;
    const got = this.#wait(`ans:${id}`);
    this.#proc.stdin.write(`${JSON.stringify({ req: { ...req, id } })}\n`);
    const said = await got;
    const drained = this.#wait("drained");
    this.#proc.stdin.write(`${JSON.stringify({ drain: true })}\n`);
    await drained;
    return said;
  }
  async line(v: Record<string, unknown>, key: string): Promise<any> {
    const got = this.#wait(key);
    this.#proc.stdin.write(`${JSON.stringify(v)}\n`);
    return got;
  }
  close() {
    this.#proc.stdin.end();
    this.#proc.kill();
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The cases

type Asked = {
  method: string;
  path: string;
  query?: [string, string][];
  headers?: Record<string, string>;
  body?: string | Buffer | object;
  viewer?: Record<string, unknown>;
  lang?: "zh" | "en";
};
type Case = { name: string; ask: Asked; world?: (w: World) => void; unordered?: boolean };

const OWNER = { sub: "u1", email: "ann@example.com", name: "Ann", role: "owner", workspace: "w1", device: "d1", home: true };
const MEMBER = { ...OWNER, sub: "u2", email: "bob@example.com", name: "Bob", role: "member" };
const VIEWER = { ...OWNER, sub: "u3", email: "cy@example.com", name: "Cy", role: "viewer" };
const OTHER_WS = { ...OWNER, sub: "u4", email: "dee@example.com", name: "Dee", role: "member", workspace: "w2", home: false };

const DATA = "/data";
const CASES: Case[] = [];
const add = (name: string, ask: Asked, more: Omit<Case, "name" | "ask"> = {}) => CASES.push({ name, ask, ...more });

async function main() {
  const { mbReaderBinary } = await import("../src/read/mb-reader.ts");
  const binary = mbReaderBinary();
  const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;
  const zh = (await import("../../client/i18n/catalog/zh/station.json", { with: { type: "json" } })).default;
  const en = (await import("../../client/i18n/catalog/en/station.json", { with: { type: "json" } })).default;
  await installMocks();
  for (const [k, v] of [...ERRORS]) if (k.includes(".")) ERRORS.set(k.slice(k.lastIndexOf(".") + 1), v);
  const { Refused } = await import("../src/api/request.ts");
  ERRORS.set("Refused", () => Refused.prototype);
  ERRORS.set("HttpError", () => Refused.prototype);
  process.env.STILLFAIL_DEV = "1";
  const { RUNTIME_KINDS } = await import("../src/agents/runtime.ts");
  ALL_RUNTIMES = RUNTIME_KINDS.join(",");
  const { Admin } = await import("../src/api/admin.ts");
  PART_ROUTES = await partRoutes();
  defineCases();

  const shellDir = mkdtempSync(join(tmpdir(), "mb-api-routes-"));
  after(() => rmSync(shellDir, { recursive: true, force: true }));

  test("the MoonBit admin API answers every route as the TypeScript one, and asks the station's parts the same", { skip }, async () => {
    const program = new Program(binary!, shellDir);
    after(() => program.close());
    await program.start({ zh, en, product: "still.fail", build: BUILD, runtimes: RUNTIME_KINDS, dev: true, data: DATA, absent: [], grantKey: GRANT_KEY.toString("base64"), stationLang: "zh" });
    current = baseWorld();
    const admin = new Admin(P("readers"), adminDeps() as never);
    // (what each side does as it starts, its parts' routes made, in a world of its own)
    await admin.handle({ ...request({ method: "GET", path: "/nope" }), signal: new AbortController().signal } as never);
    program.use(baseWorld());
    await program.line({ start: true }, "started");
    const mismatches: string[] = [];
    for (const c of CASES) {
      const req = request(c.ask);
      const tsWorld = baseWorld();
      c.world?.(tsWorld);
      current = tsWorld;
      let tsAnswer: any;
      let tsBody: Buffer;
      try {
        tsAnswer = await admin.handle({ ...req, body: req.body, signal: new AbortController().signal } as never);
        tsBody = await bodyOf(tsAnswer.body);
      } catch (e) {
        if (!(e instanceof Refused)) {
          mismatches.push(`${c.name}: the TypeScript side threw ${(e as Error).stack}`);
          continue;
        }
        tsAnswer = { refused: { status: e.status, message: e.message } };
        tsBody = Buffer.alloc(0);
      }
      await settleMicrotasks();
      const mbWorld = baseWorld();
      c.world?.(mbWorld);
      program.use(mbWorld);
      current = mbWorld;
      const mb = await program.ask({ ...req, body: req.body.toString("base64") });
      if ("failed" in mb) {
        mismatches.push(`${c.name}: the program failed: ${mb.failed}`);
        continue;
      }
      if ("refused" in mb || "refused" in tsAnswer) {
        const a = JSON.stringify(mb.refused ?? null);
        const b = JSON.stringify(tsAnswer.refused ?? null);
        if (a !== b) mismatches.push(`${c.name}: refused ${a}, TypeScript ${b}`);
        continue;
      }
      const mbBody = Buffer.from(mb.body, "base64");
      if (process.env.MB_API_ROUTES_CASE === c.name) console.log(JSON.stringify({ status: mb.status, headers: mb.headers, body: mbBody.toString("utf8"), calls: mbWorld.log }));
      const diffs: string[] = [];
      if (mb.status !== tsAnswer.status) diffs.push(`status ${mb.status}, TypeScript ${tsAnswer.status}`);
      const tsHeaders = JSON.stringify(sorted(tsAnswer.headers));
      const mbHeaders = JSON.stringify(sorted(mb.headers));
      if (tsHeaders !== mbHeaders) diffs.push(`headers ${mbHeaders}, TypeScript ${tsHeaders}`);
      if (!mbBody.equals(tsBody)) diffs.push(`body ${mbBody.toString("utf8").slice(0, 600)}\n   TypeScript ${tsBody.toString("utf8").slice(0, 600)}`);
      const tsLog = tsWorld.log.map(canonical);
      const mbLog = mbWorld.log.map(canonical);
      if (c.unordered) {
        tsLog.sort();
        mbLog.sort();
      }
      const at = firstDiff(tsLog, mbLog);
      if (at !== null) diffs.push(`calls differ at ${at}:\n   program    ${mbLog.slice(at, at + 3).join("\n              ")}\n   TypeScript ${tsLog.slice(at, at + 3).join("\n              ")}`);
      if (diffs.length > 0) mismatches.push(`${c.name} (${c.ask.method} ${c.ask.path}):\n  ${diffs.join("\n  ")}`);
    }
    // A message the program writes itself (mesh/served.ts `say`): its key claimed, settled, carried to another station.
    const kept = (k: any) => k && { status: k.status, headers: sorted(k.headers), body: Buffer.from(k.body).toString("base64") };
    const claimsOf = async (w: () => World, ts: boolean) => {
      const out: unknown[] = [];
      let n = 0;
      const claim = async (viewer: object, path: string, key: string | null) => {
        const world = w();
        n += 1;
        if (ts) {
          current = world;
          const c: any = await admin.claimSay(viewer as never, path, key, "zh");
          return { world, said: "kept" in c ? { kept: kept(c.kept) } : "refused" in c ? { refused: kept(c.refused) } : { ts: c.ts }, settle: c.settle };
        }
        program.use(world);
        current = world;
        const said = await program.line({ claimSay: { id: n, viewer, path, key, lang: "zh" } }, `claim:${n}`);
        const id = n;
        return {
          world,
          said: said.kept ? { kept: kept({ ...said.kept, body: Buffer.from(said.kept.body, "base64") }) } : said.refused ? { refused: kept({ ...said.refused, body: Buffer.from(said.refused.body, "base64") }) } : { ts: said.ts },
          settle: async (answer: any) => void (await program.line({ settle: { id, answer: answer && { ...answer, body: answer.body.toString("base64") } } }, `settled:${id}`)),
        };
      };
      const answer = { status: 200, headers: { "content-type": "application/json" }, body: Buffer.from('{"n":3}') };
      const a = await claim(OWNER, "/threads/7/messages", "k1");
      await a.settle(answer);
      out.push(a.said, a.world.log.map(canonical));
      const again = await claim(OWNER, "/threads/7/messages", "k1");
      out.push(again.said, again.world.log.map(canonical));
      const refusedNow = await claim(OWNER, "/threads/7/messages", "k2");
      await refusedNow.settle({ ...answer, status: 503 });
      out.push(refusedNow.said, refusedNow.world.log.map(canonical));
      const unkeyed = await claim(OWNER, "/threads/7/messages", null);
      out.push(unkeyed.said);
      out.push((await claim(OWNER, "/threads/10/messages", "k3")).said);
      out.push((await claim({ ...OWNER, workspace: "w-moving" }, "/threads/7/messages", "k4")).said);
      // carried: what is kept of thread 7 as thread 70 there; what another station kept, kept here
      if (ts) {
        out.push(admin.keptSends(new Map([[7, 70]])).map((k) => ({ ...k, headers: sorted(k.headers) })));
        admin.keepSends([{ viewer: "bob@example.com", thread: 8, key: "k8", at: 999000, status: 200, headers: { a: "1" }, body: Buffer.from("{}").toString("base64") }]);
      } else {
        const said = await program.line({ keptSends: { threads: [[7, 70]] } }, "keptSends");
        out.push(said.keptSends.map((k: any) => ({ ...k, headers: sorted(k.headers) })));
        await program.line({ keepSends: [{ viewer: "bob@example.com", thread: 8, key: "k8", at: 999000, status: 200, headers: { a: "1" }, body: Buffer.from("{}").toString("base64") }] }, "keptSendsKept");
      }
      out.push((await claim(MEMBER, "/threads/8/messages", "k8")).said);
      // written elsewhere: told the store's followers and delivered to the chat's sessions
      const world = w();
      if (ts) {
        current = world;
        admin.saidElsewhere(7, 4, "hi", { thread: 7, n: 4 });
      } else {
        program.use(world);
        await program.line({ saidElsewhere: { thread: 7, n: 4, text: "hi", row: { thread: 7, n: 4 } } }, "saidElsewhereDone");
      }
      out.push(world.log.map(canonical));
      return out;
    };
    const claimWorld = () => {
      const w = baseWorld();
      w.handlers.set("rows.toEntry", ([row]) => ({ ...row, entry: true }));
      return w;
    };
    const tsClaims = JSON.stringify(await claimsOf(claimWorld, true), null, 1);
    const mbClaims = JSON.stringify(await claimsOf(claimWorld, false), null, 1);
    if (process.env.MB_API_ROUTES_SHOW) console.log(tsClaims);
    if (tsClaims !== mbClaims) mismatches.push(`a message's key claimed:\n program    ${mbClaims}\n TypeScript ${tsClaims}`);

    // Every route of the admin API asked at least once: the first that answers each case, as Admin.answer finds it.
    const table: { method: string; pattern: RegExp }[] = [...(admin as any).routes, ...(MADE_PARTS ?? [])];
    const asked = new Set<number>();
    for (const c of CASES) {
      const at = table.findIndex((route) => route.method === c.ask.method && route.pattern.test(c.ask.path));
      if (at >= 0) asked.add(at);
    }
    const unasked = table.map((route, i) => (asked.has(i) ? null : `${route.method} ${route.pattern}`)).filter((x) => x !== null);
    console.log(`# routes: ${table.length}, asked: ${asked.size}, requests: ${CASES.length}`);
    if (unasked.length > 0) mismatches.push(`routes no case asks:\n  ${unasked.join("\n  ")}`);
    if (program.failed.length > 0 && mismatches.length > 0) mismatches.push(`program's stderr: ${program.failed.join("").slice(-4000)}`);
    assert.deepEqual(mismatches, [], `${mismatches.length} of ${CASES.length} requests answered otherwise:\n${mismatches.join("\n")}`);
  });
}

const BUILD = "0.1.9999";
let ALL_RUNTIMES = "";

function request(a: Asked) {
  const body = a.body === undefined ? Buffer.alloc(0) : Buffer.isBuffer(a.body) ? a.body : Buffer.from(typeof a.body === "string" ? a.body : JSON.stringify(a.body));
  const query = a.query ?? [];
  const search = query.length === 0 ? "" : `?${query.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&")}`;
  const headers = { "stillfail-runtimes": ALL_RUNTIMES, ...(a.headers ?? {}) };
  return {
    method: a.method,
    path: a.path,
    query,
    search,
    headers,
    body,
    viewer: a.viewer ?? OWNER,
    lang: a.lang ?? "zh",
  };
}

async function bodyOf(body: Buffer | AsyncIterable<Buffer | Uint8Array>): Promise<Buffer> {
  if (Buffer.isBuffer(body)) return body;
  const parts: Buffer[] = [];
  for await (const chunk of body) parts.push(Buffer.from(chunk));
  return Buffer.concat(parts);
}

const settleMicrotasks = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

const sorted = (o: Record<string, string>) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));

function canonical(v: unknown): string {
  const norm = (x: any): any =>
    Array.isArray(x) ? x.map(norm)
    : x !== null && typeof x === "object" ? ("$fn" in x ? { $fn: true } : Object.fromEntries(Object.keys(x).sort().map((k) => [k, norm(x[k])])))
    : x;
  return JSON.stringify(norm(v));
}

function firstDiff(a: string[], b: string[]): number | null {
  for (let i = 0; i < Math.max(a.length, b.length); i++) if (a[i] !== b[i]) return i;
  return null;
}

// ---------------------------------------------------------------------------------------------------------------
// The station the cases ask: a home workspace w1 with sessions s1 (thread 7, its own), s2 (thread 8), a session of
// workspace w2 (s9, thread 9), a session handed to another station (sh, thread 10).

let PART_ROUTES: (tools: any) => any[] = () => [];

/// The station's parts' routes, made as each part's module makes them, in the order the program has them.
async function partRoutes(): Promise<(tools: any) => any[]> {
  const usage = await import("../src/api/routes/usage.ts");
  const search = await import("../src/api/routes/search.ts");
  const links = await import("../src/api/routes/links.ts");
  const logins = await import("../src/api/routes/logins.ts");
  const vault = await import("../src/api/routes/vault.ts");
  const requests = await import("../src/api/routes/vault-requests.ts");
  const signins = await import("../src/api/routes/signins.ts");
  const comma = await import("../src/api/routes/comma.ts");
  const feishu = await import("../src/api/routes/feishu.ts");
  const group = await import("../src/api/routes/group.ts");
  const slack = await import("../src/api/routes/slack.ts");
  const copies = await import("../src/api/routes/copies.ts");
  const transfers = await import("../src/api/routes/transfers.ts");
  const connectDeps = () => ({
    config: configFile(), data: DATA, hub: () => P("hub"),
    overview: (viewer: unknown, lang: unknown) => callWorld("agents.overview", [viewer, lang]),
    place: () => callWorld("agents.place", []), heldBy: P("agents.heldBy"),
  });
  const lock = (ws: string) => callWorld("vault.lock", [ws]);
  return (tools) => (MADE_PARTS ??= [
    ...usage.usageRoutes(tools, () => callWorld("usage.readingAll", [])),
    ...usage.resourceRoutes(tools, P("resources.watch")),
    ...search.routes({ search: P("search"), config: configFile(), events: P("events") }),
    ...links.routes(),
    ...logins.routes(() => P("logins")),
    ...logins.pageRoutes(() => P("logins"), () => P("accounts")),
    ...vault.routes({ vaults: P("vaults"), lock, events: P("events"), beforeWrite: () => callWorld("vault.beforeWrite", []), boxed: (l: unknown, c: unknown) => callWorld("vault.boxed", [l, c]) }),
    ...requests.routes({ secrets: P("secrets"), plain: P("secrets.plain"), lock, events: P("events") }),
    ...signins.routes(P("signIns")),
    ...comma.commaRoutes(connectDeps()),
    ...feishu.feishuRoutes({ ...connectDeps(), feishu: P("feishu") }),
    ...group.groupRoutes(connectDeps()),
    ...slack.routes({ ...connectDeps(), slack: P("slack"), store: P("store"), overviewChanged: () => callWorld("events.overviewChanged", []) }),
    ...copies.routes({ copies: P("copies"), retire: P("retire"), starts: true }),
    ...transfers.routes({ drive: P("drive"), transfers: P("transfers"), key: GRANT_KEY, self: () => callWorld("transfers.self", []), nameOf: (st: string) => callWorld("transfers.nameOf", [st]), now: () => callWorld("transfers.now", []) }),
  ]);
}

const GRANT_KEY = Buffer.alloc(32, 7);
/// The parts' routes as the Admin made them (for what the cases cover).
let MADE_PARTS: any[] | null = null;

/// A part with some of its methods the test's own (around a callback the world is not given).
function partWith(name: string, own: Record<string, unknown>): any {
  const base = P(name);
  const proxy = new Proxy(base, { get: (t, prop) => (typeof prop === "string" && prop in own ? own[prop] : t[prop as any]) });
  PROXY_NAME.set(proxy, name);
  return proxy;
}

/// config.json (ConfigFile): `updateSoon` edits what `raw` gives and writes it.
const configFile = () =>
  partWith("config", {
    updateSoon: async (edit: (raw: any) => unknown) => {
      const raw = callWorld("config.raw", []);
      await edit(raw);
      callWorld("config.updateSoon", [raw]);
    },
  });

function adminDeps() {
  const agents = {
    hub: P("hub"), jobs: P("jobs"), config: configFile(), cloud: P("cloud"), updates: P("updates"), xshare: P("xshare"),
    accounts: P("accounts"), sharing: P("sharing"), connectKinds: P("connectKinds"), heldBy: P("agents.heldBy"),
    overview: (viewer: unknown, lang: unknown) => callWorld("agents.overview", [viewer, lang]),
    place: () => callWorld("agents.place", []),
  };
  return {
    events: P("events"), store: P("store"), host: P("host"), clock: P("clock"), screens: P("screens"), agents,
    config: configFile(), data: DATA, restartFront: () => callWorld("restartFront", []), cloud: P("cloud"), helper: null,
    grants: P("grants"), drive: P("drive"),
    parts: {
      allRoutes: (tools: any) => PART_ROUTES(tools),
      mayView: (r: unknown) => callWorld("parts.mayView", [{ method: (r as any).method, path: (r as any).path }]),
      cardChoiceOf: (card: unknown) => callWorld("parts.cardChoiceOf", [card]),
    },
  };
}

const SESSIONS: Record<string, any> = {
  s1: { key: "s1", workspace: "/rooms/s1", ws: null, profile: "p1" },
  s2: { key: "s2", workspace: "/rooms/s2", ws: null, profile: "p2" },
  s9: { key: "s9", workspace: "/rooms/s9", ws: "w2", profile: "p1" },
  sh: { key: "sh", workspace: "/rooms/sh", ws: "handed:w1", profile: "p1" },
};
/// Other stations' tasks run here: no session of theirs (store/rows.ts `seesMissing`).
const REMOTE_JOBS: Record<string, string> = { jr1: "remote:w1:st:a", jr2: "remote:w2:st:b", jr3: "remote:w3:st:c", jrx: "remote:w2" };
const THREADS: Record<number, any> = {
  7: { id: 7, surface: "ember", sessions: ["s1"] },
  8: { id: 8, surface: "slack", sessions: ["s2"] },
  9: { id: 9, surface: "ember", sessions: ["s9"] },
  10: { id: 10, surface: "ember", sessions: ["sh"] },
};

function baseWorld(): World {
  const h = new Map<string, Handler>();
  const patterns: [RegExp, Handler][] = [];
  const w = new World(h, patterns);
  const on = (name: string, f: Handler) => h.set(name, f);
  // the store
  on("store.getSession", ([k]) => (SESSIONS[k] ? { ...SESSIONS[k] } : null));
  on("hub.store.getSession", ([k]) => (SESSIONS[k] ? { ...SESSIONS[k] } : null));
  on("store.sessionWs", ([k]) => (SESSIONS[k] ? SESSIONS[k].ws ?? null : undefined));
  on("store.getThread", ([n]) => (THREADS[n] ? { id: n, surface: THREADS[n].surface, title: null } : null));
  on("store.threadSessions", ([n]) => (THREADS[n]?.sessions ?? []).map((s: string) => ({ session: s, thread: n })));
  on("store.handedTo", ([k]) => (k === "sh" ? { station: "st2", ws: "w1", thread: 10, there: 70 } : null));
  on("store.getJob", ([id]) => (id === "j1" ? { id: "j1", sessionKey: "s1" } : id === "j9" ? { id: "j9", sessionKey: "s9" } : REMOTE_JOBS[id] !== undefined ? { id, sessionKey: REMOTE_JOBS[id] } : null));
  on("store.handedChats", () => [{ session: "sh", station: "st2", ws: "w1", thread: 10, there: 70, at: 1000 }, { session: "s9", station: "st3", ws: "w2", thread: 9, there: 3, at: 2000 }]);
  on("store.pendingCardHeaderIfReady", () => null);
  on("store.setRead", ([, , n]) => n);
  // the readers
  on("readers.readBytes", ([op, args]) => {
    if (op === "machineSession" && args.found) {
      if (args.id !== "m1") throw thrown("HttpError", { status: 404, message: "no such session" });
      return { $bytes: Buffer.from(JSON.stringify({ session: { id: "m1", path: "/home/.claude/m1.jsonl" } })).toString("base64") };
    }
    if (op === "sessionPlace") return { $bytes: Buffer.from(JSON.stringify(w.state.place ?? { path: "/rooms/s1/a.txt", name: "a.txt", dir: false, size: 11, mtime: 5, contentType: "text/plain" })).toString("base64") };
    if (op === "fail") throw thrown("HttpError", { status: 409, message: "nope" });
    return { $bytes: Buffer.from(JSON.stringify({ op, args })).toString("base64") };
  });
  on("runtimeView.runtimeView", ([, v]) => v);
  // the clock and the wall
  on("clock.currentTimeMillisUnsafe", () => 1_000_000);
  on("ops/fibers.wall.now", () => 1_700_000_000_000);
  on("ops/version.version", () => BUILD);
  on("ops/fibers.wall.every", () => ({ $ref: "wall.every.stop" }));
  // the hub
  on("hub.config", () => ({ dataDir: DATA, profiles: [{ id: "p1", name: "P1", runtimes: ["claude", "codex"], enabled: true }, { id: "p2", name: "P2", runtimes: ["claude"], enabled: false }] }));
  on("ops/restart.pageRestart", () => ({ $ref: "restart" }));
  on("restart", (_, ww) => (ww.state.cannotRestart ? null : { $ref: "restart.go" }));
  // the agents' side
  on("agents.overview", () => ({ overview: true }));
  on("agents.place", () => ({ origin: "https://app.still.fail", workspace: "w1", station: "st1" }));
  on("accounts.profiles", () => [{ id: "p1" }]);
  on("accounts.newMachineProfile", () => "p9");
  on("accounts.newKeyedProfile", ([i]) => {
    if (!i.key) throw thrown("Refused", { status: 400, message: "a key is needed" });
    return "p10";
  });
  on("accounts.newLogin", () => ({ login: "n1" }));
  on("accounts.reviewUndecided", () => 3);
  on("accounts.putProfile", ([id]) => {
    if (id === "zz") throw thrown("Refused", { status: 404, message: "unknown profile zz" });
  });
  on("accounts.paceView", () => ({ pace: [] }));
  on("accounts.check", () => ({ ok: true }));
  on("accounts.fusionView", () => ({ f: 1 }));
  on("accounts.resetQuota", () => ({ reset: true }));
  on("accounts.askedQuota", () => ({ q: 1 }));
  on("accounts.logins.get", () => ({ job: "j" }));
  on("accounts.startLogin", () => ({ job: "started" }));
  on("accounts.logins.submitCode", ([, code]) => {
    if (code === "bad") throw thrown("Refused", { status: 404, message: "wrong code" });
    return { ok: true };
  });
  on("accounts.hasPending", ([id]) => id === "n1");
  on("accounts.logins.openPage", () => "screen-2");
  on("accounts.putAutomaticDecisions", ([i]) => {
    if (i.bad) throw thrown("Error", { message: "broken" });
  });
  on("sharing.shareProfile", ([id]) => {
    if (id === "zz") throw thrown("Error", { message: "cannot share" });
  });
  on("sharing.moveProfile", ([id]) => {
    if (id === "zz") throw thrown("Refused", { status: 400, message: "not here" });
  });
  on("sessions/archive-policy.savePolicy", ([, i]) => {
    if (i.bad) throw thrown("Error", { message: "bad policy" });
    return i.same ? null : "changed";
  });
  on("logins.logins", () => [{ id: "l1", command: "gh", url: "https://x", code: "123", screen: "s", state: "waiting" }]);
  on("logins.get", ([id]) => (id === "l1" ? { id: "l1", command: "gh", url: "https://x", callback: "c", state: "waiting" } : null));
  on("logins.cancel", ([id]) => ({ id, cancelled: true }));
  on("logins.answer", ([id]) => ({ id, url: "u", state: "ok" }));
  on("logins.callback", () => ({ status: 200, headers: {}, body: "" }));
  on("logins.openPage", ([id]) => {
    if (id !== "l1") throw thrown("Error", { message: "no page" });
    return "screen-1";
  });
  on("signIns.fill", ([, , id]) => (id === "s1" ? null : "not yours"));
  on("signIns.self", () => null);
  on("signIns.deny", () => "already done");
  on("ops/agent-env.agentEnv", ([raw]) => raw?.agentEnv ?? { B: "2", A_SECRET: "x" });
  on("ops/agent-env.parseEnvText", ([text]) => (text === "bad" ? { why: "badName", line: 1, name: "9x" } : text === "many" ? { why: "tooMany" } : { Z: "1", SECRET_KEY: "s3cr3t" }));
  on("ops/agent-env.secretValue", ([k]) => /SECRET/.test(k));
  on("ops/agent-env.maskValue", () => "••••");
  on("hub.everyChanged", () => undefined);
  on("device/tools.accessOf", ([raw]) => raw?.tools?.access ?? "off");
  on("mesh/settings.networkView", ([raw]) => ({ congestion: raw?.network?.congestion ?? "cubic" }));
  on("helper/grants.isGrant", ([g]) => ["screen", "documents", "disk"].includes(g));
  on("helper/files.askWords", ([lang]) => ({ ask: lang }));
  on("grants.request", ([g]) => {
    if (g === "documents") throw thrown("GrantRefused", { message: "station.permissions.noHelper", key: "station.permissions.noHelper" });
    if (g === "disk") return { window: "none" };
    return { window: "up", screen: true };
  });
  on("updates.get", () => ({ versions: [] }));
  on("updates/versions.channelOfId", ([id]) => (["stable", "beta"].includes(id) ? id : null));
  on("updates.update", ([id]) => {
    if (id === "nope") throw thrown("Error", { message: "no such part" });
  });
  on("cloud.memberships", () => [{ workspace: "w1", workspace_name: "W1", name: "st", home: true }, { workspace: "w2", workspace_name: "W2", name: "st", home: false }]);
  on("cli.joinWorkspace", ([, token]) => {
    if (token === "kept") throw thrown("KeptLock", { message: "the lock kept there stays" });
    if (token === "bad") throw thrown("Error", { message: "bad token" });
    return { workspace: "w3", workspace_name: "W3", name: "x" };
  });
  on("retire.retire", ([, to]) => {
    if (to === "busy") throw thrown("mesh/bus.Refused", { message: "busy" });
    if (to === "broken") throw thrown("Error", { message: "broken" });
  });
  on("retire.preview", () => ({ chats: 3 }));
  on("xshare.share", () => [{ workspace: "w2" }]);
  on("store.sessionThreads", () => [{ thread: { id: 8, createdBy: "bob@example.com" } }]);
  on("links/preview.linkPreview", ([url]) => (url.includes("none") ? null : { kind: "page", title: "T" }));
  // the drive
  on("drive.scoped", () => ({ $ref: "scopedDrive" }));
  patterns.push([/^(drive|scopedDrive)\.roots$/, () => ["/home/a"]]);
  on("drive/drive.rootsOf", () => ["/old"]);
  on("drive.checkRoot", ([p]) => {
    if (p === "/bad") throw thrown("DriveError", { message: "no such folder", code: "not_found", about: "/bad" });
    if (p === "/docs") throw thrown("DriveError", { message: "protected", code: "permission", need: { grant: "documents", top: "/Users/a/Documents", window: "up" } });
    return p;
  });
  on("drive.folders", () => ({ folders: [] }));
  patterns.push([/^(drive|scopedDrive)\.list$/, () => ({ entries: [] })]);
  patterns.push([/^(drive|scopedDrive)\.stat$/, ([, path]) => {
    if (path.includes("missing")) throw thrown("DriveError", { message: "gone", code: "not_found" });
    return { dir: !path.includes("."), size: 1 };
  }]);
  patterns.push([/^(drive|scopedDrive)\.read$/, ([, path]) => {
    if (path === "big") throw thrown("DriveError", { message: "too big to send", code: "too_large", have: 4 });
    return { type: "text/plain", total: 5, mtime: 9, bytes: { $bytes: Buffer.from("hello").toString("base64") } };
  }]);
  patterns.push([/^(drive|scopedDrive)\.(upload|mkdir|rename|remove|zip|stage)$/, (args) => ({ done: true, n: args.length })]);
  patterns.push([/^(drive|scopedDrive)\.folderToWatch$/, ([, path]) => {
    if (path === "x") throw thrown("Error", { message: "cannot watch" });
    return "/home/a";
  }]);
  on("drive/watch.changed", () => false);
  on("drive/watch.follow", () => null);
  on("transfers.now", () => 1000);
  on("drive/grants.sign", () => "signed");
  on("transfers.self", () => "st1");
  on("transfers.nameOf", () => "Other");
  on("transfers.start", ([t]) => ({ id: "t1", from: t.from }));
  on("drive/transfers.shown", ([t]) => ({ ...t, shown: true }));
  on("transfers.list", () => [{ id: "t1" }, { id: "t2" }]);
  patterns.push([/^transfers\.(cancel|retry)$/, ([, id]) => ({ id })]);
  // the screens
  on("screens.listed", () => [{ id: "sim1" }]);
  on("screens.closeScreen", ([id]) => {
    if (id === "desk") throw thrown("ScreenRefused", { message: "station.screen.noDebug", status: 405, key: "station.screen.noDebug" });
    if (id === "fail") throw thrown("Error", { message: "browser died" });
  });
  on("screens.openBrowser", ([url]) => {
    if (url.includes("fail")) throw thrown("Error", { message: "browser down" });
    return "u_0123456789ab";
  });
  on("screens.get", ([id]) => (id === "sim1" ? { debug: {} } : id === "tab1" ? { openUrl: {} } : id === "desk" ? { name: "desk" } : undefined));
  on("screens.openUrl", ([, url]) => {
    if (url === "bad") throw thrown("Error", { message: "line1\n  last line  \n" });
  });
  on("screens.endViews", () => 2);
  on("screens.debugOf", ([id]) => {
    if (id !== "sim1") throw thrown("ScreenRefused", { message: "station.screen.notFound", status: 404, key: "station.screen.notFound" });
    return { $ref: "sim" };
  });
  on("sim.logs", ([n]) => ({ lines: [], next: n }));
  on("sim.apps", () => {
    throw thrown("Error", { message: "simctl list\nfailed: no device" });
  });
  on("sim.settings", () => ({ dark: false }));
  on("sim.setSetting", ([name]) => name === "dark");
  on("screens.chromeOf", ([id]) => {
    if (id !== "sim1") throw thrown("Error", { message: "xcode\nmissing" });
    return { png: "x" };
  });
  on("sim.screenshot", () => ({ $bytes: Buffer.from("png").toString("base64") }));
  on("sim.location", ([at]) => at !== "nowhere");
  on("sim.biometrics", ([w]) => w === "match");
  on("sim.uninstall", ([a]) => a === "a");
  on("sim.push", ([a]) => a === "a");
  on("sim.recordStop", () => null);
  on("sim.install", ([p]) => (String(p).endsWith(".app") ? "a" : null));
  on("sim.relaunch", ([a]) => a === "a");
  // the connects
  on("connectKinds.get", ([kind]) => (kind === "slack" ? { $ref: "slackKind" } : undefined));
  on("slackKind.entry", ([given, had]) => (given && typeof given === "object" && !("$undef" in given) ? { ...(had ?? {}), ...given } : had));
  on("agents.heldBy", ([, , own]) => (own?.botToken === "held" ? "Other station" : null));
  on("hub.store.binding", ([id]) => (id === "slack1" ? "s1" : null));
  on("hub.accounts.modelEfforts", () => ["low", "high"]);
  on("sessions/config.runs", ([, model]) => model !== "nope");
  on("sessions/config.runtimeTitle", ([rt]) => String(rt).toUpperCase());
  on("sessions/lifecycle.bindSingle", () => "s7");
  on("slack.connects", () => [{ id: "slack1", appId: null, botToken: "xoxb-1", team: { id: "T1", name: "Team" } }, { id: "w2c", appId: "A2", botToken: "", team: null }]);
  on("slack/index.madeApps", ([raw]) => raw?.slackApps ?? []);
  on("slack/index.configTokens", ([raw]) => raw?.slackConfigTokens ?? [{ by: "ann@example.com", teamId: "T1" }]);
  on("slack/index.appIdOf", () => "A1");
  on("slack/index.slackError", ([e]) => `slack: ${e?.$error?.message}`);
  on("slack/index.withSocketMode", ([m, on]) => ({ ...m, socket: on }));
  on("slack/index.slackManifest", ([name]) => ({ display_information: { name }, oauth_config: { scopes: { bot: ["chat:write", "users:read"] } } }));
  on("slack/index.applySettings", ([m, edit]) => ({ ...m, edit }));
  on("slack/index.connectName", ([c]) => c.id);
  on("slack/index.createAppUrl", ([n]) => `https://api.slack.com/apps?new=${n}`);
  on("slack/index.ownerOfConfigToken", () => ({ id: "U1" }));
  on("slack/index.rotateConfigToken", ([, t]) => {
    if (t === "xoxe-bad") throw thrown("Error", { message: "revoked" });
    return { accessToken: "xoxe.a", refreshToken: "xoxe-r", expiresAt: 5, teamId: "T1" };
  });
  on("slack/index.settingsOf", () => ({ name: "bot" }));
  on("slack/index.shownIdentity", ([i]) => ({ shown: i.botName }));
  on("slack/index.slackAppLinks", ([app, team]) => ({ app, team }));
  on("slack/index.upsertToken", ([list, t]) => [...list, t]);
  on("slack.apps.verifyTokens", ([, b]) => (b === "bad" ? [null, ["bot token revoked"]] : [{ botName: "My Bot", teamId: "T2", team: "Team2", botImage: null }, []]));
  on("slack.apps.editManifest", () => true);
  on("slack.apps.setIcon", ([, , b]) => {
    if (b.$bytes === "") throw thrown("SlackApiError", { message: "no", code: "app_not_owned_by_manager_app" });
  });
  on("slack.apps.createApp", ([, team]) => {
    if (team === "T9") throw thrown("Error", { message: "limit" });
    return { appId: "A9", clientId: "c", clientSecret: "s" };
  });
  on("slack.apps.configured", () => true);
  on("slack.apps.exportManifest", () => ({ m: 1 }));
  on("slack.apps.exchangeInstallCode", ([, , code]) => {
    if (code === "bad") throw thrown("Error", { message: "invalid_code" });
    return ["xoxb-new", "T1"];
  });
  on("slack.chat", () => ({ $ref: "chat1" }));
  on("chat1.api", ([, params]) =>
    params.cursor
      ? { members: [{ id: "U3", profile: { email: "Zed@x.com", real_name: "Zed" }, is_restricted: true }, { id: "U4", profile: { email: "amy@x.com" }, name: "amy" }] }
      : { members: [{ id: "U1", profile: { email: "bo@x.com", real_name: "Bo", image_72: "i" } }, { id: "USLACKBOT", profile: { email: "s@x.com" } }, { id: "U2", is_bot: true, profile: { email: "b@x.com" } }, { id: "U5", profile: { email: "BO@x.com" } }], response_metadata: { next_cursor: "c2" } });
  on("feishu/web.domainOf", ([d]) => (d === "lark" ? "lark" : "feishu"));
  on("feishu/surface.verifyFeishuApp", ([, secret]) => (secret === "bad" ? [null, ["bad secret"]] : [{ botName: "FBot", botImage: null, botUserId: "ou1", teamId: "tk", team: "Tenant" }, []]));
  on("feishu.registrations.complete", ([reg]) => (reg === "r1" ? "fe1" : null));
  on("feishu.registrations.begin", ([, , name]) => {
    if (name === "fail") throw thrown("Error", { message: "down" });
    return { id: "r2", url: "https://x", expiresAt: 9 };
  });
  on("feishu.registrations.cancel", ([id]) => id === "r1");
  on("comma/index.commaLine", ([line]) => (String(line).startsWith("comma ") ? { server: "https://c.example", token: "t" } : null));
  // the vault
  const v1 = { id: "v1", ws: "w1", members: ["u1"], owner: "u1", seq: 2 };
  on("vault.lock", ([ws]) => (ws === "w1" ? { ws: "w1", devices: { $map: [["dev1", { sub: "u1" }]] } } : null));
  on("vault.boxed", () => true);
  on("vaults.memberVaults", () => [v1, { id: "v2", ws: "w1", members: ["u2"] }]);
  on("vaults.vault", ([, id]) => (id === "v1" ? v1 : null));
  on("vault/crypto.signedOk", () => true);
  on("vault/crypto.signerOf", () => ({ sub: "u1" }));
  on("vaults.vaultSnapshot", ([, id]) => (id === "v1" ? { value: v1, body: "b1" } : null));
  on("vault/crypto.vaultSupersedes", () => false);
  on("vault/crypto.vaultOk", ([, , next]) => (next.bad ? "a bad vault" : null));
  on("vaults.putVaultIf", () => true);
  on("vaults.items", () => [{ id: "i1" }]);
  on("vaults.itemSnapshot", () => null);
  on("vault/crypto.itemOk", () => null);
  on("vaults.putItemIf", () => true);
  on("vaults.boxesFor", () => [{ device: "dev1", at: 1 }, { at: 2 }]);
  on("vault/crypto.certOk", ([, c]) => (c && typeof c === "object" && c.device ? null : "not a box certificate"));
  on("cloud/lock.admit", ([, who]) => {
    if (who.endpoint !== "d1") throw thrown("Error", { message: "not admitted" });
    return { device: { id: "dev1" } };
  });
  on("vaults.boxSnapshot", () => null);
  on("vaults.putBoxIf", () => true);
  on("vault/store.isDeletedVaultWrite", () => false);
  on("secrets.pending", () => [{ id: "q1" }]);
  patterns.push([/^secrets\.(grant|deny|saved|described|removed)$/, ([, , o]) => (o.request === "no" ? "refused" : null)]);
  on("secrets.uses", () => []);
  on("secrets.plain.lasts", () => ({ lasts: 3600, at: 5 }));
  on("secrets.plain.items", () => [{ id: "pi1", owner: "ann@example.com" }]);
  on("vault/plain.shown", ([i]) => ({ id: i?.id, shown: true }));
  on("secrets.plain.setLasts", ([, , lasts]) => (typeof lasts === "number" ? null : "lasts: a number"));
  on("os.homedir", () => "/home/ann");
  on("secrets.plain.put", ([item], ww) => void (ww.state[`plain:${item.id}`] = item));
  on("secrets.plain.item", ([, id], ww) => ww.state[`plain:${id}`] ?? (id === "pi1" ? { id: "pi1", owner: "ann@example.com", version: 0, ws: "w1" } : id === "pi2" ? { id: "pi2", owner: "dee@example.com", version: 1, ws: "w2" } : null));
  on("vault/plain.plainOk", () => null);
  on("secrets.grantPlain", () => null);
  on("secrets.denyPlain", () => "not waiting");
  on("secrets.describedPlain", () => ({ id: "pi1", ws: "w1", owner: "ann@example.com" }));
  on("secrets.removedPlain", () => "not yours");
  on("secrets.savedPlain", () => ({ id: "pi3", ws: "w1", owner: "ann@example.com" }));
  on("hub.quietIn", ([ws]) => ws === "w-moving");
  on("hub.nextTs", () => "1700000000.000100");
  on("hub.compact", () => null);
  on("hub.clear", ([, readBack]) => (readBack ? "running" : null));
  on("agents/runtime.runtimeKind", ([name]) => (["claude", "codex", "dsh"].includes(name) ? name : undefined));
  on("core/model-speed.modelSpeed", ([v]) => (["standard", "fast", "ultrafast"].includes(v) ? v : null));
  on("sessions/context-cap.contextAsked", ([v]) => {
    if (v !== undefined && v !== null && typeof v !== "number" && !(typeof v === "object" && "$undef" in v)) throw thrown("Error", { message: "context must be a number" });
    return typeof v === "number" ? v : null;
  });
  on("sessions/lifecycle.newSession", () => ["s5", { id: 50 }]);
  on("sessions/lifecycle.continueMachineSession", () => ["s6", { id: 60 }]);
  on("sessions/lifecycle.openChat", () => ({ id: 51 }));
  on("sessions/lifecycle.say", () => 12);
  on("sessions/lifecycle.configure", ([, , change]) => {
    if (change.model === "bad") throw thrown("Error", { message: "no such model" });
    return undefined;
  });
  on("jobs.clearEnded", () => ["j1", "j2"]);
  on("jobs.stopFor", ([id]) => {
    if (id === "nope") throw thrown("Refused", { status: 404, message: "no job nope" });
    return { id, sessionKey: "s1" };
  });
  on("jobs/jobs.shown", ([, job]) => ({ ...job, shown: true }));
  on("sessions/relay.relayPlaces", () => [{ connect: "c1", channels: [] }]);
  on("sessions/relay.relayPeople", ([, , target]) => {
    if (target.link === "bad") throw thrown("Error", { message: "not a Slack link" });
    return [{ id: "U1", name: "Zed" }];
  });
  on("sessions/relay.relay", () => ({ relayed: true }));
  on("drive/thumbs.dir", ([d]) => `${d}/thumbs`);
  on("drive/thumbs.keep", ([files]) => files);
  on("drive/thumbs.wanted", () => true);
  on("drive/thumbs.thumbnail", () => null);
  on("drive/posters.wanted", ([n]) => /\.mp4$/.test(n));
  on("drive/posters.poster", () => null);
  on("read/sessions.mime", ([p]) => (/\.png$/.test(p) ? "image/png" : /\.txt$/.test(p) ? "text/plain" : "application/octet-stream"));
  on("read/sessions.ioMessage", ([e]) => `io: ${e.message}`);
  on("sessions/footprint.roomOfSoon", ([, ws]) => (ws === "/rooms/s2" ? "/data/rooms/s2" : null));
  on("sessions/archive.workspaceFile", ([, rel]) => (rel === "uploads/old.txt" ? { $bytes: Buffer.from("from the archive").toString("base64") } : null));
  on("sessions/image-size.shownFactsSoon", ([p]) => (/\.png$/.test(p) ? { width: 640, height: 480 } : null));
  on("read/machine.roots", () => ({ claude: "/home/.claude", codex: "/home/.codex" }));
  on("crypto.randomBytes", ([n]) => ({ $bytes: Buffer.alloc(n, 0xab).toString("base64") }));
  on("crypto.createHash", (_, w) => ({ $ref: `hash${++w.counter}` }));
  patterns.push([/^hash\d+\.update$/, (args, w) => {
    void args;
    return { $ref: "hash" + String(w.counter) };
  }]);
  patterns.push([/^hash\d+\.digest$/, () => "d".repeat(64)]);
  // marks
  on("store.homeChat", ([k]) => (k === "s1" ? { id: 7, createdBy: "ann@example.com" } : null));
  on("store.entriesBetween", ([t, n]) => (t === 7 && n === 4 ? [{ n: 4, ts: "9.1", authorKind: "agent", card: { options: [] } }] : t === 7 && n === 5 ? [{ n: 5, ts: "9.2", authorKind: "person" }] : []));
  on("rows.cardOfEntry", ([e]) => e.card);
  on("store.closeCard", ([, , , option]) => option !== "stale");
  on("parts.cardChoiceOf", ([card]) => (card?.retire ? { $ref: "retireChoice" } : undefined));
  on("retireChoice.may", ([viewer]) => (viewer.role === "owner" ? null : "only an owner chooses here"));
  // events
  on("events.open", () => ({ status: 200, headers: { "content-type": "text/event-stream" }, body: { $bytes: Buffer.from("event: hello\ndata: {}\n\n").toString("base64") } }));
  // usage and resources
  on("usage.readingAll", () => false);
  on("host.sample", () => ({ cpu: 0.5 }));
  on("resources.watch.snapshot", () => ({ at: 5, everyMs: 1000, counted: true, net: false, disk: false, total: { cpu: 1, memory: 2, netIn: 0, netOut: 0, diskRead: 0, diskWrite: 0 }, groups: [
    { key: "chat:s1", kind: "chat", session: "s1", cpu: 1, memory: 2, netIn: 0, netOut: 0, diskRead: 0, diskWrite: 0, processes: [{ pid: 3, endable: true }] },
    { key: "chat:s9", kind: "chat", session: "s9", cpu: 2, memory: 3, netIn: 1, netOut: 1, diskRead: 1, diskWrite: 1, processes: [{ pid: 4, endable: true }] },
    { key: "chat:s8", kind: "chat", session: "s8", cpu: 3, memory: 4, netIn: 1, netOut: 1, diskRead: 1, diskWrite: 1, processes: [{ pid: 5, endable: true }] },
    { key: "station", kind: "station", session: null, cpu: 1, memory: 1, netIn: 0, netOut: 0, diskRead: 0, diskWrite: 0, processes: [] },
  ], history: [] }));
  on("resources.watch.end", ([pid]) => {
    if (pid === 4) throw thrown("NotEndable", { message: "not a chat's process" });
    return { name: "node", ended: true };
  });
  on("resources.watch.follow", () => ({ $ref: "follow.stop" }));
  on("os.cpus", () => [{}, {}, {}, {}]);
  on("os.totalmem", () => 17179869184);
  // settings
  on("config.raw", (_, ww) => structuredClone(ww.state.config ?? {
    afreshAbove: 2, search: { other: 1 }, network: { mtu: 1 },
    connects: [
      { id: "slack1", kind: "slack", mode: "single-session", enabled: true, bind: { runtime: "claude", model: "opus", profile: "p1" }, slack: { botToken: "xoxb", team: { id: "T1", name: "Team" } }, createdBy: { id: "ann@example.com", name: "Ann" }, extra: "kept" },
      { id: "w2c", kind: "slack", workspace: "w2", bind: { runtime: "claude" } },
      { id: "fe1", kind: "feishu", feishu: { appId: "cli_1", registration: "r1" }, bind: { runtime: "claude" } },
    ],
    slackApps: [{ appId: "A5", by: "ann@example.com", oauth: { state: "st5", clientId: "c", clientSecret: "s", redirectUri: "https://r", botToken: "xoxb-5" } }, { appId: "A6", by: "bob@example.com", oauth: { state: "st6", clientId: "c", clientSecret: "s", redirectUri: "https://r" } }],
  }));
  on("config.updateSoon", ([raw], ww) => void (ww.state.config = raw));
  on("core/cache-policy.afreshThreshold", ([v]) => (typeof v === "number" && v >= 0 ? v : 1));
  on("search.query", ([q]) => {
    if (q === "boom") throw thrown("Error", { message: "index not built" });
    return { groups: [{ kind: "chat", hits: [], more: false }], building: false };
  });
  // presets and stars
  on("hub.presets.listed", () => [{ id: "p1" }]);
  on("hub.presets.list", () => [{ id: "p1" }, { id: "p2" }]);
  on("hub.reposDir", () => "/repos");
  on("hub.repoIndex.repos", () => ["/repos/a"]);
  on("sessions/presets.candidates", () => [{ dir: "/repos/a" }]);
  on("hub.clones.list", () => []);
  on("hub.clones.start", ([, url]) => {
    if (typeof url !== "string") throw thrown("NoCloneUrl", { message: "no url" });
    return { id: "c1", url };
  });
  on("hub.clones.drop", ([, id]) => id === "c1");
  on("hub.presets.kept", () => [{ id: "p1", rev: 2 }]);
  on("hub.presets.others", () => []);
  on("hub.presets.carry", ([, , given]) => ({ changed: given.length > 0, records: given, refused: [] }));
  on("hub.presets.add", ([, body]) => {
    if (!body.name) throw thrown("Error", { message: "a preset needs a name" });
    return { id: "p3", dirs: ["/a"], name: body.name };
  });
  on("hub.presets.put", ([, id]) => {
    if (id === "zz") throw thrown("NoPreset", { message: "no preset kept zz" });
    return { id, dirs: [] };
  });
  on("hub.presets.delete", ([, id]) => {
    if (id === "zz") throw thrown("NoPreset", { message: "no preset kept zz" });
  });
  on("hub.store.modelStars", ([, sub]) => (sub === "u1" ? JSON.stringify({ "m/a": { on: true, at: 1 } }) : null));
  on("core/preset-records.starsOf", ([v]) => {
    if (v !== undefined && v !== null && (typeof v !== "object" || Array.isArray(v)) && !("$undef" in (v as any))) throw thrown("RecordRefusal", { message: "stars: an object of models" });
    return v && !("$undef" in v) ? v : {};
  });
  on("core/preset-records.mergeStars", ([a, b]) => ({ ...a, ...b }));
  on("core/preset-records.canonical", ([v]) => JSON.stringify(Object.keys(v).sort().map((k) => [k, v[k]])));
  // the machine's files
  w.files.set("/rooms/s1/uploads/a.png", { bytes: Buffer.from("png!"), mtimeMs: 10 });
  w.files.set("/rooms/s1/a.txt", { bytes: Buffer.from("line 1\nline 2\nline 3\n"), mtimeMs: 5 });
  w.files.set("/data/rooms/s2/workspace.tar.zst", { bytes: Buffer.from("tar"), mtimeMs: 1 });
  w.files.set("/data/uploads", "dir");
  w.files.set("/data/uploads/staged.txt", { bytes: Buffer.from("staged"), mtimeMs: 1_700_000_000_000 });
  w.files.set("/data/uploads/stale.txt", { bytes: Buffer.from("stale"), mtimeMs: 1 });
  const enoent = (p: string) => thrown("Error", { message: `ENOENT: no such file or directory, stat '${p}'`, code: "ENOENT" });
  const stat = (p: string) => {
    const f = w.files.get(p);
    if (f === undefined) {
      if ([...w.files.keys()].some((k) => k.startsWith(`${p}/`))) return { size: 0, mtimeMs: 0, file: false, dir: true };
      throw enoent(p);
    }
    return f === "dir" ? { size: 0, mtimeMs: 0, file: false, dir: true } : { size: f.bytes.length, mtimeMs: f.mtimeMs, file: true, dir: false };
  };
  on("fs.stat", ([p]) => stat(p));
  on("fs.access", ([p]) => void stat(p));
  on("fs.readFile", ([p]) => {
    const f = w.files.get(p);
    if (f === undefined || f === "dir") throw enoent(p);
    return { $bytes: f.bytes.toString("base64") };
  });
  on("fs.writeFile", ([p, b, opts]) => {
    if (opts?.flag === "wx" && w.files.has(p)) throw thrown("Error", { message: `EEXIST: file already exists, open '${p}'`, code: "EEXIST" });
    w.files.set(p, { bytes: Buffer.from(b.$bytes, "base64"), mtimeMs: 1_700_000_000_000 });
  });
  on("fs.appendFile", ([p, b]) => {
    const f = w.files.get(p);
    const had = f !== undefined && f !== "dir" ? f.bytes : Buffer.alloc(0);
    w.files.set(p, { bytes: Buffer.concat([had, Buffer.from(b.$bytes, "base64")]), mtimeMs: 1_700_000_000_000 });
  });
  on("fs.mkdir", ([p]) => void w.files.set(p, w.files.get(p) ?? "dir"));
  on("fs.rename", ([a, b]) => {
    const f = w.files.get(a);
    if (f === undefined) throw enoent(a);
    w.files.delete(a);
    w.files.set(b, f);
  });
  on("fs.copyFile", ([a, b]) => {
    const f = w.files.get(a);
    if (f === undefined) throw enoent(a);
    w.files.set(b, f);
  });
  on("fs.rm", ([p]) => void w.files.delete(p));
  on("fs.statfs", () => ({ bavail: 1e9, bsize: 4096 }));
  on("fs.readdir", ([p, opts]) => {
    const names = [...new Set([...w.files.keys()].filter((k) => k.startsWith(`${p}/`)).map((k) => k.slice(p.length + 1).split("/")[0]!))];
    if (names.length === 0 && !w.files.has(p)) throw enoent(p);
    return opts?.withFileTypes ? names.map((n) => ({ name: n, dir: w.files.get(`${p}/${n}`) === "dir" || [...w.files.keys()].some((k) => k.startsWith(`${p}/${n}/`)) })) : names;
  });
  on("fs.open", ([p], ww) => {
    stat(p);
    const ref = `fh${++ww.counter}`;
    ww.state[ref] = p;
    return { $ref: ref };
  });
  patterns.push([/^fh\d+\.stat$/, () => ({ size: 21, mtimeMs: 5, file: true, dir: false })]);
  patterns.push([/^fh\d+\.read$/, ([buf, , len]) => {
    void buf;
    const bytes = Buffer.from("line 1\nline 2\nline 3\n").subarray(0, len);
    return { bytesRead: bytes.length, buffer: { $bytes: bytes.toString("base64") } };
  }]);
  on("drive/fs.readAt", ([, offset, len]) => ({ $bytes: Buffer.from("line 1\nline 2\nline 3\n").subarray(offset, offset + len).toString("base64") }));
  return w;
}

// ---------------------------------------------------------------------------------------------------------------

function defineCases() {
  const json = (o: unknown) => JSON.stringify(o);
  // chats.ts
  add("chats", { method: "GET", path: "/chats" });
  add("chats archived page", { method: "GET", path: "/chats", query: [["archived", "1"], ["page", "x"]] });
  add("chats scoped", { method: "GET", path: "/chats", query: [["session", "s1"], ["thread", "7"], ["thread", "x"]] });
  add("chats marks", { method: "GET", path: "/chats", query: [["marks", "1"], ["thread", "7"]] });
  add("chats marks whole", { method: "GET", path: "/chats", query: [["marks", "1"]] });
  add("chats shared", { method: "GET", path: "/chats", query: [["shared", "1"]] });
  add("changed chats", { method: "POST", path: "/changed/chats", body: { held: { "7": "abc" } } });
  add("changed chats no held", { method: "POST", path: "/changed/chats", body: { held: [] } });
  add("changed chats bad json", { method: "POST", path: "/changed/chats", body: "{" });
  add("entries", { method: "GET", path: "/threads/7/entries", query: [["before", "3"]] });
  add("entries not a number", { method: "GET", path: "/threads/x/entries" });
  add("letters", { method: "GET", path: "/threads/7/letters" });
  add("a read refused", { method: "GET", path: "/threads/7/entries" }, { world: (w) => w.handlers.set("readers.readBytes", () => { throw thrown("HttpError", { status: 409, message: "nope" }); }) });
  add("a read failing", { method: "GET", path: "/threads/7/entries" }, { world: (w) => w.handlers.set("readers.readBytes", () => { throw thrown("Error", { message: "broken" }); }) });
  // sessions.ts
  add("sessions", { method: "GET", path: "/sessions", query: [["connect", "slack"]] });
  add("session", { method: "GET", path: "/sessions/s1", query: [["turns", "3"]] });
  add("session another workspace's", { method: "GET", path: "/sessions/s9" });
  add("session timeline", { method: "GET", path: "/sessions/s1/timeline", query: [["limit", "5"], ["brief", "1"]] });
  add("session file", { method: "GET", path: "/sessions/s1/files", query: [["name", "a.png"]] });
  add("session file missing", { method: "GET", path: "/sessions/s1/files", query: [["name", "nope.png"]] });
  add("session file archived", { method: "GET", path: "/sessions/s2/files", query: [["name", "old.txt"]] });
  add("session file traversal", { method: "GET", path: "/sessions/s1/files", query: [["name", "../x"]] });
  add("session file unknown session", { method: "GET", path: "/sessions/zz/files", query: [["name", "a.png"]] });
  add("session part", { method: "GET", path: "/sessions/s1/parts", query: [["name", "a.png"], ["offset", "1"], ["length", "2"]] });
  add("session part bad range", { method: "GET", path: "/sessions/s1/parts", query: [["name", "a.png"], ["offset", "-1"]] });
  add("session part archived", { method: "GET", path: "/sessions/s2/parts", query: [["name", "old.txt"]] });
  add("session poster none", { method: "GET", path: "/sessions/s1/poster", query: [["name", "a.mp4"]] });
  add("session poster not a film", { method: "GET", path: "/sessions/s1/poster", query: [["name", "a.png"]] });
  add("session transcript", { method: "GET", path: "/sessions/s1/transcript" });
  add("session widget state", { method: "GET", path: "/sessions/s1/widget-state", query: [["path", "w.mbui"]] });
  add("session peek text", { method: "GET", path: "/sessions/s1/peek", query: [["path", "a.txt"], ["line", "2"]] });
  add("session peek dir", { method: "GET", path: "/sessions/s1/peek", query: [["path", "uploads"]] }, { world: (w) => (w.state.place = { path: "/rooms/s1", name: "s1", dir: true, size: 0, mtime: 5, contentType: "inode/directory" }) });
  add("session peek image", { method: "GET", path: "/sessions/s1/peek" }, { world: (w) => (w.state.place = { path: "/rooms/s1/uploads/a.png", name: "a.png", dir: false, size: 4, mtime: 5, contentType: "image/png" }) });
  add("session open", { method: "GET", path: "/sessions/s1/open", query: [["path", "a.txt"]] });
  add("session open raw", { method: "GET", path: "/sessions/s1/open", query: [["path", "a.txt"], ["raw", "1"]] });
  add("session open raw part", { method: "GET", path: "/sessions/s1/open", query: [["path", "a.txt"], ["raw", "1"], ["offset", "2"], ["length", "4"]] });
  // (a version the device keeps: 304, no bytes, whole or a part; one it changed since read as before)
  add("session open raw kept", { method: "GET", path: "/sessions/s1/open", query: [["path", "a.txt"], ["raw", "1"], ["have", "5:11"]] });
  add("session open raw part kept", { method: "GET", path: "/sessions/s1/open", query: [["path", "a.txt"], ["raw", "1"], ["offset", "2"], ["length", "4"], ["have", "5:11"]] });
  add("session open raw changed", { method: "GET", path: "/sessions/s1/open", query: [["path", "a.txt"], ["raw", "1"], ["have", "4:11"]] });
  add("session open dir", { method: "GET", path: "/sessions/s1/open" }, { world: (w) => (w.state.place = { path: "/rooms/s1", name: "s1", dir: true, size: 0, mtime: 5, contentType: "x" }) });
  add("session unknown action", { method: "GET", path: "/sessions/s1/what" });
  add("changed sessions", { method: "POST", path: "/changed/sessions", body: { held: {} } });
  add("changed threads", { method: "POST", path: "/changed/threads", query: [["session", "s1"]], body: { held: {} } });
  add("threads", { method: "GET", path: "/threads", query: [["session", "s1"]] });
  add("thread", { method: "GET", path: "/threads/7" });
  add("thread action", { method: "GET", path: "/threads/7/what" });
  add("thread another workspace's", { method: "GET", path: "/threads/9" });
  add("jobs", { method: "GET", path: "/jobs", query: [["chats", "0"]] });
  add("job", { method: "GET", path: "/jobs/j1" });
  add("job log", { method: "GET", path: "/jobs/j1/log", query: [["lines", "40"]] });
  add("job another workspace's", { method: "GET", path: "/jobs/j9" });
  add("job unknown action", { method: "GET", path: "/jobs/j1/what" });
  for (const id of Object.keys(REMOTE_JOBS)) for (const viewer of [OWNER, OTHER_WS]) add(`another station's task ${id}, of ${viewer.workspace}`, { method: "GET", path: `/jobs/${id}`, viewer });
  // hub.ts
  add("new session", { method: "POST", path: "/sessions", body: { runtime: "claude", model: "opus", title: "hi", fast: true, speed: "fast", context: 100000 } });
  add("new session bad runtime", { method: "POST", path: "/sessions", body: { runtime: "nope" } });
  add("new session bad profiles", { method: "POST", path: "/sessions", body: { runtime: "claude", profiles: [1] } });
  add("new session bad speed", { method: "POST", path: "/sessions", body: { runtime: "claude", speed: "warp" } });
  add("new session bad context", { method: "POST", path: "/sessions", body: { runtime: "claude", context: "x" } });
  add("new session moving", { method: "POST", path: "/sessions", body: { runtime: "claude" }, viewer: { ...OWNER, workspace: "w-moving" } });
  add("new session too large", { method: "POST", path: "/sessions", body: Buffer.alloc(1_000_001, 32) });
  add("new session invalid json", { method: "POST", path: "/sessions", body: "{x" });
  add("machine session", { method: "POST", path: "/machine-sessions", body: { runtime: "claude", id: "m1" } });
  add("machine session missing", { method: "POST", path: "/machine-sessions", body: { runtime: "claude", id: "m2" } });
  add("machine session dsh", { method: "POST", path: "/machine-sessions", body: { runtime: "dsh", id: "m1" } });
  add("moved", { method: "GET", path: "/moved", query: [["limit", "0"]] });
  add("moved other workspace", { method: "GET", path: "/moved", viewer: OTHER_WS });
  add("open chat", { method: "POST", path: "/threads", body: { session: "s1", title: "  a new chat  " } });
  add("open chat handed", { method: "POST", path: "/threads", body: { session: "sh" } });
  add("open chat unknown", { method: "POST", path: "/threads", body: { session: "zz" } });
  add("upload", { method: "POST", path: "/uploads", query: [["name", "../../.hidden\u0001.txt"]], body: "hello" });
  add("upload parts first", { method: "POST", path: "/uploads/parts", query: [["id", "abcdefgh"], ["name", "big.bin"], ["size", "10"], ["offset", "0"]], body: "01234" });
  add("upload parts the rest", { method: "POST", path: "/uploads/parts", query: [["id", "abcdefgh"], ["name", "big.bin"], ["size", "10"], ["offset", "3"]], body: "3456789" }, { world: (w) => w.files.set("/data/uploads/.part-abcdefgh", { bytes: Buffer.from("01234"), mtimeMs: 1_700_000_000_000 }) });
  add("upload parts asked again", { method: "POST", path: "/uploads/parts", query: [["id", "abcdefgh"], ["name", "big.bin"], ["size", "10"], ["offset", "5"]], body: "56789" });
  add("upload parts known by its hash", { method: "POST", path: "/uploads/parts", query: [["id", "zyxwvuts"], ["name", "again.bin"], ["size", "10"], ["offset", "0"], ["sha256", "d".repeat(64)]] }, { world: (w) => w.files.set("/data/uploads/2023-11-14T22-13-20-ababab-big.bin", { bytes: Buffer.from("0123456789"), mtimeMs: 1_700_000_000_000 }) });
  add("upload parts not known by its hash", { method: "POST", path: "/uploads/parts", query: [["id", "zyxwvut2"], ["name", "other.bin"], ["size", "11"], ["offset", "0"], ["sha256", "e".repeat(64)]] });
  add("upload parts bad id", { method: "POST", path: "/uploads/parts", query: [["id", "ab"], ["size", "10"], ["offset", "0"]], body: "01234" });
  add("upload parts bad offset", { method: "POST", path: "/uploads/parts", query: [["id", "abcdefgh2"], ["size", "10"], ["offset", "11"]] });
  add("upload parts too big", { method: "POST", path: "/uploads/parts", query: [["id", "abcdefgh3"], ["size", "2000000000"], ["offset", "0"]] });
  add("upload parts bad sha", { method: "POST", path: "/uploads/parts", query: [["id", "abcdefgh4"], ["size", "3"], ["offset", "0"], ["sha256", "zz"]] });
  add("delete session", { method: "DELETE", path: "/sessions/s1" });
  add("delete session handed", { method: "DELETE", path: "/sessions/sh" });
  add("clear ended jobs", { method: "DELETE", path: "/sessions/s1/jobs" });
  add("archive session", { method: "POST", path: "/sessions/s1/archive" });
  add("unarchive session", { method: "DELETE", path: "/sessions/s1/archive" });
  add("stop", { method: "POST", path: "/sessions/zz/stop" });
  add("cancel retry", { method: "POST", path: "/sessions/s1/cancel-retry", body: { thread: 7, seq: 3 } });
  add("cancel retry bad", { method: "POST", path: "/sessions/s1/cancel-retry", body: { thread: 7 } });
  add("retry", { method: "POST", path: "/sessions/s1/retry", body: { thread: 7, seq: 3 } });
  add("reassign bad", { method: "POST", path: "/sessions/s1/reassign", body: { thread: 0, seq: 3 } });
  add("evict", { method: "POST", path: "/sessions/s1/evict" });
  add("compact", { method: "POST", path: "/sessions/s1/compact" });
  add("clear refused", { method: "POST", path: "/sessions/s1/clear", body: { readBack: true } });
  add("warm", { method: "POST", path: "/sessions/s1/warm" });
  add("settings", { method: "POST", path: "/sessions/s1/settings", body: { runtime: "codex", model: "gpt", effort: null, profile: null, profiles: ["p1"], repick: true, afresh: false, speed: null, fast: true, context: 2000 } });
  add("settings bad runtime", { method: "POST", path: "/sessions/s1/settings", body: { runtime: "" } });
  add("settings bad afresh", { method: "POST", path: "/sessions/s1/settings", body: { afresh: 1 } });
  add("settings bad fast", { method: "POST", path: "/sessions/s1/settings", body: { fast: "yes" }, lang: "en" });
  add("settings refused", { method: "POST", path: "/sessions/s1/settings", body: { model: "bad" } });
  add("stop job", { method: "POST", path: "/jobs/j1/stop" });
  add("stop job unknown", { method: "POST", path: "/jobs/nope/stop" });
  add("message", { method: "POST", path: "/threads/7/messages", body: { text: " hi ", quotes: [{ author: "A", text: "q", ts: "1.2", role: "agent" }, { text: " " }], client: "android\u0007 0.1.2", cc: [8, "x"] } });
  add("message with a staged file", { method: "POST", path: "/threads/7/messages", body: { text: "see", attachments: [{ path: "/data/uploads/staged.txt", name: "s.txt", size: 6 }, { path: "/rooms/s1/uploads/a.png" }] } });
  add("message with a part file", { method: "POST", path: "/threads/7/messages", body: { attachments: [{ path: "/data/uploads/.part-abc" }] } });
  add("message empty", { method: "POST", path: "/threads/7/messages", body: { text: "  " } });
  add("message slack thread", { method: "POST", path: "/threads/8/messages", body: { text: "hi" } });
  add("message handed", { method: "POST", path: "/threads/10/messages", body: { text: "hi" } });
  add("message unknown thread", { method: "POST", path: "/threads/99/messages", body: { text: "hi" } });
  add("message answering a card", { method: "POST", path: "/threads/7/messages", body: { text: "Yes", quotes: [{ text: "q?", ts: "9.1" }] } }, { world: (w) => w.handlers.set("store.pendingCardHeaderIfReady", () => [{ ts: "9.1", n: 4 }, { options: [{ label: "Yes", action: "reply" }] }]) });
  add("message choosing a close option", { method: "POST", path: "/threads/7/messages", body: { text: "Yes", quotes: [{ text: "q?", ts: "9.1" }] } }, { world: (w) => w.handlers.set("store.pendingCardHeaderIfReady", () => [{ ts: "9.1", n: 4 }, { options: [{ label: "Yes", action: "close" }] }]) });
  add("add a session to a chat", { method: "POST", path: "/threads/7/sessions", body: { session: "s2" } });
  add("relay people", { method: "GET", path: "/threads/7/relay/people", query: [["connect", "c1"], ["channel", "C1"]] });
  add("relay people bad link", { method: "GET", path: "/threads/7/relay/people", query: [["link", "bad"]] });
  add("relay people none", { method: "GET", path: "/threads/7/relay/people" });
  add("relay places", { method: "GET", path: "/threads/7/relay" });
  add("relay", { method: "POST", path: "/threads/7/relay", body: { connect: "c1", channel: "C1", join: true, note: "see" } });
  add("relay link", { method: "POST", path: "/threads/7/relay", body: { link: "https://x.slack.com/archives/C1/p1", connect: "c1" } });
  add("archive chat", { method: "POST", path: "/threads/7/archive" });
  add("unarchive chat", { method: "DELETE", path: "/threads/7/archive" });
  add("regenerate title", { method: "POST", path: "/threads/7/regenerate-title" });
  add("regenerate title refused", { method: "POST", path: "/threads/7/regenerate-title" }, { world: (w) => w.handlers.set("sessions/regenerate-title.regenerateTitle", () => { throw thrown("TitleError", { message: "changed", problem: "changed" }); }) });
  add("regenerate title slack", { method: "POST", path: "/threads/8/regenerate-title" });
  add("dev inject", { method: "POST", path: "/dev/inject", body: { connect: "c1", channel: "C1", ts: "1.2", text: "hi" } });
  add("dev inject member", { method: "POST", path: "/dev/inject", body: {}, viewer: MEMBER });
  // marks.ts
  add("title", { method: "POST", path: "/sessions/s1/title", body: { title: "  Named  " } });
  add("title unknown", { method: "POST", path: "/sessions/zz/title", body: { title: "x" } });
  add("widget state", { method: "PUT", path: "/sessions/s1/widget-state", body: { path: "w.mbui", state: { modelContent: { a: 1 }, b: 2 } } });
  add("widget state no path", { method: "PUT", path: "/sessions/s1/widget-state", body: { state: 1 } });
  add("widget state too big", { method: "PUT", path: "/sessions/s1/widget-state", body: { path: "w", state: "x".repeat(17000) } });
  add("pin", { method: "PUT", path: "/sessions/s1/pin" });
  add("unpin", { method: "DELETE", path: "/sessions/s1/pin" });
  add("unkeep", { method: "DELETE", path: "/threads/7/keep" });
  add("hidden", { method: "PUT", path: "/threads/7/hidden", body: { hidden: true } });
  add("hidden bad", { method: "PUT", path: "/threads/7/hidden", body: { hidden: 1 } });
  add("muted", { method: "PUT", path: "/threads/7/muted", body: { muted: false } });
  add("read", { method: "PUT", path: "/threads/7/read", body: { n: 3 } });
  add("read bad", { method: "PUT", path: "/threads/7/read", body: { n: 1.5 }, lang: "en" });
  add("rename chat", { method: "PUT", path: "/threads/7/title", body: { title: "x" } });
  add("rename slack chat", { method: "PUT", path: "/threads/8/title", body: { title: "x" } });
  add("keep", { method: "PUT", path: "/threads/7/keep" });
  add("dismissed", { method: "PUT", path: "/threads/7/dismissed", body: { n: 4 } });
  add("dismissed nothing", { method: "PUT", path: "/threads/7/dismissed", body: { n: 5 } });
  add("closed card", { method: "PUT", path: "/threads/7/closed-card", body: { n: 4, option: " Done " } });
  add("closed card stale", { method: "PUT", path: "/threads/7/closed-card", body: { n: 4, option: "stale" } });
  add("closed card no option", { method: "PUT", path: "/threads/7/closed-card", body: { n: 4 } });
  add("closed card a part's", { method: "PUT", path: "/threads/7/closed-card", body: { n: 4, option: "go" }, viewer: MEMBER }, { world: (w) => w.handlers.set("store.entriesBetween", () => [{ n: 4, ts: "9.1", card: { retire: { at: 1 } } }]) });
  add("mark unknown thread", { method: "PUT", path: "/threads/99/read", body: { n: 1 } });
  // events.ts
  add("events", { method: "GET", path: "/events", query: [["live", "s1"], ["from", " 3.7 "], ["last", "5"], ["live", "s9"], ["live", "zz"], ["job", "j1"], ["lines", "5000"], ["job", "j9"], ["login", "abc"], ["login", "BAD"], ["host", "1"], ["since", "e9"], ["running", "1"], ["shared", "1"]] });
  add("events for a client from before", { method: "GET", path: "/events", headers: { "stillfail-runtimes": "claude, codex,BAD" } }, {
    world: (w) => {
      const frames = [
        'event: session\ndata: {"key":"s1","runtime":"hermes"}\n\nevent: thread\nid: 4\ndata: {"entries":[{"authorRuntime":"hermes","n":1},{"authorRuntime":"claude"},5]}\n\n',
        "event: overview\ndata: {\"a\":1}\n\nevent: hello\ndata: {}\n\n: ping",
      ];
      w.handlers.set("events.open", () => ({ status: 200, headers: { "content-type": "text/event-stream" }, body: { $stream: "ev1" } }));
      w.handlers.set("$stream.next", () => {
        const f = frames.shift();
        return f === undefined ? null : { $bytes: Buffer.from(f).toString("base64") };
      });
      w.handlers.set("runtimeView.runtimeView", ([ty, v]) => (ty === "Session" && v.runtime === "hermes" ? { $omit: 1 } : { ...v, projected: true }));
    },
  });
  add("events read-only", { method: "GET", path: "/events", query: [["login", "abc"], ["live", "s1"], ["from", "x"], ["last", "+0"]], viewer: VIEWER });
  // usage.ts
  add("machine sessions", { method: "GET", path: "/machine-sessions" });
  add("machine session", { method: "GET", path: "/machine-sessions/claude/m1", query: [["limit", "4"]] });
  add("memory", { method: "GET", path: "/memory" });
  add("memory joined", { method: "GET", path: "/memory", viewer: OTHER_WS });
  add("host", { method: "GET", path: "/host" });
  add("usage", { method: "GET", path: "/usage", query: [["from", "1e3"], ["to", "inf"], ["tz", "-5000"], ["remoteFrom", "+12"], ["historyFrom", "0"], ["historyTo", "86400000"], ["history", "1"]] });
  add("usage nan", { method: "GET", path: "/usage", query: [["from", "NaN"], ["to", "-infinity"], ["tz", "60.9"]] });
  add("usage one bound", { method: "GET", path: "/usage", query: [["historyFrom", "0"]] });
  add("usage bad range", { method: "GET", path: "/usage", query: [["historyFrom", "60000"], ["historyTo", "0"]] });
  add("usage bad cursor", { method: "GET", path: "/usage", query: [["remoteFrom", "1.5"]] });
  add("usage cursor out of range", { method: "GET", path: "/usage", query: [["remoteFrom", "9223372036854775808"]] });
  add("usage as a stream", { method: "GET", path: "/usage", headers: { accept: "text/event-stream" } });
  add("usage as a stream failing", { method: "GET", path: "/usage", headers: { accept: "text/event-stream" } }, { world: (w) => w.handlers.set("readers.readBytes", () => { throw thrown("HttpError", { status: 400, message: "bad" }); }) });
  add("usage calls", { method: "GET", path: "/usage/calls/s1", query: [["from", "-9223372036854775808"], ["beforeSeq", "007"], ["limit", "2.9"]] });
  add("resources", { method: "GET", path: "/resources" });
  add("resources end", { method: "POST", path: "/resources/processes/3/end", body: { session: "s1" } });
  add("resources end not endable", { method: "POST", path: "/resources/processes/4/end", body: { session: "s1" } });
  add("resources end not seen", { method: "POST", path: "/resources/processes/4/end", body: { session: "s9" } }, { world: (w) => w.handlers.set("readers.readBytes", () => ({ $bytes: Buffer.from(JSON.stringify({ s9: null })).toString("base64") })) });
  add("resources end no session", { method: "POST", path: "/resources/processes/4/end", body: "{}" });
  add("resources end bad json", { method: "POST", path: "/resources/processes/4/end", body: "{" });
  // context.ts, search.ts
  add("context settings", { method: "PUT", path: "/context/settings", body: { afreshWhenCold: true, afreshAbove: 1 } });
  add("context settings off", { method: "PUT", path: "/context/settings", body: { afreshWhenCold: false, afreshAbove: 3.5 } });
  add("context settings none", { method: "PUT", path: "/context/settings", body: {} });
  add("context settings bad", { method: "PUT", path: "/context/settings", body: { afreshAbove: -1 } });
  add("context settings not an object", { method: "PUT", path: "/context/settings", body: "[1]" });
  add("context settings member", { method: "PUT", path: "/context/settings", body: {}, viewer: MEMBER, lang: "en" });
  add("search settings", { method: "PUT", path: "/search/settings", body: { personal: true } });
  add("search settings bad", { method: "PUT", path: "/search/settings", body: { personal: "y" } });
  add("search settings member", { method: "PUT", path: "/search/settings", body: { personal: true }, viewer: MEMBER });
  add("search", { method: "GET", path: "/search", query: [["q", "hello"], ["kinds", "chat,nope,file"], ["limit", "20"], ["offset", "x"], ["archived", "1"], ["again", "1"]] });
  add("search no kinds", { method: "GET", path: "/search", query: [["kinds", "nope"]] });
  add("search failing", { method: "GET", path: "/search", query: [["q", "boom"]], viewer: VIEWER });
  add("search too long", { method: "GET", path: "/search", query: [["q", "x".repeat(201)]] });
  // presets.ts, stars.ts
  add("presets", { method: "GET", path: "/presets" });
  add("presets kept", { method: "GET", path: "/presets/kept" });
  add("presets others", { method: "GET", path: "/presets/others" });
  add("presets carried", { method: "PUT", path: "/presets/kept", body: { records: [{ id: "p1", rev: 3 }] } });
  add("presets carried none", { method: "PUT", path: "/presets/kept", body: { records: [] } });
  add("presets carried bad", { method: "PUT", path: "/presets/kept", body: { records: 1 } });
  add("presets carried bad json", { method: "PUT", path: "/presets/kept", body: "{" });
  add("presets carried too many", { method: "PUT", path: "/presets/kept", body: { records: Array.from({ length: 101 }, () => ({})) } });
  add("presets carried no person", { method: "PUT", path: "/presets/kept", body: { records: [] }, viewer: { ...OWNER, sub: "" } });
  add("preset clone", { method: "POST", path: "/presets/clone", body: { url: "https://github.com/a/b" } });
  add("preset clone no url", { method: "POST", path: "/presets/clone", body: {} });
  add("preset clone read-only", { method: "POST", path: "/presets/clone", body: {}, viewer: VIEWER });
  add("preset clone dropped", { method: "DELETE", path: "/presets/clones/c1" });
  add("preset clone not there", { method: "DELETE", path: "/presets/clones/c2" });
  add("preset made", { method: "POST", path: "/presets", body: { name: "web" } });
  add("preset made bad", { method: "POST", path: "/presets", body: {} });
  add("preset made bad json", { method: "POST", path: "/presets", body: "{" });
  add("preset changed", { method: "PUT", path: "/presets/p1", body: { name: "x" } });
  add("preset changed missing", { method: "PUT", path: "/presets/zz", body: {} });
  add("preset removed", { method: "DELETE", path: "/presets/p1" });
  add("preset removed missing", { method: "DELETE", path: "/presets/zz" });
  add("stars", { method: "GET", path: "/stars" });
  add("stars none", { method: "GET", path: "/stars", viewer: MEMBER });
  add("stars no person", { method: "GET", path: "/stars", viewer: { ...OWNER, sub: "" } });
  add("stars put", { method: "PUT", path: "/stars", body: { stars: { "m/b": { on: true, at: 2 } } } });
  add("stars put same", { method: "PUT", path: "/stars", body: { stars: {} } });
  add("stars put bad", { method: "PUT", path: "/stars", body: { stars: [1] } });
  add("stars put bad json", { method: "PUT", path: "/stars", body: "{" });
  // accounts.ts
  add("machine profile", { method: "POST", path: "/profiles/machine", body: { runtime: "claude" } });
  add("keyed profile", { method: "POST", path: "/profiles", body: { key: "k" } });
  add("keyed profile refused", { method: "POST", path: "/profiles", body: {} });
  add("keyed profile bad json", { method: "POST", path: "/profiles", body: "{" });
  add("new login", { method: "POST", path: "/logins", body: { runtime: "codex" } });
  add("automatic decisions", { method: "PUT", path: "/automatic-decisions", body: { on: true } });
  add("automatic decisions failing", { method: "PUT", path: "/automatic-decisions", body: { bad: true } });
  add("archiving", { method: "PUT", path: "/archiving", body: { days: 3 } });
  add("archive policy", { method: "PUT", path: "/automatic-decisions/policy", body: { days: 1 } });
  add("archive policy joined", { method: "PUT", path: "/automatic-decisions/policy", body: { days: 1 }, viewer: { ...OTHER_WS, role: "admin" } });
  add("archive policy joined same", { method: "PUT", path: "/automatic-decisions/policy", body: { same: true }, viewer: { ...OTHER_WS, role: "owner", name: "" } });
  add("archive policy joined bad", { method: "PUT", path: "/automatic-decisions/policy", body: { bad: true }, viewer: { ...OTHER_WS, role: "owner" } });
  add("archive policy joined member", { method: "PUT", path: "/automatic-decisions/policy", body: {}, viewer: OTHER_WS });
  add("review undecided", { method: "POST", path: "/automatic-decisions/review" });
  add("refresh decision models", { method: "POST", path: "/automatic-decisions/refresh" });
  add("put profile", { method: "PUT", path: "/profiles/p1", body: { name: "x" } });
  add("put profile unknown", { method: "PUT", path: "/profiles/zz", body: {} });
  add("delete profile", { method: "DELETE", path: "/profiles/p1" });
  add("pace", { method: "GET", path: "/profiles/pace" });
  add("check profile", { method: "POST", path: "/profiles/p1/check" });
  add("fusion", { method: "GET", path: "/profiles/p1/fusion" });
  add("reset quota", { method: "POST", path: "/profiles/p1/reset-quota", headers: { "Idempotency-Key": "q1" }, body: { reset: "weekly" } });
  add("reset quota no key", { method: "POST", path: "/profiles/p1/reset-quota" });
  add("reset quota bad body", { method: "POST", path: "/profiles/p1/reset-quota", headers: { "idempotency-key": "q2" }, body: "{" });
  add("asked quota", { method: "POST", path: "/profiles/p1/quota" });
  add("profile login", { method: "GET", path: "/profiles/p1/login" });
  add("profile login unknown", { method: "GET", path: "/profiles/p8/login" });
  add("profile login cancelled", { method: "DELETE", path: "/profiles/p1/login" });
  add("profile login started", { method: "POST", path: "/profiles/p1/login" });
  add("profile login code", { method: "POST", path: "/profiles/p1/login-code", body: { code: 1234 } });
  add("profile login code wrong", { method: "POST", path: "/profiles/p1/login-code", body: { code: "bad" } });
  add("share profile", { method: "POST", path: "/profiles/p1/share", body: { on: true, allow: ["a".repeat(64)], among: "all" } });
  add("share profile bad allow", { method: "POST", path: "/profiles/p1/share", body: { allow: ["x"] } });
  add("share profile failing", { method: "POST", path: "/profiles/zz/share", body: { on: false } });
  add("share profile member", { method: "POST", path: "/profiles/p1/share", body: {}, viewer: MEMBER, lang: "en" });
  add("move profile", { method: "POST", path: "/profiles/p1/move", body: { station: "b".repeat(64) } });
  add("move profile bad", { method: "POST", path: "/profiles/p1/move", body: { station: "x" } });
  add("move profile refused", { method: "POST", path: "/profiles/zz/move", body: { station: "b".repeat(64) } });
  add("share skill", { method: "POST", path: "/skills/web/share", body: { allow: "all" } });
  add("share skill bad name", { method: "POST", path: "/skills/.hidden/share", body: {} });
  add("share skill bad allow", { method: "POST", path: "/skills/web/share", body: { allow: [1] } });
  add("drop login", { method: "DELETE", path: "/logins/n1" });
  add("drop login none", { method: "DELETE", path: "/logins/n2" });
  add("login code", { method: "POST", path: "/logins/n1/code", body: { code: "x" } });
  add("login code none", { method: "POST", path: "/logins/n2/code", body: { code: "x" } });
  // logins.ts, signins.ts
  add("machine logins", { method: "GET", path: "/machine-logins" });
  add("machine logins read-only", { method: "GET", path: "/machine-logins/", viewer: VIEWER });
  add("machine login", { method: "GET", path: "/machine-logins/l1" });
  add("machine login read-only", { method: "GET", path: "/machine-logins/l1", viewer: VIEWER });
  add("machine login none", { method: "GET", path: "/machine-logins/l2" });
  add("machine login malformed", { method: "GET", path: "/machine-logins/%E0%A4%A" });
  add("machine login cancelled", { method: "DELETE", path: "/machine-logins/l1" });
  add("machine login answered", { method: "POST", path: "/machine-logins/l1/answer", body: { text: "code" } });
  add("machine login callback", { method: "POST", path: "/machine-logins/l1/callback", body: { method: "GET", path: "/cb", headers: { a: "1", b: 2 }, body: "eA==" } });
  add("machine login callback bad", { method: "POST", path: "/machine-logins/l1/callback", body: { path: "/cb" } });
  add("machine login page", { method: "POST", path: "/machine-logins/l1/browser" });
  add("machine login page failing", { method: "POST", path: "/machine-logins/l2/browser" });
  add("profile login page", { method: "POST", path: "/profiles/p1/login-browser" });
  add("profile login page unknown", { method: "POST", path: "/profiles/p8/login-browser" });
  add("new profile's login page", { method: "POST", path: "/logins/n1/browser" });
  add("new profile's login page none", { method: "POST", path: "/logins/n2/browser" });
  add("sign-in fill", { method: "POST", path: "/browser/sign-ins/s1/fill", body: { username: "a", password: "b", code: 5, keep: true } });
  add("sign-in fill refused", { method: "POST", path: "/browser/sign-ins/s2/fill", body: "[1]" });
  add("sign-in self", { method: "POST", path: "/browser/sign-ins/s1/self", body: { done: true } });
  add("sign-in deny", { method: "POST", path: "/browser/sign-ins/s1/deny", body: "{" });
  // agent-env.ts, tools.ts, diagnostics.ts, network.ts, permissions.ts, updates.ts
  add("agent env text", { method: "PUT", path: "/agent-env", body: { text: "Z=1\nSECRET_KEY=s3cr3t" } });
  add("agent env bad line", { method: "PUT", path: "/agent-env", body: { text: "bad" }, lang: "en" });
  add("agent env too many", { method: "PUT", path: "/agent-env", body: { text: "many" } });
  add("agent env patch", { method: "PUT", path: "/agent-env", body: { env: { C: "3", B: null } } });
  add("agent env patch nothing", { method: "PUT", path: "/agent-env", body: { env: { B: null, A_SECRET: null } } });
  add("agent env patch bad name", { method: "PUT", path: "/agent-env", body: { env: { "9x": "1" } } });
  add("agent env patch bad value", { method: "PUT", path: "/agent-env", body: { env: { C: 3 } } });
  add("agent env neither", { method: "PUT", path: "/agent-env", body: { env: [1] } });
  add("agent env member", { method: "PUT", path: "/agent-env", body: {}, viewer: MEMBER });
  add("agent env bad json", { method: "PUT", path: "/agent-env", body: "{" });
  add("tools access", { method: "GET", path: "/tools/access" });
  add("tools access set", { method: "PUT", path: "/tools/access", body: { access: "read" } });
  add("tools access bad", { method: "PUT", path: "/tools/access", body: { access: "all" } });
  add("tools access member", { method: "PUT", path: "/tools/access", body: { access: "read" }, viewer: MEMBER });
  add("diagnostics off", { method: "PUT", path: "/diagnostics/settings", body: { logs: false } });
  add("diagnostics on", { method: "PUT", path: "/diagnostics/settings", body: { logs: true } }, { world: (w) => (w.state.config = { telemetry: { logs: false } }) });
  add("diagnostics bad", { method: "PUT", path: "/diagnostics/settings", body: "5" });
  add("network", { method: "PUT", path: "/network/settings", body: { congestion: "bbr" } });
  add("network bad", { method: "PUT", path: "/network/settings", body: { congestion: "reno" } });
  add("network nothing", { method: "PUT", path: "/network/settings", body: {} });
  add("network empty body", { method: "PUT", path: "/network/settings" });
  add("network member", { method: "PUT", path: "/network/settings", body: {}, viewer: MEMBER, lang: "en" });
  add("restart", { method: "POST", path: "/station/restart" });
  add("restart cannot", { method: "POST", path: "/station/restart" }, { world: (w) => (w.state.cannotRestart = true) });
  add("restart member", { method: "POST", path: "/station/restart", viewer: MEMBER });
  add("permission asked", { method: "POST", path: "/permissions/request", body: { grant: "screen" } });
  add("permission no helper", { method: "POST", path: "/permissions/request", body: { grant: "documents" } });
  add("permission none", { method: "POST", path: "/permissions/request", body: { grant: "disk" } });
  add("permission unknown", { method: "POST", path: "/permissions/request", body: "{" });
  add("updates check", { method: "POST", path: "/updates/check" });
  add("updates channel", { method: "POST", path: "/updates/channel", body: { channel: "beta" } });
  add("updates channel bad", { method: "POST", path: "/updates/channel", body: { channel: "nightly" }, lang: "en" });
  add("updates auto", { method: "POST", path: "/updates/auto", body: { on: false } });
  add("updates auto bad", { method: "POST", path: "/updates/auto", body: { on: 1 } });
  add("update", { method: "POST", path: "/updates", body: { id: "codex" } });
  add("update repair", { method: "POST", path: "/updates", body: { id: "codex", repair: true } });
  add("update repair other", { method: "POST", path: "/updates", body: { id: "claude", repair: true } });
  add("update failing", { method: "POST", path: "/updates", body: { id: "nope" } });
  add("update back", { method: "POST", path: "/updates", body: { id: "station", to: "0.1.4" } });
  add("update back bad", { method: "POST", path: "/updates", body: { id: "station", to: 4 } });
  add("updates member", { method: "POST", path: "/updates/check", viewer: MEMBER });
  // workspaces.ts, copies.ts, xshare.ts, links.ts, overview
  add("workspaces", { method: "GET", path: "/workspaces" });
  add("workspaces member", { method: "GET", path: "/workspaces", viewer: OTHER_WS });
  add("join", { method: "POST", path: "/workspaces/join", body: { token: "t", lock: "c".repeat(64) } });
  add("join kept lock", { method: "POST", path: "/workspaces/join", body: { token: "kept" } });
  add("join failing", { method: "POST", path: "/workspaces/join", body: { token: "bad", lock: null } });
  add("join bad lock", { method: "POST", path: "/workspaces/join", body: { token: "t", lock: "x" } });
  add("join no token", { method: "POST", path: "/workspaces/join", body: "null" });
  add("join member", { method: "POST", path: "/workspaces/join", body: {}, viewer: MEMBER });
  add("retire", { method: "POST", path: "/retire", body: { to: "st2" } });
  add("retire busy", { method: "POST", path: "/retire", body: { to: "busy" } });
  add("retire broken", { method: "POST", path: "/retire", body: { to: "broken" } });
  add("retire no target", { method: "POST", path: "/retire", body: "{" });
  add("retire preview", { method: "GET", path: "/retire/preview" });
  add("retire cancel", { method: "DELETE", path: "/retire" });
  add("retire again", { method: "POST", path: "/retire/again" });
  add("retire member", { method: "GET", path: "/retire/preview", viewer: MEMBER });
  add("restore copies", { method: "POST", path: "/copies/restore", body: { station: "st9", gen: "g1", from: { station: "st2" } } });
  add("restore copies bad", { method: "POST", path: "/copies/restore", body: { station: "st9" } });
  add("share chat", { method: "PUT", path: "/sessions/s1/xshare", body: { to: [{ workspace: "w2", name: "W2", stations: [{ id: "a" }] }, "x"], write: true } });
  add("share chat of a thread", { method: "PUT", path: "/sessions/s2/xshare", body: { to: [] }, viewer: MEMBER });
  add("share chat bad", { method: "PUT", path: "/sessions/s1/xshare", body: { to: 1 } });
  add("share chat none", { method: "PUT", path: "/sessions/zz/xshare", body: { to: [] } });
  add("trust host", { method: "PUT", path: "/xshare/hosts", body: { workspace: "w2", name: "W2", station: "st", stationName: 5 }, viewer: OTHER_WS });
  add("link preview", { method: "GET", path: "/link-preview", query: [["url", "HTTPS://example.com"]] });
  add("link preview none", { method: "GET", path: "/link-preview", query: [["url", "http://none.example"]] });
  add("link preview bad", { method: "GET", path: "/link-preview", query: [["url", "ftp://x"]] });
  add("overview", { method: "GET", path: "/overview" });
  // drive.ts, transfers.ts
  add("drive", { method: "GET", path: "/drive" });
  add("drive read-only", { method: "GET", path: "/drive", viewer: VIEWER });
  add("drive joined", { method: "GET", path: "/drive", viewer: OTHER_WS });
  add("drive roots", { method: "PUT", path: "/drive/roots", body: { roots: ["/old", "/new", "/new"] } });
  add("drive roots joined", { method: "PUT", path: "/drive/roots", body: { roots: ["/x"] }, viewer: OTHER_WS });
  add("drive roots bad", { method: "PUT", path: "/drive/roots", body: { roots: "x" } });
  add("drive roots missing", { method: "PUT", path: "/drive/roots", body: { roots: ["/bad"] }, lang: "en" });
  add("drive roots protected", { method: "PUT", path: "/drive/roots", body: { roots: ["/docs"] } });
  add("drive roots not an object", { method: "PUT", path: "/drive/roots", body: "[]" });
  add("drive folders", { method: "GET", path: "/drive/folders", query: [["path", "/home"]] });
  add("drive folders read-only", { method: "GET", path: "/drive/folders", viewer: VIEWER });
  add("drive list", { method: "GET", path: "/drive/list", query: [["root", "/home/a"], ["path", "x"]] });
  add("drive stat missing", { method: "GET", path: "/drive/stat", query: [["root", "/home/a"], ["path", "missing"]] });
  add("drive read", { method: "GET", path: "/drive/read", query: [["root", "/home/a"], ["path", "a.txt"], ["offset", "2"], ["length", "x"]] });
  add("drive read too big", { method: "GET", path: "/drive/read", query: [["root", "/home/a"], ["path", "big"]] });
  add("drive upload", { method: "PUT", path: "/drive/upload", query: [["root", "/home/a"], ["path", "f"], ["id", "u1"], ["offset", "0"], ["total", "5"], ["replace", "1"]], body: "hello" });
  add("drive mkdir", { method: "POST", path: "/drive/mkdir", body: { root: "/home/a", path: "n" } });
  add("drive mkdir bad", { method: "POST", path: "/drive/mkdir", body: { root: "/home/a" } });
  add("drive rename", { method: "POST", path: "/drive/rename", body: { root: "/home/a", from: "a", to: "b" } });
  add("drive remove", { method: "POST", path: "/drive/remove", body: { root: "/home/a", path: "a", permanent: true } });
  add("drive zip", { method: "POST", path: "/drive/zip", body: { root: "/home/a", path: "d" } });
  add("drive watch", { method: "GET", path: "/drive/watch", query: [["root", "/home/a"], ["id", "w1"]] });
  add("drive watch failing", { method: "GET", path: "/drive/watch", query: [["root", "/home/a"], ["path", "x"]] });
  add("drive watch as a stream not watched", { method: "GET", path: "/drive/watch", headers: { accept: "text/event-stream" } });
  add("drive stage", { method: "POST", path: "/drive/stage", body: { root: "/home/a", path: "a.txt", zip: true } });
  add("drive grant", { method: "POST", path: "/drive/grant", body: { root: "/home/a", path: "p", names: ["a", "b", "a"], move: false } });
  add("drive grant joined", { method: "POST", path: "/drive/grant", body: { root: "/home/a", names: ["a"] }, viewer: OTHER_WS });
  add("drive grant move read-only", { method: "POST", path: "/drive/grant", body: { root: "/home/a", names: ["a"], move: true }, viewer: VIEWER });
  add("drive grant bad names", { method: "POST", path: "/drive/grant", body: { root: "/home/a", names: ["../x"] } });
  add("drive grant missing", { method: "POST", path: "/drive/grant", body: { root: "/home/a", names: ["missing"] } });
  add("transfer", { method: "POST", path: "/drive/transfers", body: { from: { station: "st2", grant: "g", root: "/r", names: ["a"] }, to: { root: "/home/a", path: "d" }, conflicts: { a: "keep" }, move: true } });
  add("transfer own", { method: "POST", path: "/drive/transfers", body: { from: { station: "st1", root: "/r", path: "p", names: ["a"] }, to: { root: "/home/a" } } });
  add("transfer no grant", { method: "POST", path: "/drive/transfers", body: { from: { station: "st2", root: "/r", names: ["a"] }, to: { root: "/home/a" } } });
  add("transfer not a folder", { method: "POST", path: "/drive/transfers", body: { from: { root: "/r", names: ["a"] }, to: { root: "/home/a", path: "f.txt" } } });
  add("transfer bad conflicts", { method: "POST", path: "/drive/transfers", body: { from: { root: "/r", names: ["a"] }, to: { root: "/home/a" }, conflicts: { a: "merge" } } });
  add("transfers", { method: "GET", path: "/drive/transfers" });
  add("transfer cancelled", { method: "POST", path: "/drive/transfers/t1/cancel" });
  add("transfer retried", { method: "POST", path: "/drive/transfers/t1/retry" });
  // screens (admin.ts)
  add("screens", { method: "GET", path: "/screens" });
  add("screen browser", { method: "POST", path: "/screens/browser", body: { url: "https://x", id: "u_0123456789ab" } });
  add("screen browser bad id", { method: "POST", path: "/screens/browser", body: { url: "https://x", id: "u_1" } });
  add("screen browser bad url", { method: "POST", path: "/screens/browser", body: "null" });
  add("screen browser failing", { method: "POST", path: "/screens/browser", body: { url: "https://fail" } });
  add("screen closed", { method: "POST", path: "/screens/tab1/close" });
  add("screen close refused", { method: "POST", path: "/screens/desk/close", lang: "en" });
  add("screen close failing", { method: "POST", path: "/screens/fail/close" });
  add("screen close malformed", { method: "POST", path: "/screens/%E0%A4%A/close" });
  add("screen open url", { method: "POST", path: "/screens/tab1/open-url", body: { url: "https://y" } });
  add("screen open url failing", { method: "POST", path: "/screens/sim1/open-url", body: { url: "bad" } });
  add("screen open url failing tab", { method: "POST", path: "/screens/tab1/open-url", body: { url: "bad" } });
  add("screen open url none", { method: "POST", path: "/screens/zz/open-url", body: {} });
  add("screen open url no debug", { method: "POST", path: "/screens/desk/open-url", body: {} });
  add("screen open url bad", { method: "POST", path: "/screens/tab1/open-url", body: { url: 1 } });
  add("screen open url read-only", { method: "POST", path: "/screens/tab1/open-url", body: {}, viewer: VIEWER });
  add("screen reload", { method: "POST", path: "/screens/tab1/reload" });
  add("screen back", { method: "POST", path: "/screens/tab1/back" });
  add("screen forward", { method: "POST", path: "/screens/tab1/forward" });
  add("screen sleep", { method: "POST", path: "/screens/tab1/sleep" });
  add("screen views ended", { method: "POST", path: "/screens/tab1/views/end" });
  add("screen view ended", { method: "POST", path: "/screens/tab1/views/v%201/end" });
  add("screen view malformed", { method: "POST", path: "/screens/tab1/views/%E0%A4%A/end" });
  add("screen view watch", { method: "POST", path: "/screens/tab1/views/v1/watch" });
  add("sim logs", { method: "GET", path: "/screens/sim1/logs", query: [["after", "7"]] });
  add("sim logs none", { method: "GET", path: "/screens/sim1/logs" });
  add("sim logs other", { method: "GET", path: "/screens/zz/logs" });
  add("sim logs read-only", { method: "GET", path: "/screens/sim1/logs", viewer: VIEWER });
  add("sim apps failing", { method: "GET", path: "/screens/sim1/apps" });
  add("sim settings", { method: "GET", path: "/screens/sim1/settings" });
  add("sim setting", { method: "POST", path: "/screens/sim1/settings", body: { name: "dark", value: "1" } });
  add("sim setting none", { method: "POST", path: "/screens/sim1/settings", body: { name: "x", value: "1" } });
  add("sim chrome", { method: "GET", path: "/screens/sim1/chrome/1/2" });
  add("sim chrome failing", { method: "GET", path: "/screens/zz/chrome/1/2" });
  add("sim screenshot", { method: "POST", path: "/screens/sim1/screenshot" });
  add("sim location", { method: "POST", path: "/screens/sim1/location", body: { at: "home" } });
  add("sim location none", { method: "POST", path: "/screens/sim1/location", body: {} });
  add("sim location bad", { method: "POST", path: "/screens/sim1/location", body: { at: 5 } });
  add("sim location nowhere", { method: "POST", path: "/screens/sim1/location", body: { at: "nowhere" } });
  add("sim status bar", { method: "POST", path: "/screens/sim1/status-bar", body: { tidy: true } });
  add("sim biometrics", { method: "POST", path: "/screens/sim1/biometrics", body: { what: "match" } });
  add("sim biometrics bad", { method: "POST", path: "/screens/sim1/biometrics", body: { what: "x" } });
  add("sim uninstall", { method: "POST", path: "/screens/sim1/uninstall", body: { app: "a" } });
  add("sim uninstall none", { method: "POST", path: "/screens/sim1/uninstall", body: {} });
  add("sim record", { method: "POST", path: "/screens/sim1/record", body: { panel: "cover" } });
  add("sim push", { method: "POST", path: "/screens/sim1/push", body: { app: "a", text: "hi" } });
  add("sim push bad", { method: "POST", path: "/screens/sim1/push", body: { app: "a" } });
  add("sim record stop", { method: "POST", path: "/screens/sim1/record/stop" });
  add("sim install", { method: "POST", path: "/screens/sim1/install", body: { path: "/x/A.app" } });
  add("sim install bad", { method: "POST", path: "/screens/sim1/install", body: { path: "/x/A.zip" } });
  add("sim relaunch", { method: "POST", path: "/screens/sim1/relaunch", body: { app: "a" } });
  add("sim relaunch none", { method: "POST", path: "/screens/sim1/relaunch", body: { app: "b" } });
  // connects.ts
  add("connect edited", { method: "PUT", path: "/connects/slack1", body: { bind: { model: "sonnet", effort: "high" }, slack: { botToken: "new" }, owner: { id: " Bob@Example.com ", name: "Bob" }, station: "" } });
  add("connect moved runtime", { method: "PUT", path: "/connects/slack1", body: { bind: { runtime: "codex", profiles: ["p1", "p1", " "] } } });
  add("connect moved runtime no model", { method: "PUT", path: "/connects/slack1", body: { bind: { runtime: "codex", model: "nope" } } });
  add("connect bad runtime", { method: "PUT", path: "/connects/slack1", body: { bind: { runtime: { x: 1 } } } });
  add("connect bad profiles", { method: "PUT", path: "/connects/slack1", body: { bind: { profiles: "p1" } } });
  add("connect disabled profile", { method: "PUT", path: "/connects/slack1", body: { bind: { profile: "p2" } } });
  add("connect unknown profile", { method: "PUT", path: "/connects/slack1", body: { bind: { profile: "p9" } } });
  add("connect bad effort", { method: "PUT", path: "/connects/slack1", body: { bind: { effort: "max" } } });
  add("connect bad owner", { method: "PUT", path: "/connects/slack1", body: { owner: { id: "not an email" } }, lang: "en" });
  add("connect owner by a member", { method: "PUT", path: "/connects/slack1", body: { owner: { id: "local" } }, viewer: MEMBER });
  add("connect added", { method: "PUT", path: "/connects/new1", body: { kind: "slack", bind: { runtime: "claude" }, slack: { botToken: "x" }, mode: "single-session", requireMention: false, enabled: false } });
  add("connect added held", { method: "PUT", path: "/connects/new2", body: { kind: "slack", bind: { runtime: "claude" }, slack: { botToken: "held" } } });
  add("connect added no runtime", { method: "PUT", path: "/connects/new3", body: { kind: "comma" } });
  add("connect added joined", { method: "PUT", path: "/connects/new4", body: { kind: "group", bind: { runtime: "claude" } }, viewer: OTHER_WS });
  add("connect of another workspace", { method: "PUT", path: "/connects/w2c", body: {} });
  add("connect deleted", { method: "DELETE", path: "/connects/slack1" });
  add("connect deleted unknown", { method: "DELETE", path: "/connects/zz" });
  add("connect session", { method: "POST", path: "/connects/slack1/session", body: { session: "s1", title: "T" } });
  add("connect session new", { method: "POST", path: "/connects/slack1/session", body: {} });
  add("connect reconnected", { method: "POST", path: "/connects/slack1/reconnect" });
  add("connect reconnected feishu", { method: "POST", path: "/connects/fe1/reconnect" });
  // slack.ts
  add("slack connect", { method: "POST", path: "/connects", body: { slack: { appToken: " xapp ", botToken: "xoxb" }, bind: { runtime: "claude" } } });
  add("slack connect bad token", { method: "POST", path: "/connects", body: { slack: { botToken: "bad" }, bind: { runtime: "claude" } } });
  add("slack connect installed", { method: "POST", path: "/connects", body: { slack: { install: "st5", appToken: "xapp" }, bind: { runtime: "claude" } } });
  add("slack connect not installed", { method: "POST", path: "/connects", body: { slack: { install: "st6" } } });
  add("slack connect with app", { method: "POST", path: "/connects", body: { slack: { appId: "A7" }, bind: { runtime: "claude" } } });
  add("slack app made", { method: "POST", path: "/slack/apps", body: { settings: { name: " Bot ", backgroundColor: "#abcdef" }, icon: "data:image/jpeg;base64,AAAA" } });
  add("slack app made large icon", { method: "POST", path: "/slack/apps", body: { settings: { name: " Bot ", backgroundColor: "#abcdef" }, icon: `data:image/jpeg;base64,${"AAAA".repeat(30000)}` } });
  add("slack app made icon refused", { method: "POST", path: "/slack/apps", body: { icon: "nope" } });
  add("slack app made bad color", { method: "POST", path: "/slack/apps", body: { settings: { backgroundColor: "red" } } });
  add("slack app made other team", { method: "POST", path: "/slack/apps", body: { team: "T9" } });
  add("slack app made no token", { method: "POST", path: "/slack/apps", body: {}, viewer: MEMBER });
  add("slack installed", { method: "POST", path: "/slack/installs", body: { state: "st6", code: "c" } });
  add("slack installed bad code", { method: "POST", path: "/slack/installs", body: { state: "st6", code: "bad" } });
  add("slack installed not ours", { method: "POST", path: "/slack/installs", body: { state: "" } });
  add("slack verify", { method: "POST", path: "/slack/verify", body: { connect: "slack1", appToken: " ", install: "st5" } });
  add("slack verify of another workspace", { method: "POST", path: "/slack/verify", body: { connect: "w2c" } });
  add("slack verify bad", { method: "POST", path: "/slack/verify", body: { botToken: "bad" } });
  add("slack config token", { method: "POST", path: "/slack/config-tokens", body: { refreshToken: " xoxe-ok " } });
  add("slack config token refused", { method: "POST", path: "/slack/config-tokens", body: { refreshToken: "xoxe-bad" } });
  add("slack config token bad", { method: "POST", path: "/slack/config-tokens", body: { refreshToken: "x" } });
  add("slack people", { method: "GET", path: "/slack/people" });
  add("slack create app url", { method: "GET", path: "/slack/create-app-url", query: [["name", " my bot "]] });
  add("slack create app url none", { method: "GET", path: "/slack/create-app-url" });
  add("slack this is me", { method: "PUT", path: "/me/slack/U1" });
  add("slack not me", { method: "DELETE", path: "/me/slack/U1" });
  add("slack app dropped", { method: "DELETE", path: "/slack/apps/A5" });
  add("slack app dropped not mine", { method: "DELETE", path: "/slack/apps/A6" });
  add("slack config token removed", { method: "DELETE", path: "/slack/config-tokens/T1" });
  add("slack connect's app", { method: "GET", path: "/connects/slack1/slack-app" });
  add("slack connect's app none", { method: "GET", path: "/connects/w2c/slack-app", viewer: OTHER_WS });
  add("slack connect's app changed", { method: "PUT", path: "/connects/slack1/slack-app", body: { name: "N", groups: { dm: true }, icon: "data:image/png;base64,AAAA" } });
  add("slack connect's app empty name", { method: "PUT", path: "/connects/slack1/slack-app", body: { name: " " } });
  add("slack connect's app made", { method: "POST", path: "/connects/slack1/slack-app", body: { name: "B" } });
  // feishu.ts, comma.ts, group.ts
  add("feishu verify", { method: "POST", path: "/feishu/verify", body: { appId: " cli ", appSecret: "s", domain: "lark" } });
  add("feishu verify bad", { method: "POST", path: "/feishu/verify", body: { appSecret: "bad" } });
  add("feishu connect", { method: "POST", path: "/feishu/connects", body: { feishu: { appId: "cli_2", appSecret: "s", threads: true }, bind: { runtime: "claude" } } });
  add("feishu connect bad", { method: "POST", path: "/feishu/connects", body: { feishu: { appId: "cli_2", appSecret: "bad" }, bind: { runtime: "claude" } } });
  add("feishu connect registered", { method: "POST", path: "/feishu/connects", body: { feishu: { registration: "r1" } } });
  add("feishu connect not registered", { method: "POST", path: "/feishu/connects", body: { feishu: { registration: "r9" } } });
  add("feishu registration", { method: "POST", path: "/feishu/registrations", body: { name: " app ", domain: "lark", bind: { runtime: "claude" }, mode: "single-session", threads: true } });
  add("feishu registration failing", { method: "POST", path: "/feishu/registrations", body: { name: "fail" } });
  add("feishu registration cancelled", { method: "DELETE", path: "/feishu/registrations/r1" });
  add("feishu registration not there", { method: "DELETE", path: "/feishu/registrations/r9" });
  add("feishu secret", { method: "PUT", path: "/feishu/connects/fe1/secret", body: { appSecret: " s2 " } });
  add("feishu secret bad", { method: "PUT", path: "/feishu/connects/fe1/secret", body: { appSecret: "bad" } });
  add("feishu secret not feishu", { method: "PUT", path: "/feishu/connects/slack1/secret", body: {} });
  add("comma connect", { method: "POST", path: "/comma/connects", body: { line: "comma https://c.example t", bind: { runtime: "claude" } } });
  add("comma connect bad", { method: "POST", path: "/comma/connects", body: { line: "x" } });
  add("group connect", { method: "POST", path: "/group/connects", body: { group: { server: "A".repeat(64), relays: "https://r1.example, https://r2.example https://r1.example", code: "abcd-efgh-jkmn-pqrs", botName: " Bot " }, bind: { runtime: "claude" } } });
  add("group connect bad relay", { method: "POST", path: "/group/connects", body: { group: { server: "a".repeat(64), relays: ["ftp://x"], code: "ABCDEFGHJKMNPQRS" } } });
  add("group connect bad code", { method: "POST", path: "/group/connects", body: { group: { server: "a".repeat(64), relays: ["https://r"], code: "1111" } } });
  add("group connect no code", { method: "POST", path: "/group/connects", body: { group: { server: "a".repeat(64), relays: ["https://r"] } } });
  add("group connect not a group", { method: "POST", path: "/group/connects", body: { group: "x" } });
  // vault.ts, vault-requests.ts
  add("vaults", { method: "GET", path: "/vault/vaults" });
  add("vaults no lock", { method: "GET", path: "/vault/vaults", viewer: OTHER_WS });
  add("vaults latest", { method: "POST", path: "/vault/vaults/latest", body: { held: [{ id: "v1", ws: "w1", members: ["u1"], owner: "u1", sig: { key: "k" } }, { id: "v1", ws: "w2", members: [] }, 5] } });
  add("vaults latest bad", { method: "POST", path: "/vault/vaults/latest", body: { held: 1 } });
  add("vault written", { method: "PUT", path: "/vault/vaults", body: { id: "v1", ws: "w1", members: [], owner: "u1", seq: 3 } });
  add("vault written conflict", { method: "PUT", path: "/vault/vaults", body: { id: "v1", ws: "w1", members: ["u1"], seq: 5 } });
  add("vault written bad", { method: "PUT", path: "/vault/vaults", body: { id: "v1", ws: "w1", members: ["u1"], seq: 3, bad: true } });
  add("vault copied older", { method: "PUT", path: "/vault/vaults", query: [["copy", "1"]], body: { id: "v1", ws: "w1", members: ["u1"], seq: 1 } });
  add("vault new", { method: "PUT", path: "/vault/vaults", body: { id: "v9", ws: "w1", members: ["u1"], seq: 0 } });
  add("vault other workspace", { method: "PUT", path: "/vault/vaults", body: { id: "v9", ws: "w2" } });
  add("vault not one", { method: "PUT", path: "/vault/vaults", body: "[1]" });
  add("vault items", { method: "GET", path: "/vault/items" });
  add("vault items of one", { method: "GET", path: "/vault/items", query: [["vault", "v1"]] });
  add("vault items of none", { method: "GET", path: "/vault/items", query: [["vault", "v2"]] });
  add("vault item written", { method: "PUT", path: "/vault/items", body: { vault: "v1", id: "i9", version: 0 } });
  add("vault item conflict", { method: "PUT", path: "/vault/items", body: { vault: "v1", id: "i9", version: 4 } });
  add("vault item no vault", { method: "PUT", path: "/vault/items", body: { vault: "v2", id: "i9" } });
  add("vault boxes", { method: "GET", path: "/vault/boxes" });
  add("vault box", { method: "PUT", path: "/vault/boxes", body: { device: "dev1", ws: "w1", at: 5 } });
  add("vault box not the device", { method: "PUT", path: "/vault/boxes", body: { device: "dev2", ws: "w1", at: 5 } });
  add("vault box bad", { method: "PUT", path: "/vault/boxes", body: { ws: "w1" } });
  add("vault requests", { method: "GET", path: "/vault/requests" });
  add("vault requests no lock", { method: "GET", path: "/vault/requests", viewer: OTHER_WS });
  add("vault grant", { method: "POST", path: "/vault/grants", body: { request: "q1" } });
  add("vault grant refused", { method: "POST", path: "/vault/grants", body: { request: "no" } });
  add("vault grant bad", { method: "POST", path: "/vault/grants", body: "1" });
  add("vault deny no lock", { method: "POST", path: "/vault/denials", body: {}, viewer: OTHER_WS });
  add("vault saved", { method: "POST", path: "/vault/saves", body: { request: "q2", vault: "v1" } });
  add("vault described", { method: "POST", path: "/vault/described", body: { request: "q3" } });
  add("vault removed", { method: "POST", path: "/vault/removed", body: { request: "q4" } });
  add("vault uses", { method: "GET", path: "/vault/uses", query: [["vault", "v1"]] });
  add("vault uses no lock", { method: "GET", path: "/vault/uses", viewer: OTHER_WS });
  add("plain", { method: "GET", path: "/vault/plain", viewer: { ...OWNER, email: "Ann@Example.com" } });
  add("plain lasts", { method: "PUT", path: "/vault/plain/lasts", body: { lasts: 60, at: 1 } });
  add("plain lasts bad", { method: "PUT", path: "/vault/plain/lasts", body: "null" });
  add("plain item", { method: "GET", path: "/vault/plain/item", query: [["id", "pi1"]] });
  add("plain item not mine", { method: "GET", path: "/vault/plain/item", query: [["id", "pi2"]] });
  add("plain put", { method: "PUT", path: "/vault/plain", body: { id: "pi9", version: 0, fields: [] }, viewer: OTHER_WS });
  add("plain put conflict", { method: "PUT", path: "/vault/plain", body: { id: "pi2", version: 0 }, viewer: OTHER_WS });
  add("plain put locked", { method: "PUT", path: "/vault/plain", body: { id: "pi1", version: 1 } });
  add("plain put deleted", { method: "PUT", path: "/vault/plain", body: { id: "pi1", version: 1, deleted: true } });
  add("plain put not mine", { method: "PUT", path: "/vault/plain", body: { id: "pi2", version: 2, deleted: true } });
  add("plain grant", { method: "POST", path: "/vault/plain/grants", body: { request: "q1" } });
  add("plain denial", { method: "POST", path: "/vault/plain/denials", body: { request: "q1" } });
  add("plain described", { method: "POST", path: "/vault/plain/described", body: { request: "q1" } });
  add("plain removed", { method: "POST", path: "/vault/plain/removed", body: { request: "q1" } });
  add("plain saved", { method: "POST", path: "/vault/plain/saves", body: { request: "q1" } });
  // admin.ts
  add("read-only member writes", { method: "POST", path: "/sessions/s1/stop", viewer: VIEWER });
  add("read-only member marks own read", { method: "PUT", path: "/threads/7/read", body: { n: 3 }, viewer: VIEWER });
  add("unknown route", { method: "GET", path: "/nope" });
  add("a viewer with no name", { method: "GET", path: "/nope", viewer: { sub: "u5", email: "eve@example.com", role: "member", workspace: "w1", device: "d5" } });
  add("idempotent write", { method: "POST", path: "/sessions/s1/evict", headers: { "Idempotency-Key": "k1" } });
  add("idempotent write again", { method: "POST", path: "/sessions/s1/evict", headers: { "Idempotency-Key": "k1" } });
  add("batch", { method: "POST", path: "/batch", body: { gets: ["/threads/7/entries?before=3", "/sessions/s1", "/threads/7", "/nope"] } }, { unordered: true });
  // (each answer a line as it is read: admin.ts `batchLines`; a client from before given each as a GET of it is)
  add("batch lines", { method: "POST", path: "/batch", headers: { accept: "application/x-ndjson" }, body: { gets: ["/threads/7/entries?before=3", "/sessions/s1", "/threads/7", "/nope"] } });
  add("batch lines for a client from before", { method: "POST", path: "/batch", headers: { Accept: "application/json, application/x-ndjson", "stillfail-runtimes": "claude" }, body: { gets: ["/sessions/s1", "/threads/7/entries"] } }, { world: (w) => w.handlers.set("runtimeView.runtimeView", ([, v]) => ({ ...v, projected: true })) });
  add("batch keyed", { method: "POST", path: "/batch", headers: { "idempotency-key": "b1" }, body: { gets: ["/threads/7"] } });
  add("batch bad", { method: "POST", path: "/batch", body: { gets: "x" } });
  add("batch too large", { method: "POST", path: "/batch", body: Buffer.alloc(1_000_001, 32) });
  add("old client's runtimes", { method: "GET", path: "/sessions", headers: { "stillfail-runtimes": "claude" } }, { world: (w) => w.handlers.set("runtimeView.runtimeView", ([, v]) => v) });
  add("old client refused", { method: "GET", path: "/sessions/s1", headers: { "stillfail-runtimes": "claude" } }, { world: (w) => w.handlers.set("runtimeView.runtimeView", () => ({ $omit: 1 })) });
  add("preview", { method: "GET", path: "/preview/3000/x" }, { world: (w) => w.handlers.set("jobs/preview.proxyPreview", () => ({ status: 200, headers: [["a", "1"], ["a", "2"]], body: { $bytes: Buffer.from("hi").toString("base64") } })) });
  void json;
}

// ---------------------------------------------------------------------------------------------------------------

if (!process.execArgv.includes("--experimental-test-module-mocks")) {
  const { mbReaderBinary } = await import("../src/read/mb-reader.ts");
  const skip = mbReaderBinary() === null ? "the MoonBit program (stillfail-reader) is not built here" : false;
  test("the MoonBit admin API answers as the TypeScript one (run with module mocks)", { skip }, async () => {
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
