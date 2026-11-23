// What a migration's plan is (move/scheduler.ts `plan`, over the modules move/station.ts makes) on a station with every
// case the chats plan knows, held to a dump of it as it was before its reads went by pages (each item: module, id,
// label, needs, cannot, state, wouldStop), so that how it reads never changes what it says; and what it costs on a
// station of the real one's shape (move-world.ts `officeShape`): its statements a page of chats whatever their number,
// each by an index, and the main thread given back between pages.
import assert from "node:assert/strict";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { DatabaseSync, type SQLInputValue, StatementSync } from "node:sqlite";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { join } from "node:path";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { MANUAL, comingWs } from "../src/store/rows.ts";
import { PLAN_PAGE } from "../src/move/chats.ts";
import { A, B, WS, officeShape, stillfailChat, world } from "./move-world.ts";

type Json = any;
const require = createRequire(import.meta.url);

/// A's chats and accounts with every case a plan knows (keys and paths fixed, so the dump says the same each run).
function cases() {
  const w = world();
  const a = w.get(A);
  const store = a.rig.store;
  const room = (n: string) => join(a.rig.dir, "sessions", n, "workspace");
  a.rig.raw.profiles.push(
    { id: "bor", runtime: "claude", home: "homes/bor", share: { id: "sh-b", borrowed: true, host: B } },
    { id: "solo", runtime: "claude", home: "homes/solo" },
  );
  a.rig.raw.connects.push(
    { id: "team", mode: "single-session", bind: { runtime: "claude" } },
    { id: "cm", comma: { token: "t" }, bind: { runtime: "claude" } },
  );
  let n = 0;
  const chat = (key: string, o: { connect?: string; profile?: string; ws?: string | null; workspace?: string; title?: string; surface?: string; ts?: string; home?: boolean; ran?: string[] } = {}) => {
    const i = n++;
    const connect = o.connect ?? "cl";
    store.insertSession({ key, connect, runtime: "claude", profile: o.profile ?? "cc", workspace: o.workspace ?? room(`s${i}`), token: `tok${i}`, createdAt: 1, lastActiveAt: 1, ws: o.ws === undefined ? null : o.ws, ...(o.title ? { title: o.title } : {}) });
    const ts = o.ts ?? `${1700000000 + i}.000100`;
    const t = store.openThreadOf(o.surface ?? "slack:T1", o.surface === "ember" ? "CHAT" : "C1", ts, null, "p@x", o.home === true ? key : null);
    store.joinThread(t.id, key, connect === "ember" ? "ember" : connect);
    for (const r of o.ran ?? []) store.ranIn(key, `run-${key}-${r}`, r);
    return t;
  };
  chat(sessionKey("cl", "C1", "1.1"), { title: "a Slack thread", ts: "1.1", ran: ["cx"] });
  chat(sessionKey("cl", "C1", "1.2"), { ts: "1.2", ws: WS, profile: "bor" });
  chat(sessionKey("gpt", "C1", "1.3"), { connect: "gpt", ts: "1.3", profile: "mine" });
  chat(sessionKey("cl", "C1", "1.4"), { ts: "1.4", workspace: "/elsewhere/proj" });
  const archived = sessionKey("cl", "C1", "1.5");
  chat(archived, { ts: "1.5", workspace: "/elsewhere/old" });
  store.setArchived(archived, true, MANUAL);
  chat("team:all", { connect: "team", ts: "1.6", profile: "solo" });
  chat(sessionKey("cm", "C9", "1.7"), { connect: "cm", ts: "1.7" });
  // (a still.fail chat two sessions share: one item, its sessions together)
  const shared = chat("chat:c-0001", { connect: "ember", surface: "ember", ts: "1.8", home: true, title: "a chat of two" });
  store.insertSession({ key: "chat:c-0002", connect: "ember", runtime: "codex", profile: "cx", workspace: room("s-two"), token: "tok-two", createdAt: 1, lastActiveAt: 1, ws: null });
  store.joinThread(shared.id, "chat:c-0002", "ember");
  // (handed to B: there; coming from B, not shown yet: not in the plan; of another workspace: not in it either)
  chat(sessionKey("cl", "C1", "1.9"), { ts: "1.9" });
  store.handOff([sessionKey("cl", "C1", "1.9")], B, WS, {});
  chat(sessionKey("cl", "C1", "2.0"), { ts: "2.0", ws: comingWs(WS) });
  chat(sessionKey("cl", "C1", "2.1"), { ts: "2.1", ws: "other-ws" });
  // (jobs of two chats)
  a.jobs.push({ id: "A-job-0", session: sessionKey("cl", "C1", "1.1"), name: "dev", cwd: room("s0"), command: "npm run dev" } as Json, { id: "A-job-1", session: "chat:c-0002", name: "watch", cwd: room("s-two"), command: "tsc -w" } as Json);
  mkdirSync(room("s0"), { recursive: true });
  // (linked worktrees, as git leaves them: a canonical clone of the repository cache with two chats' worktrees, one of
  // them archived; a clone outside the cache with a worktree in a chat's room; a chat's own repository in its room; a
  // worktree whose clone is gone)
  const clone = (dir: string, url: string) => {
    mkdirSync(join(dir, ".git"), { recursive: true });
    writeFileSync(join(dir, ".git", "config"), `[core]\n\tbare = false\n[remote "origin"]\n\turl = ${url}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n`);
  };
  const worktree = (repo: string, name: string, at: string) => {
    mkdirSync(join(repo, ".git", "worktrees", name), { recursive: true });
    writeFileSync(join(repo, ".git", "worktrees", name, "gitdir"), `${join(at, ".git")}\n`);
    mkdirSync(at, { recursive: true });
    writeFileSync(join(at, ".git"), `gitdir: ${join(repo, ".git", "worktrees", name)}\n`);
  };
  const cache = join(a.rig.dir, "repos", "shared");
  clone(cache, "https://example.test/shared.git");
  const elsewhere = join(a.rig.dir, "elsewhere", "own");
  clone(elsewhere, "https://example.test/own.git");
  a.elsewhere = [elsewhere];
  const linked = (k: string, n: string) => chat(sessionKey("cl", "C1", k), { ts: k, workspace: room(n) });
  linked("3.1", "w1");
  worktree(cache, "w1", join(room("w1"), "shared"));
  linked("3.2", "w2");
  worktree(cache, "w2", join(room("w2"), "shared"));
  store.setArchived(sessionKey("cl", "C1", "3.2"), true, MANUAL);
  linked("3.3", "w3");
  worktree(elsewhere, "w3", join(room("w3"), "own"));
  linked("3.4", "w4");
  clone(room("w4"), "https://example.test/standalone.git");
  linked("3.5", "w5");
  mkdirSync(join(room("w5"), "old"), { recursive: true });
  writeFileSync(join(room("w5"), "old", ".git"), `gitdir: ${join(a.rig.dir, "gone", ".git", "worktrees", "old")}\n`);
  return { w, a };
}

/// A plan as lines, one an item, in its order.
const dump = (plan: Json) => plan.items.map((x: Json) => [x.module, x.id, x.label, x.needs.map((n: Json) => `${n.module} ${n.id}`).join(","), x.cannot ?? "", x.state, x.wouldStop.map((n: Json) => `${n.module} ${n.id}`).join(",")].join(" | ").replaceAll(A, "A").replaceAll(B, "B"));
const printDump = process.env.MOVE_PLAN_DUMP === "1";

test("a plan says of every chat, account, job and connect what it said before its reads went by pages", async () => {
  const { a } = cases();
  const got = dump(await a.moves.scheduler.plan(WS, B));
  if (printDump) console.log(`DUMP\n${got.join("\n")}\nEND`);
  assert.deepEqual(got, WANT);
});

const WANT: string[] = [
  "accounts | share:sh-cc | cc |  |  | here | ",
  "accounts | key:f663c3465c5f0b8b63e89ebd3a687043 | cx |  |  | there | ",
  "accounts | share:sh-b | bor |  |  | here | ",
  "accounts | machine:mine | mine |  | 本机自己的登录不能迁到别的 station：请在那边用登录工具登录 | here | chats gpt:C1:1.3",
  "accounts | own:solo@A | solo |  |  | here | chats team:all",
  "chats | chat:c-0001 | a chat of two | accounts share:sh-cc,accounts key:f663c3465c5f0b8b63e89ebd3a687043 |  | here | ",
  "chats | cl:C1:1.1 | a Slack thread | accounts share:sh-cc,accounts key:f663c3465c5f0b8b63e89ebd3a687043 |  | here | ",
  "chats | cl:C1:1.2 | cl:C1:1.2 | accounts share:sh-b |  | here | ",
  "chats | cl:C1:1.4 | cl:C1:1.4 | accounts share:sh-cc | 对话「cl:C1:1.4」的工作目录 /elsewhere/proj 不在这台 station 自己的目录里：它的文件不会一起迁走；确实要这样的话，选不带文件再迁一次 | here | ",
  "chats | cl:C1:1.5 | cl:C1:1.5 | accounts share:sh-cc |  | here | ",
  "chats | cl:C1:1.9 | cl:C1:1.9 | accounts share:sh-cc |  | there | ",
  "chats | cl:C1:3.1 | cl:C1:3.1 | accounts share:sh-cc,repos repo:https://example.test/shared.git |  | here | ",
  "chats | cl:C1:3.2 | cl:C1:3.2 | accounts share:sh-cc,repos repo:https://example.test/shared.git |  | here | ",
  "chats | cl:C1:3.3 | cl:C1:3.3 | accounts share:sh-cc,repos repo:https://example.test/own.git |  | here | ",
  "chats | cl:C1:3.4 | cl:C1:3.4 | accounts share:sh-cc |  | here | ",
  "chats | cl:C1:3.5 | cl:C1:3.5 | accounts share:sh-cc |  | here | ",
  "chats | cm:C9:1.7 | cm:C9:1.7 | accounts share:sh-cc |  | here | ",
  "chats | gpt:C1:1.3 | gpt:C1:1.3 | accounts machine:mine |  | here | ",
  "chats | team:all | team:all | accounts own:solo@A,connects team@A |  | here | ",
  "jobs | cl:C1:1.1#dev | dev (npm run dev) | chats cl:C1:1.1 |  | here | ",
  "jobs | chat:c-0002#watch | watch (tsc -w) | chats chat:c-0001 |  | here | ",
  "connects | cl@A | cl | chats cl:C1:1.1,chats cl:C1:1.2,chats cl:C1:1.4,chats cl:C1:1.5,chats cl:C1:1.9,chats cl:C1:2.0,chats cl:C1:2.1,chats cl:C1:3.1,chats cl:C1:3.2,chats cl:C1:3.3,chats cl:C1:3.4,chats cl:C1:3.5 |  | here | ",
  "connects | gpt@A | gpt | chats gpt:C1:1.3 |  | here | ",
  "connects | team@A | team |  |  | here | chats team:all",
  "connects | cm@A | cm | chats cm:C9:1.7 |  | here | ",
  "repos | repo:https://example.test/shared.git | shared |  |  | here | ",
  "repos | repo:https://example.test/own.git | own |  |  | here | ",
  "settings | setting:askToName | askToName |  |  | here | ",
  "settings | setting:autoArchiveKeep | autoArchiveKeep |  |  | here | ",
];

/// Every statement run on a database, whenever and however it was prepared (the store keeps what it prepares, so a
/// statement made before a test looks runs many times after): what `watch` counts runs of. Installed before any store
/// is opened. The plan reads on the main thread's store only: nothing of it goes to a reader thread or the program.
const dbOf = new WeakMap<object, object>();
/// The database the last statement was prepared on (the store's is behind store/timed.ts's wrapper: found by preparing).
let prepared: object | null = null;
type Seen = { sql: string; args: SQLInputValue[]; turn: number; rows: number };
const counting: { db: object | null; seen: Seen[]; rows: number; turn: number } = { db: null, seen: [], rows: 0, turn: 0 };
{
  const prepare = DatabaseSync.prototype.prepare;
  DatabaseSync.prototype.prepare = function (this: DatabaseSync, sql: string, ...rest: unknown[]) {
    const st = (prepare as Json).call(this, sql, ...rest);
    dbOf.set(st, this);
    prepared = this;
    return st;
  } as Json;
  for (const m of ["all", "get", "iterate", "run"] as const) {
    const f = (StatementSync.prototype as Json)[m];
    (StatementSync.prototype as Json)[m] = function (this: StatementSync, ...args: SQLInputValue[]) {
      const r = f.apply(this, args);
      if (counting.db === null || dbOf.get(this) !== counting.db) return r;
      const one: Seen = { sql: this.sourceSQL, args, turn: counting.turn, rows: m === "all" ? (r as unknown[]).length : m === "get" ? (r === undefined ? 0 : 1) : 0 };
      counting.seen.push(one);
      counting.rows += one.rows;
      if (m === "iterate") return (function* () { for (const x of r as Iterable<unknown>) { one.rows++; counting.rows++; yield x; } })();
      return r;
    };
  }
}

/// The statements run on `store`'s database from now on (`stop`), with the turn of the loop each ran in (a turn given
/// back between two statements counts one more), and the rows they fetched.
function watch(store: Json) {
  store.db.prepare("SELECT 1");
  counting.db = prepared;
  counting.seen = [];
  counting.rows = 0;
  let on = true;
  const tick = () => {
    if (!on) return;
    counting.turn++;
    setImmediate(tick);
  };
  setImmediate(tick);
  return { seen: counting.seen, rows: () => counting.rows, stop: () => void ((on = false), (counting.db = null)), db: store.db as DatabaseSync };
}

/// What SQLite's plan of a statement scans of a table of the store's (none: by an index; a subquery's rows, `SCAN u`, or
/// json_each's are no table's).
function scans(db: DatabaseSync, sql: string, args: SQLInputValue[]): string[] {
  const tables = new Set((db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as { name: string }[]).map((r) => r.name));
  return (db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...args) as { detail: string }[]).map((r) => String(r.detail)).filter((d) => {
    const m = /^SCAN (\w+)/.exec(d);
    return m !== null && tables.has(m[1]!);
  });
}

/// The calls of the file system's promises from now on (`stop`), by name: what a plan asks of the disk (counted by
/// wrapping node:fs/promises and syncing the modules' bindings of it, as test/main-thread-waits.test.ts counts waits).
function watchFiles() {
  const fsp = require("node:fs/promises") as Record<string, Json>;
  const names = ["stat", "lstat", "readFile", "readdir", "open", "access", "statfs"];
  const was = new Map(names.map((n) => [n, fsp[n]]));
  const calls = new Map<string, number>();
  for (const n of names) fsp[n] = (...args: unknown[]) => (calls.set(n, (calls.get(n) ?? 0) + 1), was.get(n)(...args));
  syncBuiltinESMExports();
  return {
    total: () => [...calls.values()].reduce((a, b) => a + b, 0),
    calls,
    stop: () => {
      for (const n of names) fsp[n] = was.get(n);
      syncBuiltinESMExports();
    },
  };
}

/// The bound: statements a plan makes for each page of chats (the chats' own page and what reads it, the accounts',
/// the repositories' and each connect's), and those a plan makes whatever the chats (the jobs', each module's own).
const A_PAGE = 16;
const WHATEVER = 64;
/// Rows: each chat's row once (its page), and once more as a connect's (`sessionsOfConnect`, keys only).
const ROWS_A_CHAT = 2;
const ROWS_WHATEVER = 200;
/// Calls of the file system a plan, whatever the chats: the repository cache's listing, each clone's config and list
/// of worktrees (repos.ts `worktreesOfClones`), and the agent home's and settings' own; the first plan of a process
/// reads each worktree's gitdir once more.
const CLONES = 30;
const filesMost = (worktrees: number) => 1 + 2 * CLONES + worktrees + 32;

for (const n of [300, 2_384]) {
  test(`a plan of ${n} chats reads them a page at a time: at most ${A_PAGE} statements a page and ${WHATEVER} more, each by an index, the main thread given back between pages`, async () => {
    const { a } = officeShape(n);
    const worktrees = Math.min(Math.ceil(n / 6), 400);
    const FILES = filesMost(0);
    const first = watchFiles();
    const before = await a.moves.scheduler.plan(WS, B);
    first.stop();
    // (the chats' sizes the first read set measuring, in their own thread on a station: measured before the count)
    await a.moves.sizes.settled();
    assert.ok(first.total() <= filesMost(worktrees), `${first.total()} calls of the file system for the first plan of ${n} chats: at most ${filesMost(worktrees)}, a worktree's gitdir read once`);
    const w = watch(a.rig.store);
    const f = watchFiles();
    const plan = await a.moves.scheduler.plan(WS, B);
    f.stop();
    w.stop();
    assert.deepEqual(dump(plan), dump(before), "the same plan, read again");
    const pages = Math.ceil(n / PLAN_PAGE);
    const most = A_PAGE * pages + WHATEVER;
    const runs = new Map<number, number>();
    for (const s of w.seen) runs.set(s.turn, (runs.get(s.turn) ?? 0) + 1);
    const longest = Math.max(...runs.values());
    const by = new Map<string, { runs: number; rows: number }>();
    for (const s of w.seen) {
      const b = by.get(s.sql) ?? { runs: 0, rows: 0 };
      b.runs++;
      b.rows += s.rows;
      by.set(s.sql, b);
    }
    const top = [...by].sort((x, y) => y[1].rows - x[1].rows).slice(0, 5).map(([sql, b]) => `  stmt ${b.runs} runs ${b.rows} rows: ${sql.replace(/\s+/g, " ").slice(0, 160)}`);
    console.log(`PLAN n=${n}: ${w.seen.length} statements, ${w.rows()} rows (${pages} pages, at most ${most}; rows at most ${ROWS_A_CHAT * n + ROWS_WHATEVER}), the longest run in one turn ${longest}, file system calls ${f.total()} ${JSON.stringify(Object.fromEntries(f.calls))}\n${top.join("\n")}`);
    assert.ok(w.seen.length >= pages, `${w.seen.length} statements for ${n} chats (${pages} pages): the counter sees nothing`);
    assert.ok(w.seen.length <= most, `${w.seen.length} statements for ${n} chats (${pages} pages): at most ${most}`);
    assert.ok(w.rows() <= ROWS_A_CHAT * n + ROWS_WHATEVER, `${w.rows()} rows for ${n} chats: at most ${ROWS_A_CHAT} a chat and ${ROWS_WHATEVER}`);
    assert.ok(longest <= A_PAGE, `${longest} statements in one turn of the loop: at most a page's ${A_PAGE}`);
    assert.ok(f.total() <= FILES, `${f.total()} calls of the file system for ${n} chats: at most ${FILES}, whatever the chats`);
    const distinct = new Map(w.seen.map((s) => [s.sql, s]));
    for (const s of distinct.values()) assert.deepEqual(scans(w.db, s.sql, s.args), [], `a scan in: ${s.sql}`);
  });
}

/// A page of the move page read while a turn runs (statements and rows, whatever the station's size).
const PAGE_READ = 48;
const PAGE_READ_ROWS = 400;
/// What a page read during a turn asks the modules of where items stand: the rows it answers (each module's page, the
/// one asked for and the first of every other, as at rest), the item the turn is at among them, each once; never by the
/// station's size. Kept by n, the same at both.
const pageAsked = new Map<number, number>();

for (const n of [300, 2_384]) {
  test(`a page of the move page read while a turn runs, among ${n} chats: its rows and counts from the turn's own plan, at most ${PAGE_READ} statements and ${PAGE_READ_ROWS} rows, nothing asked of the other station, only the rows it answers (every module's page) asked where they stand, as many at 2,384 chats as at 300`, async () => {
    const { w, a } = officeShape(n);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    // (a turn held as the chat's files are placed there)
    const gate = Promise.withResolvers<void>();
    const at = Promise.withResolvers<void>();
    b.placing = async () => {
      at.resolve();
      await gate.promise;
    };
    const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await at.promise;
    // (what the other station is asked, and what the modules are asked of where items stand)
    let askedThere = 0;
    const handle = b.bus.handle.bind(b.bus);
    b.bus.handle = ((ws: string, peer: string, r: Json) => (String(r?.method ?? "").startsWith("move.") && askedThere++, handle(ws, peer, r))) as typeof b.bus.handle;
    let stated = 0;
    for (const m of a.moves.modules) {
      const was = m.state.bind(m);
      m.state = (x) => (stated++, was(x));
    }
    // (the page read is the one the moving chat is on: asked where it stands once, as a row, not again as moving)
    const list = a.moves.scheduler.held(WS, B)!.view.byModule.get("chats")!;
    const i = list.findIndex((x) => x.id === key);
    assert.ok(i >= 0, "the moving chat in the turn's plan");
    const start = Math.max(0, Math.min(i, list.length - 50));
    const w2 = watch(a.rig.store);
    const view = await a.ask("GET", "/move", null, "owner", [["to", B], ["module", "chats"], ["limit", "50"], ...(start > 0 ? [["after", list[start - 1]!.id] as [string, string]] : [])]);
    w2.stop();
    assert.equal(view.status, 200, JSON.stringify(view.body));
    const chats = view.body.modules.find((m: Json) => m.id === "chats");
    assert.equal(chats.items.length, 50, "a page of rows");
    assert.ok(chats.total > n, `counted: ${chats.total}`);
    assert.equal(askedThere, 0, "nothing asked of the other station");
    const rows = view.body.modules.reduce((t: number, m: Json) => t + m.items.length, 0);
    for (const m of view.body.modules) assert.ok(m.items.length <= 50, `${m.id}: ${m.items.length} rows, at most the page's 50`);
    assert.ok(chats.items.some((x: Json) => x.id === key && x.state === "moving"), "the moving chat among the page's rows");
    assert.equal(stated, rows, `${stated} items asked where they stand: the ${rows} rows answered, the moving one among them, each once`);
    pageAsked.set(n, stated);
    if (pageAsked.has(300) && n !== 300) assert.equal(stated, pageAsked.get(300), `as many asked among ${n} chats as among 300`);
    assert.ok(w2.seen.length <= PAGE_READ, `${w2.seen.length} statements for a page read among ${n} chats: at most ${PAGE_READ}`);
    assert.ok(w2.rows() <= PAGE_READ_ROWS, `${w2.rows()} rows for a page read among ${n} chats: at most ${PAGE_READ_ROWS}`);
    b.placing = undefined;
    gate.resolve();
    await turn;
    await w.quiet();
  });
}

test("a linked worktree made or removed between two plans is seen by the next, its clone asked only for its list", async () => {
  const { a, keys } = officeShape(30);
  const key = keys[1]!;
  const repos = (plan: Json) => plan.items.find((x: Json) => x.id === key).needs.filter((n: Json) => n.module === "repos").map((n: Json) => n.id);
  assert.deepEqual(repos(await a.moves.scheduler.plan(WS, B)), []);
  const repo = join(a.rig.dir, "repos", "r7");
  const at = join(a.rig.session(key).workspace, "r7");
  mkdirSync(join(repo, ".git", "worktrees", "late"), { recursive: true });
  writeFileSync(join(repo, ".git", "worktrees", "late", "gitdir"), `${join(at, ".git")}\n`);
  mkdirSync(at, { recursive: true });
  writeFileSync(join(at, ".git"), `gitdir: ${join(repo, ".git", "worktrees", "late")}\n`);
  assert.deepEqual(repos(await a.moves.scheduler.plan(WS, B)), ["repo:https://example.test/r7.git"], "made: seen");
  rmSync(join(repo, ".git", "worktrees", "late"), { recursive: true });
  assert.deepEqual(repos(await a.moves.scheduler.plan(WS, B)), [], "removed: gone");
});
