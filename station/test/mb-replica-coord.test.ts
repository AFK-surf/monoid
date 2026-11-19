// The copies, a station's retirement and a chat's hand-over in MoonBit (station/mb/src/replica_coord, the reader's
// `--builder harness-replica-coord`) held to the TypeScript they are written from (src/replica): each scenario is played
// on two sides made alike, one given the TypeScript and one the program, each in a temporary directory of its own, and
// what each answered (or threw, by its class and words), what it asked of the station's parts that acts (`quiet`,
// `hub.holdChat`, `store.goneTo`...), what it asked of other stations (each request as sent, the bytes after it by their
// hash), what it was told without answering (`changed`, an update held), and what it left on the disk (every path, its
// kind and bytes, the sides' own roots written `<root>`) must be the same.
//
// The station is a fake of the test's (`Side`): one function answers what both sides ask of its parts, the TypeScript
// through the deps objects its classes are given, the program through its harness's calls on stdout. Another station
// of the workspace is a function of the scenario's (`peer`), or the other side of a pair played through itself (a
// FolderPlace of the TypeScript's own, in a directory of each side's). Time is each side's clock, moved alike.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isDeepStrictEqual } from "node:util";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { mbHarnessBinary } from "./mb-harness.ts";
import { settle } from "./hub-fakes.ts";
import { Refused, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { oneBytes, readBytes } from "../src/mesh/files.ts";
import { stationLang } from "../src/ops/i18n.ts";
import { asHead, genMade } from "../src/replica/format.ts";
import { keepers, ranked, serve } from "../src/replica/peers.ts";
import { FolderPlace, behind, handOver, holdsAll, level } from "../src/replica/places.ts";
import { carriedTo, moved } from "../src/replica/restore.ts";
import { carriedPlace, cliKept, listFile } from "../src/replica/carry.ts";
import { connectsThere, jobWords, movedNote, rebuildGits } from "../src/replica/retire.ts";
import { mergeAgentHome, memoryMark, mergePresets } from "../src/replica/agent-carry.ts";
import { packBytes, receivePack } from "../src/replica/pack.ts";
import { receiveFile, sendGathered } from "../src/replica/sending.ts";
import { lackingIn } from "../src/replica/pack.ts";
import { floorOf, movedHere, Handover } from "../src/replica/handover.ts";
import { Copies, tell as copiesTell } from "../src/replica/copies.ts";
import { hearLines } from "../src/ops/log.ts";
import { Retire } from "../src/replica/retire.ts";
import { RetireAsks } from "../src/replica/retire-asks.ts";
import { afterOf, newCtx } from "../src/store/handover.ts";
import { movedSaid } from "../src/jobs/jobs.ts";
import { UNANSWERED } from "../src/move/module.ts";

type Json = any;
const NOW = 1_800_000_000_000;
const binary = mbHarnessBinary();
const dirs: string[] = [];
const programs: { close(): Promise<void> }[] = [];
// (each program waited for till it is gone, its directories after: one still running at the file's end is a leftover)
after(async () => {
  await Promise.all(programs.map((p) => p.close()));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// A child let go: its stdin ended, and waited for until it is gone (killed 2 s after where it is not).
function ended(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  const gone = new Promise<void>((r) => child.once("exit", () => r()));
  child.stdin?.end();
  setTimeout(() => child.kill("SIGKILL"), 2000).unref();
  return gone;
}

const A = "a".repeat(64);
const B = "b".repeat(64);
const C = "c".repeat(64);
const D = "d".repeat(64);
const WS = "W1";
const hex = (s: string) => createHash("sha256").update(s).digest("hex");

const catalog = (lang: string) => JSON.parse(readFileSync(new URL(`../../client/i18n/catalog/${lang}/station.json`, import.meta.url), "utf8"));

// ---------------------------------------------------------------------------------------------------------------
// The sides

class Thrown extends Error {
  readonly kind: string;
  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}

/// What a side was told: each acting call of a part, each request to another station, each notice.
type Told = [string, ...Json[]];

/// The names of what a part is asked that acts (what the sides must ask alike); the rest only read.
const ACTING = /^(quiet|unquiet|retired|accounts\.move|followAccounts|moveConnects|took|tell|jobs\.(start|stop|say)|notify|cards\.post|restart|restart\.go|runner\.(places|pass|newGenerations)|work\.(gather|place|drop)|git|hub\.(holdChat|releaseChat|wakeChat)|connects\.(route|learnOf)|store\.(goneTo|shownThere|notGone|deliveredThere|importRows|setBinding|showChat|usageChanged|setMovedNote|forgetImport|dropImport|setSessionUsage)|keepSends|arrivedStopped|shown|went|sending\.(lacking|put|putPack|adds))$/;

type Peer = (station: string, request: Json, bytes: Buffer | null, itself: boolean) => Promise<{ value: Json; bytes?: Buffer }>;

class Side {
  readonly root: string;
  readonly data: string;
  readonly told: Told[] = [];
  /// What it warned of in its log (part, words, fields).
  readonly warned: Json[] = [];
  now = NOW;
  timers: { due: number; n: number; f: () => void; off: boolean }[] = [];
  n = 0;
  peer: Peer = async () => {
    throw new Error("station unreachable");
  };
  /// What a part is asked, answered: the scenario's.
  parts: (name: string, args: Json[]) => Json = (name) => {
    throw new Error(`no part ${name}`);
  };
  state: Record<string, Json> = {};

  readonly name: "ts" | "mb";
  constructor(name: "ts" | "mb") {
    this.name = name;
    this.root = realpathSync(mkdtempSync(join(tmpdir(), `replica-coord-${name}-`)));
    dirs.push(this.root);
    this.data = join(this.root, "data");
    mkdirSync(this.data, { recursive: true });
  }

  part(name: string, args: Json[]): Json {
    if (ACTING.test(name)) this.told.push([name, ...norm(this, args)]);
    return this.parts(name, args);
  }

  async ask(station: string, request: Json, bytes: Buffer | null, itself: boolean) {
    const said = { ...request };
    delete said.page;
    // (a pack's bytes are each side's own compression: what it holds is told, not its bytes)
    let sent: Json = bytes === null ? null : hex(bytes.toString("latin1"));
    if (bytes !== null && request.pack === "zstd") {
      const into = mkdtempSync(join(tmpdir(), "replica-coord-pack-"));
      dirs.push(into);
      await receivePack(into, oneBytes(bytes), { strict: false, flush: false }).catch((e) => (sent = `bad: ${(e as Error).message}`));
      if (typeof sent === "string" && !sent.startsWith("bad")) sent = readdirSync(into).sort();
    }
    this.told.push(["ask", station, norm(this, said), sent, itself]);
    return this.peer(station, request, bytes, itself);
  }

  /// The TypeScript's Fibers, on this side's clock.
  readonly fibers = {
    now: () => this.now,
    after: (ms: number, f: () => void) => {
      const t = { due: this.now + Math.max(0, ms), n: ++this.n, f, off: false };
      this.timers.push(t);
      return () => void (t.off = true);
    },
  };

  advance(ms: number) {
    const until = this.now + ms;
    for (;;) {
      const due = this.timers.filter((t) => !t.off && t.due <= until).sort((a, b) => a.due - b.due || a.n - b.n)[0];
      if (due === undefined) break;
      due.off = true;
      this.now = Math.max(this.now, due.due);
      due.f();
    }
    this.now = until;
  }

  roster(ws: string) {
    return this.state.rosters?.[ws] ?? null;
  }
}

/// The sides' own paths and what is random in what they say made one.
function norm(side: Side, v: Json): Json {
  const text = JSON.stringify(v === undefined ? null : v) ?? "null";
  return JSON.parse(
    text
      .split(side.root).join("<root>")
      .replace(/[0-9a-z]+-[0-9a-f]{0,24}-[0-9a-f]{8}-[0-9a-f]{8}/g, "<hid>")
      .replace(/\.[0-9a-f]{8}\.tmp/g, ".<tmp>"),
  );
}

/// Every path under `dir`, its kind and bytes (a file's by their hash), in one order.
function tree(dir: string, skip: (rel: string) => boolean = () => false): Json[] {
  const out: Json[] = [];
  const walk = (at: string, rel: string) => {
    for (const name of readdirSync(at).sort()) {
      const r = rel === "" ? name : `${rel}/${name}`;
      if (skip(r)) continue;
      const p = join(at, name);
      const st = lstatSync(p);
      if (st.isSymbolicLink()) out.push([r, "link", readlinkSync(p)]);
      else if (st.isDirectory()) {
        out.push([r, "dir"]);
        walk(p, r);
      } else out.push([r, "file", r.endsWith(".json") ? readFileSync(p, "utf8") : hex(readFileSync(p).toString("latin1"))]);
    }
  };
  if (existsSync(dir)) walk(dir, "");
  return out;
}

function sameFiles(label: string, a: Side, b: Side, skip?: (rel: string) => boolean) {
  const hid = (s: Side, t: Json[]) => norm(s, t).map((x: Json) => x.map((y: Json) => (typeof y === "string" ? y.replace(/[0-9a-z]+-[0-9a-f]{0,24}-[0-9a-f]{8}-[0-9a-f]{8}/g, "<hid>").replace(/"page":"[0-9a-f]{16}"/g, '"page":"<p>"') : y)));
  assert.deepStrictEqual(hid(b, tree(b.root, skip)), hid(a, tree(a.root, skip)), `${label}: the files differ`);
}

/// What a side was told, each kind's (and each station's requests) in its order: what goes on at once (requests to
/// several stations, a pass and a levelling) is each side's own interleaving, not what it did.
function byKind(told: Told[]): Record<string, Told[]> {
  const out: Record<string, Told[]> = {};
  for (const t of told) {
    const key = t[0] === "ask" ? `ask ${t[1]} ${t[2]?.method ?? ""} ${t[2]?.origin ?? ""}` : t[0];
    (out[key] ??= []).push(t);
  }
  return out;
}

function sameTold(label: string, a: Side, b: Side) {
  if (process.env.REPLICA_COORD_DUMP) writeFileSync(join(process.env.REPLICA_COORD_DUMP, `${label}.json`), JSON.stringify({ ts: a.told, mb: b.told }, null, 1));
  // (kind by kind, each one's both sides said whole as JSON where they differ: a failure in CI shows what differs, not
  // util.inspect's `[Array]` past its depth)
  const mb = byKind(b.told), ts = byKind(a.told);
  const json = (v: unknown) => { const j = JSON.stringify(v); return j.length > 6000 ? `${j.slice(0, 6000)}… (${j.length} chars)` : j; };
  assert.deepStrictEqual(Object.keys(mb).sort(), Object.keys(ts).sort(), `${label}: the kinds asked differ`);
  for (const k of Object.keys(ts)) {
    if (isDeepStrictEqual(mb[k], ts[k])) continue;
    assert.fail(`${label}[${k}] differs (mb ${mb[k]!.length}, ts ${ts[k]!.length})\n  mb: ${json(mb[k])}\n  ts: ${json(ts[k])}`);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The program

class Program {
  #child: ChildProcess;
  #next = 0;
  #waiting = new Map<number, (v: Json) => void>();
  readonly side: Side;
  constructor(side: Side) {
    this.side = side;
    programs.push(this);
    const shell = mkdtempSync(join(tmpdir(), "replica-coord-shell-"));
    dirs.push(shell);
    this.#child = spawn(binary!, ["--builder", "harness-replica-coord", "--shell-dir", shell], { stdio: ["pipe", "pipe", "inherit"] });
    createInterface({ input: this.#child.stdout! }).on("line", (line) => {
      const said = JSON.parse(line);
      if (said.call !== undefined) {
        void (async () => {
          try {
            if (said.name === "ask") {
              const body = typeof said.body === "string" ? Buffer.from(said.body, "base64") : null;
              const got = await this.side.ask(said.args[0], said.args[1], body, said.args[2] === true);
              this.#write({ ret: said.call, value: got.value ?? null, ...(got.bytes ? { body: got.bytes.toString("base64") } : {}) });
            } else {
              const value = await this.side.part(said.name, said.args);
              this.#write({ ret: said.call, value: value === undefined ? null : value });
            }
          } catch (e) {
            this.#write({ ret: said.call, throw: { kind: kindOf(e), message: (e as Error).message } });
          }
        })();
        return;
      }
      if (said.tell !== undefined) {
        this.side.told.push([`tell:${said.tell}`, ...norm(this.side, said.args)]);
        return;
      }
      if (said.log !== undefined) {
        if (said.log === "defect") this.side.told.push(["defect", said.words]);
        if (said.log === "warn") this.side.warned.push([said.part, said.words, said.fields]);
        return;
      }
      if (said.ready === true) return;
      this.#waiting.get(said.id)?.(said);
      this.#waiting.delete(said.id);
    });
  }
  #write(v: Json) {
    this.#child.stdin!.write(`${JSON.stringify(v)}\n`);
  }
  send(op: string, fields: Json): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve) => {
      this.#waiting.set(id, resolve);
      this.#write({ id, op, ...fields });
    });
  }
  async init() {
    await this.send("init", { sep: "/", lang: stationLang(), now: this.side.now, words: { zh: catalog("zh"), en: catalog("en") } });
  }
  async set(key: string, value: Json) {
    this.side.state[key] = value;
    await this.send("set", { key, value });
  }
  async call(part: string, method: string, args: Json[] = [], body?: Buffer): Promise<Json> {
    const said = await this.send("call", { part, method, args, ...(body ? { body: body.toString("base64") } : {}) });
    if (said.error !== undefined) throw new Thrown(said.error.kind, said.error.message);
    return said.body === undefined ? said.value : { value: said.value, bytes: Buffer.from(said.body, "base64") };
  }
  async fn(name: string, ...args: Json[]): Promise<Json> {
    const said = await this.send("fn", { name, args });
    if (said.error !== undefined) throw new Thrown(said.error.kind, said.error.message);
    return said.value;
  }
  async advance(ms: number) {
    this.side.advance(ms);
    await this.send("advance", { ms });
  }
  async settle() {
    await this.send("settle", {});
  }
  close(): Promise<void> {
    return ended(this.#child);
  }
}

const kindOf = (e: unknown): string => {
  if (e instanceof Thrown) return e.kind;
  if (e instanceof Refused) return "Refused";
  const n = (e as Error)?.constructor?.name ?? "Error";
  return n === "Said" || n === "AskAgain" || n === "Gone" || n === "Full" ? n : n === "NotEmpty" ? "NotEmpty" : "Error";
};

/// What a call came to: its value, or what it threw (its class as the program says it, its words).
async function outcome(side: Side, f: () => Json): Promise<Json> {
  try {
    return { value: norm(side, await f()) };
  } catch (e) {
    const kind = kindOf(e);
    return { error: norm(side, (e as Error).message), kind: kind === "Error" || kind === "TypeError" ? "Error" : kind };
  }
}

/// Both played: their outcomes the same.
async function both(label: string, ts: Side, mb: Side, a: () => Json, b: () => Json): Promise<Json> {
  const x = await outcome(ts, a);
  const y = await outcome(mb, b);
  assert.deepStrictEqual(y, x, `${label}: the answers differ`);
  return x;
}


const throwing = (e: unknown) => {
  if (e instanceof Thrown && e.kind === "Refused") return new Refused(e.message);
  return e;
};

/// The TypeScript's view of a part answered by `side.parts`.
const tsPart = (side: Side) => (name: string, ...args: Json[]) => {
  try {
    return side.part(name, args);
  } catch (e) {
    throw throwing(e);
  }
};

// ---------------------------------------------------------------------------------------------------------------

const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

test("the copies' functions are the TypeScript's", { skip }, async () => {
  const side = new Side("mb");
  const p = new Program(side);
  await p.init();
  const ts = new Side("ts");
  const same = async (name: string, a: () => Json, ...args: Json[]) => both(name, ts, side, a, () => p.fn(name, ...args));
  const stations = [A, B, C, D];
  for (const o of stations) {
    await same("keepers", () => keepers(WS, o, stations), WS, o, stations);
    await same("ranked", () => ranked("W2", o, [...stations, o]), "W2", o, [...stations, o]);
  }
  const head = { v: 1, origin: A, workspace: WS, gen: "lz5x0-0123abcd", name: "a", dataDir: "/d", made: 5, to: 9, batches: ["0000000001-0000000009-0123abcd.ndjson.zst"], files: { [hex("f")]: 3 }, chats: 1, messages: 2, bytes: 3, runs: [{ run: "r1", from: 1 }] };
  for (const h of [head, { ...head, v: 2 }, { ...head, gen: "x" }, { ...head, to: 1.5 }, { ...head, batches: ["no"] }, { ...head, files: { nothash: 1 } }, null, { ...head, runs: null }]) {
    await same("asHead", () => asHead(h), h);
  }
  for (const g of ["lz5x0-0123abcd", "0-00000000", "zzzzzzzzzzzzzzzz-ffffffff"]) await same("genMade", () => genMade(g), g);
  const held = (gens: Json[]) => ({ gens, files: [] });
  const cases = [
    held([{ gen: head.gen, head: { ...head, to: 9 }, batches: [] }]),
    held([{ gen: head.gen, head: { ...head, to: 12 }, batches: [] }]),
    held([{ gen: "zz5x0-0123abcd", head: { ...head, gen: "zz5x0-0123abcd" }, batches: [] }]),
    held([{ gen: head.gen, head: { ...head, runs: [{ run: "other", from: 3 }] }, batches: [] }]),
    held([{ gen: head.gen, head: { ...head, origin: B }, batches: [] }]),
  ];
  for (const h of cases) {
    await same("behind", () => behind(head as Json, h as Json), head, h);
    await same("holdsAll", () => holdsAll(h as Json, cases[0] as Json), h, cases[0]);
  }
  for (const [path, from, to] of [["/old/sessions/a/b", "/old", "/new"], ["/old", "/old", "/new"], ["/other/x", "/old", "/new"], ["/old/x", "", "/new"], ["/old/x", "/old/", "/new"]]) {
    await same("moved", () => moved(path!, from!, to!), path, from, to);
  }
  for (const [path, room] of [["/old/transcripts/claude/-old-sessions-a/x.jsonl", "/new/sessions/a"], ["/old/transcripts/codex/p/x.jsonl", "/new/sessions/a"], ["/old/sessions/a/f", null]]) {
    await same("carriedTo", () => carriedTo(path!, "/old", "/new", room), path, "/old", "/new", room);
  }
  for (const path of ["/d/sessions/a", "/d/transcripts-x/y/z", "/d/homes/p/agy/.gemini/antigravity-cli/brain/i/f", "/d/other/x", "/d", "/e/sessions/a"]) {
    await same("carriedPlace", () => carriedPlace("/d", path), "/d", path);
  }
  for (const parts of [["homes", "p", "agy", ".gemini", "antigravity-cli", "conversations", "i.db"], ["homes", "p", "agy", ".gemini", "antigravity-cli", "other", "x"], ["sessions"]]) {
    await same("cliKept", () => cliKept(parts), parts);
  }
  await same("listFile", () => listFile("/s", "chat:k"), "/s", "chat:k");
  await same("connectsThere", () => connectsThere(["slack1", "x@" + C], ["ember", "slack1", "f@" + B], A, B), ["slack1", "x@" + C], ["ember", "slack1", "f@" + B], A, B);
  const ours = { presets: [{ id: "p1", rev: 2, updatedAt: 5, name: "a" }, { id: "p2", name: "old" }], gone: [{ id: "g1", gone: true, rev: 1, updatedAt: 1 }], other: 1 };
  const theirs = { presets: [{ id: "p1", rev: 3, updatedAt: 1, name: "b" }, { id: "p2", rev: 1, updatedAt: 0, name: "older" }, { id: "p3", name: "new" }], gone: [{ id: "p4", gone: true, rev: 2 }] };
  await same("mergePresets", () => mergePresets(ours as Json, theirs as Json), ours, theirs);
  const jobs = [{ session: "s1", name: "web", command: "npm start", port: 3000, id: "j1", started: true, why: null }, { session: "s1", name: "w", command: "x", port: null, id: null, started: false, why: "it ran outside" }, { session: "s2", name: "o", command: "y", port: null, id: null, started: false, why: null, old: true }];
  await same("jobWords", () => jobWords(jobs as Json), jobs);
  const index = { v: 2, dataDir: "/old", sessions: [], gits: [], skipped: [], jobs: [{ session: "s1", name: "web", command: "npm start" }], bundles: {}, files: 0, bytes: 0 };
  for (const [s, j] of [[{ key: "s1", workspace: "/old/sessions/s1/workspace", room: "/old/sessions/s1" }, jobs], [{ key: "s1", workspace: "/proj", room: null }, null], [{ key: "s2", workspace: "/old/sessions/s2", room: "/old/sessions/s2" }, jobs]]) {
    await same("movedNote", () => movedNote("old-station", "here", index as Json, s as Json, "/new", "/new/repos", j as Json), "old-station", "here", index, s, "/new", "/new/repos", j);
  }
  await same("movedHere", () => movedHere("B", "/old/sessions/s1/w", "/old", "/new"), "B", "/old/sessions/s1/w", "/old", "/new");
  await same("movedHere", () => movedHere("B", "/x", "/same", "/same"), "B", "/x", "/same", "/same");
  for (const t of [null, 10, 500 * 1024 ** 3]) await same("floorOf", () => floorOf(t), t);
  for (const [table, row] of [["entries", { n: 3 }], ["dismissed", { viewer: "v", n: 2 }], ["turns", { started_at: 1, id: "t" }], ["usage", { at: 4, id: "u" }], ["usage_files", { path: "/p" }], ["sessions", { key: "k" }], ["pins", { viewer: "w" }]]) {
    await same("afterOf", () => afterOf(table as Json, row as Json) ?? null, table, row);
  }
  const ctx = { from: B, here: A, fromData: "/old", toData: "/new", connects: { a: "b" }, profiles: {}, ws: "coming:W1" };
  await same("newCtx", () => newCtx(ctx as Json), ctx);
  const changes = [
    { type: "session", key: "k" }, { type: "sessionRemoved", key: "k", ws: "W1" }, { type: "thread", id: 3, entries: [] }, { type: "thread", id: 4, entries: [1] },
    { type: "thread", id: 5, entries: [1], closed: true }, { type: "letters" }, { type: "threadRemoved", id: 6 }, { type: "read", viewer: "v", thread: 1 },
    { type: "hidden", viewer: "v", thread: 2 }, { type: "muted", viewer: "v", thread: 3 }, { type: "pins", viewer: "v", session: "s" }, { type: "pins", viewer: "v" },
    { type: "dismissed", viewer: "v", card: { thread: 1, n: 2 }, kept: { thread: 3 } }, { type: "chatMark", session: "s", opened: 1, thread: 9 }, { type: "chatMark", session: "s", thread: null }, { type: "nothing" },
  ];
  for (const c of changes) {
    await same("tell", () => {
      const t = { sessions: [], threads: [], removedSessions: [], removedThreads: [], marks: [] };
      const said = copiesTell(t as Json, c as Json);
      return { said, told: t };
    }, c);
  }
  for (const [why, job, err] of [["moved", { name: "web", port: 3000, id: "j1" }, null], ["moved", { name: "w", port: null }, "no"], ["m", { name: "s", port: 8 }, null]]) {
    await same("movedSaid", () => movedSaid(why as string, job as Json, err as Json), why, job, err);
  }
  await same("memoryMark", () => memoryMark(A), A);
  for (const m of ["the station answered nothing", "Connection was reset", "stream stopped", "something else", "timed out after 30 s", "station unreachable"]) {
    await same("unanswered", () => UNANSWERED.test(m), m);
  }
  await p.close();
});

test("a station's folder of copies, levelling and handing over, as the TypeScript's", { skip }, async () => {
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  const gen = "lz5x0-0123abcd";
  const b1 = "0000000001-0000000004-00000000.ndjson.zst";
  const b2 = "0000000005-0000000009-11111111.ndjson.zst";
  const files = { [hex("one")]: 3, [hex("two")]: 3 };
  for (const s of [ts, mb]) {
    mkdirSync(join(s.root, "own"), { recursive: true });
    writeFileSync(join(s.root, "own", b1), "batch one");
    writeFileSync(join(s.root, "own", b2), "batch two");
    writeFileSync(join(s.root, "own", "one"), "one");
    writeFileSync(join(s.root, "own", "two"), "two");
  }
  const head = (to: number, batches: string[], fs: Json) => ({ v: 1, origin: A, workspace: WS, gen, name: "a", dataDir: "/d", made: 7, to, batches, files: fs, chats: 1, messages: 1, bytes: 1, runs: [{ run: "r1", from: 1 }] });
  let knownTs: Json = null;
  let knownMb: Json = null;
  for (const h of [head(4, [b1], { [hex("one")]: 3 }), head(9, [b1, b2], files), head(9, [b2], { [hex("two")]: 3 })]) {
    const own = (s: Side) => ({ dir: join(s.root, "own"), head: h, sources: { [hex("one")]: join(s.root, "own", "one"), [hex("two")]: join(s.root, "own", "two") } });
    const a = await outcome(ts, async () => {
      const done = await level(new FolderPlace(join(ts.root, "keep")), WS, {
        head: h as Json,
        batch: async (name) => readFileSync(join(ts.root, "own", name)),
        sources: async (hashes) => new Map(hashes.map((x) => [x, own(ts).sources[x]!])),
      }, knownTs);
      if (done.behind) return { behind: true };
      knownTs = done.known;
      return { behind: false, to: done.to, missing: done.missing, known: { ...done.known, batches: [...done.known.batches], files: [...done.known.files].sort(), others: [...done.known.others].sort() } };
    });
    const b = await outcome(mb, async () => {
      const done = await p.fn("level", join(mb.root, "keep"), WS, own(mb), knownMb);
      if (!done.behind) {
        knownMb = done.known;
        done.known.files.sort();
        done.known.others.sort();
      }
      return done;
    });
    assert.deepStrictEqual(b, a, "level");
    sameFiles("level", ts, mb);
  }
  // A folder's own answers.
  const folder = (s: Side) => join(s.root, "keep");
  await both("held", ts, mb, () => new FolderPlace(folder(ts)).held(WS, A), () => p.fn("folder.held", folder(mb), WS, A));
  await both("origins", ts, mb, () => new FolderPlace(folder(ts)).origins(WS), () => p.fn("folder.origins", folder(mb), WS));
  await both("pathOf", ts, mb, () => new FolderPlace(folder(ts)).pathOf(WS, A, gen, b2), () => p.fn("folder.pathOf", folder(mb), WS, A, gen, b2));
  await both("pathOf none", ts, mb, () => new FolderPlace(folder(ts)).pathOf(WS, A, null, "nothash"), () => p.fn("folder.pathOf", folder(mb), WS, A, null, "nothash"));
  await both("a head that goes back", ts, mb, () => new FolderPlace(folder(ts)).put(WS, A, gen, "head", "head.json", Buffer.from(JSON.stringify(head(2, [], {})))), () => p.fn("folder.put", folder(mb), WS, A, gen, "head", "head.json", Buffer.from(JSON.stringify(head(2, [], {}))).toString("base64")));
  await both("a head of another", ts, mb, () => new FolderPlace(folder(ts)).put(WS, A, gen, "head", "head.json", Buffer.from(JSON.stringify({ ...head(12, [], {}), origin: B }))), () => p.fn("folder.put", folder(mb), WS, A, gen, "head", "head.json", Buffer.from(JSON.stringify({ ...head(12, [], {}), origin: B })).toString("base64")));
  await both("a head before its batch", ts, mb, () => new FolderPlace(folder(ts)).put(WS, A, gen, "head", "head.json", Buffer.from(JSON.stringify(head(20, ["0000000010-0000000020-22222222.ndjson.zst"], {})))), () => p.fn("folder.put", folder(mb), WS, A, gen, "head", "head.json", Buffer.from(JSON.stringify(head(20, ["0000000010-0000000020-22222222.ndjson.zst"], {}))).toString("base64")));
  await both("not a copy's name", ts, mb, () => new FolderPlace(folder(ts)).held("bad ws", A), () => p.fn("folder.held", folder(mb), "bad ws", A));
  await both("drop", ts, mb, () => new FolderPlace(folder(ts)).drop(WS, A, gen, [b1, b2], [hex("one"), hex("two")]), () => p.fn("folder.drop", folder(mb), WS, A, gen, [b1, b2], [hex("one"), hex("two")]));
  sameFiles("drop", ts, mb);
  await both("hand over", ts, mb, () => handOver(new FolderPlace(folder(ts)), new FolderPlace(join(ts.root, "other")), WS, A), () => p.fn("handOverFolders", folder(mb), join(mb.root, "other"), WS, A));
  sameFiles("hand over", ts, mb);
  await p.close();
});

// ---------------------------------------------------------------------------------------------------------------
// Files sent: packs and single files, each side's taken by the other's

/// Files under `root/in` both sides read: their paths, bytes and hashes.
function inputs(): { dir: string; files: { hash: string; path: string; size: number }[] } {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "replica-coord-in-")));
  dirs.push(dir);
  const files = ["one", "two", "x".repeat(300_000), "", "zeros".repeat(70_000)].map((text, i) => {
    const path = join(dir, `f${i}`);
    writeFileSync(path, text);
    return { hash: hex(text), path, size: Buffer.byteLength(text) };
  });
  return { dir, files };
}

test("packs and files taken by their hash, each side's taken by the other's", { skip }, async () => {
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  const { files } = inputs();
  const wrong = { hash: hex("not what it holds"), path: files[0]!.path, size: files[0]!.size };
  for (const [label, entries, strict] of [["all", files, false], ["one changed", [files[0]!, wrong, files[1]!], false], ["strict changed", [wrong], true], ["gone", [{ ...files[0]!, path: join(ts.root, "none") }], false]] as [string, Json[], boolean][]) {
    const tookTs: Json[] = [];
    const tsBytes = await outcome(ts, async () => readBytes(packBytes(entries, strict, tookTs), 1 << 30));
    const mbPack = await outcome(mb, async () => p.fn("packBytes", entries, strict));
    assert.deepStrictEqual("error" in mbPack, "error" in tsBytes, `${label}: one failed`);
    if ("error" in tsBytes) {
      assert.deepStrictEqual(mbPack, tsBytes, label);
      continue;
    }
    assert.deepStrictEqual(norm(mb, mbPack.value.took), norm(ts, tookTs), `${label}: what went`);
    const mbBytes = Buffer.from(mbPack.value.bytes, "base64");
    // (each side's pack taken by the other's, and by its own)
    for (const [into, bytes] of [["from-ts", Buffer.from(tsBytes.value.data ?? tsBytes.value)], ["from-mb", mbBytes]] as [string, Buffer][]) {
      const opts = { strict: false, flush: false };
      const a = await outcome(ts, () => receivePack(join(ts.root, label, into), oneBytes(bytes), opts));
      const b = await outcome(mb, () => p.fn("receivePack", join(mb.root, label, into), bytes.toString("base64"), opts));
      assert.deepStrictEqual(b, a, `${label}: ${into} taken`);
    }
  }
  sameFiles("packs taken", ts, mb);
  for (const [label, name, body] of [["good", files[1]!.hash, "two"], ["bad", hex("zz"), "not it"], ["there", files[1]!.hash, "two"]] as [string, string, string][]) {
    await both(`receiveFile ${label}`, ts, mb, () => receiveFile(join(ts.root, "single"), name, oneBytes(Buffer.from(body))), () => p.fn("receiveFile", join(mb.root, "single"), name, Buffer.from(body).toString("base64")));
  }
  for (const label of ["bad pack", "short pack"]) {
    const bytes = label === "bad pack" ? Buffer.from("not zstd at all") : (await readBytes(packBytes([files[0]!], false, []), 1 << 20)).subarray(0, 10);
    await both(label, ts, mb, () => receivePack(join(ts.root, "bad"), oneBytes(bytes), { strict: false }), () => p.fn("receivePack", join(mb.root, "bad"), bytes.toString("base64"), { strict: false }));
  }
  await both("lackingIn", ts, mb, () => lackingIn(join(ts.root, "single"), [files[1]!.hash, hex("zz")]), () => p.fn("lackingIn", join(mb.root, "single"), [files[1]!.hash, hex("zz")]));
  sameFiles("files taken", ts, mb);
});

/// A gathering as carry.mbt writes one: an index of each session's list, in `dir`.
function gathering(dir: string, files: { hash: string; path: string; size: number }[], room: string) {
  mkdirSync(join(dir, "lists"), { recursive: true });
  const lines = files.map((f) => JSON.stringify({ path: f.path, hash: f.hash, size: f.size, mode: 0o644, mtimeMs: 1000 })).join("\n") + "\n";
  const list = join(dir, "lists", "s1.jsonl");
  writeFileSync(list, lines);
  const second = join(dir, "lists", "s2.jsonl");
  const secondLines = `${JSON.stringify({ path: files[0]!.path, hash: files[0]!.hash, size: files[0]!.size, mode: 0o644, mtimeMs: 1000 })}\n${JSON.stringify({ path: join(room, "link"), link: "x" })}\n`;
  writeFileSync(second, secondLines);
  const index = {
    v: 2, dataDir: dir, sessions: [
      { key: "s1", workspace: room, room, list: hex(lines), files: files.length, bytes: files.reduce((n, f) => n + f.size, 0), at: list },
      { key: "s2", workspace: room, room: null, list: hex(secondLines), files: 1, bytes: files[0]!.size, at: second },
    ], gits: [], skipped: [], jobs: [], bundles: {}, files: files.length + 1, bytes: files.reduce((n, f) => n + f.size, 0) + files[0]!.size,
  };
  writeFileSync(join(dir, "index.json"), JSON.stringify(index));
  return { index: join(dir, "index.json"), files: index.files, bytes: index.bytes, gits: 0, skipped: 0 };
}

test("a gathering sent a batch at a time, as the TypeScript sends it", { skip }, async () => {
  const { dir, files } = inputs();
  const g = gathering(dir, files, join(dir, "room"));
  for (const opts of [{ strict: true, packs: true, most: 2 }, { strict: true, packs: false, most: 3 }, { strict: false, indexed: true, packs: true, adds: true, packFiles: 2, packBytes: 400_000 }, { strict: false, packs: false }]) {
    const ts = new Side("ts");
    const mb = new Side("mb");
    const p = new Program(mb);
    await p.init();
    for (const s of [ts, mb]) {
      // (the other side lacks every other file; what it is sent is taken into its folder)
      s.parts = (name, args) => {
        if (name === "sending.lacking") return { lacking: args[0].filter((_: string, i: number) => i % 2 === 0), ...(opts.packs ? { pack: "zstd" } : {}) };
        if (name === "sending.put") return { ok: true };
        if (name === "sending.adds") return null;
        if (name === "sending.putPack") return { ok: true };
        throw new Error(`no part ${name}`);
      };
    }
    const taken = async (s: Side, bytes: Buffer) => {
      await receivePack(join(s.root, "taken"), oneBytes(bytes), { strict: false, flush: false });
    };
    const a = await outcome(ts, () => sendGathered(g, {
      lacking: async (hashes, fs) => ts.part("sending.lacking", [hashes, fs.map((f) => ({ hash: f.hash, path: f.path, size: f.size, ...(f.mtimeMs !== undefined ? { mtimeMs: f.mtimeMs } : {}), ...(f.room !== undefined ? { room: f.room } : {}) }))]),
      put: async (hash, bytes, path, size) => ts.part("sending.put", [hash, (await readBytes(bytes, 1 << 30)).toString("base64"), path, size]),
      ...(opts.packs ? {
        putPack: async (entries: Json[], bytes: Json, strict: boolean) => {
          await taken(ts, await readBytes(bytes, 1 << 30));
          return ts.part("sending.putPack", [entries, null, strict]);
        },
      } : {}),
      took: (f) => void ts.told.push(["tell:sending.took", norm(ts, f)]),
      ...(opts.packFiles !== undefined ? { packMost: { files: opts.packFiles, bytes: opts.packBytes } } : {}),
      most: opts.most ?? 2000,
      stopping: () => false,
      total: (b) => void ts.told.push(["tell:sending.total", b]),
      done: (b) => void ts.told.push(["tell:sending.done", b]),
      ...(opts.adds ? { adds: async (b: number) => void ts.part("sending.adds", [b]) } : {}),
    }, opts.strict, [{ session: "s1", name: "j" }], opts.indexed === true));
    mb.parts = (name, args) => {
      // (what came in a pack taken here, as the TypeScript's side takes it)
      if (name === "sending.putPack") return taken(mb, Buffer.from(args[1], "base64")).then(() => ts.parts(name, args));
      return ts.parts(name, args);
    };
    const b = await outcome(mb, () => p.fn("sendGathered", g, { ...opts, jobs: [{ session: "s1", name: "j" }] }));
    assert.deepStrictEqual(b, a, "the index's hash");
    // (a pack's bytes are each side's own compression: what they held compared, not their bytes)
    const plain = (t: Told[]) => t.map((x) => (x[0] === "sending.putPack" ? [x[0], x[1], x[3]] : x));
    assert.deepStrictEqual(plain(mb.told), plain(ts.told), `${JSON.stringify(opts)}: what was sent`);
    sameFiles(`${JSON.stringify(opts)}: what the packs held`, ts, mb);
    await p.close();
  }
});

test("a retired station's agent home merged in, as the TypeScript merges it", { skip }, async () => {
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  const src = realpathSync(mkdtempSync(join(tmpdir(), "replica-coord-home-")));
  dirs.push(src);
  const files = join(src, "files");
  mkdirSync(files, { recursive: true });
  const home = "/old/agent";
  const put = (rel: string, text: string, mode = 0o644) => {
    writeFileSync(join(files, hex(text)), text);
    return JSON.stringify({ path: `${home}/${rel}`, hash: hex(text), size: Buffer.byteLength(text), mode, mtimeMs: 1 });
  };
  const presets = JSON.stringify({ presets: [{ id: "p1", rev: 3, name: "theirs" }, { id: "p9", name: "new" }], gone: [{ id: "p2", gone: true, rev: 5 }] });
  const lines = [
    put("MEMORY.md", "# their memory\n- a fact\n"), put("presets.json", presets), put("skills/tool/SKILL.md", "a skill"), put("skills/tool/sub/x.sh", "#!/bin/sh", 0o755),
    put("skills/mine/SKILL.md", "theirs"), put("skills/.hidden/SKILL.md", "no"), put("other.txt", "no"), JSON.stringify({ path: `${home}/link`, link: "x" }), "not json",
  ];
  writeFileSync(join(src, "list.jsonl"), `${lines.join("\n")}\n`);
  for (const [label, memory] of [["empty", null], ["made empty", "# still.fail memory"], ["its own", "# ours\n- ours\n"]] as [string, string | null][]) {
    for (const s of [ts, mb]) {
      const to = join(s.root, label);
      mkdirSync(join(to, "skills", "mine"), { recursive: true });
      writeFileSync(join(to, "skills", "mine", "SKILL.md"), "ours");
      if (memory !== null) writeFileSync(join(to, "MEMORY.md"), memory);
      if (label === "its own") writeFileSync(join(to, "presets.json"), JSON.stringify({ presets: [{ id: "p1", rev: 2, name: "ours" }, { id: "p2", rev: 4, name: "kept" }] }));
    }
    const from = { origin: B, name: label === "its own" ? "" : "old one", at: NOW };
    for (let n = 0; n < 2; n++) {
      await both(`merge ${label} ${n}`, ts, mb, () => mergeAgentHome(join(ts.root, label), { dir: home, list: "", files: 0, bytes: 0, at: "" }, join(src, "list.jsonl"), files, from), () => p.fn("mergeAgentHome", join(mb.root, label), { dir: home }, join(src, "list.jsonl"), files, from));
    }
  }
  sameFiles("homes merged", ts, mb);
});

// ---------------------------------------------------------------------------------------------------------------
// The copies kept going

/// What a side's other stations are: each a folder of its own under the side's root, answering `replica.*` as the
/// TypeScript's `serve` does; `down` those not reached.
function peers(side: Side, down: Set<string>) {
  const places = new Map<string, Json>();
  return async (station: string, request: Json, bytes: Buffer | null) => {
    if (down.has(station)) throw new Error("station unreachable");
    if (!places.has(station)) places.set(station, serve({ place: new FolderPlace(join(side.root, "peers", station.slice(0, 4))), inWorkspace: () => true, hello: () => [] }));
    const answer = await places.get(station)(A, bytes === null ? { ...request } : withBytes({ ...request }, oneBytes(bytes)));
    const got = bytesOf(answer);
    return got === null ? { value: answer } : { value: { ...answer }, bytes: await readBytes(got, 1 << 30) };
  };
}

test("the copies brought to the stations that keep them, as the TypeScript brings them", { skip }, async () => {
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  const gen = "lz5x0-0123abcd";
  const b1 = "0000000001-0000000004-00000000.ndjson.zst";
  const b2 = "0000000005-0000000009-11111111.ndjson.zst";
  const down = new Set<string>([D]);
  const roster = { [WS]: [{ id: A, name: "a" }, { id: B, name: "b" }, { id: C, name: "c" }, { id: D, name: "d" }] };
  const places = { home: WS, workspaces: [{ workspace: WS, name: "a" }] };
  for (const s of [ts, mb]) {
    let passes = 0;
    s.state = { here: A, home: WS, places, rosters: roster };
    s.peer = peers(s, down) as Peer;
    const own = join(s.data, "replica", "own", WS, gen, "log");
    mkdirSync(own, { recursive: true });
    writeFileSync(join(own, b1), "one");
    writeFileSync(join(own, b2), "two");
    writeFileSync(join(s.root, "attached"), "attached");
    // (a workspace this station is not in any more: what it kept of it goes)
    mkdirSync(join(s.data, "replicas", "Gone", A), { recursive: true });
    // (another station's copy it keeps, not its own to keep)
    const kept = join(s.data, "replicas", WS, C, gen);
    mkdirSync(join(kept, "log"), { recursive: true });
    writeFileSync(join(kept, "log", b1), "c's");
    writeFileSync(join(kept, "head.json"), JSON.stringify({ v: 1, origin: C, workspace: WS, gen, name: "c", dataDir: "/c", made: 1, to: 4, batches: [b1], files: {}, chats: 1, messages: 1, bytes: 1, runs: [] }, null, 1));
    s.parts = (name, args) => {
      switch (name) {
        case "runner.places":
        case "runner.newGenerations":
        case "runner.close":
          return null;
        case "runner.pass": {
          // (a session told: the copy goes further, and stays there)
          if (args[0].sessions.length > 0) passes++;
          const to = passes > 0 ? 9 : 4;
          const batches = to === 9 ? [b1, b2] : [b1];
          return { heads: { [WS]: { v: 1, origin: A, workspace: WS, gen, name: "a", dataDir: "/d", made: 3, to, batches, files: { [hex("attached")]: 8 }, chats: 2, messages: 5, bytes: 9, runs: [{ run: "r1", from: 1 }] } }, more: false, wrote: 1, read: 3, empty: false };
        }
        case "runner.sources":
          return Object.fromEntries(args[0].map((h: string) => [h, join(s.root, "attached")]));
        case "restart":
          return false;
      }
      throw new Error(`no part ${name}`);
    };
  }
  const tsCopies = new Copies({
    data: ts.data, here: () => ts.state.here, places: () => ts.state.places, roster: (ws) => ts.roster(ws),
    ask: async (station, request) => {
      const bytes = bytesOf(request);
      const got = await ts.ask(station, request, bytes === null ? null : await readBytes(bytes, 1 << 30), false).catch((e) => Promise.reject(throwing(e)));
      return got.bytes === undefined ? got.value : withBytes(got.value, oneBytes(got.bytes));
    },
    runner: {
      places: async (pl) => void ts.part("runner.places", [pl]),
      pass: async (t) => ts.part("runner.pass", [t]),
      newGenerations: async (a) => void ts.part("runner.newGenerations", [a]),
      sources: async (h) => ts.part("runner.sources", [h]),
      close: async () => void ts.part("runner.close", []),
    },
    fibers: ts.fibers as Json,
    changed: () => void ts.told.push(["tell:changed"]),
    restart: async () => (ts.part("restart", []) === true ? async () => void ts.part("restart.go", []) : null),
    taking: () => new Set(),
  });
  for (const [k, v] of Object.entries(mb.state)) await p.set(k, v);
  await p.send("make", { part: "copies", deps: { data: mb.data } });
  // (each step brought to rest on both sides before the next: what one set going is done)
  const step = async (label: string, a: () => Json, b: () => Promise<Json>) => {
    ts.told.push(["step", label]);
    mb.told.push(["step", label]);
    const x = await outcome(ts, a);
    await settle();
    await tsCopies.settle();
    await settle();
    const y = await outcome(mb, b);
    await p.settle();
    await p.call("copies", "settle");
    await p.settle();
    ts.told.push(["outcome", label, x]);
    mb.told.push(["outcome", label, y]);
    assert.deepStrictEqual(y, x, `${label}: the answers differ`);
  };
  await step("start", () => tsCopies.start(), () => p.call("copies", "start"));
  await step("settle", () => tsCopies.settle(), () => p.call("copies", "settle"));
  await step("told", () => tsCopies.told({ type: "session", key: "s1" } as Json), () => p.call("copies", "told", [{ type: "session", key: "s1" }]));
  await step("a second on", async () => {
    ts.advance(1000);
    return null;
  }, async () => {
    await p.advance(1000);
    return null;
  });
  await step("settle after the gathering", () => tsCopies.settle(), () => p.call("copies", "settle"));
  await step("overview", () => tsCopies.overview(WS, true), () => p.call("copies", "overview", [WS, true]));
  await step("now", () => tsCopies.now(WS, C), () => p.call("copies", "now", [WS, C]));
  await step("heard", () => tsCopies.heard(B, WS, [D]), () => p.call("copies", "heard", [B, WS, [D]]));
  await step("settle after heard", () => tsCopies.settle(), () => p.call("copies", "settle"));
  await step("now after", () => tsCopies.now(null, D), () => p.call("copies", "now", [null, D]));
  await step("30 s on", async () => {
    ts.advance(30_000);
    return null;
  }, async () => {
    await p.advance(30_000);
    return null;
  });
  for (const [peer, request, body] of [
    [B, { method: "replica.hello", workspace: WS, formerly: [D, "no"] }, null],
    [B, { method: "replica.list", workspace: WS }, null],
    [B, { method: "replica.held", workspace: WS, origin: C }, null],
    [B, { method: "replica.get", workspace: WS, origin: C, gen, name: b1 }, null],
    [B, { method: "replica.get", workspace: WS, origin: C, gen, name: "head.json" }, null],
    [B, { method: "replica.get", workspace: WS, origin: C, gen: null, name: hex("x") }, null],
    [B, { method: "replica.put", workspace: WS, origin: B, kind: "file", name: hex("three") }, "three"],
    [B, { method: "replica.put", workspace: WS, origin: B, gen, kind: "batch", name: b1 }, "b"],
    [B, { method: "replica.put", workspace: WS, origin: B, gen, kind: "batch", name: "bad" }, "b"],
    [B, { method: "replica.put", workspace: WS, origin: B, gen, kind: "other", name: b1 }, "b"],
    [B, { method: "replica.put", workspace: WS, origin: B, kind: "file", name: hex("four") }, null],
    [C, { method: "replica.drop", workspace: WS, origin: C, gen, batches: [b1], files: [] }, null],
    [B, { method: "replica.drop", workspace: WS, origin: C, gen, batches: [b1], files: [] }, null],
    ["e".repeat(64), { method: "replica.held", workspace: WS, origin: A }, null],
    [B, { method: "replica.nothing", workspace: WS }, null],
  ] as [string, Json, string | null][]) {
    await step(`answer ${request.method}`, async () => {
      const req = body === null ? { ...request } : withBytes({ ...request }, oneBytes(Buffer.from(body)));
      const answer = await tsCopies.answers()(peer, req);
      const bytes = bytesOf(answer);
      return bytes === null ? answer : { value: { ...answer }, bytes: (await readBytes(bytes, 1 << 20)).toString("base64") };
    }, async () => {
      const got = await p.call("copies", "answer", [peer, request], body === null ? undefined : Buffer.from(body));
      return got?.bytes !== undefined && got?.value !== undefined ? { value: got.value, bytes: got.bytes.toString("base64") } : got;
    });
  }
  await step("settle at the end", () => tsCopies.settle(), () => p.call("copies", "settle"));
  await step("overview at the end", () => tsCopies.overview(WS), () => p.call("copies", "overview", [WS]));
  await step("restorable", () => tsCopies.restorable(WS), () => p.call("copies", "restorable", [WS]));
  await step("bringTo", () => tsCopies.bringTo(WS, B), () => p.call("copies", "bringTo", [WS, B]));
  await step("restore refused", () => tsCopies.restore(WS, C, gen, { station: A }), () => p.call("copies", "restore", [WS, C, gen, { station: A }]));
  await step("takeOver", () => tsCopies.takeOver(WS, C, gen, { connects: { x: "y" }, ws: null }), () => p.call("copies", "takeOver", [WS, C, gen, { connects: { x: "y" }, ws: null }]));
  await step("overview restoring", () => tsCopies.overview(WS), () => p.call("copies", "overview", [WS]));
  await tsCopies.close();
  await p.call("copies", "close");
  sameTold("copies", ts, mb);
  sameFiles("copies", ts, mb);
});

test("a keeper from before copies: said old, not warned of or tried again until it is heard from, the next one holding the copy, as the TypeScript does", { skip }, async () => {
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  const gen = "lz5x0-0123abcd";
  const b1 = "0000000001-0000000004-00000000.ndjson.zst";
  const roster = { [WS]: [{ id: A, name: "a" }, { id: B, name: "b" }, { id: C, name: "c" }, { id: D, name: "d" }] };
  const places = { home: WS, workspaces: [{ workspace: WS, name: "a" }] };
  const [first, second] = keepers(WS, A, [A, B, C, D]);
  const third = [B, C, D].find((x) => x !== first && x !== second)!;
  // (a station from before copies refuses every `replica.*` as its default handler did)
  const old = new Set<string>([first!]);
  for (const s of [ts, mb]) {
    s.state = { here: A, home: WS, places, rosters: roster };
    const there = peers(s, new Set());
    s.peer = (async (station: string, request: Json, bytes: Buffer | null) => {
      if (old.has(station)) throw new Refused("session and task key are required (at most 256 / 128 bytes)");
      return there(station, request, bytes);
    }) as Peer;
    const own = join(s.data, "replica", "own", WS, gen, "log");
    mkdirSync(own, { recursive: true });
    writeFileSync(join(own, b1), "one");
    s.parts = (name) => {
      switch (name) {
        case "runner.places":
        case "runner.newGenerations":
        case "runner.close":
          return null;
        case "runner.pass":
          return { heads: { [WS]: { v: 1, origin: A, workspace: WS, gen, name: "a", dataDir: "/d", made: 3, to: 4, batches: [b1], files: {}, chats: 1, messages: 1, bytes: 3, runs: [{ run: "r1", from: 1 }] } }, more: false, wrote: 1, read: 1, empty: false };
        case "runner.sources":
          return {};
        case "restart":
          return false;
      }
      throw new Error(`no part ${name}`);
    };
  }
  const tsCopies = new Copies({
    data: ts.data, here: () => ts.state.here, places: () => ts.state.places, roster: (ws) => ts.roster(ws),
    ask: async (station, request) => {
      const bytes = bytesOf(request);
      const got = await ts.ask(station, request, bytes === null ? null : await readBytes(bytes, 1 << 30), false).catch((e) => Promise.reject(throwing(e)));
      return got.bytes === undefined ? got.value : withBytes(got.value, oneBytes(got.bytes));
    },
    runner: {
      places: async (pl) => void ts.part("runner.places", [pl]),
      pass: async (t) => ts.part("runner.pass", [t]),
      newGenerations: async (a) => void ts.part("runner.newGenerations", [a]),
      sources: async (h) => ts.part("runner.sources", [h]),
      close: async () => void ts.part("runner.close", []),
    },
    fibers: ts.fibers as Json,
    changed: () => void ts.told.push(["tell:changed"]),
    restart: async () => null,
    taking: () => new Set(),
  });
  hearLines((l) => void (l.level === "WARN" && ts.warned.push([l.at, l.message, l.fields])));
  try {
    for (const [k, v] of Object.entries(mb.state)) await p.set(k, v);
    await p.send("make", { part: "copies", deps: { data: mb.data } });
    const step = async (label: string, a: () => Json, b: () => Promise<Json>) => {
      ts.told.push(["step", label]);
      mb.told.push(["step", label]);
      const x = await outcome(ts, a);
      await settle();
      await tsCopies.settle();
      await settle();
      const y = await outcome(mb, b);
      await p.settle();
      await p.call("copies", "settle");
      await p.settle();
      ts.told.push(["outcome", label, x]);
      mb.told.push(["outcome", label, y]);
      assert.deepStrictEqual(y, x, `${label}: the answers differ`);
      return x;
    };
    const asked = (s: Side) => s.told.filter((t) => t[0] === "ask" && t[1] === first).length;
    await step("start", () => tsCopies.start(), () => p.call("copies", "start"));
    await step("settle", () => tsCopies.settle(), () => p.call("copies", "settle"));
    const o = (await step("overview", () => tsCopies.overview(WS, true), () => p.call("copies", "overview", [WS, true]))).value;
    const keeping = (o: Json, s: string) => o.keepers.find((k: Json) => k.station === s);
    assert.equal(keeping(o, first!).reason, "old");
    assert.match(keeping(o, first!).error, /are required/);
    assert.equal(keeping(o, third).error, null, "the next one holds it in the old one's place");
    assert.equal(keeping(o, second!).error, null);
    const before = [asked(ts), asked(mb)];
    assert.ok(before[0]! > 0, "it was asked once");
    // a pass, and an hour on the clock: nothing asked of it again
    await step("told", () => tsCopies.told({ type: "session", key: "s1" } as Json), () => p.call("copies", "told", [{ type: "session", key: "s1" }]));
    for (let i = 0; i < 6; i++) {
      await step(`10 min on (${i})`, async () => {
        ts.advance(10 * 60_000);
        return null;
      }, async () => {
        await p.advance(10 * 60_000);
        return null;
      });
    }
    assert.deepEqual([asked(ts), asked(mb)], before, "no retry of a station from before copies");
    for (const s of [ts, mb]) assert.deepEqual(s.warned.filter((w) => w[1] === "a place not brought level"), [], `${s.name}: no warning of it`);
    // updated, it says it is up: brought level at once
    old.delete(first!);
    await step("heard", () => tsCopies.heard(first!, WS, []), () => p.call("copies", "heard", [first!, WS, []]));
    await step("settle after heard", () => tsCopies.settle(), () => p.call("copies", "settle"));
    const after = (await step("overview after", () => tsCopies.overview(WS, true), () => p.call("copies", "overview", [WS, true]))).value;
    assert.equal(keeping(after, first!).error, null);
    assert.equal(keeping(after, first!).reason, null);
    await tsCopies.close();
    await p.call("copies", "close");
    sameTold("copies-old", ts, mb);
    sameFiles("copies-old", ts, mb);
  } finally {
    hearLines(null);
  }
});

// ---------------------------------------------------------------------------------------------------------------
// A station retired

/// The station's parts a retirement asks, as the scenario's fake station answers them.
function retireParts(s: Side, g: Json, extra: (name: string, args: Json[]) => Json = () => undefined) {
  const gen = "lz5x0-0123abcd";
  return (name: string, args: Json[]): Json => {
    const more = extra(name, args);
    if (more !== undefined) return more;
    switch (name) {
      case "runner.places":
      case "runner.newGenerations":
      case "runner.close":
        return null;
      case "runner.pass":
        return { heads: { [WS]: { v: 1, origin: s.state.here, workspace: WS, gen, name: "a", dataDir: "/d", made: 3, to: 4, batches: ["0000000001-0000000004-00000000.ndjson.zst"], files: {}, chats: 2, messages: 5, bytes: 9, runs: [{ run: "r1", from: 1 }] } }, more: false, wrote: 0, read: 1, empty: false };
      case "runner.sources":
        return {};
      case "restart":
        return true;
      case "restart.go":
        return null;
      case "quiet":
        return [{ session: "s1", name: "web", command: "npm start", cwd: "/d/sessions/s1", port: 3000, watch: false }];
      case "unquiet":
      case "retired":
      case "took":
      case "moveConnects":
      case "tell":
      case "jobs.say":
      case "notify":
        return null;
      case "accounts.own":
        return [{ id: "p1", name: "Pro" }, { id: "p2", name: "Max" }];
      case "accounts.move":
        if (args[0] === "p2") throw new Thrown("Refused", "a machine's own login cannot move");
        return { id: `${args[0]}-there` };
      case "followAccounts":
        return 1;
      case "connectsOf":
        return ["slack1"];
      case "bindingsOf":
        return { slack1: "s1" };
      case "jobsIn":
        return [{ session: "s1", name: "web", command: "npm start" }];
      case "connectsNamed":
        return [{ id: "slack1", name: "Slack", kind: "slack" }];
      case "agentHome":
        return null;
      case "ofWorkspace":
        return true;
      case "room":
        return { free: 5 * 1024 ** 4, clones: false };
      case "hasGit":
        return true;
      case "jobs.start":
        return { id: "j9", name: args[1].name, port: args[1].port };
      case "jobs.running":
        return false;
      case "work.gather":
        return g;
      case "work.place":
        return { placed: 2, missing: 0, kept: 1 };
      case "work.preview":
        return { chats: 2, archived: 1, outside: 1 };
      case "git":
        return { out: "" };
      case "wsOf":
        return WS;
      case "cards.post":
        return { thread: 7, ts: "1.5" };
      case "cards.state":
        return "same";
    }
    throw new Error(`no part ${name}`);
  };
}

/// A side's Copies and Retire, the TypeScript's, over `s.parts`.
function tsRetire(s: Side) {
  const ask = async (station: string, request: Json, itself = false) => {
    const bytes = bytesOf(request);
    const got = await s.ask(station, request, bytes === null ? null : await readBytes(bytes, 1 << 30), itself).catch((e) => Promise.reject(throwing(e)));
    return got.bytes === undefined ? got.value : withBytes(got.value, oneBytes(got.bytes));
  };
  const part = tsPart(s);
  const copies = new Copies({
    data: s.data, here: () => s.state.here, places: () => s.state.places, roster: (ws) => s.roster(ws), ask: (st, r) => ask(st, r),
    runner: { places: async (pl) => void part("runner.places", pl), pass: async (t) => part("runner.pass", t), newGenerations: async (a) => void part("runner.newGenerations", a), sources: async (h) => part("runner.sources", h), close: async () => void part("runner.close") },
    fibers: s.fibers as Json, changed: () => void s.told.push(["tell:changed"]),
    restart: async () => (part("restart") === true ? async () => void part("restart.go") : null),
    taking: () => new Set(retire.takingNow()),
  });
  let asks: RetireAsks | null = null;
  let holds = 0;
  const retire: Retire = new Retire({
    data: s.data, here: () => s.state.here, home: () => s.state.home, roster: (ws) => s.roster(ws),
    ask: (st, r) => ask(st, r), askItself: (st, r) => ask(st, r, true), fibers: s.fibers as Json, changed: () => void s.told.push(["tell:changed"]),
    copies, quiet: async (ws) => part("quiet", ws), unquiet: (ws) => void part("unquiet", ws), retired: (ws) => void part("retired", ws),
    accounts: { own: () => part("accounts.own"), move: async (id, to) => part("accounts.move", id, to) },
    followAccounts: (keys, map) => part("followAccounts", keys, [...map]),
    connectsOf: (ws) => part("connectsOf", ws), bindingsOf: (cs) => part("bindingsOf", cs), moveConnects: async (ws, to) => void part("moveConnects", ws, to),
    took: (t) => void part("took", t), reposDir: join(s.root, "repos"),
    room: async () => part("room"), hasGit: async () => part("hasGit"), git: async (dir, args) => part("git", dir, args).out,
    work: {
      gather: (async (data: string, db: string, ws: string, home: boolean, scratch: string, _signal: Json, agent: string | null, keys: string[] | null) => part("work.gather", data, db, ws, home, scratch, agent ?? null, keys ?? null)) as Json,
      place: (async (data: string, index: string, from: string) => part("work.place", data, index, from, null, null, null, false)) as Json,
      preview: (async (data: string, db: string, ws: string, home: boolean) => part("work.preview", data, db, ws, home)) as Json,
    },
    jobsIn: (ws) => part("jobsIn", ws), connectsNamed: (ws) => part("connectsNamed", ws),
    tell: (session, text) => void part("tell", session, text),
    jobs: { start: async (session, j) => part("jobs.start", session, j), running: (session, n, c) => part("jobs.running", session, n, c), say: (session, text) => void part("jobs.say", session, text) },
    agentHome: (ws) => part("agentHome", ws), drives: (st, session) => asks?.drives(st, session) === true, ofWorkspace: (session, ws) => part("ofWorkspace", session, ws),
    hold: () => {
      const id = ++holds;
      s.told.push(["tell:hold", id]);
      return () => void s.told.push(["tell:letGo", id]);
    },
  });
  asks = new RetireAsks({
    data: s.data, here: () => s.state.here, roster: (ws) => s.roster(ws), wsOf: (session) => part("wsOf", session), retire,
    ask: (st, r) => ask(st, r),
    cards: { post: async (session, text, card) => part("cards.post", session, text, card), state: (session, thread, ts) => part("cards.state", session, thread, ts) },
    notify: (session, text) => void part("notify", session, text), now: () => s.now, id: (() => { let n = 0; return () => `r_test${++n}`; })(), starts: false,
  });
  return { copies, retire, asks };
}

async function mbRetire(p: Program, s: Side) {
  for (const [k, v] of Object.entries(s.state)) await p.set(k, v);
  await p.send("make", { part: "copies", deps: { data: s.data } });
  await p.send("make", { part: "retire", deps: { data: s.data, reposDir: join(s.root, "repos"), work: "station", jobs: true, tell: true } });
  await p.send("make", { part: "asks", deps: { data: s.data, ids: true, starts: false } });
}

function sessionsDb(s: Side) {
  const db = new DatabaseSync(join(s.data, "stillfail.db"));
  db.exec("CREATE TABLE sessions (key TEXT, connect TEXT, ws TEXT); INSERT INTO sessions VALUES ('s1', 'slack1', NULL), ('s2', 'ember', 'W1'), ('s3', 'other', 'W2')");
  db.close();
}

test("a station retired: its files sent, its chats handed over, its accounts and connects after them", { skip }, async () => {
  const { dir, files } = inputs();
  const g = gathering(dir, files, join(dir, "room"));
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  let take = 0;
  for (const s of [ts, mb]) {
    s.state = { here: A, home: WS, places: { home: WS, workspaces: [{ workspace: WS, name: "a" }] }, rosters: { [WS]: [{ id: A, name: "a" }, { id: B, name: "b" }, { id: C, name: "c" }] } };
    sessionsDb(s);
    const own = join(s.data, "replica", "own", WS, "lz5x0-0123abcd", "log");
    mkdirSync(own, { recursive: true });
    writeFileSync(join(own, "0000000001-0000000004-00000000.ndjson.zst"), "batch");
    s.parts = retireParts(s, g);
    const folders = peers(s, new Set());
    s.peer = async (station, request, bytes, itself) => {
      if (String(request.method).startsWith("replica.")) return folders(station, request, bytes);
      switch (request.method) {
        case "retire.begin":
        case "retire.room":
          return { value: { ok: true, free: 4 * 1024 ** 4, clones: false, git: true } };
        case "retire.lacking":
          return { value: { lacking: request.hashes, pack: "zstd" } };
        case "retire.put":
          if (request.pack === "zstd" && bytes !== null) await receivePack(join(s.root, "sent", station.slice(0, 4)), oneBytes(bytes), { strict: false, flush: false });
          return { value: { ok: true } };
        case "retire.take":
          take++;
          return { value: { ok: true } };
        case "retire.accounts":
        case "retire.tell":
          return { value: { ok: true } };
        case "retire.drop":
          return { value: { kept: true } };
      }
      void itself;
      throw new Thrown("Refused", "no such retire request");
    };
  }
  void take;
  const t = tsRetire(ts);
  const tsCopies = t.copies;
  await mbRetire(p, mb);
  // (each step brought to rest on both sides before the next: what one set going is done)
  const step = async (label: string, a: () => Json, b: () => Promise<Json>) => {
    ts.told.push(["step", label]);
    mb.told.push(["step", label]);
    const x = await outcome(ts, a);
    await settle();
    await tsCopies.settle();
    await settle();
    const y = await outcome(mb, b);
    await p.settle();
    await p.call("copies", "settle");
    await p.settle();
    ts.told.push(["outcome", label, x]);
    mb.told.push(["outcome", label, y]);
    assert.deepStrictEqual(y, x, `${label}: the answers differ`);
  };
  const settleBoth = async (label: string) => step(`settle ${label}`, async () => { await t.retire.settle(); await t.copies.settle(); }, async () => { await p.call("retire", "settle"); await p.call("copies", "settle"); });
  await step("start", async () => { await Promise.all([t.copies.start(), t.retire.start()]); return null; }, async () => { await p.call("copies", "start"); await p.call("retire", "start"); return null; });
  await settleBoth("started");
  await step("preview", () => t.retire.agentAsk(WS, { op: "preview", to: B }), () => p.call("retire", "agentAsk", [WS, { op: "preview", to: B }]));
  await step("not one of the workspace's", () => t.retire.retire(WS, D, "me@x"), () => p.call("retire", "retire", [WS, D, "me@x", {}]));
  await step("to itself", () => t.retire.retire(WS, A, "me@x"), () => p.call("retire", "retire", [WS, A, "me@x", {}]));
  await step("retire", () => t.retire.retire(WS, B, "me@x", { wait: true, driver: { station: A, session: "s9" } }), () => p.call("retire", "retire", [WS, B, "me@x", { wait: true, driver: { station: A, session: "s9" } }]));
  await settleBoth("sending");
  await step("again while it rests", () => t.retire.again(WS, { handOver: false }), () => p.call("retire", "again", [WS, { handOver: false }]));
  await step("status sent", () => t.retire.agentAsk(WS, { op: "status" }), () => p.call("retire", "agentAsk", [WS, { op: "status" }]));
  await step("a second retirement", () => t.retire.retire(WS, C, "me@x"), () => p.call("retire", "retire", [WS, C, "me@x", {}]));
  await step("hand over", () => t.retire.handOver(WS, "me@x"), () => p.call("retire", "handOver", [WS, "me@x"]));
  await settleBoth("handing");
  await step("overview handing", () => t.retire.overview(WS), () => p.call("retire", "overview", [WS]));
  const took = { method: "retire.took", workspace: WS, origin: B, jobs: [{ session: "s1", name: "web", command: "npm start", port: 3000, id: "j1", started: true, why: null }], driverTold: false, lost: null };
  await step("it took them", () => t.retire.answers((peer) => peer !== D)(B, { ...took }), () => p.call("retire", "answer", [B, took]));
  await settleBoth("took");
  await step("cancel once taken", () => t.retire.cancel(WS), () => p.call("retire", "cancel", [WS]));
  await step("status done", () => t.retire.agentAsk(WS, { op: "status" }), () => p.call("retire", "agentAsk", [WS, { op: "status" }]));
  for (const request of [
    { method: "retire.tell", workspace: WS, origin: B, session: "s9", text: "hello" },
    { method: "retire.tell", workspace: WS, origin: B, session: "", text: "" },
    { method: "retire.ask", workspace: WS, origin: B, session: "s5", op: "status" },
    { method: "retire.ask", workspace: WS, origin: B, session: "s5", op: "nothing" },
    { method: "retire.room", workspace: WS, origin: C },
    { method: "retire.nothing", workspace: WS, origin: B },
    { method: "retire.room", workspace: "bad ws", origin: B },
  ]) {
    await step(`answer ${request.method}`, () => t.retire.answers((peer) => peer !== D)(B, { ...request }), () => p.call("retire", "answer", [B, request]));
  }
  ts.advance(10 * 60_000);
  await p.advance(10 * 60_000);
  await settleBoth("at the end");
  await step("asks: start switched off", () => t.asks.tool("s1", { action: "start", to: "b" }), () => p.call("asks", "tool", ["s1", { action: "start", to: "b" }]));
  await step("asks: preview", () => t.asks.tool("s1", { action: "preview", to: "b" }), () => p.call("asks", "tool", ["s1", { action: "preview", to: "b" }]));
  await step("asks: status", () => t.asks.tool("s1", { action: "status" }), () => p.call("asks", "tool", ["s1", { action: "status" }]));
  await step("asks: of no station", () => t.asks.tool("s1", { action: "status", station: "nobody" }), () => p.call("asks", "tool", ["s1", { action: "status", station: "nobody" }]));
  await step("asks: two named", () => t.asks.tool("s1", { action: "status", station: "" }), () => p.call("asks", "tool", ["s1", { action: "status", station: "" }]));
  await step("asks: no action", () => t.asks.tool("s1", { action: "dance" }), () => p.call("asks", "tool", ["s1", { action: "dance" }]));
  await step("asks: may", () => t.asks.may({ role: "member", workspace: WS, email: "x" }, { retire: { ask: "none" } }, { thread: 7, ts: "1.5" } as Json), () => p.call("asks", "may", [{ role: "member", workspace: WS, email: "x" }, { retire: { ask: "none" } }, { thread: 7, ts: "1.5" }]));
  await t.retire.close();
  await t.copies.close();
  await p.call("retire", "close");
  await p.call("copies", "close");
  sameTold("retired", ts, mb);
  sameFiles("retired", ts, mb);
});

test("a retired station's chats taken here, as the TypeScript takes them", { skip }, async () => {
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  const gen = "lz5x0-0123abcd";
  const b1 = "0000000001-0000000004-00000000.ndjson.zst";
  const index = (_s: Side) => JSON.stringify({ v: 2, dataDir: "/old", sessions: [{ key: "s1", workspace: "/old/sessions/s1/workspace", room: "/old/sessions/s1", list: hex("l"), files: 1, bytes: 3, at: "/x" }], gits: [], skipped: [], jobs: [{ session: "s1", name: "web", command: "npm start", cwd: "/old/sessions/s1/workspace", port: 3000, watch: false }, { session: "s1", name: "out", command: "x", cwd: "/elsewhere" }, { session: "s1", name: "older", command: "y" }], bundles: {}, files: 1, bytes: 3, agent: null });
  for (const s of [ts, mb]) {
    s.state = { here: B, home: WS, places: { home: WS, workspaces: [{ workspace: WS, name: "b" }] }, rosters: { [WS]: [{ id: A, name: "a" }, { id: B, name: "b" }] } };
    s.parts = retireParts(s, null);
  }
  const t = tsRetire(ts);
  await mbRetire(p, mb);
  const step = async (label: string, a: () => Json, b: () => Promise<Json>) => {
    const x = await outcome(ts, a);
    await t.retire.settle();
    await settle();
    const y = await outcome(mb, b);
    await p.call("retire", "settle");
    await p.settle();
    await settle();
    assert.deepStrictEqual(y, x, `${label}: the answers differ`);
  };
  const ask = (label: string, request: Json, body?: Buffer) => step(label, async () => {
    const r = body === undefined ? { ...request } : withBytes({ ...request }, oneBytes(body));
    return t.retire.answers(() => true)(A, r);
  }, () => p.call("retire", "answer", [A, request], body));
  await ask("lacking before it began", { method: "retire.lacking", workspace: WS, origin: A, hashes: [] });
  await ask("begin", { method: "retire.begin", workspace: WS, origin: A, name: "a" });
  await ask("lacking", { method: "retire.lacking", workspace: WS, origin: A, hashes: [hex("one"), hex("two")] });
  await ask("too many", { method: "retire.lacking", workspace: WS, origin: A, hashes: ["no"] });
  await ask("put", { method: "retire.put", workspace: WS, origin: A, name: hex("one") }, Buffer.from("one"));
  await ask("put changed", { method: "retire.put", workspace: WS, origin: A, name: hex("one!") }, Buffer.from("two"));
  const tsIndex = Buffer.from(index(ts));
  const mbIndex = Buffer.from(index(mb));
  await step("put the index", () => t.retire.answers(() => true)(A, withBytes({ method: "retire.put", workspace: WS, origin: A, name: hex(index(ts)) }, oneBytes(tsIndex))), () => p.call("retire", "answer", [A, { method: "retire.put", workspace: WS, origin: A, name: hex(index(mb)) }], mbIndex));
  // (the copy a take brings into its restore, kept here as the retired station sent it)
  for (const s of [ts, mb]) {
    const kept = join(s.data, "replicas", WS, A, gen);
    mkdirSync(join(kept, "log"), { recursive: true });
    writeFileSync(join(kept, "log", b1), "batch");
    writeFileSync(join(kept, "head.json"), JSON.stringify({ v: 1, origin: A, workspace: WS, gen, name: "a", dataDir: "/old", made: 1, to: 4, batches: [b1], files: {}, chats: 1, messages: 1, bytes: 1, runs: [] }, null, 1));
  }
  await step("take", () => t.retire.answers(() => true)(A, { method: "retire.take", workspace: WS, origin: A, gen, carry: hex(index(ts)), connects: { slack1: "slack1@" + A }, bindings: { slack1: "s1" }, driver: { station: A, session: "s1" }, accounts: true }), () => p.call("retire", "answer", [A, { method: "retire.take", workspace: WS, origin: A, gen, carry: hex(index(mb)), connects: { slack1: "slack1@" + A }, bindings: { slack1: "s1" }, driver: { station: A, session: "s1" }, accounts: true }]));
  await step("overview taking", () => t.retire.overview(WS), () => p.call("retire", "overview", [WS]));
  await ask("drop after it is about to go in", { method: "retire.drop", workspace: WS, origin: A });
  await ask("keep", { method: "retire.drop", workspace: WS, origin: A, keep: true });
  await ask("accounts before it took them", { method: "retire.accounts", workspace: WS, origin: A, moved: [{ was: "p1", id: "p1-there" }], left: ["p2"] });
  await step("taking now", () => [...t.retire.takingNow()], () => p.call("retire", "takingNow"));
  await t.retire.close();
  await p.call("retire", "close");
  sameTold("taken", ts, mb);
  sameFiles("taken", ts, mb, (rel) => rel.endsWith("x"));
});

// ---------------------------------------------------------------------------------------------------------------
// A chat handed over

/// A side's station as a hand-over asks it: one chat (`s1`, its home thread 7, a Slack thread 8), its rows.
function handoverParts(s: Side, g: Json, handedBefore: [string, Json][] = []) {
  const handed = new Map<string, Json>(handedBefore);
  const counts = (ctx: Json, table: string, rows: Json[]) => {
    const c = ctx.counts;
    if (table === "sessions") c.sessions += rows.length;
    else if (table === "entries" || table === "letters") for (const r of rows) c[table][String(r.thread)] = (c[table][String(r.thread)] ?? 0) + 1;
    else if (table !== "threads") c.rows[table] = (c.rows[table] ?? 0) + rows.length;
    return ctx;
  };
  const rows: Record<string, Json[]> = {
    sessions: [{ key: "s1", ws: WS, connect: "ember", profile: "p1", profiles: ["p2"], workspace: join(s.data, "sessions", "s1", "workspace"), archivedAt: null, title: "Chat one" }],
    threads: [{ id: 7, surface: "ember", home: "s1" }],
    thread_sessions: [{ thread: 7, session: "s1", connect: "ember" }],
    entries: [{ thread: 7, n: 1 }, { thread: 7, n: 2 }, { thread: 8, n: 1 }],
    letters: [{ thread: 7, n: 1 }],
    runtime_sessions: [{ id: "r1", session: "s1", profile: "p3" }],
    turns: [{ id: "t1", started_at: 5 }],
    deliveries: [],
  };
  return (name: string, args: Json[]): Json => {
    switch (name) {
      case "store.getSession": return rows.sessions!.find((r) => r.key === args[0]) ?? null;
      case "store.homeChat": return args[0] === "s1" ? { id: 7, surface: "ember", home: "s1", channel: "c", threadTs: "t" } : null;
      case "store.threadSessions": return [{ session: "s1", thread: 7, connect: "ember" }];
      case "store.sessionThreads": return [{ thread: { id: 7, surface: "ember", home: "s1", channel: "c", threadTs: "t" }, connect: "ember" }, { thread: { id: 8, surface: "slack", home: null, channel: "C1", threadTs: "1.1" }, connect: "slack1" }];
      case "store.chatPage": {
        const [table, of, after] = args;
        const all = (rows[table] ?? []).filter((r: Json) => r.thread === undefined || typeof of !== "number" || r.thread === of);
        return all.filter((r: Json) => (table === "entries" || table === "letters") && typeof after === "number" ? r.n > after : true);
      }
      case "store.handedTo": return handed.get(args[0]) ?? null;
      case "store.sessionWs": return WS;
      case "store.goneTo":
        for (const k of args[0]) handed.set(k, { station: args[1], there: 70 });
        return null;
      case "store.notGone": return args[0];
      case "store.importCtx": return null;
      case "store.chatThreads": return [7, 8].filter((t) => t > args[1]);
      case "store.liveOf": return [];
      case "store.importRows": return counts(args[0], args[1], args[2]);
      case "store.binding": return null;
      case "store.sessionUsage": return null;
      case "store.shownThere": case "store.deliveredThere": case "store.setBinding": case "store.showChat": case "store.usageChanged": case "store.setMovedNote": case "store.forgetImport": case "store.dropImport": case "store.setSessionUsage":
        return null;
      case "hub.holdChat": case "hub.wakeChat": case "hub.turnEnded": case "hub.drained": return null;
      case "hub.releaseChat": return true;
      case "hub.busy": return false;
      case "hub.wsOf": return WS;
      case "connects.route": case "connects.learnOf": return null;
      case "connects.describedFor": return args[0] === "slack1" ? { station: s.state.here, described: { kind: "slack" } } : null;
      case "connects.kindOf": return args[0] === "slack1" ? { kind: "slack", mode: "thread" } : null;
      case "connects.runsOn": return null;
      case "jobs.of": return [{ session: "s1", name: "web", command: "npm start" }];
      case "jobs.stop": case "jobs.start": return null;
      case "accounts.of": return args[0] === "p3" ? null : { share: `sh-${args[0]}`, name: args[0] };
      case "accounts.here": return args[0]?.share === "sh-p1" ? "p1" : null;
      case "accounts.present": return args[0] !== "p2";
      case "keptSends": return [];
      case "keepSends": case "arrivedStopped": case "shown": case "went": case "flush": return null;
      case "bindingsOf": return {};
      case "fn.hasUsage": return false;
      case "fn.usageNow": return null;
      case "fn.handedStations": return [];
      case "work.gather": return g;
      case "work.place": return { placed: 2, missing: 0, kept: 1 };
      case "room": return { free: 5 * 1024 ** 4, total: 10 * 1024 ** 4 };
      case "hasGit": return true;
    }
    throw new Error(`no part ${name}`);
  };
}

function tsHandover(s: Side) {
  const part = tsPart(s);
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE TABLE usage (id TEXT, at INTEGER, session TEXT, thread INTEGER, profile TEXT); CREATE INDEX usage_session ON usage (session); CREATE TABLE handed_over (session TEXT, station TEXT, ws TEXT, thread INTEGER, there INTEGER); CREATE TABLE session_usage (session TEXT, usage TEXT)");
  const store = new Proxy({ db } as Json, {
    get: (o, k) => (k === "db" ? o.db : (...args: Json[]) => {
      const out = part(`store.${String(k)}`, ...args);
      if (k === "importRows") Object.assign(args[0], out);
      return out;
    }),
  });
  let holds = 0;
  const ask = async (station: string, request: Json) => {
    const bytes = bytesOf(request);
    const got = await s.ask(station, request, bytes === null ? null : await readBytes(bytes, 1 << 30), false).catch((e) => Promise.reject(throwing(e)));
    return got.bytes === undefined ? got.value : withBytes(got.value, oneBytes(got.bytes));
  };
  return new Handover({
    data: s.data, here: () => s.state.here, home: () => s.state.home, roster: (ws) => s.roster(ws), ask, fibers: s.fibers as Json, store,
    hub: { holdChat: async (k, why) => void part("hub.holdChat", k, why), releaseChat: (k) => part("hub.releaseChat", k), wakeChat: (k) => void part("hub.wakeChat", k), busy: (k) => part("hub.busy", k), turnEnded: async (k) => void part("hub.turnEnded", k), drained: async (c, ch, t) => void part("hub.drained", c, ch, t), wsOf: (k) => part("hub.wsOf", k) },
    connects: { route: async (id, c, t, st) => void part("connects.route", id, c, t, st), describedFor: (id) => part("connects.describedFor", id), learnOf: (k, st, d) => void part("connects.learnOf", k, st, d), kindOf: (id) => part("connects.kindOf", id), own: () => [], runsOn: (id) => part("connects.runsOn", id) },
    jobs: { of: (keys) => part("jobs.of", keys), stop: async (keys, why) => void part("jobs.stop", keys, why), start: (j) => void part("jobs.start", j) },
    accounts: { of: (id) => part("accounts.of", id), here: (a) => part("accounts.here", a), present: (id) => part("accounts.present", id) },
    reposDir: join(s.root, "repos"), room: async () => part("room"), hasGit: async () => part("hasGit"), flush: async (dir) => void part("flush", dir), boot: () => NOW - 1000,
    work: {
      gather: (async (data: string, db: string, ws: string, home: boolean, scratch: string, _signal: Json, agent: string | null, keys: string[] | null) => part("work.gather", data, db, ws, home, scratch, agent ?? null, keys ?? null)) as Json,
      place: (async (data: string, index: string, from: string, made: string | null, aside: string | null, placed: string | null, projects: boolean) => part("work.place", data, index, from, made, aside, placed, projects)) as Json,
    },
    told: { asked: (to: string, _key: string, make: () => Json) => ask(to, make()), run: (_peer: string, _key: string, work: () => Promise<Json>) => work(), letGo: (to: string, key: string, e: Error) => void s.told.push(["tell:told.letGo", to, key, e.message]), settle: async () => {} } as Json,
    changed: (id) => void s.told.push(["tell:changed", norm(s, id)]),
    arrivedStopped: async (keys, need, ws) => void part("arrivedStopped", keys, need, ws),
    keptSends: (threads) => part("keptSends", [...threads]),
    keepSends: (sends) => void part("keepSends", sends),
    hold: () => {
      const id = ++holds;
      s.told.push(["tell:hold", id]);
      return () => void s.told.push(["tell:letGo", id]);
    },
    shown: (keys, from) => void part("shown", keys, from),
    went: (keys) => void part("went", keys),
    bindingsOf: (keys) => part("bindingsOf", keys),
  });
}

async function mbHandover(p: Program, s: Side) {
  for (const [k, v] of Object.entries(s.state)) await p.set(k, v);
  await p.set("boot", { at: NOW - 1000 });
  await p.send("make", { part: "handover", deps: { data: s.data, reposDir: join(s.root, "repos"), work: "station", flush: true } });
}

test("a chat handed to another station, as the TypeScript hands it", { skip }, async () => {
  const { dir, files } = inputs();
  const g = gathering(dir, files, join(dir, "room"));
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  for (const s of [ts, mb]) {
    s.state = { here: A, home: WS, places: { home: WS, workspaces: [{ workspace: WS, name: "a" }] }, rosters: { [WS]: [{ id: A, name: "a" }, { id: B, name: "b" }, { id: C, name: "c", tasks: true }] } };
    s.parts = handoverParts(s, g);
    const there: Json = { sessions: 0, entries: {}, letters: {}, rows: {} };
    const refuseRows = false;
    s.peer = async (station, request, bytes) => {
      switch (request.method) {
        case "handover.begin": return { value: { ok: true, free: 4 * 1024 ** 4, total: 8 * 1024 ** 4, git: true, usage: true } };
        case "handover.lacking": return { value: { lacking: request.hashes.slice(1), pack: "zstd" } };
        case "handover.put":
          if (request.pack === "zstd" && bytes !== null) await receivePack(join(s.root, "sent", station.slice(0, 4)), oneBytes(bytes), { strict: false, flush: false });
          return { value: { ok: true } };
        case "handover.place": return { value: { ok: true, placed: 2, missing: 0 } };
        case "handover.rows": {
          if (refuseRows) throw new Thrown("Refused", "rows refused there");
          const t = request.table;
          if (t === "sessions") there.sessions += request.rows.length;
          else if (t === "entries" || t === "letters") for (const r of request.rows) there[t][String(r.thread)] = (there[t][String(r.thread)] ?? 0) + 1;
          else if (t !== "threads") there.rows[t] = (there.rows[t] ?? 0) + request.rows.length;
          return { value: { ok: true } };
        }
        case "handover.prune": return { value: { ok: true, removed: 0 } };
        case "handover.counts": return { value: { counts: { ...there, homes: { s1: 70 } } } };
        case "handover.show": case "handover.drop": return { value: { ok: true } };
        case "handover.held": return { value: { held: true } };
      }
      throw new Thrown("Refused", "no such hand-over request");
    };
  }
  const h = tsHandover(ts);
  await mbHandover(p, mb);
  const step = async (label: string, a: () => Json, b: () => Promise<Json>) => {
    const x = await outcome(ts, a);
    await h.settle();
    await settle();
    const y = await outcome(mb, b);
    await p.call("handover", "settle");
    await p.settle();
    await settle();
    assert.deepStrictEqual(y, x, `${label}: the answers differ`);
  };
  await step("start", () => h.start(), () => p.call("handover", "start"));
  for (const [key, to] of [["s1", A], ["none", B], ["s1", C], ["s1", D]]) {
    await step(`check ${key} ${to.slice(0, 1)}`, () => h.check(key!, to!), () => p.call("handover", "check", [key, to, {}]));
  }
  await step("together", () => h.together("s1"), () => p.call("handover", "together", ["s1"]));
  await step("chatOf", () => h.chatOf("s1"), () => p.call("handover", "chatOf", ["s1"]));
  await step("accountsOf", async () => Object.fromEntries(h.accountsOf(["s1"])), () => p.call("handover", "accountsOf", [["s1"]]));
  await step("handOver", () => h.handOver("s1", B), () => p.call("handover", "handOver", ["s1", B, {}]));
  await step("outs", () => h.outs(), () => p.call("handover", "outs"));
  await step("a second one while it is there", () => h.check("s1", B), () => p.call("handover", "check", ["s1", B, {}]));
  await step("reached", () => h.reached(B), () => p.call("handover", "reached", [B]));
  await step("looked", () => h.looked(), () => p.call("handover", "looked"));
  await step("answered: still", () => h.answers(() => true)(B, { method: "handover.still", workspace: WS, origin: B, id: "x-1" }), () => p.call("handover", "answer", [B, { method: "handover.still", workspace: WS, origin: B, id: "x-1" }]));
  sameTold("handed", ts, mb);
  sameFiles("handed", ts, mb);
  await p.close();
});

test("a chat that did not go: it goes on here, the other told to drop it", { skip }, async () => {
  const { dir, files } = inputs();
  const g = gathering(dir, files, join(dir, "room"));
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  for (const s of [ts, mb]) {
    s.state = { here: A, home: WS, places: { home: WS, workspaces: [{ workspace: WS, name: "a" }] }, rosters: { [WS]: [{ id: A, name: "a" }, { id: B, name: "b" }] } };
    s.parts = handoverParts(s, g);
    let drops = 0;
    s.peer = async (_station, request) => {
      switch (request.method) {
        case "handover.begin": return { value: { ok: true, free: 30 * 1024 ** 3, total: 100 * 1024 ** 3, git: true, usage: false } };
        case "handover.lacking": return { value: { lacking: request.hashes } };
        case "handover.put": return { value: { ok: true } };
        case "handover.place": return { value: { ok: true, placed: 2, missing: 0 } };
        case "handover.rows": throw new Thrown("Refused", "rows refused there");
        case "handover.drop":
          if (drops++ === 0) throw new Error("station unreachable");
          return { value: { ok: true } };
      }
      throw new Thrown("Refused", "no such hand-over request");
    };
  }
  const h = tsHandover(ts);
  await mbHandover(p, mb);
  const step = async (label: string, a: () => Json, b: () => Promise<Json>) => {
    const x = await outcome(ts, a);
    await h.settle();
    await settle();
    const y = await outcome(mb, b);
    await p.call("handover", "settle");
    await p.settle();
    await settle();
    assert.deepStrictEqual(y, x, `${label}: the answers differ`);
  };
  await step("start", () => h.start(), () => p.call("handover", "start"));
  await step("handOver refused there", () => h.handOver("s1", B), () => p.call("handover", "handOver", ["s1", B, {}]));
  ts.advance(10_000);
  await p.advance(10_000);
  await step("the drop told again", () => h.settle(), () => p.call("handover", "settle"));
  await step("outs", () => h.outs(), () => p.call("handover", "outs"));
  await step("abandon", () => h.abandon(), () => p.call("handover", "abandon"));
  await h.close();
  await p.call("handover", "close");
  sameTold("failed", ts, mb);
  sameFiles("failed", ts, mb);
  await p.close();
});

test("a chat handed here: begun, its files and rows taken, shown, as the TypeScript takes it", { skip }, async () => {
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  const index = JSON.stringify({ v: 2, dataDir: "/old", sessions: [], gits: [], skipped: [], jobs: [], bundles: {}, files: 2, bytes: 6 });
  const mine = realpathSync(mkdtempSync(join(tmpdir(), "replica-coord-mine-")));
  dirs.push(mine);
  writeFileSync(join(mine, "index.json"), index);
  const own = { index: join(mine, "index.json"), files: 0, bytes: 0, gits: 0, skipped: 0 };
  for (const s of [ts, mb]) {
    s.state = { here: B, home: WS, places: { home: WS, workspaces: [{ workspace: WS, name: "b" }] }, rosters: { [WS]: [{ id: A, name: "a" }, { id: B, name: "b" }] } };
    s.parts = handoverParts(s, own);
    mkdirSync(join(s.data, "sessions", "s1", "workspace"), { recursive: true });
    writeFileSync(join(s.data, "sessions", "s1", "workspace", "here.txt"), "two");
  }
  const h = tsHandover(ts);
  await mbHandover(p, mb);
  const step = async (label: string, a: () => Json, b: () => Promise<Json>) => {
    const x = await outcome(ts, a);
    await h.settle();
    await settle();
    const y = await outcome(mb, b);
    await p.call("handover", "settle");
    await p.settle();
    await settle();
    assert.deepStrictEqual(y, x, `${label}: the answers differ`);
  };
  const id = "lz5x0-7331-aaaaaaaa-01234567";
  const ask = (label: string, request: Json, body?: Buffer) => step(label, () => h.answers(() => true)(A, body === undefined ? { ...request } : withBytes({ ...request }, oneBytes(body))), () => p.call("handover", "answer", [A, request], body));
  await step("start", () => h.start(), () => p.call("handover", "start"));
  const base = { workspace: WS, origin: A, id };
  await ask("not begun", { ...base, method: "handover.rows", table: "sessions", rows: [] });
  await ask("a bad id", { ...base, id: "Bad Id", method: "handover.begin" });
  await ask("begin", { ...base, method: "handover.begin", keys: ["s1"], ws: WS, dataDir: "/old", accounts: { p1: { share: "sh-p1", name: "p1" }, p3: null }, nowhere: ["p3"], connects: { slack1: "slack1@" + A }, described: [{ known: { id: "slack1", origin: A }, station: A, described: { kind: "slack" } }], stoppedFor: null, bindings: { slack1: "s1" } });
  await ask("lacking", { ...base, method: "handover.lacking", hashes: [hex("two"), hex("one")], files: [{ hash: hex("two"), path: "/old/sessions/s1/workspace/here.txt", size: 3, mtimeMs: 1, room: "/old/sessions/s1/workspace" }, { hash: hex("one"), path: "/old/sessions/s1/workspace/one.txt", size: 3, mtimeMs: 1 }] });
  await ask("put", { ...base, method: "handover.put", name: hex("one") }, Buffer.from("one"));
  await ask("put the index", { ...base, method: "handover.put", name: hex(index) }, Buffer.from(index));
  await ask("place", { ...base, method: "handover.place", carry: hex(index), held: false });
  await ask("rows", { ...base, method: "handover.rows", table: "sessions", rows: [{ key: "s1" }], page: "p1" });
  await ask("rows again", { ...base, method: "handover.rows", table: "sessions", rows: [{ key: "s1" }], page: "p1" });
  await ask("rows of entries", { ...base, method: "handover.rows", table: "entries", rows: [{ thread: 7, n: 1 }, { thread: 7, n: 2 }], page: "p2" });
  await ask("rows of no table", { ...base, method: "handover.rows", table: "nothing", rows: [] });
  await ask("prune", { ...base, method: "handover.prune" });
  await ask("counts", { ...base, method: "handover.counts" });
  await ask("held", { ...base, method: "handover.held" });
  await step("comingIn", () => h.comingIn(WS), () => p.call("handover", "comingIn", [WS]));
  await step("comingFrom", () => h.comingFrom("s1"), () => p.call("handover", "comingFrom", ["s1"]));
  await ask("show", { ...base, method: "handover.show", sends: [{ thread: 7, key: "k" }, { thread: 9, key: "other" }] });
  await ask("show again", { ...base, method: "handover.show", sends: [] });
  await ask("rows after it was shown", { ...base, method: "handover.rows", table: "turns", rows: [] });
  await ask("drop once shown", { ...base, method: "handover.drop" });
  await step("arrived", () => h.arrived("s1"), () => p.call("handover", "arrived", ["s1"]));
  const second = { ...base, id: "lz5x1-7331-aaaaaaaa-89abcdef" };
  await ask("begin another", { ...second, method: "handover.begin", keys: ["s2"], ws: WS, dataDir: "/old", accounts: {}, nowhere: [], connects: {}, described: [], stoppedFor: { module: "accounts", id: "p9", label: "P9" }, bindings: {} });
  await ask("drop it", { ...second, method: "handover.drop" });
  await ask("dropped: nothing more taken", { ...second, method: "handover.counts" });
  await ask("begin with a missing account", { ...base, id: "lz5x2-1-aaaaaaaa-00000000", method: "handover.begin", keys: ["s3"], ws: WS, accounts: { p8: { share: "sh-p8", name: "Eight" } }, nowhere: [] });
  await step("ins", () => h.ins(), () => p.call("handover", "ins"));
  await h.close();
  await p.call("handover", "close");
  sameTold("taken here", ts, mb);
  sameFiles("taken here", ts, mb);
  await p.close();
});

test("records of before mended as the station starts, and a disk too full refused, as the TypeScript does", { skip }, async () => {
  const { dir, files } = inputs();
  const g = gathering(dir, files, join(dir, "room"));
  const ts = new Side("ts");
  const mb = new Side("mb");
  const p = new Program(mb);
  await p.init();
  const record = (id: string, keys: string[], step: string) => ({ id, keys, to: B, toName: "b", ws: WS, at: NOW - 5000, step, error: null, jobs: [{ session: keys[0], name: "web", command: "npm start" }], dropOwed: false, sent: {}, counts: { sessions: 1, entries: {}, letters: {}, rows: {} }, there: {}, routes: [], routed: 0, shown: false, done: 0, total: 0, held: true, v: 2 });
  for (const s of [ts, mb]) {
    s.state = { here: A, home: WS, places: { home: WS, workspaces: [{ workspace: WS, name: "a" }] }, rosters: { [WS]: [{ id: A, name: "a" }, { id: B, name: "b" }] } };
    s.parts = handoverParts(s, g, [["s1", { station: B, there: 70 }], ["s2", { station: B, there: 71 }], ["s4", { station: B, there: 72 }]]);
    const out = join(s.data, "replica", "handover", "out");
    mkdirSync(out, { recursive: true });
    // (one said gone whose hand-over failed and is there after all; one gone, dropped there, not there; one cut midway)
    writeFileSync(join(out, "lz5x0-01-bbbbbbbb-00000001.json"), JSON.stringify(record("lz5x0-01-bbbbbbbb-00000001", ["s1"], "failed")));
    writeFileSync(join(out, "lz5x0-02-bbbbbbbb-00000002.json"), JSON.stringify(record("lz5x0-02-bbbbbbbb-00000002", ["s2"], "gone")));
    writeFileSync(join(out, "lz5x0-04-bbbbbbbb-00000004.json"), JSON.stringify({ ...record("lz5x0-04-bbbbbbbb-00000004", ["s4"], "rows"), counts: null }));
    s.peer = async (_station, request) => {
      switch (request.method) {
        case "handover.held": return { value: { held: false } };
        case "move.chats.live": return { value: { live: request.keys.filter((k: string) => k === "s1") } };
        case "handover.drop": return { value: { ok: true } };
        case "handover.begin": return { value: { ok: true, free: 10 * 1024 ** 3, total: 100 * 1024 ** 3, git: true, usage: true } };
        case "handover.lacking": return { value: { lacking: request.hashes, pack: "zstd" } };
      }
      throw new Thrown("Refused", "no such hand-over request");
    };
  }
  const h = tsHandover(ts);
  await mbHandover(p, mb);
  const step = async (label: string, a: () => Json, b: () => Promise<Json>) => {
    const x = await outcome(ts, a);
    await h.settle();
    await settle();
    const y = await outcome(mb, b);
    await p.call("handover", "settle");
    await p.settle();
    await settle();
    assert.deepStrictEqual(y, x, `${label}: the answers differ`);
  };
  await step("start mends", () => h.start(), () => p.call("handover", "start"));
  await step("outs", () => h.outs(), () => p.call("handover", "outs"));
  await step("no room there", () => h.handOver("s1", B), () => p.call("handover", "handOver", ["s1", B, {}]));
  // A disk that fails what it is sent: the chat dropped here, the asker told in numbers.
  for (const s of [ts, mb]) {
    const parts = s.parts;
    s.parts = (name, args) => {
      if (name === "work.place") throw new Error("ENOSPC: no space left on device, write");
      if (name === "room") return { free: 1024 ** 3, total: 2 * 1024 ** 3 };
      return parts(name, args);
    };
  }
  const id = "lz5x9-9-aaaaaaaa-00000009";
  const index = JSON.stringify({ v: 2, dataDir: "/old", sessions: [], gits: [], skipped: [], jobs: [], bundles: {}, files: 0, bytes: 0 });
  const ask = (label: string, request: Json, body?: Buffer) => step(label, () => h.answers(() => true)(B, body === undefined ? { ...request } : withBytes({ ...request }, oneBytes(body))), () => p.call("handover", "answer", [B, request], body));
  const base = { workspace: WS, origin: B, id };
  await ask("begin", { ...base, method: "handover.begin", keys: ["s7"], ws: WS, dataDir: "/old", accounts: {}, nowhere: [], connects: {}, described: [], stoppedFor: null, bindings: {} });
  await ask("put the index", { ...base, method: "handover.put", name: hex(index) }, Buffer.from(index));
  await ask("place: the disk is full", { ...base, method: "handover.place", carry: hex(index) });
  await ask("dropped by itself", { ...base, method: "handover.held" });
  await ask("nothing more taken", { ...base, method: "handover.counts" });
  await h.close();
  await p.call("handover", "close");
  sameTold("mended", ts, mb);
  sameFiles("mended", ts, mb);
  await p.close();
});
