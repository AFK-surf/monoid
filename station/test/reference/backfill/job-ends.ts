// The step the session backfill copies an old store's jobs into job_ends by (`job-ends`: station/mb/src/legacy
// `job_ends_step` and pion/station builders_legacy `job_ends_step`), in TypeScript to compare the programs with: the
// station has no step in TypeScript to fall back to. What it runs of it is src/store/job-ends.ts's.
import type { DatabaseSync } from "node:sqlite";

import { BATCH, hasJobEnds, jobEndsMeta, VERSION } from "../../../src/store/job-ends.ts";

export * from "../../../src/store/job-ends.ts";

/// Copy at most 64 of the jobs the store had, by rowid. The cursor and the copied jobs commit with the triggers' changes.
export function jobEndsStep(db: DatabaseSync, limit = BATCH): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("job ends batch must be 1–64");
  if (!hasJobEnds(db)) return { done: true, visited: 0 };
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = jobEndsMeta(db);
    if (m === undefined || m.version !== VERSION) throw new Error("unsupported preparation of the jobs' ends");
    if (m.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = m.end_id === null ? [] : (m.cursor === null
      ? db.prepare("SELECT CAST(rowid AS TEXT) AS id FROM jobs WHERE rowid<=CAST(?1 AS INTEGER) ORDER BY jobs.rowid LIMIT ?2").all(m.end_id, limit)
      : db.prepare(`SELECT CAST(rowid AS TEXT) AS id FROM jobs WHERE rowid>CAST(?1 AS INTEGER) AND rowid<=CAST(?2 AS INTEGER)
          ORDER BY jobs.rowid LIMIT ?3`).all(m.cursor, m.end_id, limit)) as { id: string }[];
    const put = db.prepare(`INSERT INTO job_ends(id,state,ended_at) SELECT j.id,j.state,j.ended_at FROM jobs j
      WHERE j.rowid=CAST(?1 AS INTEGER) AND j.id IS NOT NULL ON CONFLICT(id) DO UPDATE SET state=excluded.state,ended_at=excluded.ended_at`);
    for (const row of rows) put.run(row.id);
    const done = rows.length < limit;
    db.prepare("UPDATE job_ends_meta SET cursor=CAST(? AS INTEGER),complete=? WHERE id=1").run(rows.at(-1)?.id ?? m.cursor, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
