// The steps src/store/process-jobs.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is src/store/process-
// jobs.ts's.
import type { DatabaseSync } from "node:sqlite";

import { VERSION, EXISTS, presence, active, changed, conflict, conflicts, stage, see, reconcile, refreshProcessJobs, processJobsReady } from "../../../src/store/process-jobs.ts";

export * from "../../../src/store/process-jobs.ts";

export const PROCESS_JOB_CONFLICT = conflict("?1", "?2", "?3");
export const PROCESS_JOB_END = "SELECT CAST(rowid AS TEXT) AS position FROM jobs INDEXED BY jobs_state WHERE state = 'running' ORDER BY rowid DESC LIMIT 1";
export const PROCESS_JOB_FIRST = `SELECT CAST(rowid AS TEXT) AS position FROM jobs INDEXED BY jobs_state
  WHERE state = 'running' AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export const PROCESS_JOB_NEXT = `SELECT CAST(rowid AS TEXT) AS position FROM jobs INDEXED BY jobs_state
  WHERE state = 'running' AND rowid > CAST(? AS INTEGER) AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export function installProcessJobs(db: DatabaseSync): void {
  if (refreshProcessJobs(db)) { processJobsReady(db); return; }
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!refreshProcessJobs(db)) {
      db.exec(`
        CREATE TABLE process_job_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL,
          complete INTEGER NOT NULL, cursor INTEGER, end_rowid INTEGER, schema_version INTEGER) WITHOUT ROWID;
        INSERT INTO process_job_meta (id, version, complete, cursor, end_rowid) VALUES (1, ${VERSION}, 0, NULL,
          CAST((${PROCESS_JOB_END}) AS INTEGER));
        CREATE TABLE process_job_rows (job TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE process_job_replaced (job TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TRIGGER process_job_before_add BEFORE INSERT ON jobs
          WHEN EXISTS (SELECT 1 FROM process_job_replaced) OR EXISTS (${conflicts}) BEGIN ${stage(false)} END;
        CREATE TRIGGER process_job_add AFTER INSERT ON jobs
          WHEN ${active("NEW")} OR EXISTS (SELECT 1 FROM process_job_replaced) BEGIN ${reconcile} ${see("NEW.rowid")} END;
        CREATE TRIGGER process_job_before_change BEFORE UPDATE ON jobs WHEN ${changed} BEGIN ${stage(true)} END;
        CREATE TRIGGER process_job_change AFTER UPDATE ON jobs WHEN ${changed} BEGIN ${reconcile} ${see("NEW.rowid")} END;
        CREATE TRIGGER process_job_drop AFTER DELETE ON jobs WHEN ${active("OLD")} BEGIN
          DELETE FROM process_job_rows WHERE job = OLD.id;
        END;
      `);
      const schema = (db.prepare("PRAGMA schema_version").get() as { schema_version: number }).schema_version;
      db.prepare("UPDATE process_job_meta SET schema_version = ? WHERE id = 1").run(schema);
    } else processJobsReady(db);
    db.exec("COMMIT");
    presence.set(db, true);
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// A VACUUM can renumber old job rowids between batches. The lookup stores stable ids; if the schema cookie changes,
/// start its bounded cursor over so no row moved behind that cursor is missed.
export function processJobsStep(db: DatabaseSync, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("process job batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const meta = db.prepare(`SELECT version, complete, CAST(cursor AS TEXT) AS cursor,
      CAST(end_rowid AS TEXT) AS end_rowid, schema_version FROM process_job_meta WHERE id = 1`).get() as
      { version: number; complete: number; cursor: string | null; end_rowid: string | null; schema_version: number } | undefined;
    if (meta?.version !== VERSION) throw new Error(`process job index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
    if (meta.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const schema = (db.prepare("PRAGMA schema_version").get() as { schema_version: number }).schema_version;
    let { cursor, end_rowid } = meta;
    if (schema !== meta.schema_version) {
      cursor = null;
      end_rowid = (db.prepare(PROCESS_JOB_END).get() as { position: string } | undefined)?.position ?? null;
    }
    const rows = end_rowid === null ? [] : (cursor === null
      ? db.prepare(PROCESS_JOB_FIRST).all(end_rowid, limit)
      : db.prepare(PROCESS_JOB_NEXT).all(cursor, end_rowid, limit)) as { position: string }[];
    const put = db.prepare(see("CAST(? AS INTEGER)"));
    for (const row of rows) put.run(row.position);
    const done = rows.length < limit;
    db.prepare("UPDATE process_job_meta SET cursor = CAST(? AS INTEGER), end_rowid = CAST(? AS INTEGER), complete = ?, schema_version = ? WHERE id = 1")
      .run(rows.at(-1)?.position ?? cursor, end_rowid, done ? 1 : 0, schema);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
