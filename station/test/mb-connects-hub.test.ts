// The connects' hub in MoonBit (station/mb src/connects_hub, `stillfail-reader-harness --builder harness-connects-hub`) held to the
// TypeScript it is written from (src/connects/*, src/group/*): each case run by both, on twins of one world made the
// same way (a station's config.json, its store and hub, the mesh between stations, the files, a clock of the test's),
// and the answers, what each asked of its world in order, what each wrote in its data directory, and its log the same.
// The program asks its world line by line (`{call, args, cid}`, answered `{re}`), the TypeScript is given functions that
// ask the same world: so both are asked the same questions, and the test answers them alike.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { appendFile, mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { extname, join, relative } from "node:path";
import { createInterface } from "node:readline";
import { after, mock, test } from "node:test";
import { Clock, Effect, Exit, Layer, Scope } from "effect";
import { mbHarnessBinary } from "./mb-harness.ts";
import { setStationLang } from "../src/ops/i18n.ts";
import { log as stationLog } from "../src/ops/log.ts";
import { Refused as Declined, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { oneBytes } from "../src/mesh/files.ts";
import { Refused } from "../src/api/request.ts";
import { NAMES_FILE, channelKey, personKey } from "../src/connects/keys.ts";
import { StatusLine } from "../src/connects/status.ts";
import { NameBook } from "../src/connects/names.ts";
import { type Connection, Connections, shownIdentity } from "../src/connects/connections.ts";
import { makeConnects } from "../src/connects/connects.ts";
import { cardsEnded, endedWords, showEnded } from "../src/connects/card-ends.ts";
import { ConnectedSurface } from "../src/connects/surface.ts";
import { RemoteConnects, answerCall, connectOf, describe, knownIn, knownOf, localOf, readRemote, threadOfEvent } from "../src/connects/remote.ts";
import { WorkspaceConnects, fingerprint } from "../src/connects/workspace.ts";
import { codeHash, deviceOf, groupConnects, makeGroup } from "../src/group/index.ts";
import { GroupThreads } from "../src/group/threads.ts";
import { GroupLink, SseLines } from "../src/group/link.ts";
import { GroupSurface, cardWords, decisionBody, imageSize, mentions, streamKey, streamOf, threadOf } from "../src/group/surface.ts";
import { Hlc, canonicalJson, deviceOfKey, directId, eventId, eventOf, isSpaceId, isTopicId, moonOrder, signEvent, signingKey, stampedOf, verified } from "../src/group/event.ts";
import { segment, input as requestInput, percentDecode } from "../src/api/request.ts";
import { unanswered } from "../src/ops/unanswered.ts";
import { testClock } from "./hub-fakes.ts";
import { memoryMesh } from "./memory-mesh.ts";
import { ImServer } from "./group-im.ts";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

type Json = any;
const dirs: string[] = [];
const fresh = (prefix: string) => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
};
const wire = (v: unknown): Json => (v === undefined ? null : JSON.parse(JSON.stringify(v) ?? "null"));
const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const UNREACHED = ["ECONNREFUSED", "ECONNRESET", "ECONNABORTED", "ENOTFOUND", "EAI_AGAIN", "ETIMEDOUT", "EHOSTUNREACH", "ENETUNREACH", "EPIPE"];

/// What an error is told as on the program's lines: its kind (the code of an error a socket gave, a refusal's status,
/// a station's refusal) and its message.
export function kindOf(e: unknown): string {
  if (!(e instanceof Error)) return "";
  if (e instanceof Refused) return `Refused:${e.status}`;
  if (e instanceof Declined) return "Declined";
  const code = (e as { code?: unknown }).code;
  if (typeof code === "string" && UNREACHED.includes(code)) return code;
  if (e.constructor.name === "GroupRefused") return `GroupRefused:${(e as unknown as { why: string }).why}`;
  if (e.constructor.name === "GroupUnreached") return "EHOSTUNREACH";
  if (e.name === "TimeoutError") return "TimeoutError";
  return code === "ENOENT" ? "ENOENT" : "";
}

/// An error made of what a world's script throws (`{throw, code?}`), as each side is to see it.
const thrown = (t: Json): Error => {
  if (t.declined) return new Declined(t.throw);
  if (t.status) return new Refused(t.status, t.throw);
  return Object.assign(new Error(t.throw), t.code ? { code: t.code } : {});
};
const wireKind = (t: Json): string => (t.declined ? "Declined" : t.status ? `Refused:${t.status}` : (t.code ?? ""));

/// What the world answers, the same for both: a value, `{throw}` thrown, or a promise the test resolves later.
type Script = (name: string, args: Json[], side: "ts" | "mb") => Json;

/// What each side asked of its world, in order, and what it noted (its log, its listeners heard).
class Record {
  said: [string, Json][] = [];
  push(name: string, args: Json[]) {
    this.said.push([name, wire(args)]);
  }
}

/// The program, its cases asked side by side, its asks of the world answered by `world`.
class Program {
  #child: ChildProcess;
  #cases = new Map<number, (v: Json) => void>();
  #next = 0;
  traffic = 0;
  world: (name: string, args: Json[]) => Promise<Json> = async (n) => { throw new Error(`no world to ask ${n}`); };
  note: (name: string, args: Json[]) => void = () => {};
  constructor() {
    this.#child = spawn(binary!, ["--builder", "harness-connects-hub", "--shell-dir", fresh("connects-hub-shell-")], { stdio: ["pipe", "pipe", "inherit"] });
    createInterface({ input: this.#child.stdout! }).on("line", (line) => this.#heard(JSON.parse(line)));
    this.#child.on("exit", (code, signal) => {
      if (!this.#closing) console.error(`the program ended: ${code ?? signal}`);
    });
  }
  #closing = false;
  #say(v: Json) {
    if (this.#closing) return;
    if ("re" in v) this.#answered++;
    this.#child.stdin!.write(`${JSON.stringify(v)}\n`);
  }
  #heard(said: Json) {
    this.traffic++;
    if (typeof said.note === "string") return this.note(said.note, said.args);
    if (typeof said.call === "string") {
      const answered = this.world(said.call, said.args).then(
        (v) => this.#say({ re: said.cid, result: wire(v) }),
        (e) => this.#say({ re: said.cid, threw: e instanceof Error ? e.message : String(e), kind: (e as Json)?.wireKind ?? kindOf(e) }),
      );
      // (a file's: answered once its disk is done with it, never held back by a test as an ask of a peer may be)
      if (said.call.startsWith("fs.")) {
        this.#answering.add(answered);
        void answered.finally(() => this.#answering.delete(answered));
      }
      return;
    }
    const answer = this.#cases.get(said.id);
    this.#cases.delete(said.id);
    answer?.(said);
  }
  /// A case, answered `{ok}` or `{error, kind}`.
  ask(v: Json): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve) => {
      this.#cases.set(id, resolve);
      this.#say({ ...v, id });
    });
  }
  /// A case's answer, or what it threw thrown here.
  async ok(v: Json): Promise<Json> {
    const got = await this.ask(v);
    if ("error" in got) throw Object.assign(new Error(got.error), { kind: got.kind });
    return got.ok;
  }
  /// What the program asked of the files and the test has not answered yet (a file removed, written, read).
  #answering = new Set<Promise<void>>();
  /// The answers written to the program so far, of any call.
  #answered = 0;
  /// Until the program, and what the test answers it, are at rest: what it asked answered too (a fiber of the
  /// program's waiting on the test's answer is no work of its own to settle, and the file it asked to remove was still
  /// there as the test looked, 2026-11-17).
  /// An answer written after the ask to settle reaches the program after it: it said it was at rest before that
  /// answer woke what waited on it, and what that does next it says after, in its own time; so it is asked again
  /// (a peer's answer heard in the same read as a case's answer, written after the settle the case's caller asked,
  /// check-station on #7023 and #6966, 2026-11-17).
  async settle() {
    for (;;) {
      while (this.#answering.size > 0) await Promise.all([...this.#answering]);
      const before = this.traffic;
      const answered = this.#answered;
      await this.ask({ op: "settle" });
      for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
      if (this.traffic === before + 1 && this.#answering.size === 0 && this.#answered === answered) return;
    }
  }
  close(): Promise<void> {
    this.#closing = true;
    return ended(this.#child);
  }
}

/// A child let go: its stdin ended, and waited for until it is gone (killed 2 s after where it is not).
function ended(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  const gone = new Promise<void>((r) => child.once("exit", () => r()));
  child.stdin?.end();
  setTimeout(() => child.kill("SIGKILL"), 2000).unref();
  return gone;
}

let program: Program | null = null;
const mb = async () => {
  if (program === null) {
    program = new Program();
    await program.ok({ op: "env", words: { zh: zhStation, en: enStation, product: "still.fail" }, lang: "zh" });
  }
  return program;
};
// (the program waited for till it is gone, its directories after: one still running at the file's end is a leftover)
after(async () => {
  await program?.close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// The program's clock: the time it is told, and its waits answered once the time passes them.
class MbClock {
  now = 0;
  #sleepers: { due: number; wake: () => void }[] = [];
  readonly p: Program;
  constructor(p: Program) {
    this.p = p;
  }
  sleep(ms: number): Promise<void> {
    // (as a TestClock's: what is due already goes at once)
    if (ms <= 0) return Promise.resolve();
    return new Promise((wake) => this.#sleepers.push({ due: this.now + ms, wake }));
  }
  async advance(ms: number) {
    const target = this.now + ms;
    for (;;) {
      await this.p.settle();
      this.#sleepers.sort((a, b) => a.due - b.due);
      const next = this.#sleepers[0];
      if (next === undefined || next.due > target) break;
      this.#sleepers.shift();
      if (next.due > this.now) {
        this.now = next.due;
        await this.p.ok({ op: "clock", now: this.now });
      }
      next.wake();
    }
    if (target > this.now) {
      this.now = target;
      await this.p.ok({ op: "clock", now: this.now });
    }
    await this.p.settle();
  }
}

/// The log of the station, as each side writes it.
function logTo(record: Record) {
  const levels = ["info", "warn", "error"] as const;
  const mocks = levels.map((level) => mock.method(stationLog, level, (part: string, words: string, fields?: Json) => record.push("log", [level, part, words, fields ?? {}])));
  return () => {
    for (const m of mocks) m.mock.restore();
  };
}

/// The program's files: its own directory, as node:fs keeps it.
async function mbFs(name: string, args: Json[]): Promise<Json> {
  const [p, b] = args as [string, string];
  const enoent = (e: Json) => {
    throw Object.assign(new Error(e.message), { wireKind: e.code === "ENOENT" ? "ENOENT" : "" });
  };
  switch (name) {
    case "fs.read":
      return readFile(p, "utf8").catch(enoent);
    case "fs.readBytes":
      return (await readFile(p).catch(enoent)).toString("hex");
    case "fs.size":
      return (await stat(p).catch(enoent)).size;
    case "fs.write":
      return writeFile(p, b);
    case "fs.writeBytes":
      return writeFile(p, Buffer.from(b, "hex"));
    case "fs.append":
      return appendFile(p, b);
    case "fs.rename":
      return rename(p, b);
    case "fs.rm":
      return rm(p, { recursive: true, force: true });
    case "fs.mkdir":
      return mkdir(p, { recursive: true });
    case "fs.readdir":
      return readdir(p).catch(enoent);
    case "fs.writePrivate":
      await mkdir(join(p, ".."), { recursive: true });
      return writeFile(p, b, { mode: 0o600 });
  }
  throw new Error(`no such file call ${name}`);
}

/// A directory's files and what they hold, by their paths in it (`dir` said as `<data>` in them).
async function tree(dir: string, top = dir): Promise<Record_> {
  const out: Record_ = {};
  for (const e of await readdir(dir, { withFileTypes: true }).catch(() => [])) {
    const p = join(dir, e.name);
    if (e.isDirectory()) Object.assign(out, await tree(p, top));
    else out[relative(top, p)] = (await readFile(p, "utf8")).split(top).join("<data>");
  }
  return out;
}
type Record_ = { [k: string]: string };

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;
/// What was asked and said, the data directories said as `<data>`, a UUID as any.
function norm(v: Json, dirs_: string[]): Json {
  let text = JSON.stringify(v);
  for (const d of dirs_) text = text.split(d).join("<data>");
  return notJson(JSON.parse(text.replace(UUID, "<uuid>")));
}
/// What JSON.parse says of text that is not JSON is V8's words; the program's are its own: both said as `<not JSON>`.
const NOT_JSON = /is not valid JSON|Unexpected end of JSON input|in JSON at position|^unexpected input at \d+$|^Unexpected token/;
function notJson(v: Json): Json {
  if (typeof v === "string") return NOT_JSON.test(v) ? "<not JSON>" : v;
  if (Array.isArray(v)) return v.map(notJson);
  if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, notJson(x)]));
  return v;
}

/// Twins of one world: the TypeScript's and the program's, each recording what it asked; `script` answers both.
class Twins {
  ts = new Record();
  mb = new Record();
  tsDir = fresh("connects-hub-ts-");
  mbDir = fresh("connects-hub-mb-");
  time = testClock();
  clock: MbClock;
  #restoreLog: () => void;
  script: Script = () => null;
  /// Notes of the program's own machinery (a mesh connection closed), done rather than compared: whether it was one.
  ownNote: (name: string, args: Json[]) => boolean = () => false;
  /// Names the program's world answers itself (the program's own machinery), not compared.
  own: (name: string, args: Json[]) => Promise<Json> | undefined = () => undefined;
  readonly p: Program;
  readonly files: { writing: () => boolean; written: () => Promise<unknown> }[] = [];
  constructor(p: Program) {
    this.p = p;
    this.clock = new MbClock(p);
    this.#restoreLog = logTo(this.ts);
    p.note = (name, args) => (this.ownNote(name, args) ? undefined : this.mb.push(name, args));
    p.world = async (name, args) => {
      if (name.startsWith("fs.")) return mbFs(name, args);
      if (name === "clock.sleep") return this.clock.sleep(args[0]);
      const own = this.own(name, args);
      if (own !== undefined) return own;
      this.mb.push(name, args);
      return this.answer(name, args, true);
    };
  }
  /// What the script answers `name`, as the side asking takes it.
  async answer(name: string, args: Json[], forMb: boolean): Promise<Json> {
    const v = await this.script(name, args, forMb ? "mb" : "ts");
    if (v !== null && typeof v === "object" && "throw" in v) {
      const e = thrown(v);
      if (forMb) Object.assign(e, { wireKind: wireKind(v) });
      throw e;
    }
    return v;
  }
  /// The TypeScript's ask of its world.
  tsAsk = (name: string, args: Json[]): Promise<Json> => {
    this.ts.push(name, args);
    return this.answer(name, args, false);
  };
  async both(ms: number) {
    await this.time.adjust(ms);
    await this.clock.advance(ms);
    await this.rest();
  }
  /// Both sides at rest.
  async rest() {
    for (;;) {
      await this.p.settle();
      const said = this.ts.said.length;
      await Promise.all(this.files.map((f) => f.written()));
      for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
      if (said === this.ts.said.length && this.files.every((f) => !f.writing())) return;
    }
  }
  /// Both sides at rest, and what each asked the same.
  /// What each side's own says differently (its bot's id, its key), said alike.
  alias: { ts: [string, string][]; mb: [string, string][] } = { ts: [], mb: [] };
  aliased(v: Json, side: "ts" | "mb"): Json {
    let text = JSON.stringify(v);
    for (const [a, b] of this.alias[side]) text = text.split(a).join(b);
    return JSON.parse(text);
  }
  async same(what: string) {
    await this.rest();
    assert.deepEqual(this.aliased(norm(this.mb.said, [this.mbDir]), "mb"), this.aliased(norm(this.ts.said, [this.tsDir]), "ts"), what);
    // (each check is of what was asked since the one before)
    this.mb.said = [];
    this.ts.said = [];
  }
  /// The files each wrote the same (`flushed`: once what the TypeScript has on its way is written).
  /// The same, in whatever order: what flows that go on side by side asked (a learning and a write of the config),
  /// each in its own order on its side.
  async sameUnordered(what: string) {
    await this.rest();
    const sorted = (v: Json[]) => v.map((x) => JSON.stringify(x)).sort();
    assert.deepEqual(sorted(this.aliased(norm(this.mb.said, [this.mbDir]), "mb")), sorted(this.aliased(norm(this.ts.said, [this.tsDir]), "ts")), what);
    this.mb.said = [];
    this.ts.said = [];
  }
  async sameFiles(what: string, flushed: () => Promise<unknown> = async () => {}) {
    await this.rest();
    await flushed();
    await this.rest();
    assert.deepEqual(this.aliased(norm(await tree(this.mbDir), []), "mb"), this.aliased(norm(await tree(this.tsDir), []), "ts"), what);
  }
  done() {
    this.#restoreLog();
    this.p.note = () => {};
  }
}
/// Twins on a clock at 0 for both.
async function twins(p: Program): Promise<Twins> {
  await p.ok({ op: "clock", now: 0 });
  return new Twins(p);
}

test("twins wait for a delayed TypeScript file write", async () => {
  const w = new Twins({ settle: async () => {} } as unknown as Program);
  try {
    let pending = true;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const file = join(w.tsDir, "delayed.txt");
    const written = (async () => {
      await gate;
      await writeFile(file, "written");
      pending = false;
    })();
    w.files.push({ writing: () => pending, written: () => written });
    let settled = false;
    const resting = w.rest().then(() => { settled = true; });
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));
    assert.equal(settled, false);
    release();
    await resting;
    assert.equal(await readFile(file, "utf8"), "written");
  } finally {
    w.done();
  }
});

/// A TypeScript function's answer as the program says it: `{ok}` or `{error, kind}`.
async function settled(f: () => unknown): Promise<Json> {
  try {
    return { ok: wire(await f()) };
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e), kind: kindOf(e) };
  }
}

/// Both answer the same: the program's case `v`, the TypeScript's `f`.
async function same(p: Program, what: string, f: () => unknown, v: Json) {
  const want = await settled(f);
  const got = await p.ask(v);
  delete got.id;
  if ("error" in want) assert.deepEqual({ error: got.error, kind: got.kind }, want, what);
  else assert.deepEqual(got, want, what);
}

const fn = (p: Program, name: string, f: () => unknown, ...args: Json[]) => same(p, `${name}(${JSON.stringify(args).slice(0, 200)})`, f, { op: "fn", name, args: wire(args) });

/// A surface as a test's snapshot says it (`{has, get, mention, link}`), its calls asked of the world (`chat.call`), as
/// the program's harness makes one of the same snapshot.
function snapSurface(id: string, snap: Json, ask: (name: string, args: Json[]) => Promise<Json>, record?: Record): Json {
  const has = new Set<string>(snap.has ?? []);
  const values = snap.get ?? {};
  const s: Json = {
    botUserId: () => values.botUserId,
    workspace: () => values.workspace,
    post: (...a: Json[]) => ask("chat.call", [id, "post", a]),
  };
  for (const name of has) {
    if (name === "cards") s.cards = true;
    else if (name === "loginCards") s.loginCards = true;
    else if (name === "mention") s.mention = (u: string) => `${snap.mention?.[0] ?? ""}${u}${snap.mention?.[1] ?? ""}`;
    else if (name === "sessionLink") s.sessionLink = (u: string, l: string) => (typeof snap.link === "string" ? snap.link.replace("\u0001", u).replace("\u0002", l) : null);
    else if (["knownPerson", "knownChannel", "working", "standsAt"].includes(name))
      s[name] = (...a: Json[]) => {
        record?.push("chat.get", [id, name, a]);
        return values[name];
      };
    else if (name in values) s[name] = () => values[name];
    else s[name] = (...a: Json[]) => ask("chat.call", [id, name, a]);
  }
  return s;
}

// ── pure ─────────────────────────────────────────────────────────────────────────────────────────────────────────

test("keys, the workspace's names of a connect, a thread's event", { skip }, async () => {
  const p = await mb();
  for (const [a, b] of [["T1", "U1"], ["g", "m:x"], ["", ""], ["T 1", "😀"]]) {
    await fn(p, "personKey", () => personKey(a!, b!), a, b);
    await fn(p, "channelKey", () => channelKey(a!, b!), a, b);
  }
  for (const k of ["slack", "feishu", "comma", "group", "other"]) await fn(p, "namesFile", () => (NAMES_FILE as Json)[k] ?? null, k);
  for (const [k, here] of [[{ id: "cl", origin: "H" }, "H"], [{ id: "cl", origin: "H" }, "S"], [{ id: "a@b", origin: "c" }, "x"]] as const) await fn(p, "localOf", () => localOf(k, here), k, here);
  for (const id of ["cl", "cl@H", "a@b@c", "@x", "x@", "@", "", "😀@é"]) await fn(p, "knownOf", () => knownOf(id, "HERE"), id, "HERE");
  for (const v of [{ id: "a", origin: "b" }, { id: "", origin: "b" }, { id: "a" }, null, "x", { id: 1, origin: "b" }, { id: "a", origin: "b", more: 1 }]) await fn(p, "knownIn", () => knownIn(v), v);
  for (const e of [
    { type: "message", message: { channel: "C1", threadTs: "1.1", ts: "1.2", user: "U", text: "hi" } },
    { type: "changed", channel: "C2", threadTs: "2.2", ts: "2.3", text: "x" },
    { type: "action", channel: "C3" },
  ]) await fn(p, "threadOfEvent", () => threadOfEvent(e as Json), e);
  const described = { kind: "slack", workspace: "ws", mode: "multi-session", requireMention: true, botNameSaid: "Bot", bind: { runtime: "claude", model: "opus" }, botUserId: "UB", botName: "B", identity: null, platform: "slack", team: "T1", cards: true, loginCards: false, mention: ["<@", ">"], link: null, has: [] };
  await fn(p, "connectOf", () => connectOf("cl@H", described as Json), "cl@H", described);
  await fn(p, "connectOf", () => connectOf("x", { ...described, bind: { runtime: "codex", effort: "high" }, botNameSaid: undefined } as Json), "x", { ...described, bind: { runtime: "codex", effort: "high" }, botNameSaid: undefined });
  for (const [kind, own] of [["slack", { botToken: "xoxb-1" }], ["feishu", { appId: "cli_1" }], ["comma", { token: "t" }], ["group", { key: "ab" }], ["slack", {}], ["slack", null], ["feishu", { appId: "" }], ["slack", { botToken: 5 }]] as const) {
    await fn(p, "fingerprint", () => fingerprint(kind, own), kind, own);
  }
  for (const i of [{ team: "T", teamId: "T1", url: "https://x/", botUserId: "U", botName: "B", botImage: null, botId: "B1" }, { teamId: "T1" }]) await fn(p, "shownIdentity", () => shownIdentity(i as Json), i);
});

test("a connect described to another station, as its surface says it", { skip }, async () => {
  const p = await mb();
  const connects = [
    { id: "cl", kind: "slack", mode: "multi-session", requireMention: true, slack: { botName: "Claude" }, bind: { runtime: "claude", model: "opus", effort: "high" } },
    { id: "fs", kind: "feishu", mode: "single-session", requireMention: false, slack: {}, bind: { runtime: "codex", model: "", effort: undefined } },
  ];
  const snaps = [
    { has: ["cards", "mention", "sessionLink", "botName", "identity", "platform", "download", "userName", "working", "api", "history"], get: { botUserId: "UB", workspace: "T1", botName: "Claude", identity: { team: "Acme", teamId: "T1" }, platform: "slack" }, mention: ["<@", ">"], link: "<\u0001|\u0002>" },
    { has: ["loginCards", "mention", "sessionLink"], get: { botUserId: "ou_1", workspace: null }, mention: ["@", ""], link: null },
    { has: [], get: { botUserId: "", workspace: null } },
    { has: ["mention"], get: { botUserId: "x" }, mention: ["", ""] },
  ];
  for (const c of connects) for (const snap of snaps) {
    await fn(p, "describe", () => describe(c as Json, "ws", snapSurface("", snap, async () => null)), c, "ws", snap);
  }
});

test("ended cards' words, a request's segment and body", { skip }, async () => {
  const p = await mb();
  for (const lang of ["zh", "en"] as const) {
    for (const card of [{ type: "options" }, { type: "text" }, null]) {
      for (const end of [{ why: "message", by: "U", byTs: "1" }, { why: "replaced" }, { why: "withdrawn" }, { why: "closed" }]) {
        for (const name of ["Ada", "", null]) await fn(p, "endedWords", () => endedWords(card, end as Json, name, lang), card, end, name, lang);
      }
    }
  }
  for (const s of ["cl", "a%20b", "a+b", "%E4%BD%A0", "%zz", "%", "%4", "x%2Fy", "%C3%28", "%EF%BB%BFa"]) {
    await fn(p, "segment", () => segment(s), s);
    await fn(p, "percentDecode", () => percentDecode(s), s);
  }
  for (const body of ["", "{\"station\":\"S\"}", "[1]", "nope", "null", "\"s\"", "x".repeat(1_000_001)]) {
    await fn(p, "input", () => requestInput({ body: Buffer.from(body) } as Json), body);
  }
});

test("the group connects' config, codes, devices, words and pictures", { skip }, async () => {
  const p = await mb();
  const raws = [
    { connects: [{ id: "g", kind: "group", group: { server: " ABCD ", relays: [" https://r ", "", 5, "https://s"], key: "k", code: " C-1 ", bound: "", botName: " Bot ", memberId: null, name: "n" }, workspace: " ws " }] },
    { connects: [{ kind: "group" }, { id: 5, kind: "group", enabled: false, group: null }, { id: "s", kind: "slack" }, null] },
    { connects: "no" },
    {},
  ];
  for (const raw of raws) await fn(p, "groupConnects", () => groupConnects(raw), raw);
  for (const code of ["abcd-efgh", "ABCD EFGH", "ab\tcd ef　gh", "straße", "ç-é", "", "ǆ"]) await fn(p, "codeHash", () => codeHash(code), code);
  for (const key of ["11".repeat(32), "ab".repeat(32), "AB".repeat(32), "12", ""]) await fn(p, "deviceOf", () => deviceOf(key), key);
  const cases: [string, string][] = [
    ["@Claude hi", "Claude"], ["hi @claude", "Claude"], ["@Claudebot", "Claude"], ["x@Claude", "Claude"], ["(@Claude)", "Claude"], ["@Claude_", "Claude"],
    ["@Claude.", "Claude"], ["", "Claude"], ["@", ""], ["@Clau de", "Clau de"], ["@a.b", "a.b"], ["@Ünï", "üNÏ"], ["@ſam", "sam"], ["@samſ", "sam"], ["@克劳德", "克劳德"], ["é@Claude", "Claude"],
  ];
  for (const [t, n] of cases) await fn(p, "mentions", () => mentions(t, n), t, n);
  for (const lang of ["zh", "en"] as const) {
    for (const [text, card] of [
      ["Pick one  \n", { type: "options", options: [{ label: "A" }, { label: "" }, { label: 3 }, {}, null] }],
      ["\n\nWhat?", { type: "text" }],
      ["", { type: "options", options: [] }],
      ["Plain", null],
      ["Pick", { type: "options", options: "x" }],
    ] as const) await fn(p, "cardWords", () => cardWords(text, card, lang), text, card, lang);
  }
  const png = (w: number, h: number) => Buffer.from([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, w >>> 24, (w >> 16) & 255, (w >> 8) & 255, w & 255, h >>> 24, (h >> 16) & 255, (h >> 8) & 255, h & 255, 8, 6, 0, 0, 0]);
  const gif = (w: number, h: number) => Buffer.from([...Buffer.from("GIF89a"), w & 255, w >> 8, h & 255, h >> 8, 0, 0]);
  const webp = (kind: string, rest: number[]) => Buffer.from([...Buffer.from("RIFF"), 0, 0, 0, 0, ...Buffer.from("WEBP"), ...Buffer.from(kind), ...rest]);
  const jpeg = (w: number, h: number) => Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 4, 1, 2, 0xff, 0xff, 0xc4, 0, 3, 9, 0xff, 0xc0, 0, 11, 8, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 1, 1, 0xff, 0xd9]);
  const pics = [png(1920, 1080), png(0, 1), png(4294967295, 2), gif(640, 480), gif(0, 3), jpeg(4032, 3024), jpeg(4032, 3024).subarray(0, 20), Buffer.from([0xff, 0xd8, 0xff, 0xda]),
    webp("VP8 ", [0, 0, 0, 0, 0, 0, 0, 0x9d, 0x01, 0x2a, 0x20, 0x03, 0x58, 0x02, 0, 0]), webp("VP8L", [0, 0, 0, 0, 0x2f, 0x1f, 0xc0, 0x15, 0xff, 0, 0, 0, 0, 0]), webp("VP8X", [0, 0, 0, 0, 0, 0, 0, 0, 0x7f, 0x02, 0, 0xdf, 0x01, 0, 0]),
    Buffer.from([1, 2, 3]), Buffer.alloc(0)];
  for (const b of pics) await fn(p, "imageSize", () => imageSize(b), hex(b));
  for (const name of ["a.PNG", "x.tar.gz", ".png", "noext", "a/b.c/d", "doc.md", "a.", "film.MOV"]) {
    const mimeOf = (n: string) => {
      const m: Json = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml", ".pdf": "application/pdf", ".txt": "text/plain", ".md": "text/markdown", ".json": "application/json", ".csv": "text/csv", ".html": "text/html", ".mp4": "video/mp4", ".mov": "video/quicktime", ".webm": "video/webm", ".mp3": "audio/mpeg", ".zip": "application/zip" };
      return m[extname(n).toLowerCase()] ?? "application/octet-stream";
    };
    await fn(p, "mimeOf", () => mimeOf(name), name);
  }
  for (const [code, msg] of [["ECONNREFUSED", "x"], ["EPIPE", "y"], ["TimeoutError", "t"], ["", "fetch failed"], ["ENOENT", "z"], ["GroupRefused:x", "r"]] as const) {
    const e = code === "TimeoutError" ? Object.assign(new Error(msg), { name: "TimeoutError" }) : Object.assign(new Error(msg), { code });
    await fn(p, "unanswered", () => unanswered(e), code, msg);
  }
});

test("the group's event stream read piece by piece", { skip }, async () => {
  const p = await mb();
  const text = "event: message\ndata: {\"a\":1}\nid: 7\n\n: a comment\n\nevent: member\ndata: 你好\ndata: 😀 two\n\nid: 9\n\ndata: plain\n\nretry: 5\n\nfield\n\nevent:x\ndata:  sp\n\n";
  const bytes = Buffer.from(text);
  for (const cut of [1, 2, 3, 5, 7, 64, bytes.length]) {
    const ts = new SseLines();
    const h = await p.ok({ op: "sse.new" });
    for (let i = 0; i < bytes.length; i += cut) {
      const piece = bytes.subarray(i, i + cut);
      assert.deepEqual(await p.ok({ op: "sse.feed", h, args: [hex(piece)] }), wire(ts.feed(piece)), `cut ${cut} at ${i}`);
    }
  }
});

// ── status lines ─────────────────────────────────────────────────────────────────────────────────────────────────

test("a status line: changed at most once an interval, in order, the latest only", { skip }, async () => {
  const p = await mb();
  const w = await twins(p);
  try {
    // (one not shown: "b")
    w.script = (name, args) => (name === "status.show" ? args[1] !== "b" : null);
    class Line extends StatusLine {
      readonly h: number;
      constructor(h: number) {
        super((e) => Effect.runPromise(e.pipe(Effect.provideService(Clock.Clock, w.time.clock))), 1000);
        this.h = h;
      }
      protected async show(status: string, now: number) {
        return (await w.tsAsk("status.show", [this.h, status, now, this.messageTs, this.page])) === true;
      }
    }
    const h = await p.ok({ op: "status.new", interval: 1000 });
    const line = new Line(h);
    const say = async (status: string, messageTs: string | null = null, page: string | null = null) => {
      line.say(status, messageTs, page);
      await p.ok({ op: "status.say", h, status, messageTs, page });
    };
    await say("reading", "1.1", "https://p");
    await w.same("the first change goes at once");
    await say("writing");
    await say("testing");
    await w.both(500);
    await w.same("none within the interval");
    await w.both(500);
    await w.same("the latest after it");
    for (const s of ["a", "b", "c", "d"]) {
      await say(s);
      await w.both(1000);
    }
    await say("", "2.2");
    await w.same("cleared at once, one not shown tried again with the next");
    await w.both(5000);
    await say("again");
    await w.same("after a while, at once again");
  } finally {
    w.done();
  }
});

// ── the names book ───────────────────────────────────────────────────────────────────────────────────────────────

test("the names book: what is known at once, the rest learned in the background and kept", { skip }, async () => {
  const p = await mb();
  for (const kept of [null, "{\"u:T:U1\":{\"person\":{\"name\":\"Ada\",\"email\":\"a@x\"},\"at\":5},\"c:T:C1\":{\"channel\":null,\"at\":1},\"9\":{\"at\":2}}", "not json", "[1]", "null", "{\"u:T:U9\":{\"person\":null,\"at\":\"x\"}}"]) {
    const w = await twins(p);
    try {
      // (what the platform says of each, by when it is asked: the clock's time)
      const asked = { ts: new Map<string, number>(), mb: new Map<string, number>() };
      w.script = (name, args, side) => {
        const key_ = `${name} ${args[1]}`;
        const now = (asked[side].get(key_) ?? 0) + 1;
        asked[side].set(key_, now);
        if (name === "names.fetch") {
          const key = args[1] as string;
          if (key.endsWith("bad")) return { throw: "lookup failed" };
          if (key.endsWith("none")) return null;
          return { name: `N-${key}-${now}`, email: "", ...(key.includes("pic") ? { picture: "https://p" } : {}) };
        }
        if (name === "names.fetchChannel") return (args[1] as string).endsWith("dm") ? null : (args[1] as string).endsWith("bad") ? { throw: "no" } : `chan-${args[1]}-${now}`;
        return null;
      };
      const path = (dir: string) => join(dir, "slack-names.json");
      if (kept !== null) {
        await writeFile(path(w.tsDir), kept);
        await writeFile(path(w.mbDir), kept);
      }
      const book = new NameBook(path(w.tsDir), { saveAfterMs: 300, learnAfterMs: 100, clock: w.time.clock });
      w.files.push((book as Json).file);
      const h = await p.ok({ op: "names.open", path: path(w.mbDir), saveAfterMs: 300, learnAfterMs: 100 });
      await w.same(`opened on ${kept}`);
      book.onLearn(() => w.ts.push("names.learned", [h]));
      await p.ok({ op: "names.onLearn", h });
      const person = async (key: string, stale: Json = null) => {
        const staleFn = stale === null ? undefined : stale.olderThan !== undefined ? (_: Json, age: number) => age > stale.olderThan : stale.noPicture ? (k: Json) => k.picture === undefined : (k: Json) => k.name !== stale.nameNot;
        await same(p, `person ${key}`, () => book.person(key, () => w.tsAsk("names.fetch", [h, key]), staleFn), { op: "names.person", h, key, stale });
        await w.rest();
      };
      const channel = async (key: string) => {
        await same(p, `channel ${key}`, () => book.channel(key, () => w.tsAsk("names.fetchChannel", [h, key])), { op: "names.channel", h, key });
        await w.rest();
      };
      for (const k of ["u:T:U1", "u:T:U2", "u:T:bad", "u:T:none", "u:T:pic", "u:T:U9"]) await person(k);
      for (const k of ["c:T:C1", "c:T:C2", "c:T:dm", "c:T:bad"]) await channel(k);
      await w.same("each looked up once");
      await person("u:T:U2");
      await w.both(100);
      await w.same("told once per burst");
      for (const k of ["u:T:U1", "u:T:U2", "u:T:bad", "u:T:pic"]) await person(k, { olderThan: 50 });
      await person("u:T:U2", { noPicture: true });
      await person("u:T:pic", { noPicture: true });
      await person("u:T:U1", { nameNot: "Ada" });
      await person("u:T:U1", { nameNot: "Bo" });
      await w.both(300);
      await w.same("stale ones again, failed ones not");
      await w.sameFiles("kept on disk", () => (book as Json).file.written());
      await w.both(600_000);
      await person("u:T:bad");
      await channel("c:T:bad");
      await w.both(10);
      await w.same("failed ones again after ten minutes");
      await person("u:T:late");
      await w.rest();
      await book.close();
      await p.ok({ op: "names.close", h });
      await person("u:T:after");
      await w.same("closed: saved, nothing learned after");
      await w.sameFiles("saved as it closed", () => (book as Json).file.written());
    } finally {
      w.done();
    }
  }
});

// ── a platform's connections ─────────────────────────────────────────────────────────────────────────────────────

/// A connection of the test's for the TypeScript (connections.ts `Connection`), as the program's harness keeps one.
class FakeConnection {
  bot = "";
  sock: Json = { connected: false, lastError: null };
  me: Json = null;
  handler: ((e: Json) => Promise<void>) | null = null;
  listeners = new Set<() => void>();
  cards = true;
  readonly h: number;
  readonly ask: (name: string, args: Json[]) => Promise<Json>;
  readonly record: Record;
  constructor(h: number, ask: (name: string, args: Json[]) => Promise<Json>, record: Record) {
    this.h = h;
    this.ask = ask;
    this.record = record;
  }
  botUserId() { return this.bot; }
  identity() { return this.me; }
  socket() { return this.sock; }
  workspace() { return null; }
  async start(handler: (e: Json) => Promise<void>) {
    this.handler = handler;
    await this.ask("conn.start", [this.h]);
  }
  async stop() { await this.ask("conn.stop", [this.h]); }
  onChange(f: () => void) {
    this.listeners.add(f);
    return () => this.listeners.delete(f);
  }
  async refreshIdentity() { await this.ask("conn.refreshIdentity", [this.h]); }
  post(...a: Json[]) { return this.ask("conn.call", [this.h, "post", a]); }
  cardEnded(...a: Json[]) { return this.ask("conn.call", [this.h, "cardEnded", a]); }
  knownPerson(...a: Json[]) { this.record.push("conn.get", [this.h, "knownPerson", a]); return null; }
  knownChannel(...a: Json[]) { this.record.push("conn.get", [this.h, "knownChannel", a]); return null; }
}

/// The connections both sides made, by their handles (each side counts its own the same).
class Conns {
  ts = new Map<number, FakeConnection>();
  readonly w: Twins;
  constructor(w: Twins) {
    this.w = w;
  }
  /// Both told: connection `h` is now `state`, its listeners hear.
  async set(h: number, state: { bot?: string; socket?: Json; identity?: Json }) {
    const c = this.ts.get(h)!;
    if (state.bot !== undefined) c.bot = state.bot;
    if (state.socket !== undefined) c.sock = state.socket;
    if (state.identity !== undefined) c.me = state.identity;
    for (const l of c.listeners) l();
    await this.w.p.ok({ op: "conn.set", c: h, botUserId: state.bot, socket: state.socket, identity: state.identity });
    await this.w.p.ok({ op: "conn.changed", c: h });
  }
  async event(h: number, event: Json) {
    await Promise.all([this.ts.get(h)!.handler!(event), this.w.p.ok({ op: "conn.event", c: h, event })]);
  }
}

test("connections: kept in line with the connects, rapid edits in order, how each stands", { skip }, async () => {
  const p = await mb();
  const w = await twins(p);
  try {
    const conns = new Conns(w);
    let mbN = 0;
    let tsN = 0;
    w.script = (name, args) => {
      if (name === "conn.create") return args[1].id === "bad" ? { throw: "cannot make it" } : ++mbN;
      if (name === "conn.start" && args[0] === 3) return { throw: "refused at start" };
      return null;
    };
    const h = await p.ok({ op: "connections.new", kind: "slack" });
    // (its create, synchronous, says what it was asked as the program asks it)
    const ts = new Connections<Json>("slack", (c) => {
      w.ts.push("conn.create", ["slack", c]);
      if (c.id === "bad") throw new Error("cannot make it");
      const made = new FakeConnection(++tsN, w.tsAsk, w.ts);
      conns.ts.set(made.h, made);
      return made as unknown as Connection;
    }, (connect, event) => w.tsAsk("connections.event", [h, connect, event]).then(() => {}), (c) => (typeof c.token === "string" ? c.token : null));
    ts.onChange(() => w.ts.push("connections.changed", [h]));
    await p.ok({ op: "connections.onChange", h });
    const both = async (what: string, tsF: () => unknown, op: Json) => same(p, what, tsF, { h, ...op });
    const reconcile = (connects: Json[]) => both("reconcile", () => ts.reconcile(connects), { op: "connections.reconcile", connects });
    const state = async (connect: Json) => both(`state ${JSON.stringify(connect)}`, () => ts.state(connect), { op: "connections.state", connect });
    const list = [
      { id: "a", enabled: true, token: "t1" },
      { id: "b", enabled: true, token: "t2" },
      { id: "off", enabled: false, token: "t3" },
      { id: "none", enabled: true },
      { id: "bad", enabled: true, token: "t4" },
      { id: "c", enabled: true, token: "t5" },
    ];
    await reconcile(list);
    await w.same("connected those enabled with tokens, failures kept");
    for (const c of list) await state(c);
    await conns.set(1, { bot: "UA", socket: { connected: true, lastError: null }, identity: { team: "Acme", teamId: "T1", url: "u", botUserId: "UA", botName: "A", botImage: null, botId: "B" } });
    await conns.set(2, { socket: { connected: false, lastError: "down" } });
    for (const c of list) await state(c);
    await conns.event(1, { type: "message", message: { channel: "C", threadTs: "1", ts: "1", user: "U", text: "hi" } });
    await reconcile([{ id: "a", enabled: true, token: "t1" }, { id: "b", enabled: true, token: "t2b" }, { id: "bad", enabled: true, token: "t4" }]);
    await w.same("re-credentialed reconnected, removed disconnected, the rest left");
    await both("ids", () => ts.ids(), { op: "connections.ids" });
    await both("refresh", () => ts.refreshIdentity("a"), { op: "connections.refreshIdentity", who: "a" });
    await Promise.all([ts.reconcile([list[0]!]), ts.stopAll(), ts.reconcile(list), p.ok({ h, op: "connections.reconcile", connects: [list[0]] }), p.ok({ h, op: "connections.stopAll" }), p.ok({ h, op: "connections.reconcile", connects: list })]);
    await w.same("rapid edits in order");
    await both("stop all", () => ts.stopAll(), { op: "connections.stopAll" });
    await w.same("all stopped");
  } finally {
    w.done();
  }
});

// ── a platform's connects ────────────────────────────────────────────────────────────────────────────────────────

/// config.json as the TypeScript's connects edit it, its edits said to the world as the program says its own.
function tsConfig(w: Twins, raw: { v: Json }) {
  const listeners = new Set<() => void>();
  return {
    listeners,
    file: {
      raw: () => raw.v,
      updateSoon: async (f: (raw: Json) => void) => {
        f(raw.v);
        await w.tsAsk("config.updated", [raw.v]);
      },
      listen: (f: () => void) => {
        listeners.add(f);
        return () => listeners.delete(f);
      },
      written: () => w.tsAsk("config.written", []),
    } as Json,
  };
}

/// The generic platform both sides keep connects of (harness.mbt `platform`).
function tsPlatform(w: Twins, conns: Conns, counter: { n: number }) {
  return {
    kind: "slack",
    names: NAMES_FILE.slack,
    connects: (raw: Json) => (Array.isArray(raw?.connects) ? raw.connects : []).filter((c: Json) => (c?.kind ?? "slack") === "slack"),
    credentials: (c: Json) => (typeof c.token === "string" ? c.token : null),
    create: (c: Json) => {
      w.ts.push("conn.create", ["slack", c]);
      if (c.id === "bad") throw new Error("cannot make it");
      const made = new FakeConnection(++counter.n, w.tsAsk, w.ts);
      conns.ts.set(made.h, made);
      return made as unknown as Connection;
    },
    seen: (c: Json, i: Json) => (c.botName === i.botName ? null : (entry: Json) => void (entry.botName = i.botName)),
  };
}

test("a platform's connects: connected in the workspace, following config.json, their bots kept there", { skip }, async () => {
  const p = await mb();
  const w = await twins(p);
  try {
    const conns = new Conns(w);
    let mbN = 0;
    w.script = (name, args) => (name === "conn.create" ? (args[1].id === "bad" ? { throw: "cannot make it" } : ++mbN) : null);
    const raw0 = { connects: [{ id: "a", enabled: true, token: "t1" }, { id: "b", kind: "slack", enabled: true, token: "t2", workspace: "w2" }, { id: "f", kind: "feishu", enabled: true, token: "x" }, { id: "bad", enabled: true, token: "t3" }] };
    const raw = { v: structuredClone(raw0) };
    const cfg = tsConfig(w, raw);
    const env = { bound: false, workspaces: ["w2"], live: ["s1", "s2"] };
    await p.ok({ op: "env", raw: structuredClone(raw0), bound: false, workspaces: ["w2"], live: ["s1", "s2"] });
    const ts = makeConnects<Json>(
      {
        data: w.tsDir,
        store: { liveSessions: () => env.live.map((key) => ({ key })), notify: (key: string) => w.ts.push("store.notify", [key]) } as Json,
        config: cfg.file,
        receive: (connect, event) => w.tsAsk("hub.receive", [connect, event]).then(() => {}),
        bound: () => env.bound,
        inWorkspace: (ws) => ws === null || env.workspaces.includes(ws),
      },
      tsPlatform(w, conns, { n: 0 }) as Json,
    );
    const h = await p.ok({ op: "connects.make", kind: "slack", data: w.mbDir });
    ts.onChange(() => w.ts.push("connects.changed", [h]));
    await p.ok({ op: "connects.call", h, name: "onChange" });
    const call = (name: string, f: () => unknown, args: Json[] = []) => same(p, name, f, { op: "connects.call", h, name, args });
    await call("reconcile", () => ts.reconcile());
    await w.same("out of the workspace: none connected");
    env.bound = true;
    await p.ok({ op: "env", bound: true });
    await call("reconcile", () => ts.reconcile());
    await w.same("in it: those of its workspaces");
    for (const c of ["a", "b", "f", "nope", { id: "a", enabled: false, token: "t1" }]) await call("state", () => ts.state(c as Json), [c]);
    await call("connects", () => ts.connects());
    await call("chat", () => ts.chat("a") !== undefined, ["a"]);
    await conns.set(1, { bot: "UA", identity: { team: "Acme", teamId: "T1", url: "", botUserId: "UA", botName: "Ada bot", botImage: null, botId: "" } });
    await w.rest();
    await w.same("a bot heard of: kept in config.json");
    // config.json edited: in line again as it is saved
    raw.v.connects.push({ id: "c", enabled: true, token: "t9" });
    raw.v.connects[0].token = "t1b";
    for (const l of cfg.listeners) l();
    await p.ok({ op: "config.set", raw: raw.v });
    await w.rest();
    await w.same("edits applied as they are saved");
    env.workspaces = [];
    await p.ok({ op: "env", workspaces: [] });
    await call("reconcile", () => ts.reconcile());
    await w.same("a workspace left: its connects disconnected");
    await call("refreshIdentity", () => ts.refreshIdentity("c"), ["c"]);
    await call("stopAll", () => ts.stopAll());
    await call("close", () => ts.close());
    await call("reconcile", () => ts.reconcile());
    await w.same("closed: nothing more");
  } finally {
    w.done();
  }
});

// ── cards that stopped waiting ───────────────────────────────────────────────────────────────────────────────────

test("cards that stopped waiting, changed where their platform shows them", { skip }, async () => {
  const { Store: StoreT } = await import("../src/store/store.ts");
  const { newMessage } = await import("../src/store/rows.ts");
  const p = await mb();
  for (const surface of ["slack:T1", "stillfail"]) {
    const w = await twins(p);
    const store = StoreT.open(":memory:", null);
    try {
      store.insertSession({ key: "a", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/a", token: "a", createdAt: 1, lastActiveAt: 1 } as Json);
      const thread = store.openThread(surface, "C1", "1.1", null, null);
      store.joinThread(thread.id, "a", "ds");
      w.script = (name, args) => {
        if (name.startsWith("store.")) return (store as Json)[name.slice(6)](...args);
        if (name === "chat.call") return args[1] === "cardEnded" && args[2][1] === "1.5" ? { throw: "not changed" } : null;
        return null;
      };
      const snap = { has: ["cards", "cardEnded"], get: { botUserId: "UB" } };
      const changes: Json[] = [];
      const stop = store.subscribe((change) => {
        changes.push(change);
        showEnded(store, (connect) => snapSurface(connect, snap, w.tsAsk, w.ts) as Json, change);
      });
      const tell = async () => {
        for (const change of changes.splice(0)) {
          await same(p, "cards ended", () => cardsEnded(store as Json, change), { op: "cards.ended", args: wire([change]) });
          w.ts.said = w.ts.said.filter(([n]) => !n.startsWith("store."));
          w.mb.said = w.mb.said.filter(([n]) => !n.startsWith("store."));
          await p.ok({ op: "cards.show", args: wire([change]), chats: { ds: snap } });
        }
        await w.rest();
        w.mb.said = w.mb.said.filter(([n]) => !n.startsWith("store."));
        await w.same("each told the same");
      };
      store.insertMessage({ ...newMessage(thread.id, "1.2", "agent", "a", "合并吗？"), card: { type: "options", options: [{ label: "合并" }] } } as Json);
      await tell();
      const [n] = store.insertMessage(newMessage(thread.id, "1.3", "person", "U1", "等等") as Json);
      await tell();
      store.deliver(thread.id, n, ["a"]);
      await tell();
      store.insertMessage({ ...newMessage(thread.id, "1.4", "agent", "a", "写一下"), card: { type: "text" } } as Json);
      await tell();
      store.insertMessage({ ...newMessage(thread.id, "1.5", "agent", "a", "换一个"), card: { type: "options", options: [{ label: "x" }] } } as Json);
      await tell();
      store.insertMessage({ ...newMessage(thread.id, "1.6", "agent", "a", "再换"), options: ["y"] } as Json);
      await tell();
      stop();
    } finally {
      store.close();
      w.done();
    }
  }
});

// ── the part ─────────────────────────────────────────────────────────────────────────────────────────────────────

test("a platform's part: taken up, connected, the people of its chats learned, its cards changed, shown", { skip }, async () => {
  const { connectsPart } = await import("../src/connects/part.ts");
  const services = await import("../src/services.ts");
  const { Agents } = await import("../src/sessions/agents.ts");
  const p = await mb();
  const w = await twins(p);
  const scope = Effect.runSync(Scope.make());
  try {
    const conns = new Conns(w);
    let mbN = 0;
    // (the store's threads and their sessions, the readers' recent people: the same for both)
    const threads: Json = { 1: { id: 1, surface: "slack:T1", channel: "C1", threadTs: "1.1" }, 2: { id: 2, surface: "stillfail", channel: "C2", threadTs: "2.1" }, 3: { id: 3, surface: "slack:T1", channel: "C3", threadTs: "3.1" } };
    const sessions: Json = { 1: [{ connect: "_internal" }, { connect: "a" }], 2: [{ connect: "a" }], 3: [{ connect: "zz" }] };
    const storeAnswer = (k: string, a: Json[]): Json => {
      if (k === "getThread") return threads[a[0]] ?? null;
      if (k === "threadSessions") return sessions[a[0]] ?? [];
      if (k === "cardReplacedBy") return a[1] === 7 ? [{ ts: "1.7", text: "pick", author: "s" }, { type: "options" }] : null;
      return null;
    };
    w.script = (name, args) => {
      if (name === "conn.create") return args[1].id === "bad" ? { throw: "cannot make it" } : ++mbN;
      if (name.startsWith("store.")) return storeAnswer(name.slice(6), args);
      if (name === "readers.recentConnectPeople") return args[0] === "a" ? JSON.stringify([{ thread: 1, people: ["U1", "U2"] }, { thread: 3, people: ["U3"] }]) : "not json";
      if (name === "conn.refreshIdentity") return args[0] === 1 ? null : { throw: "no answer" };
      return null;
    };
    const raw0 = { connects: [{ id: "a", enabled: true, token: "t1", name: "Acme" }, { id: "b", enabled: true, token: "t2" }] };
    const raw = { v: structuredClone(raw0) };
    const cfg = tsConfig(w, raw);
    await p.ok({ op: "env", raw: structuredClone(raw0), bound: true, workspaces: [], live: [] });
    let storeListener: (c: Json) => void = () => {};
    const store = {
      subscribe: (f: (c: Json) => void) => ((storeListener = f), () => {}),
      liveSessions: () => [],
      notify: () => {},
      ...Object.fromEntries(["getThread", "threadSessions", "cardEndedByMessage", "cardReplacedBy", "closedCard"].map((k) => [k, (...a: Json[]) => (w.ts.push(`store.${k}`, a), storeAnswer(k, a))])),
    };
    const kept: Json = {};
    const agents = {
      hub: { modelsFor: () => [], modelsFirst: () => [] },
      receive: (connect: string, event: Json) => w.tsAsk("hub.receive", [connect, event]),
      taken: () => true,
      bound: () => true,
      surfaces: () => {},
      nameBook: () => {},
      connectKind: (_k: string, kind: Json) => (kept.kind = kind),
      along: (a: Json) => (kept.along = a),
    };
    const layer = Effect.provideService(services.Paths, { data: w.tsDir, app: w.tsDir } as Json);
    const made = await Effect.runPromise(
      connectsPart((options) => makeConnects<Json>(options, tsPlatform(w, conns, { n: 0 }) as Json), {
        kind: "slack",
        shown: (c, connect) => ({ name: typeof connect?.name === "string" ? connect.name : connect?.id, connection: c.state(connect) }),
        entry: () => null,
        taken: () => void w.ts.push("part.taken", []),
      }).pipe(
        layer,
        Effect.provideService(services.Store, store as Json),
        Effect.provideService(services.StationConfig, cfg.file),
        Effect.provideService(services.Events, { overviewChanged: () => w.ts.push("events.overviewChanged", []), rowsChanged: () => w.ts.push("events.rowsChanged", []) } as Json),
        Effect.provideService(services.ControlPlane, { state: { membership: () => ({}) } } as Json),
        Effect.provideService(Agents, agents as Json),
        Effect.provideService(services.Readers, { read: (name: string, a: Json) => w.tsAsk(`readers.${name}`, [a.connect]) } as Json),
        Scope.provide(scope),
      ),
    );
    void made;
    const h = await p.ok({ op: "connects.make", kind: "slack", data: w.mbDir });
    const part = await p.ok({ op: "part.make", h, kind: "slack" });
    const call = (name: string, f: () => unknown, args: Json[] = []) => same(p, name, f, { op: "part.call", h: part, name, args });
    await call("taken", () => kept.along.taken());
    await w.same("taken up: connected, its kind's own after");
    await conns.set(1, { bot: "UA", socket: { connected: true, lastError: null }, identity: { team: "T", teamId: "T1", url: "", botUserId: "UA", botName: "Acme", botImage: null, botId: "" } });
    await conns.set(2, { bot: "UB", socket: { connected: true, lastError: null } });
    await w.rest();
    await conns.set(1, { socket: { connected: true, lastError: null } });
    await w.rest();
    await w.sameUnordered("connected: its recent people learned once, the overview told");
    for (const change of [
      { type: "thread", id: 1, entries: [{ kind: "message", n: 7, authorKind: "agent", author: "s", card: { type: "options" } }, { kind: "message", n: 8, authorKind: "person", author: "U9", ts: "1.8" }, { kind: "message", n: 9, authorKind: "person", author: "U9" }] },
      { type: "thread", id: 2, entries: [{ kind: "message", n: 1, authorKind: "person", author: "U1" }] },
      { type: "thread", id: 3, entries: [] },
      { type: "session", key: "x" },
    ]) {
      storeListener(change);
      await p.ok({ op: "part.call", h: part, name: "storeChanged", args: [change] });
      await w.rest();
    }
    await w.same("each change: its people learned, its cards changed");
    for (const c of [{ id: "a", enabled: true, token: "t1", name: "Acme" }, { id: "b", enabled: true, token: "t2" }, { id: "zz" }, {}]) {
      await call("connection", () => kept.kind.connection(c), [c]);
      await call("shown", () => kept.kind.shown(c), [c]);
    }
    await call("reconnect", () => kept.kind.reconnect("a"), ["a"]);
    await call("reconnect", () => kept.kind.reconnect("b"), ["b"]);
    await call("changed", () => kept.along.changed());
    await call("left", () => kept.along.left());
    await w.same("connected again, its bot read again; left: none connected");
  } finally {
    await Effect.runPromise(Scope.close(scope, Exit.void));
    w.done();
  }
});

// ── a connected surface ──────────────────────────────────────────────────────────────────────────────────────────

/// A surface whose platform is the test's (surface.ts's hooks asked of the world), as the program's harness makes one.
function tsSurface(w: Twins, h: number, o: { connect?: string; pingMs: number; staleMs: number; backoffMs?: number; statusMs: number }) {
  class Line extends StatusLine {
    readonly key: string;
    constructor(run: Json, key: string) {
      super(run, o.statusMs);
      this.key = key;
    }
    protected async show(status: string, now: number) {
      return (await w.tsAsk("surf.show", [h, this.key, status, now, this.messageTs, this.page])) === true;
    }
  }
  class Test extends ConnectedSurface {
    protected readonly kind = "test";
    protected identify() {
      return w.tsAsk("surf.identify", [h]);
    }
    protected address() {
      return w.tsAsk("surf.address", [h]);
    }
    runSocket(url: string, handler: (e: Json) => Promise<void>) {
      return Effect.tryPromise({
        try: async () => {
          for (const e of (await w.tsAsk("surf.runSocket", [h, url])) ?? []) await handler(e);
        },
        catch: (e) => e as Error,
      });
    }
    protected lookUp(user: string) {
      return w.tsAsk("surf.lookUp", [h, user]);
    }
    protected lookUpEmail(email: string) {
      return w.tsAsk("surf.lookUpEmail", [h, email]);
    }
    protected statusLine(thread: Json) {
      return new Line(this.run, `${thread.channel}/${thread.threadTs}`);
    }
    async post() {
      return "";
    }
  }
  return new Test({ connect: o.connect, pingMs: o.pingMs, staleMs: o.staleMs, backoffMs: o.backoffMs, clock: w.time.clock, onHeard: () => w.ts.push("surf.heard", [h]) });
}

test("a connected surface: who its bot is, its socket kept up on a backoff, its people and status lines", { skip }, async () => {
  const p = await mb();
  const w = await twins(p);
  try {
    const count = { ts: new Map<string, number>(), mb: new Map<string, number>() };
    const nth = (side: "ts" | "mb", key: string) => {
      const n = (count[side].get(key) ?? 0) + 1;
      count[side].set(key, n);
      return n;
    };
    const never = new Promise(() => {});
    const roles = new Map<number, string>();
    const identity = { team: "Acme", teamId: "T1", url: "", botUserId: "UB", botName: "Bot", botImage: null, botId: "B" };
    w.script = (name, args, side) => {
      const n = nth(side, `${name} ${args[0]} ${name === "surf.read" ? args[1] : ""}`);
      switch (name) {
        case "surf.identify":
          if (roles.get(args[0]) === "two") return { throw: "token revoked" };
          if (roles.get(args[0]) === "three") return identity;
          return n === 1 ? { throw: "connect ECONNREFUSED", code: "ECONNREFUSED" } : n === 2 ? { throw: "timed out", code: "ETIMEDOUT" } : n === 3 ? { throw: "invalid_auth" } : identity;
        case "surf.address":
          return n === 2 ? { throw: "no address" } : `wss://x/${n}`;
        case "surf.runSocket":
          if (n === 1) return { throw: "socket closed badly" };
          if (n <= 3) return [{ type: "message", n }];
          return never;
        case "surf.lookUp":
          return args[1] === "U1" ? { name: "Ada", email: "ada@x" } : args[1] === "U3" ? { name: "", email: "" } : null;
        case "surf.lookUpEmail":
          return args[1] === "ada@x" ? "U1" : null;
        case "surf.read":
          return args[1] === "bad" ? { throw: "read failed" } : `${args[1]}#${n}`;
        case "surf.show":
          return true;
      }
      return null;
    };
    const o = { connect: "c1", pingMs: 15000, staleMs: 45000, backoffMs: 1000, statusMs: 2000 };
    const make = async () => {
      const h = await p.ok({ op: "surface.new", kind: "test", ...o });
      return { h, ts: tsSurface(w, h, o) };
    };
    const one = await make();
    const two = await make();
    roles.set(one.h, "one");
    roles.set(two.h, "two");
    const call = (s: { h: number; ts: Json }, name: string, f: () => unknown, args: Json[] = []) => same(p, `${s.h} ${name}`, f, { op: "surface.call", h: s.h, name, args });
    const handled = (s: { h: number; ts: Json }) => (e: Json) => w.tsAsk("surf.handled", [s.h, e]).then(() => {});
    one.ts.onChange(() => w.ts.push("surf.changed", [one.h]));
    await p.ok({ op: "surface.call", h: one.h, name: "onChange" });
    await call(one, "start", () => one.ts.start(handled(one)));
    await call(two, "start", () => two.ts.start(handled(two)));
    await w.same("one not reached at first, one refused");
    const state = (s: { h: number; ts: Json }) => call(s, "state", () => ({ identity: s.ts.identity(), socket: s.ts.socket(), botUserId: s.ts.botUserId(), botName: s.ts.botName(), workspace: s.ts.workspace(), lines: s.ts.lines.size }));
    await state(one);
    for (const ms of [1000, 1000, 2000, 1000, 1000, 2000, 4000]) {
      await w.both(ms);
      await state(one);
    }
    await w.same("asked again on its backoff; a refusal then said as its error");
    // (a third: answers at once, its socket kept up)
    const three = await make();
    roles.set(three.h, "three");
    await call(three, "start", () => three.ts.start(handled(three)));
    await w.rest();
    for (const ms of [1000, 2000, 4000]) {
      await w.both(ms);
      await state(three);
    }
    await w.same("its socket connected again, on a backoff after a failure");
    for (const u of ["U1", "U2", "U3", "U1"]) {
      await call(three, "userName", () => three.ts.userName(u), [u]);
      await call(three, "userEmail", () => three.ts.userEmail(u), [u]);
    }
    for (const e of [" ADA@x ", "ada@x", "nobody@x", "", "nobody@x"]) await call(three, "userOf", () => three.ts.userOf(e), [e]);
    const kept = (key: string, ms: number) => same(p, `kept ${key}`, () => (three.ts as Json).kept(key, ms, () => w.tsAsk("surf.read", [three.h, key])), { op: "surface.call", h: three.h, name: "kept", args: [key, ms] });
    await kept("k", 100);
    await kept("k", 100);
    await w.both(100);
    await kept("k", 100);
    await kept("bad", 100);
    await kept("bad", 100);
    await call(three, "forget", () => (three.ts as Json).forget("k", 50), ["k", 50]);
    await w.both(60);
    await call(three, "forget", () => (three.ts as Json).forget("k", 50), ["k", 50]);
    await kept("k", 100);
    await w.same("kept answers, asked again after their time or a failure");
    const thread = { channel: "C1", threadTs: "1.1" };
    await call(three, "working", () => three.ts.working(thread, "1.2", "reading", "https://p"), [thread, "1.2", "reading", "https://p"]);
    await call(three, "working", () => three.ts.working(thread, null, "writing"), [thread, null, "writing", null]);
    await w.both(2000);
    await call(three, "working", () => three.ts.working(thread, null, ""), [thread, null, "", null]);
    await w.rest();
    await state(three);
    await w.same("its status lines");
    for (const s of [one, two, three]) await call(s, "stop", () => s.ts.stop());
    await call(three, "working", () => three.ts.working(thread, null, "late"), [thread, null, "late", null]);
    await w.both(60_000);
    await w.same("stopped: nothing more");
  } finally {
    w.done();
  }
});

// ── another station's connects ───────────────────────────────────────────────────────────────────────────────────


/// The mesh between the stations as each side asks it: what is asked (and the bytes after it, read) recorded alike, the
/// script's `{json, bytes}` answered as each takes it.
function meshOf(w: Twins) {
  w.own = (name, args) => {
    if (name !== "bus.ask") return undefined;
    return (async () => {
      const [station, request, body] = args;
      let bytes: string | null = null;
      if (body?.file) {
        const f = await open(body.file, "r");
        const b = Buffer.alloc(body.size);
        await f.read(b, 0, body.size, body.offset);
        await f.close();
        bytes = b.toString("hex");
      } else if (body?.hex !== undefined) bytes = body.hex;
      w.mb.push("bus.ask", [station, request, bytes]);
      const got = await w.answer("bus.ask", [station, request, bytes], true);
      return { json: got?.json ?? null, bytes: got?.bytes ?? null };
    })();
  };
  return async (station: string, request: Json): Promise<Json> => {
    const b = bytesOf(request);
    let bytes: string | null = null;
    if (b !== null) {
      const parts: Buffer[] = [];
      for await (const piece of b) parts.push(piece);
      bytes = Buffer.concat(parts).toString("hex");
    }
    const asked = [station, wire(request), bytes];
    w.ts.push("bus.ask", asked);
    const got = await w.answer("bus.ask", asked, false);
    const json = got?.json ?? null;
    return typeof got?.bytes === "string" ? withBytes(json ?? {}, oneBytes(Buffer.from(got.bytes, "hex"))) : json;
  };
}

const described = (o: Json = {}) => ({ kind: "slack", workspace: "ws", mode: "multi-session", requireMention: true, bind: { runtime: "claude" }, botUserId: "UH", botName: "Hbot", identity: null, platform: null, team: "T1", cards: true, loginCards: false, mention: ["<@", ">"], link: "<\u0001|\u0002>", has: ["cardEnded", "download", "userName", "working", "standsAt", "api", "places", "begin", "edit", "history", "channelName"], ...o });

test("another station's connects: kept on disk, their surfaces asking the station each runs on", { skip }, async () => {
  const p = await mb();
  const w = await twins(p);
  try {
    await p.ok({ op: "env", here: "S" });
    const ask = meshOf(w);
    w.script = (name, args) => {
      if (name !== "bus.ask") return null;
      const r = args[1];
      if (r.method !== "connect.call") return { json: { ok: true } };
      switch (r.op) {
        case "upload":
          return { json: { result: r.args[0].name === "nope.txt" ? {} : { path: `/up/${r.args[0].name}` } } };
        case "post":
          return { json: { result: "9.9" } };
        case "download":
          return { json: { size: 3 }, bytes: "616263" };
        case "api":
          return { json: { result: { answer: { ok: true, n: r.args[0] }, files: [{ id: "F1" }] } } };
        case "person":
          return { json: { result: r.args[0] === "U9" ? null : { name: `P-${r.args[0]}`, email: "" } } };
        case "channel":
          return { json: { result: `ch-${r.args[0]}` } };
        case "working":
          return { throw: "the station is away" };
        default:
          return { json: { result: { op: r.op, args: r.args } } };
      }
    };
    const kept = { "cl@H": { station: "H", described: described() }, "fs@H": { station: "H", described: described({ kind: "feishu", team: null, link: null, has: [], cards: false, loginCards: true, platform: "lark", mention: ["@", ""] }) }, broken: { station: 5 }, "x@H": { station: "H", described: {} } };
    for (const d of [w.tsDir, w.mbDir]) await writeFile(join(d, "remote-connects.json"), JSON.stringify(kept));
    const book = new NameBook(join(w.tsDir, "slack-names.json"), { clock: w.time.clock });
    w.files.push((book as Json).file);
    const bh = await p.ok({ op: "names.open", path: join(w.mbDir, "slack-names.json") });
    await p.ok({ op: "remote.names", kind: "slack", book: bh });
    const ts = new RemoteConnects(w.tsDir, () => "S", ask, (kind) => (kind === "slack" ? book : null));
    w.files.push(ts);
    const h = await p.ok({ op: "remote.new", data: w.mbDir });
    const call = (name: string, f: () => unknown, args: Json[] = []) => same(p, `remote ${name} ${JSON.stringify(args).slice(0, 80)}`, f, { op: "remote.call", h, name, args });
    await call("ready", () => ts.ready());
    await call("connects", () => ts.connects());
    for (const id of ["cl@H", "fs@H", "broken", "nope"]) await call("surface", () => { const s = ts.surface(id); return s ? { id: s.id, known: s.known, station: s.station, described: s.described } : null; }, [id]);
    for (const id of ["cl@H", "fs@H"]) {
      const s = ts.surface(id)! as Json;
      for (const name of ["post", "cardEnded", "download", "userName", "api", "places", "edit", "history", "working", "standsAt", "cards", "loginCards", "sessionLink", "knownPerson", "mention", "userOf"]) {
        await call("has", () => (name === "cards" || name === "loginCards" ? s[name] === true : typeof s[name] === "function"), [id, name]);
      }
      for (const [name, args] of [["botUserId", []], ["botName", []], ["identity", []], ["platform", []], ["mention", ["U1"]], ["workspace", []], ["cards", []], ["loginCards", []], ["sessionLink", ["https://x/$&", "a $` b"]]] as const) {
        await call("get", () => (name === "cards" || name === "loginCards" ? s[name] : s[name](...args)), [id, name, args]);
      }
    }
    const s = ts.surface("cl@H")! as Json;
    for (const d of [w.tsDir, w.mbDir]) {
      await writeFile(join(d, "a.txt"), "hello");
      await writeFile(join(d, "nope.txt"), "x");
    }
    const thread = { channel: "C1", threadTs: "1.1" };
    const remote = async (name: string, args: Json[], tsArgs: Json[] = args) => call("call", () => s[name](...tsArgs), ["cl@H", name, args]);
    await remote("post", [thread, "hi", [{ name: "a.txt", path: join(w.mbDir, "a.txt") }], null], [thread, "hi", [{ name: "a.txt", path: join(w.tsDir, "a.txt") }], null]);
    await remote("post", [thread, "no", [{ name: "nope.txt", path: join(w.mbDir, "nope.txt") }], { type: "options" }], [thread, "no", [{ name: "nope.txt", path: join(w.tsDir, "nope.txt") }], { type: "options" }]);
    await remote("post", [thread, "plain", [], undefined]);
    await remote("cardEnded", [thread, "1.2", "q", { type: "text" }, { why: "replaced" }]);
    await call("call", async () => hex(await s.download({ id: "F", name: "f" })), ["cl@H", "download", [{ id: "F", name: "f" }]]);
    await w.same("its calls asked of the station it runs on, files before them");
    await remote("api", ["conversations.info", { channel: "C1" }]);
    for (const name of ["userName", "channelName"]) await remote(name, ["U1"]);
    await remote("places", []);
    await remote("begin", ["C9", "hello"]);
    await remote("edit", [thread, "1.2", "edited"]);
    await remote("history", [thread, "1.0", 20]);
    await call("get", () => s.working(thread, "1.2", "reading"), ["cl@H", "working", [thread, "1.2", "reading"]]);
    await call("get", () => s.standsAt(thread, { kind: "done", words: null }), ["cl@H", "standsAt", [thread, { kind: "done", words: null }]]);
    for (const u of ["U1", "U9", "U1"]) {
      await call("get", () => s.knownPerson(u), ["cl@H", "knownPerson", [u]]);
      await w.rest();
    }
    await call("get", () => s.knownChannel("C1"), ["cl@H", "knownChannel", ["C1"]]);
    await w.rest();
    await call("get", () => s.knownChannel("C1"), ["cl@H", "knownChannel", ["C1"]]);
    await w.same("names learned through it, calls told");
    await call("learn", () => ts.learn("cl@H", "H", described()), ["cl@H", "H", described()]);
    await call("learn", () => ts.learn("new@H", "H", described({ kind: "feishu" })), ["new@H", "H", described({ kind: "feishu" })]);
    await call("moved", () => ts.moved("cl@H", "K"), ["cl@H", "K"]);
    await call("moved", () => ts.moved("fs@H", "S"), ["fs@H", "S"]);
    await call("moved", () => ts.moved("nope", "K"), ["nope", "K"]);
    await call("connects", () => ts.connects());
    await call("written", () => ts.written());
    await w.sameFiles("kept on disk", () => ts.written());
    await same(p, "read", () => readRemote(w.tsDir), { op: "remote.read", data: w.mbDir });
    await w.same("all said alike");
  } finally {
    w.done();
  }
});

test("a call of a connect's surface answered for another station", { skip }, async () => {
  const p = await mb();
  const w = await twins(p);
  try {
    w.own = (name) => (name === "answer.cleared" ? Promise.resolve(null) : undefined);
    const snap = { has: ["cards", "cardEnded", "download", "userName", "userEmail", "api", "places", "channelName", "knownPerson", "answerFiles", "working"], get: { botUserId: "UB", workspace: "T1", knownPerson: null, answerFiles: [{ id: "F2" }] } };
    const surfaceAnswer = (known: Json, ws: Json) => (known.id === "cl" && ws === "ws" ? snap : null);
    w.script = (name, args) => {
      if (name === "answer.surface") return surfaceAnswer(args[0], args[1]);
      if (name !== "chat.call") return null;
      const [, op, a] = args;
      if (op === "download") return "68656c6c6f";
      if (op === "userName") return a[0] === "U1" ? "Ada" : null;
      if (op === "userEmail") return { throw: "no email scope" };
      if (op === "post") return `posted ${a[2].length}`;
      return { op, a };
    };
    const tsSurface_ = (known: Json, ws: string | undefined) => {
      const s = surfaceAnswer(known, ws ?? null);
      w.ts.push("answer.surface", [known, ws ?? null]);
      if (s === null) return undefined;
      const made = snapSurface(known.id, s, w.tsAsk, w.ts);
      made.download = async (...a: Json[]) => Buffer.from(await w.tsAsk("chat.call", [known.id, "download", a]), "hex");
      made.answerFiles = () => s.get.answerFiles;
      return made;
    };
    const tsAnswer = answerCall(tsSurface_ as Json, join(w.tsDir, "up"));
    const h = await p.ok({ op: "answer.new", uploads: join(w.mbDir, "up") });
    const both = async (what: string, request: Json, workspace: string | undefined, bytes: string | null, mbRequest: Json = request) => {
      const want = await settled(async () => {
        const answer = await tsAnswer("H", bytes === null ? structuredClone(request) : withBytes(structuredClone(request), oneBytes(Buffer.from(bytes, "hex"))), workspace);
        const b = bytesOf(answer);
        let hexed: string | null = null;
        if (b !== null) {
          const parts: Buffer[] = [];
          for await (const x of b) parts.push(x);
          hexed = Buffer.concat(parts).toString("hex");
        }
        return { json: answer, bytes: hexed };
      });
      const got = await p.ask({ op: "answer.call", h, request: mbRequest, body: bytes, workspace: workspace ?? null });
      delete got.id;
      const n = (v: Json) => norm(v, [w.tsDir, w.mbDir]);
      if ("error" in want) assert.deepEqual({ error: got.error, kind: got.kind }, want, what);
      else assert.deepEqual(n(got), n(want), what);
      return [want.ok?.json?.result, got.ok?.json?.result];
    };
    const connect = { id: "cl", origin: "H" };
    const req = (op: string, args: Json[]) => ({ method: "connect.call", workspace: "ws", connect, op, args });
    const [tsUp, mbUp] = await both("upload", req("upload", [{ name: "../a b.txt", size: 5 }]), "ws", "68656c6c6f");
    await both("upload without a file", req("upload", [{}]), "ws", null);
    await both("upload with no name", req("upload", [{ name: "" }]), "ws", "00");
    await w.sameFiles("the file kept until it is posted");
    await both("post", req("post", [{ channel: "C" }, "hi", [{ name: "a b.txt", path: tsUp.path }], null]), "ws", null, req("post", [{ channel: "C" }, "hi", [{ name: "a b.txt", path: mbUp.path }], null]));
    await both("post of a file that did not come here", req("post", [{ channel: "C" }, "hi", [{ name: "x", path: "/etc/passwd" }], null]), "ws", null);
    await w.rest();
    await w.sameFiles("posted: its file gone");
    await both("download", { ...req("download", [{ id: "F" }]), whole: true }, "ws", null);
    await both("api", req("api", ["chat.postMessage", { text: "x" }]), "ws", null);
    await both("api with no params", req("api", ["auth.test"]), "ws", null);
    for (const u of ["U1", "U2"]) await both(`person ${u}`, req("person", [u]), "ws", null);
    await both("channel", req("channel", ["C1"]), "ws", null);
    await both("places", req("places", []), "ws", null);
    await both("working", req("working", [{ channel: "C" }, null, "x"]), "ws", null);
    await both("no such call", req("rm", []), "ws", null);
    await both("not a call it has", req("history", []), "ws", null);
    await both("another workspace", req("places", []), "other", null);
    await both("no connect", { method: "connect.call", op: "places", args: [] }, "ws", null);
    await w.same("asked alike");
  } finally {
    w.done();
  }
});

// ── the workspace's connects ─────────────────────────────────────────────────────────────────────────────────────

const roster = [{ id: "H", name: "laptop" }, { id: "S", name: "desktop" }, { id: "K", name: "kiosk" }];
const parsed = (o: Json) => ({ kind: "slack", enabled: true, mode: "multi-session", requireMention: true, slack: {}, bind: { runtime: "claude" }, ...o });
const surfaces: Json = {
  cl: { has: ["cards", "mention", "sessionLink", "download", "userName"], get: { botUserId: "UCL", workspace: "T1" }, mention: ["<@", ">"], link: "<\u0001|\u0002>" },
  team: { has: ["mention"], get: { botUserId: "UTEAM", workspace: "T1" }, mention: ["<@", ">"] },
  cm: { has: [], get: { botUserId: "", workspace: null } },
  fsh: { has: ["loginCards"], get: { botUserId: "ou_x", workspace: null } },
};

/// One station of the workspace's connects, as both sides make it: H, its connects config.json's, its hub and store
/// the test's (what they answer, `answers`), the mesh to S and K the test's.
async function wsTwins(p: Program, raw0: Json, answers: (name: string, args: Json[], side: "ts" | "mb") => Json) {
  const w = await twins(p);
  await p.ok({ op: "env", here: "H", home: "ws", stations: { ws: roster }, raw: structuredClone(raw0) });
  // (no names books, as the TypeScript's is given none)
  for (const kind of ["slack", "feishu", "comma", "group"]) await p.ok({ op: "remote.names", kind, book: 0 });
  const raw = { v: structuredClone(raw0) };
  const ask = meshOf(w);
  w.script = answers;
  const sync = (name: string, args: Json[]): Json => {
    w.ts.push(name, args);
    const v = answers(name, args, "ts");
    if (v !== null && typeof v === "object" && "throw" in v) throw thrown(v);
    return v;
  };
  const handlers = new Map<string, Json>();
  const heard: ((peer: string) => void)[] = [];
  const ref: { ts?: WorkspaceConnects } = {};
  const hub = {
    chatOf: (id: string) => {
      const got = sync("hub.chatOf", [id]);
      if (got === null) return undefined;
      if (got.remote) return ref.ts!.remote.surface(id);
      return snapSurface(id, got, w.tsAsk, w.ts);
    },
    config: () => ({ connects: sync("hub.configConnects", []) }),
    receive: (id: string, event: Json) => w.tsAsk("hub.receive", [id, event]),
    movedTo: (id: string, c: string, t: string) => sync("hub.movedTo", [id, c, t]),
    quietIn: (ws: string) => sync("hub.quietIn", [ws]) === true,
    surface: (id: string) => sync("hub.surface", [id]),
    toldBots: { set: (peer: string, bots: Set<string>) => void w.tsAsk("hub.toldBots", [peer, [...bots]]) },
  };
  const store = Object.fromEntries(["dropConnectThreadStation", "setConnectThreadStation", "connectThreadStation", "dropConnectThreads", "connectThreads", "connectLocalThreads", "threadAt"].map((k) => [k, (...a: Json[]) => sync(`store.${k}`, a)]));
  ref.ts = new WorkspaceConnects({
    data: w.tsDir,
    hub: () => hub as Json,
    store: store as Json,
    config: { raw: () => raw.v, updateSoon: async (f) => { f(raw.v); await w.tsAsk("config.updated", [raw.v]); } },
    here: () => "H",
    home: () => "ws",
    stations: (ws) => (ws === "ws" ? roster : []),
    bus: { ask, on: (m: string, inbox: Json) => void handlers.set(m, inbox), heard: (f: (peer: string) => void) => void heard.push(f) } as Json,
    names: () => null,
  });
  w.files.push({ writing: () => ref.ts!.writing(), written: () => ref.ts!.filesWritten() });
  const h = await p.ok({ op: "ws.new", data: w.mbDir });
  await ref.ts.remote.ready();
  await w.rest();
  const call = (name: string, f: (c: WorkspaceConnects) => unknown, args: Json[] = []) => same(p, `${name} ${JSON.stringify(args).slice(0, 120)}`, () => f(ref.ts!), { op: "ws.call", h, name, args });
  const handle = (method: string, peer: string, request: Json, workspace: string | undefined, bytes: string | null = null) =>
    same(p, `${method} from ${peer} ${JSON.stringify(request).slice(0, 100)}`, async () => {
      const answer = await handlers.get(method)(peer, bytes === null ? structuredClone(request) : withBytes(structuredClone(request), oneBytes(Buffer.from(bytes, "hex"))), workspace);
      return { json: answer, bytes: null };
    }, { op: "bus.handle", method, peer, request, workspace: workspace ?? null, body: bytes });
  const hear = async (peer: string) => {
    for (const f of heard) f(peer);
    await p.ok({ op: "bus.heard", peer });
    await w.rest();
  };
  return { w, h, ts: ref.ts, raw, call, handle, hear };
}

test("the workspace's connects: a platform's events routed to the station each chat runs on", { skip }, async () => {
  const p = await mb();
  const raw0 = { connects: [{ id: "cl", kind: "slack", slack: { botToken: "xoxb-1" }, station: "S", name: "Claude" }, { id: "team", mode: "single-session" }, { id: "cm", kind: "comma", comma: { token: "t" } }, { id: "g2", kind: "slack", workspace: "w2" }] };
  const quiet = { v: false };
  const { w, call } = await wsTwins(p, raw0, (name, args) => {
    switch (name) {
      case "hub.chatOf":
        return surfaces[args[0]] ?? null;
      case "hub.configConnects":
        return [parsed({ id: "cl", slack: { botName: "Claude" }, bind: { runtime: "claude", model: "opus" } }), parsed({ id: "team", mode: "single-session" }), parsed({ id: "cm", kind: "comma" })];
      case "hub.movedTo":
        return null;
      case "hub.quietIn":
        return quiet.v;
      case "hub.surface":
        return "slack:T1";
      case "store.connectThreadStation":
        return args[1] === "C-S" ? "S" : args[1] === "C-K" ? "K" : null;
      case "store.threadAt":
        return args[1] === "C-old" ? { id: 1 } : null;
      case "store.connectThreads":
      case "store.connectLocalThreads":
        return [];
      case "bus.ask":
        return args[0] === "K" ? { throw: "station unreachable" } : args[1].method === "connect.event" && args[1].event?.message?.text === "refuse" ? { throw: "no", declined: true } : { json: { ok: true } };
      case "chat.call":
        return "9.9";
    }
    return null;
  });
  try {
    const message = (channel: string, text: string, addressed = true): Json => ({ type: "message", message: { channel, threadTs: "1.1", ts: "1.2", user: "U1", text, addressed } });
    const receive = (id: string, event: Json) => call("receive", (c) => c.receive(id, event), [id, event]);
    await receive("cm", message("C1", "comma's own"));
    await receive("nope", message("C1", "not a connect here"));
    await receive("cl", message("C-S", "its chat on S"));
    await receive("cl", { type: "changed", channel: "C-S", threadTs: "1.1", ts: "1.2", text: "edit" });
    await receive("cl", message("C-K", "its chat on K, which is away"));
    await receive("cl", { type: "changed", channel: "C-K", threadTs: "1.1", ts: "1.3", text: "x" });
    await receive("cl", message("C-new", "a new conversation"));
    await receive("cl", message("C-new2", "refuse"));
    await receive("cl", message("C-old", "an old thread"));
    await receive("cl", message("C-x", "not addressed", false));
    await receive("team", message("C1", "single session"));
    await receive("g2", message("C1", "another workspace"));
    await w.same("routed: to S, to K and told it is away, new ones to its station, the rest here");
    quiet.v = true;
    await receive("team", message("C1", "held 1"));
    await receive("cl", message("C-new3", "held 2"));
    await receive("cm", message("C1", "comma is never held"));
    await w.sameFiles("held on disk, in order");
    quiet.v = false;
    await call("takeHeld", (c) => c.takeHeld("ws"), ["ws"]);
    await w.sameFiles("taken here after all");
    quiet.v = true;
    await receive("team", message("C1", "held 3"));
    await receive("cl", message("C-new4", "held 4"));
    await w.same("all alike");
    await call("moveAll", (c) => c.moveAll("ws", "S"), ["ws", "S"]);
    await receive("team", message("C1", "after the move"));
    await w.same("moved: each connect, then what was kept, then each event at once");
    await w.sameFiles("nothing left kept");
  } finally {
    w.done();
  }
});

test("the workspace's connects: a connect moved to another station and back, its move settled either way", { skip }, async () => {
  const p = await mb();
  const raw0 = { connects: [{ id: "cl", kind: "slack", slack: { botToken: "xoxb-1" } }, { id: "cm", kind: "comma", comma: { token: "t" } }, { id: "fs", kind: "feishu", feishu: { appId: "cli" }, mode: "single-session" }] };
  const gates = { ts: [] as (() => void)[], mb: [] as (() => void)[] };
  const take = { v: "ok" as string };
  const { w, h, ts, call, handle, hear } = await wsTwins(p, raw0, (name, args, side) => {
    switch (name) {
      case "hub.chatOf":
        return surfaces[args[0]] ?? (String(args[0]).includes("@") ? { remote: true } : null);
      case "hub.configConnects":
        return [parsed({ id: "cl" }), parsed({ id: "cm", kind: "comma" }), parsed({ id: "fs", kind: "feishu", mode: "single-session" })];
      case "hub.quietIn":
      case "hub.movedTo":
        return name === "hub.quietIn" ? false : null;
      case "hub.surface":
        return "slack:T1";
      case "store.connectThreads":
        return [{ channel: "C1", threadTs: "1", station: "K" }, { channel: "C2", threadTs: "2", station: "S" }];
      case "store.connectLocalThreads":
        return [{ channel: "C1", threadTs: "1" }, { channel: "C3", threadTs: "3" }];
      case "bus.ask": {
        const r = args[1];
        if (r.method === "connect.take") {
          if (take.v === "declined") return { throw: "it refused", declined: true };
          if (take.v === "lost") return { throw: "no answer in time", code: "ETIMEDOUT" };
          if (take.v === "gate") return new Promise<Json>((resolve) => gates[side].push(() => resolve({ json: { ok: true } })));
        }
        if (r.method === "connect.holds") return { json: { holds: take.v === "lost-held" } };
        if (r.method === "connect.list") return { json: { has: args[0] === "K" } };
        return { json: { ok: true } };
      }
    }
    return null;
  });
  try {
    for (const [what, id, to, viewer] of [["unknown", "nope", "S", null], ["to itself", "cl", "H", null], ["out of the workspace", "cl", "Z", null], ["another workspace's viewer", "cl", "S", "w9"]] as const) {
      await call("move", (c) => c.move(id, to, viewer, "en"), [id, to, viewer, "en"]);
      void what;
    }
    take.v = "declined";
    await call("move", (c) => c.move("cl", "S", null), ["cl", "S", null]);
    await w.sameFiles("refused there: no move kept");
    take.v = "lost";
    await call("move", (c) => c.move("cl", "S", null), ["cl", "S", null]);
    await w.rest();
    await w.sameFiles("no answer: the move kept");
    take.v = "lost-held";
    await hear("K");
    await hear("S");
    await w.same("settled once S is heard from: it holds it");
    await w.sameFiles("settled");
    take.v = "gate";
    const event = (text: string): Json => ({ type: "message", message: { channel: "C1", threadTs: "1.1", ts: "1.2", user: "U1", text, addressed: true } });
    const both = (name: string, args: Json[], f: () => Promise<unknown>) => Promise.all([settled(f), p.ask({ op: "ws.call", h, name, args })]);
    // (cm moved while S takes its time: what its socket gives meanwhile waits for S's answer and goes there)
    const moving = both("move", ["cm", "S", null, "zh", "H", ["k1"]], () => ts.move("cm", "S", null, "zh", "H", ["k1"]));
    // (each asked S to take it once it kept its move on disk, the TypeScript's a real file's writes: until then)
    for (let i = 0; i < 20000 && !(gates.ts.length > 0 && gates.mb.length > 0); i++) await w.rest();
    assert.ok(gates.ts.length > 0 && gates.mb.length > 0, "never asked S to take it");
    const meanwhile = both("receive", ["cm", event("meanwhile")], () => ts.receive("cm", event("meanwhile")));
    await w.rest();
    await w.same("asked to take it: its events wait");
    for (const g of gates.ts.splice(0)) g();
    for (const g of gates.mb.splice(0)) g();
    for (const [want, got] of [await moving, await meanwhile]) {
      delete got.id;
      assert.deepEqual(got, want);
    }
    await w.rest();
    await w.same("taken there: what waited went there, kept");
    await call("receive", (c) => c.receive("cm", event("after")), ["cm", event("after")]);
    await w.sameFiles("its move done", () => ts.remote.written());
    // back here, its chats still on their way
    const entry = { id: "cm", kind: "comma", comma: { token: "t" }, workspace: "ws" };
    await handle("connect.take", "S", { connect: { id: "cm", origin: "H" }, entry, threads: [{ channel: "C9", threadTs: "9", station: "S" }, { channel: "C8", threadTs: "8", station: "H" }, { channel: 5 }], awaiting: ["k1", "k2", 3] }, "ws");
    await handle("connect.take", "S", { connect: { id: "cm", origin: "H" }, entry, threads: [] }, "ws");
    await handle("connect.take", "Z", { connect: { id: "cm2", origin: "H" }, entry, threads: [] }, "ws");
    await call("receive", (c) => c.receive("cm", event("kept 1")), ["cm", event("kept 1")]);
    await call("receive", (c) => c.receive("cm", event("kept 2")), ["cm", event("kept 2")]);
    await w.sameFiles("kept for its chats on their way", () => ts.remote.written());
    await call("arrived", (c) => c.arrived(["k1"]), [["k1"]]);
    await call("arrived", (c) => c.arrived(["k2", "x"]), [["k2", "x"]]);
    await w.same("all there: what was kept taken, in order");
    await w.sameFiles("nothing kept", () => ts.remote.written());
    // what the other stations ask of it
    const known = (id: string, origin = "H") => ({ id, origin });
    await handle("connect.holds", "S", { connect: known("cm") }, "ws");
    await handle("connect.holds", "S", { connect: known("cl") }, "ws");
    await handle("connect.holds", "Z", { connect: known("cm") }, "ws");
    await handle("connect.holds", "S", { connect: {} }, "ws");
    await handle("connect.moved", "S", { connect: known("x", "K"), station: "S" }, "ws");
    await handle("connect.moved", "S", { connect: known("x", "K") }, "ws");
    for (const print of [fingerprint("slack", { botToken: "xoxb-1" }), fingerprint("comma", { token: "t" }), "nope", 5]) await handle("connect.list", "S", { fingerprint: print }, "ws");
    await handle("connect.list", "S", { fingerprint: fingerprint("slack", { botToken: "xoxb-1" }) }, "w9");
    await handle("connect.bots", "S", { bots: ["UB", "", 5, "UB", "UC"] }, "ws");
    await handle("connect.bots", "Z", { bots: [] }, "ws");
    await handle("connect.route", "S", { connect: known("cl"), channel: "C1", threadTs: "1", station: "S" }, "ws");
    await handle("connect.route", "S", { connect: known("cl"), channel: "C1", threadTs: "1", station: "H" }, "ws");
    await handle("connect.route", "S", { connect: known("cl"), channel: "C1", threadTs: "1" }, "ws");
    await handle("connect.route", "S", { connect: known("cl"), channel: 1, threadTs: "1" }, "ws");
    await handle("connect.route", "S", { connect: known("zz"), channel: "C1", threadTs: "1" }, "ws");
    await handle("connect.event", "S", { connect: known("cm"), kept: true, event: event("kept by S") }, "ws");
    await handle("connect.event", "S", { connect: known("zz"), kept: true, event: event("x") }, "ws");
    const d = described({ workspace: "ws" });
    await handle("connect.event", "S", { connect: known("rx", "S"), described: d, event: event("from S's connect") }, "ws");
    await handle("connect.event", "S", { connect: known("cl"), described: d, event: event("own") }, "ws");
    await handle("connect.event", "S", { connect: known("rx", "S"), described: { ...d, workspace: "w9" }, event: event("x") }, "ws");
    await handle("connect.call", "S", { connect: known("cl"), op: "userName", args: ["U1"] }, "ws");
    await handle("connect.call", "S", { connect: known("rx", "S"), op: "places", args: [] }, "ws");
    await w.same("each answered alike");
    // what it does of its own
    await call("route", (c) => c.route("cl", "C1", "1", "S"), ["cl", "C1", "1", "S"]);
    await call("route", (c) => c.route("cm", "C1", "1", "S"), ["cm", "C1", "1", "S"]);
    await call("route", (c) => c.route("rx@S", "C1", "1", "K"), ["rx@S", "C1", "1", "K"]);
    await call("route", (c) => c.route("nope", "C1", "1", "K"), ["nope", "C1", "1", "K"]);
    await call("heldBy", (c) => c.heldBy("ws", "slack", { botToken: "xoxb-9" }), ["ws", "slack", { botToken: "xoxb-9" }]);
    await call("heldBy", (c) => c.heldBy(null, "slack", { botToken: "xoxb-9" }), [null, "slack", { botToken: "xoxb-9" }]);
    await call("heldBy", (c) => c.heldBy("ws", "slack", {}), ["ws", "slack", {}]);
    for (const id of ["cl", "cm", "rx@S", "nope"]) {
      await call("describedFor", (c) => c.describedFor(id), [id]);
      await call("kindOf", (c) => c.kindOf(id), [id]);
      await call("runsOn", (c) => c.runsOn(id), [id]);
    }
    await call("learnOf", (c) => c.learnOf({ id: "y", origin: "K" }, "K", described()), [{ id: "y", origin: "K" }, "K", described()]);
    await call("learnOf", (c) => c.learnOf({ id: "cl", origin: "H" }, "K", described()), [{ id: "cl", origin: "H" }, "K", described()]);
    for (const ws of ["ws", "w9"]) {
      await call("ownIn", (c) => c.ownIn(ws), [ws]);
      await call("ownKinds", (c) => c.ownKinds(ws), [ws]);
      await call("movedAway", (c) => c.movedAway(ws), [ws]);
      await call("namedIn", (c) => c.namedIn(ws), [ws]);
    }
    await call("ownIds", (c) => c.ownIds());
    await w.same("all alike");
    await w.sameFiles("all kept alike", () => ts.remote.written());
  } finally {
    w.done();
  }
});

// ── the group connects ───────────────────────────────────────────────────────────────────────────────────────────

test("im/2's events: canonical JSON, MoonBit's order, ids, signatures, a direct space's id, the clock", { skip }, async () => {
  const p = await mb();
  const body = JSON.parse('{"text":"@Claude 看看 \\"CI\\"\\n\\ttab\\u0001 😀","input":"options","options":[{"label":"合并","detail":"现在","recommended":true},{"label":"先不"}],"placeholder":"","assignee":"","files":[],"reply_to":""}');
  for (const j of [body, JSON.parse('{"\\uffff\\uffff":1,"\\ud83d\\ude00":2,"ab":3,"B":4,"a":5,"\\u00e9":6}'), { x: [1000, 0, -0, 12345678901234, 0.1, 1e21, -3.5], b: "\b\f\u001f\u007f", n: null, t: true, f: false, o: { "": 1, v: [], body: {} } }, "s", 5, null, [[]]]) {
    await fn(p, "canonicalJson", () => canonicalJson(j), j);
  }
  for (const [a, b] of [["v", "body"], ["enc", "author"], ["a", "b"], ["b", "a"], ["", ""], ["é", "z"], ["😀", "ab"], ["\uffff", "😀"], ["abc", "z"]]) await fn(p, "moonOrder", () => moonOrder(a!, b!), a, b);
  for (const [a, b] of [["m_00112233aabbccdd", "m_ffeeddccbbaa9988"], ["m_ffeeddccbbaa9988", "m_00112233aabbccdd"], ["x", "x"]]) await fn(p, "directId", () => directId(a!, b!), a, b);
  for (const id of ["s_0123456789abcdef01234567", "d_0123456789abcdef01234567", "s_0123456789ABCDEF01234567", "x_0123456789abcdef01234567", "s_0123", "lobby", "t_0011223344556677", "t_00112233445566", ""]) {
    await fn(p, "isSpaceId", () => isSpaceId(id), id);
    await fn(p, "isTopicId", () => isTopicId(id), id);
  }
  const key = randomBytes(32).toString("hex");
  const signer = signingKey(key);
  const device = deviceOfKey(signer);
  const e = { space: "s_0123456789abcdef01234567", author: "m_00112233aabbccdd", device, dseq: 7, hlc: [1794882529815, 2] as [number, number], prev: "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9", topic: "t_0011223344556677", kind: "decision.ask", body };
  // (Ed25519 signs deterministically: the same key and text, the same signature)
  await fn(p, "signEvent", () => signEvent(signer, e), key, e);
  const own = signEvent(signer, e);
  const changed = { ...own, body: { ...own.body, text: "改过" } };
  for (const ev of [own, changed, { ...own, device: "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c" }, { ...own, sig: own.sig.toUpperCase() }, { ...own, sig: "00" }]) {
    await fn(p, "verified", () => verified(ev as Json), ev);
    await fn(p, "eventId", () => eventId(ev as Json), ev);
  }
  for (const j of [own, { ...own, v: 1 }, { ...own, enc: 1 }, { ...own, dseq: 0 }, { ...own, dseq: 1.5 }, { ...own, hlc: [1] }, { ...own, hlc: [1, "2"] }, { ...own, kind: 5 }, (({ body: _, ...rest }) => rest)(own), null, [], "x"]) {
    await fn(p, "eventOf", () => eventOf(j), j);
  }
  const stamped = { id: eventId(own), event: own, aseq: 3.7, n: -2.2, at: "9" };
  for (const j of [stamped, { ...stamped, id: "0".repeat(64) }, { ...stamped, event: changed, id: eventId(changed as Json) }, { ...stamped, aseq: null }, {}]) {
    await fn(p, "stampedOf", () => stampedOf(j), j);
  }
  const steps = [{ op: "next", wall: 100 }, { op: "next", wall: 100 }, { op: "next", wall: 50 }, { op: "saw", ms: 200, n: 3 }, { op: "next", wall: 150 }, { op: "saw", ms: 200, n: 1 }, { op: "next", wall: 300 }];
  await fn(p, "hlc", () => {
    const h = new Hlc();
    const out: Json[] = [];
    for (const s of steps) if (s.op === "next") out.push(h.next(s.wall!)); else h.saw(s.ms!, s.n!);
    return out;
  }, steps);
  for (const [t, card] of [
    ["合并吗？", { type: "options", options: [{ label: "合并", recommended: true }, { label: "先不", detail: "留着" }, { label: " " }, { label: "合并" }, { label: "x".repeat(300), detail: "y".repeat(300) }, ...Array.from({ length: 10 }, (_, i) => ({ label: `o${i}`, recommended: "yes" }))] }],
    ["要 key", { type: "text", placeholder: "sk_test_..." }],
    ["要 key", { type: "text" }],
    ["?", { type: "options" }],
    ["?", null],
  ] as const) await fn(p, "decisionBody", () => decisionBody(t, card), t, card);
  for (const [sp, tp] of [["s_1", "lobby"], ["s_1", ""], ["s_1", "t_2"]]) await fn(p, "threadOf", () => threadOf(sp!, tp!), sp, tp);
  for (const th of [{ channel: "s_1", threadTs: "s_1" }, { channel: "s_1", threadTs: "t_2" }]) await fn(p, "streamOf", () => streamOf(th), th);
  for (const [sp, tp] of [["s_1", "lobby"], ["s_1", ""], ["s_1", "t_2"]]) await fn(p, "streamKey", () => streamKey(sp!, tp!), sp, tp);
});

test("what a group connect heard of its anchor, kept on disk (im/2; im/1's read as nothing)", { skip }, async () => {
  const p = await mb();
  for (const kept of [
    null,
    "{\"g\":{\"v\":2,\"spaces\":{\"s_1\":{\"aseq\":3,\"dseq\":2,\"prev\":\"ab\"},\"s_2\":{\"aseq\":-1,\"dseq\":1.5,\"prev\":5}},\"last\":{\"s_1\":3,\"s_1/t_9\":2,\"x\":\"no\"}},\"h\":{\"v\":2,\"spaces\":[]},\"old\":{\"since\":\"5\",\"last\":{\"c1\":3}}}",
    "nope",
    "[]",
  ]) {
    const w = await twins(p);
    try {
      const path = (d: string) => join(d, "group-threads.json");
      if (kept !== null) for (const d of [w.tsDir, w.mbDir]) await writeFile(path(d), kept);
      const ts = new GroupThreads(path(w.tsDir));
      w.files.push(ts);
      const h = await p.ok({ op: "threads.open", path: path(w.mbDir) });
      await w.same(`opened on ${kept}`);
      const call = (name: string, args: Json[]) => same(p, `${name} ${JSON.stringify(args)}`, () => (ts as Json)[name](...args), { op: "threads.call", h, name, args });
      for (const [name, args] of [
        ["spaces", ["g"]], ["spaces", ["x"]], ["space", ["g", "s_1"]], ["space", ["g", "s_9"]], ["last", ["g", "s_1"]], ["last", ["g", "x"]], ["last", ["q", "s_1"]],
        ["took", ["g", "s_1", 2]], ["took", ["g", "s_1", 9, "s_1/t_9"]], ["took", ["n", "s_3", 1]], ["took", ["n", "s_3", 0, "s_3"]], ["took", ["n", "10", 4, "10"]],
        ["said", ["g", "s_1", 2, "zz"]], ["said", ["g", "s_1", 3, ""]], ["said", ["g", "s_1", 3, ""]], ["said", ["g", "s_1", 3, "cd"]], ["said", ["g", "s_1", 3, "cd"]], ["said", ["g", "s_4", 1, ""]], ["said", ["g", "s_1", 5, ""]],
        ["forget", ["g", "s_1"]], ["forget", ["g", "zz"]], ["forget", ["zz", "zz"]], ["drop", ["h"]], ["drop", ["zz"]], ["spaces", ["g"]], ["space", ["n", "s_3"]],
      ] as const) await call(name, args as unknown as Json[]);
      await call("flushed", []);
      await w.sameFiles("written alike", () => ts.flushed());
    } finally {
      w.done();
    }
  }
});

/// An anchor of the IM on a mesh in memory, and both sides' endpoints on it (the program's through the test's lines).
async function imWorld(p: Program) {
  const w = await twins(p);
  const mesh = memoryMesh();
  const server = new ImServer(await mesh.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("im/2")], relayUrls: [], discovery: false } as Json));
  const handles = new Map<number, Json>();
  let next = 0;
  const keep = (v: Json) => (handles.set(++next, v), next);
  w.own = (name, args) => {
    if (!name.startsWith("mesh.")) return undefined;
    return (async () => {
      switch (name) {
        case "mesh.bind": {
          const o = args[0];
          const e = await mesh.bind({ secretKey: Buffer.from(o.secretKey, "hex"), alpns: (o.alpns ?? []).map((a: string) => Buffer.from(a)), relayUrls: o.relayUrls, discovery: false } as Json);
          return { h: keep(e), id: e.id() };
        }
        case "mesh.connect":
          return keep(await handles.get(args[0]).connect(args[1], Buffer.from(args[2])));
        case "mesh.accept": {
          const c = await handles.get(args[0]).accept();
          return c ? { h: keep(c), remote: c.remoteId() } : null;
        }
        case "mesh.openBi":
          return keep(await handles.get(args[0]).openBi());
        case "mesh.acceptBi": {
          const s = await handles.get(args[0]).acceptBi();
          return s ? keep(s) : null;
        }
        case "mesh.read": {
          const b = await handles.get(args[0]).read();
          return b === null ? null : b.toString("hex");
        }
        case "mesh.write":
          return handles.get(args[0]).write(Buffer.from(args[1], "hex"));
        case "mesh.finish":
          return handles.get(args[0]).finish();
        case "mesh.reset":
          return handles.get(args[0]).reset(args[1]);
        case "mesh.stopped":
          return handles.get(args[0]).stopped();
        case "mesh.endpointClose":
          return handles.get(args[0]).close();
      }
      throw new Error(`no ${name}`);
    })();
  };
  w.ownNote = (name, args) => {
    if (name !== "mesh.close") return false;
    const c = handles.get(args[0]);
    if (!c.isClosed()) c.close(args[1], args[2]);
    return true;
  };
  return { w, mesh, server };
}

test("a group connect (im/2): let in by its code, its spaces and topics taken once, decisions, live state, Stop, secrets", { skip }, async () => {
  const p = await mb();
  const { w, mesh, server } = await imWorld(p);
  const stops: (() => Promise<unknown>)[] = [];
  try {
    const ada = server.member("Ada", true);
    const bo = server.member("Bo");
    const keyT = randomBytes(32).toString("hex");
    const keyM = randomBytes(32).toString("hex");
    const threadsT = new GroupThreads(join(w.tsDir, "group-threads.json"));
    w.files.push(threadsT);
    const th = await p.ok({ op: "threads.open", path: join(w.mbDir, "group-threads.json") });
    const o = { connect: "g", server: server.endpoint.id(), relays: ["https://relay.test"], botName: "Claude" };
    const h = await p.ok({ op: "gsurface.new", ...o, key: keyM, code: server.code(), threads: th });
    // (how many pieces the event stream came in is the mesh's: what each side heard is held to the same, not that)
    const ts = new GroupSurface({ ...o, key: keyT, code: server.code(), threads: threadsT, endpoints: mesh as Json, clock: w.time.clock });
    const ownNote = w.ownNote;
    w.ownNote = (name, args) => name === "gsurf.heard" || ownNote(name, args);
    const handler = (e: Json) => w.tsAsk("gsurf.handled", [h, e]).then(() => {});
    stops.push(() => ts.stop(), () => p.ok({ op: "gsurface.call", h, name: "stop" }));
    ts.onChange(() => w.ts.push("gsurf.changed", [h]));
    await p.ok({ op: "gsurface.call", h, name: "onChange" });
    await ts.start(handler);
    await p.ok({ op: "gsurface.call", h, name: "start" });
    await server.until(() => server.devices.size === 4);
    const settle = async () => {
      for (let i = 0; i < 6; i++) await w.rest();
    };
    await settle();
    const botT = ts.botUserId();
    const botM = (await p.ok({ op: "gsurface.call", h, name: "state" })).identity.botUserId;
    const deviceT = deviceOfKey(signingKey(keyT));
    const deviceM = deviceOfKey(signingKey(keyM));
    w.alias = { ts: [[botT, "<bot>"], [deviceT, "<device>"]], mb: [[botM, "<bot>"], [deviceM, "<device>"]] };
    // (each side's messages handed on so far, counted across the checks)
    const handed = { ts: 0, mb: 0 };
    const count = (side: "ts" | "mb") => handed[side] + w[side].said.filter(([x]) => x === "gsurf.handled").length;
    const same_ = w.same.bind(w);
    w.same = async (what: string) => {
      handed.ts = count("ts");
      handed.mb = count("mb");
      await same_(what);
    };
    const said = async (n: number) => {
      for (let i = 0; i < 4000 && !(count("ts") >= n && count("mb") >= n); i++) await w.rest();
      assert.ok(count("ts") >= n && count("mb") >= n, `never handed ${n} messages on (${count("ts")}, ${count("mb")})`);
    };
    await w.same("joined: who it is, its name as asked");
    // (a space of each's, the same people saying the same in both: its places the same)
    const both = <T,>(f: (bot: string, side: "ts" | "mb") => T): { ts: T; mb: T } => ({ ts: f(botT, "ts"), mb: f(botM, "mb") });
    const alias = (v: { ts: string; mb: string }, as: string) => {
      w.alias.ts.push([v.ts, as]);
      w.alias.mb.push([v.mb, as]);
    };
    const g = both((bot) => server.group("Team", ada, [ada, bo, bot]));
    alias(g, "<space>");
    const d = both((bot) => server.direct(ada, bot));
    alias(d, "<direct>");
    await settle();
    const sayBoth = (space: { ts: string; mb: string }, from: string, words: string, more: (side: "ts" | "mb") => Json = () => ({})) => both((_, side) => server.say(space[side], from, words, more(side)));
    sayBoth(g, ada, "hello all");
    sayBoth(g, bo, "@claude look at this");
    sayBoth(g, bo, "@Claudette not you");
    sayBoth(d, ada, "hi there");
    const picture = pngOf(640, 480);
    const file = both((_, side) => server.upload(g[side], ada, "pic.png", "image/png", picture));
    const first = server.messages(g.ts)[0]!.id;
    const firstM = server.messages(g.mb)[0]!.id;
    sayBoth(g, ada, "a file @Claude", (side) => ({ files: [file[side].sha256], replyTo: side === "ts" ? first : firstM }));
    await said(5);
    await settle();
    await w.same("each message taken once, a space's mentions addressed, a direct space's every one");
    // a topic about the bot, opened from one of its messages; one not about it
    const topic = both((bot, side) => server.topic(g[side], bo, "the CI @Claude", ""));
    alias(topic, "<topic>");
    sayBoth(g, bo, "in the topic", (side) => ({ topic: topic[side] }));
    const plain = both((_, side) => server.topic(g[side], bo, "lunch", ""));
    alias(plain, "<plain>");
    sayBoth(g, bo, "where to eat", (side) => ({ topic: plain[side] }));
    await said(7);
    await settle();
    await w.same("a topic about the bot calls it; one not about it does not");
    // what it posts: words, files, long words, a card as a decision, a field
    const thread = (space: { ts: string; mb: string }, tp = "lobby") => both((_, side) => threadOf(space[side], tp === "lobby" ? "lobby" : (tp as Json)[side]));
    const surfaceCall = async (name: string, args: (side: "ts" | "mb") => Json[]) => {
      const want = await settled(async () => {
        const v = await (ts as Json)[name](...args("ts"));
        return v instanceof Uint8Array ? hex(v) : v;
      });
      const got = await p.ask({ op: "gsurface.call", h, name: "call", args: [name, wire(args("mb"))] });
      delete got.id;
      const n = (side: "ts" | "mb", v: Json) => w.aliased(norm(v, [w.tsDir, w.mbDir]), side);
      if ("error" in want) assert.deepEqual(n("mb", { error: got.error, kind: got.kind }), n("ts", want), name);
      else assert.deepEqual(n("mb", got), n("ts", want), `${name} ${JSON.stringify(args("ts")).slice(0, 100)}`);
    };
    for (const dir of [w.tsDir, w.mbDir]) await writeFile(join(dir, "note.txt"), "the words of a file");
    const lobby = thread(g);
    await surfaceCall("post", (side) => [lobby[side], "plain words", [], null]);
    await surfaceCall("post", (side) => [lobby[side], "with a file", [{ name: "note.txt", path: join(side === "ts" ? w.tsDir : w.mbDir, "note.txt") }], null]);
    await surfaceCall("post", (side) => [lobby[side], "x".repeat(12000), [], null]);
    await surfaceCall("post", (side) => [lobby[side], "Which one?", [], { type: "options", options: [{ label: "Merge", recommended: true }, { label: "Wait", detail: "a day" }] }]);
    await settle();
    // answered by its button: the person's choice to the agent
    const asked = both((_, side) => server.messages(g[side]).at(-1)!.id);
    both((_, side) => server.resolve(g[side], ada, asked[side], "Wait"));
    await said(8);
    await settle();
    await w.same("a decision answered: its choice to the agent");
    await surfaceCall("post", (side) => [lobby[side], "Again?", [], { type: "options", options: [{ label: "Yes" }, { label: "No" }] }]);
    await settle();
    sayBoth(g, ada, " 2 ");
    await said(9);
    await settle();
    await w.same("a person's message where a decision waits closes it, an option's number its words");
    await surfaceCall("post", (side) => [lobby[side], "Key?", [], { type: "text", placeholder: "sk_..." }]);
    const textAsked = both((_, side) => server.messages(g[side]).at(-1)!);
    await surfaceCall("cardEnded", (side) => [lobby[side], String(textAsked[side].aseq), "", null, { why: "withdrawn" }]);
    both((_, side) => server.resolve(g[side], ada, textAsked[side].id, "sk_late"));
    sayBoth(g, ada, "after");
    await said(10);
    await settle();
    await w.same("a card ended on the station: its answer after is no word to the agent");
    // an anchor from before decisions: a card as numbered words
    server.noDecisions = true;
    await surfaceCall("post", (side) => [lobby[side], "Pick", [], { type: "options", options: [{ label: "A" }, { label: "B" }] }]);
    server.noDecisions = false;
    sayBoth(g, ada, "1");
    await said(11);
    await settle();
    await w.same("words where the anchor takes no decision, answered by number");
    // an edit, Stop on its live state, secrets both ways
    both((_, side) => server.edit(g[side], ada, (side === "ts" ? server.messages(g.ts) : server.messages(g.mb))[0]!.id, "hello everyone"));
    await settle();
    both((_, side) => server.stop(g[side], ada));
    both((_, side) => server.stop(g[side], ada, "lobby", "m_someone_else"));
    await settle();
    both((_, side) => server.secretThrough(g[side], ada, side === "ts" ? botT : botM, "API key", "sk-123"));
    await settle();
    const direct = await Promise.all([server.secretDirect(mesh as Json, g.ts, ada, deviceT, "db pass", "hunter2"), server.secretDirect(mesh as Json, g.mb, ada, deviceM, "db pass", "hunter2")]);
    assert.deepEqual(direct[1], direct[0], "the device's answer");
    const forged = await Promise.all([server.secretDirect(mesh as Json, g.ts, ada, deviceT, "x", "y", "lobby", randomBytes(32)), server.secretDirect(mesh as Json, g.mb, ada, deviceM, "x", "y", "lobby", randomBytes(32))]);
    assert.deepEqual(forged[1], forged[0], "a device not the member's: refused");
    await said(13);
    await settle();
    const secretIds = (side: "ts" | "mb") => w[side].said.filter(([n, a]) => n === "gsurf.handled" && a[1].message?.files?.[0]?.url?.startsWith("secret:")).map(([, a]) => a[1].message.files[0].id);
    const ids = { ts: secretIds("ts"), mb: secretIds("mb") };
    for (let i = 0; i < ids.ts.length; i++) alias({ ts: ids.ts[i], mb: ids.mb[i] }, `<secret ${i}>`);
    // (a secret's place among the space's events is said with its id's first digits: those the test drew)
    // (and a Stop's moment, the anchor's clock as each side's was pressed, one after the other)
    const strip = (side: "ts" | "mb") =>
      (w[side].said = w[side].said.map(([n, a]) =>
        n === "gsurf.handled" && a[1].message?.files?.[0]?.url?.startsWith("secret:")
          ? [n, [a[0], { ...a[1], message: { ...a[1].message, ts: a[1].message.ts.split(".")[0] } }]]
          : n === "gsurf.handled" && a[1].type === "stop"
            ? [n, [a[0], { ...a[1], ts: "<at>" }]]
            : [n, a],
      ) as Json);
    strip("ts");
    strip("mb");
    await w.same("an edit, Stop (its own, not another bot's), secrets handed through the anchor and end to end");
    for (let i = 0; i < ids.ts.length; i++) {
      await surfaceCall("download", (side) => [{ id: ids[side][i], name: "s.secret", size: 6, url: `secret:${ids[side][i]}` }]);
      await surfaceCall("download", (side) => [{ id: ids[side][i], name: "s.secret", size: 6, url: `secret:${ids[side][i]}` }]);
    }
    for (const [name, args] of [
      ["history", (side: "ts" | "mb") => [lobby[side], "", 3]], ["history", (side: "ts" | "mb") => [lobby[side], "5", 100]], ["history", (side: "ts" | "mb") => [lobby[side], "x", 2]],
      ["history", (side: "ts" | "mb") => [threadOf(g[side], topic[side]), "", 50]],
      ["history", (side: "ts" | "mb") => [lobby[side], "", Number.NaN]], ["history", (side: "ts" | "mb") => [lobby[side], "8", Number.NaN]],
      ["quoted", (side: "ts" | "mb") => [lobby[side], "1"]], ["quoted", (side: "ts" | "mb") => [lobby[side], "0"]], ["quoted", (side: "ts" | "mb") => [lobby[side], "999"]],
      ["places", () => []], ["peopleIn", (side: "ts" | "mb") => [g[side]]], ["peopleIn", () => ["nope"]], ["channelName", (side: "ts" | "mb") => [g[side]]], ["channelName", (side: "ts" | "mb") => [d[side]]],
      ["download", (side: "ts" | "mb") => [{ id: file[side].sha256, name: "pic.png", size: 16, url: `${g[side]}/${file[side].sha256}` }]],
      ["download", () => [{ id: "x", name: "x", size: 1, url: null }]],
      ["userName", () => [ada]], ["userName", () => ["nobody"]], ["userEmail", () => [ada]],
    ] as const) await surfaceCall(name, args as Json);
    for (const [name, args] of [["mention", () => [ada]], ["mention", () => ["nobody"]], ["knownPerson", () => [bo]], ["knownChannel", (side: "ts" | "mb") => [g[side]]], ["knownChannel", () => ["nope"]], ["sessionLink", () => ["u", "l"]], ["botName", () => []], ["platform", () => []]] as const) {
      const want = (ts as Json)[name](...(args as Json)("ts"));
      const got = await p.ok({ op: "gsurface.call", h, name: "get", args: [name, (args as Json)("mb")] });
      assert.deepEqual(w.aliased(got, "mb"), w.aliased(wire(want), "ts"), name);
    }
    // its live state as the agent works
    await surfaceCall("working", (side) => [lobby[side], "1", "reading the logs", null]);
    await settle();
    await surfaceCall("working", (side) => [lobby[side], null, "x".repeat(250), null]);
    await w.both(2000);
    await settle();
    await w.both(60_000);
    await settle();
    await surfaceCall("working", (side) => [lobby[side], null, "", null]);
    await settle();
    await w.both(60_000);
    await settle();
    const lives = (bot: string) => server.lives.filter((l) => l.author === bot).map(({ space: _s, author: _a, device: _d, at: _at, ...l }) => l);
    assert.deepEqual(lives(botM), lives(botT), "its live state said alike, again while it stands, done as the turn ends");
    assert.ok(lives(botT).length >= 4, "said, changed, said again, done");
    // its own count gone back while it runs (its place kept): the anchor refuses what it says for its count, it syncs
    // and says it again after the anchor's
    const placeOf = (space: string) => server.spaces.get(space)!.lastAseq;
    threadsT.drop("g");
    threadsT.took("g", g.ts, placeOf(g.ts));
    await p.ok({ op: "threads.call", h: th, name: "drop", args: ["g"] });
    await p.ok({ op: "threads.call", h: th, name: "took", args: ["g", g.mb, placeOf(g.mb)] });
    const refusedBefore = server.refusals.filter((r) => r === "dseq").length;
    await surfaceCall("post", (side) => [lobby[side], "after its count went back", [], null]);
    await settle();
    assert.equal(server.refusals.filter((r) => r === "dseq").length - refusedBefore, 2, "each refused once for its count, synced, said again");
    await surfaceCall("begin", (side) => [g[side], "a new thread"]);
    await settle();
    // what each posted, as the anchor keeps it
    const posted = (space: string) => server.messages(space).map((m) => ({ aseq: m.aseq, n: m.n, kind: m.kind, mine: m.author === botT || m.author === botM, text: m.text, files: m.files.map((f: Json) => ({ name: f.name, mime: f.mime, size: f.size, width: f.width, height: f.height })), open: m.open, options: m.options }));
    assert.deepEqual(posted(g.mb), posted(g.ts), "posted alike");
    // the link cut: what was said meanwhile taken once it is back
    server.cut();
    await settle();
    sayBoth(g, ada, "while it was away");
    await w.both(1000);
    await settle();
    await said(14);
    await settle();
    await w.same("its link back, what was said meanwhile taken");
    await stops.shift()!();
    await stops.shift()!();
    await threadsT.flushed();
    await p.ok({ op: "threads.call", h: th, name: "flushed", args: [] });
    // started again from what it kept, its own count there gone back (a station's state restored from before): what
    // was said while it was down taken once, its count taken again of what the anchor's sync says, what it says after it
    for (const [dir, space] of [[w.tsDir, g.ts], [w.mbDir, g.mb]] as const) {
      const path = join(dir, "group-threads.json");
      const v = JSON.parse(await readFile(path, "utf8"));
      v.g.spaces[space] = { ...v.g.spaces[space], dseq: 0, prev: "" };
      await writeFile(path, JSON.stringify(v));
    }
    sayBoth(g, ada, "while it was down");
    const refusedAtRestart = server.refusals.filter((r) => r === "dseq").length;
    const threadsT2 = new GroupThreads(join(w.tsDir, "group-threads.json"));
    w.files.push(threadsT2);
    const th2 = await p.ok({ op: "threads.open", path: join(w.mbDir, "group-threads.json") });
    const h2 = await p.ok({ op: "gsurface.new", ...o, key: keyM, code: null, threads: th2 });
    const ts2 = new GroupSurface({ ...o, key: keyT, code: null, threads: threadsT2, endpoints: mesh as Json, clock: w.time.clock });
    stops.push(() => ts2.stop(), () => p.ok({ op: "gsurface.call", h: h2, name: "stop" }));
    await ts2.start((e: Json) => w.tsAsk("gsurf.handled", [h2, e]).then(() => {}));
    await p.ok({ op: "gsurface.call", h: h2, name: "start" });
    await settle();
    for (let i = 0; i < 4000 && !(w.ts.said.some(([n, a]) => n === "gsurf.handled" && a[0] === h2) && w.mb.said.some(([n, a]) => n === "gsurf.handled" && a[0] === h2)); i++) await w.rest();
    await settle();
    const want2 = await settled(() => ts2.post(lobby.ts, "after the restart", []));
    const got2 = await p.ask({ op: "gsurface.call", h: h2, name: "call", args: ["post", wire([lobby.mb, "after the restart", [], null])] });
    delete got2.id;
    assert.deepEqual(got2, want2, "said again after the anchor's count");
    assert.equal(server.refusals.filter((r) => r === "dseq").length - refusedAtRestart, 0, "its count taken again of the anchor's sync, never said behind it");
    await settle();
    assert.deepEqual(posted(g.mb), posted(g.ts), "posted alike after the restart");
    await w.same("started again: what was said while it was down taken once");
    await stops.pop()!();
    await stops.pop()!();
    await threadsT2.flushed();
    await p.ok({ op: "threads.call", h: th2, name: "flushed", args: [] });
    // (its last event's id: of its own space, device and clock)
    for (const dir of [w.tsDir, w.mbDir]) {
      const path = join(dir, "group-threads.json");
      await writeFile(path, (await readFile(path, "utf8")).replace(/"prev":"[0-9a-f]{64}"/g, '"prev":"<id>"'));
    }
    await w.sameFiles("what it heard kept");
  } finally {
    for (const s of stops) await s();
    await server.close();
    w.done();
  }
});

/// A PNG's head of so many pixels (its signature and IHDR: all a size is read of).
function pngOf(width: number, height: number): Buffer {
  const b = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]).copy(b, 0);
  b.writeUInt32BE(width, 16);
  b.writeUInt32BE(height, 20);
  return b;
}

test("the group connects: joined as config.json says, its code taken out once let in, how each shows", { skip }, async () => {
  const p = await mb();
  const { w, mesh, server } = await imWorld(p);
  const stops: (() => Promise<unknown>)[] = [];
  try {
    const ada = server.member("Ada", true);
    const keyT = randomBytes(32).toString("hex");
    const keyM = randomBytes(32).toString("hex");
    const codeT = server.code();
    const codeM = server.code();
    const entry = (key: string, code: string) => ({ id: "g", kind: "group", enabled: true, group: { server: server.endpoint.id().toUpperCase(), relays: ["https://relay.test"], key, code, botName: "Claude" }, bind: { runtime: "claude" } });
    const rawT = { connects: [entry(keyT, codeT), { id: "s", kind: "slack" }] };
    const rawM = { connects: [entry(keyM, codeM), { id: "s", kind: "slack" }] };
    w.alias = { ts: [[keyT, "<key>"], [codeT, "<code>"], [codeHash(codeT), "<bound>"], [deviceOf(keyT)!, "<device>"]], mb: [[keyM, "<key>"], [codeM, "<code>"], [codeHash(codeM), "<bound>"], [deviceOf(keyM)!, "<device>"]] };
    const raw = { v: structuredClone(rawT) };
    const cfg = tsConfig(w, raw);
    await p.ok({ op: "env", raw: structuredClone(rawM), bound: true, workspaces: [], live: [] });
    const ts = makeGroup({
      data: w.tsDir,
      store: { liveSessions: () => [], notify: () => {} } as Json,
      config: cfg.file,
      receive: (connect, event) => w.tsAsk("hub.receive", [connect, event]).then(() => {}),
      bound: () => true,
      inWorkspace: () => true,
      clock: w.time.clock,
      endpoints: () => mesh as Json,
    });
    const h = await p.ok({ op: "group.make", data: w.mbDir });
    stops.push(() => ts.close(), () => p.ok({ op: "group.call", h, name: "close" }));
    const shown = async (what: string) => {
      const want = ts.shown(raw.v.connects[0]);
      const got = await p.ok({ op: "group.call", h, name: "shown", args: [(await p.ok({ op: "config.raw" })).connects[0]] });
      assert.deepEqual(w.aliased(norm(got, []), "mb"), w.aliased(norm(wire(want), []), "ts"), what);
    };
    await shown("waiting to join");
    await same(p, "connects", () => ts.connects(), { op: "connects.call", h, name: "connects", args: [] }).catch(async () => {
      assert.deepEqual(w.aliased(await p.ok({ op: "connects.call", h, name: "connects", args: [] }), "mb"), w.aliased(wire(ts.connects()), "ts"));
    });
    await ts.reconcile();
    await p.ok({ op: "connects.call", h, name: "reconcile", args: [] });
    await server.until(() => server.devices.size === 3);
    for (let i = 0; i < 10; i++) await w.rest();
    const botT = ts.chat("g")!.botUserId();
    const botM = (await p.ok({ op: "group.call", h, name: "surface", args: ["g", "botUserId", []] }));
    w.alias.ts.push([botT, "<bot>"]);
    w.alias.mb.push([botM, "<bot>"]);
    await w.sameUnordered("joined: its member and name kept, its code taken out");
    raw.v = cfg.file.raw();
    await shown("joined");
    const state = async () => assert.deepEqual(w.aliased(await p.ok({ op: "connects.call", h, name: "state", args: ["g"] }), "mb"), w.aliased(wire(ts.state("g")), "ts"));
    await state();
    const pt = server.direct(ada, botT);
    const pm = server.direct(ada, botM);
    w.alias.ts.push([pt, "<private>"]);
    w.alias.mb.push([pm, "<private>"]);
    server.say(pt, ada, "hello");
    server.say(pm, ada, "hello");
    for (let i = 0; i < 2000 && !(w.ts.said.some(([n]) => n === "hub.receive") && w.mb.said.some(([n]) => n === "hub.receive")); i++) await w.rest();
    await w.same("what its server says reaches the hub");
    await stops.shift()!();
    await stops.shift()!();
    // (what it heard: each space's place and its own count, each stream's last)
    const heard = async (d: string) => JSON.parse(await readFile(join(d, "group-threads.json"), "utf8")).g;
    const prevOf = (v: Json) => JSON.parse(JSON.stringify(v).replace(/"prev":"[0-9a-f]{64}"/g, '"prev":"<id>"'));
    assert.deepEqual(prevOf(w.aliased(await heard(w.mbDir), "mb")), prevOf(w.aliased(await heard(w.tsDir), "ts")), "what it heard kept");
    await w.sameUnordered("closed alike");
  } finally {
    for (const s of stops) await s();
    await server.close();
    w.done();
  }
});

test("POST /connects/:id/move: the connect moved, the overview answered; a refusal in its words", { skip }, async () => {
  const { WorkspaceConnectsLive } = await import("../src/connects/workspace.ts");
  const services = await import("../src/services.ts");
  const { Agents } = await import("../src/sessions/agents.ts");
  const p = await mb();
  const raw0 = { connects: [{ id: "cl", kind: "slack", slack: { botToken: "xoxb-1" } }, { id: "a+b", kind: "slack" }] };
  const answers = (name: string, args: Json[]): Json => {
    switch (name) {
      case "hub.chatOf":
        return surfaces.cl;
      case "hub.configConnects":
        return [parsed({ id: "cl" }), parsed({ id: "a+b" })];
      case "store.connectThreads":
      case "store.connectLocalThreads":
        return [];
      case "agents.overview":
        return { overview: true };
      case "bus.ask":
        return args[1].method === "connect.take" && args[1].connect.id === "a+b" ? { throw: "boom" } : { json: { ok: true } };
    }
    return null;
  };
  const { w, call } = await wsTwins(p, raw0, answers);
  const scope = Effect.runSync(Scope.make());
  try {
    // (the TypeScript's route as its layer gives it, over a WorkspaceConnects of its own on the same world)
    const raw = { v: structuredClone(raw0) };
    let routes: Json[] = [];
    const sync = (name: string, args: Json[]) => (w.ts.push(name, args), answers(name, args));
    const hub = {
      chatOf: (id: string) => snapSurface(id, sync("hub.chatOf", [id]), w.tsAsk, w.ts),
      config: () => ({ connects: sync("hub.configConnects", []) }),
      receive: async () => {},
      movedTo: () => null,
      quietIn: () => false,
      surface: () => "slack:T1",
      toldBots: { set: () => {} },
    };
    const ask = (station: string, request: Json) => {
      w.ts.push("bus.ask", [station, wire(request), null]);
      const got = answers("bus.ask", [station, request]);
      return got?.throw ? Promise.reject(new Error(got.throw)) : Promise.resolve(got.json);
    };
    await Effect.runPromise(
      Layer.build(WorkspaceConnectsLive).pipe(
        Effect.provideService(services.Paths, { data: fresh("connects-hub-route-"), app: "" } as Json),
        Effect.provideService(Agents, { hub, surfaces: () => {}, connects: () => {}, route: () => {}, connectHeld: () => {}, overview: async () => w.tsAsk("agents.overview", []) } as Json),
        Effect.provideService(services.Peers, { ask, on: () => {}, heard: () => {} } as Json),
        Effect.provideService(services.Store, Object.fromEntries(["dropConnectThreadStation", "setConnectThreadStation", "connectThreadStation", "dropConnectThreads", "connectThreads", "connectLocalThreads", "threadAt"].map((k) => [k, (...a: Json[]) => sync(`store.${k}`, a)])) as Json),
        Effect.provideService(services.StationConfig, { raw: () => raw.v, updateSoon: async (f: Json) => { f(raw.v); await w.tsAsk("config.updated", [raw.v]); } } as Json),
        Effect.provideService(services.Parts, { routes: (r: Json[]) => void (routes = r) } as Json),
        Effect.provideService(services.ControlPlane, { state: { state: { station: "H" }, home: () => "ws", membership: (ws: string) => (ws === "ws" ? { peers: roster } : null) } } as Json),
        Scope.provide(scope),
      ),
    );
    await w.rest();
    w.ts.said = [];
    w.mb.said = [];
    const route = routes[0];
    const answer = async (at: string, body: string, viewer: Json, lang: string) => {
      const m = route.pattern.exec(`connects/${at}/move`);
      const r = { path: `/connects/${at}/move`, body: Buffer.from(body), viewer, lang };
      const got = await route.handle(r, [m[1]]);
      return { status: got.status, body: JSON.parse(Buffer.isBuffer(got.body) ? got.body.toString() : got.body) };
    };
    for (const [at, body, viewer, lang] of [
      ["cl", "{\"station\":\"Z\"}", { workspace: "ws", email: "a@x" }, "en"],
      ["cl", "{}", { workspace: "ws", email: "a@x" }, "zh"],
      ["cl", "nope", { workspace: "ws", email: "a@x" }, "zh"],
      ["nope", "{\"station\":\"S\"}", { workspace: "ws", email: "a@x" }, "zh"],
      ["cl", "{\"station\":\"S\"}", { workspace: "w9", email: "a@x" }, "zh"],
      ["a%2Bb", "{\"station\":\"S\"}", { workspace: "ws" }, "zh"],
      ["cl", "{\"station\":\"S\"}", { workspace: "ws", email: "a@x" }, "zh"],
    ] as const) {
      await call("moveRoute", () => answer(at, body, viewer, lang), [`/connects/${at}/move`, at, body, viewer.workspace, (viewer as Json).email, lang]);
      // (a move that got no answer is settled in the background: at rest before the next is asked)
      await w.rest();
    }
    await w.same("moved, or refused in its words");
  } finally {
    await Effect.runPromise(Scope.close(scope, Exit.void));
    w.done();
  }
});

test("a connected surface's socket: opened, what it says, ended, refused, gone quiet, never opened", { skip }, async () => {
  const { WebSocketServer, default: WebSocket } = await import("ws");
  const { createServer } = await import("node:net");
  const p = await mb();
  const w = await twins(p);
  // (a socket's server on 127.0.0.1: one that says, closes, refuses, keeps quiet; and one that never answers the handshake)
  const wss = new WebSocketServer({ host: "127.0.0.1", port: 0, autoPong: false, verifyClient: (info: Json) => !info.req.url.startsWith("/refuse") } as Json);
  wss.on("connection", (socket: Json, req: Json) => {
    if (req.url === "/talk") {
      socket.send("hello");
      socket.send(Buffer.from([1, 2, 3]));
      socket.send("end");
    } else if (req.url === "/fail") socket.send("fail:bad thing");
    else if (req.url === "/close") socket.close();
  });
  await new Promise((r) => wss.once("listening", r));
  const held = new Set<Json>();
  const mute = createServer((c) => void held.add(c));
  await new Promise<void>((r) => mute.listen(0, "127.0.0.1", () => r()));
  const port = (wss.address() as Json).port;
  const mutePort = (mute.address() as Json).port;
  // (the program's sockets: real ones of the test's, what each says told the program in order)
  const clients = new Map<number, Json>();
  w.ownNote = (name, args) => {
    if (!name.startsWith("ws.")) return false;
    if (name === "ws.open") {
      const [, sh, url, headers] = args;
      const ws = new WebSocket(url, { headers });
      clients.set(sh, ws);
      let chain = Promise.resolve();
      const tell = (event: Json) => (chain = chain.then(() => p.ok({ op: "ws.event", h: sh, event }).then(() => {})));
      ws.on("open", () => tell({ type: "open" }));
      ws.on("message", (data: Buffer, binary: boolean) => tell({ type: "message", hex: Buffer.from(data).toString("hex"), binary }));
      ws.on("pong", () => tell({ type: "pong" }));
      ws.on("ping", () => tell({ type: "ping" }));
      ws.on("close", () => tell({ type: "close" }));
      ws.on("error", (e: Error) => tell({ type: "error", message: e.message }));
      ws.on("unexpected-response", (_req: Json, res: Json) => tell({ type: "refused", status: res.statusCode, said: res.headers["handshake-msg"] ?? "" }));
    } else if (name === "ws.ping") clients.get(args[0])?.ping();
    else if (name === "ws.terminate") {
      const c = clients.get(args[0]);
      c?.removeAllListeners();
      c?.on("error", () => {});
      c?.terminate();
    }
    return true;
  };
  try {
    const o = { connect: "c", pingMs: 15000, staleMs: 45000, statusMs: 1000 };
    for (const [path, steps] of [["/talk", 0], ["/fail", 0], ["/close", 0], ["/refuse", 0], ["/quiet", 4], ["mute", 4]] as const) {
      const h = await p.ok({ op: "surface.new", kind: "test", ...o });
      const ts = tsSurface(w, h, o) as Json;
      const url = path === "mute" ? `ws://127.0.0.1:${mutePort}/` : `ws://127.0.0.1:${port}${path}`;
      const hooks = {
        opened: () => w.ts.push("surf.opened", [h]),
        message: (_s: Json, data: Buffer, said: Json) => {
          const text = Buffer.from(data).toString();
          w.ts.push("surf.message", [h, text, said.binary, said.now]);
          if (text === "end") said.end(null);
          else if (text.startsWith("fail:")) said.end(new Error(text.slice(5)));
        },
        ping: () => w.ts.push("surf.ping", [h]),
      };
      const tsRun = settled(() => Effect.runPromise(ts.socketTo(url, hooks, { "x-test": "1" })));
      const mbRun = p.ask({ op: "surface.call", h, name: "socketTo", args: [url, { "x-test": "1" }] });
      const opened = () => path === "mute" || path === "/refuse" || (w.ts.said.some(([n, a]) => n === "surf.opened" && a[0] === h) && w.mb.said.some(([n, a]) => n === "surf.opened" && a[0] === h));
      for (let i = 0; i < 100000 && path === "/quiet" && !opened(); i++) await new Promise((r) => setImmediate(r));
      if (path === "/quiet") assert.ok(opened(), `${path}: never opened`);
      for (let i = 0; i < steps; i++) {
        await w.both(15000);
        for (let k = 0; k < 20; k++) await new Promise((r) => setImmediate(r));
      }
      const [want, got] = await Promise.all([tsRun, mbRun]);
      delete got.id;
      assert.deepEqual(got, want, path);
      await w.rest();
      await call_(p, h, ts);
      await w.same(`${path}: said alike`);
    }
  } finally {
    for (const c of clients.values()) {
      c.removeAllListeners();
      c.on("error", () => {});
      c.terminate();
    }
    for (const c of wss.clients) c.terminate();
    for (const c of held) c.destroy();
    wss.close();
    mute.close();
    w.done();
  }
  async function call_(p_: Program, h: number, ts: Json) {
    await same(p_, "socket", () => ts.socket(), { op: "surface.call", h, name: "state" }).catch(async () => {
      const got = await p_.ok({ op: "surface.call", h, name: "state" });
      assert.deepEqual(got.socket, wire(ts.socket()), "its socket's state");
    });
  }
});

test("a group connect's link: its hello refused or let in, pinged, asked, its stream, let go", { skip }, async () => {
  const p = await mb();
  const { w, mesh, server } = await imWorld(p);
  try {
    server.member("Ada", true);
    const keyT = randomBytes(32).toString("hex");
    const keyM = randomBytes(32).toString("hex");
    const o = { server: server.endpoint.id(), relays: ["https://relay.test"] };
    const ts = new GroupLink({ endpoints: mesh as Json, secretKey: Buffer.from(keyT, "hex"), ...o });
    const h = await p.ok({ op: "link.new", key: keyM, ...o, ips: [] });
    const codes = { ts: server.code(), mb: server.code() };
    const n = (side: "ts" | "mb", v: Json) => w.aliased(v, side);
    const call = async (name: string, tsF: () => Promise<Json>, args: Json[] | ((side: "ts" | "mb") => Json[])) => {
      const want = await settled(tsF);
      const got = await p.ask({ op: "link.call", h, name, args: typeof args === "function" ? args("mb") : args });
      delete got.id;
      if ("error" in want) assert.deepEqual({ error: got.error, kind: got.kind }, want, name);
      else assert.deepEqual(n("mb", got), n("ts", want), name);
      return [want, got];
    };
    w.alias = { ts: [[codes.ts, "<code>"]], mb: [[codes.mb, "<code>"]] };
    await call("device", async () => {
      const d = await ts.device();
      w.alias.ts.push([d, "<device>"]);
      w.alias.mb.push([await p.ok({ op: "link.call", h, name: "device", args: [] }), "<device>"]);
      return d;
    }, []);
    await call("open", async () => ts.open(), []);
    await call("connect", () => ts.connect({ credential: "" }), [{ credential: "" }]);
    await call("connect", () => ts.connect({ credential: "NOPE-NOPE" }), [{ credential: "NOPE-NOPE" }]);
    await call("ping", () => ts.ping(), []);
    await call("ask", () => ts.ask("GET", "/members"), ["GET", "/members"]);
    const meT = await ts.connect({ credential: codes.ts, name: "Claude" });
    const meM = await p.ok({ op: "link.call", h, name: "connect", args: [{ credential: codes.mb, name: "Claude" }] });
    w.alias.ts.push([meT.member, "<member>"]);
    w.alias.mb.push([meM.member, "<member>"]);
    assert.deepEqual(n("mb", meM), n("ts", wire(meT)), "let in by its code");
    await call("open", async () => ts.open(), []);
    await call("ping", () => ts.ping(), []);
    const asked = async (verb: string, path: string, body?: Json, bodies = true) => {
      const want = await settled(async () => {
        const a = await ts.ask(verb, path, body === undefined ? undefined : body.hex !== undefined ? Buffer.from(body.hex, "hex") : body.json);
        return { status: a.status, headers: a.headers, body: a.body.toString() };
      });
      const got = await p.ask({ op: "link.call", h, name: "ask", args: [verb, path, body ?? null] });
      delete got.id;
      const strip = (v: Json) => (bodies || !v.ok ? v : { ok: { ...v.ok, body: "<body>" } });
      assert.deepEqual(strip(n("mb", got)), strip(n("ts", want)), `${verb} ${path}`);
    };
    // (who the members are has the other's bot in it, before or after this one's)
    await asked("GET", "/members", undefined, false);
    await asked("POST", "/sync", { json: { since: {} } });
    await asked("POST", "/me/name", { json: { name: "Claude" } });
    await asked("GET", "/nope");
    const stream = await settled(async () => {
      const s = await ts.stream("GET", "/events");
      s.cancel();
      return { status: s.status, headers: s.headers };
    });
    const mbStream = await p.ok({ op: "link.call", h, name: "stream", args: ["GET", "/events"] });
    await p.ok({ op: "link.call", h: mbStream.h, name: "cancel", args: [] });
    assert.deepEqual({ ok: { status: mbStream.status, headers: mbStream.headers } }, stream, "its event stream");
    await call("drop", async () => ts.drop("enough"), ["enough"]);
    await call("open", async () => ts.open(), []);
    await call("ask", () => ts.ask("GET", "/members"), ["GET", "/members"]);
    await call("close", () => ts.close(), []);
    await call("connect", () => ts.connect({ credential: "" }), [{ credential: "" }]);
  } finally {
    await server.close();
    w.done();
  }
});
