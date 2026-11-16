// The MoonBit checker of the kept statistics' coverage (station/mb, src/usage) answers as the minute worker did (its
// checks, `reference`): in the same states of the remote tasks and chat statistics, for the same viewers, the same
// answers. (What was spent is counted as it is written, store/usage-15m.ts: nothing of it to check.)
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import type { InWorkspace } from "../src/store/rows.ts";
import { Store } from "../src/store/store.ts";
import { usageChatStatsReady } from "../src/store/usage-chat-stats.ts";
import { MinuteReader } from "../src/usage/minute-reader.ts";

const binary = mbReaderBinary();

const viewers = [null, { workspace: "A", home: false }, { workspace: "A", home: true }, { workspace: "B", home: false }];

/// What each reader answers to every kind of ask, for every viewer: "ok" or its error.
async function answers(reader: MinuteReader): Promise<string[]> {
  const out: string[] = [];
  const said = (p: Promise<void>) => p.then(() => "ok", (e: Error) => e.message);
  for (const v of viewers) out.push(await said(reader.readyChats(v)));
  out.push(await said(reader.readyRemote()));
  return out;
}

/// What the minute worker answered (usage/minute-worker.ts before the program took it), on a read-only connection:
/// all "ok" once every statistic is complete, else each ask's.
function reference(path: string): string[] {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const installed = (name: string) => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) !== undefined;
    const remote = () => !installed("remote_run_progress") || (db.prepare("SELECT done FROM remote_run_progress WHERE id = 1").get() as { done: number } | undefined)?.done === 1;
    const chats = (v: InWorkspace | null) => !installed("usage_chat_progress") || usageChatStatsReady(db, v);
    const complete = remote() && chats(null);
    const said = (ready: boolean, name: string) => complete || ready ? "ok" : `historical ${name} statistics are unavailable`;
    const out: string[] = [];
    for (const v of viewers) out.push(said(chats(v), "chat and card"));
    out.push(said(remote(), "remote task"));
    return out;
  } finally { db.close(); }
}

/// The states: fresh (every statistic complete), then each made incomplete in turn, for a workspace or for all.
const states: [string, string][] = [
  ["fresh", ""],
  ["remote tasks not filled", "UPDATE remote_run_progress SET done = 0"],
  ["chats not filled", "UPDATE usage_chat_progress SET done = 0"],
  // (with the remote tasks not filled too, so that the checker is asked rather than all being complete)
  ["a session of A moved", "UPDATE remote_run_progress SET done = 0; INSERT INTO usage_chat_dirty_scope(session, kind, ws) VALUES ('s', 2, 'A')"],
  ["a home session moved", "UPDATE remote_run_progress SET done = 0; INSERT INTO usage_chat_dirty_scope(session, kind, ws) VALUES ('s', 1, '')"],
  ["card outcomes incomplete", "CREATE TABLE card_outcomes_incomplete (x)"],
];

for (const [name, sql] of states) {
  test(`the MoonBit checker answers as the minute worker: ${name}`, async () => {
    assert.notEqual(binary, null, "the MoonBit reader is built (station/mb/build.sh, or STILLFAIL_MB_READER)");
    const dir = mkdtempSync(join(tmpdir(), "mb-usage-check-"));
    const path = join(dir, "stillfail.db");
    const store = Store.open(path, join(dir, "archive"));
    if (sql) store.db.exec(sql);
    const moonbit = new MinuteReader(path, {}, binary!);
    try {
      const theirs = reference(path);
      assert.deepEqual(await answers(moonbit), theirs);
      // (each state is one a reader tells apart: fresh is all complete, the others are not)
      assert.equal(theirs.every((a) => a === "ok"), name === "fresh", JSON.stringify(theirs));
    } finally {
      await moonbit.close();
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
}
