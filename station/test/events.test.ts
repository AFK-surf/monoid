// GET /events: what is written told as it is written (each device makes its sidebar and a thread's summary itself),
// one `session` event per burst, the shared chat list by what changed, `read` only to its viewer, job logs as they grow; and each event with its id (the station's run, its number), what was told
// told again to a stream that takes over from another or comes back after its link went (`since`).
import type { Clock } from "effect";
import assert from "node:assert/strict";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mock, test } from "node:test";
import { changedKeysFromMemos, Events, type EventsDeps, OVERVIEW_VIEWER_BATCH, overviewChangedKeys, overviewComparable, overviewComparableMemo, serializeRawOverview } from "../src/api/events.ts";
import { log } from "../src/ops/log.ts";
import { KEPT_MS } from "../src/api/event-log.ts";
import type { StoreChange } from "../src/store/rows.ts";
import { given, settle, testClock } from "./hub-fakes.ts";

const viewer = (email: string) => ({ sub: email, email, name: email, role: "member", workspace: "w", device: "d" });

/// A station process's events. `handover`: what goes over to the next process; `db`: the rows and overview of another's
/// (the same station's, in the next process).
function setup(clock?: Clock.Clock, handover?: EventsDeps["handover"], db?: { rows: Record<string, any[]>; overview: { running: number } }, host: EventsDeps["host"] = async () => ({ cpu: 1 })) {
  let listener: (c: StoreChange) => void = () => {};
  const rows: Record<string, any[]> = db?.rows ?? { "a@x": [{ id: "1", title: "one" }], "b@x": [] };
  const overview = db?.overview ?? { running: 0 };
  const reads: string[] = [];
  const readers: any = {
    read: async (op: string, args: any) => {
      reads.push(op);
      if (op === "summary") return JSON.stringify({ key: args.key });
      // The shared chat list (read/views.ts sharedOf): here a@x's rows.
      if (op === "sharedOf") {
        const all = rows["a@x"] ?? [];
        return JSON.stringify({ rows: all, scope: args.sessions === null ? null : [...args.sessions, ...all.map((r) => r.id)] });
      }
      throw new Error(op);
    },
  };
  const dir = mkdtempSync(join(tmpdir(), "events-"));
  const events = new Events({
    readers,
    // What is said is told as the store wrote it, never read first (no `entries` read here).
    said: (_thread, entries) => entries.map((e) => ({ n: e.n, text: "hi" })),
    subscribe: (l) => ((listener = l), () => {}),
    host,
    jobLog: (id) => (id === "j" ? join(dir, "j.log") : null),
    logNow: async (id) => (id === "j" ? { text: require("node:fs").readFileSync(join(dir, "j.log"), "utf8"), outputAt: 7 } : null),
    sessionExists: (key) => key !== "gone",
    clock,
    handover,
  });
  events.follow({ overview: async () => ({ ...overview }) });
  return { events, rows, reads, readers, overview, change: (c: StoreChange) => listener(c), dir };
}

/// Reads a stream's events as they come.
function reader(body: AsyncIterable<Buffer>) {
  const it = body[Symbol.asyncIterator]();
  const got: { id?: string; event?: string; data?: any; raw: string }[] = [];
  let pump: Promise<void> | null = null;
  const more = () =>
    (pump ??= (async () => {
      for (;;) {
        const next = await it.next();
        if (next.done) return;
        const raw = next.value.toString();
        const m = /^(?:id: ([0-9a-f]+\.\d+)\n)?event: (.+)\ndata: (.*)\n\n$/.exec(raw);
        // `made`, said first to every stream (it makes its rows itself), is kept as it came alone.
        got.push(m && m[2] !== "made" ? { id: m[1], event: m[2], data: JSON.parse(m[3]!), raw } : { raw });
      }
    })());
  more();
  return { got, close: () => it.return?.() };
}
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);

/// The process before, as the next one finds it (run/hub.json): the one that handed over (every one of a test is this
/// process), gone once `gone` is.
const previous = (gone: Promise<void> = Promise.resolve()) => ({ pid: process.pid, gone });

/// Opens a@x's stream from `since`: whether it was resumed, and what it is told.
async function opened(events: Events, since: string | null = null) {
  const answer = await events.open(viewer("a@x"), "zh", false, [], [], since);
  return { resumed: (answer.headers as Record<string, string>)["stillfail-resumed"] === "1", ...reader(answer.body as AsyncIterable<Buffer>) };
}

test("the first change can remove a shared chat", async () => {
  const { events, rows, change } = setup(testClock().clock);
  rows["a@x"] = [{ id: "1", title: "one", ws: "w" }];
  const stream = await opened(events);
  rows["a@x"] = [];
  change({ type: "threadRemoved", id: 1, ws: "w" });
  await settle();
  assert.ok(stream.got.some((e) => e.event === "chat-shared-removed" && e.data.id === "1"));
  await stream.close();
});

test("shared changes are kept while another stream follows", async () => {
  const { events, rows, change } = setup(testClock().clock);
  rows["a@x"] = [{ id: "1", title: "one", ws: "w" }];
  const other = await opened(events);
  const shared = await opened(events);
  change({ type: "session", key: "1" });
  await settle();
  const heard = shared.got.findLast((e) => e.id)!.id!;
  await shared.close();
  rows["a@x"] = [...rows["a@x"]!, { id: "2", title: "new", ws: "w" }];
  change({ type: "session", key: "2" });
  await settle();
  const back = await opened(events, heard);
  await settle();
  assert.equal(back.resumed, true);
  assert.ok(back.got.some((e) => e.event === "chat-shared" && e.data.id === "2"));
  await back.close();
  await other.close();
});

test("a shared chat moving between workspaces is removed from the old one, including on replay", async () => {
  const { events, rows, change } = setup(testClock().clock);
  rows["a@x"] = [{ id: "1", title: "one", ws: "w" }];
  const from = await opened(events);
  const answer = await events.open({ ...viewer("b@x"), workspace: "other", home: false }, "zh", false, [], [], null);
  const to = reader(answer.body as AsyncIterable<Buffer>);
  change({ type: "session", key: "1" });
  await settle();
  const heard = from.got.findLast((e) => e.id)!.id!;
  await from.close();
  rows["a@x"] = [{ id: "1", title: "one", ws: "other" }];
  change({ type: "session", key: "1" });
  await settle();
  const back = await opened(events, heard);
  await settle();
  assert.equal(back.resumed, true);
  assert.ok(back.got.some((e) => e.event === "chat-shared-removed" && e.data.id === "1"));
  assert.ok(to.got.some((e) => e.event === "chat-shared" && e.data.id === "1"));
  await back.close();
  await to.close();
});

test("changes while the first shared list is read are included in its baseline", async () => {
  const { events, rows, readers, change } = setup(testClock().clock);
  rows["a@x"] = [{ id: "1", title: "old", ws: "w" }];
  const read = readers.read;
  let finish: (() => void) | undefined;
  readers.read = async (op: string, args: unknown) => {
    if (op !== "sharedOf" || finish) return read(op, args);
    const captured = await read(op, args);
    return new Promise<string>((resolve) => { finish = () => resolve(captured); });
  };
  const opening = opened(events);
  await settle();
  assert.ok(finish);
  rows["a@x"] = [{ id: "1", title: "new", ws: "w" }];
  change({ type: "session", key: "1" });
  await settle();
  finish();
  const stream = await opening;
  await settle();
  rows["a@x"] = [{ id: "1", title: "old", ws: "w" }];
  change({ type: "session", key: "1" });
  await settle();
  assert.ok(stream.got.some((e) => e.event === "chat-shared" && e.data.title === "old"));
  await stream.close();
});

test("an old handover without a shared baseline cannot resume a shared stream", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const before = setup(time.clock, { file, previous: previous() });
  const lost = await opened(before.events);
  before.change({ type: "session", key: "1" });
  await settle();
  const heard = lost.got.findLast((e) => e.id)!.id!;
  await before.events.handOver();
  const handed = JSON.parse(readFileSync(file, "utf8"));
  delete handed.shared;
  writeFileSync(file, JSON.stringify(handed));
  const after = setup(time.clock, { file, previous: previous() }, before);
  const back = await opened(after.events, heard);
  await settle();
  assert.equal(back.resumed, false);
  assert.ok(back.got.some((e) => e.event === "missed"));
  await lost.close();
  await back.close();
});

test("a failed shared update ends its stream and prevents resuming across the missing change", async () => {
  const { events, rows, readers, change } = setup(testClock().clock);
  rows["a@x"] = [{ id: "1", title: "one", ws: "w" }];
  const stream = await opened(events);
  change({ type: "session", key: "1" });
  await settle();
  const heard = stream.got.findLast((e) => e.id)!.id!;
  const read = readers.read;
  let fail = true;
  readers.read = (op: string, args: unknown) => {
    if (op === "sharedOf" && fail) { fail = false; return Promise.reject(new Error("reader failed")); }
    return read(op, args);
  };
  rows["a@x"] = [...rows["a@x"]!, { id: "2", title: "new", ws: "w" }];
  change({ type: "session", key: "2" });
  await settle();
  assert.equal(events.inUse(), false);
  const back = await opened(events, heard);
  await settle();
  assert.equal(back.resumed, false);
  assert.ok(back.got.some((e) => e.event === "missed"));
  await back.close();
});

test("several shared streams read the initial list only once", async () => {
  const { events, reads } = setup(testClock().clock);
  const [first, second] = await Promise.all([opened(events), opened(events)]);
  assert.equal(reads.filter((op) => op === "sharedOf").length, 1);
  await first.close();
  await second.close();
});

test("the first change after a shared stream opens tells its chat", async () => {
  const { events, rows, change } = setup(testClock().clock);
  rows["a@x"] = [{ id: "1", title: "one", ws: "w" }];
  const stream = await opened(events);
  await settle();
  rows["a@x"] = [...rows["a@x"]!, { id: "2", title: "new", ws: "w" }];
  change({ type: "session", key: "2" });
  await settle();
  assert.ok(stream.got.some((e) => e.event === "chat-shared" && e.data.id === "2"));
  await stream.close();
});

test("a shared stream coming back is told a chat created while nobody followed", async () => {
  const { events, rows, change } = setup(testClock().clock);
  rows["a@x"] = [{ id: "1", title: "one", ws: "w" }];
  const lost = await opened(events);
  change({ type: "session", key: "1" });
  await settle();
  const heard = lost.got.findLast((e) => e.id)!.id!;
  await lost.close();
  rows["a@x"] = [...rows["a@x"]!, { id: "2", title: "new", ws: "w" }];
  change({ type: "session", key: "2" });
  await settle();
  const back = await opened(events, heard);
  await settle();
  assert.equal(back.resumed, true);
  assert.ok(back.got.some((e) => e.event === "chat-shared" && e.data.id === "2"));
  await back.close();
});

test("a stream coming back says where the log was as it joined: what it tells up to there is told again, after it as it happens", async () => {
  const { events, rows, change } = setup(testClock().clock);
  rows["a@x"] = [{ id: "1", title: "one", ws: "w" }];
  const lost = await opened(events);
  change({ type: "session", key: "1" });
  await settle();
  const heard = lost.got.findLast((e) => e.id)!.id!;
  await lost.close();
  rows["a@x"] = [...rows["a@x"]!, { id: "2", title: "new", ws: "w" }];
  change({ type: "session", key: "2" });
  await settle();
  const answer = await events.open(viewer("a@x"), "zh", false, [], [], heard);
  const back = reader(answer.body as AsyncIterable<Buffer>);
  const head = (answer.headers as Record<string, string>)["stillfail-head"]!;
  await settle();
  const n = (id: string) => Number(id.split(".")[1]);
  const told = (id: string) => back.got.find((e) => e.event === "chat-shared" && e.data.id === id && e.id);
  assert.ok(told("2") && n(told("2")!.id!) <= n(head), `${head} ${told("2")?.id}`);
  rows["a@x"] = [...rows["a@x"]!, { id: "3", title: "later", ws: "w" }];
  change({ type: "session", key: "3" });
  await settle();
  assert.ok(told("3") && n(told("3")!.id!) > n(head), `${head} ${told("3")?.id}`);
  // Not resumed: none said.
  const answered = await events.open(viewer("a@x"), "zh", false, [], [], null);
  assert.equal((answered.headers as Record<string, string>)["stillfail-head"], undefined);
  const fresh = reader(answered.body as AsyncIterable<Buffer>);
  await fresh.close();
  await back.close();
});

test("a shared stream coming back after station handover is told a chat created while away", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const before = setup(time.clock, { file, previous: previous() });
  before.rows["a@x"] = [{ id: "1", title: "one", ws: "w" }];
  const lost = await opened(before.events);
  before.change({ type: "session", key: "1" });
  await settle();
  const heard = lost.got.findLast((e) => e.id)!.id!;
  await lost.close();
  await before.events.handOver();
  const after = setup(time.clock, { file, previous: previous() }, before);
  await settle();
  after.rows["a@x"] = [...after.rows["a@x"]!, { id: "2", title: "new", ws: "w" }];
  after.change({ type: "session", key: "2" });
  await settle();
  const back = await opened(after.events, heard);
  await settle();
  assert.equal(back.resumed, true);
  assert.ok(back.got.some((e) => e.event === "chat-shared" && e.data.id === "2"));
  await back.close();
});

test("changes are told as events, read only to its viewer, shared chat list once for everyone", async () => {
  const { events, rows, change, reads } = setup(testClock().clock);
  const a = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  const b = reader((await events.open(viewer("b@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  await settle();
  assert.equal(a.got[0]!.raw, "retry: 3000\n\n");
  assert.equal(a.got[1]!.raw, `event: made\ndata: ${JSON.stringify({ rows: true, marks: true, shared: true })}\n\n`, "told first it makes its rows from the shared list");
  rows["a@x"] = [{ id: "1", title: "one" }, { id: "2", title: "two" }];
  reads.length = 0;
  // A burst: one `session` event and one shared chat list read for everyone.
  change({ type: "session", key: "s" });
  change({ type: "session", key: "s" });
  change({ type: "session", key: "gone" });
  change({ type: "read", viewer: "b@x", thread: 3, n: 9 });
  await settle();
  const ofA = a.got.filter((e) => e.event).map((e) => [e.event, e.data]);
  assert.deepEqual(ofA, [["session", { key: "s" }], ["chat-shared", { id: "2", title: "two" }]]);
  const ofB = b.got.filter((e) => e.event).map((e) => [e.event, e.data]);
  assert.deepEqual(ofB, [["read", { viewer: "b@x", thread: 3, n: 9 }], ["session", { key: "s" }], ["chat-shared", { id: "2", title: "two" }]]);
  assert.deepEqual(reads, ["summary", "sharedOf"]);
  // Ids go up on each stream, of one run of the station; what is told to everyone has one id on all streams.
  const numbers = (got: { id?: string }[]) => got.filter((e) => e.id).map((e) => Number(e.id!.split(".")[1]));
  for (const got of [a.got, b.got]) assert.deepEqual(numbers(got), [...numbers(got)].sort((x, y) => x - y));
  assert.equal(new Set([...a.got, ...b.got].filter((e) => e.id).map((e) => e.id!.split(".")[0])).size, 1);
  const sessionIds = [a, b].map((s) => s.got.find((e) => e.event === "session")!.id);
  assert.equal(sessionIds[0], sessionIds[1]);
  rows["a@x"] = [{ id: "2", title: "two" }];
  change({ type: "threadRemoved", id: 1 });
  await settle();
  assert.deepEqual(a.got.slice(-2).map((e) => [e.event, e.data]), [["thread-removed", { id: 1 }], ["chat-shared-removed", { id: "1" }]]);
  change({ type: "thread", id: 4, entries: [{ n: 1 } as any] });
  await settle();
  assert.deepEqual(b.got.filter((e) => e.event === "thread").map((e) => e.data), [{ id: 4, entries: [{ n: 1, text: "hi" }] }]);
  await a.close();
  await b.close();
  assert.equal(events.inUse(), false);
});

test("what a viewer marks is told as written to their streams alone", async () => {
  const { events, change } = setup(testClock().clock);
  const a = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  const b = reader((await events.open(viewer("b@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  await settle();
  change({ type: "pins", viewer: "a@x", session: "s", at: 5 });
  change({ type: "dismissed", viewer: "a@x", card: { thread: 3, n: 7 } });
  change({ type: "dismissed", viewer: "a@x", kept: { thread: 3, kept: false } });
  change({ type: "hidden", viewer: "a@x", thread: 3, hidden: true });
  change({ type: "muted", viewer: "a@x", thread: 3, muted: true });
  await settle();
  const told = (got: { event?: string; data?: any }[]) => got.filter((e) => e.event === "pin" || e.event === "dismiss" || e.event === "kept" || e.event === "hidden" || e.event === "muted").map((e) => [e.event, e.data]);
  assert.deepEqual(told(a.got), [["pin", { session: "s", at: 5 }], ["dismiss", { thread: 3, n: 7 }], ["kept", { thread: 3, kept: false }], ["hidden", { thread: 3, hidden: true }], ["muted", { thread: 3, muted: true }]]);
  assert.deepEqual(told(b.got), []);
  // What is written of a chat beside what is said in it, to those who see it.
  change({ type: "chatMark", thread: 3, session: "s", archive: { suggested: 4 } });
  await settle();
  assert.deepEqual(a.got.filter((e) => e.event === "chat-mark").map((e) => e.data), [{ thread: 3, session: "s", archive: { suggested: 4 } }]);
  await a.close();
  await b.close();
});

test("a stream that takes over is told first what was told to everyone after the last id its predecessor gave", async () => {
  const time = testClock();
  const { events, change } = setup(time.clock);
  const old = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  change({ type: "session", key: "s1" });
  await settle();
  const heard = old.got.find((e) => e.event === "session")!.id!;
  // Told while the new stream is asked for (it is not the station's yet): only the old one has them.
  change({ type: "thread", id: 4, entries: [{ n: 1 } as any] });
  change({ type: "read", viewer: "b@x", thread: 3, n: 9 });
  change({ type: "read", viewer: "a@x", thread: 3, n: 9 });
  await settle();
  const fresh = reader((await events.open(viewer("a@x"), "zh", false, [], [], heard)).body as AsyncIterable<Buffer>);
  await settle();
  const told = (got: typeof old.got) => got.filter((e) => e.event === "thread" || e.event === "read").map((e) => [e.id, e.event]);
  // Again, with the ids they had, and only what is this viewer's (not b@x's read).
  assert.deepEqual(told(fresh.got), told(old.got));
  assert.deepEqual(told(fresh.got).map(([, event]) => event).sort(), ["read", "thread"]);
  // From then on, as to everyone.
  change({ type: "thread", id: 5, entries: [{ n: 1 } as any] });
  await settle();
  assert.deepEqual(fresh.got.filter((e) => e.event === "thread").map((e) => e.data.id), [4, 5]);
  await old.close();
  await fresh.close();
});

test("a stream that takes over from what is not kept any more, or another run's, is told it missed it", async () => {
  const time = testClock();
  const { events, change } = setup(time.clock);
  const old = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  change({ type: "thread", id: 3, entries: [{ n: 1 } as any] });
  await settle();
  change({ type: "thread", id: 4, entries: [{ n: 1 } as any] });
  await settle();
  const [three] = old.got.filter((e) => e.event === "thread").map((e) => e.id!);
  // The last it heard (thread 4's summary to its viewer came after thread 4).
  const four = old.got.findLast((e) => e.id)!.id!;
  const told = async (since: string) => {
    const s = reader((await events.open(viewer("a@x"), "zh", false, [], [], since)).body as AsyncIterable<Buffer>);
    await settle();
    await s.close();
    return s.got.filter((e) => e.event === "thread" || e.event === "missed").map((e) => (e.event === "thread" ? e.data.id : e.event));
  };
  assert.deepEqual(await told(`${"0a0a0a0a"}.1`), ["missed"], "another run's");
  // An hour on, more told: 3 and 4 are let go.
  await time.adjust(3_601_000);
  change({ type: "thread", id: 5, entries: [{ n: 1 } as any] });
  await settle();
  change({ type: "thread", id: 6, entries: [{ n: 1 } as any] });
  await settle();
  assert.deepEqual(await told(three!), ["missed"], "4 came after it, and is not kept any more");
  // After the last let go, or later: all that came after is kept, told again.
  assert.deepEqual(await told(four!), [5, 6]);
  assert.deepEqual(await told(old.got.filter((e) => e.event === "thread").at(-2)!.id!), [6]);
  await old.close();
});

test("a stream that comes back after its link went is told what was told meanwhile and how its overview stands", async () => {
  const time = testClock();
  const { events, rows, overview, change } = setup(time.clock);
  const open = async (since?: string) => {
    const answer = await events.open(viewer("a@x"), "zh", false, [], [], since ?? null);
    return { resumed: (answer.headers as Record<string, string>)["stillfail-resumed"] === "1", ...reader(answer.body as AsyncIterable<Buffer>) };
  };
  const lost = await open();
  change({ type: "session", key: "s1" });
  await settle();
  const heard = lost.got.findLast((e) => e.id)!.id!;
  await lost.close();
  assert.equal(events.inUse(), false);
  // Nobody follows: what is told is still made and kept a while, for one coming back.
  change({ type: "thread", id: 4, entries: [{ n: 1 } as any] });
  change({ type: "processes" } as StoreChange);
  rows["a@x"] = [{ id: "1", title: "one, renamed" }, { id: "2", title: "two" }];
  overview.running = 1;
  change({ type: "session", key: "s2" });
  await settle();
  await time.adjust(60_000);
  const back = await open(heard);
  await settle();
  assert.equal(back.resumed, true);
  const told = back.got.filter((e) => e.event).map((e) => [e.event, e.event === "thread" ? e.data.id : e.event === "session" ? e.data.key : e.data]);
  assert.deepEqual(told, [
    ["thread", 4],
    ["session", "s2"],
    ["chat-shared", { id: "1", title: "one, renamed" }],
    ["chat-shared", { id: "2", title: "two" }],
    // Its overview, as it changed while none of its viewer's streams was there to be told.
    ["overview", { running: 1 }],
  ]);
  // Its overview again only as it changes.
  change({ type: "processes" } as StoreChange);
  await settle();
  assert.equal(back.got.filter((e) => e.event === "overview").length, 1);
  await back.close();
  // Past KEPT_MS with nobody: what was told is let go, and one coming back from before reads the station again.
  await time.adjust(3_601_000);
  const late = await open(back.got.findLast((e) => e.id)!.id!);
  await settle();
  assert.equal(late.resumed, false);
  assert.deepEqual(late.got.filter((e) => e.event).map((e) => e.event), ["missed"]);
  await late.close();
});

test("a stream read afresh is told where the log is, so the next goes on from there though nothing was told", async () => {
  const time = testClock();
  const { events, change } = setup(time.clock);
  const open = async (since?: string) => {
    const answer = await events.open(viewer("a@x"), "zh", false, [], [], since ?? null);
    return { resumed: (answer.headers as Record<string, string>)["stillfail-resumed"] === "1", ...reader(answer.body as AsyncIterable<Buffer>) };
  };
  // Something told before it, to a stream gone since: the new one is not told it, and goes on from after it.
  const before = await open();
  change({ type: "session", key: "s1" });
  await settle();
  await before.close();
  const first = await open();
  await settle();
  const at = first.got.map((e) => /^id: ([0-9a-f]+\.\d+)\n\n$/.exec(e.raw)?.[1]).find((id) => id !== undefined);
  assert.ok(at, JSON.stringify(first.got));
  assert.deepEqual(first.got.filter((e) => e.event).map((e) => e.event), []);
  // A quiet station: nothing else came on it before its link went.
  await first.close();
  change({ type: "session", key: "s2" });
  await settle();
  const back = await open(at);
  await settle();
  assert.equal(back.resumed, true);
  // What was told after it (s2), and not what was told before it (s1).
  assert.deepEqual(back.got.filter((e) => e.event === "session").map((e) => e.data.key), ["s2"]);
  // Resumed, it is told no position of its own: what comes on it says where it is.
  assert.equal(back.got.filter((e) => /^id: [^\n]+\n\n$/.test(e.raw)).length, 0);
  await back.close();
});

test("a job's log is told now and as it grows", async () => {
  const time = testClock();
  const { events, dir } = setup(time.clock);
  writeFileSync(join(dir, "j.log"), "one\n");
  const s = reader((await events.open(viewer("a@x"), "zh", false, [], [["j", 50], ["nothing", 5]])).body as AsyncIterable<Buffer>);
  await settle();
  appendFileSync(join(dir, "j.log"), "two\n");
  // Looked at again within 5 s, its watch or not (what the watch tells is side/events.test.ts's), once.
  await time.adjust(5_000);
  await settle();
  const logs = s.got.filter((e) => e.event === "job-log").map((e) => e.data);
  assert.deepEqual(logs, [
    { id: "j", lines: 50, text: "one\n", outputAt: 7 },
    { id: "j", lines: 50, text: "one\ntwo\n", outputAt: 7 },
  ]);
  await s.close();
});

test("what the agents spent is told at most once a minute: the first change at once, the last at the end of it", async () => {
  const time = testClock();
  const { events, change } = setup(time.clock);
  const s = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  const told = () => s.got.filter((e) => e.event === "usage").length;
  change({ type: "usage", sessions: ["k"] });
  await settle();
  assert.equal(told(), 1);
  // A model call every 15 s: told again once, a minute after the first.
  for (let i = 0; i < 3; i++) {
    await time.adjust(15_000);
    change({ type: "usage", sessions: ["k"] });
    await settle();
  }
  assert.equal(told(), 1);
  await time.adjust(15_000);
  await settle();
  assert.equal(told(), 2);
  // Quiet a while: the next change is told at once.
  await time.adjust(120_000);
  change({ type: "usage", sessions: ["k"] });
  await settle();
  assert.equal(told(), 3);
  await s.close();
});

test("usage is told with when the earliest call recorded since was made, each telling kept for one who comes back", async () => {
  // A page holding the usage reads again only the days from then on (client/core-ts/src/station/usage-part.ts); read
  // whole at each telling, it was 2 to 23 s of the station's time a read on a station (2026-11-02).
  const time = testClock();
  const { events, change } = setup(time.clock);
  const s = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  const told = (got: typeof s.got) => got.filter((e) => e.event === "usage").map((e) => e.data);
  change({ type: "usage", sessions: ["k"], from: 5_000 });
  await settle();
  // In the while, the earliest of the calls said: one made before those told already.
  await time.adjust(15_000);
  change({ type: "usage", sessions: ["k"], from: 9_000 });
  change({ type: "usage", sessions: ["j"], from: 2_000 });
  await settle();
  await time.adjust(45_000);
  await settle();
  // A change that does not say when: all of it.
  await time.adjust(60_000);
  change({ type: "usage", sessions: ["k"] });
  await settle();
  assert.deepEqual(told(s.got), [{ from: 5_000 }, { from: 2_000 }, {}]);
  // One that comes back from before them is told each, not the last alone; from after the first, the others.
  const ids = s.got.filter((e) => e.event === "usage").map((e) => e.id!);
  const run = ids[0]!.split(".")[0];
  for (const [since, want] of [[`${run}.0`, [{ from: 5_000 }, { from: 2_000 }, {}]], [ids[0]!, [{ from: 2_000 }, {}]]] as const) {
    const back = reader((await events.open(viewer("a@x"), "zh", false, [], [], since)).body as AsyncIterable<Buffer>);
    await settle();
    assert.deepEqual(told(back.got), want, since);
    await back.close();
  }
  await s.close();
});

// On a station (2026-11-02 15:41 UTC) what was told of two messages just said waited 50 s and 31 s: each was read back first,
// in line behind other reads. What is said is told as the store wrote it.
test("what is said in a thread is told at once, though no read is ever answered", async () => {
  const { events, change, readers } = setup(testClock().clock);
  const a = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  readers.read = () => new Promise(() => {});
  change({ type: "thread", id: 4, entries: [{ n: 7 } as any] });
  change({ type: "letters", id: 4, letters: [{ n: 2 } as any] });
  await settle();
  assert.deepEqual(a.got.filter((e) => e.event === "thread" || e.event === "letters").map((e) => [e.event, e.data]), [
    ["thread", { id: 4, entries: [{ n: 7, text: "hi" }] }],
    ["letters", { id: 4, letters: [{ n: 2, text: "hi" }] }],
  ]);
  await a.close();
});

test("only what is told again has an id: a stream's ids are the log from where it was asked, in order", async () => {
  // A client asks the next stream for what came after the last id it heard. A session's steps, numbered as the latest
  // and told before what was missed, left a client whose stream went in between with the latest id and nothing of
  // what it missed.
  const { events, change } = setup(testClock().clock);
  const first = reader((await events.open(viewer("a@x"), "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  change({ type: "session", key: "s1" });
  await settle();
  const heard = first.got.findLast((e) => e.id)!.id!;
  await first.close();
  for (const id of [4, 5, 6]) change({ type: "thread", id, entries: [{ n: 1 } as any] });
  await settle();
  // A session followed says its steps as the stream opens.
  events.follow({ live: (_key, _from, _last, send) => (send({ type: "steps", steps: [] }), () => {}) });
  const back = reader((await events.open(viewer("a@x"), "zh", false, [["k", 0, null]], [], heard)).body as AsyncIterable<Buffer>);
  await settle();
  // What is its own has no id, whenever it comes: nothing goes on from it.
  assert.equal(back.got.filter((e) => e.event === "live").length, 1);
  assert.equal(back.got.find((e) => e.event === "live")!.id, undefined);
  change({ type: "thread", id: 7, entries: [{ n: 1 } as any] });
  await settle();
  // With an id: what was told after `heard`, then what is told from now, each number above the one before.
  const logged = back.got.filter((e) => e.id);
  assert.deepEqual(logged.filter((e) => e.event === "thread").map((e) => e.data.id), [4, 5, 6, 7]);
  const ns = logged.map((e) => Number(e.id!.split(".")[1]));
  assert.ok(ns.every((n, i) => n > Number(heard.split(".")[1]) && (i === 0 || n > ns[i - 1]!)), `${heard}: ${ns}`);
  await back.close();
});

test("what says a thing whole is kept as it was last told only", async () => {
  const { events, overview, change } = setup(testClock().clock);
  const first = reader((await events.open(viewer("a@x"), "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  change({ type: "session", key: "s1" });
  await settle();
  const heard = first.got.findLast((e) => e.id)!.id!;
  // While it is away (another of its viewer's follows on): a session and the overview change again and again, a thread
  // is said in twice.
  const other = reader((await events.open(viewer("a@x"), "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  await first.close();
  for (let i = 1; i <= 5; i++) {
    overview.running = i;
    events.overviewChanged();
    change({ type: "session", key: "s2" });
    if (i % 2 === 1) change({ type: "thread", id: 4, entries: [{ n: i } as any] });
    await settle();
  }
  assert.equal(other.got.filter((e) => e.event === "overview").length, 5, "one following hears each as it is told");
  const back = reader((await events.open(viewer("a@x"), "zh", false, [], [], heard)).body as AsyncIterable<Buffer>);
  await settle();
  const count = (name: string) => back.got.filter((e) => e.event === name).length;
  // Every thing said in a thread (each adds to it); the session and the overview once, as they were last told.
  assert.deepEqual([count("thread"), count("session"), count("overview")], [3, 1, 1]);
  assert.deepEqual(back.got.find((e) => e.event === "overview")!.data, { running: 5 });
  await back.close();
  await other.close();
});

test("a stream that follows the sessions at work is told what each its viewer sees does, from where it stood, naming none; what is done meanwhile after it", async () => {
  const { events } = setup(testClock().clock);
  const seen: Record<string, string> = { k: "a@x", other: "b@x" };
  const named: string[] = [];
  events.follow({
    held: () => ["k", "other"],
    // (asked of the sessions' program: answered later)
    heldNow: async (keys) => Object.fromEntries(keys.map((key) => [key, [{ type: "timeline", start: key === "k" ? 7 : 2, entries: [], usage: null }, { type: "steps", steps: [], phase: null }]])),
    // A client that does not know yet names the sessions too: they are not followed by name then.
    live: (key) => (named.push(key), () => {}),
  });
  // Only the viewer's sessions.
  (events as any).deps.seen = (v: any, of: any) => !("session" in of) || seen[of.session] === v.email;
  const answer = await events.open(viewer("a@x"), "zh", false, [["k", 0, 200]], [], null, true, [], true);
  assert.equal(answer.headers?.["stillfail-follows"], "running");
  assert.equal(answer.headers?.["stillfail-live-rates"], "1");
  // (done before it was told how it is now: told after that)
  events.heldTold("k", { type: "rate", tokensPerSecond: 3 });
  const a = reader(answer.body as AsyncIterable<Buffer>);
  const old = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  await settle();
  assert.deepEqual(named, [], "nothing followed by name");
  const live = () => a.got.filter((e) => e.event === "live").map((e) => [e.data.key, e.data.type, e.data.start ?? null]);
  // As it is now: where its transcript ends, nothing of it; its steps; then what it did meanwhile.
  assert.deepEqual(live().slice(0, 3), [["k", "timeline", 7], ["k", "steps", null], ["k", "rate", null]]);
  a.got.splice(a.got.findIndex((e) => e.event === "live" && e.data.type === "rate"), 1);
  // From now on, what it does as it does it; the other viewer's not at all; a stream from before not at all.
  events.heldTold("k", { type: "timeline", start: 7, entries: [{ text: "new" }] });
  events.heldTold("other", { type: "timeline", start: 2, entries: [{ text: "theirs" }] });
  await settle();
  assert.deepEqual(live().slice(2), [["k", "timeline", 7]]);
  assert.equal(old.got.filter((e) => e.event === "live").length, 0);
  await a.close();
  await old.close();
});

test("a stream from before asked nothing new: the sessions it names, as before", async () => {
  const { events } = setup(testClock().clock);
  const named: [string, number][] = [];
  events.follow({ held: () => ["k"], heldNow: async () => ({}), live: (key, from) => (named.push([key, from]), () => {}) });
  const answer = await events.open(viewer("a@x"), "zh", false, [["k", 3, 200]], []);
  assert.equal(answer.headers?.["stillfail-follows"], undefined);
  await settle();
  assert.deepEqual(named, [["k", 3]]);
  reader(answer.body as AsyncIterable<Buffer>).close();
});

test("a named live stream only receives a delayed result while its viewer can still see the session", async () => {
  const { events } = setup(testClock().clock);
  let visible = true;
  let exists = true;
  let send: (message: unknown) => void = () => {};
  (events as any).deps.seen = () => visible;
  (events as any).deps.sessionExists = () => exists;
  events.follow({ live: (_key, _from, _last, tell) => { send = tell; return () => {}; } });
  const stream = reader((await events.open(viewer("a@x"), "zh", false, [["k", 0, null]], [])).body as AsyncIterable<Buffer>);
  try {
    send({ type: "timeline", entries: [{ text: "visible" }] });
    visible = false;
    send({ type: "timeline", entries: [{ text: "hidden" }] });
    visible = true;
    send({ type: "timeline", entries: [{ text: "visible again" }] });
    exists = false;
    send({ type: "timeline", entries: [{ text: "deleted" }] });
    await settle();
    assert.deepEqual(stream.got.filter((e) => e.event === "live").map((e) => e.data.entries[0].text), ["visible", "visible again"]);
  } finally { await stream.close(); }
});

test("the sidebar's rows are made from the shared list and what is told: no per-viewer sidebar read", async () => {
  // Every change read every row it could touch again for every viewer: 3 to 5 s each on a station short of memory (2026-11-03).
  const { events, change, reads } = setup(testClock().clock);
  const theirs = reader((await events.open(viewer("a@x"), "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  await settle();
  assert.deepEqual(reads, ["sharedOf"], "shared baseline read once on open");
  change({ type: "thread", id: 4, entries: [{ n: 1 } as any] });
  change({ type: "session", key: "s1" });
  change({ type: "read", viewer: "a@x", thread: 4, n: 1 });
  change({ type: "pins", viewer: "a@x", session: "s1", at: 5 });
  change({ type: "dismissed", viewer: "a@x", card: { thread: 4, n: 1 } });
  await settle();
  assert.deepEqual(reads, ["sharedOf", "summary", "sharedOf"], "only the session summary and shared chat list");
  assert.deepEqual(theirs.got.filter((e) => e.event === "pin").map((e) => e.data), [{ session: "s1", at: 5 }], "what it makes them of, told");
  // Nor what changes which rows there are (a chat's sessions, a chat gone): told that, it reads what it needs itself.
  change({ type: "thread", id: 4, entries: [] });
  change({ type: "threadRemoved", id: 5 });
  await settle();
  assert.deepEqual(reads, ["sharedOf", "summary", "sharedOf", "sharedOf"]);
  assert.deepEqual(theirs.got.filter((e) => e.event === "chat-changed" || e.event === "thread-removed").map((e) => [e.event, e.data]), [["chat-changed", { thread: 4 }], ["thread-removed", { id: 5 }]]);
  // Come back where it left off: resumed.
  const id = theirs.got.at(-1)!.id!;
  const back = await events.open(viewer("a@x"), "zh", false, [], [], id);
  assert.equal((back.headers as Record<string, string>)["stillfail-resumed"], "1");
  reader(back.body as AsyncIterable<Buffer>).close();
  await theirs.close();
});

test("a stream that comes back to the next station process is resumed there, as the one before would have resumed it", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const before = setup(time.clock, { file, previous: previous() });
  const lost = await opened(before.events);
  before.change({ type: "processes" } as StoreChange);
  before.change({ type: "session", key: "s1" });
  await settle();
  const heard = lost.got.findLast((e) => e.id)!.id!;
  // An update: the next process is up before this one stops, and waits for it to be gone.
  const gone = Promise.withResolvers<void>();
  const after = setup(time.clock, { file, previous: previous(gone.promise) }, before);
  // Its streams cut as it stops; what it tells until it hands over is kept all the same, whoever it is for.
  await lost.close();
  before.change({ type: "thread", id: 4, entries: [{ n: 1 } as any] });
  await settle();
  before.change({ type: "read", viewer: "a@x", thread: 3, n: 9 });
  before.change({ type: "read", viewer: "b@x", thread: 3, n: 9 });
  before.rows["a@x"] = [{ id: "1", title: "one" }, { id: "2", title: "two" }];
  before.change({ type: "session", key: "s2" });
  await settle();
  await before.events.handOver();
  before.change({ type: "session", key: "s9" });
  await settle();
  assert.ok(existsSync(file));
  // Its client comes back to the next one before the old one is gone: answered once it is, from what it handed over.
  const asked = opened(after.events, heard);
  let answered = false;
  void asked.then(() => (answered = true));
  await settle();
  assert.equal(answered, false);
  gone.resolve();
  const back = await asked;
  await settle();
  assert.equal(back.resumed, true);
  assert.equal(existsSync(file), false);
  const told = back.got.filter((e) => e.event).map((e) => [e.event, e.event === "thread" ? e.data.id : e.event === "session" ? e.data.key : e.data]);
  // What came after `since` and is its viewer's (not b@x's read, nothing told once handed over); the overview as it
  // was: not told again.
  assert.deepEqual(told, [
    ["thread", 4],
    ["read", { viewer: "a@x", thread: 3, n: 9 }],
    ["session", "s2"],
    ["chat-shared", { id: "2", title: "two" }],
  ]);
  // And on from there: the same run, numbered on.
  after.change({ type: "session", key: "s3" });
  await settle();
  const ids = back.got.filter((e) => e.id).map((e) => e.id!.split("."));
  assert.deepEqual(back.got.filter((e) => e.event === "session").map((e) => e.data.key), ["s2", "s3"]);
  assert.ok(ids.every(([run, n], i) => run === heard.split(".")[0] && Number(n) > Number(heard.split(".")[1]) && (i === 0 || Number(n) > Number(ids[i - 1]![1]))), JSON.stringify(ids));
  await back.close();
});

test("what the next process tells before its streams come back is kept for them, as while nobody follows", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const before = setup(time.clock, { file, previous: previous() });
  const lost = await opened(before.events);
  before.change({ type: "session", key: "s1" });
  await settle();
  const heard = lost.got.findLast((e) => e.id)!.id!;
  await lost.close();
  await before.events.handOver();
  // The next one takes up the sessions: what they do is told with nobody following yet, a thread's entries read as
  // the one who followed last has them.
  const after = setup(time.clock, { file, previous: previous() }, before);
  await settle();
  after.change({ type: "thread", id: 5, entries: [{ n: 1 } as any] });
  after.change({ type: "session", key: "s3" });
  await settle();
  await time.adjust(60_000);
  const back = await opened(after.events, heard);
  await settle();
  assert.equal(back.resumed, true);
  const told = back.got.filter((e) => e.event && e.event !== "overview").map((e) => [e.event, e.event === "thread" ? e.data.id : e.event === "session" ? e.data.key : e.data]);
  assert.deepEqual(told, [["thread", 5], ["session", "s3"]]);
  await back.close();
});

test("a stream that comes back to a process that took up nothing to go on from is told it missed it", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  /// A process whose stream was cut, stopped: handing over or not (a crash). The last id its stream heard.
  const stopped = async (hands: boolean) => {
    const before = setup(time.clock, { file, previous: previous() });
    const lost = await opened(before.events);
    before.change({ type: "processes" } as StoreChange);
    before.change({ type: "session", key: "s1" });
    await settle();
    await lost.close();
    if (hands) await before.events.handOver();
    return lost.got.findLast((e) => e.id)!.id!;
  };
  /// Its stream back at the next process: whether it was resumed, and the events it is told.
  const back = async (since: string) => {
    const after = setup(time.clock, { file, previous: previous() });
    const s = await opened(after.events, since);
    await settle();
    await s.close();
    return [s.resumed, s.got.filter((e) => e.event).map((e) => e.event)];
  };
  // Handed over: resumed, with nothing to tell.
  assert.deepEqual(await back(await stopped(true)), [true, []]);
  // A crash: nothing handed over.
  assert.deepEqual(await back(await stopped(false)), [false, ["missed"]]);
  // Handed over longer than KEPT_MS before the next process came: not taken up, and gone.
  const old = await stopped(true);
  await time.adjust(KEPT_MS + 1_000);
  assert.deepEqual(await back(old), [false, ["missed"]]);
  assert.equal(existsSync(file), false);
  // What does not read (cut short): not taken up, and gone.
  const cut = await stopped(true);
  writeFileSync(file, readFileSync(file, "utf8").slice(0, 100));
  assert.deepEqual(await back(cut), [false, ["missed"]]);
  assert.equal(existsSync(file), false);
  // Nobody followed for longer than KEPT_MS: nothing is handed over.
  const quiet = setup(time.clock, { file, previous: previous() });
  await (await opened(quiet.events)).close();
  await time.adjust(KEPT_MS + 1_000);
  await quiet.events.handOver();
  assert.equal(existsSync(file), false);
});

test("what the next process is to tell before it goes on from the one before is told after what that one told, numbered on", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const before = setup(time.clock, { file, previous: previous() });
  const lost = await opened(before.events);
  before.change({ type: "session", key: "s1" });
  await settle();
  const heard = lost.got.findLast((e) => e.id)!.id!;
  await lost.close();
  // The next one is up while the one before stops (a device may reach it first): what it is to tell meanwhile waits.
  const gone = Promise.withResolvers<void>();
  const after = setup(time.clock, { file, previous: previous(gone.promise) }, before);
  after.change({ type: "read", viewer: "a@x", thread: 3, n: 9 });
  after.change({ type: "read", viewer: "b@x", thread: 3, n: 9 });
  after.events.tell("vault-plain", { id: "p1" }, "vault-plain\0p1", { workspace: "w", email: "a@x" });
  after.change({ type: "thread", id: 5, entries: [{ n: 1 } as any] });
  after.change({ type: "session", key: "s2" });
  await settle();
  before.change({ type: "session", key: "s3" });
  await settle();
  await before.events.handOver();
  gone.resolve();
  const back = await opened(after.events, heard);
  await settle();
  assert.equal(back.resumed, true);
  // All of it, the one before's first, and only what is a@x's (not b@x's read); a thread's entries read as a@x has them.
  const told = back.got.filter((e) => e.event && e.event !== "overview").map((e) => [e.event, e.event === "thread" ? e.data.id : e.event === "session" ? e.data.key : e.data]);
  assert.deepEqual(told, [
    ["session", "s3"],
    ["read", { viewer: "a@x", thread: 3, n: 9 }],
    ["vault-plain", { id: "p1" }],
    ["thread", 5],
    ["session", "s2"],
  ]);
  // The same run, numbered on from the last the one before told.
  const [run, n] = heard.split(".");
  const ids = back.got.filter((e) => e.id).map((e) => e.id!.split("."));
  assert.ok(ids.every(([r, m], i) => r === run && Number(m) > Number(n) && (i === 0 || Number(m) > Number(ids[i - 1]![1]))), JSON.stringify(ids));
  await back.close();
});

test("what is handed over is gone on from only by the process that waited for the one that handed it over", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  // Another process's pid (every one of a test is this process).
  const other = process.pid + 1;
  /// A process whose stream was cut, slow to stop: the last id its stream heard, and its handing over.
  const slow = async () => {
    const before = setup(time.clock, { file, previous: previous() });
    const lost = await opened(before.events);
    before.change({ type: "processes" } as StoreChange);
    before.change({ type: "session", key: "s1" });
    await settle();
    await lost.close();
    return { heard: lost.got.findLast((e) => e.id)!.id!, before };
  };
  /// The next process, waiting for `pid`: whether a@x's stream from `since` is resumed there, and the events it is told.
  const back = async (since: string, pid: number | null) => {
    const after = setup(time.clock, { file, previous: { pid, gone: Promise.resolve() } });
    const s = await opened(after.events, since);
    await settle();
    await s.close();
    return [s.resumed, s.got.filter((e) => e.event).map((e) => e.event)];
  };
  // The next one waited for it in vain (40 s), found nothing, and went on with a run of its own; then it hands over.
  let a = await slow();
  let b = setup(time.clock, { file, previous: previous() });
  await settle();
  await a.before.events.handOver();
  assert.ok(existsSync(file));
  // That one stops with nothing to hand over (nobody followed it): what is there goes with it.
  await b.events.handOver();
  assert.equal(existsSync(file), false);
  // Or it crashes: the one after it waits for it (run/hub.json names it), and does not go on from what is there.
  a = await slow();
  b = setup(time.clock, { file, previous: previous() });
  await settle();
  await a.before.events.handOver();
  assert.deepEqual(await back(a.heard, other), [false, ["missed"]]);
  assert.equal(existsSync(file), false);
  // Stopped before the next one started (none holds the station then): gone on from.
  a = await slow();
  await a.before.events.handOver();
  assert.deepEqual(await back(a.heard, null), [true, []]);
});

test("what is handed over that can be neither read nor removed fails no stream, waited on or not", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  mkdirSync(file, { recursive: true });
  const unhandled: unknown[] = [];
  const heard = (reason: unknown) => void unhandled.push(reason);
  process.on("unhandledRejection", heard);
  try {
    // Nobody waits on its taking up.
    setup(time.clock, { file, previous: previous() });
    await settle();
    // A stream does: answered, told it missed what was before.
    const after = setup(time.clock, { file, previous: previous() });
    const s = await opened(after.events, "1f2e3d4c.3");
    await settle();
    assert.equal(s.resumed, false);
    assert.deepEqual(s.got.filter((e) => e.event).map((e) => e.event), ["missed"]);
    await s.close();
  } finally {
    process.off("unhandledRejection", heard);
  }
  assert.deepEqual(unhandled, []);
});

test("a vault's records are told to its members as they are as each is told, again too", async () => {
  const time = testClock();
  const members = new Set(["a@x"]);
  const { events } = setup(time.clock);
  events.follow({ inVault: (viewer, vault) => vault === "v1" && members.has(viewer.sub) });
  /// a@x's and b@x's streams, each from its `since`.
  const streams = async (since: string[]) => {
    const both = await Promise.all(["a@x", "b@x"].map(async (who, i) => reader((await events.open(viewer(who), "zh", false, [], [], since[i] ?? null)).body as AsyncIterable<Buffer>)));
    await settle();
    return both;
  };
  const first = await streams([]);
  const at = first.map((s) => s.got.map((e) => /^id: ([0-9a-f]+\.\d+)\n\n$/.exec(e.raw)?.[1]).find((id) => id !== undefined)!);
  events.tell("vault-request", { id: "r1" }, "vault-request\0r1", { workspace: "w", vault: "v1" });
  await settle();
  const told = (s: (typeof first)[number]) => s.got.filter((e) => e.event === "vault-request").map((e) => e.data.id);
  assert.deepEqual(first.map(told), [["r1"], []]);
  for (const s of first) await s.close();
  // a@x left the vault and b@x came in: what their streams are told again is as the vault's members are now.
  members.delete("a@x");
  members.add("b@x");
  const again = await streams(at);
  assert.deepEqual(again.map(told), [[], ["r1"]]);
  for (const s of again) await s.close();
});

test("a session's summary read before its messages were taken is not told after the station told they were", async () => {
  // Its agent took a message (`session-pending`, told at once) while the summary a change before asked for was still
  // being read: told after it, that summary had the message waiting again and the turn before, and a device stood the
  // agent back in the queue, its activity in the chat gone until the next summary came (2026-11-09).
  const { events, readers, change } = setup(testClock().clock);
  const a = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  await settle();
  const read = readers.read;
  let pending = 1;
  let release: () => void = () => {};
  const held = new Promise<void>((r) => (release = r));
  let first = true;
  readers.read = async (op: string, args: any) => {
    if (op !== "summary") return read(op, args);
    const snapshot = pending;
    if (first) {
      first = false;
      await held;
    }
    return JSON.stringify({ key: args.key, pending: snapshot });
  };
  change({ type: "session", key: "s" });
  await settle();
  pending = 0;
  change({ type: "session", key: "s", pending: 0 });
  release();
  await settle();
  const told = a.got.filter((e) => e.event === "session" || e.event === "session-pending").map((e) => [e.event, e.data.pending]);
  assert.deepEqual(told, [["session-pending", 0], ["session", 0]]);
  await a.close();
});

test("a chat handed to another station is told to a stream cut before and resumed after, only to its workspace's", async () => {
  const { events, change } = setup(testClock().clock);
  const before = await opened(events);
  change({ type: "session", key: "1" });
  await settle();
  const heard = before.got.findLast((e) => e.id)!.id!;
  await before.close();
  // Handed over while no stream of a@x's was open: one of another workspace's, open then, is not told.
  const answer = await events.open({ ...viewer("b@x"), workspace: "other", home: false }, "zh", false, [], [], null);
  const other = reader(answer.body as AsyncIterable<Buffer>);
  change({ type: "moved", key: "1", station: "b", ws: "w", thread: 7, there: 3 });
  await settle();
  const back = await opened(events, heard);
  await settle();
  assert.equal(back.resumed, true);
  const moved = back.got.filter((e) => e.event === "chat-moved");
  assert.deepEqual(moved.map((e) => e.data), [{ session: "1", station: "b", thread: 7, there: 3 }]);
  assert.ok(!other.got.some((e) => e.event === "chat-moved"));
  await back.close();
  await other.close();
});

test("a host sample that fails is no rejection, as a stream joins or on the beat after", async () => {
  const time = testClock();
  let asked = 0;
  const { events } = setup(time.clock, undefined, undefined, () => (asked++, Promise.reject(new Error("spawn UNKNOWN"))));
  const unhandled: unknown[] = [];
  const heard = (reason: unknown) => void unhandled.push(reason);
  process.on("unhandledRejection", heard);
  try {
    const s = reader((await events.open(viewer("a@x"), "zh", true, [], [])).body as AsyncIterable<Buffer>);
    await settle();
    await time.adjust(10_000);
    await settle();
    assert.equal(asked, 2, "asked as it joined and on the beat");
    assert.equal(s.got.filter((e) => e.event === "host").length, 0);
    await s.close();
  } finally {
    process.off("unhandledRejection", heard);
  }
  assert.deepEqual(unhandled, []);
});

test("spare=1 filters live snapshots and heldTold events to open sessions, sets stillfail-spared, and cuts live traffic", async () => {
  const { events } = setup(testClock().clock);
  const keys = ["A", "B", "C", "D", "E"];
  const heldNowAsked: string[][] = [];
  events.follow({
    held: () => keys,
    heldNow: async (asked) => {
      heldNowAsked.push([...asked]);
      return Object.fromEntries(asked.map((key) => [key, [{ type: "timeline", start: 10, entries: [], usage: null }, { type: "steps", steps: [], phase: null }]]));
    },
  });
  const spareA = await events.open(viewer("a@x"), "zh", false, [], [], null, true, [], true, ["A"]);
  const spareNone = await events.open(viewer("a@x"), "zh", false, [], [], null, true, [], true, []);
  const full = await events.open(viewer("a@x"), "zh", false, [], [], null, true, [], true, null);
  assert.equal(spareA.headers?.["stillfail-spared"], "1");
  assert.equal(spareNone.headers?.["stillfail-spared"], "1");
  assert.equal(full.headers?.["stillfail-spared"], undefined);

  const rawBytes = (body: AsyncIterable<Buffer>) => {
    let bytes = 0;
    const got: { event: string; data: any }[] = [];
    const it = body[Symbol.asyncIterator]();
    let buf = "";
    const loop = (async () => {
      for (;;) {
        const next = await it.next();
        if (next.done) break;
        bytes += next.value.length;
        buf += next.value.toString("utf8");
        for (let at = buf.indexOf("\n\n"); at >= 0; at = buf.indexOf("\n\n")) {
          const block = buf.slice(0, at);
          buf = buf.slice(at + 2);
          const ev = /^event:\s*(.+)$/m.exec(block)?.[1];
          const data = /^data:\s*(.+)$/m.exec(block)?.[1];
          if (ev && data) got.push({ event: ev, data: JSON.parse(data) });
        }
      }
    })();
    return { got, bytes: () => bytes, close: async () => { await it.return?.(); await loop; } };
  };

  const rA = rawBytes(spareA.body as AsyncIterable<Buffer>);
  const rNone = rawBytes(spareNone.body as AsyncIterable<Buffer>);
  const rFull = rawBytes(full.body as AsyncIterable<Buffer>);
  await settle();

  // heldNow snapshot only requested for A on spareA, none on spareNone, all 5 on full
  assert.deepEqual(heldNowAsked, [["A"], keys]);

  // Same workload across all 5 running sessions (20 steps each)
  for (let i = 0; i < 20; i++) {
    for (const k of keys) {
      events.heldTold(k, {
        type: "timeline",
        start: 10 + i,
        entries: [{ kind: "tool", name: "read_file", summary: `step ${i} of session ${k} with payload` }],
        usage: { input: 1000 + i, output: 200 + i },
      });
    }
  }
  await settle();

  const liveA = rA.got.filter((e) => e.event === "live");
  const liveNone = rNone.got.filter((e) => e.event === "live");
  const liveFull = rFull.got.filter((e) => e.event === "live");

  // (a) spare=1&open=A: only A's live events (2 snapshot + 20 timeline = 22), 0 from B..E
  assert.ok(liveA.every((e) => e.data.key === "A"));
  assert.equal(liveA.length, 22);
  assert.equal(liveA.filter((e) => e.data.key !== "A").length, 0);
  // (b) spare=1 with no open: 0 live events
  assert.equal(liveNone.length, 0);
  // (c) without spare: all 5 sessions (5*2 snapshot + 5*20 timeline = 110)
  assert.equal(liveFull.length, 110);

  console.log(`[spare-live stats] full: ${liveFull.length} live events, ${rFull.bytes()} bytes | spare(open=A): ${liveA.length} live events, ${rA.bytes()} bytes | spare(no open): ${liveNone.length} live events, ${rNone.bytes()} bytes`);

  await rA.close();
  await rNone.close();
  await rFull.close();
});

test("events route parses spare=1 and repeated open=<key> (deduped, filtered, capped at 16, only with running=1)", async () => {
  const { routes } = await import("../src/api/routes/events.ts");
  const calls: { running: boolean; spare: string[] | null }[] = [];
  const open = async (_v: any, _l: any, _h: any, _live: any, _logs: any, _s: any, _b: any, _lo: any, running: boolean, spare: string[] | null) => {
    calls.push({ running, spare });
    return { status: 200, headers: {}, body: "" };
  };
  const existing = new Set(Array.from({ length: 20 }, (_, i) => `s${i}`));
  const [route] = routes({ events: { open } as any, sessionExists: (k: string) => existing.has(k) } as any);
  const ask = (query: [string, string][]) => route!.handle({ viewer: viewer("a@x"), lang: "zh", query } as any, [] as any);

  await ask([["running", "1"], ["spare", "1"], ["open", "s1"], ["open", "s1"], ["open", "missing"], ...Array.from({ length: 20 }, (_, i): [string, string] => ["open", `s${i}`])]);
  await ask([["spare", "1"], ["open", "s1"]]);
  await ask([["running", "1"]]);
  await ask([["running", "1"], ["spare", "1"]]);

  assert.equal(calls[0]!.running, true);
  assert.equal(calls[0]!.spare?.length, 16);
  assert.equal(new Set(calls[0]!.spare).size, 16);
  assert.ok(!calls[0]!.spare!.includes("missing"));
  assert.deepEqual(calls[1], { running: false, spare: null });
  assert.deepEqual(calls[2], { running: true, spare: null });
  assert.deepEqual(calls[3], { running: true, spare: [] });
});

test("a stream that comes back has its own viewer's overview made again, not every viewer's", async () => {
  const { events, change } = setup(testClock().clock);
  const made: string[] = [];
  events.follow({ overview: async (v) => (made.push(v.email), { running: 0 }) });
  const other = await events.open(viewer("b@x"), "zh", false, [], [], null);
  const otherStream = reader(other.body as AsyncIterable<Buffer>);
  const first = await opened(events);
  change({ type: "session", key: "1" });
  await settle();
  const heard = first.got.findLast((e) => e.id)!.id!;
  await first.close();
  made.length = 0;
  const back = await opened(events, heard);
  await settle();
  assert.equal(back.resumed, true);
  assert.deepEqual(made, ["a@x"]);
  await back.close();
  await otherStream.close();
});

test("what is told to every stream looks up the session or thread it names once, and a live step is made once", async () => {
  const { events, change } = setup(testClock().clock);
  events.follow({ held: () => [], heldNow: async () => ({}) });
  const looked: string[] = [];
  // Session k is a@x's and c@x's to see, not b@x's.
  (events as any).deps.seer = (of: any) => (looked.push(JSON.stringify(of)), (v: any) => v.email !== "b@x");
  const streams = await Promise.all(["a@x", "b@x", "c@x"].map(async (who) => reader((await events.open(viewer(who), "zh", false, [], [], null, true, [], true)).body as AsyncIterable<Buffer>)));
  await settle();
  looked.length = 0;
  events.heldTold("k", { type: "rate", tokensPerSecond: 3 });
  change({ type: "thread", id: 9, entries: [] });
  await settle();
  assert.deepEqual(looked, [JSON.stringify({ session: "k" }), JSON.stringify({ thread: 9 })]);
  const told = streams.map((s) => s.got.filter((e) => e.event === "live").map((e) => e.raw));
  assert.deepEqual(told[1], []);
  assert.equal(told[0]!.length, 1);
  assert.deepEqual(told[2], told[0]);
  assert.deepEqual(JSON.parse(/data: (.*)\n/.exec(told[0]![0]!)![1]!), { type: "rate", tokensPerSecond: 3, key: "k" });
  assert.deepEqual(streams.map((s) => s.got.some((e) => e.event === "chat-changed")), [true, false, true]);
  await Promise.all(streams.map((s) => s.close()));
});

test("background overview changes coalesce into one trailing push and volatile telemetry drift is ignored", async () => {
  const time = testClock();
  const { events, change } = setup(time.clock);
  let state = {
    counts: { running: 1 },
    disk: { freeBytes: 50_000_000_000, totalBytes: 100_000_000_000 },
    processes: [{ pid: 1, rssMb: 100 }],
    machine: { uptime: 10, loadavg: [1, 1, 1] },
  };
  events.follow({ overview: async () => structuredClone(state) });
  const stream = await opened(events);

  // First background change fires immediately.
  change({ type: "processes" } as StoreChange);
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, 1);

  // Burst of background changes within 10 s coalesces into a single trailing overview after the window.
  for (let i = 2; i <= 5; i++) {
    state.counts.running = i;
    events.overviewSoon();
    await settle();
  }
  assert.equal(stream.got.filter((e) => e.event === "overview").length, 1, "burst held back until window ends");
  await time.adjust(10_000);
  await settle();
  const afterBurst = stream.got.filter((e) => e.event === "overview");
  assert.equal(afterBurst.length, 2, "one trailing overview after burst");
  assert.equal(afterBurst[1]!.data.counts.running, 5);

  // Jitter in ample disk freeBytes, process rssMb, and machine telemetry does not emit another overview.
  state.disk.freeBytes -= 4_096_000;
  state.processes[0]!.rssMb = 142;
  state.machine.uptime = 999;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, 2, "volatile telemetry drift suppressed");

  // Crossing into and out of the 10 GiB low-disk threshold on a 100 GiB disk emits both ways.
  const GiB = 1024 ** 3;
  state.disk = { freeBytes: 20 * GiB, totalBytes: 100 * GiB };
  events.overviewChanged();
  await settle();
  const beforeWarn100 = stream.got.filter((e) => e.event === "overview").length;
  state.disk = { freeBytes: 8 * GiB, totalBytes: 100 * GiB };
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, beforeWarn100 + 1, "100 GiB disk entering <= 10 GiB warning emits");
  state.disk = { freeBytes: 20 * GiB, totalBytes: 100 * GiB };
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, beforeWarn100 + 2, "100 GiB disk leaving warning emits");

  // Crossing into and out of the 10% low-disk threshold on a 1000 GiB disk emits both ways.
  state.disk = { freeBytes: 120 * GiB, totalBytes: 1000 * GiB };
  events.overviewChanged();
  await settle();
  const beforeWarn1000 = stream.got.filter((e) => e.event === "overview").length;
  state.disk = { freeBytes: 80 * GiB, totalBytes: 1000 * GiB };
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, beforeWarn1000 + 1, "1000 GiB disk entering <= 10% warning emits");
  state.disk = { freeBytes: 120 * GiB, totalBytes: 1000 * GiB };
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, beforeWarn1000 + 2, "1000 GiB disk leaving warning emits");

  await stream.close();
});

test("large low-percent disk jitter and routine healthy copies ticks do not trigger overview pushes", async () => {
  const time = testClock();
  const { events } = setup(time.clock);
  const GiB = 1024 ** 3;
  const MiB = 1024 ** 2;
  let state: Record<string, any> = {
    counts: { running: 2 },
    disk: { freeBytes: 94 * GiB, totalBytes: 1858 * GiB },
    copies: {
      mode: "auto",
      to: 1000,
      chats: 42,
      formerly: [],
      keepers: [
        { id: "k1", name: "mini", at: 1_795_520_000_000, to: 1000, status: "ok", error: null },
      ],
      backup: {
        s3: [{ id: "s3-1", at: 1_795_520_000_000, to: 1000, error: null }],
      },
    },
  };
  events.follow({ overview: async () => structuredClone(state) });
  const stream = await opened(events);

  events.overviewChanged();
  await settle();
  let base = stream.got.filter((e) => e.event === "overview").length;
  assert.equal(base, 1);

  // Small +/-200 MiB fluctuations on a 1858 GiB drive with 94 GiB free (5.1%) stay in the same 1% bucket.
  state.disk.freeBytes -= 200 * MiB;
  events.overviewChanged();
  await settle();
  state.disk.freeBytes += 200 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base, "small jitter on large <10% drive suppressed");

  // Healthy backup copy progress ticks (`to`, `chats`, `at`) do not trigger pushes.
  state.copies.to = 1001;
  state.copies.chats = 43;
  state.copies.keepers[0].to = 1001;
  state.copies.keepers[0].at = 1_795_520_030_000;
  state.copies.backup.s3[0].to = 1001;
  state.copies.backup.s3[0].at = 1_795_520_030_000;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base, "healthy routine copies progress suppressed");

  // When a place was last level is what its row says ("N minutes ago"): told again once it moved on by a step.
  state.copies.keepers[0].at = 1_795_520_000_000 + 11 * 60_000;
  state.copies.backup.s3[0].at = 1_795_520_000_000 + 11 * 60_000;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base + 1, "a later backup time is told within ten minutes");
  base += 1;

  // A large drive's free space as a warning says it is never more than 4 GiB off.
  state.disk.freeBytes -= 5 * GiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base + 1, "5 GiB less on a large low drive emits");
  base += 1;

  // The first chat on a station changes what is offered on it.
  state.copies.chats = 0;
  events.overviewChanged();
  await settle();
  base = stream.got.filter((e) => e.event === "overview").length;
  state.copies.chats = 1;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base + 1, "its first chat emits");
  base += 1;

  // Crossing into <= 10 GiB still emits.
  state.disk.freeBytes = 8 * GiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base + 1, "crossing <= 10 GiB emits");

  // A keeper error still emits.
  state.copies.keepers[0].error = "disk full";
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base + 2, "keeper error emits");

  // Clearing the error and falling behind (keeper.to < copies.to) still emits.
  state.copies.keepers[0].error = null;
  state.copies.keepers[0].to = 900;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base + 3, "keeper synced->behind emits");

  // `copies.formerly` change still emits.
  state.copies.formerly = ["ws/old"];
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, base + 4, "copies.formerly change emits");

  await stream.close();
});

test("free-disk step hysteresis suppresses boundary oscillation while warning transitions still emit immediately", async () => {
  const time = testClock();
  const { events } = setup(time.clock);
  const GiB = 1024 ** 3;
  const MiB = 1024 ** 2;
  const state = {
    counts: { running: 1 },
    disk: { freeBytes: 8 * GiB + 1 * MiB, totalBytes: 100 * GiB },
  };
  events.follow({ overview: async () => structuredClone(state) });
  const stream = await opened(events);

  events.overviewChanged();
  await settle();
  let count = stream.got.filter((e) => e.event === "overview").length;
  assert.equal(count, 1);

  // Synthetic trace across a 512 MiB step boundary (1 MiB each side every 10 s for one hour): 0 extra overviews.
  for (let i = 0; i < 360; i++) {
    state.disk.freeBytes = i % 2 === 0 ? 8 * GiB - 1 * MiB : 8 * GiB + 1 * MiB;
    events.overviewChanged();
    await time.adjust(10_000);
    await settle();
  }
  assert.equal(stream.got.filter((e) => e.event === "overview").length, count, "low-step boundary oscillation suppressed");

  // Moving past the downward hysteresis margin (128 MiB for a 512 MiB step) emits once, then holds against +/-1 MiB jitter.
  state.disk.freeBytes = 8 * GiB - 127 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, count, "within downward margin holds bucket");

  state.disk.freeBytes = 8 * GiB - 128 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "past downward margin emits");

  for (let i = 0; i < 10; i++) {
    state.disk.freeBytes = 8 * GiB - 128 * MiB + (i % 2 === 0 ? 1 * MiB : -1 * MiB);
    events.overviewChanged();
    await settle();
  }
  assert.equal(stream.got.filter((e) => e.event === "overview").length, count, "oscillation around new bucket suppressed");

  // Moving back up requires crossing the upward hysteresis margin (+128 MiB past 8 GiB) before emitting.
  state.disk.freeBytes = 8 * GiB + 127 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, count, "within upward margin holds bucket");

  state.disk.freeBytes = 8 * GiB + 128 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "past upward margin emits");

  for (let i = 0; i < 10; i++) {
    state.disk.freeBytes = 8 * GiB + 128 * MiB + (i % 2 === 0 ? -1 * MiB : 1 * MiB);
    events.overviewChanged();
    await settle();
  }
  assert.equal(stream.got.filter((e) => e.event === "overview").length, count, "oscillation around upward threshold suppressed");

  // Large drive pct bucket (1858 GiB total, 4 GiB step, 1 GiB margin) around 92 GiB (pct:23).
  state.disk = { freeBytes: 92 * GiB + 1 * MiB, totalBytes: 1858 * GiB };
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "entering pct:23 emits");

  for (let i = 0; i < 360; i++) {
    state.disk.freeBytes = i % 2 === 0 ? 92 * GiB - 1 * MiB : 92 * GiB + 1 * MiB;
    events.overviewChanged();
    await time.adjust(10_000);
    await settle();
  }
  assert.equal(stream.got.filter((e) => e.event === "overview").length, count, "pct-step boundary oscillation suppressed");

  state.disk.freeBytes = 91 * GiB + 1 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, count, "within pct downward margin holds bucket");

  state.disk.freeBytes = 91 * GiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "past pct downward margin emits pct:22");

  state.disk.freeBytes = 92 * GiB + 1 * GiB - 1 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, count, "within pct upward margin holds bucket");

  state.disk.freeBytes = 93 * GiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "past pct upward margin emits pct:23");

  // Warning-level transitions (ok <-> low, ok <-> pct, pct <-> low) still emit immediately at 1 MiB boundaries.
  state.disk = { freeBytes: 10 * GiB + 1 * MiB, totalBytes: 100 * GiB };
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count);

  state.disk.freeBytes = 10 * GiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "ok -> low warning emits immediately");

  state.disk.freeBytes = 10 * GiB + 1 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "low -> ok warning emits immediately");

  state.disk = { freeBytes: 100 * GiB + 1 * MiB, totalBytes: 1000 * GiB };
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count);

  state.disk.freeBytes = 100 * GiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "ok -> pct warning emits immediately");

  state.disk.freeBytes = 100 * GiB + 1 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "pct -> ok warning emits immediately");

  state.disk = { freeBytes: 10 * GiB + 1 * MiB, totalBytes: 1000 * GiB };
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count);

  state.disk.freeBytes = 10 * GiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "pct -> low warning emits immediately");

  state.disk.freeBytes = 10 * GiB + 1 * MiB;
  events.overviewChanged();
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, ++count, "low -> pct warning emits immediately");

  await stream.close();
});

test("handover preserves free-disk step hysteresis for resumed streams", async () => {
  const time = testClock();
  const GiB = 1024 ** 3;
  const MiB = 1024 ** 2;
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const state = {
    counts: { running: 1 },
    disk: { freeBytes: 8 * GiB + 1 * MiB, totalBytes: 100 * GiB },
  };

  const before = setup(time.clock, { file, previous: previous() });
  before.events.follow({ overview: async () => structuredClone(state) });
  const lost = await opened(before.events);
  before.events.overviewChanged();
  await settle();
  assert.equal(lost.got.filter((e) => e.event === "overview").length, 1);
  const heard = lost.got.findLast((e) => e.id)!.id!;
  await before.events.handOver();

  const after = setup(time.clock, { file, previous: previous() }, before);
  after.events.follow({ overview: async () => structuredClone(state) });
  const back = await opened(after.events, heard);
  await settle();
  assert.equal(back.resumed, true);

  state.disk.freeBytes = 8 * GiB - 1 * MiB;
  after.events.overviewChanged();
  await settle();
  assert.equal(back.got.filter((e) => e.event === "overview").length, 0, "handover keeps disk step hysteresis");

  state.disk.freeBytes = 8 * GiB - 128 * MiB;
  after.events.overviewChanged();
  await settle();
  assert.equal(back.got.filter((e) => e.event === "overview").length, 1, "crossing margin after handover emits");

  await lost.close();
  await back.close();
});

test("overviewComparable falls back cleanly on malformed previous or changed pct step size", () => {
  const GiB = 1024 ** 3;
  const MiB = 1024 ** 2;
  const lowSample = { counts: { running: 1 }, disk: { freeBytes: 8 * GiB - 1 * MiB, totalBytes: 100 * GiB } };
  const fresh = overviewComparable(lowSample);
  assert.equal(JSON.parse(fresh).disk.freeBytes, "low:15");

  // Malformed JSON or unexpected freeBytes shapes fall back to exact bucketing without throwing.
  for (const bad of ["not-json", "{}", JSON.stringify({ disk: null }), JSON.stringify({ disk: { freeBytes: 123 } }), JSON.stringify({ disk: { freeBytes: "bad:1" } })]) {
    assert.equal(JSON.parse(overviewComparable(lowSample, bad)).disk.freeBytes, "low:15");
  }

  // When totalBytes changes the pct step size (250 GiB -> 2.5 GiB step vs 400 GiB -> 4 GiB step), do not reuse the old index.
  const prev250 = overviewComparable({ disk: { freeBytes: 25 * GiB - 1 * MiB, totalBytes: 250 * GiB } });
  assert.equal(JSON.parse(prev250).disk.freeBytes, "pct:9");
  const resized400 = overviewComparable({ disk: { freeBytes: 25 * GiB - 1 * MiB, totalBytes: 400 * GiB } }, prev250);
  assert.equal(JSON.parse(resized400).disk.freeBytes, "pct:6");
});

test("overviewChangedKeys reports only changed top-level keys without leaking values", () => {
  const prev = overviewComparable({ counts: { running: 1 }, profiles: [{ id: "p1", secret: "nope" }], move: { offered: true, chats: [] } });
  const next = overviewComparable({ counts: { running: 2 }, profiles: [{ id: "p1", secret: "nope" }], move: { offered: true, chats: ["c1"] } });
  assert.deepEqual(overviewChangedKeys(prev, next), ["counts", "move"]);
  assert.deepEqual(overviewChangedKeys(prev, prev), []);
  assert.deepEqual(overviewChangedKeys("not-json", next), ["?"]);
});

test("background overview triggers coalesce with sessionRemoved while immediate admin triggers flush once and cancel trailing timer", async () => {
  const time = testClock();
  const { events, change } = setup(time.clock);
  const state = { counts: { running: 1, sessions: 3 }, move: { offered: true, chats: [] as string[] }, configTag: "a" };
  events.follow({ overview: async () => structuredClone(state) });
  const stream = await opened(events);

  // First background change when quiet emits immediately.
  events.overviewSoon("move");
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, 1);

  // Burst of move + config + sessionRemoved within 10s coalesces overview, while session-removed still emits immediately.
  state.move.chats = ["c1"];
  events.overviewSoon("move");
  state.configTag = "b";
  events.overviewSoon("config");
  state.counts.sessions = 2;
  change({ type: "sessionRemoved", key: "s1", ws: "w" } as StoreChange);
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "session-removed").length, 1, "session-removed stays immediate");
  assert.equal(stream.got.filter((e) => e.event === "overview").length, 1, "burst overview held for 10s window");

  await time.adjust(10_000);
  await settle();
  const afterCoalesce = stream.got.filter((e) => e.event === "overview");
  assert.equal(afterCoalesce.length, 2, "single trailing overview after burst");
  assert.equal(afterCoalesce[1]!.data.counts.sessions, 2);
  assert.equal(afterCoalesce[1]!.data.configTag, "b");

  // Interleaving a background overviewSoon with an immediate overviewChanged flushes immediately and cancels the trailing timer.
  state.counts.running = 2;
  events.overviewSoon("processes");
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, 2);

  state.configTag = "c";
  events.overviewChanged("admin:network");
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, 3, "immediate admin trigger flushes right away");

  // Advancing 10s must not fire a redundant trailing push.
  await time.adjust(10_000);
  await settle();
  assert.equal(stream.got.filter((e) => e.event === "overview").length, 3, "cancelled trailing timer does not double-push");

  await stream.close();
});

/// `overviewComparable` as it was before it was serialized key by key: what it says must stay byte for byte the same.
function comparableBefore(value: unknown, previous?: string): string {
  const GiB = 1024 ** 3;
  const LOW = 10 * GiB, LOW_STEP = 512 * 1024 ** 2;
  const pctStep = (total: number) => Math.min(4 * GiB, Math.max(2 * GiB, Math.floor(total / 100)));
  const prevBucket = () => {
    if (previous === undefined) return null;
    try {
      const parsed = JSON.parse(previous);
      const disk = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? parsed.disk : null;
      if (disk === null || typeof disk !== "object" || Array.isArray(disk) || typeof disk.freeBytes !== "string") return null;
      const match = /^(low|pct):(-?\d+)$/.exec(disk.freeBytes);
      return match === null ? null : { regime: match[1], index: Number(match[2]), total: typeof disk.totalBytes === "number" ? disk.totalBytes : 0 };
    } catch {
      return null;
    }
  };
  const stepped = (regime: string, free: number, step: number) => {
    const prev = prevBucket();
    if (prev !== null && prev.regime === regime && (regime === "low" ? LOW_STEP : prev.total > 0 ? pctStep(prev.total) : 0) === step) {
      const margin = Math.floor(step / 4);
      if (free > prev.index * step - margin && free < (prev.index + 1) * step + margin) return `${regime}:${prev.index}`;
    }
    return `${regime}:${Math.floor(free / step)}`;
  };
  if (value === null || typeof value !== "object" || Array.isArray(value)) return JSON.stringify(value);
  const src = value as Record<string, any>;
  const out: Record<string, unknown> = { ...src };
  delete out.machine;
  const d = src.disk;
  if (d !== null && typeof d === "object" && !Array.isArray(d) && typeof d.freeBytes === "number") {
    const total = typeof d.totalBytes === "number" ? d.totalBytes : 0;
    const free = d.freeBytes;
    out.disk = { ...d, freeBytes: free <= LOW ? stepped("low", free, LOW_STEP) : total > 0 && free * 10 <= total ? stepped("pct", free, pctStep(total)) : "ok" };
  }
  if (Array.isArray(src.processes)) out.processes = src.processes.map((p: any) => (p === null || typeof p !== "object" || Array.isArray(p) ? p : (({ rssMb: _, ...rest }) => rest)(p)));
  const c = src.copies;
  if (c !== null && typeof c === "object" && !Array.isArray(c)) {
    const headTo = typeof c.to === "number" ? c.to : 0;
    const normTarget = (item: any) => {
      if (item === null || typeof item !== "object" || Array.isArray(item)) return item;
      const { to: tTo, at: tAt, ...rest } = item;
      const synced = typeof tTo === "number" && headTo > 0 ? tTo >= headTo : tTo === headTo;
      return { ...rest, synced, at: typeof tAt === "number" ? Math.floor(tAt / 600_000) : (tAt ?? null) };
    };
    const { to: _to, chats, ...restCopies } = c;
    const normCopies: Record<string, unknown> = { ...restCopies, hasData: headTo > 0, hasChats: typeof chats === "number" ? chats > 0 : (chats ?? null) };
    if (Array.isArray(c.keepers)) normCopies.keepers = c.keepers.map(normTarget);
    if (c.backup !== null && typeof c.backup === "object" && !Array.isArray(c.backup)) normCopies.backup = Array.isArray(c.backup.s3) ? { ...c.backup, s3: c.backup.s3.map(normTarget) } : c.backup;
    out.copies = normCopies;
  }
  return JSON.stringify(out);
}

test("overviewComparable says byte for byte what it said before it was serialized key by key", () => {
  const GiB = 1024 ** 3;
  const MiB = 1024 ** 2;
  const odd = { a: undefined, f: () => 1, s: Symbol("s"), nested: { x: undefined, y: [1, undefined, null, { z: undefined }], "q\"uote": "é\n " }, n: null, nan: Number.NaN, big: 1e21, neg: -0 };
  const samples: unknown[] = [
    null, undefined, 0, "text", true, [], [1, { a: 1 }], {},
    odd,
    { machine: { cpu: 9 }, counts: { running: 1 }, ...odd },
    { disk: { freeBytes: 8 * GiB - 1 * MiB, totalBytes: 100 * GiB, mount: "/" } },
    { disk: { freeBytes: 25 * GiB - 1 * MiB, totalBytes: 250 * GiB } },
    { disk: { freeBytes: 500 * GiB, totalBytes: 1000 * GiB } },
    { disk: { freeBytes: 8 * GiB, totalBytes: Number.POSITIVE_INFINITY } },
    { disk: { freeBytes: Number.NEGATIVE_INFINITY } },
    { disk: { freeBytes: "low:3", totalBytes: 1 } },
    { disk: null, processes: [{ key: "a", rssMb: 12, state: "running" }, null, [1], "x"] },
    { copies: { to: 9, chats: 3, keepers: [{ id: "k", to: 9, at: 1_234_567_890 }, { id: "l", to: 3 }, null], backup: { s3: [{ to: 10, at: "x" }], on: true } } },
    { copies: { to: undefined, chats: undefined, backup: { s3: "no" } } },
    { counts: { running: 2 }, gone: undefined, extra: [1] },
    { counts: { running: 1 }, toJSON: () => ({ said: "itself" }) },
  ];
  for (const value of samples) {
    const fresh = overviewComparable(value);
    assert.equal(fresh, comparableBefore(value), JSON.stringify(value));
    // Against itself and against the other samples told before it (hysteresis across regimes, malformed previous).
    for (const previous of [fresh, "not-json", ...samples.map((s) => overviewComparable(s))]) {
      if (typeof previous !== "string") continue;
      assert.equal(overviewComparable(value, previous), comparableBefore(value, previous));
    }
  }
  // What the memo says changed is what parsing both says, for every pair of samples (a whole one has no keys).
  for (const a of samples) {
    const memoA = overviewComparableMemo(a, null);
    assert.equal(memoA.text, overviewComparable(a));
    if (a !== null && typeof a === "object" && "toJSON" in a) assert.equal(memoA.keys, null, "told as a whole: changed keys are parsed");
    for (const b of samples) {
      const memoB = overviewComparableMemo(b, null);
      if (memoA.keys === null || memoB.keys === null) continue;
      assert.deepEqual(changedKeysFromMemos(memoA, memoB), overviewChangedKeys(memoA.text, memoB.text), `${JSON.stringify(a)} → ${JSON.stringify(b)}`);
    }
  }
  // A hysteresis walk: each told against the last, in the low and the percent regimes and across them.
  let now: string | undefined;
  let before: string | undefined;
  for (let i = 0; i < 400; i++) {
    const free = i < 200 ? 8 * GiB + ((i * 37) % 300) * MiB - 150 * MiB : 30 * GiB + ((i * 53) % 9000) * MiB - 4500 * MiB;
    const value = { counts: { running: i % 3 }, disk: { freeBytes: free, totalBytes: i % 7 === 0 ? 400 * GiB : 300 * GiB } };
    now = overviewComparable(value, now);
    before = comparableBefore(value, before);
    assert.equal(now, before, `step ${i}`);
  }
});

/// `JSON.parse` calls made by the station's events (not by the test reading what it is told), while `during` runs.
/// `by`: only those made under it (a function's name in the stack).
async function parsesIn(during: () => Promise<void>, by = /src[\\/]api[\\/]events\.ts/): Promise<number> {
  let parses = 0;
  const parse = JSON.parse;
  const spy = mock.method(JSON, "parse", function (this: unknown, ...args: Parameters<typeof JSON.parse>) {
    if (by.test(new Error().stack ?? "")) parses++;
    return parse.apply(this, args);
  });
  try {
    await during();
  } finally {
    spy.mock.restore();
  }
  return parses;
}

test("a viewer's overview is told against what it was told without parsing it again, hysteresis and changed keys as before", async () => {
  const time = testClock();
  const GiB = 1024 ** 3;
  const MiB = 1024 ** 2;
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const pushed: any[] = [];
  const info = mock.method(log, "info", (_at: string, words: string, fields?: any) => void (words === "overview pushed" && pushed.push(fields)));
  try {
    const state = { counts: { running: 1 }, move: { chats: [] as string[] }, disk: { freeBytes: 8 * GiB + 1 * MiB, totalBytes: 100 * GiB } };
    const before = setup(time.clock, { file, previous: previous() });
    before.events.follow({ overview: async () => structuredClone(state) });
    const stream = await opened(before.events);
    const told = () => stream.got.filter((e) => e.event === "overview").length;
    before.events.overviewChanged();
    await settle();
    assert.equal(told(), 1);

    // Within the low bucket's margin, and only telemetry moving: suppressed, nothing parsed.
    const quiet = await parsesIn(async () => {
      for (const free of [8 * GiB - 1 * MiB, 8 * GiB - 127 * MiB, 8 * GiB + 100 * MiB]) {
        state.disk.freeBytes = free;
        before.events.overviewChanged();
        await settle();
      }
    });
    assert.equal(quiet, 0, "suppressed tellings parse nothing");
    assert.equal(told(), 1, "hysteresis holds the bucket");

    // A field and, past the margin, the bucket change: told, its keys said, nothing parsed.
    pushed.length = 0;
    const changed = await parsesIn(async () => {
      state.counts.running = 2;
      before.events.overviewChanged("direct");
      await settle();
      state.disk.freeBytes = 8 * GiB - 128 * MiB;
      before.events.overviewChanged("direct");
      await settle();
      state.move.chats = ["c1"];
      state.disk.freeBytes = 8 * GiB - 1 * MiB;
      before.events.overviewChanged("direct");
      await settle();
    });
    assert.equal(changed, 0, "changed tellings parse nothing");
    assert.equal(told(), 4);
    assert.deepEqual(pushed.map((p) => p.changedKeys), [["counts"], ["disk"], ["move"]]);
    assert.ok(pushed.every((p) => p.viewers === 1 && p.suppressed === 0 && p.initial === 0));

    // Taken up by the next process: the first telling parses what was handed over, once; after that, nothing.
    const heard = stream.got.findLast((e) => e.id)!.id!;
    await before.events.handOver();
    const after = setup(time.clock, { file, previous: previous() }, before);
    after.events.follow({ overview: async () => structuredClone(state) });
    state.disk.freeBytes = 8 * GiB - 100 * MiB;
    let back!: Awaited<ReturnType<typeof opened>>;
    const first = await parsesIn(async () => {
      back = await opened(after.events, heard);
      await settle();
    }, /previousDiskBucket|overviewChangedKeys/);
    assert.equal(back.resumed, true);
    assert.equal(first, 1, "what was handed over is parsed once, for its disk bucket, as the stream comes back");
    const toldBack = () => back.got.filter((e) => e.event === "overview").length;
    assert.equal(toldBack(), 0, "handed-over hysteresis holds");
    const baseline = toldBack();
    pushed.length = 0;
    const quietBack = await parsesIn(async () => {
      after.events.overviewChanged();
      await settle();
    });
    assert.equal(quietBack, 0, "the suppressed telling after it made its memo");
    state.counts.running = 3;
    const then = await parsesIn(async () => {
      state.disk.freeBytes = 8 * GiB - 127 * MiB;
      after.events.overviewChanged();
      await settle();
      state.counts.running = 4;
      after.events.overviewChanged();
      await settle();
    });
    assert.equal(then, 0, "after the first telling nothing is parsed");
    assert.equal(toldBack(), baseline + 2);
    assert.deepEqual(pushed.map((p) => p.changedKeys), [["counts"], ["counts"]]);
    await stream.close();
    await back.close();
  } finally {
    info.mock.restore();
  }
});

/// `n` viewers' streams, each told an overview of its own.
async function manyViewers(events: Events, n: number) {
  const streams = [];
  for (let i = 0; i < n; i++) {
    const answer = await events.open(viewer(`v${i}@x`), "zh", false, [], [], null);
    streams.push(reader(answer.body as AsyncIterable<Buffer>));
  }
  await settle();
  return streams;
}

test("an overview told to many viewers is made a few at a time, the event loop let go between them", async () => {
  const { events } = setup(testClock().clock);
  const made: string[] = [];
  const between: number[] = [];
  events.follow({
    overview: async (v) => {
      // Something waiting for the event loop as the round begins runs before the round is through.
      if (made.length === 0) setImmediate(() => between.push(made.length));
      made.push(v.email);
      return { who: v.email };
    },
  });
  const n = 10;
  const streams = await manyViewers(events, n);
  made.length = 0;
  events.overviewChanged();
  await settle();
  assert.deepEqual(between, [OVERVIEW_VIEWER_BATCH], "the loop was let go after the first viewers");
  assert.equal(made.length, n);
  for (let i = 0; i < n; i++) {
    const told = streams[i]!.got.filter((e) => e.event === "overview");
    assert.deepEqual(told.map((e) => e.data), [{ who: `v${i}@x` }], `v${i}@x is told its own overview once`);
  }
  for (const s of streams) await s.close();
});

test("a handover while an overview is told to many viewers waits for all of them and hands each over", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const before = setup(time.clock, { file, previous: previous() });
  let release!: () => void;
  const held = new Promise<void>((r) => (release = r));
  let holding = false;
  before.events.follow({
    overview: async (v) => {
      // The second few wait: the round is under way as the handover begins.
      if (holding && v.email === `v${OVERVIEW_VIEWER_BATCH}@x`) await held;
      return { who: v.email };
    },
  });
  const n = 10;
  const streams = await manyViewers(before.events, n);
  holding = true;
  before.events.overviewChanged();
  await settle();
  const toldBy = () => streams.filter((s) => s.got.some((e) => e.event === "overview")).length;
  // The held one's few are told but for it; the next few are not begun.
  assert.equal(toldBy(), 2 * OVERVIEW_VIEWER_BATCH - 1, "the first few are told, the rest wait");
  let handed = false;
  const handing = before.events.handOver().then(() => void (handed = true));
  await settle();
  assert.equal(handed, false, "the handover waits for the round");
  release();
  await given(handing, "the handover is done once the round is");
  assert.equal(toldBy(), n, "every viewer was told before the handover");
  const written = JSON.parse(readFileSync(file, "utf8"));
  assert.equal(written.overviews.length, n, "each viewer's overview is handed over");
  assert.ok(written.overviews.every(([, text]: [string, string]) => /^\{"who":"v\d+@x"\}$/.test(text)));
  for (const s of streams) await s.close();
});

test("the first overview a taken-up stream is told, changed, says its changed keys from what was handed over, then parses nothing", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const pushed: any[] = [];
  const info = mock.method(log, "info", (_at: string, words: string, fields?: any) => void (words === "overview pushed" && pushed.push(fields)));
  try {
    const state = { counts: { running: 1 }, move: { chats: [] as string[] } };
    const before = setup(time.clock, { file, previous: previous() });
    before.events.follow({ overview: async () => structuredClone(state) });
    const lost = await opened(before.events);
    before.events.overviewChanged();
    await settle();
    const heard = lost.got.findLast((e) => e.id)!.id!;
    await before.events.handOver();

    const after = setup(time.clock, { file, previous: previous() }, before);
    after.events.follow({ overview: async () => structuredClone(state) });
    state.counts.running = 2;
    pushed.length = 0;
    let back!: Awaited<ReturnType<typeof opened>>;
    const first = await parsesIn(async () => {
      back = await opened(after.events, heard);
      await settle();
    }, /previousDiskBucket|overviewChangedKeys/);
    assert.equal(back.resumed, true);
    assert.equal(first, 3, "what was handed over is parsed once for its disk bucket, and with the new one for what changed");
    assert.deepEqual(back.got.filter((e) => e.event === "overview").map((e) => e.data.counts.running), [2]);
    assert.deepEqual(pushed.map((p) => p.changedKeys), [["counts"]]);

    pushed.length = 0;
    const then = await parsesIn(async () => {
      state.move.chats = ["c1"];
      after.events.overviewChanged();
      await settle();
    });
    assert.equal(then, 0, "the next round parses nothing");
    assert.deepEqual(pushed.map((p) => p.changedKeys), [["move"]]);
    await lost.close();
    await back.close();
  } finally {
    info.mock.restore();
  }
});

test("two devices of the same person track overview independently: reconnect order causes no push, and a lockDevice change pushes only to that device", async () => {
  const { events } = setup(testClock().clock);
  const locks = new Map<string, { base: string; proof: string }>([
    ["dev-a", { base: "base-a1", proof: "proof-a1" }],
    ["dev-b", { base: "base-b1", proof: "proof-b1" }],
  ]);
  const shared = { profiles: [{ id: "p1" }], counts: { running: 1 } };
  let sharedBuilds = 0;
  events.follow({
    overview: async (v, _lang, round) => {
      let body = round?.get("shared");
      if (body === undefined) {
        sharedBuilds++;
        body = shared;
        round?.set("shared", body);
      }
      return {
        ...(body as object),
        viewer: { via: "mesh", ...v, lockDevice: locks.get(v.device) },
      };
    },
  });
  const devAViewer = { ...viewer("a@x"), device: "dev-a", lockDevice: locks.get("dev-a") };
  const devBViewer = { ...viewer("a@x"), device: "dev-b", lockDevice: locks.get("dev-b") };
  const sA1 = reader((await events.open(devAViewer, "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  const sB = reader((await events.open(devBViewer, "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  events.overviewChanged();
  await settle();
  assert.equal(sharedBuilds, 1, "both devices share one round computation");
  assert.equal(sA1.got.filter((e) => e.event === "overview").length, 1);
  assert.equal(sB.got.filter((e) => e.event === "overview").length, 1);
  assert.equal(sA1.got.find((e) => e.event === "overview")!.data.viewer.device, "dev-a");
  assert.equal(sB.got.find((e) => e.event === "overview")!.data.viewer.device, "dev-b");

  // Reconnect dev-a behind dev-b so client order flips (dev-b is now first): neither device gets a spurious push.
  const heardA = sA1.got.findLast((e) => e.id)!.id!;
  await sA1.close();
  const sA2 = reader((await events.open(devAViewer, "zh", false, [], [], heardA)).body as AsyncIterable<Buffer>);
  await settle();
  assert.equal(sA2.got.filter((e) => e.event === "overview").length, 0, "reconnecting dev-a unchanged causes no push");
  events.overviewChanged();
  await settle();
  assert.equal(sA2.got.filter((e) => e.event === "overview").length, 0, "broadcast after client reorder causes no push to dev-a");
  assert.equal(sB.got.filter((e) => e.event === "overview").length, 1, "broadcast after client reorder causes no push to dev-b");

  // Only dev-a's lockDevice changes (e.g. approved in safe mode): pushed to dev-a alone, not dev-b.
  locks.set("dev-a", { base: "base-a2", proof: "proof-a2" });
  events.overviewChanged();
  await settle();
  const aUpdates = sA2.got.filter((e) => e.event === "overview");
  assert.equal(aUpdates.length, 1, "dev-a receives its lockDevice update");
  assert.deepEqual(aUpdates[0]!.data.viewer.lockDevice, { base: "base-a2", proof: "proof-a2" });
  assert.equal(sB.got.filter((e) => e.event === "overview").length, 1, "dev-b receives nothing when only dev-a's lockDevice changes");

  await sA2.close();
  await sB.close();
});

test("serializeRawOverview matches JSON.stringify byte for byte across edge cases", () => {
  const samples: unknown[] = [
    null, 0, "abc", true, [1, undefined, { a: 2 }], {},
    { machine: { cpu: 1 }, disk: { freeBytes: 123, totalBytes: 456 }, processes: [{ pid: 1, rssMb: 99 }], copies: { to: 5, chats: 2 }, counts: { running: 1 }, skip: undefined, fn: () => 1, sym: Symbol("x"), neg: -0, nan: Number.NaN },
    { counts: { running: 1 }, toJSON: () => ({ custom: true }) },
  ];
  for (const s of samples) {
    assert.equal(serializeRawOverview(s), JSON.stringify(s));
  }
});

test("large per-device overviews do not exhaust EventLog KEPT_BYTES and resuming across handover still catches missed overviews", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const big = "x".repeat(160_000);
  let count = 1;
  const before = setup(time.clock, { file, previous: previous() });
  before.events.follow({
    overview: async (v, _lang, round) => {
      let payload = round?.get("payload");
      if (payload === undefined) {
        payload = { big, counts: { running: count } };
        round?.set("payload", payload);
      }
      return { ...(payload as object), viewer: { via: "mesh", ...v } };
    },
  });
  // Open 60 devices (> 9.6 MB of overviews if pinned in EventLog, exceeding the 8 MB KEPT_BYTES cap).
  const streams: Awaited<ReturnType<typeof opened>>[] = [];
  for (let i = 0; i < 60; i++) {
    const v = { ...viewer(`u${i}@x`), device: `d${i}` };
    const ans = await before.events.open(v, "zh", false, [], [], null);
    streams.push({ resumed: false, ...reader(ans.body as AsyncIterable<Buffer>) });
  }
  before.change({ type: "session", key: "s1" });
  before.events.overviewChanged();
  await settle();
  // Capture an earlier id on device 0 before a second overview push, then close device 0 and keep a sibling stream open.
  const v0 = { ...viewer("u0@x"), device: "d0" };
  const heardBefore = streams[0]!.got.findLast((e) => e.id)!.id!;
  const sibling = reader((await before.events.open(v0, "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  await streams[0]!.close();
  count = 2;
  before.events.overviewChanged();
  await settle();
  assert.equal(sibling.got.filter((e) => e.event === "overview").length, 1);
  // Hand over to next process; device 0 resumes from heardBefore even though 60 x 160 KB overviews were sent.
  await before.events.handOver();
  const after = setup(time.clock, { file, previous: previous() }, before);
  after.events.follow({
    overview: async (v, _lang, round) => {
      let payload = round?.get("payload");
      if (payload === undefined) {
        payload = { big, counts: { running: count } };
        round?.set("payload", payload);
      }
      return { ...(payload as object), viewer: { via: "mesh", ...v } };
    },
  });
  const ansBack = await after.events.open(v0, "zh", false, [], [], heardBefore);
  assert.equal((ansBack.headers as Record<string, string>)["stillfail-resumed"], "1", "EventLog was not evicted by 60 x 160 KB overviews");
  const back = reader(ansBack.body as AsyncIterable<Buffer>);
  await settle();
  const ovs = back.got.filter((e) => e.event === "overview");
  assert.equal(ovs.length, 1, "resuming stream receives the missed overview after handover");
  assert.equal(ovs[0]!.data.counts.running, 2);
  await back.close();
  await sibling.close();
  for (let i = 1; i < streams.length; i++) await streams[i]!.close();
});

test("missed overview catch-up on resume emits a strictly increasing id and does not rewind Last-Event-ID", async () => {
  const { events, overview, change } = setup(testClock().clock);
  const v = { ...viewer("a@x"), device: "dev-mono" };
  const s1 = reader((await events.open(v, "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  change({ type: "session", key: "s1" });
  await settle();
  const heard1 = s1.got.findLast((e) => e.id)!.id!;
  const sibling = reader((await events.open(v, "zh", false, [], [], null)).body as AsyncIterable<Buffer>);
  await s1.close();

  // While s1 is disconnected: overview updates first (older seq), then thread entries arrive (newer seq).
  overview.running = 7;
  events.overviewChanged();
  await settle();
  change({ type: "thread", id: 9, entries: [{ n: 1 } as any] });
  await settle();
  const siblingOvsBefore = sibling.got.filter((e) => e.event === "overview").length;
  assert.equal(siblingOvsBefore, 1);

  // s1 resumes from heard1: receives replayed thread, then catch-up overview with strictly larger id.
  const s2 = reader((await events.open(v, "zh", false, [], [], heard1)).body as AsyncIterable<Buffer>);
  await settle();
  const seqs = s2.got.filter((e) => e.id).map((e) => Number(e.id!.split(".")[1]));
  assert.ok(seqs.length >= 2, `expected thread + overview events, got ${JSON.stringify(seqs)}`);
  for (let i = 1; i < seqs.length; i++) {
    assert.ok(seqs[i]! > seqs[i - 1]!, `expected strictly increasing ids, got ${JSON.stringify(seqs)}`);
  }
  assert.equal(s2.got.filter((e) => e.event === "thread").length, 1);
  assert.equal(s2.got.filter((e) => e.event === "overview").length, 1);
  assert.equal(sibling.got.filter((e) => e.event === "overview").length, siblingOvsBefore, "sibling does not get a duplicate overview");

  // Reconnecting again from s2's last id must not replay the thread event or push another overview.
  const heard2 = s2.got.findLast((e) => e.id)!.id!;
  await s2.close();
  const s3 = reader((await events.open(v, "zh", false, [], [], heard2)).body as AsyncIterable<Buffer>);
  await settle();
  assert.equal(s3.got.filter((e) => e.event === "thread").length, 0, "no duplicate thread replay after catch-up");
  assert.equal(s3.got.filter((e) => e.event === "overview").length, 0, "no duplicate overview after catch-up");

  await s3.close();
  await sibling.close();
});

test("legacy device-less handover keys are used on first compare and dropped on the next handover", async () => {
  const time = testClock();
  const file = join(mkdtempSync(join(tmpdir(), "events-")), "run", "events.json");
  const before = setup(time.clock, { file, previous: previous() });
  const s0 = await opened(before.events);
  before.events.overviewChanged();
  await settle();
  const heard = s0.got.findLast((e) => e.id)!.id!;
  await before.events.handOver();
  // Rewrite handed-over overviews to legacy 3-part viewerKey (without device), plus an offline legacy key.
  const legacy = JSON.parse(readFileSync(file, "utf8"));
  legacy.overviews = [
    ["a@x\0w\0zh", JSON.stringify({ running: 0 })],
    ["ghost@x\0w\0zh", JSON.stringify({ running: 0 })],
  ];
  delete legacy.overviewSeqs;
  writeFileSync(file, JSON.stringify(legacy));

  const after = setup(time.clock, { file, previous: previous() }, before);
  const back = await opened(after.events, heard);
  await settle();
  assert.equal(back.got.filter((e) => e.event === "overview").length, 0, "legacy key suppresses unchanged overview");
  await after.events.handOver();

  const nextHanded = JSON.parse(readFileSync(file, "utf8"));
  assert.ok(nextHanded.overviews.every(([k]: [string, string]) => k.split("\0").length === 4), `no legacy keys carried over: ${JSON.stringify(nextHanded.overviews)}`);
  assert.ok(nextHanded.overviews.some(([k]: [string, string]) => k === "a@x\0w\0zh\0d"));
  await s0.close();
  await back.close();
});

test("overviewPatch=1 emits full overview on baseline, then overview-patch with refreshed normalized fields, del, and null values", async () => {
  const { events } = setup(testClock().clock);
  const GiB = 1024 ** 3;
  const state: Record<string, any> = {
    counts: { sessions: 3, running: 1, warm: 2 },
    profiles: [{ id: "p1", name: "alpha" }],
    interrupted: { count: 2 },
    machine: { cpu: 10 },
    disk: { freeBytes: 50 * GiB, totalBytes: 100 * GiB },
    processes: [{ pgid: 42, runtime: "claude", rssMb: 120 }],
    copies: { to: 10, chats: 5, keepers: [{ id: "k1", to: 10, at: 60_000 }] },
  };
  events.follow({ overview: async () => structuredClone(state) });
  const v = { ...viewer("a@x"), device: "dev-mix" };
  const optedIn = reader((await events.open(v, "zh", false, [], [], null, false, [], false, null, true)).body as AsyncIterable<Buffer>);
  const legacy = reader((await events.open(v, "zh", false, [], [], null, false, [], false, null, false)).body as AsyncIterable<Buffer>);

  // Initial push: both streams receive full `overview` to establish baseline.
  events.overviewChanged();
  await settle();
  assert.equal(optedIn.got.filter((e) => e.event === "overview").length, 1);
  assert.equal(optedIn.got.filter((e) => e.event === "overview-patch").length, 0);
  assert.equal(legacy.got.filter((e) => e.event === "overview").length, 1);

  // Only `counts` changes comparably, `interrupted` disappears, and normalized/stripped fields move within their buckets.
  state.counts.running = 2;
  delete state.interrupted;
  state.machine.cpu = 77;
  state.disk.freeBytes = 49 * GiB;
  state.processes[0].rssMb = 345;
  state.copies.to = 12;
  state.copies.keepers[0].to = 12;
  events.overviewChanged();
  await settle();

  const patches = optedIn.got.filter((e) => e.event === "overview-patch");
  assert.equal(patches.length, 1, "opted-in stream gets overview-patch");
  assert.equal(optedIn.got.filter((e) => e.event === "overview").length, 1, "opted-in stream does not get full overview");
  assert.equal(legacy.got.filter((e) => e.event === "overview").length, 2, "legacy stream still gets full overview");
  assert.equal(legacy.got.filter((e) => e.event === "overview-patch").length, 0);
  assert.deepEqual(patches[0]!.data.set.counts, { sessions: 3, running: 2, warm: 2 });
  assert.equal(patches[0]!.data.set.profiles, undefined, "unchanged large keys omitted from patch");
  assert.deepEqual(patches[0]!.data.del, ["interrupted"]);
  assert.equal(patches[0]!.data.set.processes[0].rssMb, 345, "processes[].rssMb refreshed with latest raw value");
  assert.equal(patches[0]!.data.set.disk.freeBytes, 49 * GiB, "disk.freeBytes refreshed with latest raw value");
  assert.equal(patches[0]!.data.set.copies.to, 12, "copies progress refreshed with latest raw value");
  assert.equal(patches[0]!.data.set.machine.cpu, 77, "machine refreshed with latest raw value");

  // Legitimate top-level `null` value goes into `set`, never `del`.
  state.disk = null;
  events.overviewChanged();
  await settle();
  const patch2 = optedIn.got.filter((e) => e.event === "overview-patch")[1]!;
  assert.equal(patch2.data.set.disk, null);
  assert.equal(patch2.data.del, undefined);

  await optedIn.close();
  await legacy.close();
});

test("same-device afresh stream resets memo so opted-in sibling receives full overview before patches resume", async () => {
  const { events } = setup(testClock().clock);
  const state = { counts: { running: 1 }, profiles: [{ id: "p1" }] };
  events.follow({ overview: async () => structuredClone(state) });
  const v = { ...viewer("a@x"), device: "dev-tabs" };

  const tab1 = reader((await events.open(v, "zh", false, [], [], null, false, [], false, null, true)).body as AsyncIterable<Buffer>);
  events.overviewChanged();
  await settle();
  assert.equal(tab1.got.filter((e) => e.event === "overview").length, 1);

  state.counts.running = 2;
  events.overviewChanged();
  await settle();
  assert.equal(tab1.got.filter((e) => e.event === "overview-patch").length, 1);

  // Second tab on the same device connects afresh (`since = null`), clearing the shared device memo.
  const tab2 = reader((await events.open(v, "zh", false, [], [], null, false, [], false, null, true)).body as AsyncIterable<Buffer>);
  state.counts.running = 3;
  events.overviewChanged();
  await settle();
  assert.equal(tab1.got.filter((e) => e.event === "overview").length, 2, "tab1 receives full overview after afresh reset");
  assert.equal(tab1.got.filter((e) => e.event === "overview-patch").length, 1, "tab1 does not receive a patch against stale memo");
  assert.equal(tab2.got.filter((e) => e.event === "overview").length, 1, "tab2 receives full overview");
  assert.equal(tab2.got.filter((e) => e.event === "overview-patch").length, 0);

  // Subsequent change goes back to overview-patch for both tabs.
  state.counts.running = 4;
  events.overviewChanged();
  await settle();
  assert.equal(tab1.got.filter((e) => e.event === "overview-patch").length, 2);
  assert.equal(tab2.got.filter((e) => e.event === "overview-patch").length, 1);

  await tab1.close();
  await tab2.close();
});

test("resuming overviewPatch stream gets full overview first (never replayed patches) with id above replayed events", async () => {
  const { events, change } = setup(testClock().clock);
  const state: Record<string, any> = { counts: { running: 1 }, profiles: [{ id: "p1" }] };
  events.follow({ overview: async () => structuredClone(state) });
  const v = { ...viewer("a@x"), device: "dev-resume-patch" };

  const s1 = reader((await events.open(v, "zh", false, [], [], null, false, [], false, null, true)).body as AsyncIterable<Buffer>);
  events.overviewChanged();
  await settle();
  const heard1 = s1.got.findLast((e) => e.id)!.id!;
  const sibling = reader((await events.open(v, "zh", false, [], [], heard1, false, [], false, null, true)).body as AsyncIterable<Buffer>);
  await s1.close();

  // While s1 is disconnected: two overview-patches happen interleaved with two thread events.
  state.profiles = [{ id: "p1" }, { id: "p2" }];
  events.overviewChanged();
  await settle();
  change({ type: "thread", id: 9, entries: [{ n: 1 } as any] });
  await settle();
  state.counts.running = 5;
  events.overviewChanged();
  await settle();
  change({ type: "thread", id: 9, entries: [{ n: 2 } as any] });
  await settle();
  assert.equal(sibling.got.filter((e) => e.event === "overview-patch").length, 2, "connected sibling received both patches");
  const siblingFullBefore = sibling.got.filter((e) => e.event === "overview").length;

  // s1 resumes from heard1: replays both thread events, 0 patches, then full overview with id > all replayed ids.
  const s2 = reader((await events.open(v, "zh", false, [], [], heard1, false, [], false, null, true)).body as AsyncIterable<Buffer>);
  await settle();
  assert.equal(s2.got.filter((e) => e.event === "thread").length, 2);
  assert.equal(s2.got.filter((e) => e.event === "overview-patch").length, 0, "missed patches are never replayed");
  const ovEvents = s2.got.filter((e) => e.event === "overview" || e.event === "overview-patch");
  assert.equal(ovEvents.length, 1);
  assert.equal(ovEvents[0]!.event, "overview", "first overview-related event on resume is full overview");
  assert.deepEqual(ovEvents[0]!.data, state, "catch-up overview includes all changes missed while offline");
  const seqs = s2.got.filter((e) => e.id).map((e) => Number(e.id!.split(".")[1]));
  for (let i = 1; i < seqs.length; i++) {
    assert.ok(seqs[i]! > seqs[i - 1]!, `strictly increasing ids expected, got ${JSON.stringify(seqs)}`);
  }
  assert.equal(sibling.got.filter((e) => e.event === "overview").length, siblingFullBefore);

  // Subsequent change sends overview-patch to both s2 and sibling.
  state.counts.running = 6;
  events.overviewChanged();
  await settle();
  assert.equal(s2.got.filter((e) => e.event === "overview-patch").length, 1);
  assert.equal(sibling.got.filter((e) => e.event === "overview-patch").length, 3);

  await s2.close();
  await sibling.close();
});

test("GET /events route enables overviewPatch only for clients advertising full runtimes and profile services", async () => {
  const { routes } = await import("../src/api/routes/events.ts");
  const { RUNTIME_KINDS } = await import("../src/agents/runtime.ts");
  const calls: boolean[] = [];
  const fakeEvents = {
    open: async (...args: any[]) => {
      calls.push(Boolean(args[10]));
      return { status: 200, headers: {}, body: Buffer.from("") };
    },
  } as any;
  const route = routes({ events: fakeEvents, sessionExists: () => true } as any)[0]!;
  const baseReq = {
    method: "GET",
    path: "/events",
    query: [["overviewPatch", "1"]] as [string, string][],
    viewer: viewer("a@x"),
    lang: "zh" as const,
    body: Buffer.from(""),
  };
  // Legacy core (no runtime/profile-services headers): stays full overview.
  await route.handle({ ...baseReq, headers: {} }, []);
  // Core missing profile-services header: stays full overview.
  await route.handle({ ...baseReq, headers: { "stillfail-runtimes": RUNTIME_KINDS.join(",") } }, []);
  // Full modern core without overviewPatch=1: stays full overview.
  await route.handle({ ...baseReq, query: [], headers: { "stillfail-runtimes": RUNTIME_KINDS.join(","), "stillfail-profile-services": "1" } }, []);
  // Full modern core with overviewPatch=1: enabled.
  await route.handle({ ...baseReq, headers: { "stillfail-runtimes": RUNTIME_KINDS.join(","), "stillfail-profile-services": "1" } }, []);
  assert.deepEqual(calls, [false, false, false, true]);
});
