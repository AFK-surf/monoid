// The reads a migration makes (store/handover.ts `chatPage`, `chatThreads`; store `sessionsOfWs`, `sessionsOfConnect`,
// `handedChats`) go by an index and a limit, never through a table: each statement they prepare is asked SQLite's plan,
// which names no scan of a table of the store's (a CTE of a table's viewers is walked by the table's key), and no page
// is longer than asked, on a store with many chats.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { DatabaseSync, SQLInputValue } from "node:sqlite";
import { Store } from "../src/store/store.ts";
import { CHAT_TABLES } from "../src/store/handover.ts";

const TABLES = new Set([...CHAT_TABLES, "handed_over"]);

/// Every statement `store` prepares from now on, with what it was run with, kept to be asked its plan.
function watch(store: Store): { sql: string; args: SQLInputValue[] }[] {
  const seen: { sql: string; args: SQLInputValue[] }[] = [];
  const db = store.db;
  Object.defineProperty(store, "db", { configurable: true, value: new Proxy(db, {
    get(target, property) {
      if (property === "prepare") return (sql: string) => {
        const st = target.prepare(sql);
        return new Proxy(st, {
          get(s, p) {
            const v = Reflect.get(s, p, s);
            if (p === "all" || p === "get" || p === "iterate") return (...args: SQLInputValue[]) => (seen.push({ sql, args }), (v as (...a: SQLInputValue[]) => unknown).apply(s, args));
            return typeof v === "function" ? v.bind(s) : v;
          },
        });
      };
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  }) });
  return seen;
}

function scans(db: DatabaseSync, sql: string, args: SQLInputValue[]): string[] {
  const plan = (db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...args) as { detail: string }[]).map((r) => String(r.detail));
  // (a mark table's viewers are walked one at a time by its key, `ORDER BY viewer LIMIT 1` from the last: SQLite says
  // each such seek a scan of the key's index, stopped at its first row)
  const viewers = sql.includes("WITH RECURSIVE viewers");
  return plan.filter((d) => {
    const m = /^SCAN (\w+)/.exec(d);
    return m !== null && TABLES.has(m[1]!) && !(viewers && / USING COVERING INDEX sqlite_autoindex_/.test(d));
  });
}

test("a migration's reads go by an index and a limit, on a store with many chats", () => {
  const store = Store.open(":memory:");
  const db = store.db;
  try {
    for (let i = 0; i < 300; i++) {
      const key = `chat:c-${String(i).padStart(4, "0")}`;
      store.insertSession({ key, connect: i % 2 === 0 ? "ember" : "cl", runtime: "claude", profile: "cc", workspace: `/d/sessions/chat/${key}/workspace`, token: `t${i}`, createdAt: 1, lastActiveAt: 1, ws: i % 3 === 0 ? "other" : null });
      const thread = store.openThread("ember", "C", `ts-${i}`, null, "p@x").id;
      store.joinThread(thread, key, "ember");
      for (let n = 0; n < 5; n++) store.insertMessage({ thread, ts: `${i}.${n}`, authorKind: "person", author: "p@x", text: "hi" });
      for (const v of ["a@x", "b@x", "c@x"]) {
        store.setRead(v, thread, 2);
        store.setPin(v, key, true);
      }
      store.startTurnFor(`turn-${i}`, key, "message", { profile: "cc", person: "p@x", thread });
      store.ranIn(key, `run-${i}`, "cc");
    }
    const key = "chat:c-0150";
    const thread = store.chatThreads([key], 0, 10)[0]!;
    const seen = watch(store);
    const pages: [string, number][] = [];
    for (const table of CHAT_TABLES) {
      const of = ["sessions", "turns", "runtime_sessions", "pins", "opened_chats", "deliveries"].includes(table) ? key : thread;
      pages.push([table, store.chatPage(table, of, null, 2, [key]).length]);
    }
    pages.push(["threads of", store.chatThreads([key], 0, 2).length]);
    pages.push(["sessions of ws", store.sessionsOfWs(null, "home", "", 2).length]);
    pages.push(["sessions of a workspace", store.sessionsOfWs("other", "home", "", 2).length]);
    pages.push(["sessions of a connect", store.sessionsOfConnect("cl", 2).length]);
    pages.push(["handed", store.handedChats("", 2).length]);
    for (const [what, n] of pages) assert.ok(n <= 2, `${what}: ${n} rows for a page of 2`);
    assert.ok(seen.length >= CHAT_TABLES.length, "every read was watched");
    for (const s of [...seen]) assert.deepEqual(scans(db, s.sql, s.args), [], `a scan in: ${s.sql}`);
  } finally {
    store.close();
  }
});

// The home workspace's sessions say none (those from before workspaces were written) or the home's id (a station
// enrolled since: every chat of the move drill's A, 2026-11-14, whose plan then listed none): a plan pages through both,
// and those it handed away, merged by key, and a joined workspace's alone; paging across the merge skips no key.
test("a workspace's sessions, a page at a time: the home one's whether they say no workspace or its id", () => {
  const store = Store.open(":memory:");
  try {
    const want: Record<string, string[]> = { home: [], other: [] };
    for (let i = 0; i < 40; i++) {
      const key = `chat:c-${String(i).padStart(4, "0")}`;
      const ws = i % 4 === 0 ? null : i % 4 === 1 ? "home" : i % 4 === 2 ? "handed:home" : "other";
      store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: `/d/sessions/chat/${key}/workspace`, token: `t${i}`, createdAt: 1, lastActiveAt: 1, ws });
      want[ws === "other" ? "other" : "home"]!.push(key);
    }
    const all = (ws: string | null) => {
      const got: string[] = [];
      for (let after = ""; ; ) {
        const page = store.sessionsOfWs(ws, "home", after, 7);
        assert.ok(page.length <= 7);
        got.push(...page);
        if (page.length < 7) return got;
        after = page.at(-1)!;
      }
    };
    assert.deepEqual(all(null), want.home);
    assert.deepEqual(all("other"), want.other);
  } finally {
    store.close();
  }
});

test("liveProfileOf uses a primary-key seek and liveWitnessesOnProfiles checks multiple profiles in one pass", () => {
  const store = Store.open(":memory:");
  const db = store.db;
  try {
    for (let i = 0; i < 100; i++) {
      const key = `chat:c-${String(i).padStart(4, "0")}`;
      const profile = i < 2 ? "borrowed-a" : i === 2 ? "borrowed-b" : i === 3 ? "borrowed-c" : "own";
      store.insertSession({ key, connect: "ember", runtime: "claude", profile, workspace: `/d/sessions/${key}`, token: `t${i}`, createdAt: 1, lastActiveAt: 1, ws: null });
    }
    // Archive borrowed-b's only chat, and hand over borrowed-c's only chat.
    store.setArchived("chat:c-0002", true, "p@x");
    db.prepare("INSERT INTO handed_over (session, station, ws, thread, there, at) VALUES (?, ?, NULL, 1, 1, 1)").run("chat:c-0003", "peer-st");

    const seen = watch(store);
    assert.equal(store.liveProfileOf("chat:c-0000"), "borrowed-a");
    assert.equal(store.liveProfileOf("chat:c-0002"), null, "archived session has no live profile");
    assert.equal(store.liveProfileOf("chat:c-0003"), null, "handed-over session has no live profile");
    assert.equal(store.liveProfileOf("chat:missing"), null);
    for (const s of seen) assert.deepEqual(scans(db, s.sql, s.args), [], `liveProfileOf must not scan: ${s.sql}`);

    seen.length = 0;
    const witnesses = store.liveWitnessesOnProfiles(["borrowed-a", "borrowed-b", "borrowed-c", "borrowed-empty"]);
    assert.equal(seen.length, 1, "single SQL query checks all requested profiles at once");
    for (const s of seen) {
      assert.deepEqual(scans(db, s.sql, s.args), [], `liveWitnessesOnProfiles must not scan: ${s.sql}`);
      const plan = (db.prepare(`EXPLAIN QUERY PLAN ${s.sql}`).all(...s.args) as { detail: string }[]).map((r) => String(r.detail)).join("\n");
      assert.match(plan, /SEARCH s USING (?:COVERING )?INDEX sessions_live_profile \(profile=\?\)/, plan);
    }
    assert.equal(witnesses.size, 1);
    assert.equal(witnesses.get("borrowed-a"), "chat:c-0000");
    assert.equal(witnesses.has("borrowed-b"), false);
    assert.equal(witnesses.has("borrowed-c"), false);
    assert.equal(witnesses.has("borrowed-empty"), false);
    assert.equal(store.liveWitnessesOnProfiles([]).size, 0);

    seen.length = 0;
    assert.deepEqual(store.liveSessionsOn("borrowed-a", 1), ["chat:c-0000"]);
    assert.deepEqual(store.liveSessionsOn("borrowed-b", 1), []);
    assert.deepEqual(store.liveSessionsOn("borrowed-c", 1), []);
    for (const s of seen) {
      assert.deepEqual(scans(db, s.sql, s.args), [], `liveSessionsOn must not scan: ${s.sql}`);
      const plan = (db.prepare(`EXPLAIN QUERY PLAN ${s.sql}`).all(...s.args) as { detail: string }[]).map((r) => String(r.detail)).join("\n");
      assert.match(plan, /SEARCH sessions USING (?:COVERING )?INDEX sessions_live_profile \(profile=\?\)/, plan);
    }
  } finally {
    store.close();
  }
});
