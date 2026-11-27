import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import { Effect, Layer } from "effect";
import { SETTLE_MS, StatusLive, TASKS_MOST, WaitingTracker, routeOf, statusOf, statusServer, type LocalStatus, type StatusInput } from "../src/api/status.ts";
import { platform } from "../src/platform/index.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { Store, WAITING_FOR_PEOPLE, WAITING_FOR_PERSON_OF } from "../src/store/store.ts";
import { testClock } from "./hub-fakes.ts";

const DAY = 24 * 60 * 60_000;
const input = (o: Partial<StatusInput> = {}): StatusInput => ({
  version: "0.1.9", cloud: { origin: "https://cloud.example", workspace: "w1", workspace_name: "Lab", station: "st" }, reached: true,
  running: [], processes: new Map(), waiting: [], ...o,
});

test("the local status counts agents at work, warm and waiting, each once, and lists their tasks", () => {
  const s = statusOf(input({
    running: [{ key: "a", title: "build", since: 10 }, { key: "b", title: "lint", since: 20 }],
    processes: new Map([["a", "running"], ["b", "running"], ["c", "warm"], ["d", "running"]]),
    waiting: [{ key: "e", title: "deploy?", need: "may I deploy", endedAt: 5 }, { key: "a", title: "build", need: "old", endedAt: 1 }],
  }));
  assert.deepEqual(s.agents, { busy: 3, warm: 1, total: 5 });
  assert.equal(s.waiting, 1, "one at work again is not waiting");
  assert.equal(s.enrolled, true);
  assert.equal(s.workspaceName, "Lab");
  assert.deepEqual(s.tasks.map((t) => [t.session, t.state]), [["b", "working"], ["a", "working"], ["d", "working"], ["e", "waiting"]]);
  assert.equal(s.tasks.at(-1)?.need, "may I deploy");
});

test("a station in no workspace, or removed from it, is not enrolled", () => {
  assert.equal(statusOf(input({ cloud: null })).enrolled, false);
  assert.equal(statusOf(input({ cloud: { origin: "https://c", workspace: "w", removed_at: 3 } })).enrolled, false);
  assert.equal(statusOf(input({ cloud: { origin: "https://c", workspace: "" } })).enrolled, false);
});

test("the tasks said are at most TASKS_MOST, the counts of all", () => {
  const running = Array.from({ length: TASKS_MOST + 5 }, (_, n) => ({ key: `s${n}`, title: null, since: n }));
  const s = statusOf(input({ running }));
  assert.equal(s.tasks.length, TASKS_MOST);
  assert.equal(s.agents.busy, TASKS_MOST + 5);
});

test("the socket answers GET /v1/status, its stream and /healthz, nothing else", () => {
  assert.equal(routeOf("GET", "/v1/status"), "status");
  assert.equal(routeOf("GET", "/v1/status?watch=1"), "watch");
  assert.equal(routeOf("GET", "/v1/status?watch=0"), "status");
  assert.equal(routeOf("GET", "/healthz"), "health");
  assert.equal(routeOf("POST", "/v1/status"), null);
  assert.equal(routeOf("GET", "/admin/api/overview"), null);
});

test("the sessions waiting for a person: their latest turn asked, nobody answered, not archived, lately", () => {
  const time = testClock(), store = Store.open(":memory:", null, time.clock);
  try {
    const now = store.now();
    const session = (key: string, title: string) => {
      store.insertSession({ key, connect: "chat", runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, createdAt: now, lastActiveAt: now });
      store.setTitle(key, title);
    };
    const turn = (id: string, key: string, declared: string | null, need: string | null = null) => {
      store.startTurn(id, key, "message");
      store.endTurn(id, "completed", null, declared, null);
      if (need !== null) store.db.prepare("UPDATE turns SET need = ? WHERE id = ?").run(need, id);
    };
    session("asks", "deploy"); turn("t1", "asks", "all_done"); turn("t2", "asks", "need_human", "may I deploy");
    session("done", "done"); turn("t3", "done", "need_human"); turn("t4", "done", "all_done");
    session("answered", "answered"); turn("t5", "answered", "need_help");
    const thread = store.openThread("chat", "C", "x", null, null);
    store.db.prepare("INSERT INTO deliveries(thread,n,session,delivered_at) VALUES(?,1,'answered',NULL)").run(thread.id);
    session("archived", "archived"); turn("t6", "archived", "need_human"); store.setArchived("archived", true, "p");
    const got = store.waitingForPeople(now - DAY, 10);
    assert.deepEqual(got.map((w) => [w.key, w.need]), [["asks", "may I deploy"]]);
    assert.deepEqual(store.waitingForPeople(now + 1, 10), [], "a turn that ended before `since` is not looked at");
  } finally {
    store.close();
  }
});

test("the waiting sessions' read goes by the open sessions, each by its latest turn", () => {
  const store = Store.open(":memory:");
  try {
    const plan = store.db.prepare(`EXPLAIN QUERY PLAN ${WAITING_FOR_PEOPLE}`).all(0, 10).map((r: any) => String(r.detail));
    assert.ok(plan.some((d) => /SCAN s USING INDEX sessions_live\b/.test(d)), plan.join("\n"));
    assert.ok(!plan.some((d) => /^SCAN (t|u|d)\b/.test(d) || /^SCAN s$/.test(d)), plan.join("\n"));
    assert.ok(!plan.some((d) => /turns_waiting|deliveries_session/.test(d)), plan.join("\n"));
    assert.ok(plan.some((d) => /SEARCH u USING COVERING INDEX turns_by_session\b/.test(d)), plan.join("\n"));
    assert.ok(plan.some((d) => /SEARCH t USING INTEGER PRIMARY KEY \(rowid=\?\)/.test(d)), plan.join("\n"));
    assert.ok(plan.some((d) => /SEARCH d USING (COVERING )?INDEX deliveries_pending\b/.test(d)), plan.join("\n"));
  } finally {
    store.close();
  }
});

test("who waits costs the open sessions alone, however often each asked before", () => {
  const time = testClock(), store = Store.open(":memory:", null, time.clock);
  try {
    const now = store.now();
    const turn = store.db.prepare("INSERT INTO turns(id, session_key, kind, started_at, ended_at, outcome, declared) VALUES(?,?,'message',?,?,'completed',?)");
    store.db.exec("BEGIN IMMEDIATE");
    for (let n = 0; n < 30; n++) {
      const key = `s${n}`;
      store.insertSession({ key, connect: "chat", runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, createdAt: now, lastActiveAt: now });
      // Many earlier turns that asked; only the open ones' latest are read.
      for (let k = 0; k < 40; k++) turn.run(`${key}-${k}`, key, now - 1000 + k, now - 999 + k, "need_human");
    }
    store.db.exec("COMMIT");
    for (let n = 10; n < 30; n++) store.setArchived(`s${n}`, true, "p");
    let seen = 0;
    store.db.function("seen_turn", (_rowid) => { seen++; return 1; });
    const counted = WAITING_FOR_PEOPLE.replace("AND t.ended_at >= ?1", "AND seen_turn(t.rowid) AND t.ended_at >= ?1");
    assert.notEqual(counted, WAITING_FOR_PEOPLE);
    const rows = store.db.prepare(counted).all(now - DAY, 50);
    assert.equal(rows.length, 10);
    assert.deepEqual(store.waitingForPeople(now - DAY, 50).map((w) => w.need), Array(10).fill(null));
    assert.ok(seen <= 10, `${seen} turns looked at for 10 open sessions of 1,200 turns that asked`);
  } finally {
    store.close();
  }
});

test("a long delivered past and archived sessions change nothing of who waits: one undelivered row does", () => {
  const time = testClock(), store = Store.open(":memory:", null, time.clock);
  try {
    const PAST = 400, now = store.now();
    const thread = store.openThread("chat", "C", "long", null, null);
    const deliver = store.db.prepare("INSERT INTO deliveries(thread,n,session,delivered_at) VALUES(?,?,?,?)");
    const asked = (key: string) => {
      store.insertSession({ key, connect: "chat", runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, createdAt: now, lastActiveAt: now });
      for (let n = 1; n <= PAST; n++) deliver.run(thread.id, n, key, now);
      // An earlier turn that asked too: only a session's latest is told, once.
      for (const id of [`${key}-1`, `${key}-2`]) {
        store.startTurn(id, key, "message");
        store.endTurn(id, "completed", null, "need_human", null);
        store.db.prepare("UPDATE turns SET need = ? WHERE id = ?").run(`need of ${id}`, id);
      }
    };
    const waiting = () => store.waitingForPeople(now - DAY, 10).map((w) => [w.key, w.need]).sort();
    store.db.exec("BEGIN IMMEDIATE");
    for (const key of ["open", "other"]) asked(key);
    for (let n = 0; n < 20; n++) asked(`archived${n}`);
    store.db.exec("COMMIT");
    for (let n = 0; n < 20; n++) store.setArchived(`archived${n}`, true, "p");

    assert.deepEqual(waiting(), [["open", "need of open-2"], ["other", "need of other-2"]]);

    deliver.run(thread.id, PAST + 1, "open", null);
    assert.deepEqual(waiting(), [["other", "need of other-2"]], "one row undelivered after the long past: answered");
    store.db.prepare("UPDATE deliveries SET delivered_at = ? WHERE session = 'open' AND delivered_at IS NULL").run(now);
    assert.deepEqual(waiting(), [["open", "need of open-2"], ["other", "need of other-2"]], "delivered, and its latest turn still asks");

    deliver.run(thread.id, PAST + 1, "archived0", null);
    assert.deepEqual(waiting(), [["open", "need of open-2"], ["other", "need of other-2"]], "an archived session's undelivered row is its own");
    store.setArchived("archived1", false, "p");
    assert.deepEqual(waiting(), [["archived1", "need of archived1-2"], ["open", "need of open-2"], ["other", "need of other-2"]], "back from the archive, it waits again");
  } finally {
    store.close();
  }
});

/// A request and a response, as statusServer's handler takes them, with what was written to it.
function exchange(url: string) {
  const req = Object.assign(new EventEmitter(), { method: "GET", url });
  const res = Object.assign(new EventEmitter(), {
    status: 0, lines: [] as string[], ended: false,
    writeHead(status: number) { this.status = status; return this; },
    write(text: string) { this.lines.push(text); return true; },
    end(text?: string) { if (text !== undefined) this.lines.push(text); this.ended = true; return this; },
  });
  return { req, res };
}

test("a watcher is told the status now, then once a burst of changes settles, and only when it changed", async () => {
  const time = testClock(), fibers = new Fibers("status-test", time.clock);
  let busy = 0;
  let listener = () => {};
  const now = (): LocalStatus => statusOf(input({ running: Array.from({ length: busy }, (_, n) => ({ key: `s${n}`, title: null, since: n })) }));
  const s = statusServer(now, (f) => { listener = f; return () => { listener = () => {}; }; }, fibers);
  try {
    const one = exchange("/v1/status");
    s.server.emit("request", one.req, one.res);
    assert.equal(one.res.status, 200);
    assert.equal(one.res.ended, true);
    assert.equal(JSON.parse(one.res.lines[0]).agents.busy, 0);

    const w = exchange("/v1/status?watch=1");
    s.server.emit("request", w.req, w.res);
    assert.equal(w.res.lines.length, 1);
    busy = 1; listener(); busy = 2; listener(); listener();
    await time.adjust(SETTLE_MS - 1);
    assert.equal(w.res.lines.length, 1, "nothing before the burst settles");
    await time.adjust(1);
    assert.equal(w.res.lines.length, 2);
    assert.equal(JSON.parse(w.res.lines[1]).agents.busy, 2);
    listener();
    await time.adjust(SETTLE_MS);
    assert.equal(w.res.lines.length, 2, "the same status is not said again");

    const gone = exchange("/nothing");
    s.server.emit("request", gone.req, gone.res);
    assert.equal(gone.res.status, 404);
  } finally {
    s.close();
    await fibers.close();
  }
});

test("where there are no Unix sockets (Windows) there is no status socket, and nothing of the station is asked for", async () => {
  const had = platform.hasUnixSockets;
  platform.hasUnixSockets = false;
  try {
    // Given none of the services it asks for: it ends before asking any (one asked for would fail the build).
    await Effect.runPromise(Effect.scoped(Layer.build(StatusLive)) as Effect.Effect<unknown>);
  } finally {
    platform.hasUnixSockets = had;
  }
});

test("waitingForPersonOf uses primary-key and covering index seeks with zero table scans", () => {
  const store = Store.open(":memory:");
  try {
    const plan = store.db.prepare(`EXPLAIN QUERY PLAN ${WAITING_FOR_PERSON_OF}`).all("s1", 0).map((r: any) => String(r.detail));
    assert.ok(!plan.some((d) => /^SCAN\b/.test(d)), plan.join("\n"));
    assert.ok(plan.some((d) => /SEARCH s USING INDEX sqlite_autoindex_sessions_1 \(key=\?\)/.test(d)), plan.join("\n"));
    assert.ok(plan.some((d) => /SEARCH u USING COVERING INDEX turns_by_session\b/.test(d)), plan.join("\n"));
    assert.ok(plan.some((d) => /SEARCH t USING INTEGER PRIMARY KEY \(rowid=\?\)/.test(d)), plan.join("\n"));
    assert.ok(plan.some((d) => /SEARCH d USING (COVERING )?INDEX deliveries_pending\b/.test(d)), plan.join("\n"));
  } finally {
    store.close();
  }
});

test("WaitingTracker matches waitingForPeople via O(1) per-key updates without rescanning sessions_live", async () => {
  const time = testClock(), store = Store.open(":memory:", null, time.clock);
  try {
    const mk = (key: string, title: string) => {
      const now = store.now();
      store.insertSession({ key, connect: "chat", runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, createdAt: now, lastActiveAt: now });
      store.setTitle(key, title);
    };
    const ask = async (key: string, turnId: string, declared: string, need: string | null = null) => {
      await time.adjust(10);
      store.startTurn(turnId, key, "message");
      if (need !== null) store.setNeed(turnId, need);
      await time.adjust(10);
      store.endTurn(turnId, "completed", null, declared, null);
    };

    mk("s0", "Zero");
    mk("s1", "First");
    mk("s2", "Second");
    mk("s3", "Third");
    mk("other", "Other");
    await ask("s0", "t0", "need_human", "need-0");
    // Deliver a pending message to s0 so it is hidden initially, then cleared in the same tick as s3 drops.
    const th0 = store.openThread("chat", "C", "th0", null, null);
    store.joinThread(th0.id, "s0", "chat");
    const [m0] = store.insertMessage({ thread: th0.id, ts: "0.1", authorKind: "person", author: "p@x", text: "hold" });
    store.deliver(th0.id, m0, ["s0"]);
    await ask("s1", "t1", "need_human", "need-1");
    await ask("s2", "t2", "need_human", "need-2");
    await ask("s3", "t3", "need_human", "need-3");

    let fullScans = 0;
    let pkSeeks = 0;
    const origAll = store.waitingForPeople.bind(store);
    const origOne = store.waitingForPersonOf.bind(store);
    store.waitingForPeople = (since, limit) => { fullScans++; return origAll(since, limit); };
    store.waitingForPersonOf = (key, since) => { pkSeeks++; return origOne(key, since); };

    const tracker = new WaitingTracker(store);
    const off = store.subscribe((c) => tracker.note(c));
    try {
      const since = () => store.now() - DAY;
      // Initial seed with limit=2 (truncated because 3 sessions are waiting: s3, s2, s1).
      assert.deepEqual(tracker.read(since(), 2), origAll(since(), 2));
      assert.equal(fullScans, 1);
      assert.equal(pkSeeks, 0);

      // Routine updates on an unrelated session perform 0 full scans and only O(1) PK seeks.
      for (let i = 0; i < 10; i++) {
        store.setTitle("other", `edit-${i}`);
        assert.deepEqual(tracker.read(since(), 2), origAll(since(), 2));
      }
      assert.equal(fullScans, 1, "routine updates never rescan sessions_live");
      assert.equal(pkSeeks, 10, "routine updates use O(1) waitingForPersonOf PK seeks");

      // Title update on a waiting session refreshes it in place with 0 full scans.
      store.setTitle("s3", "Third renamed");
      assert.deepEqual(tracker.read(since(), 2), origAll(since(), 2));
      assert.equal(tracker.read(since(), 2)[0]?.title, "Third renamed");
      assert.equal(fullScans, 1);

      // Delivery answers s3 -> drops from top-2 while truncated -> re-seeds once to promote s1.
      const thread = store.openThread("chat", "C", "th1", null, null);
      store.joinThread(thread.id, "s3", "chat");
      const [msgN] = store.insertMessage({ thread: thread.id, ts: "1.1", authorKind: "person", author: "p@x", text: "go ahead" });
      store.deliver(thread.id, msgN, ["s3"]);
      assert.deepEqual(tracker.read(since(), 2), origAll(since(), 2));
      assert.deepEqual(tracker.read(since(), 2).map((r) => r.key), ["s2", "s1"]);
      assert.equal(fullScans, 2, "shrinking a truncated top-limit set re-seeds once to promote #3");

      // markDelivered clears s3's undelivered row -> s3 returns to waiting and displaces s1 without a full scan.
      store.markDelivered("s3", [{ thread: thread.id, n: msgN, apart: false }]);
      assert.deepEqual(tracker.read(since(), 2), origAll(since(), 2));
      assert.deepEqual(tracker.read(since(), 2).map((r) => r.key), ["s3", "s2"]);
      assert.equal(fullScans, 2, "a newly waiting session displaces the oldest in memory without rescanning");

      // Same-tick swap while truncated: s3 drops out while older s0 (endedAt < floor) becomes waiting in the same
      // tick. Even though known.size stays 2, lost > gainedAboveFloor triggers a re-seed so unseen s1 outranks s0.
      const [msgN2] = store.insertMessage({ thread: thread.id, ts: "1.2", authorKind: "person", author: "p@x", text: "second" });
      store.deliver(thread.id, msgN2, ["s3"]);
      store.markDelivered("s0", [{ thread: th0.id, n: m0, apart: false }]);
      assert.deepEqual(tracker.read(since(), 2), origAll(since(), 2));
      assert.deepEqual(tracker.read(since(), 2).map((r) => r.key), ["s2", "s1"]);
      assert.equal(fullScans, 3, "same-tick drop + older-than-floor return re-seeds to promote unseen #3");
      // deliveredThere also emits a session change so s3 returns to waiting in exact parity with waitingForPeople.
      store.deliveredThere(["s3"]);
      assert.deepEqual(tracker.read(since(), 2), origAll(since(), 2));
      assert.deepEqual(tracker.read(since(), 2).map((r) => r.key), ["s3", "s2"]);
      assert.equal(fullScans, 3, "deliveredThere refreshes s3 via O(1) PK seek without rescanning");

      // With limit=10 (not truncated), archiving/deleting/completing never needs a full re-seed.
      assert.deepEqual(tracker.read(since(), 10), origAll(since(), 10));
      const scansUntruncated = fullScans;
      store.setArchived("s2", true, "p@x");
      assert.deepEqual(tracker.read(since(), 10), origAll(since(), 10));
      await ask("s1", "t1b", "all_done");
      assert.deepEqual(tracker.read(since(), 10), origAll(since(), 10));
      store.deleteSession("s3");
      store.deleteSession("s0");
      assert.deepEqual(tracker.read(since(), 10), origAll(since(), 10));
      assert.equal(fullScans, scansUntruncated, "untruncated cache handles archive, turn completion, and delete with 0 full scans");

      // Expiry past `since` evicts in memory with 0 full scans.
      await ask("other", "to1", "need_human", "wait-me");
      assert.deepEqual(tracker.read(since(), 10).map((r) => r.key), ["other"]);
      await time.adjust(DAY + 100);
      assert.deepEqual(tracker.read(since(), 10), []);
      assert.equal(fullScans, scansUntruncated);
    } finally {
      off();
    }
  } finally {
    store.close();
  }
});
