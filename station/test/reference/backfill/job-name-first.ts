// The steps src/store/job-name-first.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/job-name-first.ts's.
import type { DatabaseSync } from "node:sqlite";
import { checkJobNameFirst } from "../../../src/store/job-name-first.ts";

export * from "../../../src/store/job-name-first.ts";

export const JOB_NAME_FIRST_LARGE = "SELECT 1 FROM thread_sessions WHERE thread=? LIMIT 1 OFFSET 64";
export const JOB_NAME_FIRST_ROW = `SELECT m.* FROM thread_sessions m WHERE m.rowid=(SELECT best FROM job_name_first
  WHERE owner=?1 AND thread=?2 AND ready=1 AND restart=0)`;
// Keep the cursor and end as SQLite values, not decoded JS strings: old keys can contain NUL, invalid UTF-8 or blobs.
export const JOB_NAME_FIRST_SCAN = (first: boolean) => `SELECT rowid FROM thread_sessions WHERE thread=?1
  AND session <= (SELECT through_session FROM job_name_first WHERE owner=?2)
  ${first ? "" : "AND session > (SELECT after_session FROM job_name_first WHERE owner=?2)"}
  ORDER BY session LIMIT ?3`;
/// Prepare one requested chat in bounded batches. Writers also consider additions behind the cursor. If the current
/// minimum disappears the cursor restarts; a fixed end lets an ongoing stream of later additions finish preparation.
export function jobNameFirstStep(db: DatabaseSync, owner: string, thread: number, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(thread) || !Number.isSafeInteger(limit) || limit < 1 || limit > 128) throw new RangeError("invalid job name first batch");
  db.exec("BEGIN IMMEDIATE");
  try {
    checkJobNameFirst(db);
    db.prepare(`INSERT OR IGNORE INTO job_name_first(owner,thread,through_session)
      SELECT ?1,?2,(SELECT session FROM thread_sessions WHERE thread=?2 ORDER BY session DESC LIMIT 1)
      WHERE EXISTS (SELECT 1 FROM session_up_job_rows WHERE session=?1 LIMIT 1)`).run(owner, thread);
    const current = db.prepare("SELECT thread,ready FROM job_name_first WHERE owner=?").get(owner) as { thread: number; ready: number } | undefined;
    if (!current || current.thread !== thread || current.ready === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    db.prepare(`UPDATE job_name_first SET restart=0,ready=0,best=NULL,after_session=NULL,
      through_session=(SELECT session FROM thread_sessions WHERE thread=?2 ORDER BY session DESC LIMIT 1)
      WHERE owner=?1 AND thread=?2 AND restart=1`).run(owner, thread);
    const first = (db.prepare("SELECT after_session IS NULL AS first FROM job_name_first WHERE owner=?").get(owner) as { first: number }).first === 1;
    const q = db.prepare(JOB_NAME_FIRST_SCAN(first)); q.setReadBigInts(true);
    const batch = q.all(thread, owner, limit) as { rowid: bigint }[];
    if (batch.length) {
      const candidate = db.prepare(`SELECT rowid FROM thread_sessions WHERE rowid IN (${batch.map(() => "?").join(",")})
        ORDER BY joined_at,rowid LIMIT 1`); candidate.setReadBigInts(true);
      const best = (candidate.get(...batch.map((row) => row.rowid)) as { rowid: bigint }).rowid;
      db.prepare(`UPDATE job_name_first SET best=?2 WHERE owner=?1 AND best IS NOT ?2
        AND (best IS NULL OR (SELECT rowid FROM thread_sessions WHERE rowid IN (best,?2)
          ORDER BY joined_at,rowid LIMIT 1)=?2)`).run(owner, best);
      db.prepare(`UPDATE job_name_first SET after_session=(SELECT session FROM thread_sessions WHERE rowid=?2)
        WHERE owner=?1`).run(owner, batch.at(-1)!.rowid);
    }
    const done = batch.length < limit;
    if (done) db.prepare("UPDATE job_name_first SET ready=1 WHERE owner=?").run(owner);
    db.exec("COMMIT");
    return { done, visited: batch.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}