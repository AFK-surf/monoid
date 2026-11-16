// The steps src/store/archive-policy-index.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/archive-policy-index.ts's.
import type { DatabaseSync } from "node:sqlite";

import { VERSION, BATCH, hasLegacyArchivePolicy, meta } from "../../../src/store/archive-policy-index.ts";

export * from "../../../src/store/archive-policy-index.ts";

/// Copy at most 64 old policy rows. The cursor and the copied rows commit with the triggers' concurrent changes.
export function archivePolicyIndexStep(db: DatabaseSync, limit = BATCH): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("policy batch must be 1–64");
  if (!hasLegacyArchivePolicy(db)) return { done: true, visited: 0 };
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = meta(db);
    if (m.version !== VERSION) throw new Error("unsupported archive policy preparation");
    if (m.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = m.end_id === null ? [] : (m.cursor === null
      ? db.prepare(`SELECT CAST(id AS TEXT) AS id FROM archive_policy WHERE id<=CAST(?1 AS INTEGER)
          ORDER BY archive_policy.id LIMIT ?2`).all(m.end_id, limit)
      : db.prepare(`SELECT CAST(id AS TEXT) AS id FROM archive_policy WHERE id>CAST(?1 AS INTEGER) AND id<=CAST(?2 AS INTEGER)
          ORDER BY archive_policy.id LIMIT ?3`).all(m.cursor, m.end_id, limit)) as { id: string }[];
    const put = db.prepare(`INSERT INTO archive_policy_lookup(id,ws) SELECT p.id,p.ws FROM archive_policy p
      WHERE p.id=CAST(?1 AS INTEGER) AND NOT EXISTS (SELECT 1 FROM archive_policy_lookup k WHERE k.id=p.id)`);
    for (const row of rows) put.run(row.id);
    const done = rows.length < limit;
    db.prepare("UPDATE archive_policy_lookup_meta SET cursor=CAST(? AS INTEGER),complete=? WHERE id=1")
      .run(rows.at(-1)?.id ?? m.cursor, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
