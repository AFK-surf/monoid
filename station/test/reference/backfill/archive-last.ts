// The steps src/store/archive-last.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/archive-last.ts's.
import type { DatabaseSync } from "node:sqlite";
import { VERSION, checked, schema, installArchiveLast, archiveLast } from "../../../src/store/archive-last.ts";

export * from "../../../src/store/archive-last.ts";

const BATCH = 64;
export const ARCHIVE_LAST_SLICE_FIRST = `SELECT CAST(e.n AS TEXT) AS n,CASE WHEN e.kind='message' THEN e.at END AS at
  FROM entries e WHERE e.thread=? ORDER BY e.n DESC LIMIT ?`;
export const ARCHIVE_LAST_SLICE_BEFORE = `SELECT CAST(e.n AS TEXT) AS n,CASE WHEN e.kind='message' THEN e.at END AS at
  FROM entries e WHERE e.thread=?1 AND e.n<CAST(?2 AS INTEGER) ORDER BY e.n DESC LIMIT ?3`;
/// The same guarded answer for a reader that needs the complete message.
export function archiveLastKey(db: DatabaseSync, thread: number): { known: boolean; n: string | null } {
  const { known, n } = archiveLast(db, thread, true);
  return { known, n };
}
/// Each transaction advances at most 64 source entries. Progress is shared between openers and rolls back with them.
export function archiveLastStep(db: DatabaseSync, thread: number, limit = BATCH): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("archive last batch must be 1–64");
  if (!installArchiveLast(db)) return { done: false, visited: 0 };
  const version = checked.get(db)!;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (schema(db) !== version) { db.exec("COMMIT"); return { done: false, visited: 0 }; }
    const meta = db.prepare("SELECT version,epoch FROM archive_last_meta WHERE id=1").get() as
      { version: number; epoch: string } | undefined;
    if (!meta) { db.exec("COMMIT"); checked.delete(db); return { done: false, visited: 0 }; }
    if (meta.version !== VERSION) throw new Error("archive last metadata has an unsupported version");
    const epoch = meta.epoch;
    db.prepare(`INSERT INTO archive_last_guard(thread,epoch,before_n,at,ready) VALUES(?,?,NULL,NULL,0)
      ON CONFLICT(thread) DO UPDATE SET epoch=excluded.epoch,before_n=NULL,at=NULL,ready=0
        WHERE archive_last_guard.epoch!=excluded.epoch`).run(thread, epoch);
    const state = db.prepare(`SELECT CAST(before_n AS TEXT) AS before_n,at,ready FROM archive_last_guard
      WHERE thread=? AND epoch=?`).get(thread, epoch) as { before_n: string | null; at: number | null; ready: number };
    // A ready guard from the earlier time-only worker has no key. Reuse its time for archive reads, but rescan it
    // when a message is requested. Older workers ignore before_n on ready rows, so they can share the same guard.
    if (state.ready && (state.before_n !== null || state.at === null)) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = (state.before_n === null
      ? db.prepare(ARCHIVE_LAST_SLICE_FIRST).all(thread, limit)
      : db.prepare(ARCHIVE_LAST_SLICE_BEFORE).all(thread, state.before_n, limit)) as { n: string; at: number | null }[];
    const last = rows.find((row) => row.at !== null);
    const done = last !== undefined || rows.length < limit;
    db.prepare(`UPDATE archive_last_guard SET before_n=CAST(? AS INTEGER),at=?,ready=? WHERE thread=? AND epoch=?`)
      .run(last?.n ?? (done ? null : rows.at(-1)!.n), last?.at ?? null, done ? 1 : 0, thread, epoch);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}