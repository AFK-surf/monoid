// The fill of the compactions' calls (usage_main_calls) in TypeScript, which the station no longer runs: the contexts
// kept by the database (src/store/usage-compact.ts) replaced them, and what is left of them is freed by the usage
// retirement (station/mb src/usagefill). Kept for the tests of the triggers it went with (usage-compactions-index).
import type { DatabaseSync } from "node:sqlite";

/// The cursor, calls and resulting compactions commit together. New writes are indexed by the trigger even if their
/// rowid falls inside the remaining range; INSERT OR IGNORE makes a later pass over one harmless.
export function backfillUsageCompactions(db: DatabaseSync, limit = 32): { done: boolean; processed: number } {
  db.exec("BEGIN IMMEDIATE");
  try {
    const state = db.prepare("SELECT after_rowid, end_rowid, done FROM usage_compaction_backfill WHERE id = 1").get() as { after_rowid: number | null; end_rowid: number; done: number };
    if (state.done) {
      db.exec("COMMIT");
      return { done: true, processed: 0 };
    }
    const columns = "SELECT rowid, session, at, id, profile, model, context, subagent FROM usage";
    const rows = (state.after_rowid === null
      ? db.prepare(`${columns} WHERE rowid <= ? ORDER BY rowid LIMIT ?`).all(state.end_rowid, limit)
      : db.prepare(`${columns} WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?`).all(state.after_rowid, state.end_rowid, limit)) as {
        rowid: number; session: string; at: number; id: string; profile: string | null; model: string | null; context: number | null; subagent: number;
      }[];
    const insert = db.prepare("INSERT OR IGNORE INTO usage_main_calls VALUES (?, ?, ?, ?, ?, ?)");
    for (const r of rows) if (r.subagent === 0) insert.run(r.session, r.at, r.id, r.profile, r.model, r.context);
    const after = rows.at(-1)?.rowid ?? state.end_rowid;
    const done = rows.length < limit || after >= state.end_rowid;
    db.prepare("UPDATE usage_compaction_backfill SET after_rowid = ?, done = ? WHERE id = 1").run(after, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, processed: rows.length };
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}
