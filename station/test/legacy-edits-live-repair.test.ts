import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { Readers } from "../src/read/pool.ts";
import { makeStore, messagesBefore, stateQuestion } from "./reference/store.ts";
import { installLegacyEdits, legacyEditStep } from "./reference/backfill/legacy-edits-build.ts";
import { addClientColumn, repairMergedEditLookup } from "../src/store/schema.ts";
import { Store } from "../src/store/store.ts";

for (const installed of [false, true]) {
  test(`a removed native index is repaired for question and page readers (old lookup installed: ${installed})`, async () => {
    const dir = mkdtempSync(join(tmpdir(), "live-edit-repair-"));
    const store = Store.open(join(dir, "stillfail.db")), db = store.db;
    const readers = new Readers(dir, 1, undefined, 1);
    // (the station's writer repairs what the builder leaves to it, services.ts; without one, readers of a test's make
    // their own connection for it)
    if (installed) readers.repairEdits = () => repairMergedEditLookup(db);
    try {
      const thread = store.openThread("ember", "CHAT", "old", null, null).id;
      db.prepare(`INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at)
        VALUES(?,1,'message','ask','agent','worker','May I?',1)`).run(thread);
      const edit = db.prepare("INSERT INTO entries(thread,n,kind,target,author_kind,author,text,at) VALUES(?,?,'edit',?,'agent','worker',?,?)");
      edit.run(thread, 2, 1, "   ", 2);
      for (let n = 3; n <= 151; n++) edit.run(thread, n, n + 1000, "other", n);
      db.exec("DROP INDEX entries_edits");
      if (installed) installLegacyEdits(db);
      const read = makeStore(db, dir), question = { key: "worker", threads: [thread], ts: "ask" };
      assert.deepEqual(stateQuestion(read, "worker", [thread], "absent"), { kind: "missing" });
      assert.throws(() => stateQuestion(read, "worker", [thread], "ask"), /legacy edit lookup pending/);
      assert.throws(() => messagesBefore(read, thread, null, 1), /legacy edit lookup pending/);
      const [found, page] = await Promise.all([
        readers.read("stateQuestion", question, "en").then(JSON.parse),
        readers.read("latestMessages", { thread, limit: 1 }, "en").then(JSON.parse),
      ]);
      assert.deepEqual(found, { kind: "invalid" });
      assert.equal(page.length, 1);
      assert.equal(page[0].text, "   ");
      assert.match(String(db.prepare("SELECT sql FROM sqlite_master WHERE type='view' AND name='merged'").get()?.sql), /legacy_edit_meta/);
      assert.equal(db.prepare("SELECT scanned FROM legacy_edit_meta WHERE id=1").get()?.scanned, 1);
    } finally { readers.close(); store.close(); rmSync(dir, { recursive: true, force: true }); }
  });
}

for (const prepared of [false, true]) {
  test(`a removed older target index is repaired while reading a question (prepared: ${prepared})`, async () => {
    const dir = mkdtempSync(join(tmpdir(), "live-old-index-repair-"));
    const store = Store.open(join(dir, "stillfail.db")), db = store.db;
    const readers = new Readers(dir, 1, undefined, 1);
    // (the station's writer repairs what the builder leaves to it: services.ts)
    readers.repairEdits = () => repairMergedEditLookup(db);
    try {
      const thread = store.openThread("ember", "CHAT", "old", null, null).id;
      db.prepare(`INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at)
        VALUES(?,1,'message','ask','agent','worker','May I?',1)`).run(thread);
      const edit = db.prepare("INSERT INTO entries(thread,n,kind,target,author_kind,author,text,at) VALUES(?,?,'edit',?,'agent','worker',?,?)");
      edit.run(thread, 2, 1, "   ", 2);
      for (let n = 3; n <= 151; n++) edit.run(thread, n, n + 1000, "other", n);
      db.exec("DROP INDEX entries_edits; CREATE INDEX entries_target ON entries(thread,target) WHERE target IS NOT NULL");
      installLegacyEdits(db);
      addClientColumn(db);
      if (prepared) while (!legacyEditStep(db).ready) { /* prepare */ }
      db.exec("DROP INDEX entries_target");
      const read = makeStore(db, dir);
      assert.throws(() => stateQuestion(read, "worker", [thread], "ask"), /legacy edit lookup pending/);
      assert.deepEqual(JSON.parse(await readers.read("stateQuestion", { key: "worker", threads: [thread], ts: "ask" }, "en")), { kind: "invalid" });
      assert.equal(db.prepare("SELECT old_index FROM legacy_edit_meta WHERE id=1").get()?.old_index, 0);
      assert.doesNotMatch(String(db.prepare("SELECT sql FROM sqlite_master WHERE type='view' AND name='merged'").get()?.sql), /INDEXED BY entries_target/);
    } finally { readers.close(); store.close(); rmSync(dir, { recursive: true, force: true }); }
  });
}

test("a repair that finds another's write under way waits for no lock and is tried again once it is done", async () => {
  const dir = mkdtempSync(join(tmpdir(), "live-edit-repair-busy-"));
  const path = join(dir, "stillfail.db"), store = Store.open(path), db = store.db;
  const other = new DatabaseSync(path, { timeout: 0 });
  const readers = new Readers(dir, 1, undefined, 1);
  // (the writer's repair as services.ts makes it: a lock held elsewhere is SQLITE_BUSY at once, never waited for)
  const writer = new DatabaseSync(path, { timeout: 0 });
  const busy = Promise.withResolvers<void>();
  let tries = 0;
  readers.repairEdits = () => {
    tries++;
    try { repairMergedEditLookup(writer); }
    catch (error) { if (((error as { errcode?: number }).errcode ?? 0) % 256 === 5) busy.resolve(); throw error; }
  };
  try {
    const thread = store.openThread("ember", "CHAT", "old", null, null).id;
    db.prepare(`INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at)
      VALUES(?,1,'message','ask','agent','worker','May I?',1)`).run(thread);
    const edit = db.prepare("INSERT INTO entries(thread,n,kind,target,author_kind,author,text,at) VALUES(?,?,'edit',?,'agent','worker',?,?)");
    edit.run(thread, 2, 1, "   ", 2);
    for (let n = 3; n <= 151; n++) edit.run(thread, n, n + 1000, "other", n);
    db.exec("DROP INDEX entries_edits");
    other.exec("BEGIN IMMEDIATE");
    let settled = false;
    const found = readers.read("stateQuestion", { key: "worker", threads: [thread], ts: "ask" }, "en")
      .finally(() => { settled = true; });
    await busy.promise;
    assert.equal(settled, false, "the read waits on, failing nothing, while the other write holds the lock");
    other.exec("COMMIT");
    assert.deepEqual(JSON.parse(await found), { kind: "invalid" });
    assert.ok(tries >= 2, `${tries} tries`);
    assert.match(String(db.prepare("SELECT sql FROM sqlite_master WHERE type='view' AND name='merged'").get()?.sql), /legacy_edit_meta/);
  } finally { readers.close(); other.close(); writer.close(); store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("an index removed after a question snapshot is still usable in that snapshot", () => {
  const dir = mkdtempSync(join(tmpdir(), "live-edit-snapshot-"));
  const path = join(dir, "stillfail.db"), store = Store.open(path), writer = new DatabaseSync(path);
  try {
    const thread = store.openThread("ember", "CHAT", "snapshot", null, null).id;
    store.db.prepare(`INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at)
      VALUES(?,1,'message','ask','agent','worker','May I?',1)`).run(thread);
    let removed = false;
    const observed = new Proxy(store.db, { get(target, property) {
      if (property === "prepare") return (sql: string) => {
        const statement = target.prepare(sql);
        if (sql.includes("FROM entries") && sql.includes("ts = ?") && sql.includes("kind = 'message'")) {
          return new Proxy(statement, { get(stmt, member) {
            if (member === "get") return (...args: Parameters<typeof stmt.get>) => {
              const row = stmt.get(...args);
              if (!removed) { removed = true; writer.exec("DROP INDEX entries_edits"); }
              return row;
            };
            const value = Reflect.get(stmt, member, stmt);
            return typeof value === "function" ? value.bind(stmt) : value;
          } });
        }
        return statement;
      };
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    } });
    const read = makeStore(observed, dir);
    assert.deepEqual(stateQuestion(read, "worker", [thread], "ask"), { kind: "found", about: [thread, 1, "ask"] });
    assert.equal(removed, true);
    assert.throws(() => stateQuestion(read, "worker", [thread], "ask"), /legacy edit lookup pending/);
  } finally { writer.close(); store.close(); rmSync(dir, { recursive: true, force: true }); }
});
