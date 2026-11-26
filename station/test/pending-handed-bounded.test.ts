import assert from "node:assert/strict";
import { test } from "node:test";
import { PENDING_HANDED_LETTERS, PENDING_HANDED_MESSAGES, Store } from "../src/store/store.ts";

function setupSession(store: Store, session: string) {
  store.insertSession({ key: session, connect: "ember", runtime: "claude", profile: "cc", workspace: "/w/s", token: session, createdAt: 1, lastActiveAt: 1 });
  const thread = store.openThread("ember", "CHAT", `chat-${session}`, null, null).id;
  store.joinThread(thread, session, "ember");
  return thread;
}

test("pendingHanded seeks partial pending indexes without temp sort or full scans", () => {
  const store = Store.open(":memory:");
  try {
    const msgPlan = (store.db.prepare(`EXPLAIN QUERY PLAN ${PENDING_HANDED_MESSAGES}`).all("s1", 10) as { detail: string }[])
      .map((r) => r.detail).join(" | ");
    const letterPlan = (store.db.prepare(`EXPLAIN QUERY PLAN ${PENDING_HANDED_LETTERS}`).all("s1", 10) as { detail: string }[])
      .map((r) => r.detail).join(" | ");
    assert.ok(msgPlan.includes("deliveries_pending"), msgPlan);
    assert.ok(letterPlan.includes("letter_deliveries_pending"), letterPlan);
    assert.ok(!msgPlan.includes("TEMP B-TREE"), msgPlan);
    assert.ok(!letterPlan.includes("TEMP B-TREE"), letterPlan);
    assert.ok(!msgPlan.includes("SCAN "), msgPlan);
    assert.ok(!letterPlan.includes("SCAN "), letterPlan);
  } finally {
    store.close();
  }
});

test("pendingHanded visits bounded rows independent of delivered and other-session backlog", () => {
  const visited: number[] = [];
  for (const size of [40, 4_000]) {
    const store = Store.open(":memory:"), db = store.db;
    try {
      const t1 = setupSession(store, "s1");
      const t2 = setupSession(store, "other");
      const putEntry = db.prepare("INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at) VALUES(?,?,'message',?,'person','p','hi',?)");
      const putDeliv = db.prepare("INSERT INTO deliveries(thread,n,session,delivered_at) VALUES(?,?,?,?)");
      const putLetter = db.prepare("INSERT INTO letters(thread,n,ts,author_kind,author,text,at,letter) VALUES(?,?,?,'agent','a','note',?,?)");
      const putLetterDeliv = db.prepare("INSERT INTO letter_deliveries(thread,n,session,delivered_at) VALUES(?,?,?,?)");
      const letterMeta = JSON.stringify({ way: "in", title: "peer", link: null });

      db.exec("BEGIN");
      for (let i = 1; i <= size; i++) {
        // Delivered backlog on s1.
        putEntry.run(t1, i, `d.${i}`, i);
        putDeliv.run(t1, i, "s1", i);
        putLetter.run(t1, i, `ld.${i}`, i, letterMeta);
        putLetterDeliv.run(t1, i, "s1", i);
        // Pending backlog on other session.
        putEntry.run(t2, i, `o.${i}`, i);
        putDeliv.run(t2, i, "other", null);
        putLetter.run(t2, i, `lo.${i}`, i, letterMeta);
        putLetterDeliv.run(t2, i, "other", null);
        // Excess pending rows on s1 beyond limit.
        const n = size + i;
        putEntry.run(t1, n, `p.${i}`, n);
        putDeliv.run(t1, n, "s1", null);
        putLetter.run(t1, n, `lp.${i}`, n, letterMeta);
        putLetterDeliv.run(t1, n, "s1", null);
      }
      db.exec("COMMIT");

      let count = 0;
      let instrumented = 0;
      db.function("visited_pending_row", (_rowid) => { count++; return 1; });
      const traced = new Proxy(db, {
        get(target, prop) {
          if (prop === "prepare") {
            return (sql: string) => {
              const observed = sql.replace(
                /AND d\.delivered_at IS NULL/gi,
                "AND visited_pending_row(d.rowid) AND d.delivered_at IS NULL",
              );
              if (observed !== sql) instrumented++;
              return target.prepare(observed);
            };
          }
          const value = Reflect.get(target, prop, target);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      (store as any).db = traced;
      const handed = store.pendingHanded("s1", 5);
      assert.equal(handed.length, 5);
      assert.ok(instrumented >= 2, "both message and letter queries instrumented");
      visited.push(count);
    } finally {
      (store as any).db = db;
      store.close();
    }
  }
  assert.ok(visited[1]! <= visited[0]! + 2 && visited[1]! <= 12,
    `pendingHanded visited rows grew with backlog: ${visited.join(" / ")}`);
});

test("pendingHanded merges entries and apart letters by time, excludes orphans and delivered, and obeys limit", () => {
  const store = Store.open(":memory:"), db = store.db;
  try {
    const t = setupSession(store, "s1");
    const unjoined = store.openThread("ember", "CHAT", "unjoined", null, null).id;
    const letterMeta = JSON.stringify({ way: "in", title: "peer", link: null });

    db.prepare("INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at) VALUES(?,1,'message','1.1','person','p','a',10)").run(t);
    db.prepare("INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at) VALUES(?,2,'message','2.1','person','p','b',30)").run(t);
    db.prepare("INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at) VALUES(?,3,'message','3.1','person','p','done',5)").run(t);
    db.prepare("INSERT INTO deliveries(thread,n,session,delivered_at) VALUES(?,1,'s1',NULL)").run(t);
    db.prepare("INSERT INTO deliveries(thread,n,session,delivered_at) VALUES(?,2,'s1',NULL)").run(t);
    db.prepare("INSERT INTO deliveries(thread,n,session,delivered_at) VALUES(?,3,'s1',5)").run(t);

    // Orphaned delivery (session not in thread_sessions).
    db.prepare("INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at) VALUES(?,1,'message','u.1','person','p','orphan',1)").run(unjoined);
    db.prepare("INSERT INTO deliveries(thread,n,session,delivered_at) VALUES(?,1,'s1',NULL)").run(unjoined);

    db.prepare("INSERT INTO letters(thread,n,ts,author_kind,author,text,at,letter) VALUES(?,1,'l.1','agent','a','L1',20,?)").run(t, letterMeta);
    db.prepare("INSERT INTO letters(thread,n,ts,author_kind,author,text,at,letter) VALUES(?,2,'l.2','agent','a','L2',30,?)").run(t, letterMeta);
    db.prepare("INSERT INTO letters(thread,n,ts,author_kind,author,text,at,letter) VALUES(?,3,'l.3','agent','a','L3',40,?)").run(t, letterMeta);
    db.prepare("INSERT INTO letter_deliveries(thread,n,session,delivered_at) VALUES(?,1,'s1',NULL)").run(t);
    db.prepare("INSERT INTO letter_deliveries(thread,n,session,delivered_at) VALUES(?,2,'s1',NULL)").run(t);
    db.prepare("INSERT INTO letter_deliveries(thread,n,session,delivered_at) VALUES(?,3,'s1',NULL)").run(t);

    assert.deepEqual(store.pendingHanded("s1"), [
      { thread: t, n: 1, apart: false },
      { thread: t, n: 1, apart: true },
      { thread: t, n: 2, apart: false },
      { thread: t, n: 2, apart: true },
      { thread: t, n: 3, apart: true },
    ]);
    assert.deepEqual(store.pendingHanded("s1", 3), [
      { thread: t, n: 1, apart: false },
      { thread: t, n: 1, apart: true },
      { thread: t, n: 2, apart: false },
    ]);
    assert.deepEqual(store.pendingHanded("s1", 0), []);
  } finally {
    store.close();
  }
});
