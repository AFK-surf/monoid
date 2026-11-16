// The steps src/store/legacy-decision-time.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/legacy-decision-time.ts's.
import type { DatabaseSync } from "node:sqlite";

import { VERSION, BATCH, hasLegacyDecisionTime, meta } from "../../../src/store/legacy-decision-time.ts";

export * from "../../../src/store/legacy-decision-time.ts";

/// Copy at most 64 ids, in the same transaction as progress; trigger updates are already reflected in the source.
export function decisionTimeIndexStep(db: DatabaseSync, limit = BATCH): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("decision-time batch must be 1–64");
  if (!hasLegacyDecisionTime(db)) return { done: true, visited: 0 };
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = meta(db);
    if (m.version !== VERSION) throw new Error("unsupported legacy decision-time preparation");
    if (m.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = m.end_id === null ? [] : (m.cursor === null
      ? db.prepare(`SELECT CAST(id AS TEXT) id FROM decision_checks WHERE id<=CAST(?1 AS INTEGER)
          ORDER BY decision_checks.id LIMIT ?2`).all(m.end_id, limit)
      : db.prepare(`SELECT CAST(id AS TEXT) id FROM decision_checks WHERE id>CAST(?1 AS INTEGER) AND id<=CAST(?2 AS INTEGER)
          ORDER BY decision_checks.id LIMIT ?3`).all(m.cursor, m.end_id, limit)) as { id: string }[];
    const put = db.prepare(`INSERT INTO legacy_decision_time(id,created_at,session)
      SELECT id,created_at,session FROM decision_checks d WHERE d.id=CAST(?1 AS INTEGER)
        AND NOT EXISTS (SELECT 1 FROM legacy_decision_time l WHERE l.id=d.id)`);
    for (const row of rows) put.run(row.id);
    const done = rows.length < limit;
    db.prepare("UPDATE legacy_decision_time_meta SET cursor=CAST(? AS INTEGER),complete=? WHERE id=1")
      .run(rows.at(-1)?.id ?? m.cursor, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
