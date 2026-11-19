// The station's browser in MoonBit (station/mb src/browser: `stillfail-reader-harness --builder harness-browser`) held to the TypeScript
// it is a port of (src/browser/): the same world given to both, each part of the one and of the other driven the same
// way, and what each did compared: what it answered, what it asked of its world (each DevTools command on each
// connection, the Chrome host's finds, launches and kills, a sign-in form's waits) and told its station (screens added
// and taken away, a tab's use, a view's size, a sign-in taken out, the log), and every file it keeps (owners.json,
// user-tabs.json, contexts.json, state.json, a login tab's state), byte for byte. The functions of no state on the same
// inputs: addresses, cookies and passkeys, Chrome's command line and its DevToolsActivePort, keys and pictures, the
// pages' scripts, Farview's wire, its release and config, the tool's words. A Farview tab's ports are served here, on
// 127.0.0.1, and both sides reach them over TCP (the program through its shell). Time is the test's clock for both:
// the program's timers are armed on it here, and nothing waits for real time.
import assert from "node:assert/strict";
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { Fibers } from "../src/ops/fibers.ts";
import { log } from "../src/ops/log.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { ScreenRefused } from "../src/screens/hub.ts";
import type { ScreenSource, ScreenView } from "../src/screens/source.ts";
import { StationBrowser } from "../src/browser/browser.ts";
import { Browsers } from "../src/browser/browsers.ts";
import type { Cdp, CdpEvent } from "../src/browser/cdp.ts";
import { BrowserState, type ChromeHost, type Running, chromeArgs, headfulAgent, parseActivePort } from "../src/browser/chrome.ts";
import { decodeAnswer, encodeAsk } from "../src/browser/farview-agent.ts";
import { FarviewForm } from "../src/browser/farview-form.ts";
import { FARVIEW_RELEASES, farviewAsset, farviewCacheDir, farviewSources, ghSource } from "../src/browser/farview-release.ts";
import { DEFAULT_SIZE, FarviewScreen, FrameLink, inputOf, sizeFor } from "../src/browser/farview-screen.ts";
import { FIRST_PAGE, chatDir, farviewConfig, farviewFor, farviewHowTo, hostFileOf } from "../src/browser/farview.ts";
import { BEHIND, Gate } from "../src/browser/gate.ts";
import { Owners } from "../src/browser/owners.ts";
import { Authenticators, passkeyOf, sitePasskeys } from "../src/browser/passkeys.ts";
import { pass, sessionOfPath, sessionPath } from "../src/browser/proxy.ts";
import { BUTTON_SCRIPT, FINDER, LOOK_SCRIPT, MOVE_MS, TabForm, drive, pickScript } from "../src/browser/signin-form.ts";
import { allCookies, expired, keptOf, ofSites, siteCookies, stateOf } from "../src/browser/signins.ts";
import { BROWSER, browserTools, howTo, sessionWs } from "../src/browser/tool.ts";
import { addressOrSearch, BLANK_PAGE, extractFirstHttpUrl, normalizeBrowserUrl, persistableBrowserUrl, siteOfBrowserUrl } from "../src/browser/url.ts";
import { COPY_HOOK, LOGIN_HOOK, TabView, fillScript, hostOf, jpegSize, keyCode, keyEvent, passkeyHook, rpFor, sameClientData, toViewport, viewportOf } from "../src/browser/view.ts";
import { testClock } from "./hub-fakes.ts";
import { childGone } from "./child-gone.ts";

type Json = any;

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), `mbbrowser-${what}-`));
  dirs.push(dir);
  return dir;
};
// (the program gone first, then its directories: setup-env.mjs looks for what a file left running)
after(async () => {
  await childGone(program?.child);
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// A JSON round trip: what both sides are compared as.
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

/// The test's clock, shared by both sides: the TypeScript's parts' Fibers and the program's timers.
const t = testClock();
const clockFibers = new Fibers("mb-browser", t.clock);
after(() => clockFibers.close());
const later = (ms: number, f: () => void) => clockFibers.after(ms, f); // timer: the TypeScript's tabs' own, on the test's clock

/// Turns of the loop until what was set going here is done (the TypeScript's side of `quiet`): `n` of them with no file
/// request out, as hub-fakes.ts `settle`. The TypeScript's tabs read and write their files on libuv's threads (a login's
/// state.json read as its tab opens, user-tabs.json written as it changes), and how many turns that takes is the
/// machine's: counted alone, a CI runner compared the two sides before the TypeScript's had read it (134186072690,
/// 2026-11-17).
async function turns(n = 30) {
  for (let quiet = 0; quiet < n; ) {
    await new Promise((r) => setImmediate(r));
    // (a file handle's close, the last step of fs/promises' writeFile and readFile, is a request of its own: CloseReq)
    quiet = process.getActiveResourcesInfo().some((r) => r === "FSReqPromise" || r === "FSReqCallback" || r === "CloseReq") ? 0 : quiet + 1;
  }
}

// ── what both sides do, written down the same way ──

/// What a side asked of its world or told its station, in order: `[channel, what, ...args]`. A DevTools connection's
/// commands are its own channel (its id); the rest by what they are.
type Entry = Json[];

/// The world both sides are given: what a DevTools command is answered (by connection, method, params, session), what
/// the Chrome host does, a form's wait. Throwing is answering with that failure.
type World = (call: string, inst: string, args: Json[]) => Json;

/// What each side wrote, normalized: random ids of a person's popups and viewers' bindings made the same.
function normal(v: Json): Json {
  const s = JSON.stringify(v ?? null)
    .replace(/u_p_(\d+)_[0-9a-f]{6}/g, "u_p_$1_RANDOM")
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "UUID")
    .replace(/__stillfailPasskey_[0-9a-f]{32}/g, "__stillfailPasskey_UUID");
  return JSON.parse(s);
}

/// The entries by channel, each channel's in its order (what one connection was asked is in the order it was asked;
/// two connections' asks have no order between them).
function byChannel(entries: Entry[], conns: string[]): Record<string, Json[]> {
  // (each side's connections named by the order they were made in: their ids are each side's own)
  const names = new Map<string, string>(conns.map((c, i) => [c, `conn${i + 1}`]));
  const rename = (v: Json): Json => (typeof v === "string" && names.has(v) ? names.get(v) : v);
  const out: Record<string, Json[]> = {};
  for (const e of normal(entries) as Entry[]) {
    const r = e.map(rename);
    (out[String(r[0])] ??= []).push(r.slice(1));
  }
  return out;
}

function sameEntries(ts: Entry[], mb: Entry[], what: string, tsConnIds: string[] = [], mbConnIds: string[] = []) {
  assert.deepEqual(byChannel(mb, mbConnIds), byChannel(ts, tsConnIds), `${what}: what each asked and told`);
}

/// Every file under `dir`, by its path in it, with its text.
function filesOf(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (at: string) => {
    if (!existsSync(at)) return;
    for (const name of readdirSync(at).sort()) {
      const path = join(at, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (!name.endsWith(".tmp")) out[path.slice(dir.length + 1)] = readFileSync(path, "utf8");
    }
  };
  walk(dir);
  return out;
}

function sameFiles(ts: string, mbDir: string, what: string) {
  assert.deepEqual(filesOf(mbDir), filesOf(ts), `${what}: the files kept`);
}

/// An outcome as either side gives it: its value, or its failure's kind and words (a refused screen by its status and
/// key).
async function outcome(f: () => Promise<unknown> | unknown): Promise<Json> {
  try {
    return { ok: normal(plain(await f())) };
  } catch (e) {
    if (e instanceof ScreenRefused) return { refused: [e.status, e.key] };
    return { failed: (e as Error).message };
  }
}

/// The program's answer as an outcome.
async function mbOutcome(f: () => Promise<Json>): Promise<Json> {
  try {
    return { ok: normal(await f()) };
  } catch (e) {
    const err = (e as { err?: Json }).err;
    if (err?.kind === "ScreenRefused") return { refused: [err.status, err.key] };
    return { failed: err?.message ?? (e as Error).message };
  }
}

// ── the program ──

// Socket and program messages wake waits for facts delivered from outside this process.
const farviewEvents = new EventEmitter();
let farviewVersion = 0;
function wakeFarview() { farviewVersion++; farviewEvents.emit("changed"); }

class Program {
  readonly child: ChildProcessWithoutNullStreams;
  #next = 0;
  readonly #done = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void }>();
  readonly #timers = new Map<number, () => void>();
  readonly #inflight = new Set<Promise<unknown>>();
  #asked = 0;
  /// What it asked and told, as entries.
  entries: Entry[] = [];
  /// The connections it made, in order.
  conns: string[] = [];
  /// When each of its timers comes due (the test's clock).
  readonly due = new Map<number, number>();
  world: World = () => null;
  #stderr = "";

  constructor() {
    const shell = fresh("shell");
    this.child = spawn(binary!, ["--builder", "harness-browser", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
    createInterface({ input: this.child.stdout }).on("line", (line) => this.#line(line));
    this.child.stderr.on("data", (d) => (this.#stderr += d));
    this.child.on("exit", (code) => {
      for (const w of this.#done.values()) w.reject(new Error(`the program ended (${code}): ${this.#stderr}`));
    });
  }

  #send(j: Json) {
    this.child.stdin.write(`${JSON.stringify({ ...j, now: clockFibers.now() })}\n`);
  }

  cmd(cmd: string, j: Json = {}): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve, reject) => {
      this.#done.set(id, { resolve, reject });
      this.#send({ cmd, id, ...j });
    });
  }

  #line(line: string) {
    const m = JSON.parse(line);
    if (typeof m.done === "number") {
      const w = this.#done.get(m.done);
      this.#done.delete(m.done);
      if (m.err !== undefined) w?.reject(Object.assign(new Error(m.err.message), { err: m.err }));
      else w?.resolve(m.ok);
      return;
    }
    if (typeof m.tell === "string") {
      if (m.tell === "after") {
        this.due.set(m.timer, clockFibers.now() + Math.max(0, m.ms));
        this.#timers.set(m.timer, clockFibers.after(m.ms, () => (this.due.delete(m.timer), void this.cmd("fire", { timer: m.timer })))); // timer: the program's own, armed on the test's clock
      } else if (m.tell === "cancel") (this.#timers.get(m.timer)?.(), this.#timers.delete(m.timer), this.due.delete(m.timer));
      else { this.entries.push(tellEntry(m.tell, m.inst, m.args)); wakeFarview(); }
      return;
    }
    if (typeof m.call === "string") {
      this.#asked++;
      if (m.call === "connect") this.conns.push(m.args[0]);
      this.entries.push(askEntry(m.call, m.inst, m.args));
      wakeFarview();
      const run = (async () => {
        try {
          const ok = await this.world(m.call, m.inst, m.args);
          this.#send({ re: m.id, ok: ok === undefined ? null : ok });
        } catch (e) {
          this.#send({ re: m.id, err: { kind: "Error", message: (e as Error)?.message ?? String(e) } });
        }
      })();
      this.#inflight.add(run);
      void run.finally(() => this.#inflight.delete(run));
    }
  }

  /// Once nothing here or there goes on before something else is asked.
  async quiet() {
    for (let i = 0; i < 1000; i++) {
      await Promise.all([...this.#inflight]);
      await turns(3);
      const asked = this.#asked;
      await this.cmd("sync");
      await turns(3);
      if (this.#inflight.size === 0 && this.#asked === asked) return;
    }
    throw new Error("the program never came to rest");
  }

  fn(name: string, ...args: Json[]): Promise<Json> {
    return this.cmd("fn", { name, args });
  }
  make(kind: string, inst: string, o: Json = {}): Promise<Json> {
    return this.cmd("new", { kind, inst, ...o });
  }
  call(inst: string, method: string, ...args: Json[]): Promise<Json> {
    return this.cmd("call", { inst, method, args });
  }
  emit(cdp: string, method: string, params: Json, sessionId?: string): Promise<Json> {
    return this.cmd("emit", { cdp, method, params, ...(sessionId === undefined ? {} : { sessionId }) });
  }
}

/// An entry of an ask: a DevTools command on its connection's channel, the rest on the asker's.
function askEntry(call: string, inst: string, args: Json[]): Entry {
  if (call === "cdp.send") return [inst, args[0], args[1] ?? {}, args[2] ?? null];
  return [call, ...args];
}

/// An entry of what a part told: its kind on a channel of its own.
function tellEntry(tell: string, _inst: string, args: Json[]): Entry {
  if (tell === "log") return ["log", args[0], args[2], args[3] ?? {}];
  if (tell === "cdp.closed") return [_inst, "closed"];
  return [tell, ...args];
}

let program: Program | null = null;
async function mb(): Promise<Program> {
  if (program !== null) return program;
  program = new Program();
  return program;
}

// The TypeScript side's own entries, and its log heard as the program's is.
let tsEntries: Entry[] = [];
const logInfo = log.info;
const logWarn = log.warn;
log.info = (at: string, message: string, fields?: Json) => {
  if (at === "browser") tsEntries.push(["log", "info", message, plain(fields ?? {})]);
  else logInfo(at, message, fields);
};
log.warn = (at: string, message: string, fields?: Json) => {
  if (at === "browser") tsEntries.push(["log", "warn", message, plain(fields ?? {})]);
  else logWarn(at, message, fields);
};
after(() => {
  log.info = logInfo;
  log.warn = logWarn;
});

/// A DevTools connection of the TypeScript's side: its commands answered by the world as the program's are, its
/// events given by the test.
class WorldCdp implements Cdp {
  readonly id: string;
  #listeners = new Set<(e: CdpEvent) => void>();
  #end!: () => void;
  closed = new Promise<void>((r) => (this.#end = r));
  gone = false;
  readonly #world: () => World;
  constructor(id: string, world: () => World) {
    this.id = id;
    this.#world = world;
  }
  async send(method: string, params: object = {}, sessionId?: string) {
    if (this.gone) throw new Error("closed");
    tsEntries.push([this.id, method, plain(params), sessionId ?? null]);
    // (answered after a turn, as the program's are)
    await Promise.resolve();
    return this.#world()("cdp.send", this.id, [method, plain(params), sessionId ?? null]) ?? {};
  }
  on(listener: (e: CdpEvent) => void) {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
  emit(method: string, params: Json, sessionId?: string) {
    for (const l of [...this.#listeners]) l({ method, params, sessionId });
  }
  close() {
    if (this.gone) return;
    this.gone = true;
    tsEntries.push([this.id, "closed"]);
    this.#end();
  }
  end() {
    if (this.gone) return;
    this.gone = true;
    this.#end();
  }
}

/// Both sides' connections by their ids (the program's are its own; the TypeScript's here).
const tsCdps = new Map<string, WorldCdp>();
let tsCdpSeq = 0;
function tsCdp(world: () => World, id?: string): WorldCdp {
  const c = new WorldCdp(id ?? `cdp${++tsCdpSeq}`, world);
  tsCdps.set(c.id, c);
  return c;
}

/// An event given both sides' connection `id`.
async function emitBoth(p: Program, id: string, method: string, params: Json, sessionId?: string) {
  tsCdps.get(id)?.emit(method, params, sessionId);
  await p.emit(id, method, params, sessionId);
}

/// Both sides brought to rest, the clock moved on `ms` first where it is said.
async function settleBoth(p: Program, ms = 0) {
  // (the clock moved on to each of the program's timers in turn, both sides brought to rest there: what a timer arms as
  // it comes due is armed then, as the TypeScript's are)
  const end = clockFibers.now() + ms;
  for (;;) {
    await turns(10);
    await p.quiet();
    await turns(10);
    await p.quiet();
    const now = clockFibers.now();
    if (now >= end) return;
    const next = Math.min(end, ...[...p.due.values()].filter((d) => d > now));
    await t.adjust(next - now);
  }
}

/// What both sides did since the last look, compared, and let go.
function sameSince(p: Program, what: string) {
  sameEntries(tsEntries, p.entries, what, tsConns, p.conns);
  tsEntries = [];
  p.entries = [];
}

/// The browsers a case made on both sides, the TypeScript's and the program's instance of it: those a case that failed
/// left open are closed as the next begins, so that what their timers do is not told among its entries (a case that
/// failed at one assertion went on to fail the one after it, 134186072690, 2026-11-17). Closing one closed is nothing.
const made: { ts: { close(): Promise<void> }; inst: string }[] = [];
function held<T extends { close(): Promise<void> }>(ts: T, inst: string): T {
  made.push({ ts, inst });
  return ts;
}

/// A fresh start for a case: no entries, the connections' ids counted from 1 on both sides.
async function begin(p: Program) {
  for (const m of made.splice(0)) {
    await m.ts.close().catch(() => {});
    await p.call(m.inst, "close").catch(() => {});
  }
  await p.quiet();
  tsEntries = [];
  p.entries = [];
  tsConns.length = 0;
  p.conns = [];
}

/// The TypeScript side's connections made by its Chrome host, in order.
const tsConns: string[] = [];

// ── the functions of no state ──

/// Each input given both, its answer the same.
async function sameFn(p: Program, name: string, f: (...args: Json[]) => unknown, cases: Json[][]) {
  for (const args of cases) {
    const ts = await outcome(() => f(...args));
    const got = await mbOutcome(() => p.fn(name, ...args));
    assert.deepEqual(got, ts, `${name}(${JSON.stringify(args)})`);
  }
}

const URLS = [
  "", "  ", "mail.proton.me", "localhost:3000/app", "localhost:abc", "127.0.0.1:8080/x", "[::1]:3000", "[::1]", "alice@proton.me",
  "https://example.com", "HTTPS://Example.COM/a/../b?x=1#y", "http://a.b.c:80/", "https://a.com:443/x", "javascript:alert(1)",
  "mailto:x@y.z", "file:///etc/passwd", "about:blank", "chrome://settings", "see https://github.com/foo/bar, and more.",
  "text (https://a.test/x) end", "<https://a.test/q?x=1>.", "https://user:pw@host.com/", "ftp://x.y/", "a..b.com", ".a.com",
  "a.com.", "x", "x.y", "x.yz", "1.2.3.4", "256.1.1.1", "例え.jp", "https://例え.jp/パス", "foo.localhost", "a b.com",
  "http://", "https://", "http://a", "sub.domain.co.uk/path?q=1#h", "\u0007bad.com", "http://0x7f.1/", "https://h/é",
  "words only here", "https://a.com/x!", "https://a.com/x?y=1;", "go to http://a.com", "hTtP://Mixed.Case/", "x".repeat(9000),
  `https://${"a".repeat(8200)}.com`, "http://[::1]:99/", "localhost", "LOCALHOST:80", "[fe80::1", "a:1:2",
];

const COOKIES_READ = [
  { name: "a", value: "1", domain: ".github.com", path: "/", expires: 1900000000, size: 2, httpOnly: true, secure: true, session: false, sameSite: "Lax", priority: "Medium", sourceScheme: "Secure", sourcePort: 443 },
  { name: "b", value: "2", domain: "api.github.com", expires: -1, session: true, partitionKey: { topLevelSite: "https://x.test", hasCrossSiteAncestor: false } },
  { name: "c", value: "3", domain: "notgithub.com", path: "/x" },
  { name: "d", value: "4", domain: "GitHub.com", expires: 0 },
  { name: 5, value: "x", domain: "github.com" },
  null,
  [1, 2],
  { name: "e", value: "5", domain: "x.github.com", partitionKey: null, expires: 12.5, session: false },
];

const PASSKEYS = [
  { credentialId: "Y3JlZA", rpId: "github.com", privateKey: "a2V5", userHandle: "dXNlcg", signCount: 3, isResidentCredential: true },
  { credentialId: "b3RoZXI", rpId: "login.example.com", privateKey: "a2V5Mg", userHandle: "", signCount: -1 },
  { credentialId: "eA", rpId: "a.test", privateKey: "eQ", signCount: 1.5 },
  { credentialId: 1, rpId: "x", privateKey: "y" },
  null,
];

/// The start of a JPEG of `width` × `height`: SOI, an APP0, a SOF0; an EXIF note turned a quarter where `turned`.
function jpeg(width: number, height: number, turned = false): Uint8Array {
  const app0 = [0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00];
  const tiff = [0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08, 0x00, 0x01, 0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
  const note = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];
  const app1 = turned ? [0xff, 0xe1, (note.length + 2) >> 8, (note.length + 2) & 0xff, ...note] : [];
  const sof = [0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1];
  return Uint8Array.from([0xff, 0xd8, ...app0, ...app1, ...sof, 0, 0xff, 0xd9]);
}
const b64 = (data: Uint8Array) => Buffer.from(data).toString("base64");

test("addresses: links in prose, bare hosts, searches, sites, what a sleeping tab keeps", { skip }, async () => {
  const p = await mb();
  const one = URLS.map((u) => [u]);
  await sameFn(p, "extractFirstHttpUrl", extractFirstHttpUrl, one);
  await sameFn(p, "normalizeBrowserUrl", normalizeBrowserUrl, one);
  await sameFn(p, "addressOrSearch", addressOrSearch, one);
  await sameFn(p, "siteOfBrowserUrl", siteOfBrowserUrl, one);
  await sameFn(p, "persistableBrowserUrl", persistableBrowserUrl, one);
  await sameFn(p, "BLANK_PAGE", () => BLANK_PAGE, [[]]);
  await sameFn(p, "addressOrSearch", addressOrSearch, [["what is 1+1 & 2?"], ["中文 搜索"], ["a/b c"], ["emoji 😀 here"]]);
});

test("a session's address on the door: its key, and only a key's", { skip }, async () => {
  const p = await mb();
  const sessions = ["chat:c-1", "slack:T1/C2/1700000000.1", "a", "中文", "x?y/z", "😀"];
  await sameFn(p, "sessionPath", sessionPath, sessions.map((s) => [s]));
  const paths = [...sessions.map((s) => sessionPath(s)), ...sessions.map((s) => `${sessionPath(s)}/?x=1`), "/browser/", "/browser/!!", "/browser/YQ/x",
    "/browser/YQ?\nx", "/other/YQ", "/browser/A", "/browser/YQ=", "/browser/YR", "/browser/YQ?ok", "/browser/YQ/"];
  await sameFn(p, "sessionOfPath", sessionOfPath, paths.map((s) => [s]));
});

test("sign-ins: a site's cookies set again as DevTools takes them, taken out expired; passkeys; what the vault keeps", { skip }, async () => {
  const p = await mb();
  await sameFn(p, "ofSites", ofSites, [[".github.com", ["github.com"]], ["API.GitHub.com", ["github.com"]], ["notgithub.com", ["github.com"]], ["a.b", ["x", "a.b"]], ["github.com", ["GitHub.com"]], ["", [""]]]);
  await sameFn(p, "allCookies", allCookies, [[COOKIES_READ], [null], ["x"], [[]]]);
  await sameFn(p, "siteCookies", siteCookies, [[COOKIES_READ, ["github.com"]], [COOKIES_READ, []], [COOKIES_READ, ["x.github.com", "notgithub.com"]]]);
  const kept = [JSON.stringify(siteCookies(COOKIES_READ, ["github.com"])), JSON.stringify({ cookies: siteCookies(COOKIES_READ, ["github.com"]), passkeys: PASSKEYS }), "not json", "null", "{}", '{"cookies":5,"passkeys":[{}]}', "[1,2]"];
  await sameFn(p, "stateOf", stateOf, kept.map((k) => [k]));
  await sameFn(p, "keptOf", (s: Json) => keptOf({ cookies: s.cookies, passkeys: s.passkeys.map(passkeyOf).filter(Boolean) }), [[{ cookies: COOKIES_READ.slice(0, 2), passkeys: [] }], [{ cookies: [], passkeys: PASSKEYS }]]);
  await sameFn(p, "expired", expired, [[siteCookies(COOKIES_READ, ["github.com"])], [[{ name: "x", value: "y", domain: "d", path: "/", expires: 5 }]]]);
  await sameFn(p, "passkeyOf", passkeyOf, PASSKEYS.map((k) => [k]));
  await sameFn(p, "sitePasskeys", (all: Json, sites: Json) => sitePasskeys(all.map(passkeyOf).filter(Boolean), sites), [[PASSKEYS, ["github.com"]], [PASSKEYS, ["example.com", "a.test"]]]);
});

test("Chrome's command line, its DevToolsActivePort, its headful agent; how a tab is opened behind", { skip }, async () => {
  const p = await mb();
  await sameFn(p, "parseActivePort", parseActivePort, ["53412\n/devtools/browser/0b1c-77\n", "9222\r\n/devtools/browser/x", "", "53412", "0\n/devtools/browser/x", "70000\n/devtools/browser/x", "12a\n/devtools/browser/x", "9222\n/json", "0009222\n /devtools/browser/y \n", "9222\r\r\n/devtools/browser/z"].map((x) => [x]));
  await sameFn(p, "chromeArgs", chromeArgs, [[{ profile: "/d/browser/profile", port: 0, headless: false }], [{ profile: "/p", port: 9333, headless: true, userAgent: "UA" }], [{ profile: "/p q", port: 1, headless: true, userAgent: "" }]]);
  await sameFn(p, "headfulAgent", headfulAgent, [["Mozilla/5.0 (Macintosh) HeadlessChrome/155.0.0.0 Safari/537.36"], ["HeadlessChrome/1 HeadlessChrome/2"], ["Chrome/1"]]);
  await sameFn(p, "BEHIND", () => BEHIND, [[]]);
});

test("a view's helpers: the viewport, a JPEG's size, a point of the frame, keys and their commands, a page's passkey asks", { skip }, async () => {
  const p = await mb();
  await sameFn(p, "viewportOf", viewportOf, [[{ cssVisualViewport: { clientWidth: 1200.4, clientHeight: 799.5 } }], [{ cssLayoutViewport: { clientWidth: 10, clientHeight: 0 } }], [{ layoutViewport: { clientWidth: "30", clientHeight: 20 } }], [null], [{ cssVisualViewport: null, cssLayoutViewport: { clientWidth: 3, clientHeight: 4 } }]]);
  await sameFn(p, "jpegSize", (d: string) => jpegSize(Buffer.from(d, "base64")), [[b64(jpeg(1280, 720))], [b64(jpeg(3, 65535))], [b64(jpeg(640, 480, true))], [b64(Uint8Array.from([0x89, 0x50, 0x4e, 0x47]))], [b64(Uint8Array.from([0xff, 0xd8, 0xff, 0xd9]))], [b64(Uint8Array.from([0xff, 0xd8, 0xff, 0xff, 0xff, 0xc0, 0, 17, 8, 0, 2, 0, 3]))]]);
  await sameFn(p, "toViewport", toViewport, [[0.5, 0.25, { width: 1200, height: 800 }], [0, 1, { width: 1200, height: 800 }], [-0.2, 1.5, { width: 1200, height: 800 }], [Number.NaN, 0.5, { width: 10, height: 10 }], [0.333, 0.777, { width: 390, height: 844 }]]);
  const keys: [string, string][] = [["Enter", "Enter"], ["a", "KeyA"], ["@", "Digit2"], ["F5", "F5"], ["F24", "F24"], ["F25", "F25"], ["F0", "F0"], [";", "Semicolon"], ["7", "Numpad7"], ["Z", ""], ["9", ""], ["é", "KeyE"], ["", ""], [" ", "Space"], ["ArrowUp", "ArrowUp"], ["x", "Digit"], ["q", "KeyAB"]];
  await sameFn(p, "keyCode", keyCode, keys.map(([k, c]) => [k, c]));
  const events: Json[] = [];
  for (const [key, code] of keys) for (const mods of [0, 1, 2, 4, 8, 12, 6, 15, 16, 7.9]) for (const kind of ["down", "up"]) events.push({ t: "key", kind, key, code, mods });
  for (const key of ["a", "c", "x", "v", "z", "Z", "y", "😀", "ab"]) events.push({ t: "key", kind: "down", key, code: "", mods: 4 }, { t: "key", kind: "down", key, code: "", mods: 12 }, { t: "key", kind: "down", key, code: "", mods: 0 });
  await sameFn(p, "keyEvent", keyEvent, events.map((e) => [e]));
  const ours = JSON.stringify({ type: "webauthn.get", challenge: "abc", origin: "https://a.test", crossOrigin: false });
  await sameFn(p, "sameClientData", sameClientData, [[ours, ours], [JSON.stringify({ type: "webauthn.get", challenge: "abc", origin: "https://a.test", other: 1 }), ours], [JSON.stringify({ type: "webauthn.get", challenge: "abd", origin: "https://a.test" }), ours], [JSON.stringify({ type: "webauthn.get", challenge: "abc", origin: "https://a.test", crossOrigin: true }), ours], ["nope", ours], ["5", ours], ["null", ours]]);
  await sameFn(p, "rpFor", rpFor, [["github.com", "github.com"], ["GitHub.com.", "github.com"], ["github.com", "api.github.com"], ["com", "api.com"], ["", "x"], ["hub.com", "github.com"]]);
  await sameFn(p, "hostOf", hostOf, [["https://API.GitHub.com./x"], ["about:blank"], [""], ["not a url"], ["http://[::1]:3000/"], ["https://例え.jp/"]]);
});

test("the pages' scripts are the TypeScript's, character for character", { skip }, async () => {
  const p = await mb();
  await sameFn(p, "COPY_HOOK", () => COPY_HOOK, [[]]);
  await sameFn(p, "LOGIN_HOOK", () => LOGIN_HOOK, [[]]);
  await sameFn(p, "fillScript", fillScript, [["alice", "pw"], [undefined, "p\"w\n"], ["名字", undefined], [undefined, undefined]]);
  await sameFn(p, "passkeyHook", passkeyHook, [["0b1c2d3e-0000-4000-8000-000000000000"], ["a\"b"]]);
  await sameFn(p, "FINDER", () => FINDER, [[]]);
  await sameFn(p, "LOOK_SCRIPT", () => LOOK_SCRIPT, [[]]);
  await sameFn(p, "pickScript", pickScript, [["username"], ["password"], ["code"]]);
  await sameFn(p, "BUTTON_SCRIPT", () => BUTTON_SCRIPT, [[]]);
  await sameFn(p, "MOVE_MS", () => MOVE_MS, [[]]);
});

test("Farview: its wire, its release, its config and its words", { skip }, async () => {
  const p = await mb();
  const asks: Json[] = [{ kind: "look" }, { kind: "eval", script: "1+1" }, { kind: "cookies", verb: "set", arg: JSON.stringify([{ name: "é", value: "x".repeat(300) }]) }, { kind: "act", verb: "type", selector: "[a]", text: "pässwörd" }, { kind: "eval", script: "x".repeat(70000) }, { kind: "passkeys", verb: "set", arg: JSON.stringify(PASSKEYS) }, { kind: "passkeys", verb: "clear", arg: "github.com" }];
  await sameFn(p, "encodeAsk", (a: Json) => encodeAsk(a).toString("base64"), asks.map((a) => [a]));
  const body = (kind: number, ...strs: string[]) => {
    const out: number[] = [];
    const varint = (v: number) => { let u = ((v << 1) ^ (v >> 31)) >>> 0; while (u >= 0x80) { out.push((u & 0x7f) | 0x80); u >>>= 7; } out.push(u); };
    varint(kind);
    for (const s of strs) { const b = Buffer.from(s, "utf8"); varint(b.length); out.push(...b); }
    return Buffer.from(out).toString("base64");
  };
  await sameFn(p, "decodeAnswer", (d: string) => decodeAnswer(Buffer.from(d, "base64")), [[body(33, "{\"a\":1}")], [body(20, "https://a.test/", "A — b", "outline\nmore")], [body(21)], [body(7, "x")], [body(33, "x".repeat(200))]]);
  const release = { rev: "f232322775f819e81555884d2f11a8b1ae40092c", sha256: "ab".repeat(32) };
  await sameFn(p, "FARVIEW_RELEASES", () => FARVIEW_RELEASES, [[]]);
  await sameFn(p, "farviewAsset", farviewAsset, [["darwin-arm64", release], ["linux-x64", { rev: "abc", sha256: "" }]]);
  await sameFn(p, "farviewCacheDir", (cache: string, target: string, r: Json) => farviewCacheDir(target, r, { STILLFAIL_NATIVE_CACHE: cache }), [["/cache", "darwin-arm64", release], ["/c/../d/", "x", release]]);
  await sameFn(p, "farviewSources", farviewSources, [["n.tar.gz", {}], ["n.tar.gz", { STILLFAIL_FARVIEW_SOURCES: " https://a.test/x , gh:o/r@t ,," }], ["n", { STILLFAIL_NATIVE_STORE: "https://s", STILLFAIL_NATIVE_REPO: "o/r", STILLFAIL_NATIVE_RELEASE: "" }]]);
  await sameFn(p, "ghSource", ghSource, ["gh:AFK-surf/farview@builds/n.tar.gz", "gh:a/b@t@x/n", "gh:a/b/c@t/n", "gh:a@t/n", "gh:a/b@t/n/m", "gh:a/b@/n", "https://x", "gh:a b/c@t/n"].map((x) => [x]));
  const bytes = [Buffer.from(""), Buffer.from("abc"), Buffer.alloc(1000, 7), Buffer.from("中文")];
  await sameFn(p, "sha256", (d: string) => createHash("sha256").update(Buffer.from(d, "base64")).digest("hex"), bytes.map((b) => [b.toString("base64")]));
  const releases = { "darwin-arm64": { rev: "0123456789abcdef", sha256: "ab".repeat(32) } };
  const configs: Json[] = [{}, { browser: { engine: "farview" } }, { browser: { farview: false } }, { browser: { engine: "farview", sessions: ["chat:a", 3, ""] } }, { browser: { farview: "/opt/fv", engine: "farview" } }, { browser: { farview: "/opt/x/../fv/" } }, { browser: null }, { browser: [] }, null];
  for (const target of ["darwin-arm64", "linux-riscv64"]) {
    await sameFn(p, "farviewConfig", (raw: Json, tg: string, rs: Json, cache: string) => farviewConfig(raw, tg, rs, { STILLFAIL_NATIVE_CACHE: cache }), configs.map((c) => [c, target, releases, "/cache"]));
  }
  const some = farviewConfig({ browser: { farview: "/opt/fv", sessions: ["chat:a"] } });
  const every = farviewConfig({ browser: { farview: "/opt/fv", engine: "farview" } });
  await sameFn(p, "farviewFor", farviewFor, [[some, "chat:a", undefined], [some, "chat:b", undefined], [some, "chat:b", "farview"], [some, "chat:a", "chrome"], [every, "chat:x", undefined], [every, "chat:x", "chrome"], [null, "chat:a", "farview"]]);
  await sameFn(p, "hostFileOf", hostFileOf, [[{ pid: 12, port: 4000, agent: 4001, frame: 4002 }], [{ pid: 12, port: 4000, agent: 4001, frame: 4002, closed: true }], [{ pid: 12, port: 4000, agent: 4001, frame: 4002, closed: "yes" }], [{ pid: 12, port: 4000, agent: 4001 }], [{ pid: 0, port: 1, agent: 1, frame: 1 }], [{ pid: 12, port: 70000, agent: 4001, frame: 4002 }], ["x"], [{ pid: 1.5, port: 1, agent: 1, frame: 1 }], [null]]);
  await sameFn(p, "chatDir", chatDir, [["chat:c-1/2"], ["slack:T/C/1.2"], ["中文"], [""]]);
  await sameFn(p, "FIRST_PAGE", () => FIRST_PAGE, [[]]);
  const tabs = [{ id: "fv_abc", title: "A \"tab\"", url: "https://a.test/", attached: false, session: "chat:a", agent: 4001 }, { id: "fv_abc_1", title: "", url: "", attached: false, session: "chat:a", agent: 4002 }];
  await sameFn(p, "farviewHowTo", farviewHowTo, [[every, tabs], [every, []]]);
  await sameFn(p, "inputOf", inputOf, [[{ t: "pointer", kind: "down", x: 0.5, y: 0.25, buttons: 1 }, { width: 1280, height: 800, scale: 2 }], [{ t: "wheel", x: 0.1, y: 0.2, dx: 3, dy: -4 }, { width: 390, height: 844, scale: 3 }], [{ t: "key", kind: "up", key: "a", code: "KeyA", mods: 2 }, DEFAULT_SIZE], [{ t: "text", text: "hi" }, DEFAULT_SIZE], [{ t: "pose", name: "open" }, DEFAULT_SIZE], [{ t: "pointer", kind: "move", x: 1 / 3, y: 2 / 3, buttons: 0 }, { width: 1000, height: 700, scale: 1.5 }]]);
  await sameFn(p, "sizeFor", sizeFor, [[{ codecs: ["jpeg"], maxWidth: 2560, maxHeight: 1600 }], [{ codecs: ["jpeg"], maxWidth: 640, maxHeight: 900 }], [{ codecs: ["jpeg"], maxWidth: 0, maxHeight: 900 }], [{ codecs: ["jpeg"], maxWidth: 1, maxHeight: 1, fit: { width: 390.4, height: 844.6, scale: 3 } }], [{ codecs: ["jpeg"], maxWidth: 640, maxHeight: 400, fit: { width: 0, height: 1, scale: 2 } }], [{ codecs: ["jpeg"], maxWidth: 640, maxHeight: 400, fit: { width: 300, height: 600, scale: 0 } }]]);
  await sameFn(p, "DEFAULT_SIZE", () => DEFAULT_SIZE, [[]]);
});

test("the tool's declaration, a session's address of it and what it says of a browser that runs", { skip }, async () => {
  const p = await mb();
  await sameFn(p, "BROWSER", () => BROWSER, [[]]);
  await sameFn(p, "sessionWs", sessionWs, [[null, "chat:a"], ["http://127.0.0.1:4777/mcp", "chat:a"], ["http://127.0.0.1:4777", "x"], ["https://h/mcp/", "x"]]);
  const running = { running: true, http: "http://127.0.0.1:9222", ws: "ws://127.0.0.1:9222/devtools/browser/x", binary: "/Applications/Chrome", headless: true };
  await sameFn(p, "howTo", howTo, [[running, "ws://127.0.0.1:4777/browser/YQ"], [running, null], [{ ...running, binary: "", headless: false }, null], [{ running: true }, null]]);
});

// ── the gate, and the door's pass through it ──

/// Messages an agent and Chrome say through a gate, in turn: what each side's gate lets through each way.
const GATE_SCRIPT: ["client" | "chrome" | "wants", Json][] = [
  ["client", { id: 1, method: "Target.createTarget", params: { url: "https://a/" } }],
  ["chrome", { id: 1, result: { targetId: "N" } }],
  ["client", { id: 2, method: "Target.createTarget", params: { url: "https://a/", browserContextId: "C2" } }],
  ["client", { id: 3, method: "Storage.getCookies", params: {} }],
  ["client", { id: 4, method: "Browser.grantPermissions", params: { permissions: ["geolocation"], browserContextId: "C1" } }],
  ["client", { id: 5, method: "Storage.getCookies", params: { browserContextId: "C2" } }],
  ["client", { id: 6, method: "Target.attachToTarget", params: { targetId: "X", flatten: true } }],
  ["client", { id: 7, method: "Target.attachToTarget", params: { targetId: "A", flatten: true } }],
  ["chrome", { id: 7, result: { sessionId: "SA1" } }],
  ["client", { id: 8, method: "Browser.close", params: {} }],
  ["client", { id: 8.5, method: "Tracing.start" }],
  ["client", { id: 9, method: "Target.disposeBrowserContext", params: { browserContextId: "C1" } }],
  ["client", { id: 10, method: "Target.getBrowserContexts" }],
  ["client", { id: 11, sessionId: "S9", method: "Runtime.evaluate", params: { expression: "1" } }],
  ["client", { id: "s", method: "Target.getTargetInfo" }],
  ["client", { method: "Target.activateTarget", params: { targetId: "A" } }],
  ["client", "not json"],
  ["client", [1, 2]],
  ["client", 7],
  ["client", { id: 12 }],
  ["client", { id: 13, method: "Target.createBrowserContext", params: { disposeOnDetach: true } }],
  ["chrome", { id: 13, result: { browserContextId: "C9" } }],
  ["client", { id: 14, method: "Target.createTarget", params: { browserContextId: "C9", url: "about:blank", newWindow: false } }],
  ["client", { id: 15, method: "Target.getBrowserContexts" }],
  ["client", { id: 16, method: "Target.disposeBrowserContext", params: { browserContextId: "C9" } }],
  ["client", { id: 17, method: "Target.detachFromTarget", params: { sessionId: "SA1" } }],
  ["client", { id: 18, method: "Target.detachFromTarget", params: { sessionId: "nope" } }],
  ["chrome", { method: "Target.targetCreated", params: { targetInfo: { targetId: "A", browserContextId: "C1", type: "page" } } }],
  ["chrome", { method: "Target.targetCreated", params: { targetInfo: { targetId: "X", browserContextId: "C2", type: "page" } } }],
  ["chrome", { method: "Target.targetDestroyed", params: { targetId: "X" } }],
  ["chrome", { method: "Target.attachedToTarget", params: { sessionId: "SX", targetInfo: { targetId: "X", browserContextId: "C2" }, waitingForDebugger: true } }],
  ["wants", '{"id":2000000000,"result":{}}'],
  ["chrome", { id: 2000000000, result: {} }],
  ["chrome", { method: "Runtime.executionContextCreated", params: {}, sessionId: "SX" }],
  ["chrome", { id: 99, sessionId: "SX", result: {} }],
  ["chrome", { method: "Target.detachedFromTarget", params: { sessionId: "SX" } }],
  ["chrome", { method: "Target.attachedToTarget", params: { sessionId: "SA", targetInfo: { targetId: "A2", browserContextId: "C1" } } }],
  ["client", { id: 20, sessionId: "SA", method: "Runtime.evaluate", params: { expression: "1" } }],
  ["client", { id: 21, sessionId: "SA", method: "Page.bringToFront", params: {} }],
  ["client", { id: 22, sessionId: "SA", method: "Page.navigate", params: { url: "https://b.test/" } }],
  ["chrome", { id: 22, sessionId: "SA", result: { frameId: "F" } }],
  ["client", { id: 23, sessionId: "SA", method: "Input.dispatchMouseEvent", params: { type: "mousePressed", x: 1, y: 2 } }],
  ["chrome", { id: 23, sessionId: "SA", error: { code: 1, message: "no" } }],
  ["client", { id: 24, sessionId: "SA", method: "Input.dispatchKeyEvent", params: { type: "keyDown", key: "a" } }],
  ["chrome", { id: 24, sessionId: "SA", result: {} }],
  ["client", { id: 25, sessionId: "SA", method: "Target.setAutoAttach", params: { autoAttach: true } }],
  ["client", { id: 26, method: "Target.getTargets", params: {} }],
  ["chrome", { id: 26, result: { targetInfos: [{ targetId: "A", browserContextId: "C1" }, { targetId: "X", browserContextId: "C2" }, { targetId: "K" }, null] } }],
  ["client", { id: 27, sessionId: "SA", method: "Target.getTargets", params: {} }],
  ["chrome", { id: 27, sessionId: "SA", result: { targetInfos: [{ targetId: "X", browserContextId: "C2" }] } }],
  ["client", { id: 28, sessionId: "SA", method: "Storage.getCookies", params: {} }],
  ["client", { id: 29, method: "Target.closeTarget", params: { targetId: "N" } }],
  ["chrome", { method: "Target.targetCrashed", params: { targetId: "N" } }],
  ["chrome", { method: "Target.targetDestroyed", params: { targetId: "N" } }],
  ["chrome", { method: "Target.targetDestroyed", params: { targetId: "N" } }],
  ["chrome", { method: "Target.detachedFromTarget", params: { sessionId: "SA" } }],
  ["client", { id: 30, sessionId: "SA", method: "Runtime.evaluate", params: {} }],
  ["chrome", { method: "Page.loadEventFired", params: {} }],
  ["chrome", "{broken"],
  ["wants", '{"method":"Target.targetCreated"}'],
  ["wants", '{"id":5}'],
  ["wants", "x".repeat((1 << 20) + 1)],
  ["chrome", { method: "Target.targetInfoChanged", params: { targetInfo: { targetId: "K", browserContextId: "C1" } } }],
  ["chrome", { method: "Target.receivedMessageFromTarget", params: { sessionId: "SZ" } }],
];

test("the gate: the chat's context its tabs', cookies' and permissions'; another chat's targets never told; what Chrome attached on its own let go of", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const contexts: Record<string, string> = { X: "C2", A: "C1" };
  const ts = new Gate({ context: "C1", contextOf: (id) => contexts[id], opened: (id) => tsEntries.push(["opened", id]), used: (id, url) => tsEntries.push(["used", id, url ?? null]) });
  await p.make("gate", "g1", { context: "C1", contexts });
  for (const [side, m] of GATE_SCRIPT) {
    const text = typeof m === "string" ? m : JSON.stringify(m);
    const method = side === "client" ? "fromClient" : side === "chrome" ? "fromChrome" : "wants";
    const tsGot = side === "client" ? ts.fromClient(text) : side === "chrome" ? ts.fromChrome(text) : ts.wants(text);
    const mbGot = await p.call("g1", method, text);
    assert.deepEqual(mbGot, plain(tsGot), `${method} ${text.slice(0, 200)}`);
  }
  await p.quiet();
  sameSince(p, "the gate");
});

/// A WebSocket end as the door's pass takes one: what it is sent, written down.
class FakeWs extends EventEmitter {
  readyState = 1;
  readonly side: string;
  constructor(side: string) {
    super();
    this.side = side;
  }
  send(data: unknown, opts?: { binary?: boolean }) {
    if (opts === undefined) tsEntries.push(["ws", this.side, String(data)]);
    else tsEntries.push(["raw", this.side, Buffer.from(data as Buffer).toString("base64"), opts.binary === true]);
  }
  close() {
    this.readyState = 3;
    tsEntries.push(["close", this.side]);
  }
  terminate() {
    this.readyState = 3;
    tsEntries.push(["terminate", this.side]);
  }
}

test("the door's pass: both ways through the chat's gate, binary from the agent dropped, a big frame of Chrome's passed unread, either end closing both", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const contexts = { A: "C1", X: "C2" };
  const client = new FakeWs("client");
  const upstream = new FakeWs("upstream");
  pass(client as never, upstream as never, new Gate({ context: "C1", contextOf: (id) => (contexts as Json)[id] }));
  await p.make("pass", "p1", { context: "C1", contexts });
  const steps: [string, string, boolean][] = [
    ["client", JSON.stringify({ id: 1, method: "Target.createTarget", params: {} }), false],
    ["client", "binary bytes", true],
    ["chrome", JSON.stringify({ id: 1, result: { targetId: "T" } }), false],
    ["chrome", JSON.stringify({ method: "Target.targetCreated", params: { targetInfo: { targetId: "X", browserContextId: "C2" } } }), false],
    ["chrome", JSON.stringify({ method: "Page.screencastFrame", params: { data: "x".repeat(100) } }), false],
    ["chrome", "raw bytes of chrome's", true],
    ["client", JSON.stringify({ id: 2, method: "Browser.close" }), false],
  ];
  for (const [side, text, binary] of steps) {
    if (side === "client") client.emit("message", Buffer.from(text), binary);
    else upstream.emit("message", Buffer.from(text), binary);
    await p.call("p1", side === "client" ? "fromClient" : "fromChrome", text, binary);
  }
  upstream.emit("close");
  await p.call("p1", "end");
  await p.quiet();
  sameSince(p, "the pass");
});

// ── whose each tab is, and state.json ──

test("whose each tab is: learnt before the file is read and after, a tab gone before it is read not taken from it, those no longer there forgotten; the same file", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const tsDir = fresh("owners-ts");
  const mbDir = fresh("owners-mb");
  const before = JSON.stringify({ T1: "chat:a", T2: "chat:b", "10": "chat:n", "2": "chat:m", T3: "", T4: 5 }, null, 2);
  for (const d of [tsDir, mbDir]) writeFileSync(join(d, "owners.json"), before);
  // (the program's read held until what comes before it came: the TypeScript's is read off the thread, after what is
  // asked at once as it is made)
  let release!: () => void;
  const released = new Promise<void>((r) => (release = r));
  p.world = async (call, _inst, args) => {
    if (call !== "files.read") return null;
    await released;
    return existsSync(args[0]) ? readFileSync(args[0], "utf8") : null;
  };
  await p.make("owners", "o1", { dir: mbDir, held: true });
  const ts = new Owners(tsDir);
  const before1 = ts.set("T9", "chat:z");
  ts.drop("T2");
  assert.equal(await p.call("o1", "set", "T9", "chat:z"), before1, "set before");
  await p.call("o1", "drop", "T2");
  const both = async (what: string, f: () => unknown, method: string, ...args: Json[]) => {
    const a = await outcome(f);
    const b = await mbOutcome(() => p.call("o1", method, ...args));
    assert.deepEqual(b, a, what);
  };
  release();
  await both("ready", () => ts.ready(), "ready");
  for (const id of ["T1", "T2", "T9", "10", "2", "T3", "T4", "none"]) await both(`of ${id}`, () => ts.of(id), "of", id);
  await both("written", () => ts.written(), "written");
  sameFiles(tsDir, mbDir, "after it was read");
  await both("set again", () => ts.set("T1", "chat:a"), "set", "T1", "chat:a");
  await both("set new", () => ts.set("T5", "chat:c"), "set", "T5", "chat:c");
  await both("drop", () => ts.drop("T9"), "drop", "T9");
  await both("drop none", () => ts.drop("T77"), "drop", "T77");
  await both("keep", () => ts.keep(new Set(["T1", "2", "T5"])), "keep", ["T1", "2", "T5"]);
  await both("written", () => ts.written(), "written");
  await p.quiet();
  sameFiles(tsDir, mbDir, "after it was changed");
  // an unreadable file: nothing taken from it
  for (const d of [tsDir, mbDir]) writeFileSync(join(d, "owners.json"), "[1, 2]");
  const ts2 = new Owners(tsDir);
  await p.make("owners", "o2", { dir: mbDir });
  await ts2.ready();
  await p.call("o2", "ready");
  assert.deepEqual(await p.call("o2", "of", "T1"), ts2.of("T1") ?? null);
  p.entries = p.entries.filter((e) => e[0] !== "files.read");
  sameSince(p, "the owners");
});

test("state.json: each change read, made and written whole in turn after the one before", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const tsDir = fresh("state-ts");
  const mbDir = fresh("state-mb");
  for (const d of [tsDir, mbDir]) writeFileSync(join(d, "state.json"), JSON.stringify({ port: 9222, lastUse: 5, extra: [1] }));
  const ts = new BrowserState(tsDir);
  await p.make("state", "s1", { dir: mbDir });
  const patches = [{ lastUse: 10 }, { running: { pid: 1, started: 2, port: 9222, ws: "ws://x", binary: "b", headless: true, userAgent: "u" } }, { port: 9333, headlessAgent: { binary: "b", mtimeMs: 1.5, agent: "A" } }];
  for (const patch of patches) {
    void ts.change((s) => ({ ...s, ...patch }));
    void p.call("s1", "change", patch);
  }
  await ts.written();
  await p.call("s1", "written");
  assert.deepEqual(await p.call("s1", "read"), plain(await ts.read()));
  sameFiles(tsDir, mbDir, "state.json");
  for (const d of [tsDir, mbDir]) writeFileSync(join(d, "state.json"), "nope");
  assert.deepEqual(await p.call("s1", "read"), plain(await ts.read()));
});

// ── passkeys in the chats' tabs ──

const KEY_A = { credentialId: "Y3JlZEE", rpId: "github.com", privateKey: "a2V5QQ", userHandle: "dUE", signCount: 1 };
const KEY_B = { credentialId: "Y3JlZEI", rpId: "login.example.com", privateKey: "a2V5Qg", signCount: 0 };

test("passkeys: each chat's tab given an authenticator with its context's passkeys, one made in a tab put in the others, read, put and taken out", { skip }, async () => {
  const p = await mb();
  await begin(p);
  let credentials: Json[] = [{ ...KEY_A, signCount: 4 }, { ...KEY_B, signCount: 2 }, { nope: 1 }];
  // (each side's own: a tab's page moves once on each)
  const worldOf = (): World => {
    const moved = new Set<string>(["S-T3"]);
    return (call, _inst, args) => {
      if (call !== "cdp.send") return null;
      const [method, params, session] = args;
      switch (method) {
        case "Target.getTargets":
          return { targetInfos: [{ type: "page", targetId: "T1", browserContextId: "C1" }, { type: "page", targetId: "T2", browserContextId: "C2" }, { type: "iframe", targetId: "F", browserContextId: "C1" }, null] };
        case "Target.attachToTarget":
          return { sessionId: `S-${params.targetId}` };
        case "WebAuthn.addVirtualAuthenticator":
          if (session === "S-T4") throw new Error("Only one internal authenticator is allowed");
          return { authenticatorId: `A-${session}` };
        case "WebAuthn.addCredential":
          if (moved.has(session)) {
            moved.delete(session);
            throw new Error("The authenticator has not been enabled");
          }
          return {};
        case "WebAuthn.getCredentials":
          return { credentials };
        default:
          return {};
      }
    };
  };
  const world = worldOf();
  p.world = worldOf();
  const ts = new Authenticators(tsCdp(() => world, "k1"), (ctx) => ctx === "C1" || ctx === "C3", (ctx) => tsEntries.push(["changed", ctx]));
  await p.make("keys", "keys1", { cdp: "k1", chats: ["C1", "C3"] });
  const both = async (what: string, f: () => unknown, method: string, ...args: Json[]) => {
    const a = await outcome(f);
    const b = await mbOutcome(() => p.call("keys1", method, ...args));
    assert.deepEqual(b, a, what);
    await settleBoth(p);
  };
  await both("start", () => ts.start(), "start");
  sameSince(p, "started");
  await emitBoth(p, "k1", "Target.targetCreated", { targetInfo: { type: "page", targetId: "T3", browserContextId: "C1" } });
  await settleBoth(p);
  await emitBoth(p, "k1", "Target.targetCreated", { targetInfo: { type: "page", targetId: "T4", browserContextId: "C3" } });
  await settleBoth(p);
  await emitBoth(p, "k1", "Target.targetInfoChanged", { targetInfo: { type: "page", targetId: "T5", browserContextId: "C9" } });
  await settleBoth(p);
  sameSince(p, "tabs come");
  await both("put", () => ts.put("C1", [passkeyOf(KEY_A)!, passkeyOf(KEY_B)!]), "put", "C1", [KEY_A, KEY_B]);
  sameSince(p, "put in every tab, one moved given an authenticator again");
  await both("put none", () => ts.put("C1", []), "put", "C1", []);
  // One made in a tab: kept, put into the others; one that signed: its count kept.
  const made = { credentialId: "bmV3", rpId: "a.test", privateKey: "cHJpdg", userHandle: "aA", signCount: 0 };
  await emitBoth(p, "k1", "WebAuthn.credentialAdded", { authenticatorId: "A-S-T1", credential: made }, "S-T1");
  await settleBoth(p);
  await emitBoth(p, "k1", "WebAuthn.credentialAsserted", { authenticatorId: "A-S-T1", credential: { ...made, signCount: 1 } }, "S-T1");
  await emitBoth(p, "k1", "WebAuthn.credentialAdded", { authenticatorId: "wrong", credential: made }, "S-T1");
  await emitBoth(p, "k1", "WebAuthn.credentialAdded", { authenticatorId: "A-S-T9", credential: made }, "S-T9");
  await emitBoth(p, "k1", "WebAuthn.credentialUpdated", { authenticatorId: "A-S-T3", credential: { bad: true } }, "S-T3");
  await settleBoth(p);
  sameSince(p, "a passkey made in a tab");
  // A tab's page navigated: an authenticator in the environment it is in now; a frame's navigation: none.
  await emitBoth(p, "k1", "Page.frameNavigated", { frame: { id: "F1" } }, "S-T3");
  await settleBoth(p);
  await emitBoth(p, "k1", "Page.frameNavigated", { frame: { id: "F2", parentId: "F1" } }, "S-T3");
  await settleBoth(p);
  sameSince(p, "navigated");
  await both("read", () => ts.read("C1"), "read", "C1");
  await both("read sites", () => ts.read("C1", ["github.com"]), "read", "C1", ["github.com"]);
  await both("read other", () => ts.read("C2"), "read", "C2");
  for (const rp of ["github.com", "GitHub.com.", "a.test", "example.com"]) await both(`has ${rp}`, () => ts.has("C1", rp), "has", "C1", rp);
  credentials = [];
  await both("take out", () => ts.takeOut("C1", ["github.com", "a.test"]), "takeOut", "C1", ["github.com", "a.test"]);
  sameSince(p, "read and taken out");
  await emitBoth(p, "k1", "Target.targetDestroyed", { targetId: "T3" });
  await both("put after one went", () => ts.put("C1", [passkeyOf(KEY_A)!]), "put", "C1", [KEY_A]);
  await both("forget", () => ts.forget("C1"), "forget", "C1");
  await both("read forgotten", () => ts.read("C1", ["github.com"]), "read", "C1", ["github.com"]);
  await both("close", () => ts.close(), "close");
  await emitBoth(p, "k1", "Target.targetCreated", { targetInfo: { type: "page", targetId: "T6", browserContextId: "C1" } });
  await settleBoth(p);
  sameSince(p, "after closing");
});

// ── a person's view of a tab ──

/// The world of a tab's view: its page at `url`, frames as the test casts them.
function viewWorld(state: { url: string; viewport?: Json }): World {
  return (call, _inst, args) => {
    if (call !== "cdp.send") return null;
    const [method] = args;
    switch (method) {
      case "Page.getLayoutMetrics":
        return state.viewport ?? { cssVisualViewport: { clientWidth: 1000, clientHeight: 700 } };
      case "Target.getTargetInfo":
        return { targetInfo: { targetId: "T1", url: state.url } };
      case "Page.getFrameTree":
        return { frameTree: { frame: { id: "F1" } } };
      case "Page.createIsolatedWorld":
        return { executionContextId: 7 };
      case "Page.addScriptToEvaluateOnNewDocument":
        return { identifier: "SCRIPT" };
      default:
        return {};
    }
  };
}

/// Both sides' view made on connection `cdp`: the TypeScript's, and the program's as instance `inst`.
async function views(p: Program, world: World, cdp: string, inst: string, ownPasskey?: string[]) {
  const ts = new TabView({
    cdp: tsCdp(() => world, cdp), session: "S1", targetId: "T1", now: () => clockFibers.now(),
    sized: (s) => tsEntries.push(["sized", plain(s)]), used: () => tsEntries.push(["used"]), ended: () => tsEntries.push(["ended"]),
    ...(ownPasskey ? { ownPasskey: (rp: string) => ownPasskey.includes(rp) } : {}),
  });
  await p.make("view", inst, { cdp, session: "S1", targetId: "T1", ...(ownPasskey ? { ownPasskey } : {}) });
  return ts;
}

const frameOf = (f: Json) => (f === null ? null : { ...(f.config ? { config: f.config } : {}), key: f.key, ts: f.ts, data: Buffer.from(f.data).toString("base64") });

test("a view: cast within the viewer's size, frames acknowledged only as the next is asked for, two held at most, a key frame again, its end", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const state = { url: "https://a.test/" };
  const world = viewWorld(state);
  p.world = world;
  const ts = await views(p, world, "v1", "view1");
  const options = { codecs: ["jpeg"], maxWidth: 1280.6, maxHeight: 0.2 };
  await outcome(() => ts.start(options as never));
  await p.call("view1", "start", options);
  await settleBoth(p);
  sameSince(p, "started");
  const cast = async (ack: number, w: number, h: number, meta: Json) => emitBoth(p, "v1", "Page.screencastFrame", { sessionId: ack, data: b64(jpeg(w, h)), metadata: meta }, "S1");
  await cast(1, 640, 480, { deviceWidth: 1000, deviceHeight: 700, timestamp: 1.5 });
  await cast(2, 640, 480, { deviceWidth: 1000, deviceHeight: 700, timestamp: 1.6 });
  await cast(3, 800, 600, { deviceWidth: 1200, deviceHeight: 900 });
  await settleBoth(p);
  const next = async (what: string) => {
    const a = frameOf(await ts.next());
    const b = await p.call("view1", "next");
    assert.deepEqual(b, a, what);
    await settleBoth(p);
  };
  await next("the newest of those cast");
  sameSince(p, "the older let go");
  // a next waiting for a frame: given as it comes
  const waitingTs = ts.next();
  const waitingMb = p.call("view1", "next");
  await settleBoth(p);
  await cast(4, 800, 600, { deviceWidth: 1200, deviceHeight: 900, timestamp: 0 });
  assert.deepEqual(await waitingMb, frameOf(await waitingTs), "a waiting next");
  ts.keyframe();
  await p.call("view1", "keyframe");
  await next("the last again");
  await cast(5, 0, 0, { deviceWidth: 0 });
  await cast(6, 0, 0, {});
  await next("a frame of no size of its own: the last's");
  sameSince(p, "cast");
  assert.deepEqual(await p.call("view1", "viewport"), plain(ts.viewport()));
  assert.deepEqual(await p.call("view1", "video"), plain(ts.video()));
  // its tab gone: a waiting next is none, and every one after
  const lastTs = ts.next();
  const lastMb = p.call("view1", "next");
  await settleBoth(p);
  await emitBoth(p, "v1", "Target.detachedFromTarget", { sessionId: "S1" });
  assert.deepEqual(await lastMb, frameOf(await lastTs));
  await next("after its end");
  ts.close();
  await p.call("view1", "close");
  await settleBoth(p);
  sameSince(p, "its end");
});

test("a view laid out for the viewer's phone, a person's pointer, wheel, keys and words, a paste; closed", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const world = viewWorld({ url: "https://a.test/" });
  p.world = world;
  const ts = await views(p, world, "v2", "view2");
  const options = { codecs: ["jpeg"], maxWidth: 400, maxHeight: 800, fit: { width: 390, height: 844, scale: 3 } };
  await ts.start(options as never);
  await p.call("view2", "start", options);
  await settleBoth(p);
  const inputs: Json[] = [
    { t: "pointer", kind: "move", x: 0.5, y: 0.5, buttons: 0 },
    { t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 },
    { t: "pointer", kind: "up", x: 0.5, y: 0.5, buttons: 0 },
    { t: "pointer", kind: "down", x: 0.501, y: 0.5, buttons: 1 },
    { t: "pointer", kind: "up", x: 0.501, y: 0.5, buttons: 0 },
    { t: "pointer", kind: "down", x: 0.9, y: 0.1, buttons: 2 },
    { t: "pointer", kind: "up", x: 0.9, y: 0.1, buttons: 0 },
    { t: "pointer", kind: "down", x: 0.2, y: 0.2, buttons: 0 },
    { t: "pointer", kind: "up", x: 1.5, y: -1, buttons: 0 },
    { t: "wheel", x: 0.3, y: 0.4, dx: 0, dy: 120 },
    { t: "key", kind: "down", key: "a", code: "KeyA", mods: 0 },
    { t: "key", kind: "down", key: "z", code: "KeyZ", mods: 12 },
    { t: "key", kind: "up", key: "a", code: "KeyA", mods: 0 },
    { t: "text", text: "héllo" },
    { t: "text", text: "" },
    { t: "pose", name: "open" },
  ];
  for (const [i, input] of inputs.entries()) {
    if (i === 5) await t.adjust(600);
    await ts.input(input as never);
    await p.call("view2", "input", input);
    await settleBoth(p);
  }
  await ts.setClipboard({ type: "text", text: "pasted" } as never, true);
  await p.call("view2", "setClipboard", { type: "text", text: "pasted" }, true);
  await ts.setClipboard({ type: "text", text: "not pasted" } as never, false);
  await p.call("view2", "setClipboard", { type: "text", text: "not pasted" }, false);
  await settleBoth(p);
  sameSince(p, "input");
  ts.close();
  await p.call("view2", "close");
  await settleBoth(p);
  await ts.input(inputs[1] as never);
  await p.call("view2", "input", inputs[1]);
  await settleBoth(p);
  sameSince(p, "closed, laid out as it was again");
});

test("a view's clipboard, login fields and passkey sign-ins: each heard through a binding of its own, answered only for the tab's own origin", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const state = { url: "https://a.test/login" };
  const world = viewWorld(state);
  p.world = world;
  const ts = await views(p, world, "v3", "view3", ["vault.test"]);
  await ts.start({ codecs: ["jpeg"], maxWidth: 800, maxHeight: 600 } as never);
  await p.call("view3", "start", { codecs: ["jpeg"], maxWidth: 800, maxHeight: 600 });
  await settleBoth(p);
  sameSince(p, "started");
  // the clipboard
  const stopTs = ts.watchClipboard((c) => tsEntries.push(["clip", plain(c)]));
  const stopMb = await p.call("view3", "watchClipboard");
  await settleBoth(p);
  for (const payload of ["copied", "", 5]) await emitBoth(p, "v3", "Runtime.bindingCalled", { name: "__stillfailCopied", payload }, "S1");
  await emitBoth(p, "v3", "Runtime.bindingCalled", { name: "__stillfailCopied", payload: "other session" }, "S2");
  await settleBoth(p);
  stopTs();
  await p.call(stopMb, "stop");
  await emitBoth(p, "v3", "Runtime.bindingCalled", { name: "__stillfailCopied", payload: "after" }, "S1");
  await settleBoth(p);
  sameSince(p, "the clipboard");
  // the login fields, and a fill only on its host
  const stopLoginTs = ts.watchLogin((l) => tsEntries.push(["login", plain(l)]));
  const stopLoginMb = await p.call("view3", "watchLogin");
  await settleBoth(p);
  for (const payload of ['{"field":"password"}', '{"field":"password","filled":true}', "null", '{"field":"other"}', "bad json", '{"field":"username","filled":false}']) {
    await emitBoth(p, "v3", "Runtime.bindingCalled", { name: "__stillfailLogin", payload }, "S1");
    await settleBoth(p);
  }
  state.url = "about:blank";
  await emitBoth(p, "v3", "Runtime.bindingCalled", { name: "__stillfailLogin", payload: '{"field":"username"}' }, "S1");
  await settleBoth(p);
  state.url = "https://A.test/login";
  for (const f of [{ host: "a.test", username: "alice", password: "pw" }, { host: "b.test", password: "x" }, { host: "A.TEST", username: "u" }]) {
    await ts.fill(f as never);
    await p.call("view3", "fill", f);
    await settleBoth(p);
  }
  stopLoginTs();
  await p.call(stopLoginMb, "stop");
  await settleBoth(p);
  sameSince(p, "the login fields");
  // passkey sign-ins: each side's binding is its viewer's own (a random owner), said to each in its own name
  state.url = "https://a.test/login";
  const heardTs: Json[] = [];
  const stopKeyTs = ts.watchPasskey((a) => heardTs.push(plain(a)));
  const stopKeyMb = await p.call("view3", "watchPasskey");
  await settleBoth(p);
  const nameOf = (entries: Entry[]) => entries.find((e) => e[1] === "Runtime.addBinding" && String(e[2]?.name).startsWith("__stillfailPasskey_"))![2].name as string;
  const tsName = nameOf(tsEntries);
  const mbName = nameOf(p.entries);
  const ownerOf = (name: string) => {
    const hex = name.slice("__stillfailPasskey_".length);
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  };
  const say = async (said: Json, sessionId = "S1") => {
    tsCdps.get("v3")!.emit("Runtime.bindingCalled", { name: tsName, payload: JSON.stringify({ ...said, owner: said.owner ?? ownerOf(tsName) }) }, sessionId);
    await p.emit("v3", "Runtime.bindingCalled", { name: mbName, payload: JSON.stringify({ ...said, owner: said.owner ?? ownerOf(mbName) }) }, sessionId);
    await settleBoth(p);
  };
  await say({ id: "1", rpId: "a.test", challenge: "Y2hhbA", allow: ["YQ", "Yg"], userVerification: "required" });
  await say({ id: "2", rpId: "A.Test.", challenge: "Y2hhbA", allow: [], userVerification: "weird" });
  await say({ id: "3", rpId: "other.test", challenge: "Y2hhbA" });
  await say({ id: "4", rpId: "vault.test", challenge: "Y2hhbA" });
  await say({ id: "5", rpId: "a.test", challenge: "not base64!" });
  await say({ id: "6", rpId: "a.test", challenge: "Y2hhbA", owner: "someone else" });
  await say({ id: "", rpId: "a.test", challenge: "Y2hhbA" });
  await say({ id: "2", gone: true });
  await say({ id: "7", rpId: "a.test", challenge: "Y2hhbA" });
  const answers: Json[] = [
    { id: "nope", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln" },
    { id: "7", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln", userHandle: "dQ" },
  ];
  for (const a of answers) {
    await ts.passkey(a as never);
    await p.call("view3", "passkey", a);
    await settleBoth(p);
  }
  await say({ id: "8", rpId: "a.test", challenge: "Y2hhbA" });
  const theirs = Buffer.from(JSON.stringify({ type: "webauthn.get", challenge: "Y2hhbA", origin: "https://a.test", crossOrigin: false, extra: 1 })).toString("base64url");
  await ts.passkey({ id: "8", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln", clientData: theirs } as never);
  await p.call("view3", "passkey", { id: "8", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln", clientData: theirs });
  await settleBoth(p);
  await say({ id: "9", rpId: "a.test", challenge: "Y2hhbA" });
  const wrong = Buffer.from(JSON.stringify({ type: "webauthn.get", challenge: "other", origin: "https://a.test" })).toString("base64url");
  await ts.passkey({ id: "9", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln", clientData: wrong } as never);
  await p.call("view3", "passkey", { id: "9", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln", clientData: wrong });
  await settleBoth(p);
  await say({ id: "10", rpId: "a.test", challenge: "Y2hhbA" });
  await ts.passkey({ id: "10", error: "NotAllowedError" } as never);
  await p.call("view3", "passkey", { id: "10", error: "NotAllowedError" });
  await settleBoth(p);
  await say({ id: "11", rpId: "a.test", challenge: "Y2hhbA" });
  state.url = "https://elsewhere.test/";
  await ts.passkey({ id: "11", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln" } as never);
  await p.call("view3", "passkey", { id: "11", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln" });
  await settleBoth(p);
  state.url = "http://localhost:3000/";
  await say({ id: "12", rpId: "localhost", challenge: "Y2hhbA" });
  state.url = "http://plain.test/";
  await say({ id: "13", rpId: "plain.test", challenge: "Y2hhbA" });
  stopKeyTs();
  await p.call(stopKeyMb, "stop");
  await settleBoth(p);
  const heardMb = p.entries.filter((e) => e[0] === "passkey").map((e) => e[1]);
  p.entries = p.entries.filter((e) => e[0] !== "passkey");
  assert.deepEqual(normal(heardMb), normal(heardTs), "the asks a person's app is given");
  sameSince(p, "passkey sign-ins");
  ts.close();
  await p.call("view3", "close");
  await settleBoth(p);
  sameSince(p, "closed");
});

// ── a sign-in form filled by the station ──

/// A sign-in page that goes on as its form is sent: its steps, what each asks, where each is.
function formWorld(o: { steps: Json[]; moves?: boolean }): { world: World; at: () => number } {
  let step = 0;
  let marked = false;
  const world: World = (call, _inst, args) => {
    if (call === "wait") return null;
    if (call !== "cdp.send") return null;
    const [method, params] = args;
    switch (method) {
      case "Target.getTargetInfo":
        return { targetInfo: { url: o.steps[Math.min(step, o.steps.length - 1)].url } };
      case "Page.getFrameTree":
        return { frameTree: { frame: { id: `F${step}` } } };
      case "Page.createIsolatedWorld":
        return { executionContextId: 100 + step };
      case "Input.dispatchKeyEvent":
        if (params.type === "keyUp" && o.moves !== false) {
          step++;
          marked = false;
        }
        return {};
      case "Runtime.evaluate": {
        const e = params.expression as string;
        const page = o.steps[Math.min(step, o.steps.length - 1)];
        if (e === LOOK_SCRIPT) return { result: { value: page.asks } };
        if (e.startsWith("(() => { const el =")) return { result: { value: page.asks[["username", "password", "code"].find((k) => e.includes(`["${k}"]`))!] === true } };
        if (e === BUTTON_SCRIPT) return { result: { value: page.button ?? null } };
        if (e === "window.__stillfailSent = true") { marked = true; return { result: { value: true } }; }
        if (e === "window.__stillfailSent === true") return { result: { value: marked } };
        if (page.throws) throw new Error(page.throws);
        return { exceptionDetails: { text: "?" } };
      }
      default:
        return {};
    }
  };
  return { world, at: () => step };
}

test("a sign-in form: each step's fields typed (a code a digit at a time), sent with Enter, until the page leaves its sign-in, asks a code it was not given, or needs a person", { skip }, async () => {
  const p = await mb();
  const cases: { what: string; steps: Json[]; values: Json; used?: string[]; moves?: boolean; site?: string }[] = [
    { what: "an account and a password, then a code not given", steps: [{ url: "https://login.a.test/", asks: { username: true, password: true, code: false, blocked: false } }, { url: "https://login.a.test/2fa", asks: { username: false, password: false, code: true, blocked: false } }], values: { username: "alice", password: "pw" } },
    { what: "a code, then signed in", steps: [{ url: "https://a.test/2fa", asks: { code: true } }, { url: "https://a.test/home", asks: {} }], values: { code: "123456" } },
    { what: "elsewhere", steps: [{ url: "https://other.test/", asks: { username: true } }], values: { username: "u" } },
    { what: "a captcha", steps: [{ url: "https://a.test/", asks: { username: true, blocked: true } }], values: { username: "u" } },
    { what: "nothing it takes", steps: [{ url: "https://a.test/", asks: { password: true } }], values: { username: "u" } },
    { what: "asked again what was typed", steps: [{ url: "https://a.test/", asks: { password: true } }], values: { password: "p" }, used: ["password"] },
    { what: "stuck: nothing moves, a button pressed", steps: [{ url: "https://a.test/", asks: { username: true }, button: { x: 10.5, y: 20 } }], values: { username: "u" }, moves: false },
    { what: "stuck with no button", steps: [{ url: "https://a.test/", asks: { username: true } }], values: { username: "u" }, moves: false },
    { what: "left at once", steps: [{ url: "https://a.test/", asks: {} }], values: {} },
  ];
  for (const [i, c] of cases.entries()) {
    await begin(p);
    const tsSide = formWorld({ steps: c.steps, moves: c.moves });
    const mbSide = formWorld({ steps: c.steps, moves: c.moves });
    p.world = mbSide.world;
    const cdp = `f${i}`;
    const form = new TabForm(tsCdp(() => tsSide.world, cdp), "S1", "T1");
    await p.make("tabForm", `form${i}`, { cdp, session: "S1", targetId: "T1" });
    const used = new Set<string>(c.used ?? []);
    const driven = await drive(form, c.site ?? "a.test", c.values, used as never, async (ms) => void tsEntries.push(["wait", ms]));
    const got = await p.call(`form${i}`, "drive", c.site ?? "a.test", c.values, c.used ?? []);
    assert.deepEqual(got, { driven: plain(driven), used: [...used] }, c.what);
    await p.quiet();
    sameSince(p, c.what);
  }
  // each step alone, and a page whose world went as it was asked
  await begin(p);
  const steps = [{ url: "https://a.test/", asks: { username: true, password: true }, button: { x: 1, y: 2 }, throws: "Cannot find context with specified id" }];
  const tsSide = formWorld({ steps });
  p.world = formWorld({ steps }).world;
  const form = new TabForm(tsCdp(() => tsSide.world, "fz"), "S1", "T1");
  await p.make("tabForm", "formz", { cdp: "fz", session: "S1", targetId: "T1" });
  for (const [m, args] of [["host", []], ["url", []], ["on", ["a.test"]], ["on", ["b.test"]], ["look", []], ["type", ["code", "12"]], ["type", ["username", "u"]], ["enter", []], ["press", []], ["mark", []], ["marked", []], ["close", []]] as [string, Json[]][]) {
    const a = await outcome(() => (form as Json)[m](...args));
    const b = await mbOutcome(() => p.call("formz", m, ...args));
    assert.deepEqual(b, a, m);
    await p.quiet();
  }
  sameSince(p, "each step");
});

// ── the station's browser: its Chrome, its tabs as screens, a person's own pages, the chats' contexts ──

const runningOf = (n: number, o: Json = {}): Json => ({ pid: 100 + n, started: 5000 + n, port: 9300, ws: `ws://127.0.0.1:9300/devtools/browser/${n}`, binary: "/chrome", headless: true, userAgent: "UA", ...o });

/// What a station's Chrome answers (each side its own): a Chrome left running where `left` says one, launched anew
/// otherwise; tabs and contexts made with ids counted; the pages' metrics, cookies and passkeys as `state` says.
function stationWorld(state: { left?: Json; targets?: Json[]; cookies?: Json[]; credentials?: Json[]; refuse?: string[] }): World {
  let launches = 0;
  let made = 0;
  let contexts = 0;
  return (call, _inst, args) => {
    switch (call) {
      case "chrome.find": {
        const left = state.left ?? null;
        return left;
      }
      case "chrome.launch":
        return runningOf(++launches);
      case "chrome.kill":
        return null;
      case "connect":
        if (state.refuse?.includes(args[1])) throw new Error("connect ECONNREFUSED");
        return null;
      case "cdp.send": {
        const [method, params, session] = args;
        switch (method) {
          case "Target.getTargets":
            return { targetInfos: state.targets ?? [] };
          case "Target.createTarget":
            return { targetId: `N${++made}` };
          case "Target.createBrowserContext":
            return { browserContextId: `CTX${++contexts}` };
          case "Target.attachToTarget":
            return { sessionId: `S-${params.targetId}` };
          case "WebAuthn.addVirtualAuthenticator":
            return { authenticatorId: `A-${session}` };
          case "Page.getLayoutMetrics":
            return { cssVisualViewport: { clientWidth: 1200, clientHeight: 800 } };
          case "Browser.getWindowForTarget":
            return { bounds: { width: 1280, height: 900 } };
          case "Storage.getCookies":
            return { cookies: state.cookies ?? [] };
          case "WebAuthn.getCredentials":
            return { credentials: state.credentials ?? [] };
          case "Page.getNavigationHistory":
            return { currentIndex: 1, entries: [{ id: 11 }, { id: 12 }, { id: 13 }] };
          default:
            return {};
        }
      }
      default:
        return null;
    }
  };
}

/// The TypeScript side's Chrome host over `world`, its calls written down as the program's are asked.
function tsChrome(world: () => World, installed = true): ChromeHost {
  let n = 0;
  return {
    async find() {
      tsEntries.push(["chrome.find"]);
      await Promise.resolve();
      return world()("chrome.find", "", []);
    },
    async launch() {
      tsEntries.push(["chrome.launch"]);
      await Promise.resolve();
      return world()("chrome.launch", "", []) as Running;
    },
    installed: () => installed,
    async kill(r) {
      tsEntries.push(["chrome.kill", plain(r)]);
      await Promise.resolve();
      world()("chrome.kill", "", [plain(r)]);
    },
    async connect(ws) {
      const id = `t${++n}`;
      tsConns.push(id);
      tsEntries.push(["connect", id, ws]);
      await Promise.resolve();
      world()("connect", "", [id, ws]);
      return tsCdp(world, id);
    },
  };
}

/// The TypeScript side's screens, written down as the program's are told.
const tsSources = new Map<string, ScreenSource>();
function tsScreens() {
  return {
    add(source: ScreenSource) {
      tsSources.set(source.id, source);
      tsEntries.push(["screens.add", source.id]);
      return () => void tsEntries.push(["screens.remove", source.id]);
    },
    changed() {
      tsEntries.push(["screens.changed"]);
    },
    setBrowser(b: unknown) {
      tsEntries.push(["screens.browser", b !== null]);
    },
    list: () => [],
    get: (id: string) => tsSources.get(id),
    watch: () => () => {},
  } as never;
}

const sourceInfo = (s: Json) => ({
  id: s.id, kind: s.kind, title: s.title(), site: s.site?.() ?? null, address: s.address?.() ?? "", size: s.size(),
  peek: Boolean(s.peek), openedBy: s.openedBy?.() ?? null, userTab: s.userTab === true, popup: s.popup === true,
  sleeping: s.sleeping?.() === true, farview: s.farview === true,
});

/// Both sides' connection `k` (the k-th each side's Chrome host made, from 0).
async function emitConn(p: Program, k: number, method: string, params: Json, sessionId?: string) {
  tsCdps.get(tsConns[k]!)!.emit(method, params, sessionId);
  await p.emit(p.conns[k]!, method, params, sessionId);
}

/// Both sides' call: started on both, both brought to rest, then each one's outcome compared.
async function bothCall(p: Program, what: string, ts: () => unknown, inst: string, method: string, ...args: Json[]) {
  const a = outcome(ts);
  const b = mbOutcome(() => p.call(inst, method, ...args));
  await settleBoth(p);
  assert.deepEqual(await b, await a, what);
  await settleBoth(p);
}

/// A screen of both sides, by its id: what it says of itself the same.
async function sameSource(p: Program, id: string, what: string) {
  const s = tsSources.get(id);
  assert.ok(s, `${what}: the TypeScript's screen ${id}`);
  assert.deepEqual(normal(await p.call(id, "info")), normal(plain(sourceInfo(s))), `${what}: ${id}`);
}

test("the station's browser: started once however many ask, its tabs screens with their titles and sizes, closed when idle, started again when it dies in use, let go as the station ends and taken up by the next", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const tsDir = fresh("station-ts");
  const mbDir = fresh("station-mb");
  const stateTs: Json = {};
  const stateMb: Json = {};
  const worldTs = stationWorld(stateTs);
  p.world = stationWorld(stateMb);
  const both = (f: (s: Json) => void) => (f(stateTs), f(stateMb));
  const ts = held(new StationBrowser({ dir: tsDir, chrome: tsChrome(() => worldTs), screens: tsScreens(), clock: t.clock, later }), "st");
  await p.make("station", "st", { dir: mbDir });
  await settleBoth(p);
  sameSince(p, "made");
  // two asking at once: one Chrome
  const a1 = outcome(() => ts.endpoint());
  const a2 = outcome(() => ts.endpoint());
  const b1 = mbOutcome(() => p.call("st", "endpoint"));
  const b2 = mbOutcome(() => p.call("st", "endpoint"));
  await settleBoth(p);
  assert.deepEqual([await b1, await b2], [await a1, await a2], "the endpoint");
  sameSince(p, "started once");
  // a tab comes: a screen, measured, its title read again later
  both((s) => (s.targets = [{ targetId: "A", type: "page", title: "Later title", url: "https://x.test/a", browserContextId: "D" }]));
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "A", type: "page", title: "", url: "https://x.test/a", browserContextId: "D" } });
  await settleBoth(p);
  await sameSource(p, "browser:A", "a tab come");
  sameSince(p, "a tab come");
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "W", type: "service_worker", browserContextId: "D" } });
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "B", type: "page", title: "B", url: "about:blank", browserContextId: "D", openerId: "A", attached: true } });
  await settleBoth(p);
  sameSince(p, "a tab its page opened");
  await settleBoth(p, 1000);
  await sameSource(p, "browser:A", "its title read again");
  sameSince(p, "titles read again");
  await settleBoth(p, 4000);
  await emitConn(p, 0, "Target.targetInfoChanged", { targetInfo: { targetId: "A", type: "page", title: "Moved", url: "https://y.test/", browserContextId: "D" } });
  await settleBoth(p);
  await sameSource(p, "browser:A", "moved");
  sameSince(p, "moved");
  await bothCall(p, "tabs", () => ts.tabs(), "st", "tabs");
  await bothCall(p, "status", () => ts.status(), "st", "status");
  await bothCall(p, "available", () => ts.available(), "st", "available");
  await bothCall(p, "own", () => ts.own("A", "chat:a"), "st", "own", "A", "chat:a");
  await sameSource(p, "browser:A", "owned");
  await bothCall(p, "tabUrl", () => ts.tabUrl("A"), "st", "tabUrl", "A");
  await bothCall(p, "contextOf", () => ts.contextOf("A"), "st", "contextOf", "A");
  await bothCall(p, "hasTab", () => ts.hasTab("Z"), "st", "hasTab", "Z");
  await bothCall(p, "send", () => ts.send("Browser.getVersion"), "st", "send", "Browser.getVersion");
  sameSince(p, "asked of it");
  // a screen's own ways: an address (searched where it is none), reload, back and forward, closed
  const tsA = tsSources.get("browser:A")! as Json;
  await bothCall(p, "openUrl", () => tsA.openUrl("example.com"), "browser:A", "openUrl", "example.com");
  await bothCall(p, "openUrl words", () => tsA.openUrl("what is this"), "browser:A", "openUrl", "what is this");
  await bothCall(p, "openUrl none", () => tsA.openUrl("  "), "browser:A", "openUrl", "  ");
  await bothCall(p, "reload", () => tsA.reload(), "browser:A", "reload");
  await bothCall(p, "back", () => tsA.back(), "browser:A", "back");
  await bothCall(p, "forward", () => tsA.forward(), "browser:A", "forward");
  sameSince(p, "a screen's ways");
  // a view of it: on a connection of its own, its size told; a viewer that takes no JPEG refused
  const tsView = await outcome(async () => { const v = await tsA.open({ codecs: ["jpeg"], maxWidth: 800, maxHeight: 600 }); (globalThis as Json).tsView = v; return "view"; });
  const mbView = await p.call("browser:A", "open", { codecs: ["jpeg"], maxWidth: 800, maxHeight: 600 });
  assert.deepEqual(tsView, { ok: "view" });
  await settleBoth(p);
  await bothCall(p, "a viewer of no JPEG", () => tsA.open({ codecs: ["h264"], maxWidth: 1, maxHeight: 1 }), "browser:A", "open", { codecs: ["h264"], maxWidth: 1, maxHeight: 1 });
  sameSince(p, "a view");
  // idle: kept while a person watches, closed an hour after the view ended
  await settleBoth(p, 3 * 60 * 60_000);
  await bothCall(p, "status while watched", () => ts.status(), "st", "status");
  (globalThis as Json).tsView.close();
  await p.call(mbView, "close");
  await settleBoth(p);
  await settleBoth(p, 60 * 60_000);
  await bothCall(p, "status idle", () => ts.status(), "st", "status");
  sameSince(p, "closed when idle");
  // started again, then it dies in use: started again at once; dying again at once, after a pause
  await bothCall(p, "endpoint again", () => ts.endpoint(), "st", "endpoint");
  await settleBoth(p, 120_000);
  await bothCall(p, "used", () => ts.used(), "st", "used");
  const died = async () => {
    const k = tsConns.length - 1;
    tsCdps.get(tsConns[k]!)!.end();
    await p.cmd("cdpEnd", { cdp: p.conns[k] });
    await settleBoth(p);
  };
  await died();
  await bothCall(p, "status after it died", () => ts.status(), "st", "status");
  await died();
  await bothCall(p, "status after it died again", () => ts.status(), "st", "status");
  await settleBoth(p, 999);
  await settleBoth(p, 1);
  await bothCall(p, "status a second on", () => ts.status(), "st", "status");
  sameSince(p, "started again");
  // the station process ends: let go, not closed; what the next takes up written down
  await bothCall(p, "close", () => ts.close(), "st", "close");
  sameSince(p, "let go");
  sameFiles(tsDir, mbDir, "as the station ended");
  // the next process: the Chrome left running taken up, its tabs coming again as Chrome tells of them
  both((s) => (s.left = runningOf(3)));
  const next = held(new StationBrowser({ dir: tsDir, chrome: tsChrome(() => worldTs), screens: tsScreens(), clock: t.clock, later }), "st2");
  await p.make("station", "st2", { dir: mbDir });
  await bothCall(p, "resume", () => next.resume(), "st2", "resume");
  const k = tsConns.length - 1;
  tsCdps.get(tsConns[k]!)!.emit("Target.targetCreated", { targetInfo: { targetId: "A", type: "page", title: "Moved", url: "https://y.test/", browserContextId: "D" } });
  await p.emit(p.conns[k]!, "Target.targetCreated", { targetInfo: { targetId: "A", type: "page", title: "Moved", url: "https://y.test/", browserContextId: "D" } });
  await settleBoth(p);
  await sameSource(p, "browser:A", "taken up");
  await bothCall(p, "closeOf", () => next.closeOf("chat:a"), "st2", "closeOf", "chat:a");
  await emitConn(p, k, "Target.targetDestroyed", { targetId: "A" });
  await settleBoth(p);
  await bothCall(p, "stop", () => next.stop(), "st2", "stop");
  await bothCall(p, "close", () => next.close(), "st2", "close");
  sameSince(p, "taken up and stopped");
  sameFiles(tsDir, mbDir, "after the next");
});

test("the station's own tabs: opened behind (the browser started for it), in an isolated context whose cookies and passkeys a login keeps, closed when asked", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const tsDir = fresh("own-ts");
  const mbDir = fresh("own-mb");
  const stateTs: Json = { cookies: COOKIES_READ, credentials: [KEY_A] };
  const stateMb: Json = { cookies: COOKIES_READ, credentials: [KEY_A] };
  const worldTs = stationWorld(stateTs);
  p.world = stationWorld(stateMb);
  const ts = held(new StationBrowser({ dir: tsDir, chrome: tsChrome(() => worldTs), screens: tsScreens(), clock: t.clock, later }), "own");
  await p.make("station", "own", { dir: mbDir });
  // a tab of its own context: waited for until Chrome tells of it
  const a = outcome(() => ts.openTab("https://login.test/"));
  const b = mbOutcome(() => p.call("own", "openTab", "https://login.test/"));
  await settleBoth(p);
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "N1", type: "page", url: "https://login.test/", title: "" } });
  await settleBoth(p);
  assert.deepEqual(await b, await a, "openTab");
  sameSince(p, "a tab of its own");
  // one not told of: given up waiting after its time
  const a2 = outcome(() => ts.openTab("https://slow.test/"));
  const b2 = mbOutcome(() => p.call("own", "openTab", "https://slow.test/"));
  await settleBoth(p);
  await settleBoth(p, 3000);
  assert.deepEqual(await b2, await a2, "openTab not told of");
  sameSince(p, "a tab not told of");
  // a login's tab: its state read from the file, kept back to it as it changes, the file gone where nothing is left
  const tsHome = join(tsDir, "login");
  const mbHome = join(mbDir, "login");
  mkdirSync(tsHome);
  mkdirSync(mbHome);
  const kept = keptOf({ cookies: siteCookies(COOKIES_READ, ["github.com"]), passkeys: [passkeyOf(KEY_B)!] });
  writeFileSync(join(tsHome, "state.json"), kept);
  writeFileSync(join(mbHome, "state.json"), kept);
  let tsPath: string | null = join(tsHome, "state.json");
  await p.call("own", "setStateFile", join(mbHome, "state.json"));
  const a3 = outcome(() => ts.openTab("https://github.com/login", { stateFile: () => tsPath }));
  const b3 = mbOutcome(() => p.call("own", "openTab", "https://github.com/login", true));
  await settleBoth(p);
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "N3", type: "page", url: "https://github.com/login", browserContextId: "CTX1" } });
  await settleBoth(p);
  assert.deepEqual(await b3, await a3, "a login's tab");
  sameSince(p, "a login's tab");
  await emitConn(p, 0, "Target.targetInfoChanged", { targetInfo: { targetId: "N3", type: "page", url: "https://github.com/home", browserContextId: "CTX1" } });
  await settleBoth(p);
  await bothCall(p, "flushed", () => ts.flushed(), "own", "flushed");
  sameSince(p, "its state kept as it changed");
  assert.equal(readFileSync(join(mbHome, "state.json"), "utf8"), readFileSync(join(tsHome, "state.json"), "utf8"), "the login's state");
  // its home moved away: not made again
  tsPath = null;
  await p.call("own", "setStateFile", null);
  await bothCall(p, "close the login's tab", () => ts.closeTab("N3"), "own", "closeTab", "N3");
  await bothCall(p, "close a tab", () => ts.closeTab("N1"), "own", "closeTab", "N1");
  await bothCall(p, "close none", () => ts.closeTab("none"), "own", "closeTab", "none");
  sameSince(p, "closed");
  // attached on a connection of its own (a sign-in's form), and its context's passkeys
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "N9", type: "page", url: "https://a.test/" } });
  await settleBoth(p);
  const tsAttached = await ts.attach("N9");
  const mbAttached = await p.call("own", "attach", "N9");
  assert.equal(mbAttached.session, tsAttached.session);
  await settleBoth(p);
  await bothCall(p, "attach a closed tab", () => ts.attach("gone"), "own", "attach", "gone");
  await bothCall(p, "passkeys read", async () => (await ts.passkeys()).read("CTX1"), "own", "passkeys.read", "CTX1");
  await bothCall(p, "passkeys put", async () => (await ts.passkeys()).put("CTX1", [passkeyOf(KEY_A)!]), "own", "passkeys.put", "CTX1", [KEY_A]);
  await bothCall(p, "passkeys has", async () => (await ts.passkeys()).has("CTX1", "github.com"), "own", "passkeys.has", "CTX1", "github.com");
  sameSince(p, "attached");
  await bothCall(p, "close", () => ts.close(), "own", "close");
  sameSince(p, "let go");
  sameFiles(tsDir, mbDir, "the station's own tabs");
});

test("a person's own pages: opened by the app's id, asleep when unwatched, woken on a view, a page's popup its own, navigated, discarded; asleep as Chrome stops", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const tsDir = fresh("user-ts");
  const mbDir = fresh("user-mb");
  const worldTs = stationWorld({});
  p.world = stationWorld({});
  const ts = held(new StationBrowser({ dir: tsDir, chrome: tsChrome(() => worldTs), screens: tsScreens(), clock: t.clock, later }), "user");
  await p.make("station", "user", { dir: mbDir });
  const a = outcome(() => ts.openUserTab("mail.proton.me", "u_abc123"));
  const b = mbOutcome(() => p.call("user", "openUserTab", "mail.proton.me", "u_abc123"));
  await settleBoth(p);
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "N1", type: "page", url: "https://mail.proton.me/", title: "" } });
  await settleBoth(p);
  assert.deepEqual(await b, await a, "openUserTab");
  await bothCall(p, "asked again", () => ts.openUserTab("other", "u_abc123"), "user", "openUserTab", "other", "u_abc123");
  await bothCall(p, "a bad address", () => ts.openUserTab("x".repeat(9000), "u_bad"), "user", "openUserTab", "x".repeat(9000), "u_bad");
  sameSince(p, "opened");
  await emitConn(p, 0, "Target.targetInfoChanged", { targetInfo: { targetId: "N1", type: "page", title: "Inbox (3) - Proton Mail", url: "https://mail.proton.me/u/0/inbox?secret=1" } });
  await settleBoth(p);
  await bothCall(p, "flushed", () => ts.flushed(), "user", "flushed");
  await sameSource(p, "browser:u_abc123", "titled");
  sameFiles(tsDir, mbDir, "user-tabs.json");
  sameSince(p, "titled");
  // unwatched: asleep
  await settleBoth(p, 10 * 60_000);
  await emitConn(p, 0, "Target.targetDestroyed", { targetId: "N1" });
  await settleBoth(p);
  await sameSource(p, "browser:u_abc123", "asleep");
  sameSince(p, "asleep");
  // a view wakes it at its saved address; a popup its page opens is a user tab of its own, gone as it closes itself
  const src = tsSources.get("browser:u_abc123")! as Json;
  const va = outcome(async () => { (globalThis as Json).userView = await src.open({ codecs: ["jpeg"], maxWidth: 800, maxHeight: 600 }); return "view"; });
  const vb = mbOutcome(() => p.call("browser:u_abc123", "open", { codecs: ["jpeg"], maxWidth: 800, maxHeight: 600 }));
  await settleBoth(p);
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "N2", type: "page", url: "https://mail.proton.me/u/0/inbox?secret=1", title: "Inbox" } });
  await settleBoth(p);
  assert.deepEqual((await va).ok, "view");
  const mbView = (await vb).ok;
  await sameSource(p, "browser:u_abc123", "woken");
  sameSince(p, "woken");
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "POP1", type: "page", url: "https://claude.ai/magic-link", title: "Verify", openerId: "N2" } });
  await settleBoth(p);
  sameSince(p, "a popup");
  await emitConn(p, 0, "Target.targetDestroyed", { targetId: "POP1" });
  await settleBoth(p);
  sameSince(p, "the popup gone");
  // navigated while live; back; the view ended: asleep after its time again
  await bothCall(p, "navigate", () => src.openUrl("news.ycombinator.com"), "browser:u_abc123", "openUrl", "news.ycombinator.com");
  await bothCall(p, "back", () => src.back(), "browser:u_abc123", "back");
  await bothCall(p, "reload", () => src.reload(), "browser:u_abc123", "reload");
  (globalThis as Json).userView.close();
  await p.call(mbView, "close");
  await settleBoth(p);
  await settleBoth(p, 10 * 60_000);
  sameSince(p, "navigated, asleep again");
  await bothCall(p, "flushed", () => ts.flushed(), "user", "flushed");
  sameFiles(tsDir, mbDir, "user-tabs.json asleep");
  // a sleeping tab navigated: woken at the new address
  const na = outcome(() => src.openUrl("https://example.com/new"));
  const nb = mbOutcome(() => p.call("browser:u_abc123", "openUrl", "https://example.com/new"));
  await settleBoth(p);
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "N3", type: "page", url: "https://example.com/new", title: "" } });
  await settleBoth(p);
  assert.deepEqual(await nb, await na, "navigate asleep");
  sameSince(p, "navigated asleep");
  // Chrome stops: asleep, its target left for nobody; discarded
  await bothCall(p, "stop", () => ts.stop(), "user", "stop");
  await sameSource(p, "browser:u_abc123", "Chrome stopped");
  await bothCall(p, "discard", () => src.discard(), "browser:u_abc123", "discard");
  await bothCall(p, "flushed", () => ts.flushed(), "user", "flushed");
  sameSince(p, "stopped and discarded");
  sameFiles(tsDir, mbDir, "user-tabs.json at the end");
  await bothCall(p, "close", () => ts.close(), "user", "close");
  sameSince(p, "let go");
});

/// What the TypeScript's browsers tell their station, written down as the program's are told.
function listen(b: Browsers) {
  b.onTakenOut((s, r, k, w) => tsEntries.push(["takenOut", s, r, k, w ?? null]));
  b.onFresh((s) => tsEntries.push(["fresh", s]));
  b.onResumed((s) => tsEntries.push(["resumed", s]));
  b.onUsed((s, h) => tsEntries.push(["used", s, h]));
}

test("each chat's own context: made as its agent asks, its gate's parts, its sign-ins put in and taken out as their grants end, gone with its chat or its Chrome, kept for the next station process", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const tsDir = fresh("browsers-ts");
  const mbDir = fresh("browsers-mb");
  const stateTs: Json = { cookies: COOKIES_READ, credentials: [KEY_A] };
  const stateMb: Json = { cookies: COOKIES_READ, credentials: [KEY_A] };
  const worldTs = stationWorld(stateTs);
  p.world = stationWorld(stateMb);
  const ts = held(new Browsers({ dir: tsDir, chrome: tsChrome(() => worldTs), screens: tsScreens(), clock: t.clock, later }), "bs");
  listen(ts);
  await p.make("browsers", "bs", { dir: mbDir });
  await bothCall(p, "context", () => ts.context("chat:a"), "bs", "context", "chat:a");
  await bothCall(p, "the same context", () => ts.context("chat:a"), "bs", "context", "chat:a");
  await bothCall(p, "endpoint", () => ts.endpoint("chat:b"), "bs", "endpoint", "chat:b");
  const tsOpen = await ts.open("chat:a");
  const mbOpen = await p.call("bs", "open", "chat:a");
  assert.deepEqual({ ws: mbOpen.ws, context: mbOpen.context }, { ws: tsOpen.ws, context: tsOpen.gate.context }, "the door's way in");
  await settleBoth(p);
  sameSince(p, "contexts made");
  // a tab of chat:a's context: its, listed for it alone; its use heard
  await emitConn(p, 0, "Target.targetCreated", { targetInfo: { targetId: "TA", type: "page", url: "https://github.com/x", title: "GH", browserContextId: "CTX1" } });
  await settleBoth(p);
  await bothCall(p, "tabs of a", () => ts.tabs("chat:a"), "bs", "tabs", "chat:a");
  await bothCall(p, "tabs of b", () => ts.tabs("chat:b"), "bs", "tabs", "chat:b");
  await bothCall(p, "status", () => ts.status("chat:a"), "bs", "status", "chat:a");
  await bothCall(p, "status of none", () => ts.status("chat:none"), "bs", "status", "chat:none");
  await bothCall(p, "used", () => ts.used("chat:a", "TA"), "bs", "used", "chat:a", "TA");
  await bothCall(p, "used by url", () => ts.used("chat:a", "x", "https://Sub.Example.com/p"), "bs", "used", "chat:a", "x", "https://Sub.Example.com/p");
  await sameSource(p, "browser:TA", "a chat's tab");
  sameSince(p, "a chat's tab");
  // a sign-in put in, its cookies of its sites and passkeys; read back as the vault keeps it
  const now = clockFibers.now() / 1000;
  const signed = { request: "r1", workspace: "w1", sites: ["github.com"], cookies: keptOf({ cookies: COOKIES_READ as never, passkeys: [passkeyOf(KEY_A)!, passkeyOf(KEY_B)!] }), until: now + 60 };
  await bothCall(p, "signIn", () => ts.signIn("chat:a", signed), "bs", "signIn", "chat:a", signed);
  await bothCall(p, "signIn again", () => ts.signIn("chat:a", { ...signed, until: now + 30, workspace: undefined }), "bs", "signIn", "chat:a", { ...signed, until: now + 30, workspace: undefined });
  await bothCall(p, "cookies", () => ts.cookies("chat:a", ["github.com"], false), "bs", "cookies", "chat:a", ["github.com"], false);
  await bothCall(p, "cookies of the station's own", () => ts.cookies("chat:a", ["github.com"], true), "bs", "cookies", "chat:a", ["github.com"], true);
  await bothCall(p, "extend", () => ts.extendSignIn("chat:a", "r1", now + 90), "bs", "extendSignIn", "chat:a", "r1", now + 90);
  await bothCall(p, "passkeysIn", () => ts.passkeysIn("chat:a", { sites: ["github.com"], cookies: signed.cookies }), "bs", "passkeysIn", "chat:a", { sites: ["github.com"], cookies: signed.cookies });
  sameSince(p, "signed in");
  // its grant ends: taken out, its cookies as they were then given back
  await settleBoth(p, 90_000);
  sameSince(p, "taken out as its grant ended");
  // a sign-in into chat:b, ended while Chrome is closed: taken out once it is there again
  await bothCall(p, "signIn b", () => ts.signIn("chat:b", { ...signed, request: "r2", until: clockFibers.now() / 1000 + 10 }), "bs", "signIn", "chat:b", { ...signed, request: "r2", until: clockFibers.now() / 1000 + 10 });
  await bothCall(p, "station stop", () => ts.station.stop(), "bs", "station.stop");
  await settleBoth(p, 20_000);
  await bothCall(p, "endpoint b after", () => ts.endpoint("chat:b"), "bs", "endpoint", "chat:b");
  sameSince(p, "a new Chrome: new contexts");
  // its chat stopped, then archived
  await bothCall(p, "stop a", () => ts.stop("chat:a"), "bs", "stop", "chat:a");
  await bothCall(p, "closeOf b", () => ts.closeOf("chat:b"), "bs", "closeOf", "chat:b");
  await bothCall(p, "form of a tab not its", () => ts.form("chat:a", "TA"), "bs", "form", "chat:a", "TA");
  sameSince(p, "stopped and archived");
  await bothCall(p, "a sign-in left for the next", () => ts.signIn("chat:c", { ...signed, request: "r3", until: clockFibers.now() / 1000 + 600 }), "bs", "signIn", "chat:c", { ...signed, request: "r3", until: clockFibers.now() / 1000 + 600 });
  await bothCall(p, "close", () => ts.close(), "bs", "close");
  sameSince(p, "let go");
  sameFiles(tsDir, mbDir, "contexts.json as the station ended");
  // the next station process: the contexts kept taken up with the Chrome left running, their passkeys put in again
  stateTs.left = runningOf(2);
  stateMb.left = runningOf(2);
  const next = held(new Browsers({ dir: tsDir, chrome: tsChrome(() => worldTs), screens: tsScreens(), clock: t.clock, later }), "bs2");
  listen(next);
  await p.make("browsers", "bs2", { dir: mbDir });
  await bothCall(p, "resume", () => next.resume(), "bs2", "resume");
  await bothCall(p, "passkeysAgain", () => next.passkeysAgain(), "bs2", "passkeysAgain");
  await bothCall(p, "the next one's endpoint", () => next.endpoint("chat:c"), "bs2", "endpoint", "chat:c");
  await bothCall(p, "close the next", () => next.close(), "bs2", "close");
  sameSince(p, "taken up");
  sameFiles(tsDir, mbDir, "contexts.json at the end");
});

test("the browser tool: endpoint by default, tabs, status, stop, each the chat's own; Farview's actions refused without it", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const tsDir = fresh("tool-ts");
  const mbDir = fresh("tool-mb");
  const worldTs = stationWorld({});
  p.world = stationWorld({});
  const ts = held(new Browsers({ dir: tsDir, chrome: tsChrome(() => worldTs), screens: tsScreens(), clock: t.clock, later }), "tb");
  listen(ts);
  await p.make("browsers", "tb", { dir: mbDir });
  const door = "http://127.0.0.1:4777/mcp";
  const [tool] = browserTools(ts, () => door);
  await p.make("tool", "tool1", { browsers: "tb", door });
  for (const args of [{}, { action: "tabs" }, { action: "status" }, { action: "endpoint" }, { action: "open" }, { action: "close" }, { action: "bogus" }, { engine: "farview" }, { action: "stop" }, { action: "status" }, { action: 5 }]) {
    await bothCall(p, JSON.stringify(args), () => tool!.run("chat:t", args as never), "tool1", "run", "chat:t", args);
  }
  await bothCall(p, "close", () => ts.close(), "tb", "close");
  sameSince(p, "the tool");
});

// ── a chat's Farview tab, over ports served here ──

/// Wait for socket or program events; an async query also yields to the OS between checks.
async function until(what: string, f: () => boolean | Promise<boolean>) {
  const end = Date.now() + 15_000;
  for (;;) {
    const version = farviewVersion;
    const result = f();
    const asynchronous = result instanceof Promise;
    const left = end - Date.now();
    if (left <= 0) throw new Error(`${what}: it did not come`);
    let limit: ReturnType<typeof setTimeout> | undefined;
    const timed = new Promise<never>((_, reject) => { limit = setTimeout(() => reject(new Error(`${what}: it did not come`)), left); });
    try { if (await Promise.race([Promise.resolve(result), timed])) return; }
    finally { clearTimeout(limit); }
    if (farviewVersion !== version) continue;
    await new Promise<void>((resolve) => {
      const wake = () => { clearTimeout(timer); farviewEvents.off("changed", wake); resolve(); };
      const timer = setTimeout(wake, asynchronous ? Math.min(5, left) : left);
      farviewEvents.once("changed", wake);
      if (farviewVersion !== version) wake();
    });
  }
}

/// An agent port as a Farview host's: each ask read off its wire and written down, answered as `answer` says.
async function agentPort(answer: (ask: Json) => Json) {
  const heard: Json[] = [];
  const server = createServer((s) => {
    let buf = Buffer.alloc(0);
    s.on("data", (d: Buffer) => {
      buf = Buffer.concat([buf, d]);
      while (buf.length >= 4) {
        const n = buf.readUInt32BE(0);
        if (buf.length < 4 + n) break;
        const body = buf.subarray(4, 4 + n);
        buf = buf.subarray(4 + n);
        let i = 0;
        const int = () => { let shift = 0, u = 0; for (;;) { const c = body[i++]!; u |= (c & 0x7f) << shift; shift += 7; if (c < 0x80) break; } u >>>= 0; return (u >>> 1) ^ -(u & 1); };
        const str = () => { const k = int(); const v = body.subarray(i, i + k).toString("utf8"); i += k; return v; };
        const kind = int();
        const ask = kind === 19 ? { kind: "look" } : kind === 32 ? { kind: "eval", script: str() } : kind === 35 ? { kind: "cookies", verb: str(), arg: str() } : kind === 42 ? { kind: "passkeys", verb: str(), arg: str() } : { kind: "act", verb: str(), selector: str(), text: str() };
        heard.push(ask);
        const a = answer(ask);
        if (a === undefined) continue;
        // (a notice first, as a host's other messages may come: not an answer)
        s.write(encodeAnswer({ kind: "notice" }));
        s.write(encodeAnswer(a));
      }
    });
    s.on("error", () => {});
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return { port: (server.address() as { port: number }).port, heard, close: () => server.close() };
}

function encodeAnswer(a: Json): Buffer {
  const out: number[] = [];
  const varint = (v: number) => { let u = ((v << 1) ^ (v >> 31)) >>> 0; while (u >= 0x80) { out.push((u & 0x7f) | 0x80); u >>>= 7; } out.push(u); };
  const str = (s: string) => { const b = Buffer.from(s, "utf8"); varint(b.length); out.push(...b); };
  if (a.kind === "value") { varint(33); str(a.value); }
  else if (a.kind === "seen") { varint(20); str(a.url); str(a.title); str(a.outline); }
  else if (a.kind === "taken") varint(21);
  else varint(99);
  const head = Buffer.alloc(4);
  head.writeUInt32BE(out.length);
  return Buffer.concat([head, Buffer.from(out)]);
}

/// A sign-in page as a Farview host serves it to the station's asks.
function signInHost(state: { url: string; marked: boolean; taken?: boolean }) {
  return (ask: Json): Json => {
    if (state.taken) return { kind: "taken" };
    if (ask.kind === "look") return { kind: "seen", url: state.url, title: "Sign in", outline: "a form" };
    if (ask.kind === "act") return ask.verb === "type" && ask.text === "refuse" ? { kind: "value", value: "x" } : { kind: "seen", url: state.url, title: "", outline: "" };
    if (ask.kind === "cookies") return { kind: "value", value: ask.verb === "get" ? JSON.stringify(COOKIES_READ) : "ok" };
    const script = ask.script as string;
    if (script === LOOK_SCRIPT) return { kind: "value", value: JSON.stringify({ username: true, password: true, code: false, blocked: false }) };
    if (script === "(window.__stillfailSent = true)") { state.marked = true; return { kind: "value", value: "true" }; }
    if (script === "window.__stillfailSent === true") return { kind: "value", value: String(state.marked) };
    if (script.includes("data-stillfail-signin-button")) return { kind: "value", value: "true" };
    if (script.includes('["code"]')) return { kind: "value", value: "false" };
    if (script.includes("data-stillfail-signin")) return { kind: "value", value: "true" };
    return { kind: "value", value: "not json {" };
  };
}

test("a Farview tab's sign-in form: the same finder's fields marked and typed on its agent port, Enter, its button; a tab a person took back", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const stateTs: { url: string; marked: boolean; taken?: boolean } = { url: "https://a.test/login", marked: false };
  const stateMb: { url: string; marked: boolean; taken?: boolean } = { url: "https://a.test/login", marked: false };
  const hostTs = await agentPort(signInHost(stateTs));
  const hostMb = await agentPort(signInHost(stateMb));
  try {
    const ts = new FarviewForm(hostTs.port);
    await p.make("farviewForm", "fv1", { port: hostMb.port });
    const steps: [string, Json[]][] = [["url", []], ["host", []], ["on", ["a.test"]], ["on", ["b.test"]], ["look", []], ["type", ["username", "alice"]], ["type", ["code", "1"]], ["type", ["password", "refuse"]], ["enter", []], ["press", []], ["mark", []], ["marked", []], ["close", []]];
    for (const [m, args] of steps) {
      const a = await outcome(() => (ts as Json)[m](...args));
      const b = await mbOutcome(() => p.call("fv1", m, ...args));
      assert.deepEqual(b, a, m);
    }
    assert.deepEqual(hostMb.heard, hostTs.heard, "what each asked of the tab");
    // the person took the tab back: a value refused, a look none
    stateTs.taken = true;
    stateMb.taken = true;
    for (const [m, args] of [["url", []], ["look", []], ["marked", []], ["mark", []], ["type", ["username", "u"]]] as [string, Json[]][]) {
      const a = await outcome(() => (ts as Json)[m](...args));
      const b = await mbOutcome(() => p.call("fv1", m, ...args));
      assert.deepEqual(b, a, `taken: ${m}`);
    }
    // a port nobody listens on
    const gone = new FarviewForm(1);
    await p.make("farviewForm", "fv2", { port: 1 });
    for (const m of ["url", "look", "marked"]) {
      assert.deepEqual(await mbOutcome(() => p.call("fv2", m)), await outcome(() => (gone as Json)[m]()), `no host: ${m}`);
    }
  } finally {
    hostTs.close();
    hostMb.close();
  }
});

/// A frame port as a Farview host's: each connection's lines written down by its number; a picture asked for answered
/// with `picture`, its bytes in two pieces and the page's line after them in the second's write.
async function framePortOf(picture: Buffer) {
  const heard: Json[] = [];
  const sockets: Socket[] = [];
  let seq = 3;
  const server = createServer((s) => {
    const k = sockets.length;
    sockets.push(s);
    wakeFarview();
    let buf = "";
    s.on("data", (d) => {
      buf += d.toString("latin1");
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const m = JSON.parse(Buffer.from(buf.slice(0, nl), "latin1").toString("utf8"));
        buf = buf.slice(nl + 1);
        heard.push([k, m]);
        wakeFarview();
        if (m.frame) {
          s.write(`${JSON.stringify({ frame: { seq: seq++, width: 640, height: 450, format: "jpeg", bytes: picture.length } })}\n`);
          s.write(picture.subarray(0, 2));
          s.write(Buffer.concat([picture.subarray(2), Buffer.from(`${JSON.stringify({ page: { url: "https://a.test/", title: "A" } })}\n`)]));
        }
      }
    });
    s.on("error", () => {});
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const said = (m: Json) => {
    for (const s of sockets) s.write(`${JSON.stringify(m)}\n`);
  };
  const close = () => {
    for (const s of sockets) s.destroy();
    server.close();
  };
  return { port: (server.address() as { port: number }).port, heard, said, close, sockets };
}

test("a Farview tab as a screen: its page and size heard, a view's size, a picture only once the host says the tab changed, a person's input, paste and copies, its end", { skip }, async () => {
  const p = await mb();
  await begin(p);
  const picture = Buffer.from([0xff, 0xd8, 9, 8, 7, 0xff, 0xd9]);
  const portTs = await framePortOf(picture);
  const portMb = await framePortOf(picture);
  try {
    // a link alone: a picture asked for, the lines after it heard, nothing after its end
    const link = new FrameLink(portTs.port);
    const linkHeard: Json[] = [];
    link.heard = (m) => { linkHeard.push(m); wakeFarview(); };
    await p.make("frameLink", "link1", { port: portMb.port });
    const pic = await link.picture();
    const mbPic = await p.call("link1", "picture");
    assert.deepEqual(mbPic, { header: pic!.header, data: pic!.data.toString("base64") });
    await until("the page's line", () => linkHeard.length > 0 && p.entries.some((e) => e[0] === "heard"));
    link.send({ text: "hello" });
    await p.call("link1", "send", { text: "hello" });
    await until("the host heard", () => portTs.heard.length === 2 && portMb.heard.length === 2);
    link.close();
    await p.call("link1", "close");
    assert.deepEqual(await p.call("link1", "picture"), await link.picture());
    assert.deepEqual(p.entries.filter((e) => e[0] === "heard").map((e) => e[1]), linkHeard);
    // the screen and a view of it
    const screen = new FarviewScreen({ session: "chat:c-1", port: portTs.port, n: 2 });
    const opened: Json[] = [];
    screen.opened = (url, meta) => { opened.push([url, meta]); wakeFarview(); };
    let closedByPage = 0;
    screen.closedByPage = () => { closedByPage++; wakeFarview(); };
    await p.make("farviewScreen", "fs1", { session: "chat:c-1", port: portMb.port, n: 2 });
    screen.watch();
    await p.call("fs1", "watch");
    await until("the watch's connection", () => portTs.sockets.length === 2 && portMb.sockets.length === 2);
    const info = () => ({ id: screen.id, title: screen.title(), site: screen.site() ?? null, address: screen.address(), size: screen.size(), viewing: screen.viewing(), page: screen.page() });
    assert.deepEqual(await p.call("fs1", "info"), plain(info()), "before it says anything");
    for (const m of [{ page: { url: "https://b.test/x", title: "" } }, { size: { width: 1000, height: 700, scale: 2 } }, { openTab: "https://c.test/" }, { openTab: "" }, { openTab: "https://oauth.test/", window: "w_1", opener: "fv_x_2", origin: "https://b.test" }, { closeTab: false }, { closeTab: true }]) {
      portTs.said(m);
      portMb.said(m);
    }
    await until("the page heard", () => opened.length === 2 && closedByPage === 1 && p.entries.some((e) => e[0] === "closedByPage"));
    assert.deepEqual(await p.call("fs1", "info"), plain(info()), "its page and size");
    assert.deepEqual(p.entries.filter((e) => e[0] === "opened").map((e) => [e[1], e[2]]), opened);
    assert.equal(p.entries.filter((e) => e[0] === "closedByPage").length, closedByPage);
    const options = { codecs: ["jpeg"], maxWidth: 4000, maxHeight: 4000, fit: { width: 400, height: 800, scale: 2 } };
    const view = await screen.open(options as never);
    const mbView = await p.call("fs1", "open", options);
    const first = frameOf(await view.next());
    assert.deepEqual(await p.call(mbView, "next"), first, "the first picture");
    // nothing changed: no picture asked for until the host says one
    const waitingTs = view.next();
    const waitingMb = p.call(mbView, "next");
    for (const port of [portTs, portMb]) port.said({ changed: 9 });
    assert.deepEqual(await waitingMb, frameOf(await waitingTs), "after it changed");
    view.keyframe();
    await p.call(mbView, "keyframe");
    assert.deepEqual(await p.call(mbView, "next"), frameOf(await view.next()), "a key frame");
    for (const input of [{ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 }, { t: "wheel", x: 0.1, y: 0.9, dx: 0, dy: 120 }, { t: "key", kind: "down", key: "Enter", code: "Enter", mods: 8 }, { t: "text", text: "你好" }, { t: "pose", name: "open" }]) {
      await view.input(input as never);
      await p.call(mbView, "input", input);
    }
    for (const port of [portTs, portMb]) port.said({ size: { width: 500, height: 900 } });
    await until("the size heard", async () => portTs.heard.length >= 6 && portMb.heard.length === portTs.heard.length && screen.size().height === 1800 && (await p.call("fs1", "info")).size.height === 1800);
    await view.setClipboard!({ type: "text", text: "pasted" } as never, true);
    await p.call(mbView, "setClipboard", { type: "text", text: "pasted" }, true);
    await view.setClipboard!({ type: "text", text: "" } as never, true);
    await p.call(mbView, "setClipboard", { type: "text", text: "" }, true);
    const copiedTs: Json[] = [];
    view.watchClipboard!((c) => { copiedTs.push(plain(c)); wakeFarview(); });
    await p.call(mbView, "watchClipboard");
    for (const port of [portTs, portMb]) port.said({ copied: "copied words" });
    await until("the copy heard", () => copiedTs.length === 1 && p.entries.some((e) => e[0] === "clip"));
    assert.deepEqual(p.entries.filter((e) => e[0] === "clip").map((e) => e[1]), copiedTs);
    view.bounds!(640, 400);
    await p.call(mbView, "bounds", 640, 400);
    view.bounds!(640, 400);
    await p.call(mbView, "bounds", 640, 400);
    assert.deepEqual(await p.call(mbView, "video"), plain(view.video!()));
    await until("the host heard all", () => portTs.heard.length === portMb.heard.length && portTs.heard.length > 8);
    assert.deepEqual(portMb.heard, portTs.heard, "what the host was sent, by connection");
    assert.deepEqual(await p.call("fs1", "info"), plain(info()), "viewed");
    view.close();
    await p.call(mbView, "close");
    assert.deepEqual(await p.call(mbView, "next"), frameOf(await view.next()), "after its end");
    assert.deepEqual(await p.call("fs1", "info"), plain(info()), "its view ended");
    screen.close();
    await p.call("fs1", "close");
    assert.deepEqual(await mbOutcome(() => p.call("fs1", "open", options)), await outcome(() => screen.open(options as never)), "closed");
    await p.quiet();
    assert.deepEqual(normal(p.entries.filter((e) => e[0] === "log")), normal(tsEntries.filter((e) => e[0] === "log")), "the log");
  } finally {
    portTs.close();
    portMb.close();
  }
});

// ── Farview's release ──

test("Farview's release: asked of each source in turn, a tarball whose SHA-256 is not the release's refused and nothing of it unpacked, kept where the cache keeps it, not asked again once there", { skip, timeout: 60_000 }, async () => {
  const p = await mb();
  await begin(p);
  const root = fresh("release");
  const src = join(root, "src", "farview-macos-arm64");
  mkdirSync(join(src, "bin"), { recursive: true });
  mkdirSync(join(src, "lib"), { recursive: true });
  writeFileSync(join(src, "bin", "host.exe"), "#!/bin/sh\n");
  writeFileSync(join(src, "bin", "agent.exe"), "#!/bin/sh\necho agent\n");
  writeFileSync(join(src, "lib", "x.dylib"), "lib");
  const { execFileSync } = await import("node:child_process");
  const tgz = join(root, "release.tar.gz");
  execFileSync("tar", ["-czf", tgz, "-C", join(root, "src"), "farview-macos-arm64"]);
  const bytes = readFileSync(tgz);
  const release = { rev: "f232322775f819e81555884d2f11a8b1ae40092c", sha256: createHash("sha256").update(bytes).digest("hex") };
  const { unpackRelease } = await import("../src/browser/farview-release.ts");
  const served: Record<string, Buffer | null> = { "https://bad/x": Buffer.from("not it"), "https://none/x": null, "https://good/x": bytes };
  const cases: [string, string[]][] = [
    ["refused, then none", ["https://bad/x", "https://none/x"]],
    ["none at all", ["https://none/x"]],
    ["refused, then the release", ["https://bad/x", "https://good/x"]],
    ["there already", ["https://bad/x"]],
  ];
  const tsDir = join(fresh("release-ts"), "cache", "farview", "f23232277581-darwin-arm64");
  const mbDir = join(fresh("release-mb"), "cache", "farview", "f23232277581-darwin-arm64");
  const tsAsked: string[] = [];
  p.world = (call, _inst, args) => (call === "fetch" ? (served[args[0]]?.toString("base64") ?? null) : null);
  for (const [what, sources] of cases) {
    const a = await outcome(() => unpackRelease(tsDir, "darwin-arm64", release, sources, async (url) => (tsAsked.push(url), served[url] ? new Uint8Array(served[url]!) : null)));
    const b = await mbOutcome(() => p.cmd("unpack", { dir: mbDir, target: "darwin-arm64", release, sources }));
    assert.deepEqual(b, a, what);
    assert.deepEqual(filesOf(join(mbDir, "..")), filesOf(join(tsDir, "..")), `${what}: what is kept`);
  }
  assert.deepEqual(p.entries.filter((e) => e[0] === "fetch").map((e) => e[1]), tsAsked, "what each asked for");
});
