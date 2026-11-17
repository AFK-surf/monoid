// The steps src/store/archive-mark-index.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/archive-mark-index.ts's.
import type { DatabaseSync } from "node:sqlite";
import { parts, markers } from "../../../src/store/archive-mark-index.ts";

export * from "../../../src/store/archive-mark-index.ts";

export function archiveMarksStep(db: DatabaseSync, limit = 256): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("archive mark batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const all = markers(db);
    const meta = all.find((m) => m.complete !== 1);
    if (meta === undefined) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const { source, key, rows } = parts(meta.kind);
    const positions = (meta.last_rowid === null
      ? db.prepare(`SELECT CAST(rowid AS TEXT) AS position FROM ${source} WHERE rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`).all(meta.end_rowid, limit)
      : db.prepare(`SELECT CAST(rowid AS TEXT) AS position FROM ${source} WHERE rowid > CAST(? AS INTEGER) AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`).all(meta.last_rowid, meta.end_rowid, limit)) as { position: string }[];
    const put = db.prepare(`INSERT INTO ${rows} (${key}, position) SELECT s.${key}, s.rowid FROM ${source} s WHERE s.rowid = CAST(? AS INTEGER)
      AND NOT EXISTS (SELECT 1 FROM ${rows} i WHERE i.${key} IS s.${key} AND i.position = s.rowid)`);
    for (const row of positions) put.run(row.position);
    const finished = positions.length < limit;
    db.prepare("UPDATE archive_mark_meta SET last_rowid = CAST(? AS INTEGER), complete = ? WHERE kind = ?")
      .run(positions.at(-1)?.position ?? meta.last_rowid, finished ? 1 : 0, meta.kind);
    db.exec("COMMIT");
    return { done: finished && all.every((m) => m.kind === meta.kind || m.complete === 1), visited: positions.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}