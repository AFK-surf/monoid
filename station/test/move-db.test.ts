import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { openMoveDb } from "../../apps/mbui/e2e/move-db.ts";
import { Store } from "../src/store/store.ts";

describe("apps/mbui/e2e/move-db", () => {
  it("writes sessions, threads, memberships, and messages readable by Store", () => {
    const dir = mkdtempSync(join(tmpdir(), "stillfail-move-db-"));
    try {
      const dbPath = join(dir, "stillfail.db");
      // Initialize the real station schema with Store.open, then close as the move drill does.
      const init = Store.open(dbPath);
      init.close();

      const moveDb = openMoveDb(dbPath);
      try {
        const at = 1_700_000_000_000;
        const key = "chat:c-0123456789abcdef0123456789abcdef";
        const workspace = join(dir, "sessions", "chat", "c-0123456789abcdef0123456789abcdef", "workspace");
        moveDb.insertSession({
          key,
          connect: "ember",
          runtime: "claude",
          profile: "cc",
          workspace,
          token: "tok-move-db-test",
          createdAt: at,
          lastActiveAt: at,
          ws: "ws-home",
          title: "seeded test 0",
        });

        const thread = moveDb.openThread("ember", "CHAT", "1700000000.000000", "seeded test 0", "alice@example.test");
        assert.ok(thread.id > 0);
        // Re-opening the same thread returns the existing row id.
        const threadAgain = moveDb.openThread("chat", "CHAT", "1700000000.000000", "other title", "bob@example.test");
        assert.equal(threadAgain.id, thread.id);

        assert.equal(moveDb.joinThread(thread.id, key, "ember"), true);
        assert.equal(moveDb.joinThread(thread.id, key, "chat"), false);

        const [n1, fresh1] = moveDb.insertMessage({
          thread: thread.id,
          ts: "1700000000.0000000",
          authorKind: "person",
          author: "alice@example.test",
          text: "first message",
          at: at + 10,
        });
        assert.equal(n1, 1);
        assert.equal(fresh1, true);

        // Duplicate ts is idempotent and returns the original n.
        const [n1Dup, freshDup] = moveDb.insertMessage({
          thread: thread.id,
          ts: "1700000000.0000000",
          authorKind: "person",
          author: "alice@example.test",
          text: "duplicate",
          at: at + 20,
        });
        assert.equal(n1Dup, 1);
        assert.equal(freshDup, false);

        const [n2, fresh2] = moveDb.insertMessage({
          thread: thread.id,
          ts: "1700000000.0000001",
          authorKind: "person",
          author: "alice@example.test",
          text: "second message",
          at: at + 30,
        });
        assert.equal(n2, 2);
        assert.equal(fresh2, true);
      } finally {
        moveDb.close();
      }

      // Verify Store reads back every written row without schema or normalization discrepancies.
      const store = Store.open(dbPath);
      try {
        const session = store.getSession("chat:c-0123456789abcdef0123456789abcdef");
        assert.ok(session !== null);
        assert.equal(session.connect, "chat");
        assert.equal(session.scope, "thread");
        assert.equal(session.title, "seeded test 0");
        assert.equal(session.runtime, "claude");
        assert.equal(session.profile, "cc");
        assert.equal(session.ws, "ws-home");

        const thread = store.threadAt("chat", "CHAT", "1700000000.000000");
        assert.ok(thread !== null);
        assert.equal(thread.surface, "chat");
        assert.equal(thread.title, "seeded test 0");
        assert.equal(thread.createdBy, "alice@example.test");

        const threads = store.sessionThreads(session.key);
        assert.equal(threads.length, 1);
        assert.equal(threads[0]?.thread.id, thread.id);
        assert.equal(threads[0]?.connect, "chat");

        const entries = store.entriesAfter(thread.id, 0);
        assert.equal(entries.length, 2);
        assert.equal(entries[0]?.n, 1);
        assert.equal(entries[0]?.text, "first message");
        assert.equal(entries[0]?.authorKind, "person");
        assert.equal(entries[0]?.author, "alice@example.test");
        assert.equal(entries[1]?.n, 2);
        assert.equal(entries[1]?.text, "second message");
      } finally {
        store.close();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
