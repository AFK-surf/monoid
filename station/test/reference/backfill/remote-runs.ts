// The fill of the remote tasks' index (remote_run_lookup) from the runs of before it, in TypeScript, which the station
// runs nowhere: the triggers of src/store/remote-runs.ts keep it from its install on. Kept for its tests.
import type { DatabaseSync } from "node:sqlite";
import { WS } from "../../../src/store/remote-runs.ts";

/// Fill no more than `limit` old rows; writes, deletions, and the cursor commit together.
export function backfillRemoteRuns(db: DatabaseSync, limit = 32): { done: boolean; processed: number } {
  db.exec("BEGIN IMMEDIATE");
  try {
    const state = db.prepare("SELECT after_seq, end_seq, done FROM remote_run_progress WHERE id = 1").get() as
      { after_seq: number | null; end_seq: number | null; done: number };
    if (state.done) {
      db.exec("COMMIT");
      return { done: true, processed: 0 };
    }
    const rows = (state.after_seq === null
      ? db.prepare("SELECT rowid AS seq, at FROM remote_runs WHERE rowid <= ? ORDER BY rowid LIMIT ?").all(state.end_seq, limit)
      : db.prepare("SELECT rowid AS seq, at FROM remote_runs WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?").all(state.after_seq, state.end_seq, limit)) as
      { seq: number; at: number }[];
    const add = db.prepare(`INSERT OR IGNORE INTO remote_run_lookup
      SELECT ${WS("r")}, r.at, r.rowid, r.job, r.session FROM remote_runs r WHERE r.rowid = ?`);
    for (const row of rows) add.run(row.seq);
    const done = rows.length < limit;
    db.prepare("UPDATE remote_run_progress SET after_seq = ?, done = ? WHERE id = 1")
      .run(rows.at(-1)?.seq ?? state.after_seq, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, processed: rows.length };
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}
