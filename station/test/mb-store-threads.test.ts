// The store of threads in MoonBit (station/mb/src/store_threads, `stillfail-reader-harness --builder harness-store-threads`) against
// the TypeScript store (src/store/store.ts) on twin databases with one clock: each step is played on both, the value
// given back, what was told (StoreChange) and what was asked to be prepared held equal, and the two databases are held
// equal row for row at the end of each scenario and between its parts. The queued card outcomes' consumer
// (card-outbox-worker.ts) is played the same way: its page reads held at a gate, its clock moved by the test.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { MbProcess } from "../src/read/mb-reader.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { cardEditPage, cardMessagePage, cardOutcomeHeads, saveWithCardOutcome, type CardOutcome } from "../src/store/card-outbox.ts";
import { CardOutcomeWorker } from "../src/store/card-outbox-worker.ts";
import { installLegacyEdits } from "../src/store/legacy-edits-build.ts";
import { addClientColumn } from "../src/store/schema.ts";
import { Store, archiveLookOf } from "../src/store/store.ts";
import { installWidgetSources } from "../src/store/widget-sources.ts";
import { settle, testClock } from "./hub-fakes.ts";

const binary = mbHarnessBinary();

type Json = any;
type Hook = { sql: string; args?: unknown[] } | { throw: string } | null | undefined;

/// A value as JSON carries it, with what JSON cannot say said: undefined at the top, a Map as an object, a Set as a list.
function plain(v: unknown, top = true): Json {
  if (v === undefined) return top ? { $undefined: true } : undefined;
  if (typeof v === "bigint") return Number(v);
  if (v instanceof Map) return Object.fromEntries([...v].map(([k, x]) => [String(k), plain(x, false)]));
  if (v instanceof Set) return [...v].map((x) => plain(x, false));
  if (Array.isArray(v)) return v.map((x) => plain(x, false) ?? null);
  if (v instanceof Uint8Array) return [...v];
  if (v !== null && typeof v === "object") {
    return Object.fromEntries(Object.entries(v).filter(([, x]) => x !== undefined).map(([k, x]) => [k, plain(x, false)]));
  }
  return v;
}

/// A guard's random token left out of what is compared.
function untokened(v: Json): Json {
  if (Array.isArray(v)) return v.map(untokened);
  if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, k === "token" && typeof x === "string" ? "<token>" : untokened(x)]));
  return v;
}

function errorOf(e: unknown): Json {
  const error = e as Error & { sessions?: string[] };
  const name = error?.constructor?.name ?? "Error";
  const out: Json = { name: ["MessageWriteBusy", "DecisionSessionsUnavailable", "SessionChatUnavailable", "CcSessionsUnavailable"].includes(name) ? name : "Error", message: error?.message ?? String(e) };
  if (name === "CcSessionsUnavailable") out.sessions = error.sessions;
  return out;
}

function run(db: DatabaseSync, hook: Hook, n?: number): void {
  if (!hook) return;
  if ("throw" in hook) throw new Error(hook.throw);
  db.prepare(hook.sql).run(...((hook.args ?? []).map((a) => (a === "$n" && n !== undefined ? n : a)) as never[]));
}

/// Every table of a database, row by row (sorted), and its schema.
function dump(db: DatabaseSync): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all() as { name: string }[];
  for (const { name } of tables) {
    const rows = db.prepare(`SELECT * FROM "${name.replaceAll('"', '""')}"`).all() as Json[];
    out[name] = rows.map((r) => {
      // (a fresh database's random epoch for the archive's guard is each opener's own)
      if (name === "archive_last_meta") r = { ...r, epoch: "" };
      // (a live guard's token is random on each side)
      if ((name === "card_scan_guard" || name === "restate_guard") && typeof r.token === "string") r = { ...r, token: "<token>" };
      return JSON.stringify(plain(r));
    }).sort();
  }
  out.$schema = (db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").all() as Json[]).map((r) => JSON.stringify(r));
  return out;
}

class Twin {
  readonly dir: string;
  readonly time = testClock();
  readonly ts: Store;
  readonly twin: Store;
  readonly paths: [string, string];
  mb: MbProcess | null = null;
  changes: Json[] = [];
  requested: Json[] = [];
  #id = 0;
  #answers = new Map<number, (v: Json) => void>();
  worker: CardOutcomeWorker | null = null;
  exited = Promise.withResolvers<void>();
  gates = new Map<number, PromiseWithResolvers<void>>();
  held = 0;
  steps = 0;

  constructor() {
    this.dir = mkdtempSync(join(tmpdir(), "mb-store-threads-"));
    this.paths = [join(this.dir, "a", "stillfail.db"), join(this.dir, "b", "stillfail.db")];
    this.ts = Store.open(this.paths[0], join(this.dir, "a", "archive"), this.time.clock);
    this.twin = Store.open(this.paths[1], join(this.dir, "b", "archive"), this.time.clock);
    this.ts.subscribe((c) => this.changes.push(c));
    this.ts.requestLatestThread = (s) => this.requested.push({ latestThread: s });
    this.ts.requestSessionChat = (s) => this.requested.push({ sessionChat: s });
  }

  now(): number { return this.time.clock.currentTimeMillisUnsafe(); }
  async adjust(ms: number): Promise<void> { await this.time.adjust(ms); }

  /// The same setup on both databases (what this package does not write: sessions, turns, raw rows).
  both(f: (s: Store, db: DatabaseSync) => void): void {
    f(this.ts, this.ts.db);
    f(this.twin, this.twin.db);
    this.changes = [];
    this.requested = [];
  }

  session(key: string, extra: Json = {}): void {
    const now = this.now();
    this.both((s) => s.insertSession({ key, connect: "ember", runtime: "claude", profile: "p", workspace: `/w/${key}`, token: `t-${key}`, createdAt: now, lastActiveAt: now, ...extra }));
  }

  /// The MoonBit store on the twin, which reads what it reads once (the old lookups there) as it starts.
  start(): void {
    assert.notEqual(binary, null, "the tests' MoonBit program is built (station/mb/build.sh --harness, or STILLFAIL_MB_HARNESS)");
    this.mb = new MbProcess(binary!, ["--builder", "harness-store-threads", "--db", this.paths[1]]);
    this.mb.on("message", (m: Json) => {
      const answer = this.#answers.get(m.id);
      this.#answers.delete(m.id);
      answer?.(m);
    });
  }

  ask(op: string, args: unknown[], now = this.now()): Promise<Json> {
    const id = ++this.#id;
    return new Promise((resolve) => {
      this.#answers.set(id, resolve);
      this.mb!.postMessage({ id, op, args: plain(args, false), now } as never);
    });
  }

  callTs(op: string, args: Json[]): unknown {
    const s = this.ts as Json;
    const db = this.ts.db;
    switch (op) {
      case "insertMessage": {
        const [m, before, inserted] = args as [Json, Hook, Hook];
        return this.ts.insertMessage(m, before ? () => run(db, before) : undefined, inserted ? (n) => run(db, inserted, n) : undefined);
      }
      case "saveCardOutcome": return this.ts.saveCardOutcome(args[0], () => run(db, args[1]));
      case "restateCard": {
        const spec = args[3] as { merge?: Json; set?: Json };
        return this.ts.restateCard(args[0], args[1], args[2], (was) => (spec.set !== undefined ? spec.set : { ...was, ...spec.merge }));
      }
      case "archiveMarks": {
        const marks = this.ts.archiveMarks();
        return {
          pinned: Object.fromEntries((args[0] as string[]).map((k) => [k, marks.pinned(k)])),
          kept: Object.fromEntries((args[1] as number[]).map((k) => [String(k), marks.kept(k)])),
        };
      }
      case "cardOutcomeHeads": return cardOutcomeHeads(db, args[0], args[1]);
      case "archiveLook": return archiveLookOf(db, args[0].now, args[0].after, args[0].slackAfter);
      case "cardEditPage": return cardEditPage(db, args[0], args[1], args[2] ?? null);
      case "cardMessagePage": return cardMessagePage(db, args[0], args[1], args[2] ?? null);
      default: {
        // (an optional argument the step leaves out is the TypeScript's default: absent, not null)
        while (args.length > 0 && args.at(-1) === undefined) args = args.slice(0, -1);
        return s[op](...args);
      }
    }
  }

  /// One step on both stores: the same answer, the same changes told, the same preparation asked.
  async step(op: string, ...args: Json[]): Promise<Json> {
    return (await this.stepWith(op, args, args)).ours;
  }

  /// The same with arguments of each side's own (a scan's guard holds a random token on each).
  async stepWith(op: string, args: Json[], mbArgs: Json[]): Promise<{ ours: Json; theirs: Json }> {
    this.steps++;
    this.changes = [];
    this.requested = [];
    const now = this.now();
    let ours: Json;
    try { ours = { result: plain(this.callTs(op, args)) }; } catch (e) { ours = { error: errorOf(e) }; }
    ours.changes = JSON.parse(JSON.stringify(plain(this.changes, false)));
    ours.requested = this.requested;
    ours = JSON.parse(JSON.stringify(ours));
    const theirs = await this.ask(op, mbArgs, now);
    const got = { ...(theirs.error !== undefined ? { error: theirs.error } : { result: theirs.result }), changes: theirs.changes, requested: theirs.requested };
    assert.deepEqual(untokened(got), untokened(ours), `${op}(${JSON.stringify(args).slice(0, 400)})`);
    return { ours: ours.result, theirs: theirs.result };
  }

  /// Both databases, row by row.
  same(why: string): void {
    const a = dump(this.ts.db), b = dump(this.twin.db);
    assert.deepEqual(Object.keys(b), Object.keys(a), `${why}: the same tables`);
    for (const k of Object.keys(a)) assert.deepEqual(b[k], a[k], `${why}: table ${k}`);
  }

  // ── the queued outcomes' consumer, on both ──

  startWorker(exited: boolean): Promise<void> {
    const page = <P>(read: (db: DatabaseSync, thread: number, target: string, before: string | null) => P) =>
      async (thread: number, target: string, before: string | null): Promise<P> => {
        const gate = this.gates.get(thread);
        if (gate !== undefined) { this.held++; await gate.promise; this.held--; }
        return read(this.ts.db, thread, target, before);
      };
    this.worker = new CardOutcomeWorker(this.ts, this.exited.promise, page(cardEditPage), page(cardMessagePage));
    if (exited) this.exited.resolve();
    return this.workerStep("worker.start", [exited], () => undefined);
  }

  /// A step of the consumers: what both told meanwhile (each ordering its own scans: as a multiset), and how many page
  /// reads wait at a gate.
  async workerStep(op: string, args: Json[], ours: () => unknown, ms = 0): Promise<void> {
    this.steps++;
    this.changes = [];
    let result: Json;
    try { result = plain(ours()); } catch (e) { result = { error: errorOf(e) }; }
    if (ms > 0) await this.adjust(ms);
    await settle(20);
    const told = (JSON.parse(JSON.stringify(plain(this.changes, false))) as Json[]).map((c) => JSON.stringify(c)).sort();
    const theirs = await this.ask(op, args, this.now());
    const state = (await this.ask("worker.state", [], this.now())).result;
    const got = (theirs.changes as Json[]).map((c) => JSON.stringify(c)).sort();
    assert.deepEqual(got, told, `${op}: the changes told`);
    if (typeof result === "string" || result?.error !== undefined) assert.deepEqual(theirs.error ?? theirs.result, result?.error ?? result, `${op}: its answer`);
    assert.equal(state.held, this.held, `${op}: page reads held at a gate (${JSON.stringify(state)})`);
  }

  hold(thread: number): Promise<void> {
    this.gates.set(thread, Promise.withResolvers<void>());
    return this.workerStep("worker.hold", [thread], () => undefined);
  }

  release(thread: number): Promise<void> {
    const gate = this.gates.get(thread);
    this.gates.delete(thread);
    return this.workerStep("worker.release", [thread], () => { gate?.resolve(); });
  }

  async close(): Promise<void> {
    if (this.mb !== null) {
      if (this.worker !== null) await this.ask("worker.close", []);
      await this.mb.terminate();
    }
    for (const gate of this.gates.values()) gate.resolve();
    this.exited.resolve();
    await this.worker?.close();
    this.ts.close();
    this.twin.close();
    rmSync(this.dir, { recursive: true, force: true });
  }
}

async function twin(f: (t: Twin) => Promise<void>): Promise<void> {
  const t = new Twin();
  try { await f(t); }
  finally { await t.close(); }
}

const msg = (thread: number, ts: string, authorKind: string, author: string, text: string, more: Json = {}) => ({ thread, ts, authorKind, author, text, ...more });

test("threads, who takes part and their lists, as the store keeps them", async () => {
  await twin(async (t) => {
    await t.adjust(1_000);
    t.session("alice-home", { ws: "ws1", createdBy: "Alice@Example.com", title: "Alice's" });
    t.session("bob", { ws: "ws1" });
    t.session("carol", { ws: "ws2" });
    t.session("many");
    t.start();
    const home = await t.step("openThreadOf", "ember", "CHAT", "1.0", null, "alice@example.com", "alice-home");
    await t.step("openThreadOf", "ember", "CHAT", "1.0", "again", null, null);
    const slack = await t.step("openThread", "slack:T1", "C1", "2.0", "a thread", null);
    await t.step("openThread", "feishu:f", "C1", "2.0", null, "x");
    await t.step("threadsAt", "C1", "2.0");
    await t.step("threadAt", "slack:T1", "C1", "2.0");
    await t.step("threadAt", "slack:T1", "C1", "9.9");
    await t.step("getThread", home.id);
    await t.step("getThread", 999);
    for (const [s, th, c] of [["alice-home", home.id, "ember"], ["bob", home.id, "ember"], ["bob", slack.id, "slack1"], ["carol", slack.id, "slack1"]] as const)
      await t.step("joinThread", th, s, c);
    await t.step("joinThread", slack.id, "bob", "slack1");
    await t.adjust(10);
    await t.step("insertMessage", msg(slack.id, "2.1", "person", "U1", "hello from slack"));
    await t.step("insertMessage", msg(home.id, "1.1", "person", "alice@example.com", "first words, which are long enough to be the chat's first text"));
    await t.step("insertMessage", msg(home.id, "1.2", "agent", "bob", "an answer"));
    await t.step("threadOfMessage", "slack:T1", "C1", "2.1");
    await t.step("threadOfMessage", "slack:T1", "C1", "2.0");
    await t.step("threadOfMessage", "slack:T1", "C1", "7.0");
    await t.step("leaveThread", slack.id, "carol");
    await t.step("leaveThread", slack.id, "carol");
    await t.step("leftThread", "carol", "slack1", "C1", "2.0");
    await t.step("leftThread", "bob", "slack1", "C1", "2.0");
    await t.step("joinThread", slack.id, "carol", "slack1");
    await t.step("threadSessions", slack.id);
    await t.step("hasActiveWatch", slack.id);
    await t.step("hasSessionActiveWatch", "bob");
    await t.step("sessionThread", "bob", "C1", "2.0");
    await t.step("sessionThread", "bob", "C9", "2.0");
    await t.step("sessionThreadById", "bob", home.id);
    await t.step("sessionHomeThread", "alice-home");
    await t.step("sessionHomeThread", "bob");
    await t.step("ccThreads", home.id);
    await t.step("sessionThreads", "bob");
    await t.step("sessionThreads", "bob", 1);
    await t.step("recentSessionThreads", "bob");
    await t.step("latestThreadIfReady", "bob");
    await t.step("latestThread", "bob");
    await t.step("latestThread", "nobody");
    await t.step("sessionChat", "bob");
    await t.step("sessionChat", "alice-home");
    await t.step("sessionChat", "nobody");
    // a session in many threads: its recent ones by the indexes, and what is asked to be prepared
    for (let i = 0; i < 24; i++) {
      await t.adjust(1);
      const th = await t.step("openThread", "slack:T1", "C2", `5.${i}`, null, null);
      await t.step("joinThread", th.id, "many", "slack1");
      if (i % 5 === 0) await t.step("insertMessage", msg(th.id, `5.${i}.1`, "person", `U${i}`, `said ${i}`));
    }
    assert.equal((await t.step("recentSessionThreads", "many")).more, true);
    await t.step("recentSessionThreads", "many", 5);
    await t.step("latestThreadIfReady", "many");
    await t.step("latestThread", "many");
    await t.step("sessionChat", "many");
    await t.step("listThreads", "alice@example.com", null, null);
    await t.step("listThreads", "alice@example.com", "bob", null);
    await t.step("listThreads", "U1", null, slack.id);
    await t.step("listThreads", "alice@example.com", null, null, "none");
    await t.step("recentConnectPeople", "slack1", 10);
    await t.step("recentChatList", null, null, 10);
    await t.step("recentChatList", "ws1", "ws1", 3);
    await t.step("recentChatList", "ws2", "ws1", 0);
    await t.step("searchChatList", null, null, 5, "said");
    await t.step("searchChatList", "ws1", null, 5, "first words");
    await t.step("searchChatList", null, null, 0, "x");
    await t.step("firstText", home.id);
    t.same("threads");
  });
});

test("messages recorded with all they carry, edited in long chains, and their entries read", async () => {
  await twin(async (t) => {
    await t.adjust(5_000);
    t.session("agent-a", { ws: "ws1", model: "m1", effort: "high" });
    t.session("agent-b");
    t.start();
    const chat = await t.step("openThreadOf", "ember", "CHAT", "c1", null, "p@x.com", null);
    const slack = await t.step("openThread", "slack:T", "C", "s1", null, null);
    await t.step("joinThread", chat.id, "agent-a", "ember");
    await t.step("joinThread", slack.id, "agent-b", "slack1");
    await t.step("insertMessage", msg(chat.id, "m1", "person", "p@x.com", "plain"));
    await t.step("insertMessage", msg(chat.id, "m1", "person", "p@x.com", "again, the same message"));
    await t.step("insertMessage", msg(chat.id, "m2", "person", "p@x.com", "with files", {
      attachments: [{ path: "/f/a.png", name: "a.png", size: 10, width: 4, height: 3, extra: "dropped" }, { name: "b", path: "/f/b", size: 0, duration: 5, frames: 2 }],
      quotes: [{ author: "q", text: "quoted", comment: "c", ts: "1", role: "agent" }], client: "web", at: 4_000,
    }));
    await t.step("insertMessage", msg(chat.id, "m3", "agent", "agent-a", "a card", { card: { type: "options", options: [{ label: "yes" }, { label: "no", action: "close" }] }, declared: "need_human" }));
    await t.step("insertMessage", msg(chat.id, "m4", "agent", "agent-a", "old options", { options: ["a", "b"], profile: "p", runtime: "codex" }));
    await t.step("insertMessage", msg(chat.id, "m5", "agent", "agent-b", "named", { agentIdentity: { model: "x", effort: null, runtime: "claude" } }));
    await t.step("insertMessage", msg(chat.id, "m6", "ember", "ember", "a run changed", { change: { was: { runtime: "claude" }, now: { runtime: "codex" } } }));
    await t.step("insertMessage", msg(chat.id, "m7", "agent", "agent-b", "来自 another chat", { letter: { way: "in", title: "other", link: null } }));
    await t.step("insertMessage", msg(chat.id, "m8", "person", "p@x.com", "bad file", { attachments: [{ name: "x" }] }));
    // the hooks under the write lock: a statement that goes with it, and one that undoes it
    await t.step("insertMessage", msg(chat.id, "m9", "person", "p@x.com", "hooked"), { sql: "INSERT INTO relayed_to (connect, channel, at) VALUES ('hook', 'before', 1)" }, { sql: "INSERT INTO relayed_to (connect, channel, at) VALUES ('hook', 'n', ?)", args: ["$n"] });
    await t.step("insertMessage", msg(chat.id, "m10", "person", "p@x.com", "refused"), { throw: "not now" });
    await t.step("insertMessage", msg(chat.id, "m11", "person", "p@x.com", "refused after"), undefined, { throw: "too late" });
    // another writer holds the database: a guarded write says so and writes nothing
    const holders = t.paths.map((p) => { const db = new DatabaseSync(p); db.exec("BEGIN IMMEDIATE"); return db; });
    await t.step("insertMessage", msg(chat.id, "m12", "person", "p@x.com", "busy"), { sql: "SELECT 1" });
    for (const h of holders) { h.exec("ROLLBACK"); h.close(); }
    // a message brings its archived session back, not one archived by hand
    t.both((s) => { s.setArchived("agent-b", true, "auto"); s.setArchived("agent-a", true, "manual"); });
    await t.step("insertMessage", msg(slack.id, "s2", "person", "U1", "wakes agent-b"));
    await t.step("insertMessage", msg(chat.id, "m13", "agent", "agent-b", "said by agent-b"));
    // edits, a long chain of them
    for (let i = 0; i < 70; i++) {
      await t.adjust(1);
      await t.step("editMessage", "ember", "CHAT", "c1", "m1", `edit ${i}`);
    }
    await t.step("editMessage", "ember", "CHAT", "c1", "m1", "edit 69");
    await t.step("editMessageIfReady", "ember", "CHAT", "c1", "m1", "edit 70, bounded");
    await t.step("messageAtIfReady", chat.id, "m1");
    await t.step("editMessage", "ember", "CHAT", "c1", "nope", "x");
    await t.step("editMessage", "ember", "CHAT", "zz", "m1", "x");
    await t.step("editMessageIfReady", "ember", "CHAT", "c1", "m2", "files, edited");
    await t.step("editMessageIfReady", "ember", "CHAT", "c1", "m2", "files, edited");
    await t.step("lastMessage", chat.id);
    await t.step("lastMessage", 999);
    await t.step("lastMessageAtForArchive", chat.id);
    await t.step("unreadCount", "p@x.com", chat.id);
    await t.step("unreadCount", "someone", chat.id);
    await t.step("messageCount", chat.id);
    await t.step("unreadForArchive", "p@x.com", chat.id);
    await t.step("setRead", "p@x.com", chat.id, 3);
    await t.step("unreadForArchive", "p@x.com", chat.id);
    await t.step("unreadForArchive", "U1", slack.id);
    const last = await t.step("lastEntry", chat.id);
    await t.step("lastEntry", 999);
    await t.step("entriesAfter", chat.id, last - 3);
    await t.step("entriesBefore", chat.id, null, 4);
    await t.step("entriesBefore", chat.id, 6, 2);
    await t.step("entriesBetween", chat.id, 2, 5);
    await t.step("messagePageEntries", chat.id, [3, 4, 5]);
    await t.step("messagePageEntries", chat.id, [2, 5, 9]);
    await t.step("messagePageEntries", chat.id, []);
    await t.step("messageAt", chat.id, "m1");
    await t.step("messageAtIfReady", chat.id, "m1");
    await t.step("messageAtIfReady", chat.id, "none");
    await t.step("messageNumberAt", chat.id, "m3");
    await t.step("messageNumberAt", chat.id, "none");
    await t.step("cardAt", chat.id, "m3");
    await t.step("cardAt", chat.id, "m4");
    await t.step("cardAt", chat.id, "none");
    await t.step("messagesBefore", chat.id, null, 3);
    await t.step("messagesBefore", chat.id, 5, 10);
    t.same("messages");
  });
});

test("letters, deliveries in and across workspaces, and a viewer's marks", async () => {
  await twin(async (t) => {
    await t.adjust(10_000);
    t.session("s1", { ws: "ws1", createdBy: "Owner@X.com" });
    t.session("s2", { ws: "ws1" });
    t.session("s3", { ws: "ws2" });
    t.session("s4");
    t.start();
    const chat = await t.step("openThreadOf", "ember", "CHAT", "d1", null, null, null);
    const slack = await t.step("openThread", "slack:T", "C", "d2", null, null);
    const other = await t.step("openThread", "slack:T", "C", "d3", null, null);
    for (const [th, s, c] of [[chat.id, "s1", "ember"], [chat.id, "s2", "ember"], [slack.id, "s1", "slack1"], [slack.id, "s2", "slack1"], [other.id, "s3", "slack1"]] as const)
      await t.step("joinThread", th, s, c);
    await t.step("insertLetter", { thread: chat.id, ts: "l1", authorKind: "agent", author: "s9", text: "from far", letter: { way: "in", title: "Far", link: "https://x" } });
    await t.step("insertLetter", { thread: chat.id, ts: "l2", authorKind: "agent", author: "s1", text: "to far", attachments: [{ name: "f", path: "/f", size: 1 }], letter: { way: "out", title: "Far", link: null } });
    await t.step("lastLetter", chat.id);
    await t.step("lastLetter", slack.id);
    await t.adjust(5);
    await t.step("insertMessage", msg(chat.id, "d1.1", "person", "owner@x.com", "hi all"));
    await t.step("deliverLetter", chat.id, 1, ["s1", "s2"]);
    await t.step("deliverLetter", chat.id, 1, ["s1"]);
    await t.step("deliver", chat.id, 1, ["s1", "s2"]);
    await t.step("deliver", chat.id, 1, ["s1", "s2"]);
    // a conversational card in a platform's thread, settled as a person's message is handed over
    await t.step("insertMessage", msg(slack.id, "d2.1", "agent", "s1", "which?", { card: { type: "options", options: [{ label: "a" }] } }));
    await t.step("insertMessage", msg(slack.id, "d2.2", "person", "U7", "a"));
    await t.step("deliver", slack.id, 2, ["s1", "s2", "s4"]);
    // a Router's delivery, kept to its workspace's chat
    await t.step("insertMessage", msg(slack.id, "d2.3", "person", "U7", "more"));
    await t.step("deliver", slack.id, 3, ["s1", "s3"], { expected: "ws1", fallback: null });
    await t.step("deliver", slack.id, 3, ["s1"], { expected: "ws2", fallback: null });
    await t.step("deliver", 999, 1, ["s1"], { expected: "ws1", fallback: null });
    await t.step("deliver", other.id, 1, ["s3"], { expected: "ws2", fallback: "ws9" });
    await t.step("deliveryPending", slack.id, 2, "s1");
    await t.step("deliveryPending", slack.id, 2, "s4");
    t.both((_, db) => {
      db.prepare("INSERT INTO comma_router_once (key, thread, n, at, pending) VALUES ('k1', ?, 3, 1, 1)").run(slack.id);
      db.prepare("INSERT INTO comma_router_once_targets (id, position, session) VALUES (1, 0, 's1')").run();
    });
    await t.step("completeRouterWrite", 1);
    await t.step("completeRouterWrite", 1);
    await t.step("completeRouterWrite", 7);
    await t.step("pendingMessages", "s1");
    await t.step("pendingMessages", "s2");
    await t.step("pendingBefore", "s1", slack.id, 3);
    await t.step("pendingCount", "s1");
    await t.step("hasPending", "s2");
    await t.step("hasPending", "s9");
    await t.step("hasUndelivered", "s1");
    await t.step("markDelivered", "s1", [{ thread: chat.id, n: 1, apart: false }, { thread: chat.id, n: 1, apart: true }]);
    await t.step("markDelivered", "s1", []);
    await t.step("heardThreads", "s1", [chat.id, slack.id, chat.id, 999]);
    await t.step("markUndelivered", "s1", [{ thread: chat.id, n: 1, apart: true }]);
    await t.step("markUndelivered", "s1", []);
    await t.step("sessionsWithPending");
    await t.step("returningSessionsIn", "ws1");
    await t.step("returningSessionsIn", "ws2");
    await t.step("starter", "s1");
    await t.step("starter", "s2");
    await t.step("starter", "nobody");
    await t.step("participants", "s1");
    await t.step("participants", null);
    await t.step("readPosition", "v@x.com", chat.id);
    await t.step("setRead", "v@x.com", chat.id, 2);
    await t.step("setRead", "v@x.com", chat.id, 1);
    await t.step("setChatHidden", "v@x.com", chat.id, true);
    await t.step("setChatHidden", "v@x.com", chat.id, false);
    await t.step("setChatMuted", "V@X.com", chat.id, true);
    await t.step("setChatMuted", "V@X.com", chat.id, false);
    await t.step("setChatMuted", "V@X.com", slack.id, true);
    await t.step("setPin", "v@x.com", "s1", true);
    await t.adjust(3);
    await t.step("setPin", "v@x.com", "s1", true);
    await t.step("setPin", "w@x.com", "s2", true);
    await t.step("setPin", "w@x.com", "s2", false);
    await t.step("pins", "v@x.com");
    await t.step("pinnedSessions");
    await t.step("archiveMarks", ["s1", "s2"], [chat.id, slack.id]);
    await t.step("noteRelayed", "slack1", "C");
    await t.adjust(2);
    await t.step("noteRelayed", "slack1", "C");
    await t.step("noteRelayed", "slack1", "G");
    await t.step("relayedTo", "slack1");
    await t.step("setConnectThreadStation", "slack1", "C", "d2", "st-a");
    await t.step("setConnectThreadStation", "slack1", "C", "d2", "st-b");
    await t.step("connectThreadStation", "slack1", "C", "d2");
    await t.step("connectThreadStation", "slack1", "C", "none");
    await t.step("connectThreads", "slack1");
    await t.step("connectLocalThreads", "slack1");
    await t.step("dropConnectThreads", "slack1");
    await t.step("connectThreads", "slack1");
    await t.step("keepChat", "v@x.com", chat.id);
    await t.step("keepChat", "w@x.com", chat.id);
    await t.step("keepChat", "w@x.com", slack.id);
    await t.step("keptChats", null);
    await t.step("keptChats", "w@x.com");
    await t.step("unkeepChat", "w@x.com", chat.id);
    await t.step("archiveMarks", ["s1"], [chat.id, slack.id]);
    t.same("deliveries");
  });
});

test("the archive's decisions, a workspace's policy as it moves on, and what a review suggests", async () => {
  await twin(async (t) => {
    await t.adjust(100_000);
    t.session("d1", { ws: "ws1" });
    t.session("d2", { ws: "ws1" });
    t.session("d3");
    t.start();
    const chat = await t.step("openThreadOf", "ember", "CHAT", "a1", null, null, "d1");
    await t.step("joinThread", chat.id, "d1", "ember");
    await t.step("decisionsVersion");
    for (const [s, r] of [["d1", { pick: 1, why: "x" }], ["d2", { pick: 2 }], ["d1", { pick: 3, nested: { a: [1, 2] } }], ["d3", null]] as const) {
      await t.adjust(10);
      await t.step("recordDecision", s, r);
    }
    await t.step("decisionsVersion");
    await t.step("recentDecisions");
    await t.step("decisionSessionsReady");
    await t.step("lastDecision", "d1");
    await t.step("lastDecision", "d3");
    await t.step("lastDecision", "none");
    await t.step("latestDecisionsSince", 0);
    await t.step("latestDecisionsSince", 100_015);
    await t.step("latestDecisionsSince", 0, { workspace: "ws1" });
    await t.step("latestDecisionsSince", 0, { workspace: "ws1", home: false });
    await t.step("latestDecisionsSince", 0, { workspace: "ws9", home: false });
    await t.step("archivePolicy");
    await t.step("archivePolicy", "ws1");
    for (const [p, ws] of [[{ idle: 3 }, null], [{ idle: 5, keep: ["x"] }, "ws1"], [{ idle: 7 }, "ws1"], [0, "ws2"]] as const) {
      await t.adjust(1);
      await t.step("setArchivePolicy", p, { by: "owner", device: 1 }, `to ${JSON.stringify(p)}`, ws);
    }
    await t.step("archivePolicy");
    await t.step("archivePolicy", "ws1");
    await t.step("archivePolicy", "ws2");
    await t.step("decisionsVersion");
    await t.step("insertMessage", msg(chat.id, "a1.1", "person", "p", "anything left?"));
    await t.step("setArchiveVerdict", "d1", chat.id, 1, { option: "done", why: ["nothing"] });
    await t.step("setArchiveVerdict", "d1", chat.id, 1, { option: "wait" });
    await t.step("suggestArchive", "d1", chat.id, 1);
    await t.step("archiveSuggested", chat.id);
    await t.step("insertMessage", msg(chat.id, "a1.2", "agent", "d1", "more"));
    await t.step("archiveSuggested", chat.id);
    await t.step("suggestArchive", "d1", chat.id, 2);
    await t.step("archiveSuggested", chat.id);
    await t.step("clearArchiveSuggestion", "d1", chat.id);
    await t.step("clearArchiveSuggestion", "d1", chat.id);
    await t.step("archiveSuggested", chat.id);
    // the session index gone under the store: its lookup falls back to the bounded tail, then waits for preparation
    t.both((_, db) => db.exec("DROP INDEX decision_checks_session"));
    await t.step("lastDecision", "d2");
    await t.step("decisionSessionsReady");
    await t.step("latestDecisionsSince", 0, { workspace: "ws1", home: false });
    await t.step("lastDecision", "none");
    await t.step("archiveLook", { now: t.now(), after: 1, slackAfter: 5 });
    await t.step("archiveLook", { now: t.now(), after: 10_000_000, slackAfter: 0 });
    t.same("decisions");
  });
});

test("cards: what a chat waits on, what ended it, choices that close it, logins and moves told once", async () => {
  await twin(async (t) => {
    await t.adjust(200_000);
    t.session("ag", { ws: "ws1" });
    t.session("ag2", { ws: "ws1" });
    t.session("moved");
    t.start();
    const chat = await t.step("openThreadOf", "ember", "CHAT", "k1", null, null, null);
    const slack = await t.step("openThread", "slack:T", "C", "k2", null, null);
    await t.step("joinThread", chat.id, "ag", "ember");
    await t.step("joinThread", slack.id, "ag2", "slack1");
    const options = { type: "options", options: [{ label: "Keep going" }, { label: " Stop ", action: "close" }] };
    await t.step("pendingCard", chat.id);
    await t.step("insertMessage", msg(chat.id, "k1.1", "agent", "ag", "first question", { card: options }));
    t.both((s) => { s.startTurn("turn-1", "ag", "message"); s.setAbout("turn-1", [chat.id, 1, "k1.1"]); s.endTurn("turn-1", "done", null, "need_human", null); });
    await t.step("pendingCard", chat.id);
    await t.step("pendingCardHeader", chat.id);
    await t.step("pendingCardHeaderIfReady", chat.id);
    await t.step("pendingCardHeaderIfReady", slack.id);
    await t.step("askingMessage", chat.id, null, [0, 300_000]);
    await t.step("insertMessage", msg(chat.id, "k1.2", "agent", "ag", "a newer question", { options: ["x", "y"] }));
    await t.step("cardReplacedBy", chat.id, 2);
    await t.step("cardReplacedBy", chat.id, 1);
    await t.step("insertMessage", msg(chat.id, "k1.3", "person", "p", "x"));
    await t.step("cardEndedByMessage", chat.id, 3);
    await t.step("cardEndedByMessage", chat.id, 2);
    await t.step("pendingCard", chat.id);
    // a system card waits whatever is said, until it is decided or withdrawn
    await t.step("insertMessage", msg(chat.id, "k1.4", "agent", "ag", "a secret", { card: { type: "text", vault: { name: "key" } } }));
    await t.step("insertMessage", msg(chat.id, "k1.5", "person", "p", "one moment"));
    await t.step("pendingCard", chat.id);
    await t.step("cardReplacedBy", chat.id, 4);
    await t.step("withdrawCard", "ag", chat.id, "k1.4");
    await t.step("withdrawCard", "ag", chat.id, "k1.4");
    await t.step("withdrawCard", "ag2", chat.id, "k1.4");
    await t.step("closedCard", chat.id, 4);
    await t.step("pendingCard", chat.id);
    await t.step("cardClosedSince", chat.id, 0);
    // restated on its own post, a long edit chain under it
    for (let i = 0; i < 70; i++) await t.step("editMessage", "ember", "CHAT", "k1", "k1.4", `secret ${i}`);
    await t.step("restateCard", "ag", chat.id, "k1.4", { merge: { vault: { name: "key", outcome: { status: "saved" } } } });
    await t.step("restateCard", "ag", chat.id, "nope", { merge: {} });
    await t.step("restateCard", "ag2", chat.id, "k1.4", { set: { type: "text" } });
    await t.step("messageAt", chat.id, "k1.4");
    await t.step("cardReplacedBy", chat.id, 4);
    await t.step("closedCard", chat.id, 4);
    await t.step("pendingCardHeader", chat.id);
    // a choice that closes the card, said in each language
    await t.step("insertMessage", msg(chat.id, "k1.6", "agent", "ag", "go on?", { card: options }));
    t.both((s) => { s.startTurn("turn-2", "ag", "message"); s.setAbout("turn-2", [chat.id, 77, "k1.6"]); });
    const at = await t.step("messageNumberAt", chat.id, "k1.6");
    t.both((s) => { s.setAbout("turn-2", [chat.id, at, "k1.6"]); s.endTurn("turn-2", "done", null, "need_human", null); });
    await t.step("closeCard", "v@x.com", chat.id, at, "Keep going", "zh");
    await t.step("closeCard", "v@x.com", chat.id, at, "Stop", "en");
    await t.step("closeCard", "v@x.com", chat.id, at, "Stop", "zh");
    await t.step("closeCard", "v@x.com", chat.id, 999, "Stop", "zh");
    await t.step("insertMessage", msg(slack.id, "k2.1", "agent", "ag2", "still in its turn", { card: options }));
    t.both((s) => { s.startTurn("turn-3", "ag2", "message"); s.setAbout("turn-3", [slack.id, 1, "k2.1"]); });
    await t.step("closeCard", "w@x.com", slack.id, 1, "Stop", "zh");
    await t.step("closedCard", chat.id, at);
    await t.step("untoldCardChoices", "ag");
    await t.step("untoldCardChoices", "ag2", 1);
    await t.step("cardChoices", chat.id, [at, 1, 2]);
    await t.step("markCardChoicesTold", "ag", [{ thread: chat.id, n: at }]);
    await t.step("untoldCardChoices", "ag");
    await t.step("dismiss", "v@x.com", chat.id, 1);
    await t.step("dismiss", "v@x.com", chat.id, 1);
    await t.step("dismissed", "v@x.com");
    await t.step("askingMessage", chat.id, at, [0, 0]);
    await t.step("insertMessage", msg(slack.id, "k2.2", "agent", "ag2", "a need without a card"));
    await t.step("askingMessage", slack.id, null, [0, 999_999_999]);
    // a login's cards closed as it ends
    await t.step("insertMessage", msg(slack.id, "k2.3", "agent", "ag2", "sign in", { card: { type: "login", login: "Abc123" } }));
    await t.step("insertMessage", msg(chat.id, "k1.7", "agent", "ag", "sign in too", { card: { type: "login", login: "Abc123" } }));
    await t.step("insertMessage", msg(chat.id, "k1.8", "agent", "ag", "another", { card: { type: "login", login: "other" } }));
    await t.step("closeLoginCards", "Abc123");
    await t.step("closeLoginCards", "Abc123");
    await t.step("closeLoginCards", "nobody");
    // what a moved chat's agent is told once
    await t.step("setMovedNotes", [{ session: "moved", text: "you moved here" }, { session: "ghost", text: "nobody" }]);
    await t.step("setMovedNotes", []);
    await t.step("untoldMovedNote", "moved");
    await t.step("untoldMovedNote", "ghost");
    await t.step("markMovedNoteTold", "moved");
    await t.step("markMovedNoteTold", "moved");
    await t.step("untoldMovedNote", "moved");
    t.same("cards");
  });
});

/// An old card: its post, an edit with a card far back, and many later edits, as card-outbox-worker.test.ts makes one.
function longCard(db: DatabaseSync, thread: number, ts: string): void {
  db.prepare(`INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at,card) VALUES(?,1,'message',?,'agent','a','question',1,?)`)
    .run(thread, ts, JSON.stringify({ type: "text", adb: { reason: "original" } }));
  const edit = db.prepare("INSERT INTO entries(thread,n,kind,target,author_kind,author,text,at,card) VALUES(?,?,'edit',?,'agent','a',?,?,?)");
  edit.run(thread, 2, 1, "old card", 2, JSON.stringify({ type: "text", adb: { reason: "old card" } }));
  for (let n = 3; n <= 82; n++) edit.run(thread, n, 1, `text ${n}`, n, null);
  for (let n = 83; n <= 162; n++) edit.run(thread, n, n + 1000, "other", n, JSON.stringify({ type: "text" }));
}

test("queued card outcomes: saved with their request, restated now or after a guarded scan, a stale scan refused", async () => {
  await twin(async (t) => {
    await t.adjust(300_000);
    t.session("a");
    t.start();
    const chat = await t.step("openThreadOf", "ember", "CHAT", "q1", null, null, null);
    await t.step("joinThread", chat.id, "a", "ember");
    await t.step("insertMessage", msg(chat.id, "card", "agent", "a", "allow the phone?", { card: { type: "text", adb: { reason: "test" } } }));
    const item = { thread: chat.id, ts: "card", agent: "a", field: "adb", close: true, outcome: { status: "granted" } };
    await t.step("saveCardOutcome", item, { sql: "INSERT INTO relayed_to (connect, channel, at) VALUES ('save', 'x', 1)" });
    await t.step("saveCardOutcome", { ...item, field: "rig", close: false, outcome: { status: "denied", n: 2 } }, null);
    await t.step("saveCardOutcome", { ...item, ts: "missing" }, { throw: "the request failed" });
    const heads = await t.step("cardOutcomeHeads", "0", 64);
    await t.step("restateQueuedCard", heads[0]);
    await t.step("restateQueuedCard", heads[0]);
    await t.step("cardOutcomeHeads", "0", 64);
    const next = (await t.step("cardOutcomeHeads", "0", 1))[0];
    const scan = await t.stepWith("beginCardEditScan", [next], [next]);
    await t.step("cardEditPage", chat.id, scan.ours.target, null);
    await t.step("cardMessagePage", chat.id, scan.ours.target, null);
    await t.stepWith("restateQueuedCard", [next, { scan: { ...scan.ours, ts: "other" }, card: null }], [next, { scan: { ...scan.theirs, ts: "other" }, card: null }]);
    await t.stepWith("restateQueuedCard", [next, { scan: scan.ours, card: null, edit: null }], [next, { scan: scan.theirs, card: null, edit: null }]);
    await t.stepWith("endCardEditScan", [scan.ours], [scan.theirs]);
    await t.step("cardOutcomeHeads", "0", 64);
    await t.step("messageAt", chat.id, "card");
    // a queued outcome whose post is gone is discarded
    await t.step("saveCardOutcome", { ...item, ts: "gone" }, null);
    await t.step("restateQueuedCard", (await t.step("cardOutcomeHeads", "0", 64))[0]);
    // an old store whose edits are prepared in bounded steps: the outcome waits for a guarded scan
    let oldThread = 0;
    t.both((s, db) => {
      oldThread = s.openThread("ember", "CHAT", "q-old", null, null).id;
      longCard(db, oldThread, "old");
      db.exec("DROP INDEX entries_edits; DROP INDEX IF EXISTS entries_target");
      installLegacyEdits(db); addClientColumn(db); installWidgetSources(db);
    });
    const old = { thread: oldThread, ts: "old", agent: "a", field: "adb", close: true, outcome: { status: "granted" } };
    await t.step("saveCardOutcome", old, null);
    const queued = (await t.step("cardOutcomeHeads", "0", 64))[0];
    assert.deepEqual(await t.step("messageAtIfReady", old.thread, "old"), { $undefined: true }, "an old message's edits wait for preparation");
    assert.deepEqual(await t.step("editMessageIfReady", "ember", "CHAT", "q-old", "old", "not yet"), { $undefined: true });
    await t.step("cardReplacedBy", old.thread, 1);
    await t.step("pendingCardHeaderIfReady", old.thread);
    assert.deepEqual(await t.step("restateQueuedCard", queued), { $undefined: true }, "an old card waits for a guarded scan");
    const guard = await t.stepWith("beginCardEditScan", [queued], [queued]);
    const message = await t.step("cardMessagePage", queued.thread, guard.ours.target, null);
    const card = await t.step("cardEditPage", queued.thread, guard.ours.target, null);
    // a write to the chat between the pages makes the scan stale
    t.both((_, db) => db.prepare("INSERT INTO entries(thread,n,kind,target,author_kind,author,text,at) VALUES(?,163,'edit',1,'agent','a','concurrent',163)").run(queued.thread));
    const prepared = (scan: Json) => ({ scan, card: card.card ?? null, edit: message.n ?? null });
    await t.stepWith("restateQueuedCard", [queued, prepared(guard.ours)], [queued, prepared(guard.theirs)]);
    const again = await t.stepWith("beginCardEditScan", [queued], [queued]);
    const message2 = await t.step("cardMessagePage", queued.thread, again.ours.target, null);
    const card2 = await t.step("cardEditPage", queued.thread, again.ours.target, null);
    const prepared2 = (scan: Json) => ({ scan, card: card2.card ?? null, edit: message2.n ?? null });
    await t.stepWith("restateQueuedCard", [queued, prepared2(again.ours)], [queued, prepared2(again.theirs)]);
    await t.step("cardOutcomeHeads", "0", 64);
    await t.step("messageAt", queued.thread, "old");
    t.same("outcomes");
  });
});

test("the consumer of queued outcomes: scans at most four old cards at once, waits for handover, retries a busy write", async () => {
  await twin(async (t) => {
    await t.adjust(400_000);
    const threads: number[] = [];
    t.both((s, db) => {
      for (let i = 0; i < 6; i++) {
        const thread = s.openThread("ember", "CHAT", `old-${i}`, null, null).id;
        longCard(db, thread, "card");
        if (s === t.ts) threads.push(thread);
      }
      const short = s.openThread("ember", "CHAT", "short", null, null).id;
      db.prepare(`INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at,card) VALUES(?,1,'message','card','agent','a','short',1,?)`)
        .run(short, JSON.stringify({ type: "text", adb: {} }));
      db.exec("DROP INDEX entries_edits; DROP INDEX IF EXISTS entries_target");
      installLegacyEdits(db); addClientColumn(db); installWidgetSources(db);
    });
    t.start();
    const short = (await t.step("threadAt", "ember", "CHAT", "short")).id;
    for (const thread of threads) await t.hold(thread);
    await t.startWorker(false);
    const item = (thread: number): Omit<CardOutcome, "id"> => ({ thread, ts: "card", agent: "a", field: "adb", close: true, outcome: { status: "granted", thread } });
    for (const thread of threads) await t.workerStep("worker.save", [item(thread), null], () => t.worker!.save(item(thread), () => {}));
    await t.workerStep("worker.save", [item(short), null], () => t.worker!.save(item(short), () => {}));
    t.same("nothing written before the station before exits");
    await t.workerStep("worker.exited", [], () => { t.exited.resolve(); });
    assert.equal(t.held, 4, "four old cards are scanned at once, the others wait");
    t.same("the short card written while the old ones are read");
    for (const thread of threads) await t.release(thread);
    await t.workerStep("worker.run", [], () => undefined, 250);
    await t.workerStep("worker.run", [], () => undefined, 30_000);
    assert.equal((await t.step("cardOutcomeHeads", "0", 64)).length, 0, "every outcome written");
    t.same("every old card restated");
    // a busy write is tried again after 250 ms: an outcome another station left, found while a writer holds the database
    t.both((_, db) => saveWithCardOutcome(db, item(short), () => {}));
    const holders = t.paths.map((p) => { const db = new DatabaseSync(p); db.exec("BEGIN IMMEDIATE"); return db; });
    await t.workerStep("worker.wake", [], () => t.worker!.wake());
    for (const h of holders) { h.exec("ROLLBACK"); h.close(); }
    t.same("nothing written while another writes");
    await t.workerStep("worker.run", [], () => undefined, 249);
    t.same("nor before its retry");
    await t.workerStep("worker.run", [], () => undefined, 1);
    assert.equal((await t.step("cardOutcomeHeads", "0", 64)).length, 0, "written on its retry");
    await t.workerStep("worker.run", [], () => undefined, 30_000);
    t.same("the consumer at rest");
  });
});
