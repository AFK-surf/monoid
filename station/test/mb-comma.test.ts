// Comma on the station in MoonBit (station/mb src/comma, `stillfail-reader-harness --builder harness-comma`) held to the TypeScript
// it is written from (src/comma/): each case run by both on the same data, its answer (or what it threw) the same; the
// statistics' and the Task index's databases (stats.ts, stats-age.ts) written by each from copies of one file and
// compared table by table, the Tasks' file (tasks.ts) byte for byte, the Router's reads and writes (chats.ts) against a
// station's store of each made the same way (hub-fakes.ts's Rig), the peers' reads (peer.ts) against the same answers,
// and a connect's socket (surface.ts) given the same frames by a stand-in for Comma's gateway, the frames each sends it
// compared one by one. Time is the test's on both sides (fibers.ts `wall`, and the program's clock), and so are the
// random bytes and UUIDs each makes.
//
// The program is asked synchronously (a worker holds it, the test waiting on an Atomics cell): the Router's write runs
// its keyed hooks inside the store's transaction (lifecycle.ts `say`), and the program's hooks must answer there.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, mock, test } from "node:test";
import { Worker } from "node:worker_threads";
import { mbHarnessBinary } from "./mb-harness.ts";
import { wall } from "../src/ops/fibers.ts";
import { log } from "../src/ops/log.ts";
import { setStationLang } from "../src/ops/i18n.ts";
import { chatOf, chatRef, CommaStats, heldFrom, IndexSync, nextPage, probePage, RevIndex, statsRowsOf, statsWire, taskRowsOf, taskWire, type IndexRow, type StationRows } from "../src/comma/stats.ts";
import { installStatsAge, statsAgeCandidates, statsAgeReady, statsAgeStep } from "../src/comma/stats-age.ts";
import { CommaTasks, threadTsOf } from "../src/comma/tasks.ts";
import { commaConnects, commaLine, maskToken } from "../src/comma/index.ts";
import { connectUrl, CommaSurface, questionOf, seqTs } from "../src/comma/surface.ts";
import { peerRead, textOf, workspaceRead, type WorkspaceReads } from "../src/comma/peer.ts";
import { routerReads, routerSays } from "../src/comma/chats.ts";
import { workspaceIndex } from "../src/comma/workspace-index.ts";
import { say as lifecycleSay } from "../src/sessions/lifecycle.ts";
import { MessageWriteBusy } from "../src/store/store.ts";
import { Rig, settle } from "./hub-fakes.ts";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };

type Json = any;

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

const dirs: string[] = [];
const fresh = (prefix: string) => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
};

/// JSON of a value (undefined as null, as the wire says it).
const wire = (v: unknown): Json => (v === undefined ? null : JSON.parse(JSON.stringify(v) ?? "null"));

/// What a thrown error is told as: its kind (its class's name, but for a plain Error) and its message.
const kindOf = (e: unknown): string => {
  if (!(e instanceof Error)) return "";
  const said = (e as { kind?: unknown }).kind;
  if (typeof said === "string") return said;
  return e.constructor.name === "Error" ? "" : e.constructor.name;
};

// ── the same randomness and time on both sides ─────────────────────────────────────────────────────────────────

const require = createRequire(import.meta.url);
const nodeCrypto = require("node:crypto");
let randomSeq = 0;
const testRandom = (seq: number, n: number) => {
  const h = createHash("sha256").update(`random ${seq}`).digest("hex");
  let out = h;
  while (out.length < n * 2) out += h;
  return out.slice(0, n * 2);
};
const testUuid = (seq: number) => `00000000-0000-4000-8000-${String(seq).padStart(12, "0")}`;
nodeCrypto.randomBytes = (n: number) => Buffer.from(testRandom(++randomSeq, n), "hex");
nodeCrypto.randomUUID = () => testUuid(++randomSeq);
syncBuiltinESMExports();

/// The test's clock, as `wall` (both sides start each scenario at the same moment).
const clock = { now: 0, seq: 0, timers: [] as { due: number; seq: number; f: () => void }[] };
mock.method(wall, "now", () => clock.now);
mock.method(wall, "after", (ms: number, f: () => void) => {
  const t = { due: clock.now + Math.max(0, ms), seq: ++clock.seq, f };
  clock.timers.push(t);
  return () => {
    const i = clock.timers.indexOf(t);
    if (i >= 0) clock.timers.splice(i, 1);
  };
});
/// The clock moved on by `ms`: each timer due by then fired in its turn, what it set going let run.
async function advanceTs(ms: number): Promise<number[]> {
  const to = clock.now + ms;
  const fired: number[] = [];
  for (;;) {
    const due = clock.timers.filter((t) => t.due <= to).sort((a, b) => a.due - b.due || a.seq - b.seq)[0];
    if (due === undefined) break;
    clock.timers.splice(clock.timers.indexOf(due), 1);
    clock.now = Math.max(clock.now, due.due);
    fired.push(due.due);
    due.f();
    await settle();
  }
  clock.now = Math.max(clock.now, to);
  return fired;
}

/// What the station's log says of Comma, each side's.
const tsLogs: Json[] = [];
/// Logs compared, a JSON syntax error's words aside: V8's sentence (`Unexpected token…is not valid JSON`) and the
/// program's (`unexpected input at <n>`) say the same failure, and only a log reads them.
const sameLogs = (got: Json[], want: Json[], what = "what each logged") => {
  const plain = (logs: Json[]) => logs.map((l) => {
    const e = l.fields?.error;
    const syntax = typeof e === "string" && (/JSON|^unexpected input at \d+$/.test(e));
    return syntax ? { ...l, fields: { ...l.fields, error: "<a JSON syntax error>" } } : l;
  });
  assert.deepEqual(plain(got), plain(want), what);
};
for (const level of ["info", "warn"] as const) {
  mock.method(log, level, (part: string, message: string, fields?: Json) => {
    if (part === "comma") tsLogs.push({ level, message, fields: wire(fields ?? {}) });
  });
}

// ── the program, asked synchronously ───────────────────────────────────────────────────────────────────────────

const WORKER = `
const { parentPort, workerData } = require("node:worker_threads");
const { spawn } = require("node:child_process");
const { createInterface } = require("node:readline");
const head = new Int32Array(workerData.sab, 0, 2);
const body = new Uint8Array(workerData.sab, 8);
const child = spawn(workerData.binary, workerData.args, { stdio: ["pipe", "pipe", "inherit"] });
const queue = [];
let asked = false;
const pump = () => {
  if (!asked || Atomics.load(head, 0) !== 0 || queue.length === 0) return;
  asked = false;
  const b = queue.shift();
  body.set(b);
  Atomics.store(head, 1, b.length);
  Atomics.store(head, 0, 1);
  Atomics.notify(head, 0);
};
createInterface({ input: child.stdout }).on("line", (l) => { queue.push(Buffer.from(l, "utf8")); pump(); });
child.on("exit", (code) => { queue.push(Buffer.from(JSON.stringify({ exited: code }))); pump(); });
parentPort.on("message", (m) => {
  if (m.write !== undefined) child.stdin.write(m.write);
  if (m.next) { asked = true; pump(); }
  if (m.end) {
    // (the program let go: told back once it is gone, killed 2 s after where it is not)
    if (child.exitCode !== null || child.signalCode !== null) parentPort.postMessage({ ended: true });
    else {
      child.once("exit", () => parentPort.postMessage({ ended: true }));
      child.stdin.end();
      setTimeout(() => child.kill("SIGKILL"), 2000).unref();
    }
  }
});
`;

/// What the program asks of the test: answered by the scenario's own.
type Answer = (name: string, args: Json[], cb: (said: Json) => (...a: Json[]) => Json) => Json;

class Program {
  #worker: Worker;
  #head: Int32Array;
  #body: Uint8Array;
  #id = 0;
  #call = 0;
  answer: Answer = (name) => { throw new Error(`nothing answers ${name}`); };
  /// What the program told: its log, the frames it sent Comma, an index's change, a socket it ended.
  logs: Json[] = [];
  sent: Json[] = [];
  told: Json[] = [];
  /// Told each frame the program sends Comma, as it sends it (a stand-in gateway answers by `post`).
  onSent: ((socket: number, frame: Json) => void) | null = null;
  onTold: ((told: Json) => void) | null = null;
  constructor() {
    const sab = new SharedArrayBuffer(8 + 64 * 1024 * 1024);
    this.#head = new Int32Array(sab, 0, 2);
    this.#body = new Uint8Array(sab, 8);
    this.#worker = new Worker(WORKER, { eval: true, workerData: { sab, binary, args: ["--builder", "harness-comma", "--shell-dir", fresh("comma-shell-")] } });
    this.#worker.unref();
  }
  #write(v: Json) {
    this.#worker.postMessage({ write: `${JSON.stringify(v)}\n` });
  }
  #line(): Json {
    this.#worker.postMessage({ next: true });
    if (Atomics.wait(this.#head, 0, 0, 120_000) === "timed-out" && Atomics.load(this.#head, 0) === 0) throw new Error("the program did not answer");
    const n = Atomics.load(this.#head, 1);
    const text = Buffer.from(this.#body.subarray(0, n)).toString("utf8");
    Atomics.store(this.#head, 0, 0);
    const said = JSON.parse(text);
    if ("exited" in said) throw new Error(`the program exited (${said.exited})`);
    return said;
  }
  /// A callback the program gave, as a function of the test's (each run of it waits for the program's answer).
  #callback = (said: Json) => (...a: Json[]) => {
    const k = ++this.#call;
    this.#write({ cb: said?.$cb, call: k, args: wire(a) });
    return this.#until((m) => m.cbDone === k);
  };
  /// Answers read while another wait (one nested in an answer of the test's) was reading, kept for theirs.
  #early: Json[] = [];
  /// Lines read and served (the program's asks answered, what it tells kept) until the one `mine` takes.
  #until(mine: (m: Json) => boolean): Json {
    for (;;) {
      const kept = this.#early.findIndex(mine);
      const m = kept >= 0 ? this.#early.splice(kept, 1)[0] : this.#line();
      if (typeof m.tell === "string") {
        this.activity++;
        if (m.tell === "log") this.logs.push({ level: m.level, message: m.message, fields: m.fields });
        else if (m.tell === "sent") {
          this.sent.push({ socket: m.socket, frame: m.frame });
          this.onSent?.(m.socket, m.frame);
        } else {
          this.told.push(m);
          this.onTold?.(m);
        }
        continue;
      }
      if (typeof m.call === "string") {
        let reply: Json;
        try {
          const v = this.answer(m.call, m.args, this.#callback);
          reply = { answer: m.id, result: wire(v) };
        } catch (e) {
          reply = { answer: m.id, threw: e instanceof Error ? e.message : String(e), kind: kindOf(e) };
        }
        this.#write(reply);
        continue;
      }
      if (mine(m)) {
        if ("error" in m) throw Object.assign(new Error(m.error), { kind: m.kind, data: m.data });
        return m.ok;
      }
      if ("done" in m && this.#posted.delete(m.done)) continue;
      if ("done" in m || "cbDone" in m) this.#early.push(m);
    }
  }
  /// A case of the program's: what it answers, or what it threw (thrown here as it was).
  ask(op: string, ...args: Json[]): Json {
    const id = ++this.#id;
    this.#write({ op, id, args: wire(args) });
    return this.#until((m) => m.done === id);
  }
  /// A case of the program's not waited for (what it answers is let go).
  /// How much the program said or was given past the cases asked: what a settled wait has to see stop.
  activity = 0;
  post(op: string, ...args: Json[]) {
    this.activity++;
    const id = ++this.#id;
    this.#posted.add(id);
    this.#write({ op, id, args: wire(args) });
  }
  #posted = new Set<number>();
  /// Till nothing it does goes on: what it set going let run (`drain`) again while that made it say or be given more.
  settle() {
    for (;;) {
      const before = this.activity;
      this.ask("drain");
      if (this.activity === before) return;
    }
  }
  /// The program let go, waited for till it is gone, and its thread after it.
  async close(): Promise<void> {
    this.#worker.ref();
    const ended = new Promise<void>((r) => {
      const heard = (m: Json) => {
        if (m?.ended !== true) return;
        this.#worker.off("message", heard);
        r();
      };
      this.#worker.on("message", heard);
    });
    this.#worker.postMessage({ end: true });
    await ended;
    await this.#worker.terminate();
  }
}

let program: Program | null = null;
const mb = (): Program => {
  if (program === null) {
    program = new Program();
    program.ask("words", zhStation, enStation, "still.fail");
    program.ask("lang", "zh");
  }
  return program;
};
// (the program waited for till it is gone, its directories after: one still running at the file's end is a leftover)
after(async () => {
  await program?.close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// What a function gives, as the program says it: `{ok}` or `{error, kind}`.
function settled(f: () => unknown): Json {
  try {
    return { ok: wire(f()) };
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e), kind: kindOf(e) };
  }
}
async function settledAsync(f: () => Promise<unknown>): Promise<Json> {
  try {
    return { ok: wire(await f()) };
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e), kind: kindOf(e) };
  }
}
const mbSettled = (op: string, ...args: Json[]): Json => settled(() => mb().ask(op, ...args));

/// Both, the same: a function of no state.
function same(op: string, ts: () => unknown, ...args: Json[]) {
  const want = settled(ts);
  const got = mbSettled(op, ...args);
  if ("error" in want) assert.deepEqual({ error: got.error, kind: got.kind }, want, `${op}(${JSON.stringify(args).slice(0, 400)})`);
  else assert.deepEqual(got, want, `${op}(${JSON.stringify(args).slice(0, 400)})`);
}

/// A scenario's start, the same on both sides: the clock and the randomness, the logs.
function begin(now = 1_760_000_000_000) {
  clock.now = now;
  clock.timers.length = 0;
  randomSeq = 0;
  tsLogs.length = 0;
  const p = mb();
  p.ask("clock.set", now);
  p.ask("random.reset");
  p.logs.length = 0;
  p.sent.length = 0;
  p.told.length = 0;
  p.onSent = null;
  p.onTold = null;
}

/// Every table of a database, its rows in order, as text (blobs as hex): what both sides wrote, to compare.
function dump(path: string, skipTables: string[] = []): Json {
  const db = new DatabaseSync(path);
  try {
    const out: Json = {};
    const tables = db.prepare("SELECT name, sql FROM sqlite_master WHERE type IN ('table', 'index', 'trigger') ORDER BY type, name").all() as { name: string; sql: string | null }[];
    out.schema = tables.map((t) => [t.name, (t.sql ?? "").replace(/\s+/g, " ")]);
    for (const t of tables) {
      if (skipTables.includes(t.name)) continue;
      if (!(db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(t.name))) continue;
      const cols = (db.prepare(`PRAGMA table_info(${t.name})`).all() as { name: string }[]).map((c) => c.name);
      const sel = cols.map((c) => `quote(${c}) AS ${c}`).join(", ");
      out[t.name] = db.prepare(`SELECT rowid AS _rowid_, ${sel} FROM ${t.name} ORDER BY rowid`).all();
    }
    return out;
  } finally {
    db.close();
  }
}

// ── pure ───────────────────────────────────────────────────────────────────────────────────────────────────────

test("pure: chat refs, a Task's thread, a Message's ts, a connect's line and token", { skip }, () => {
  for (const [thread, station] of [[1, undefined], [42, "st-2"], [9007199254740991, "a@b"], [3.5, undefined], [0, "x"]] as [number, string | undefined][]) {
    same("chatRef", () => chatRef(thread, station), thread, station ?? null);
  }
  for (const ref of ["1", "42@st", "0", "007", "12@", "@st", "1@a@b", "12x", "", " 1", "9007199254740991", "9007199254740992", "99999999999999999999", "5@line\nbreak", "5@tab\there", "١٢", "3@😀"]) {
    same("chatOf", () => chatOf(ref), ref);
  }
  for (const task of ["t-1", "", "a/b/c", "😀 task", "\ud800 lone", "x".repeat(500)]) same("threadTsOf", () => threadTsOf(task), task);
  for (const seq of [0, 1, 1700000000, 12.5, 1e21]) same("seqTs", () => seqTs(seq), seq);
  for (const line of ["comma https://c.example abcdefgh", "  comma   wss://c.example/x/y  ABCdef_-12  ", "comma ws://h:80 abcdefgh", "comma http://h:8080/ abcdefgh", "comma https://h:443 abcdefgh",
    "comma ftp://h abcdefgh", "comma https://h short", "comma https://h abc def", "Comma https://h abcdefgh", "comma notaurl abcdefgh", "comma https://user:pw@H.Example/ abcdefgh",
    "comma https://h tokénnnnnn", "", "comma", "comma\thttps://h　abcdefgh", "comma https://127.1 abcdefgh", "comma https://[::1]:9 abcdefgh", "comma https://h:99999 abcdefgh",
    "comma https://a%41b abcdefgh", "comma https:// abcdefgh", `comma https://h ${"a".repeat(512)}`, `comma https://h ${"a".repeat(513)}`]) {
    same("commaLine", () => commaLine(line), line);
  }
  for (const t of ["", "a", "abcd", "abcde", "secret-token-1234", "😀😀x"]) same("maskToken", () => maskToken(t), t);
});

test("pure: the gateway's address", { skip }, () => {
  const os = { platform: () => "linux", arch: () => "x64" };
  const realOs = require("node:os");
  const keep = { platform: realOs.platform, arch: realOs.arch };
  realOs.platform = os.platform;
  realOs.arch = os.arch;
  syncBuiltinESMExports();
  try {
    for (const server of ["https://comma.example", "https://Comma.Example:443///", "http://localhost:8080", "http://h:80", "https://h:80", "wss://h", "ws://h:443", "https://u:p@h/x?y#z",
      "https://h/path/ignored", "ftp://h", "notaurl", "https://h\\x", "https://127.1", "https://h:65536", "file:///x", "foo://h/x", " https://h "]) {
      for (const [name, ws] of [["host one", null], ["名 · 站", "w s/1"], ["a&b=c+d%", "ws\ud800"]] as [string, string | null][]) {
        same("connectUrl", () => connectUrl(server, name, ws), server, name, ws, "linux", "x64");
      }
    }
  } finally {
    realOs.platform = keep.platform;
    realOs.arch = keep.arch;
    syncBuiltinESMExports();
  }
});

test("pure: a card as Comma's question, config.json's Comma connects", { skip }, () => {
  const cards: Json[] = [
    null, { type: "text" }, { type: "options", options: [{ label: "one" }] },
    { type: "options", options: [{ label: " A " }, { label: "B", detail: "  why  ", recommended: true }, { label: "" }, { label: 5 }, { nolabel: true }] },
    { type: "options", options: Array.from({ length: 7 }, (_, i) => ({ label: `o${i}` })) },
    { type: "options", options: Array.from({ length: 6 }, (_, i) => ({ label: "😀".repeat(120) + i, detail: "d".repeat(400), recommended: i === 2 ? true : "yes" })) },
    { type: "options", options: "nope" }, { type: "options" }, [],
  ];
  for (const card of cards) for (const prompt of ["  Which?  ", "", "x".repeat(700)]) same("questionOf", () => questionOf(card, prompt), card, prompt);
  const raws: Json[] = [
    null, {}, { connects: "x" }, { connects: [null, 5, { kind: "slack" }, { kind: "comma" }, { kind: "comma", id: 7, enabled: false, comma: { server: "", token: 5 }, workspace: "" },
      { kind: "comma", id: "c1", enabled: "no", comma: { server: "https://c", token: "t" }, workspace: "w1" }, { kind: "comma", id: null, comma: null }] },
  ];
  for (const raw of raws) same("commaConnects", () => commaConnects(raw), raw);
});

const DAY = 24 * 60 * 60_000;

/// Stations' rows of every kind a build reads, edge ones too.
function stationRows(): StationRows[] {
  const people = { p1: { email: "ann@x", name: "Ann" }, p2: { name: "Bo" }, p3: { email: "", name: "" }, null: { name: "Nobody" }, undefined: { email: "u@x" } };
  const usage = (extra: Json[] = []) => ({
    people,
    rows: [
      { day: "2025-10-01", session: "s1", thread: 1, person: "p1", account: "a1", runtime: "claude", model: "opus", calls: 3, input: 10, cacheRead: 1, cacheWrite: 2, output: 5, cost: 0.5 },
      { day: "2025-10-02", session: "s1", person: "p2", runtime: "codex", calls: 1 },
      { day: "2025-09-01", session: "old", runtime: "claude" },
      { day: "2025-10-03", session: "s2", person: null, account: null, model: null, runtime: "claude", cost: null },
      { day: "2025-10-03", session: "s3", person: "p3", runtime: 7 },
      { day: "2025-10-04", session: "s4", runtime: "claude", thread: null },
      { day: 20251005, session: "s5", runtime: "claude" },
      { day: "2025-10-05", session: 5, runtime: "claude" },
      { day: "2025-10-06\u0000x", session: "s\ud800", runtime: "claude", person: "undefined" },
      { day: "2025-10-06", session: "s1", person: "p1", account: "a1", runtime: "claude", model: "opus", calls: 9 },
      ...extra,
    ],
  });
  const chats = (extra: Json[] = []) => [
    { thread: 1, surface: "app", title: "First", state: "running", creator: { email: "Ann@X", name: "Ann", ref: "u1" }, createdAt: 1, lastActiveAt: 2, agents: [{ runtime: "claude", model: "opus" }], url: "https://app/x", router: true,
      attention: { kind: "need", card: "options", waitsFor: [" Ann@X ", "ann@x", "bad", "b@c d", "c@d", 5, "e@f", "g@h", "i@j", "k@l", "m@n", "o@p"], note: "  please look  " } },
    { thread: 2, title: "😀".repeat(130), state: "need_human", creator: { name: "Bo" }, archived: true, attention: { kind: "need", card: "login" } },
    { thread: 3, state: "all_done", creator: null, agents: [], url: "http://not-https", attention: { kind: "other" } },
    { thread: 4, state: "ended", creator: { ref: "r4" }, createdAt: 9, attention: { kind: "done", card: "options", note: "n".repeat(400) }, url: `https://${"u".repeat(500)}` },
    { thread: 5, creator: "plain", title: 5, agents: [{ runtime: "r".repeat(50), model: null }], router: "yes" },
    { thread: "6" }, null, { thread: 7.5, archived: "true", lastActiveAt: null, createdAt: 3 },
    ...extra,
  ];
  return [
    { usage: usage(), chats: chats() },
    { station: "st-2", usage: usage([{ day: "2025-10-07", session: "x", runtime: "codex" }]), chats: chats([{ thread: 8, title: "theirs" }]) },
    { station: "st-3", usage: { rows: "none" }, chats: [] },
    { station: "st-4", usage: null, chats: [{ thread: 1, title: "same thread, another station" }] },
  ];
}

test("pure: a station's rows as the Stats index and the Task index keep them, and as the wire carries them", { skip }, () => {
  const rowsOf = (m: Map<string, { kind: string; json: string }>) => [...m].map(([k, v]) => [k, v.kind, v.json]);
  for (const s of stationRows()) {
    for (const fromDay of ["2025-10-01", "2025-10-03", "2025-09-01", "2026-01-01"]) same("statsRowsOf", () => rowsOf(statsRowsOf(s, fromDay)), s, fromDay);
    same("taskRowsOf", () => rowsOf(taskRowsOf(s)), s);
  }
  const rows: IndexRow[] = [
    { key: "stillfail\u0000usage\u00002025-10-01\u0000s1", source: "stillfail", kind: "usage", rev: 3, removed: false, json: '{"day":"2025-10-01","n":1}' },
    { key: "k\ud800", source: "stillfail", kind: "usage", rev: 4, removed: true, json: "" },
    { key: "bad", source: "stillfail", kind: "usage", rev: 5, removed: false, json: "{not json" },
    { key: "12", source: "stillfail", kind: "task", rev: 6, removed: false, json: JSON.stringify({ task: "12", title: "t", status: "done", created_by: null, created_at: 1, last_activity_at: 2, runtime: null, model: null, attention: "need", card: "secret", waits_for: ["a@b"], note: "x", url: "https://u", router: true }) },
    { key: "13", source: "stillfail", kind: "task", rev: 7, removed: false, json: JSON.stringify({ task: "13", waits_for: ["a@b"], note: "x", card: "secret", router: "yes", url: 5 }) },
    { key: "14", source: "stillfail", kind: "task", rev: 8, removed: false, json: JSON.stringify({ task: "14", attention: "done", card: "options", waits_for: [] }) },
    { key: "15", source: "stillfail", kind: "task", rev: 9, removed: false, json: "null" },
    { key: "16", source: "stillfail", kind: "task", rev: 10, removed: false, json: "5" },
  ];
  for (const r of rows) {
    same("statsWire", () => statsWire(r), r);
    same("taskWire", () => taskWire(r), r);
  }
  for (const v of [null, 5, "x", {}, { epoch: "e", through: 5 }, { epoch: null, through: -1 }, { epoch: 3 }, { through: 2.5 }, [], { epoch: "e", through: "9" }]) {
    same("heldFrom", () => heldFrom(v), v);
  }
});

// ── the statistics' databases ──────────────────────────────────────────────────────────────────────────────────

/// One database made for both sides from the same file: the TypeScript's at `ts`, the program's at `mb`.
function twin(setup?: (db: DatabaseSync) => void): { ts: string; mb: string; dir: string } {
  const dir = fresh("comma-db-");
  const ts = join(dir, "ts.db");
  const db = new DatabaseSync(ts);
  db.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
  setup?.(db);
  db.close();
  const mbPath = join(dir, "mb.db");
  copyFileSync(ts, mbPath);
  return { ts, mb: mbPath, dir };
}

/// Stats rows of `n`, some recent, some old, some with no day or not JSON: what the age index sorts.
function seedStats(db: DatabaseSync, n: number, big = false) {
  new RevIndex(db, "stats_index");
  new RevIndex(db, "task_index");
  const put = db.prepare("INSERT INTO stats_index (key, source, kind, rev, json, removed) VALUES (?, 'stillfail', ?, ?, ?, ?)");
  for (let i = 1; i <= n; i++) {
    const day = i % 7 === 0 ? undefined : `2025-${String(1 + (i % 12)).padStart(2, "0")}-${String(1 + (i % 28)).padStart(2, "0")}`;
    const json = i % 11 === 0 ? "{broken" : i % 13 === 0 ? JSON.stringify({ day: 5 }) : JSON.stringify({ day, session: `s${i}`, pad: big && i % 5 === 0 ? "x".repeat(2000) : "" });
    put.run(`stillfail\u0000usage\u0000${day ?? ""}\u0000s${i}`, i % 2 === 0 ? "usage" : "task", i, json, i % 9 === 0 ? 1 : 0);
  }
  db.prepare("INSERT INTO meta (key, value) VALUES ('stats_index.rev', ?)").run(String(n));
}

test("stats-age: the day index installed, built a batch at a time, and read, the same", { skip }, () => {
  for (const [n, big, limit] of [[0, false, 64], [40, false, 7], [300, false, 64], [120, true, 16], [1, false, 1]] as [number, boolean, number][]) {
    begin();
    const t = twin((db) => seedStats(db, n, big));
    const a = new DatabaseSync(t.ts);
    const p = mb();
    const h = p.ask("db.open", t.mb);
    const steps: Json[] = [];
    assert.deepEqual(settled(() => statsAgeReady(a, 0)), mbSettled("age.ready", h, 0), "ready before install");
    installStatsAge(a);
    p.ask("age.install", h);
    installStatsAge(a);
    p.ask("age.install", h);
    for (let i = 0; i < 400; i++) {
      const want = statsAgeStep(a, limit);
      const got = p.ask("age.step", h, limit);
      assert.deepEqual(got, want, `step ${i} of ${n}`);
      steps.push(want);
      if (want.done) break;
    }
    // writers dirty some rows (an older station's), a VACUUM renumbers, and it is caught up again
    for (const db of [a]) {
      db.exec("UPDATE stats_index SET json = '{\"day\":\"2025-12-31\"}' WHERE rev % 5 = 0");
      db.exec("INSERT OR REPLACE INTO stats_index (key, source, kind, rev, json) VALUES ('fresh', 'stillfail', 'usage', 999, '{\"day\":\"2025-11-11\"}')");
    }
    p.ask("db.exec", h, "UPDATE stats_index SET json = '{\"day\":\"2025-12-31\"}' WHERE rev % 5 = 0");
    p.ask("db.exec", h, "INSERT OR REPLACE INTO stats_index (key, source, kind, rev, json) VALUES ('fresh', 'stillfail', 'usage', 999, '{\"day\":\"2025-11-11\"}')");
    for (const max of [0, 3, null]) assert.deepEqual(p.ask("age.ready", h, max), statsAgeReady(a, max), `ready ${max}`);
    a.exec("VACUUM");
    p.ask("db.exec", h, "VACUUM");
    for (let i = 0; i < 400; i++) {
      const want = statsAgeStep(a, limit);
      assert.deepEqual(p.ask("age.step", h, limit), want, `after VACUUM, step ${i}`);
      if (want.done) break;
    }
    for (const day of ["2025-01-01", "2025-06-15", "2026-01-01", "2025-11-11"]) {
      const want = statsAgeCandidates(a, day).map((r) => ({ key: Buffer.from(r.key).toString("hex"), json: String(r.json) }));
      assert.deepEqual(p.ask("age.candidates", h, day), want, `candidates from ${day}`);
    }
    assert.deepEqual(settled(() => statsAgeStep(a, 0)), mbSettled("age.step", h, 0), "a batch of none");
    a.close();
    p.ask("db.close", h);
    assert.deepEqual(dump(t.mb), dump(t.ts), `the databases after ${n} rows`);
  }
});

// ── the statistics: builds applied, the Router's keys, an index's readers ─────────────────────────────────────

const quiet = () => () => {};
const nothing = async () => ({ stations: [], unread: [] });

test("stats: builds applied to both, the indexes, the Router's keys and titles, the same", { skip }, () => {
  begin();
  const t = twin();
  const p = mb();
  const a = new CommaStats(t.ts, nothing, quiet);
  const h = p.ask("stats.open", t.mb);
  const both = (what: string, ts: () => unknown, op: string, ...args: Json[]) => assert.deepEqual(mbSettled(op, h, ...args), settled(ts), what);
  const rows = stationRows();
  const from = Date.UTC(2025, 9, 2, 13);
  // first build: all of them; again the same: nothing changes; a station not read keeps its rows; one gone loses them
  both("first", () => a.apply(rows, [], from), "stats.apply", rows, [], from);
  both("again", () => a.apply(rows, [], from), "stats.apply", rows, [], from);
  const fewer = [{ ...rows[0]!, chats: rows[0]!.chats.slice(1) }, rows[1]!];
  both("fewer, st-3 and st-4 unread", () => a.apply(fewer, ["st-3", "st-4"], from), "stats.apply", fewer, ["st-3", "st-4"], from);
  both("fewer, all read", () => a.apply(fewer, [], from), "stats.apply", fewer, [], from);
  both("later days", () => a.apply(rows, [], from + 3 * DAY), "stats.apply", rows, [], from + 3 * DAY);
  both("nothing", () => a.apply([], [""], from), "stats.apply", [], [""], from);
  both("nothing at all", () => a.apply([], [], from + 40 * DAY), "stats.apply", [], [], from + 40 * DAY);
  for (const index of ["stats", "task"] as const) {
    const i = index === "stats" ? a.stats : a.tasks;
    both(`${index} epoch`, () => i.epoch(), "index.epoch", index);
    both(`${index} rev`, () => i.rev(), "index.rev", index);
    for (const [since, limit, omit] of [[0, 5, false], [3, 100, true], [0, 1000, false], [999, 5, false]] as [number, number, boolean][]) {
      both(`${index} since ${since}`, () => i.since(since, limit, omit), "index.since", index, since, limit, omit);
    }
    both(`${index} pruned`, () => i.pruned(), "index.pruned", index);
    both(`${index} held`, () => i.held("conn-a", 4), "index.held", index, "conn-a", 4);
    both(`${index} pruned after`, () => i.pruned(), "index.pruned", index);
    both(`${index} held all`, () => i.held("conn-a", 1e9), "index.held", index, "conn-a", 1e9);
    both(`${index} pruned at last`, () => i.pruned(), "index.pruned", index);
  }
  for (const ref of ["1", "2", "3", "8@st-2", "999", "1@st-4", "x", "6"]) both(`title ${ref}`, () => ({ title: a.taskTitle(ref) }), "stats.taskTitle", ref);
  for (const key of ["cm:k1", "cm:k2", "cm:\ud800"]) both(`said ${key}`, () => a.said(key), "stats.said", key);
  both("remember", () => a.remember("cm:k1", 12), "stats.remember", "cm:k1", 12);
  both("remember again", () => a.remember("cm:k1", 99), "stats.remember", "cm:k1", 99);
  both("remember a lone surrogate", () => a.remember("cm:\ud800", 7), "stats.remember", "cm:\ud800", 7);
  clock.now += 40 * DAY;
  p.ask("clock.set", clock.now);
  both("remember after the days", () => a.remember("cm:k2", 3), "stats.remember", "cm:k2", 3);
  for (const key of ["cm:k1", "cm:k2", "cm:�"]) both(`said ${key} at last`, () => a.said(key), "stats.said", key);
  a.close();
  p.ask("stats.close", h);
  assert.deepEqual(dump(t.mb), dump(t.ts));
});

test("stats: an index's tombstones held for its readers, and their floor", { skip }, () => {
  begin();
  const t = twin();
  const p = mb();
  const a = new CommaStats(t.ts, nothing, quiet);
  const h = p.ask("stats.open", t.mb);
  const rows = stationRows();
  const from = Date.UTC(2025, 9, 1);
  a.apply(rows, [], from);
  p.ask("stats.apply", h, rows, [], from);
  a.apply([], [], from);
  p.ask("stats.apply", h, [], [], from);
  const ta = a.tasks.following(), tb = a.tasks.following();
  const ma = p.ask("index.following", h, "task"), mbb = p.ask("index.following", h, "task");
  const steps: [string, () => unknown, string, ...Json[]][] = [
    ["observed a", () => a.tasks.observed(ta, 5), "index.observed", "task", ma, 5],
    ["held named", () => a.tasks.held("named", 50), "index.held", "task", "named", 50],
    ["held b", () => a.tasks.held(tb, 7), "index.held", "task", mbb, 7],
    ["pruned", () => a.tasks.pruned(), "index.pruned", "task"],
    ["gone a", () => a.tasks.gone(ta), "index.gone", "task", ma],
    ["held b more", () => a.tasks.held(tb, 9), "index.held", "task", mbb, 9],
    ["pruned again", () => a.tasks.pruned(), "index.pruned", "task"],
    ["gone b", () => a.tasks.gone(tb), "index.gone", "task", mbb],
    ["held named all", () => a.tasks.held("named", 1e6), "index.held", "task", "named", 1e6],
    ["pruned at last", () => a.tasks.pruned(), "index.pruned", "task"],
    ["since", () => a.tasks.since(0, 100), "index.since", "task", 0, 100, false],
  ];
  for (const [what, ts, op, ...args] of steps) assert.deepEqual(mbSettled(op, h, ...args), settled(ts), what);
  a.close();
  p.ask("stats.close", h);
  assert.deepEqual(dump(t.mb), dump(t.ts));
});

test("pages: what Comma lacks of an index, a page at a time, and a socket's sync, the same", { skip }, () => {
  for (const big of [false, true]) {
    begin();
    const t = twin();
    const p = mb();
    const a = new CommaStats(t.ts, nothing, quiet);
    const h = p.ask("stats.open", t.mb);
    // many rows (some large) so the pages are cut by rows and by bytes
    const many: StationRows[] = [{
      usage: { rows: Array.from({ length: 450 }, (_, i) => ({ day: "2025-10-02", session: `s${i}`, runtime: "claude", model: big && i % 3 === 0 ? "m".repeat(900) : "opus", calls: i })) },
      chats: Array.from({ length: 260 }, (_, i) => ({ thread: i + 1, title: big && i % 4 === 0 ? "t".repeat(4000) : `chat ${i}`, attention: { kind: "need", note: "n".repeat(big ? 250 : 5) } })),
    }];
    const from = Date.UTC(2025, 9, 1);
    a.apply(many, [], from);
    p.ask("stats.apply", h, many, [], from);
    for (const index of ["stats", "task"] as const) {
      const i = index === "stats" ? a.stats : a.tasks;
      const w = index === "stats" ? statsWire : taskWire;
      assert.deepEqual(p.ask("page.probe", h, index), wire(probePage(i)), `${index} probe`);
      let held: Json = { epoch: null, through: 0 };
      for (let n = 0; n < 20; n++) {
        const want = nextPage(i, held, w);
        assert.deepEqual(p.ask("page.next", h, index, held, index), wire(want), `${index} page ${n}`);
        if (want === null) break;
        held = { epoch: want.epoch, through: want.through };
      }
      // a socket following it: a reset, its pages, what it holds acknowledged, a stale epoch, a floor passed
      const sa = new IndexSync(i, w);
      const sm = p.ask("sync.new", h, index, index);
      const helds: Json[] = [{ epoch: null, through: 0 }];
      let last: Json = helds[0];
      for (let n = 0; n < 30; n++) {
        const want = sa.next(last);
        assert.deepEqual(p.ask("sync.next", sm, last), wire(want), `${index} sync ${n}`);
        if (want === null) break;
        last = { epoch: want.epoch, through: want.through };
      }
      for (const odd of [{ epoch: "old", through: 3 }, { epoch: last.epoch, through: 1e9 }, { epoch: last.epoch, through: 0 }, last]) {
        const want = sa.next(odd);
        assert.deepEqual(p.ask("sync.next", sm, odd), wire(want), `${index} sync given ${JSON.stringify(odd)}`);
      }
      sa.close();
      p.ask("sync.close", sm);
    }
    // a change after: tombstones and a new row, paged again from where Comma was
    a.apply([{ ...many[0]!, chats: many[0]!.chats.slice(0, 100) }], [], from);
    p.ask("stats.apply", h, [{ ...many[0]!, chats: many[0]!.chats.slice(0, 100) }], [], from);
    for (const index of ["stats", "task"] as const) {
      const i = index === "stats" ? a.stats : a.tasks;
      const w = index === "stats" ? statsWire : taskWire;
      let held: Json = { epoch: i.epoch(), through: 100 };
      for (let n = 0; n < 20; n++) {
        const want = nextPage(i, held, w);
        assert.deepEqual(p.ask("page.next", h, index, held, index), wire(want), `${index} later page ${n}`);
        if (want === null) break;
        held = { epoch: want.epoch, through: want.through };
      }
    }
    a.close();
    p.ask("stats.close", h);
    assert.deepEqual(dump(t.mb), dump(t.ts));
  }
});

// ── the Tasks' file ────────────────────────────────────────────────────────────────────────────────────────────

test("tasks: a connect's Tasks kept, given, left and forgotten, the file the same", { skip }, async () => {
  for (const start of [null, "{}", "[1]", "not json", JSON.stringify({ c1: { "10": { task: "10", threadTs: "1.000001", start: { requester: "u", title: null, runtime: null, model: null }, fetched: 2, answered: 1 }, t0: { task: "t0", threadTs: "9.000009", start: { requester: "u", title: null, runtime: null, model: null }, fetched: 0, answered: 0, left: true } }, "2": {} })]) {
    begin();
    const dir = fresh("comma-tasks-");
    const tsPath = join(dir, "ts.json"), mbPath = join(dir, "mb.json");
    if (start !== null) { writeFileSync(tsPath, start); writeFileSync(mbPath, start); }
    const a = new CommaTasks(tsPath);
    const p = mb();
    const h = p.ask("tasks.open", mbPath);
    const steps: [string, () => unknown, string, ...Json[]][] = [
      ["get none", () => a.get("c1", "t1"), "tasks.get", "c1", "t1"],
      ["invite t1", () => a.invited("c1", "t1", { requester: "ann", title: "T", runtime: "claude", model: null }, 0), "tasks.invited", "c1", "t1", { requester: "ann", title: "T", runtime: "claude", model: null }, 0],
      ["invite 5", () => a.invited("c1", "5", { requester: "bo", title: null, runtime: null, model: null }, 3), "tasks.invited", "c1", "5", { requester: "bo", title: null, runtime: null, model: null }, 3],
      ["given t1", () => a.given("c1", "t1", 7, null), "tasks.given", "c1", "t1", 7, null],
      ["given t1 less", () => a.given("c1", "t1", 2, 4), "tasks.given", "c1", "t1", 2, 4],
      ["given none", () => a.given("c1", "nope", 1, 1), "tasks.given", "c1", "nope", 1, 1],
      ["invite t1 again", () => a.invited("c1", "t1", { requester: "ann", title: "T2", runtime: "codex", model: "gpt" }, 2), "tasks.invited", "c1", "t1", { requester: "ann", title: "T2", runtime: "codex", model: "gpt" }, 2],
      ["by thread", () => a.byThread("c1", threadTsOf("t1")), "tasks.byThread", "c1", threadTsOf("t1")],
      ["by thread none", () => a.byThread("c1", "0.000000"), "tasks.byThread", "c1", "0.000000"],
      ["taking", () => a.taking("c1"), "tasks.taking", "c1"],
      ["left 5", () => a.left("c1", "5"), "tasks.left", "c1", "5"],
      ["left 5 again", () => a.left("c1", "5"), "tasks.left", "c1", "5"],
      ["taking after", () => a.taking("c1"), "tasks.taking", "c1"],
      ["invite c2", () => a.invited("c2", "x", { requester: "", title: null, runtime: null, model: null }, 0), "tasks.invited", "c2", "x", { requester: "", title: null, runtime: null, model: null }, 0],
      ["forget c1", () => a.forget("c1"), "tasks.forget", "c1"],
      ["forget none", () => a.forget("zz"), "tasks.forget", "zz"],
      ["taking c2", () => a.taking("c2"), "tasks.taking", "c2"],
      ["taking 2", () => a.taking("2"), "tasks.taking", "2"],
    ];
    for (const [what, ts, op, ...args] of steps) {
      assert.deepEqual(mbSettled(op, h, ...args), settled(ts), `${what} (from ${start})`);
    }
    await a.written();
    p.ask("tasks.written", h);
    assert.equal(readFileSync(mbPath, "utf8"), readFileSync(tsPath, "utf8"), `the file (from ${start})`);
    sameLogs(p.logs, tsLogs);
  }
});

// ── a build: started, told of changes, every hour, and a database another holds ──────────────────────────────

test("stats: builds started, settled after a change, hourly, and tried again past a lock, the same", { skip }, async () => {
  begin(Date.UTC(2025, 9, 5, 10));
  const t = twin();
  const p = mb();
  const rows = stationRows();
  let given: Json = { stations: rows, unread: [] };
  const tsReads: Json[] = [], mbReads: Json[] = [];
  const tsListeners = new Set<(fast?: boolean) => void>();
  const mbListeners: ((...a: Json[]) => Json)[] = [];
  const a = new CommaStats(t.ts, async (from, to) => {
    tsReads.push([from, to]);
    const g = structuredClone(given);
    return g.valid === false ? { ...g, valid: () => false } : g;
  }, (changed) => {
    tsListeners.add(changed);
    return () => tsListeners.delete(changed);
  }, undefined, 30);
  p.answer = (name, args, cb) => {
    if (name === "read") { mbReads.push([args[1], args[2]]); return given; }
    if (name === "changes.listen") { mbListeners.push(cb(args[1])); return null; }
    if (name === "changes.stop") return null;
    throw new Error(`nothing answers ${name}`);
  };
  const h = p.ask("stats.open", t.mb, 30);
  const settleBoth = async () => {
    await a.settled();
    await settle();
    p.settle();
    p.ask("stats.settled", h);
  };
  const timers = () => clock.timers.map((x) => x.due).sort();
  const mbTimers = () => (p.ask("clock.timers", h) as number[]).sort();
  a.start();
  p.ask("stats.start", h);
  await settleBoth();
  assert.deepEqual(mbReads, tsReads, "the first build's read");
  assert.deepEqual(mbTimers(), timers(), "the hour's timer");
  // a change: built a minute after, the changes of that minute together
  given = { stations: [{ ...rows[0]!, chats: rows[0]!.chats.slice(0, 2) }], unread: ["st-2"] };
  for (const l of tsListeners) l();
  for (const l of tsListeners) l();
  for (const l of mbListeners) l();
  for (const l of mbListeners) l();
  assert.deepEqual(mbTimers(), timers(), "the minute's timer");
  const fired = await advanceTs(60_000);
  assert.deepEqual(p.ask("clock.advance", 60_000), fired);
  await settleBoth();
  assert.deepEqual(mbReads, tsReads, "the build after a change");
  // a slow usage change followed by a fast chat change settles in 1 s (overriding the 60 s wait), and nudge does the same
  for (const l of tsListeners) l(false);
  for (const l of mbListeners) l(false);
  assert.deepEqual(mbTimers(), timers(), "the slow timer before fast override");
  for (const l of tsListeners) l(true);
  for (const l of mbListeners) l(true);
  assert.deepEqual(mbTimers(), timers(), "the fast timer replacing the slow one");
  const fastFired = await advanceTs(1_000);
  assert.deepEqual(p.ask("clock.advance", 1_000), fastFired);
  await settleBoth();
  assert.deepEqual(mbReads, tsReads, "the build after a fast change");
  a.nudge();
  p.ask("stats.nudge", h);
  assert.deepEqual(mbTimers(), timers(), "the nudge's timer");
  const nudgeFired = await advanceTs(1_000);
  assert.deepEqual(p.ask("clock.advance", 1_000), nudgeFired);
  await settleBoth();
  assert.deepEqual(mbReads, tsReads, "the build after a nudge");
  // another station holds the database: the build is tried again, backing off, until it is let go
  const blockers = [new DatabaseSync(t.ts), new DatabaseSync(t.mb)];
  for (const b of blockers) b.exec("BEGIN IMMEDIATE");
  given = { stations: rows, unread: [] };
  a.build();
  p.ask("stats.build", h);
  await settle();
  p.settle();
  assert.deepEqual(mbTimers(), timers(), "the retry's timer");
  for (const ms of [25, 50]) {
    const f = await advanceTs(ms);
    assert.deepEqual(p.ask("clock.advance", ms), f, `retried after ${ms}`);
    await settle();
    p.settle();
    assert.deepEqual(mbTimers(), timers(), `the retry's timer after ${ms}`);
  }
  for (const b of blockers) { b.exec("ROLLBACK"); b.close(); }
  const f = await advanceTs(100);
  assert.deepEqual(p.ask("clock.advance", 100), f, "retried once let go");
  await settleBoth();
  // the hour
  const hour = await advanceTs(60 * 60_000);
  assert.deepEqual(p.ask("clock.advance", 60 * 60_000), hour, "the hour");
  await settleBoth();
  assert.deepEqual(mbReads, tsReads, "every read");
  assert.deepEqual(mbTimers(), timers(), "the timers at last");
  // a read that fails, and one no longer valid
  given = { stations: [{ usage: { rows: [] }, chats: [] }], unread: [], valid: false };
  a.build();
  p.ask("stats.build", h);
  await settleBoth();
  a.close();
  p.ask("stats.close", h);
  assert.deepEqual(timers(), [], "the TypeScript's timers stopped");
  assert.deepEqual(mbTimers(), [], "the program's timers stopped");
  sameLogs(p.logs, tsLogs);
  assert.deepEqual(dump(t.mb), dump(t.ts));
});

test("workspace index: a workspace's build read only while the station is in it, its start again after a change", { skip }, async () => {
  begin(Date.UTC(2025, 9, 5, 10));
  const dir = fresh("comma-ws-"), mbDir = fresh("comma-ws-mb-");
  const p = mb();
  let inside = true, version = 0;
  const tsReads: Json[] = [], mbReads: Json[] = [];
  const read = async (from: number, to: number) => { tsReads.push([from, to]); return { stations: stationRows(), unread: [] }; };
  await CommaStats.makeDirs(dir);
  const w = workspaceIndex(dir, "ws-1\ud800", () => inside, () => version, read, () => () => {});
  p.answer = (name, args) => {
    if (name === "read") { mbReads.push([args[1], args[2]]); return { stations: stationRows(), unread: [] }; }
    if (name === "changes.listen" || name === "changes.stop") return null;
    throw new Error(`nothing answers ${name}`);
  };
  p.ask("stats.makeDirs", mbDir);
  const h = p.ask("wsindex.open", mbDir, "ws-1\ud800");
  const settleBoth = async () => {
    await w.stats.settled();
    await settle();
    p.settle();
    p.ask("stats.settled", h);
  };
  const steps: [string, () => void, () => void][] = [
    ["start", () => w.indexes.start(), () => p.ask("wsindex.start", h)],
    ["start again, nothing moved", () => w.indexes.start(), () => p.ask("wsindex.start", h)],
    ["out of the workspace, a build", () => { inside = false; w.stats.build(); }, () => { p.ask("wsindex.set", h, false, 0); p.ask("stats.build", h); }],
    ["in it again, the version moved: started again", () => { inside = true; version = 1; w.indexes.start(); }, () => { p.ask("wsindex.set", h, true, 1); p.ask("wsindex.start", h); }],
    ["the version moved under a build", () => { version = 2; w.stats.build(); }, () => { p.ask("wsindex.set", h, true, 2); p.ask("stats.build", h); }],
  ];
  for (const [what, ts, prog] of steps) {
    ts();
    prog();
    await settleBoth();
    assert.deepEqual(mbReads, tsReads, what);
  }
  w.stats.close();
  p.ask("stats.close", h);
  const name = createHash("sha256").update("ws-1\ud800", "utf16le").digest("hex");
  assert.equal(p.ask("workspaceDbName", "ws-1\ud800"), name, "the workspace's file");
  assert.deepEqual(dump(join(mbDir, "comma-indexes", `${name}.db`)), dump(join(dir, "comma-indexes", `${name}.db`)));
  sameLogs(p.logs, tsLogs);
});

// ── peers ──────────────────────────────────────────────────────────────────────────────────────────────────────

test("peers: another station's read answered, and a workspace's stations read, the same", { skip }, async () => {
  begin();
  const p = mb();
  const { bytesOf } = await import("../src/mesh/bus.ts");
  const answers: Record<string, string> = {
    outflowUsage: JSON.stringify({ rows: [{ day: "2025-10-01", session: "s", runtime: "claude", person: null, account: null, model: null }] }),
    outflowChats: JSON.stringify({ chats: [{ thread: 1 }] }),
    outflowMessages: "null",
  };
  for (const [peer, request, ws, home, refused] of [
    ["p1", { op: "outflowUsage", args: { from: 1, to: 2, lang: "en", ws: "spoofed" } }, "w1", "w1", []],
    ["p1", { op: "outflowChats", args: [7, 8] }, "w2", "w1", []],
    ["p1", { op: "outflowChats", args: "str" }, "w2", null, []],
    ["p2", { op: "outflowMessages", args: null }, "w1", "w1", ["p2"]],
    ["p1", { op: "nope" }, "w1", "w1", []],
    ["p1", { op: "outflowUsage" }, "", "w1", []],
    ["p1", { op: "outflowUsage" }, undefined, "w1", []],
    ["p1", null, "w1", "w1", []],
  ] as [string, Json, string | undefined, string | null, string[]][]) {
    const tsAsked: Json[] = [], mbAsked: Json[] = [];
    const handler = peerRead(async (op, args, lang) => { tsAsked.push([op, args, lang]); return answers[op]!; }, () => home, () => "zh", () => 3,
      (who, w) => { if (refused.includes(who)) throw new Error(`${who} is not of ${w}`); });
    const want = await settledAsync(async () => {
      const got = await handler(peer, request, ws);
      return { head: { size: (got as Json).size }, text: await textOf(bytesOf(got)!) };
    });
    p.answer = (name, args) => {
      if (name === "peer.read") { mbAsked.push(args); return answers[args[0]]; }
      throw new Error(`nothing answers ${name}`);
    };
    const got = mbSettled("peer.read", peer, request, home, 3, refused, ws ?? null);
    assert.deepEqual(got, want, `peerRead ${JSON.stringify(request)}`);
    assert.deepEqual(mbAsked, wire(tsAsked), `what was read for ${JSON.stringify(request)}`);
  }
  for (const chunks of [[], ["a", "😀b"], ["x".repeat(1000)]]) {
    const want = await textOf((async function* () { for (const c of chunks) yield Buffer.from(c); })());
    assert.equal(p.ask("peer.textOf", chunks), want);
  }
  // a workspace's stations: this one, two that answer (one in pages), one with a cursor that does not continue, one
  // whose usage answer is short, one whose roster is not known
  const usageOk = JSON.stringify({ rows: [{ day: "2025-10-02", session: "s", runtime: "codex", person: "p", account: null, model: "m" }], people: { p: { name: "P" } } });
  const there: Record<string, (op: string, args: Json) => string> = {
    a: (op) => (op === "outflowUsage" ? usageOk : JSON.stringify({ chats: [{ thread: 2 }] })),
    b: (op, args) => (op === "outflowUsage" ? usageOk : args.before === undefined ? JSON.stringify({ chats: [{ thread: 3 }], more: true, next: "c1" }) : JSON.stringify({ chats: [{ thread: 4 }], more: false })),
    c: (op, args) => (op === "outflowUsage" ? usageOk : JSON.stringify({ chats: [{ thread: 5 }], more: true, next: args.before ?? "same" })),
    d: (op) => (op === "outflowUsage" ? JSON.stringify({ rows: [{ day: "2025-10-02" }] }) : "{}"),
    e: () => "not json",
  };
  for (const [of, others] of [[{ workspace: "w1", home: true }, ["a", "b", "c", "d", "e"]], [null, ["a"]], [{ workspace: "w2", home: false }, null]] as [Json, string[] | null][]) {
    const calls = { ts: [] as Json[], mb: [] as Json[] };
    const reads = (side: "ts" | "mb"): WorkspaceReads => ({
      of: () => of,
      here: async (op, args) => { calls[side].push(["here", op, args]); return op === "outflowUsage" ? usageOk : JSON.stringify({ chats: [{ thread: 1 }] }); },
      others: async () => { calls[side].push(["others"]); if (others === null) throw new Error("the roster is not current"); return others; },
      there: async (station, op, args) => { calls[side].push(["there", station, op, args]); return there[station]!(op, args); },
    });
    const want = await settledAsync(() => workspaceRead(reads("ts"))(100, 200));
    const r = reads("mb");
    p.answer = (name, args) => {
      if (name === "reads.here") { calls.mb.push(["here", args[0], args[1]]); return args[0] === "outflowUsage" ? usageOk : JSON.stringify({ chats: [{ thread: 1 }] }); }
      if (name === "reads.others") { calls.mb.push(["others"]); if (others === null) throw new Error("the roster is not current"); return others; }
      if (name === "reads.there") { calls.mb.push(["there", args[0], args[1], args[2]]); return there[args[0]]!(args[1], args[2]); }
      throw new Error(`nothing answers ${name}`);
    };
    void r;
    const got = mbSettled("workspace.read", of, 100, 200);
    assert.deepEqual(got, want, `workspaceRead of ${JSON.stringify(of)}`);
    const key = (c: Json) => JSON.stringify(c);
    assert.deepEqual(calls.mb.map(key).sort(), wire(calls.ts).map(key).sort(), `what was read of ${JSON.stringify(of)}`);
  }
});

// ── the Router: its reads of a chat, its writes in one ─────────────────────────────────────────────────────────

test("router: a chat's messages read for the Router, from here and another station, the same", { skip }, async () => {
  begin();
  const t = twin();
  const p = mb();
  const a = new CommaStats(t.ts, nothing, quiet);
  const h = p.ask("stats.open", t.mb);
  const titled: StationRows[] = [{ usage: { rows: [] }, chats: [{ thread: 1, title: "Here" }, { thread: 2, title: "Two" }] }, { station: "st", usage: { rows: [] }, chats: [{ thread: 3, title: "There" }] }];
  a.apply(titled, [], 0);
  p.ask("stats.apply", h, titled, [], 0);
  const m = (n: number, kind = "message", extra: Json = {}) => ({ n, kind, authorKind: "person", author: `a${n}`, person: n % 2 === 0 ? { name: `N${n}`, email: `e${n}@x` } : n % 3 === 0 ? { email: `e${n}@x` } : null, text: `t${n}`, at: n * 10, ...extra });
  // what a station answers, by the position read after: messages only, or raw entries an older station gives (edits
  // between), and answers that do not hold up
  const answersBy: Record<string, (after: number, limit: number) => Json> = {
    plain: (after, limit) => ({ messages: [m(after + 1, "message", { card: { type: "options", options: [{ label: "Ship", recommended: true }] } }), m(after + 2, "message", { card: null })].slice(0, limit), last: after + 2, more: false, messagesOnly: true }),
    legacy: (after) => after < 30 ? { messages: [m(after + 1, "edit"), m(after + 2, "edit"), ...(after >= 20 ? [m(after + 3)] : [])], last: after + 3, more: true } : { messages: [m(after + 1)], last: after + 1, more: false },
    edits: (after) => ({ messages: [m(after + 1, "edit")], last: after + 1, more: true }),
    stuck: (after) => ({ messages: [m(after, "edit")], last: after, more: true }),
    nullChat: () => null,
    badLast: () => ({ messages: [], last: -1 }),
    badMore: () => ({ messages: [], last: 3, more: "yes" }),
    emptyMore: () => ({ messages: [], last: 3, more: true, messagesOnly: true }),
    notMessage: () => ({ messages: [m(1, "edit")], last: 2, more: false, messagesOnly: true }),
    descending: () => ({ messages: [m(2), m(1)], last: 2, more: false }),
    past: () => ({ messages: [m(9)], last: 5, more: false }),
    many: (after, limit) => ({ messages: Array.from({ length: limit + 5 }, (_, i) => m(after + i + 1)), last: after + limit + 5, more: false }),
  };
  for (const kind of Object.keys(answersBy)) {
    for (const [ref, after, limit, of] of [["1", 0, 100, { workspace: "w", home: true }], ["3@st", 5, 2, null], ["2", 10, 1, { workspace: "w2", home: false }], ["nope", 0, 5, null], ["99", 0, 5, null]] as [string, number, number, Json][]) {
      const asked = { ts: [] as Json[], mb: [] as Json[] };
      const answer = (side: "ts" | "mb", where: string, args: Json) => {
        asked[side].push([where, args]);
        return JSON.stringify(answersBy[kind]!(args.after, args.limit));
      };
      const reads = { of: () => of, here: async (op: string, args: Json) => answer("ts", `here ${op}`, args), there: async (st: string, op: string, args: Json) => answer("ts", `there ${st} ${op}`, args) };
      const want = await settledAsync(() => routerReads(a, reads, ref, after, limit));
      p.answer = (name, args) => {
        if (name === "reads.here") return answer("mb", `here ${args[0]}`, args[1]);
        if (name === "reads.there") return answer("mb", `there ${args[0]} ${args[1]}`, args[2]);
        throw new Error(`nothing answers ${name}`);
      };
      assert.deepEqual(mbSettled("router.reads", h, of, ref, after, limit), want, `${kind} ${ref}`);
      assert.deepEqual(asked.mb, wire(asked.ts), `what was read: ${kind} ${ref}`);
    }
  }
  a.close();
  p.ask("stats.close", h);
});

/// A session of the rig's, in its home workspace.
function member(rig: Rig, key: string) {
  rig.store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: 1, ws: null } as never);
}

/// What the program's Router asks of a station's hub and store: the rig's.
const hubAnswer = (rig: Rig): Answer => (name, args, cb) => {
  const db = rig.store.db;
  switch (name) {
    case "hub.get": return db.prepare(args[0]).get(...args[1]) ?? null;
    case "hub.all": return db.prepare(args[0]).all(...args[1]);
    case "hub.run": db.prepare(args[0]).run(...args[1]); return null;
    case "hub.threadSessions": return rig.store.threadSessions(args[0]);
    case "hub.getSession": return rig.store.getSession(args[0]);
    case "hub.wsOf": return rig.hub.wsOf(args[0]);
    case "hub.deliver": rig.hub.deliver(args[0], args[1], args[2], args[3], { retryPending: true, workspace: args[4] }); return null;
    case "hub.complete": return rig.store.completeRouterWrite(args[0]);
    case "hub.say": {
      const hooks = args[3];
      return lifecycleSay(rig.hub, args[0], args[1], args[2], [], [], null, hooks === null ? undefined : {
        workspace: hooks.workspace,
        before: () => void cb(hooks.before)(),
        inserted: (n: number) => void cb(hooks.inserted)(n),
        targets: () => cb(hooks.targets)(),
      });
    }
  }
  throw new Error(`nothing answers ${name}`);
};

/// What a rig keeps of the Router's writes: the chat's messages, each session's, the keyed writes and their targets.
function routerState(rig: Rig, thread: number, sessions: string[]): Json {
  return {
    messages: rig.store.entriesAfter(thread, 0).filter((e) => e.kind === "message").map((e) => [e.n, e.author, e.text]),
    pending: sessions.map((s) => rig.store.pendingMessages(s).map((m) => [m.message.n, m.message.text])),
    once: rig.store.db.prepare("SELECT id, key, thread, n, at, pending FROM comma_router_once ORDER BY id").all(),
    targets: rig.store.db.prepare("SELECT id, position, session FROM comma_router_once_targets ORDER BY id, position").all(),
  };
}

test("router: the Router's writes in a chat, once per key, against a station's store, the same", { skip }, async () => {
  begin();
  const p = mb();
  const rigs = [new Rig({ workspaces: ["home", "other"] }), new Rig({ workspaces: ["home", "other"] })];
  const [ra, rb] = rigs as [Rig, Rig];
  try {
    const threads: number[] = [];
    for (const rig of rigs) {
      rig.hub.hold("drain");
      for (const k of ["a", "b", "c", "d"]) member(rig, k);
      rig.store.db.prepare("UPDATE sessions SET ws = 'other' WHERE key = 'd'").run();
      const t1 = rig.store.openThreadOf("ember", "CHAT", "chat", "A chat", "ann@x", "a");
      rig.store.joinThread(t1.id, "a", "ember"); rig.store.joinThread(t1.id, "b", "ember"); rig.store.joinThread(t1.id, "c", "ember");
      rig.store.leaveThread(t1.id, "b");
      const t2 = rig.store.openThreadOf("ember", "CHAT", "chat2", "Other's", "ann@x", "d");
      rig.store.joinThread(t2.id, "d", "ember");
      threads.push(t1.id, t2.id);
    }
    const [t1, t2] = threads as [number, number];
    const sa = CommaStats.at(ra.dir, nothing, quiet);
    const hb = p.ask("stats.at", rb.dir);
    p.answer = hubAnswer(rb);
    const home = ra.hub.wsOf("a");
    const writes: [string, Json, string | null, (() => void)?][] = [
      ["a keyed write", { thread: t1, text: "hello", key: "cm:k1", requester: "Router", connect: "cm" }, home],
      ["the same key again", { thread: t1, text: "hello again", key: "cm:k1", requester: "Router", connect: "cm" }, home],
      ["a write with no key", { thread: t1, text: "no key", key: "", requester: "Swarm", connect: "cm" }, home],
      ["another workspace's chat", { thread: t2, text: "x", key: "cm:k2", requester: "Router", connect: "cm" }, home],
      ["another workspace's chat, no key", { thread: t2, text: "x", key: "", requester: "Router", connect: "cm" }, home],
      ["no such chat", { thread: 99999, text: "x", key: "cm:k3", requester: "Router", connect: "cm" }, home],
      ["the other workspace's own", { thread: t2, text: "theirs", key: "cm:k4", requester: "Router", connect: "cm" }, "other"],
      ["a keyed write, its delivery interrupted", { thread: t1, text: "interrupted", key: "cm:k5", requester: "Router", connect: "cm" }, home, () => {
        for (const rig of rigs) {
          const deliver = rig.hub.deliver;
          rig.hub.deliver = () => { rig.hub.deliver = deliver; throw new Error("delivery interrupted"); };
        }
      }],
      ["the interrupted one tried again (its text changed: the first is delivered)", { thread: -1, text: "-changed", key: "cm:k5", requester: "Router", connect: "cm" }, home, () => {
        for (const rig of rigs) rig.store.joinThread(t1, "b", "ember");
      }],
      ["its key expired", { thread: t1, text: "late", key: "cm:k6", requester: "Router", connect: "cm" }, home, () => {
        for (const rig of rigs) {
          rig.store.db.prepare("INSERT INTO comma_router_once (key, thread, n, at, pending) VALUES ('cm:k6', ?, 1, 1, 2)").run(t1);
        }
      }],
      ["a write after the days, old keys let go", { thread: t1, text: "much later", key: "cm:k7", requester: "Router", connect: "cm" }, home, () => {
        clock.now += 40 * DAY;
        p.ask("clock.set", clock.now);
      }],
    ];
    for (const [what, w, ws, before] of writes) {
      before?.();
      const want = settled(() => routerSays(ra.hub, sa, ws, w));
      const got = mbSettled("router.says", hb, ws, w);
      assert.deepEqual(got, want, what);
      assert.deepEqual(routerState(rb, t1, ["a", "b", "c", "d"]), routerState(ra, t1, ["a", "b", "c", "d"]), `the chat after: ${what}`);
      assert.deepEqual(routerState(rb, t2, ["d"]), routerState(ra, t2, ["d"]), `the other chat after: ${what}`);
    }
    // a busy store: the write refused as the station is busy, with and without a key
    for (const rig of rigs) {
      const insert = rig.store.insertMessage;
      rig.store.insertMessage = (() => { rig.store.insertMessage = insert; throw new MessageWriteBusy("busy"); }) as never;
    }
    assert.deepEqual(mbSettled("router.says", hb, home, { thread: t1, text: "busy", key: "cm:k8", requester: "Router", connect: "cm" }),
      settled(() => routerSays(ra.hub, sa, home, { thread: t1, text: "busy", key: "cm:k8", requester: "Router", connect: "cm" })), "busy");
    sa.close();
    p.ask("stats.close", hb);
    assert.deepEqual(dump(join(rb.dir, "comma-stats.db")), dump(join(ra.dir, "comma-stats.db")), "the old database's keys");
  } finally {
    for (const rig of rigs) await rig.close();
  }
});

// ── a connect's socket ─────────────────────────────────────────────────────────────────────────────────────────

/// Frames as compared: a UUID either side made said as such (the two index senders take theirs in their own order).
const plainIds = (v: Json): Json => JSON.parse(JSON.stringify(v).replace(/00000000-0000-4000-8000-\d{12}/g, "<uuid>"));
/// Each side's frames, by what they are (a request by its method, an answer by the request's id), in their order.
const framesBy = (frames: Json[]): Json => {
  const out: Record<string, Json[]> = {};
  for (const f of frames.map(plainIds)) {
    const key = f.type === "request" ? `request ${f.method}` : f.type === "response" || f.type === "error" ? `${f.type} ${f.id}` : f.type;
    (out[key] ??= []).push(f);
  }
  return out;
};

test("surface: a connect's socket given the same frames by Comma, what it sends and does the same", { skip }, async () => {
  begin(Date.UTC(2025, 9, 5, 10));
  setStationLang("en");
  const p = mb();
  p.ask("lang", "en");
  const realOs = require("node:os");
  const keepOs = { platform: realOs.platform, arch: realOs.arch };
  realOs.platform = () => "linux";
  realOs.arch = () => "x64";
  syncBuiltinESMExports();
  const dir = fresh("comma-surface-");
  const t = twin();
  const tsTasks = new CommaTasks(join(dir, "ts-tasks.json"));
  const mbTasks = p.ask("tasks.open", join(dir, "mb-tasks.json"));
  const sa = new CommaStats(t.ts, nothing, quiet);
  const sh = p.ask("stats.open", t.mb);
  const rows: StationRows[] = [...stationRows(), {
    station: "big",
    usage: { rows: Array.from({ length: 420 }, (_, i) => ({ day: "2025-10-02", session: `s${i}`, runtime: "claude", model: i % 4 === 0 ? "m".repeat(600) : "opus", calls: i })) },
    chats: Array.from({ length: 230 }, (_, i) => ({ thread: i + 1, title: i % 5 === 0 ? "t".repeat(3000) : `chat ${i}` })),
  }];
  sa.apply(rows, [], Date.UTC(2025, 9, 1));
  p.ask("stats.apply", sh, rows, [], Date.UTC(2025, 9, 1));
  // (the epochs made first, the same: each index sender asks for its own in its own turn)
  randomSeq = 0;
  p.ask("random.reset");
  for (const index of ["stats", "task"] as const) assert.equal(p.ask("index.epoch", sh, index), (index === "stats" ? sa.stats : sa.tasks).epoch());
  const models = [{ runtime: "claude", model: "opus" }, { runtime: "claude", model: null }, { runtime: "codex", model: "gpt" }, { runtime: "claude", model: "opus" }];
  // each side's station: its store, its hub's handler, its names
  const sides = { ts: { calls: [] as Json[], events: [] as Json[], book: new Map<string, Json>(), sessions: new Map<string, Json>(), posts: 0 }, mb: { calls: [] as Json[], events: [] as Json[], book: new Map<string, Json>(), sessions: new Map<string, Json>(), posts: 0 } };
  const store = (side: "ts" | "mb") => ({
    getSession: (key: string) => { sides[side].calls.push(["getSession", key]); return sides[side].sessions.get(key) ?? null; },
    pendingCount: (key: string) => { sides[side].calls.push(["pendingCount", key]); return key.length; },
    threadAt: (surface: string, channel: string, ts: string) => { sides[side].calls.push(["threadAt", surface, channel, ts]); return ts.startsWith("1") ? { id: 77 } : null; },
    leaveThread: (thread: number, session: string) => { sides[side].calls.push(["leaveThread", thread, session]); },
  });
  const downloads = { ts: [] as Json[], mb: [] as Json[] };
  const handler = (side: "ts" | "mb") => async (event: Json) => {
    sides[side].events.push(wire(event));
    if (event.message.text === "fetch me") {
      for (const f of event.message.files) {
        downloads[side].push(side === "ts" ? await settledAsync(async () => [...await s.download(f)]) : mbSettled("surface.download", h, f.id, f.name, f.size));
      }
    }
    const key = `cm:TASK:${event.message.threadTs}`;
    if (!sides[side].sessions.has(key)) sides[side].sessions.set(key, { key, running: sides[side].events.length % 2 === 0 });
  };
  const chats = (side: "ts" | "mb") => ({
    read: async (ref: string, after: number, limit: number) => { sides[side].calls.push(["chats.read", ref, after, limit]); if (ref === "bad") throw new Error("no such chat"); return { title: "T", messages: [], through: after }; },
    say: async (ref: string, text: string, key: string, requester: string, connect: string) => { sides[side].calls.push(["chats.say", ref, text, key, requester, connect]); return { seq: 5 }; },
  });
  const tsStore = store("ts");
  const book = {
    person: (key: string, fetch: () => Promise<Json>) => {
      const known = sides.ts.book.get(key) ?? null;
      void fetch().then((person) => { if (person !== null) { sides.ts.calls.push(["book.person", key, wire(person)]); sides.ts.book.set(key, person); } else sides.ts.calls.push(["book.known", key]); });
      return known;
    },
  };
  randomSeq = 0;
  p.ask("random.reset");
  const s = new CommaSurface({ connect: "cm", server: "https://Comma.Example/", token: "tok-12345", name: "Ws · host", workspace: "w1", tasks: tsTasks, store: tsStore as never,
    models: () => models as never, book: book as never, lang: "en", stats: { stats: sa.stats, tasks: sa.tasks, start: () => {} }, chats: chats("ts"), previousExited: Promise.resolve(), inScope: () => true });
  (s as Json).handler = handler("ts");
  after(() => s.stop());
  const h = p.ask("surface.new", { connect: "cm", server: "https://Comma.Example/", token: "tok-12345", name: "Ws · host", workspace: "w1", tasks: mbTasks, stats: sh, chats: true, models, lang: "en" });
  const mbStore = store("mb"), mbHandler = handler("mb"), mbChats = chats("mb");
  const held = { ts: new Set<string>(), mb: new Set<string>() };
  const fileBytes = Buffer.from("file contents of a Comma Message, read a part at a time");
  // Comma's gateway, the same for each side: what it answers what a side asks
  const gateway = (side: "ts" | "mb", f: Json): Json | null => {
    if (f.type !== "request") return null;
    switch (f.method) {
      case "task.hello": return { type: "response", id: f.id, result: {} };
      case "stats.index": case "task.index": {
        const first = !held[side].has(f.method);
        held[side].add(f.method);
        return { type: "response", id: f.id, result: first ? { epoch: null, through: 0 } : { epoch: f.params.epoch, through: f.params.through } };
      }
      case "task.post": return f.params.text === "refuse" ? { type: "error", id: f.id, error: "no" } : { type: "response", id: f.id, result: { seq: 40 + ++sides[side].posts } };
      case "task.file": {
        const at = f.params.offset as number;
        return { type: "response", id: f.id, result: f.params.index === 9 ? { missing: "gone" } : { offset: at, data: fileBytes.subarray(at, at + 7).toString("base64") } };
      }
    }
    return null;
  };
  const sock = Object.assign(new (await import("node:events")).EventEmitter(), {
    sent: [] as Json[],
    send(d: string) {
      const f = JSON.parse(d);
      this.sent.push(f);
      const answer = gateway("ts", f);
      if (answer !== null) setImmediate(() => (s as Json).frame(sock, answer, () => sides.ts.calls.push(["end"])));
    },
  });
  p.onSent = (socket, f) => {
    const answer = gateway("mb", f);
    if (answer !== null) p.post("surface.frame", h, socket, answer);
  };
  p.onTold = (m) => { if (m.tell === "end") sides.mb.calls.push(["end"]); };
  p.answer = (name, args) => {
    switch (name) {
      case "store.getSession": return mbStore.getSession(args[1]);
      case "store.pendingCount": return mbStore.pendingCount(args[1]);
      case "store.threadAt": return mbStore.threadAt(args[1], args[2], args[3]);
      case "store.leaveThread": return mbStore.leaveThread(args[1], args[2]);
      case "handler": { const done = mbHandler(args[1]); void done; return null; }
      case "book.person": sides.mb.calls.push(["book.person", args[1], args[2]]); sides.mb.book.set(args[1], args[2]); return null;
      case "book.known": sides.mb.calls.push(["book.known", args[1]]); return sides.mb.book.get(args[1]) ?? null;
      case "chats.read": return null;
      case "chats.say": return null;
    }
    throw new Error(`nothing answers ${name}`);
  };
  // (the Router's reads and writes answered by each side's own, the program's synchronously)
  const prevAnswer = p.answer;
  p.answer = (name, args, cb) => {
    if (name === "chats.read") { sides.mb.calls.push(["chats.read", args[1], args[2], args[3]]); if (args[1] === "bad") throw new Error("no such chat"); return { title: "T", messages: [], through: args[2] }; }
    if (name === "chats.say") { sides.mb.calls.push(["chats.say", ...args.slice(1)]); return { seq: 5 }; }
    return prevAnswer(name, args, cb);
  };
  void mbChats;
  const settleBoth = async () => {
    for (let i = 0; i < 4; i++) {
      await settle();
      p.settle();
    }
  };
  const compare = (what: string) => {
    assert.deepEqual(framesBy(p.sent.map((x) => x.frame)), framesBy(sock.sent), `the frames sent: ${what}`);
    assert.deepEqual(sides.mb.events, sides.ts.events, `what the hub was handed: ${what}`);
    assert.deepEqual(sides.mb.calls, sides.ts.calls, `what the station was asked: ${what}`);
    sameLogs(p.logs, tsLogs, `what each logged: ${what}`);
  };
  assert.deepEqual(p.ask("surface.identify", h), wire((s as Json).identify ? await (s as Json).identify() : null), "who it is");
  assert.deepEqual(p.ask("surface.address", h), await (s as Json).address(), "where it dials");
  assert.equal(p.ask("surface.instance", h), (s as Json).instance, "its instance");
  // connected: metadata, hello, both indexes sent a page at a time as Comma takes them
  const frame = (f: Json) => {
    (s as Json).frame(sock, f, () => sides.ts.calls.push(["end"]));
    p.ask("surface.frame", h, 1, f);
  };
  frame({ type: "connected", device_id: "dev", connector_run_id: "run" });
  await settleBoth();
  for (let i = 0; i < 12; i++) {
    const fired = await advanceTs(300);
    assert.deepEqual(p.ask("clock.advance", 300), fired, `the index's wait ${i}`);
    await settleBoth();
  }
  compare("connected, the indexes sent");
  // the statistics change: sent again a second after, Comma given what it lacks
  const changed = [rows[0]!, { ...rows[4]!, chats: rows[4]!.chats.slice(0, 50) }];
  sa.apply(changed, [], Date.UTC(2025, 9, 1));
  p.ask("stats.apply", sh, changed, [], Date.UTC(2025, 9, 1));
  await settleBoth();
  for (let i = 0; i < 12; i++) {
    const fired = await advanceTs(300);
    assert.deepEqual(p.ask("clock.advance", 300), fired, `the change's wait ${i}`);
    await settleBoth();
  }
  compare("the indexes sent again after a change");
  // what Comma asks
  const requests: Json[] = [
    { method: "task.invite", params: { task: "t-1", start: { requester: "u1", title: " T ", runtime: "claude", model: "opus" }, answered: 2 } },
    { method: "task.invite", params: { task: "t-2", start: { requester: "u2", runtime: "codex" } } },
    { method: "task.invite", params: { task: "t-3", start: { requester: "u3", runtime: "nope" } } },
    { method: "task.invite", params: { task: "", start: {} } },
    { method: "task.invite", params: { task: "t-4", start: [] } },
    { method: "task.invite", params: { task: "t-1", start: { requester: "u1" }, replace: true } },
    { method: "task.invite", params: { task: "t-1", start: { requester: "u9" } } },
    { method: "task.put", params: { task: "t-1", through: 9, answered: 3, messages: [
      { seq: 5, author: { kind: "person", id: "p1", name: "Ann", email: "ann@x", picture: "https://pic" }, text: "five", files: [{ index: 0, name: "a.txt", size: 12 }, { index: 1, name: "", size: 1 }, { index: -1, name: "x", size: 1 }] },
      { seq: 2, author: { kind: "person", id: "p1" }, text: "answered already" },
      { seq: 4, author: { kind: "agent", id: "r1", session: "s" }, text: "its own" },
      { seq: 4, author: { kind: "agent", id: "r1" }, text: "four" },
      { seq: 6, author: { kind: "agent" }, text: "" },
      { seq: 7, author: null, text: 5, files: [{ index: 2, name: "b.bin", size: 3 }] },
      { seq: "8", text: "no seq" },
    ] } },
    { method: "task.put", params: { task: "t-1", through: 12, messages: [{ seq: 12, author: { kind: "person", id: "p2", name: "Bo" }, text: "twelve" }] } },
    { method: "task.put", params: { task: "nope", messages: [] } },
    { method: "task.put", params: { task: "t-1", messages: [{ seq: 13, author: { kind: "person", id: "p2", name: "Bo" }, text: "fetch me", files: [{ index: 0, name: "c.txt", size: fileBytes.length }, { index: 9, name: "gone.txt", size: 4 }] }] } },
    { method: "task.status", params: { task: "t-1" } },
    { method: "task.status", params: { task: "t-2" } },
    { method: "task.status", params: { task: "nope" } },
    { method: "task.read", params: { task: "12", after: 3, limit: 500 } },
    { method: "task.read", params: { task: "bad", after: -1, limit: 0 } },
    { method: "task.say", params: { task: "12", text: "  hi  ", key: "k1", requester_name: "Group", requester: "r" } },
    { method: "task.say", params: { task: "12", text: "   " } },
    { method: "task.say", params: { task: "12", text: "x", requester: "r2" } },
    { method: "task.posted_file", params: { key: "nope", task: "t-1", index: 0 } },
    { method: "task.leave", params: { task: "t-2" } },
    { method: "task.leave", params: { task: "nope" } },
    { method: "task.put", params: { task: "t-2", messages: [{ seq: 1, author: { kind: "person", id: "p" }, text: "after leaving" }] } },
    { method: "files.list", params: {} },
  ];
  for (const [i, r] of requests.entries()) {
    frame({ type: "request", id: `r${i}`, ...r });
    await settleBoth();
    compare(`request r${i} ${r.method}`);
  }
  frame({ type: "heartbeat" });
  frame({ type: "response", id: "unknown", result: 1 });
  frame("not an object");
  await settleBoth();
  compare("a heartbeat and what is not asked");
  // posts: plain, with a question card, with files Comma reads first, refused, and where a turn stands
  const t1 = threadTsOf("t-1");
  const att = join(dir, "att.txt");
  writeFileSync(att, "x".repeat(300_000));
  const files = [{ path: att, name: "att.txt", size: 300_000 }, { path: join(dir, "gone.txt"), name: "gone.txt", size: 1 }];
  const card = { type: "options", options: [{ label: "yes", recommended: true }, { label: "no", detail: "not now" }] };
  for (const [what, message, fs, c, thread] of [["plain", "hello", [], null, t1], ["a card", "pick one", [], card, t1], ["refused", "refuse", [], null, t1], ["no such Task", "x", [], null, "0.000000"]] as [string, string, Json[], Json, string][]) {
    const want = await settledAsync(() => s.post({ channel: "TASK", threadTs: thread }, message, fs, c));
    assert.deepEqual(mbSettled("surface.post", h, "TASK", thread, message, fs, c), want, `post: ${what}`);
    await settleBoth();
    compare(`post: ${what}`);
  }
  // a post with files: Comma reads them while it waits
  const pa = s.post({ channel: "TASK", threadTs: t1 }, "with files", files as never, null);
  p.onSent = (socket, f) => {
    if (f.type === "request" && f.method === "task.post" && f.params.files !== undefined) {
      for (const [k, q] of [[0, 0], [0, 262144], [1, 0], [5, 0]] as [number, number][]) {
        p.post("surface.frame", h, socket, { type: "request", id: `pf${k}-${q}`, method: "task.posted_file", params: { key: f.params.key, task: f.params.task, index: k, offset: q } });
      }
      p.post("surface.frame", h, socket, { type: "request", id: "pf-badtask", method: "task.posted_file", params: { key: f.params.key, task: "other", index: 0 } });
    }
    const answer = gateway("mb", f);
    if (answer !== null) p.post("surface.frame", h, socket, answer);
  };
  const postFrame = sock.sent.find((f: Json) => f.method === "task.post" && f.params.files !== undefined);
  for (const [k, q] of [[0, 0], [0, 262144], [1, 0], [5, 0]] as [number, number][]) {
    (s as Json).frame(sock, { type: "request", id: `pf${k}-${q}`, method: "task.posted_file", params: { key: postFrame.params.key, task: postFrame.params.task, index: k, offset: q } }, () => {});
  }
  (s as Json).frame(sock, { type: "request", id: "pf-badtask", method: "task.posted_file", params: { key: postFrame.params.key, task: "other", index: 0 } }, () => {});
  await settleBoth();
  const want = await settledAsync(() => pa);
  assert.deepEqual(mbSettled("surface.post", h, "TASK", t1, "with files", files, null), want, "post with files");
  await settleBoth();
  compare("post with files");
  for (const [kind, words] of [["done", null], ["need", "  over to you  "], ["left", "x"], ["done", "refuse"]] as [string, string | null][]) {
    s.standsAt({ channel: "TASK", threadTs: t1 }, { kind: kind as never, words });
    p.ask("surface.standsAt", h, "TASK", t1, kind, words);
    await settleBoth();
    compare(`stands at ${kind}`);
  }
  // a file of a Message read from Comma a part at a time; one gone, one not of a Message
  for (const [id, name, size] of [["5-0", "a.txt", 12], ["7-2", "b.bin", 3], ["nope", "x", 1]] as [string, string, number][]) {
    const want = await settledAsync(async () => [...await s.download({ id, name, size, url: null } as never)]);
    assert.deepEqual(mbSettled("surface.download", h, id, name, size), want, `download ${id}`);
    await settleBoth();
    compare(`download ${id}`);
  }
  assert.deepEqual(downloads.mb, downloads.ts, "files fetched while a Message was heard");
  assert.equal(downloads.ts.length, 2);
  for (const user of ["p1", "agent:r1", "nobody"]) {
    assert.equal(p.ask("surface.mention", h, user), s.mention(user), `mention ${user}`);
    await settleBoth();
  }
  for (const email of ["ann@x", "ANN@X", "none@x"]) {
    assert.deepEqual(p.ask("surface.lookUpEmail", h, email), await (s as Json).lookUpEmail(email), `look up ${email}`);
  }
  // a close: what waits is told Comma is not connected; the socket's own close ends the index senders
  frame({ type: "close" });
  await settleBoth();
  sock.emit("close");
  (s as Json).closed();
  p.ask("socket.close", 1);
  p.ask("surface.closed", h);
  await settleBoth();
  const notConnected = await settledAsync(() => s.post({ channel: "TASK", threadTs: t1 }, "after close", [], null));
  assert.deepEqual(mbSettled("surface.post", h, "TASK", t1, "after close", [], null), notConnected, "post after close");
  compare("closed");
  await tsTasks.written();
  p.ask("tasks.written", mbTasks);
  assert.equal(readFileSync(join(dir, "mb-tasks.json"), "utf8"), readFileSync(join(dir, "ts-tasks.json"), "utf8"), "the Tasks' file");
  await s.stop();
  sa.close();
  p.ask("stats.close", sh);
  assert.deepEqual(dump(t.mb), dump(t.ts));
  realOs.platform = keepOs.platform;
  realOs.arch = keepOs.arch;
  syncBuiltinESMExports();
  setStationLang("zh");
  p.ask("lang", "zh");
});

// ── Comma's parts: its connects, each connect's scope ──────────────────────────────────────────────────────────

test("parts: config.json's connects as the connects keep them, each one's scope as the station's workspaces move, the same", { skip }, async () => {
  begin();
  const p = mb();
  const { makeComma } = await import("../src/comma/index.ts");
  const realOs = require("node:os");
  const keepHost = realOs.hostname;
  realOs.hostname = () => "test-host";
  syncBuiltinESMExports();
  const rig = new Rig();
  try {
    for (const named of [false, true]) {
      p.told.length = 0;
      let raw: Json = { connects: [
        { id: "home", kind: "comma", comma: { server: "https://c.example", token: "home_token" } },
        { id: "joined", kind: "comma", workspace: "w-j", comma: { server: "https://c.example", token: "joined_token" } },
        { id: "other", kind: "comma", workspace: "w-x", comma: { server: "https://c.example", token: "other_token" } },
        { id: "off", kind: "comma", enabled: false, comma: { server: "https://c.example", token: "off_token" } },
        { id: "half", kind: "comma", comma: { server: "", token: "t" } },
        { id: "slack", kind: "slack" },
      ] };
      let home: string | null = "w-home", version = 0, within = ["w-home", "w-j"];
      const inWorkspace = ["w-j", "w-x"];
      let previousDone!: () => void;
      const previous = new Promise<void>((resolve) => { previousDone = resolve; });
      const tsScopes: string[] = [], tsAsked: Json[] = [], mbAsked: Json[] = [];
      const listeners = new Set<(raw: Json) => void>();
      const scopeListeners = new Set<() => void>();
      const config = { raw: () => raw, listen: (f: (raw: Json) => void) => { listeners.add(f); return () => listeners.delete(f); }, updateSoon: async () => {}, written: async () => {} };
      const emptyDb = new DatabaseSync(":memory:");
      emptyDb.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
      const empty = { stats: new RevIndex(emptyDb, "stats_index"), tasks: new RevIndex(emptyDb, "task_index"), start: () => {} };
      const scoped = { stats: new RevIndex(emptyDb, "stats_index"), tasks: new RevIndex(emptyDb, "task_index"), start: () => {} };
      const dir = fresh("comma-parts-");
      const connects = makeComma({ data: dir, config: config as never, store: rig.store, receive: async () => {}, bound: () => false,
        inWorkspace: (ws) => ws === null || inWorkspace.includes(ws),
        scope: (ws) => {
          tsScopes.push(ws);
          return { indexes: scoped, chats: { read: async (...a: Json[]) => (tsAsked.push(["read", ws, ...a]), { title: ws }), say: async (...a: Json[]) => (tsAsked.push(["say", ws, ...a]), { seq: 3 }) } };
        },
        empty, home: () => home, within: (ws) => within.includes(ws), scopeVersion: () => version,
        onScopeChange: (changed) => { scopeListeners.add(changed); return () => scopeListeners.delete(changed); }, previousExited: previous,
        ...(named ? { name: (ws: string | null) => `named ${ws ?? "home"}` } : {}) });
      const mbDir = fresh("comma-parts-mb-");
      const h = p.ask("comma.make", { data: mbDir, raw, home, within, inWorkspace, version, named });
      const mbScopes = () => p.told.filter((t) => t.tell === "scope").map((t) => t.workspace);
      p.answer = (name, args) => {
        if (name === "scope.read") { mbAsked.push(["read", args[0], args[1], args[2], args[3]]); return { title: args[0] }; }
        if (name === "scope.say") { mbAsked.push(["say", ...args]); return { seq: 3 }; }
        if (name === "comma.reconcile") return null;
        throw new Error(`nothing answers ${name}`);
      };
      const connections = (connects as Json).connections;
      assert.deepEqual(p.ask("comma.connects", h), wire(connects.connects()), "the connects");
      assert.deepEqual(p.ask("comma.credentials", h), connects.connects().map((c: Json) => connections.credentials(c)), "what makes each one's connection another");
      const surfaces: Record<string, { ts: Json; mb: number }> = {};
      for (const id of ["home", "joined", "other", "off", "half"]) {
        const c = connects.connects().find((x: Json) => x.id === id);
        surfaces[id] = { ts: connections.create(c), mb: p.ask("comma.create", h, id) };
      }
      const probe = (what: string) => {
        for (const [id, s] of Object.entries(surfaces)) {
          const ts = s.ts;
          let stats: Json;
          try {
            const got = typeof ts.stats === "function" ? ts.stats() : ts.stats;
            stats = got === null ? { none: true } : { is: got === empty ? "empty" : "scoped" };
          } catch (e) {
            stats = { error: (e as Error).message };
          }
          const want = { inScope: ts.inScope(), stats, chats: ts.chats !== null, name: ts.name, workspace: ts.ofWorkspace };
          assert.deepEqual(p.ask("comma.probe", h, s.mb), want, `${id}: ${what}`);
        }
        assert.deepEqual(mbScopes(), tsScopes, `the scopes opened: ${what}`);
      };
      probe("the previous station not gone yet");
      previousDone();
      p.ask("comma.set", h, { previousExited: true });
      await settle();
      p.settle();
      probe("the previous station gone");
      for (const [ref, after, limit] of [["12", 0, 5], ["3@st", 2, 1]] as [string, number, number][]) {
        for (const id of ["home", "joined"]) {
          const want = await settledAsync(() => surfaces[id]!.ts.chats.read(ref, after, limit));
          assert.deepEqual(mbSettled("comma.read", surfaces[id]!.mb, ref, after, limit), want, `read ${id} ${ref}`);
          const said = await settledAsync(() => surfaces[id]!.ts.chats.say(ref, "hi", "k", "Router", id));
          assert.deepEqual(mbSettled("comma.say", surfaces[id]!.mb, ref, "hi", "k", "Router", id), said, `say ${id} ${ref}`);
        }
      }
      assert.deepEqual(mbAsked, wire(tsAsked), "what the scopes' Routers were asked");
      const moves: [string, () => void, Json][] = [
        ["the home connect's token edited", () => { raw = structuredClone(raw); raw.connects[0].comma.token = "edited_token"; }, { raw: null }],
        ["the joined connect moved to another workspace", () => { raw = structuredClone(raw); raw.connects[1].workspace = "w-x"; }, { raw: null }],
        ["the station's workspaces moved", () => { version++; }, { version: null }],
        ["the station left the joined workspace", () => { within = ["w-home"]; }, { within: null }],
        ["the home moved", () => { home = "w-new"; within = ["w-new"]; }, { home: null, within: null }],
      ];
      for (const [what, move, set] of moves) {
        move();
        for (const l of listeners) l(raw);
        const now = { raw, home, version, within };
        p.ask("comma.set", h, Object.fromEntries(Object.keys(set).map((k) => [k, (now as Json)[k]])));
        probe(what);
      }
      for (const l of scopeListeners) l();
      p.ask("comma.scopeChanged", h);
      p.settle();
      for (const entry of [...raw.connects, null, {}, { comma: { server: "s", token: "abcdefgh" } }]) {
        assert.deepEqual(p.ask("comma.shown", entry), wire(connects.shown(entry)), `shown ${JSON.stringify(entry)}`);
      }
      assert.equal(p.ask("comma.tasksFile", h), join(mbDir, "comma-tasks.json"));
      assert.equal(connects.tasks.path, join(dir, "comma-tasks.json"));
      await connects.close();
      p.ask("comma.close", h);
      emptyDb.close();
    }
  } finally {
    realOs.hostname = keepHost;
    syncBuiltinESMExports();
    await rig.close();
  }
});

// ── the Comma part of the station (module.ts) ──────────────────────────────────────────────────────────────────
// module.ts is an Effect Layer over the whole station (its cloud, readers, mesh bus, store, agents and connects): no
// test makes it alone. What it decides of its own is held here to what its code says, case by case.

test("live: the station's workspaces, a peer's read and write, a scope's Router, as module.ts has them", { skip }, async () => {
  begin();
  const p = mb();
  const realOs = require("node:os");
  const keepHost = realOs.hostname;
  realOs.hostname = () => "test-host";
  syncBuiltinESMExports();
  const rig = new Rig({ workspaces: ["w-home"] });
  try {
    rig.hub.hold("drain");
    member(rig, "a");
    const thread = rig.store.openThreadOf("ember", "CHAT", "chat", "A chat", "ann@x", "a");
    rig.store.joinThread(thread.id, "a", "ember");
    const dir = fresh("comma-live-");
    const memberships: Json = { "w-home": { workspace: "w-home", workspace_name: "Home WS", name: "" }, "w-j": { workspace: "w-j", workspace_name: "J WS", name: "joined-st" } };
    const asked: Json[] = [];
    const hub = hubAnswer(rig);
    p.answer = (name, args, cb) => {
      if (name === "live.read") { asked.push(["read", ...args]); return args[0] === "outflowMessages" ? JSON.stringify({ messages: [], last: 0, more: false, messagesOnly: true }) : JSON.stringify({ read: args[0] }); }
      if (name === "live.askText") { asked.push(["askText", ...args]); return "there"; }
      if (name === "live.ask") {
        asked.push(["ask", ...args]);
        if (args[1].method === "peers") return args[1].workspace === "w-j" ? { current: true, stations: [{ id: "st-here" }, { id: "a" }, { id: "" }, { id: 5 }, null, { id: "b" }] } : { current: false };
        return { seq: 77 };
      }
      return hub(name, args, cb);
    };
    const h = p.ask("live.new", { data: dir, home: "w-home", memberships, station: "st-here" });
    assert.ok(existsSync(join(dir, "comma-indexes")) && existsSync(join(dir, "comma-stats.db")), "its folders and the legacy database made");
    assert.match(p.ask("live.emptyEpoch", h), /^[0-9a-f]{32}\.keys1\.gc1$/, "the empty index, an epoch of its own");
    // the workspaces' version: moved only as they change
    const versions: number[] = [];
    for (const set of [{ memberships }, { home: "w-home" }, { home: "w-j" }, { home: "w-home" }, { memberships: { ...memberships, "w-z": { workspace: "w-z", workspace_name: "Z", name: "z" } } }, { memberships }]) {
      p.ask("live.set", h, set);
      versions.push(p.ask("live.scopeVersion", h));
    }
    assert.deepEqual(versions, [0, 0, 1, 2, 3, 4]);
    assert.deepEqual(["w-home", "w-j", "w-x"].map((w) => p.ask("live.within", h, w)), [true, true, false]);
    assert.deepEqual([null, "w-j", "w-x"].map((w) => p.ask("live.name", h, w)), ["Home WS · test-host", "J WS · joined-st", "test-host"]);
    // a write another station's Router asks of this one
    const say = (request: Json, ws: string | null) => mbSettled("live.say", h, "peer", request, ws);
    assert.deepEqual(say({ say: { thread: thread.id, text: "x" } }, null), { error: "not this workspace", kind: "" });
    assert.deepEqual(say({ say: { thread: thread.id, text: "x" } }, "w-x"), { error: "not this workspace", kind: "" });
    assert.deepEqual(say({}, "w-home"), { error: "no such write", kind: "" });
    assert.deepEqual(say({ say: { thread: "1", text: "x" } }, "w-home"), { error: "no such write", kind: "" });
    assert.deepEqual(say({ say: { thread: thread.id, text: "  " } }, "w-home"), { error: "no such write", kind: "" });
    assert.deepEqual(say({ say: { thread: thread.id, text: "early" } }, "w-home"), { error: "the previous station is still handing over; retry the write", kind: "" });
    p.ask("live.set", h, { previousExited: true });
    p.settle();
    const n = say({ say: { thread: thread.id, text: "from a peer" } }, "w-home");
    assert.deepEqual(rig.store.entriesAfter(thread.id, 0).filter((e) => e.kind === "message").map((e) => [e.n, e.author, e.text]), [[n.ok.seq, "slack:comma:Router", "from a peer"]]);
    const keyed = say({ say: { thread: thread.id, text: "keyed", key: "cm:k", requester: "Swarm", connect: "cm" } }, "w-home");
    assert.deepEqual(say({ say: { thread: thread.id, text: "keyed again", key: "cm:k", requester: "Swarm", connect: "cm" } }, "w-home"), keyed, "once per key");
    // a read another station asks of this one: the chats' with this station's pages, in the language it speaks
    asked.length = 0;
    assert.deepEqual(mbSettled("live.peerRead", h, "peer", { op: "outflowChats", args: { since: 1, pages: "spoofed" } }, "w-j"), { ok: { head: { size: Buffer.byteLength(JSON.stringify({ read: "outflowChats" })) }, text: JSON.stringify({ read: "outflowChats" }) } });
    p.ask("live.set", h, { refused: ["peer"] });
    assert.deepEqual(mbSettled("live.peerRead", h, "peer", { op: "outflowUsage" }, "w-j"), { error: "peer is not a station of w-j", kind: "" });
    assert.deepEqual(asked, [["read", "outflowChats", { since: 1, pages: { origin: "https://app.example", station: "st-here" }, lang: "zh", ws: { workspace: "w-j", home: false } }, "zh", false]]);
    // a scope's reads: this station's in the background, the others by the roster (this one, and no id, left out)
    asked.length = 0;
    assert.deepEqual(p.ask("live.others", h, "w-j"), ["a", "b"]);
    assert.deepEqual(mbSettled("live.others", h, "w-home"), { error: "the roster is not current", kind: "" });
    assert.equal(p.ask("live.here", h, "w-j", "outflowChats", { since: 2, lang: "en" }), JSON.stringify({ read: "outflowChats" }));
    assert.equal(p.ask("live.there", h, "w-j", "st-2", "outflowUsage", { from: 1 }), "there");
    assert.deepEqual(asked, [
      ["ask", "", { method: "peers", workspace: "w-j" }],
      ["ask", "", { method: "peers", workspace: "w-home" }],
      ["read", "outflowChats", { since: 2, lang: "zh", pages: { origin: "https://app.example", station: "st-here" } }, "zh", true],
      ["askText", "st-2", { method: "outflow.read", workspace: "w-j", op: "outflowUsage", args: { from: 1 }, whole: true }],
    ]);
    // a scope's Router: reads through the index, writes here or on the chat's station
    asked.length = 0;
    assert.deepEqual(mbSettled("live.scopeRead", h, "w-home", `${thread.id}`, 0, 5), { ok: { title: "", messages: [], through: 0 } });
    const here = mbSettled("live.scopeSay", h, "w-home", `${thread.id}`, "router here", "k2", "Router", "cm");
    assert.equal(typeof here.ok.seq, "number");
    assert.deepEqual(rig.store.db.prepare("SELECT key FROM comma_router_once ORDER BY id").all().map((r: Json) => r.key), ["cm:k", "cm:k2"], "keyed by its connect");
    assert.deepEqual(mbSettled("live.scopeSay", h, "w-home", "3@st-2", "router there", "", "Router", "cm"), { ok: { seq: 77 } });
    assert.deepEqual(mbSettled("live.scopeSay", h, "w-home", "x", "t", "", "Router", "cm"), { error: "no such chat", kind: "" });
    assert.deepEqual(mbSettled("live.scopeSay", h, "w-x", "1", "t", "", "Router", "cm"), { error: "the workspace changed while writing", kind: "" });
    assert.deepEqual(asked, [
      ["read", "outflowMessages", { thread: thread.id, after: 0, limit: 5, messagesOnly: true, ws: { workspace: "w-home", home: true }, lang: "zh" }, "zh", true],
      ["ask", "st-2", { method: "comma.say", workspace: "w-home", say: { thread: 3, text: "router there", key: "", requester: "Router", connect: "cm" } }],
    ]);
    // peer chat-change push: local chat moves notify peers after 1 s, and incoming peerChanged checks membership
    asked.length = 0;
    assert.deepEqual(mbSettled("live.peerChanged", h, "peer", "w-j"), { error: "peer is not a station of w-j", kind: "" });
    p.ask("live.set", h, { refused: [] });
    assert.deepEqual(mbSettled("live.peerChanged", h, "peer", "w-j"), { ok: { ok: true } });
    assert.deepEqual(mbSettled("live.peerChanged", h, "peer", "w-x"), { error: "not this workspace", kind: "" });
    p.ask("live.changed", h, "session");
    p.ask("live.changed", h, "thread");
    p.ask("clock.advance", 1_000);
    p.settle();
    assert.ok(asked.some((x: Json) => x[0] === "ask" && x[1] === "a" && x[2]?.method === "comma.changed" && x[2]?.workspace === "w-j"));
    assert.ok(asked.some((x: Json) => x[0] === "ask" && x[1] === "b" && x[2]?.method === "comma.changed" && x[2]?.workspace === "w-j"));
    assert.ok(existsSync(join(dir, "comma-indexes", `${createHash("sha256").update("w-home", "utf16le").digest("hex")}.db`)), "the scope's index, in its folder");
    p.ask("live.close", h);
  } finally {
    realOs.hostname = keepHost;
    syncBuiltinESMExports();
    await rig.close();
  }
});
