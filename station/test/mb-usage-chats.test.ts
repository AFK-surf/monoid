// The chats of the sessions that moved between workspaces given their new workspace by the MoonBit program (station/mb
// src/usagefill `drain_chat_dirty_step`, reader `--builder usage-retire` asked `{drainChats}`) as the TypeScript it
// replaced does (test/reference/backfill/usage-chats.ts `drainUsageChatDirty`): the same answers and tables step by
// step, through moves of workspace, of key and sessions gone, a session's chats over several batches. And how the
// station runs it (usage/module.ts `drainUsageChats`): no program while no session waits, none asked while a write of
// the station's own is announced, pages told once all are counted, and the program gone after.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { drainUsageChats } from "../src/usage/module.ts";
import { drainUsageChatDirty } from "./reference/backfill/usage-chats.ts";

const binary = mbReaderBinary();

const session = (store: Store, key: string, ws: string | null) => store.insertSession({ key, connect: "ember", runtime: "claude",
  profile: "cc", workspace: `/w/${key}`, token: key, ws, createdAt: 1, lastActiveAt: 1 } as Parameters<Store["insertSession"]>[0]);

/// Sessions in two workspaces and the home one, in 90 chats (a's in 45 of them, over several batches), cards in some.
function world() {
  const dir = mkdtempSync(join(tmpdir(), "mb-usage-chats-"));
  const path = join(dir, "stillfail.db");
  const store = Store.open(path, join(dir, "archive"));
  for (const [key, ws] of [["a", "A"], ["b", "A"], ["c", null], ["d", "B"]] as const) session(store, key, ws);
  for (let i = 0; i < 90; i++) {
    const thread = store.openThread("ember", "CHAT", `t${i}`, `Chat ${i}`, null).id;
    store.joinThread(thread, i % 2 === 0 ? "a" : "b", "ember");
    if (i % 5 === 0) store.joinThread(thread, "c", "ember");
    if (i % 7 === 0) store.joinThread(thread, "d", "ember");
  }
  return { dir, path, store, close: () => { store.close(); rmSync(dir, { recursive: true, force: true }); } };
}

/// The moves both sides are given: a workspace's sessions moved, one moved again, one's key changed, one gone.
const MOVES = [
  "UPDATE sessions SET ws = 'B' WHERE ws = 'A'",
  "UPDATE sessions SET ws = 'C' WHERE key = 'a'",
  "UPDATE sessions SET key = 'b2' WHERE key = 'b'",
  "DELETE FROM sessions WHERE key = 'd'",
  "UPDATE sessions SET ws = NULL WHERE key = 'a'",
];

/// Every row of the chats' statistics, a line each, sorted.
function tables(store: Store): string[] {
  const db = store.db;
  const names = (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'usage_chat%' ORDER BY name").all() as { name: string }[]).map((r) => r.name);
  return names.flatMap((name) => (db.prepare(`SELECT * FROM "${name}"`).all() as object[]).map((r) => `${name} ${JSON.stringify(r)}`)).sort();
}

function asker(path: string) {
  const program = new MbProcess(binary!, ["--builder", "usage-retire", "--db", path]);
  const ask = (message: object) => {
    const answered = new Promise<{ done: boolean; error?: string }>((resolve) => program.once("message", resolve));
    program.postMessage(message);
    return answered;
  };
  return { program, ask };
}

test("the MoonBit program gives the moved sessions' chats their workspace as the TypeScript did, step by step", async () => {
  assert.notEqual(binary, null, "the MoonBit reader is built (station/mb/build.sh, or STILLFAIL_MB_READER)");
  const ts = world(), mb = world();
  const { program, ask } = asker(mb.path);
  try {
    assert.deepEqual(await ask({ drainChats: 8 }), { done: true }, "none waits: done at once");
    same(tables(mb.store), tables(ts.store), "before");
    let steps = 0, paged = false;
    for (const move of MOVES) {
      ts.store.db.exec(move);
      mb.store.db.exec(move);
      same(tables(mb.store), tables(ts.store), move);
      assert.ok(ts.store.db.prepare("SELECT 1 FROM usage_chat_dirty LIMIT 1").get(), `${move}: a session waits`);
      for (let done = false, n = 0; !done; n++) {
        assert.ok(n < 40, `${move}: done within 40 steps`);
        const ours = await ask({ drainChats: 8 });
        assert.equal(ours.error, undefined);
        const theirs = drainUsageChatDirty(ts.store.db, 8);
        assert.equal(ours.done, theirs.done, `${move}, step ${n}`);
        paged ||= ts.store.db.prepare("SELECT 1 FROM usage_chat_dirty WHERE thread_after IS NOT NULL").get() !== undefined;
        same(tables(mb.store), tables(ts.store), `${move}, step ${n}`);
        done = ours.done;
        steps++;
      }
    }
    assert.ok(paged, "a session's chats went over several batches");
    assert.ok(steps >= 15, `${steps} steps`);
    assert.equal(mb.store.db.prepare("SELECT 1 FROM usage_chat_dirty LIMIT 1").get(), undefined);
    // a size under one is one
    mb.store.db.exec(MOVES[0]!.replace("'A'", "'C'"));
    for (let n = 0; n < 100 && !(await ask({ drainChats: 0 })).done; n++);
    assert.equal(mb.store.db.prepare("SELECT 1 FROM usage_chat_dirty LIMIT 1").get(), undefined);
    // where the chats' statistics are not there: none waits
    mb.store.db.exec("DROP TABLE usage_chat_dirty");
    assert.deepEqual(await ask({ drainChats: 8 }), { done: true });
  } finally {
    await program.terminate();
    ts.close();
    mb.close();
  }
});

/// The lines only one side has, none when the same.
function same(ours: string[], theirs: string[], what: string) {
  const a = new Set(ours), b = new Set(theirs);
  assert.deepEqual({ ours: ours.filter((r) => !b.has(r)).slice(0, 5), theirs: theirs.filter((r) => !a.has(r)).slice(0, 5) }, { ours: [], theirs: [] }, what);
}

test("the station starts the program only when a session waits, asks it nothing during its own writes, and lets it go", { skip: process.platform === "win32" && "a shell script stands for the program" }, async () => {
  assert.notEqual(binary, null, "the MoonBit reader is built (station/mb/build.sh, or STILLFAIL_MB_READER)");
  const f = world();
  // (the program as the station starts it, each start's pid written down)
  const starts = join(f.dir, "starts"), wrapper = join(f.dir, "reader.sh");
  writeFileSync(wrapper, `#!/bin/sh\necho $$ >> '${starts}'\nexec '${binary}' "$@"\n`);
  chmodSync(wrapper, 0o755);
  const started = () => existsSync(starts) ? readFileSync(starts, "utf8").trim().split("\n").map(Number) : [];
  const told: unknown[] = [];
  const unsubscribe = f.store.subscribe((change) => { if (change.type === "usage") told.push(change); });
  const drain = drainUsageChats(f.store, Promise.resolve(), 8, wrapper);
  const priority = new Int32Array(f.store.backfillPriority);
  try {
    await new Promise<void>((resolve) => setImmediate(resolve));
    await drain.drained();
    assert.deepEqual(started(), [], "none waits as the station before has gone: no program");
    // a workspace of no session's moved: told, none waits
    f.store.setSessionsWs("Z", "Y");
    await drain.drained();
    assert.deepEqual(started(), [], "none waits after a move of no chats: no program");
    assert.deepEqual(told, []);

    // A write of the station's own announced: the program is asked nothing. (Turns of the loop only to give it the
    // chance: while the write is announced, none can be counted however many go by.)
    Atomics.add(priority, 0, 1);
    f.store.setSessionsWs("A", "B");
    const waiting = () => (f.store.db.prepare("SELECT COUNT(*) AS n FROM usage_chat_dirty").get() as { n: number }).n;
    assert.equal(waiting(), 2);
    const moved = () => (f.store.db.prepare("SELECT COUNT(*) AS n FROM usage_chat_members WHERE ws = 'B' AND session IN ('a', 'b')").get() as { n: number }).n;
    for (let i = 0; i < 50; i++) await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(waiting(), 2, "nothing counted while the station writes");
    assert.equal(moved(), 0);
    assert.deepEqual(told, []);
    Atomics.sub(priority, 0, 1);
    await drain.drained();
    assert.equal(waiting(), 0);
    assert.equal(moved(), 90);
    assert.deepEqual(told, [{ type: "usage", sessions: [], statisticsOnly: true }], "pages open told once");
    assert.equal(Atomics.load(priority, 1), 0, "the permit given back");
    const [pid, ...more] = started();
    assert.deepEqual(more, [], "one program for all of it");
    assert.throws(() => process.kill(pid!, 0), { code: "ESRCH" }, "the program let go once none waits");

    // moved again: a program of its own, let go again
    f.store.db.exec("UPDATE sessions SET ws = 'C' WHERE key = 'a'");
    f.store.setSessionsWs("B", "D");
    await drain.drained();
    assert.equal(waiting(), 0);
    assert.equal(started().length, 2);
    assert.throws(() => process.kill(started()[1]!, 0), { code: "ESRCH" });
    assert.equal(told.length, 2);
  } finally {
    drain.stop();
    unsubscribe();
    f.close();
  }
});
