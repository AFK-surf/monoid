// The steps src/store/legacy-edits-build.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/legacy-edits-build.ts's.
import type { DatabaseSync } from "node:sqlite";

import { VERSION, BATCH, hasLegacyEdits, proposed, installLegacyEdits, type Key, meta, limitOf } from "../../../src/store/legacy-edits-build.ts";

export * from "../../../src/store/legacy-edits-build.ts";

export function legacyEditStep(db: DatabaseSync, limit = BATCH): { ready: boolean; visited: number } {
  limitOf(limit);
  installLegacyEdits(db);
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = meta(db);
    if (m.version !== VERSION) throw new Error("unsupported legacy edit preparation");
    if (m.scanned) { db.exec("COMMIT"); return { ready: true,visited: 0 }; }
    const columns = "CAST(e.thread AS TEXT) thread,CAST(e.n AS TEXT) n";
    const rows: Key[] = [];
    if (m.end_thread !== null) {
      if (m.cursor_thread !== null) {
        const same = m.cursor_thread === m.end_thread;
        const sql = `SELECT ${columns} FROM entries e WHERE e.thread=CAST(?1 AS INTEGER) AND e.n>CAST(?2 AS INTEGER)
          ${same ? "AND e.n<=CAST(?3 AS INTEGER) ORDER BY e.n LIMIT ?4" : "ORDER BY e.n LIMIT ?3"}`;
        rows.push(...(same ? db.prepare(sql).all(m.cursor_thread,m.cursor_n,m.end_n,limit)
          : db.prepare(sql).all(m.cursor_thread,m.cursor_n,limit)) as Key[]);
      }
      if (rows.length < limit && m.cursor_thread !== m.end_thread) {
        const sql = `SELECT ${columns} FROM entries e WHERE e.thread<CAST(?1 AS INTEGER)
          ${m.cursor_thread === null ? "" : "AND e.thread>CAST(?2 AS INTEGER)"}
          ORDER BY e.thread,e.n LIMIT ?${m.cursor_thread === null ? 2 : 3}`;
        rows.push(...(m.cursor_thread === null ? db.prepare(sql).all(m.end_thread,limit-rows.length)
          : db.prepare(sql).all(m.end_thread,m.cursor_thread,limit-rows.length)) as Key[]);
        if (rows.length < limit) rows.push(...db.prepare(`SELECT ${columns} FROM entries e
          WHERE e.thread=CAST(?1 AS INTEGER) AND e.n<=CAST(?2 AS INTEGER) ORDER BY e.n LIMIT ?3`)
          .all(m.end_thread,m.end_n,limit-rows.length) as Key[]);
      }
    }
    // Keep target values inside SQLite: old stores can contain non-integer values and integers outside JS's range.
    const put = db.prepare(`INSERT INTO legacy_edit_build(thread,target,n)
      SELECT e.thread,e.target,e.n FROM entries e WHERE e.thread=CAST(?1 AS INTEGER) AND e.n=CAST(?2 AS INTEGER)
        AND e.target IS NOT NULL AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=e.thread AND d.n=e.n)
      ON CONFLICT(thread,target,n) DO NOTHING`);
    for (const row of rows) put.run(row.thread,row.n);
    const last = rows.at(-1), ready = rows.length < limit;
    db.prepare("UPDATE legacy_edit_meta SET scanned=?,cursor_thread=CAST(? AS INTEGER),cursor_n=CAST(? AS INTEGER) WHERE id=1")
      .run(ready ? 1 : 0,last?.thread ?? m.cursor_thread,last?.n ?? m.cursor_n);
    db.exec("COMMIT");
    return { ready,visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function legacyEditDrain(db: DatabaseSync, limit = BATCH): number {
  limitOf(limit);
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = meta(db);
    if (m.version !== VERSION) throw new Error("unsupported legacy edit preparation");
    if (!m.scanned) { db.exec("COMMIT"); return 0; }
    const first = db.prepare("SELECT CAST(d.thread AS TEXT) thread,CAST(d.n AS TEXT) n FROM legacy_edit_dirty d ORDER BY d.thread,d.n LIMIT 1");
    // A key can have arbitrarily many proposed targets. Remove at most this batch's budget before folding the key.
    const extras = db.prepare(`SELECT target FROM legacy_edit_targets INDEXED BY legacy_edit_targets_by_key
      WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?2 AS INTEGER)
        AND target IS NOT (SELECT target FROM entries WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?2 AS INTEGER))
      ORDER BY target LIMIT ?3`);
    extras.setReadBigInts(true);
    const dropTarget = db.prepare("DELETE FROM legacy_edit_targets WHERE thread=CAST(? AS INTEGER) AND target IS ? AND n=CAST(? AS INTEGER)");
    const drop = db.prepare(`DELETE FROM legacy_edit_build WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?2 AS INTEGER)
      AND target IS (SELECT old_target FROM legacy_edit_dirty WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?2 AS INTEGER))`);
    const put = db.prepare(`INSERT INTO legacy_edit_build(thread,target,n)
      SELECT thread,target,n FROM entries WHERE thread=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)
        AND target IS NOT NULL ON CONFLICT(thread,target,n) DO NOTHING`);
    const dropCurrent = db.prepare(`DELETE FROM legacy_edit_targets WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?2 AS INTEGER)
      AND target IS (SELECT target FROM entries WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?2 AS INTEGER))`);
    const done = db.prepare("DELETE FROM legacy_edit_dirty WHERE thread=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)");
    let visited = 0;
    while (visited < limit) {
      const key = first.get() as Key | undefined;
      if (!key) break;
      const oldTargets = extras.all(key.thread,key.n,limit-visited) as { target: string | number | bigint | Uint8Array }[];
      for (const target of oldTargets) { dropTarget.run(key.thread,target.target,key.n); visited++; }
      if (visited === limit) break;
      drop.run(key.thread,key.n); put.run(key.thread,key.n); dropCurrent.run(key.thread,key.n); done.run(key.thread,key.n);
      visited++;
    }
    db.exec("COMMIT");
    return visited;
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function legacyEditsMaintenanceStep(db: DatabaseSync): { done: boolean; visited: number } {
  if (!hasLegacyEdits(db)) return { done: true,visited: 0 };
  if (!meta(db).scanned) {
    const result=legacyEditStep(db);
    return { done: false,visited: result.visited };
  }
  const visited=legacyEditDrain(db);
  return { done: visited < BATCH,visited };
}
