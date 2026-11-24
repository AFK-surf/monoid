// What a station keeps running with nothing asked of it, where the MoonBit program is there: no reader thread at all
// (read/pool.ts: the program answers every read, a card's queued pages too, and one of its readers is kept), and none
// of the programs a search, a live transcript's lookup, the vault's uses and the usage checker start: each goes once
// nothing has been asked of it for its IDLE_MS (fired here by the test) or at once (`trimIdle`, Readers' too), and the
// next ask starts it again and is answered as before. Before (2026-11-15) a station kept three reader threads (~150–200
// MB) and these programs (~300 MB) for good.
import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { mock, test } from "node:test";
import { Effect, Layer } from "effect";
import { wall } from "../src/ops/fibers.ts";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { Search } from "../src/search/search.ts";
import { Previous, Paths, ReaderConfig, Readers as ReadersService, ReadersAndStore } from "../src/services.ts";
import { LiveLocator } from "../src/sessions/live-locator.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { MinuteReader } from "../src/usage/minute-reader.ts";
import { initializePendingIndex } from "../src/vault/pending-index.ts";
import { initializeReboxIndex } from "../src/vault/rebox-index.ts";
import { initializeUseIndex, UseIndex } from "../src/vault/use-index.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program is not built here" : false;
const IDLE_MS = 60_000;

/// Timers of the test's: `fire(ms)` fires those of `ms` armed and not called off; how many it fired.
function timers() {
  const armed: { ms: number; f: () => void; live: boolean }[] = [];
  const waits: { ms: number; resolve: () => void }[] = [];
  return {
    after: (ms: number, f: () => void) => {
      const t = { ms, f, live: true };
      armed.push(t);
      for (const w of waits.filter((w) => w.ms === ms)) { waits.splice(waits.indexOf(w), 1); w.resolve(); }
      return () => { t.live = false; };
    },
    /// Once a timer of `ms` is armed (at once where one is).
    whenArmed: (ms: number) => armed.some((t) => t.live && t.ms === ms) ? Promise.resolve()
      : new Promise<void>((resolve) => waits.push({ ms, resolve })),
    armed: (ms: number) => armed.filter((t) => t.live && t.ms === ms).length,
    fire: (ms: number) => {
      const due = armed.filter((t) => t.live && t.ms === ms);
      for (const t of due) { t.live = false; t.f(); }
      return due.length;
    },
  };
}

/// The programs ended from now on, each awaited by `ended()`.
function ends() {
  const ending: Promise<number>[] = [];
  const original = MbProcess.prototype.terminate;
  const terminate = mock.method(MbProcess.prototype, "terminate", function (this: MbProcess) {
    const p = original.call(this);
    ending.push(p);
    return p;
  });
  return { ended: () => Promise.all(ending.splice(0)), restore: () => terminate.mock.restore() };
}

/// How many of the station's programs run with `arg` among their arguments.
const running = (arg: string) => MbProcess.live().filter((p) => p.args.includes(arg)).length;

/// The reader threads and readers of each line (read/pool.ts, its private lines).
const lines = (readers: Readers) => {
  const r = readers as unknown as Record<"asked" | "told" | "pages" | "log" | "moved", { slots: { worker: unknown }[] }>;
  return { asked: r.asked.slots.length, told: r.told.slots.length, pages: r.pages.slots.length, log: r.log.slots.length, moved: r.moved.slots.length, slots: r.moved.slots };
};

test("with the MoonBit program no reader thread is started: warmed, read, a card's pages and the log checkpointed; one reader kept", { skip }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-idle-readers-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const t = timers();
  // (only IDLE_MS the test's: a background read's rest, as long as it took, is the wall's as it is)
  const wallAfter = wall.after;
  const after = mock.method(wall, "after", (ms: number, f: () => void) => ms === IDLE_MS ? t.after(ms, f) : wallAfter(ms, f));
  const e = ends();
  const readers = new Readers(data, 2);
  try {
    const thread = store.openThread("ember", "CHAT", "c", "c", null).id;
    store.insertMessage({ ...newMessage(thread, "1", "person", "a@x", "hello"), at: 10 } as ReturnType<typeof newMessage>);
    assert.ok(readers.mbReader !== null);
    readers.warm();
    assert.deepEqual({ ...lines(readers), slots: undefined }, { asked: 0, told: 0, pages: 0, log: 0, moved: 1, slots: undefined });
    // Two at once: a second reader of the program beside the first.
    // (two a person waits on: what is in bulk leaves the second reader to them)
    const [list, again] = await Promise.all([readers.read("latestMessages", { thread, limit: 5 }, "en"), readers.read("latestMessages", { thread, limit: 5 }, "en")]);
    assert.ok(list.includes("hello"), list);
    assert.equal(again, list);
    assert.deepEqual(await readers.cardMessagePage(thread, "1", null), { kind: "end" });
    assert.deepEqual(await readers.cardEditPage(thread, "1", null), { kind: "end" });
    assert.ok(await readers.checkpointHard());
    const seen = lines(readers);
    assert.equal(seen.asked + seen.told, 0, "no reader thread");
    assert.equal(seen.moved, 2);
    // Idle: the second reader goes, the first is kept.
    const [first] = seen.slots;
    t.fire(IDLE_MS);
    await e.ended();
    assert.equal(lines(readers).moved, 1);
    assert.equal(lines(readers).slots[0], first);
    assert.equal(lines(readers).log, 0, "the checkpoint's reader went too");
    // Short of memory: the kept one goes as well, and the next read starts one again.
    assert.ok(readers.trimIdle() >= 1);
    await e.ended();
    assert.equal(lines(readers).moved, 0);
    assert.equal(running(`--data`), 0);
    assert.deepEqual(await readers.cardEditPage(thread, "1", null), { kind: "end" });
    assert.equal(lines(readers).moved, 1);
    assert.equal(lines(readers).asked + lines(readers).told, 0);
  } finally {
    readers.close(); store.close(); e.restore(); after.mock.restore();
    rmSync(data, { recursive: true, force: true });
  }
});

test("the station's readers start no usage checker: made and warmed, it waits for a read that finds the statistics incomplete", { skip }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-idle-usage-check-"));
  try {
    const paths = Layer.succeed(Paths)({ data, app: data });
    await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
      const readers = yield* ReadersService;
      assert.equal((readers as unknown as { minutes: MinuteReader | null }).minutes, null, "no checker made");
      assert.equal(running("usage-check"), 0, "no checker's program");
    })).pipe(Effect.provide(ReadersAndStore.pipe(Layer.provide(Layer.succeed(ReaderConfig)(() => undefined)), Layer.provide(Layer.succeed(Previous)({ pid: null, gone: Promise.resolve(), exited: Promise.resolve() })), Layer.provide(paths)))));
  } finally {
    rmSync(data, { recursive: true, force: true });
  }
});

test("Readers.trimIdle lets go of what onTrim gave, past one that fails", { skip }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-idle-trim-"));
  const store = Store.open(join(data, "stillfail.db"));
  const readers = new Readers(data, 1);
  try {
    let asked = 0;
    readers.onTrim(() => { asked++; return 2; });
    readers.onTrim(() => { throw new Error("broken"); });
    assert.equal(readers.trimIdle(), 2);
    assert.equal(asked, 1);
  } finally { readers.close(); store.close(); rmSync(data, { recursive: true, force: true }); }
});

test("a search starts its program when asked, lets it go when idle or trimmed, and starts it again for the next", { skip }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-idle-search-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const t = timers();
  const e = ends();
  const search = new Search({ data, after: t.after });
  try {
    store.insertSession({ key: "s", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w/s", token: "s", createdAt: 1, lastActiveAt: 1, ws: "W" } as Parameters<Store["insertSession"]>[0]);
    const thread = store.openThreadOf("ember", "ember", "s", null, "a@x", "s").id;
    store.joinThread(thread, "s", "ember");
    store.insertMessage({ ...newMessage(thread, "1", "person", "a@x", "deploy the kelvin build") } as ReturnType<typeof newMessage>);
    const asker = { workspace: "W", home: true, scopes: ["write"] };
    const found = async () => (await search.query("kelvin", asker, { kinds: ["message"] })).groups.flatMap((g) => g.hits.map((h) => h.text));
    search.start();
    assert.equal(search.running, false, "nothing started with the station");
    assert.equal(running("search"), 0);
    const first = await found();
    assert.ok(first.some((text) => text.includes("kelvin")), JSON.stringify(first));
    assert.equal(search.running, true);
    assert.equal(t.armed(IDLE_MS), 1);
    t.fire(IDLE_MS);
    assert.equal(search.running, false);
    await e.ended();
    assert.equal(running("search"), 0);
    assert.deepEqual(await found(), first, "started again, it finds the same");
    assert.equal(search.trimIdle(), 1);
    assert.equal(search.trimIdle(), 0, "nothing left to let go");
    await e.ended();
    assert.deepEqual(await found(), first);
    // A search under way is never let go.
    const under = search.query("kelvin", asker, { kinds: ["message"] });
    assert.equal(search.trimIdle(), 0);
    await under;
  } finally {
    await search.stop(); store.close(); e.restore();
    rmSync(data, { recursive: true, force: true });
  }
});

test("the live locator's program goes when trimmed and comes back for the next lookup", { skip }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-idle-locator-"));
  const store = Store.open(join(data, "stillfail.db"));
  const e = ends();
  const locator = new LiveLocator(data, (key) => store.getSession(key), () => [{ id: "own", home: join(data, "home") }]);
  try {
    store.insertSession({ key: "k", connect: "ember", runtime: "claude", profile: "own", workspace: join(data, "w"), token: "t", createdAt: 1, lastActiveAt: 1, ws: "mine" });
    assert.equal(locator.running, false);
    assert.equal(await locator.locate("k"), null);
    assert.equal(locator.running, true);
    assert.equal(locator.trimIdle(), 1);
    assert.equal(locator.running, false);
    await e.ended();
    assert.equal(running("live-locator"), 0);
    assert.equal(await locator.locate("k"), null);
    assert.equal(locator.running, true);
  } finally {
    await locator.close(); store.close(); e.restore();
    rmSync(data, { recursive: true, force: true });
  }
});

test("the vault's use reader goes once its background is done and idle, and reads again from where the database says", { skip }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "mb-idle-uses-"));
  const path = join(dir, "stillfail.db");
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA journal_mode = WAL; CREATE TABLE vault_requests (ws TEXT NOT NULL, id TEXT NOT NULL, session TEXT NOT NULL,
    status TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY (ws,id));`);
  const put = db.prepare("INSERT INTO vault_requests VALUES(?,?,'s',?,?)");
  for (let i = 0; i < 40; i++) put.run("w", `r${String(i).padStart(3, "0")}`, "granted", `{"item":"i${i}","session":"s","status":"granted","vault":"v","at":${i}}`);
  initializeUseIndex(db); initializePendingIndex(db); initializeReboxIndex(db);
  const t = timers();
  const e = ends();
  const uses = new UseIndex(db, { after: t.after });
  try {
    const first = await uses.read("w", "v", null, 5);
    assert.equal(first.length, 5);
    // Its background goes on after the read; once done and nothing is asked, it is let go after IDLE_MS.
    await t.whenArmed(IDLE_MS);
    assert.equal(uses.running, true);
    t.fire(IDLE_MS);
    assert.equal(uses.running, false);
    await e.ended();
    assert.equal(running("vault-uses"), 0);
    // The next read starts it again, the same page; let go at once, then read again.
    assert.deepEqual(await uses.read("w", "v", null, 5), first);
    assert.equal(uses.running, true);
    await t.whenArmed(IDLE_MS);
    assert.equal(uses.trimIdle(), 1);
    assert.equal(uses.running, false);
    await e.ended();
    assert.deepEqual(await uses.read("w", "v", null, 5), first);
  } finally {
    await uses.close(); db.close(); e.restore();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the usage checker goes when idle or trimmed, what it found kept, and answers again when asked", { skip }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "mb-idle-minutes-"));
  const path = join(dir, "stillfail.db");
  let store = Store.open(path);
  // As on a station whose chat statistics were never filled: never complete, so the checker would stay.
  for (const [key, ws] of [["a", "workspace-a"], ["b", "workspace-b"]] as const) {
    store.insertSession({ key, ws, connect: key, runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, createdAt: 1, lastActiveAt: 1 });
  }
  store.db.exec("UPDATE usage_chat_progress SET done = 0");
  const midnight = Date.UTC(2026, 0, 2);
  const call = (id: string, at: number) => ({ id, at, model: "m", subagent: true, fast: false, input: 1, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 0, calls: 1, context: null, window: null });
  const of = { turn: null, person: null, thread: null, profile: null };
  store.recordUsage("/a.jsonl", { session: "a", offset: 1, model: "m" }, "claude", [[call("a1", midnight - 30_000), of]]);
  store.recordUsage("/b.jsonl", { session: "b", offset: 1, model: "m" }, "claude", Array.from({ length: 50 }, (_, n) => [call(`b${n}`, midnight - 1_000_000), of]) as never);
  store.close();
  store = Store.open(path);
  const t = timers();
  const e = ends();
  const reader = new MinuteReader(path, { after: t.after }, binary!);
  const viewer = { workspace: "workspace-a", home: false };
  try {
    await assert.rejects(reader.readyChats(viewer), /chat.*unavailable/);
    assert.equal(reader.running, true);
    assert.equal(t.armed(IDLE_MS), 1, "nothing asked: it goes after IDLE_MS");
    t.fire(IDLE_MS);
    assert.equal(reader.running, false);
    await e.ended();
    assert.equal(running("usage-check"), 0);
    await assert.rejects(reader.readyChats(viewer), /chat.*unavailable/, "started again, the same answer");
    assert.equal(reader.running, true);
    assert.equal(reader.trimIdle(), 1);
    assert.equal(reader.trimIdle(), 0);
    await e.ended();
    await assert.rejects(reader.readyChats(viewer), /chat.*unavailable/);
    // An ask under way is never let go.
    const under = reader.readyChats(viewer).catch(() => {});
    assert.equal(reader.trimIdle(), 0);
    await under;
  } finally {
    await reader.close(); store.close(); e.restore();
    rmSync(dir, { recursive: true, force: true });
  }
});
