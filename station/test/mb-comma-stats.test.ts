// The Comma indexes by the MoonBit program (`--builder comma-stats`, station/mb/src/comma; the station's
// src/comma/stats.ts) held to the TypeScript it replaced (test/reference/comma-stats.ts) on the same input: the same
// rows (keys and JSON byte for byte: every station's usage and chats, titles and notes cut by code points, emails
// lowercased as JavaScript does and kept once, a row gone tombstoned, an unread station's kept), the same build through
// the age index (its batches, a writer that keeps dirtying rows, ACTIVE_REPAIR_TURNS), the same pages (PAGE_BYTES,
// PAGE_ROWS, rows of one revision never split), the same titles; and what is each connection's kept by the station,
// so a program let go and started again between pages prunes no tombstone another connection still needs.
import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { wall } from "../src/ops/fibers.ts";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { CommaStats, IDLE_MS, type Held, type IndexFollower, type Page, type StationRows } from "../src/comma/stats.ts";
import { CommaStats as RefStats, IndexSync as RefSync, type RevIndex as RefIndex, statsWire, taskWire } from "./reference/comma-stats.ts";

type Json = any;
const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program is not built here" : false;
const DAY = 24 * 60 * 60_000;
const quiet = () => () => {};
const nothing = async () => ({ stations: [], unread: [] });

const dirs: string[] = [];
after(() => { for (const d of dirs) rmSync(d, { recursive: true, force: true }); });
const tempdir = () => { const d = mkdtempSync(join(tmpdir(), "mb-comma-stats-")); dirs.push(d); return d; };

/// A day `n` days before now (UTC), as the stations name it.
const dayAgo = (n: number) => new Date(wall.now() - n * DAY).toISOString().slice(0, 10);

const emoji = "😀";
const long = (n: number) => Array.from({ length: n }, (_, i) => (i % 3 === 1 ? emoji : String.fromCharCode(0x61 + (i % 26)))).join("");

/// Every station's usage and chats, with what the rows' rules turn on.
function stations(round: number): StationRows[] {
  const usage = (day: string, session: string, person: unknown, extra: Json = {}) =>
    ({ day, session, thread: 7, person, account: "cc", runtime: "claude", model: "claude-opus-5-5", calls: 1 + round, input: 10, cacheRead: 0, cacheWrite: 0, output: 5, cost: 0.1 + 0.2, ...extra });
  const people = {
    "p:ada": { name: "Ada", email: "Ada@X.com", via: "feishu" },
    "p:bo": { name: "Bo", email: "", via: "slack" },
    "p:nameless": { name: "", email: null },
    "p:😀": { email: "smile@x" },
  };
  const attention = (kind: unknown, waitsFor: unknown, note?: unknown) => ({ kind, waitsFor, ...(note === undefined ? {} : { note }) });
  const chat = (thread: unknown, extra: Json = {}) => ({ thread, surface: "stillfail", title: `Chat ${String(thread)}`, state: "working",
    creator: { ref: "ann@x", name: null, email: "ann@x" }, createdAt: 1_700_000_000_000, lastActiveAt: 1_700_000_000_500 + round, archived: false,
    agents: [{ runtime: "claude", model: "claude-opus-5-5" }], ...extra });
  const here: StationRows = {
    usage: { people, rows: [
      usage(dayAgo(1), "s1", "p:ada"),
      usage(dayAgo(1), "s1", "p:ada", { calls: 99 }), // the same key again: its place kept, the later row taken
      usage(dayAgo(2), "s2", "p:bo"),
      usage(dayAgo(2), "s3", "p:nameless"),
      usage(dayAgo(3), "s4", null, { account: null, model: null }),
      usage(dayAgo(3), "s5", undefined, { cost: undefined, input: undefined }),
      usage(dayAgo(3), "s6", "toString"),
      usage(dayAgo(3), "s7", "constructor"),
      usage(dayAgo(3), "s8", "__proto__"),
      usage(dayAgo(4), `s${emoji}\ud800`, "p:😀", { model: "a\u0000b", calls: 1e21, cacheRead: 5e-324, output: -0 }),
      usage(dayAgo(40), "too-old", "p:ada"),
      usage("not-a-day", "odd", "p:ada"),
      { day: dayAgo(1), runtime: "claude" }, // no session: not a row
      ...(round === 0 ? [usage(dayAgo(5), "dropped-later", "p:ada")] : []),
    ] },
    chats: [
      chat(1, { title: long(130), state: "need_human" }),
      chat(2, { title: `a\ud800b${emoji}`, state: "all_done", creator: "plain string" }),
      chat(3, { state: "ended", creator: null, agents: [] }),
      chat(4, { archived: true, attention: attention("need", ["ann@x"]) }),
      chat(5, { attention: attention("need", [" ANN@X.com ", "ann@x.com", "bad", "a@b@c", "x @y", 7, "ÄNN@X.COM", "İ@x", "ΑΣ@Σ.x",
        "a1@x", "a2@x", "a3@x", "a4@x", "a5@x", "a6@x", `${"z".repeat(199)}@x`], `  ${long(400)}  `), url: "https://app.example/c/5", router: true }),
      chat(6, { attention: attention("done", "not an array", "   "), url: "http://plain", router: "true" }),
      chat(7, { attention: attention("other", ["a@b"]), url: `https://${"x".repeat(500)}` }),
      chat(8, { attention: attention("failed", [], 12), agents: [{ runtime: "r".repeat(50), model: long(150) }], title: "" }),
      chat(9, { title: undefined, surface: undefined, state: undefined, createdAt: undefined, lastActiveAt: undefined, agents: undefined }),
      chat(10, { lastActiveAt: undefined, createdAt: 42, agents: ["not an agent"] }),
      chat(11.5, { title: "a fractional thread" }),
      chat("12", { title: "not a number" }),
      ...(round === 0 ? [chat(13, { title: "gone later" })] : []),
    ],
  };
  const there: StationRows = { station: "st-there", usage: { people: {}, rows: [usage(dayAgo(2), "b", "ann@x"), usage(dayAgo(2), "c", "ann@x")] },
    chats: [chat(3, { state: "all_done" }), ...(round === 0 ? [chat(4, { title: "kept while unread" })] : [])] };
  const smile: StationRows = { station: `st-${emoji}`, usage: { rows: [usage(dayAgo(1), "e", "p:ada")], people }, chats: [chat(1)] };
  return round === 0 ? [here, there, smile] : [here, smile];
}

/// Both indexes' rows as each keeps them.
async function mbRows(stats: CommaStats) {
  return { stats: await stats.stats.since(0, 100_000), tasks: await stats.tasks.since(0, 100_000) };
}
function refRows(stats: RefStats) {
  return { stats: stats.stats.since(0, 100_000), tasks: stats.tasks.since(0, 100_000) };
}

test("the program's rows are the TypeScript's, byte for byte, through changes, drops and an unread station", { skip }, async () => {
  const dir = tempdir();
  const reference = new RefStats(join(dir, "ref.db"), nothing, quiet);
  const program = new CommaStats(join(dir, "mb.db"), nothing, quiet, { binary: binary! });
  try {
    const from = wall.now() - 31 * DAY;
    for (const [round, unread] of [[0, []], [1, ["st-there"]], [1, []]] as const) {
      const given = stations(round);
      assert.deepEqual(await program.apply(given, [...unread], from), reference.apply(given, [...unread], from), `round ${round} changed alike`);
      assert.deepEqual(await mbRows(program), refRows(reference), `round ${round}`);
    }
    const tasks = refRows(reference).tasks.map((row) => JSON.parse(row.json));
    const five = tasks.find((t) => t.task === "5");
    assert.deepEqual(five.waits_for, ["ann@x.com", "änn@x.com", "i̇@x", "ας@σ.x", "a1@x", "a2@x", "a3@x", "a4@x"], "lowercased as JavaScript does, once each, at most 8");
    assert.equal([...tasks.find((t) => t.task === "1").title].length, 120);
    for (const ref of ["1", "2", "5", "8", "3@st-there", `1@st-${emoji}`, "13", "nope", "5\ud800"]) {
      assert.equal(await program.taskTitle(ref), reference.taskTitle(ref), `title of ${ref}`);
    }
  } finally { reference.close(); await program.close(); }
});

test("a build through the age index is the TypeScript's, its old rows read a batch a turn", { skip }, async () => {
  const dir = tempdir();
  const seed = new RefStats(join(dir, "seed.db"), nothing, quiet);
  // Old history enough for the age index to be used (256 small bodies of days before the build's), and some recent.
  const old = Array.from({ length: 300 }, (_, i) => ({ day: dayAgo(60 + (i % 20)), session: `old${i}`, person: null, account: null, runtime: "claude", model: null, calls: i }));
  seed.apply([{ usage: { rows: old, people: {} }, chats: [] }], [], 0);
  seed.close();
  copyFileSync(join(dir, "seed.db"), join(dir, "ref.db"));
  copyFileSync(join(dir, "seed.db"), join(dir, "mb.db"));
  const given = stations(0);
  const read = async () => ({ stations: given, unread: [] });
  const reference = new RefStats(join(dir, "ref.db"), read, quiet);
  const program = new CommaStats(join(dir, "mb.db"), read, quiet, { binary: binary! });
  try {
    reference.build(); await reference.settled();
    program.build(); await program.settled();
    assert.deepEqual(await mbRows(program), refRows(reference));
    const ages = (path: string) => {
      const db = new DatabaseSync(path);
      try { return db.prepare("SELECT id, generation, kind, day FROM comma_stats_age ORDER BY id").all(); } finally { db.close(); }
    };
    assert.deepEqual(ages(join(dir, "mb.db")), ages(join(dir, "ref.db")), "the age index classified alike");
    // A second build with rows gone: the same tombstones, through the candidates the age index gives.
    given.splice(1, 2);
    reference.build(); await reference.settled();
    program.build(); await program.settled();
    assert.deepEqual(await mbRows(program), refRows(reference));
  } finally { reference.close(); await program.close(); }
});

/// The program itself, asked line by line (what CommaStats asks it).
function raw(path: string) {
  const child = new MbProcess(binary!, ["--builder", "comma-stats", "--db", path]);
  let next = 0;
  const waiting = new Map<number, (answer: Json) => void>();
  child.on("message", (answer: Json) => { waiting.get(answer.id)?.(answer); waiting.delete(answer.id); });
  return {
    ask: (op: string, args: Json = {}) => new Promise<Json>((resolve) => { const id = ++next; waiting.set(id, resolve); child.postMessage({ ...args, id, op }); }),
    close: () => child.terminate(),
  };
}

test("a writer that keeps dirtying old rows cannot hold a build off: after ACTIVE_REPAIR_TURNS it is written", { skip }, async () => {
  const dir = tempdir(), path = join(dir, "mb.db");
  const seed = new RefStats(path, nothing, quiet);
  const old = Array.from({ length: 600 }, (_, i) => ({ day: dayAgo(60 + (i % 20)), session: `old${i}`, person: null, account: null, runtime: "claude", model: null, calls: i }));
  seed.apply([{ usage: { rows: old, people: {} }, chats: [] }], [], 0);
  seed.close();
  copyFileSync(path, join(dir, "ref.db"));
  const writer = new DatabaseSync(path);
  const p = raw(path);
  try {
    const fromDay = dayAgo(31);
    let got = await p.ask("build", { build: 1, stations: stations(0), unread: [], fromDay });
    let turns = 1;
    // Classify the old rows until only the dirty ones are left, then keep dirtying one each turn.
    while (got.done !== true) {
      writer.prepare("UPDATE stats_index SET json = json WHERE rowid = ?").run(1 + (turns % 50));
      got = await p.ask("turn", { build: 1 });
      turns++;
      assert.ok(turns < 40, "the build finished despite the writer");
    }
    assert.equal(got.error, undefined);
    assert.ok(turns > 10, `the old rows were classified over turns, then ACTIVE_REPAIR_TURNS more (${turns})`);
    assert.ok(got.stats > 0);
  } finally { await p.close(); writer.close(); }
  // The same rows as the TypeScript writes them, the old ones read whole.
  const reference = new RefStats(join(dir, "ref.db"), nothing, quiet);
  const written = new CommaStats(path, nothing, quiet, { binary: binary! });
  try {
    reference.apply(stations(0), [], wall.now() - 31 * DAY);
    assert.deepEqual(await mbRows(written), refRows(reference));
  } finally { reference.close(); await written.close(); }
});

/// Comma's copy as a connection's pages make it.
function copy() {
  const rows = new Map<string, Json>();
  let held: Held = { epoch: null, through: 0 };
  return {
    get held() { return held; },
    apply(page: Page): Held {
      if (page.reset) rows.clear();
      for (const row of page.rows) {
        const key = row.key ?? row.thread;
        if (row.removed) rows.delete(key); else rows.set(key, row);
      }
      held = { epoch: page.epoch, through: page.through };
      return held;
    },
    rows,
  };
}

async function follow(next: (held: Held) => Promise<Page | null> | Page | null, c: ReturnType<typeof copy>): Promise<Page[]> {
  const pages: Page[] = [];
  for (let page = await next(c.held); page !== null; page = await next(c.held)) {
    pages.push(page);
    c.apply(page);
    assert.ok(pages.length < 500);
  }
  return pages;
}

test("the program's pages are the TypeScript's: PAGE_BYTES, PAGE_ROWS, learnt row limits and one revision never split", { skip }, async () => {
  const dir = tempdir();
  const reference = new RefStats(join(dir, "ref.db"), nothing, quiet);
  // Large bodies (each stats row carries its chat's agents), small ones after, and many rows.
  const chats = Array.from({ length: 450 }, (_, i) => ({ thread: i + 1, title: i < 40 ? "x".repeat(9000) : `small ${emoji}`,
    agents: i < 40 ? Array.from({ length: 60 }, (_, j) => ({ runtime: "claude", model: `m${j}` })) : [] }));
  reference.apply([{ usage: { rows: [], people: {} }, chats }], [], 0);
  const db = new DatabaseSync(join(dir, "ref.db"));
  // Rows of one revision past an adaptive boundary, as an older writer can leave them.
  const rev = Number((db.prepare("SELECT value FROM meta WHERE key = 'stats_index.rev'").get() as Json).value);
  const put = db.prepare("INSERT INTO stats_index (key, source, kind, rev, json) VALUES (?, 'stillfail', 'task', ?, ?)");
  for (let i = 0; i < 30; i++) put.run(`same-${i}`, rev + 1, JSON.stringify({ thread: 1000 + i, title: i < 3 ? "y".repeat(20_000) : "z" }));
  db.prepare("UPDATE meta SET value = ? WHERE key = 'stats_index.rev'").run(String(rev + 1));
  db.close();
  reference.stats.epoch(); reference.tasks.epoch();
  reference.close();
  copyFileSync(join(dir, "ref.db"), join(dir, "mb.db"));
  const ref = new RefStats(join(dir, "ref.db"), nothing, quiet);
  const program = new CommaStats(join(dir, "mb.db"), nothing, quiet, { binary: binary! });
  try {
    for (const [name, wire] of [["stats", statsWire], ["task", taskWire]] as const) {
      const refIndex: RefIndex = name === "stats" ? ref.stats : ref.tasks;
      const mbIndex = name === "stats" ? program.stats : program.tasks;
      const refSync = new RefSync(refIndex, wire);
      const mbSync: IndexFollower = await mbIndex.follow(name);
      const a = copy(), b = copy();
      const expected = await follow((held) => refSync.next(held), a);
      const got = await follow((held) => mbSync.next(held), b);
      assert.deepEqual(got, expected, `${name} pages`);
      assert.ok(expected.length > (name === "stats" ? 8 : 2));
      assert.ok(expected.every((page) => page.rows.length <= 200 && Buffer.byteLength(JSON.stringify(page.rows)) <= 60 * 1024 || page.rows.length === 1));
      // Changed alike, then paged on from what each holds.
      const changed = [{ usage: { rows: [], people: {} }, chats: chats.slice(100) }];
      assert.deepEqual(await program.apply(changed, [], 0), ref.apply(changed, [], 0));
      assert.deepEqual(await follow((held) => mbSync.next(held), b), await follow((held) => refSync.next(held), a), `${name} pages after a change`);
      assert.deepEqual([...b.rows.keys()], [...a.rows.keys()]);
      assert.deepEqual(await mbIndex.probe(), { epoch: a.held.epoch, reset: false, since: a.held.through, through: a.held.through, rows: [] });
      mbSync.close(); refSync.close();
    }
  } finally { ref.close(); await program.close(); }
});

/// Timers of the test's: `fire(ms)` fires those of `ms` armed and not called off.
function timers() {
  const armed: { ms: number; f: () => void; live: boolean }[] = [];
  return {
    after: (ms: number, f: () => void) => { const t = { ms, f, live: true }; armed.push(t); return () => { t.live = false; }; },
    fire(ms: number) { let n = 0; for (const t of armed.splice(0)) if (t.live && t.ms === ms) { t.f(); n++; } else if (t.live) armed.push(t); return n; },
  };
}

test("what each connection holds is the station's: a program let go between pages prunes no tombstone another still needs", { skip }, async () => {
  const dir = tempdir();
  const clock = timers();
  const stats = new CommaStats(join(dir, "mb.db"), nothing, quiet, { binary: binary!, after: clock.after });
  try {
    const chats = (n: number) => [{ usage: { rows: [], people: {} }, chats: Array.from({ length: n }, (_, i) => ({ thread: i + 1, title: `t${i}` })) }];
    await stats.apply(chats(3), [], 0);
    const first = await stats.tasks.follow("task"), second = await stats.tasks.follow("task");
    const a = copy(), b = copy();
    await follow((held) => first.next(held), a);
    await follow((held) => second.next(held), b);
    // Thread 3 goes: a tombstone both copies need.
    await stats.apply(chats(2), [], 0);
    // The program is let go (trimmed, then idle) and started again between the two connections' pages.
    assert.equal(stats.trimIdle(), 1);
    assert.equal(stats.running, false);
    await follow((held) => first.next(held), a);
    assert.equal(a.rows.has("3"), false);
    assert.equal(clock.fire(IDLE_MS), 1);
    assert.equal(stats.running, false, "let go once idle");
    const pages = await follow((held) => second.next(held), b);
    assert.deepEqual(pages.flatMap((p) => p.rows).map((r) => [r.thread, r.removed]), [["3", true]], "the second connection is told the chat went");
    assert.deepEqual([...b.rows.keys()], ["1", "2"]);
    assert.equal(pages.some((p) => p.reset), false, "nothing it needed was pruned: no reset");
    // Once both hold it, the tombstone goes.
    assert.equal((await stats.tasks.since(0, 100)).some((r) => r.removed), false);
    assert.ok(stats.started >= 3);
    first.close(); second.close();
  } finally { await stats.close(); }
});

test("a build under way keeps its program; nothing asked, it goes", { skip }, async () => {
  const dir = tempdir();
  const clock = timers();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const stats = new CommaStats(join(dir, "mb.db"), async () => { await gate; return { stations: stations(0), unread: [] }; }, quiet, { binary: binary!, after: clock.after });
  try {
    await stats.stats.probe();
    stats.build();
    assert.equal(stats.trimIdle(), 0, "a build under way");
    release();
    await stats.settled();
    assert.equal(stats.trimIdle(), 1);
    assert.equal(await stats.taskTitle("1"), [...long(130)].slice(0, 120).join(""));
  } finally { await stats.close(); }
});

test("the indexes take nothing on the station's thread: no SQLite but the Router's one table of before", () => {
  const src = new URL("../src/comma/", import.meta.url);
  const sqlite = readdirSync(src).filter((f) => f.endsWith(".ts") && readFileSync(new URL(f, src), "utf8").includes("node:sqlite"));
  assert.deepEqual(sqlite, ["legacy-said.ts"]);
  const legacy = readFileSync(new URL("legacy-said.ts", src), "utf8");
  assert.doesNotMatch(legacy, /stats_index|task_index|comma_stats_age/);
  const stats = readFileSync(new URL("stats.ts", src), "utf8");
  assert.doesNotMatch(stats, /"node:fs"|(readFile|writeFile|exists|mkdir|stat|readdir|open|rename|unlink|rm|copyFile)Sync\(/, "no synchronous file system call");
});
