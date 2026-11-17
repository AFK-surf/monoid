// The steps src/store/legacy-people-since.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/legacy-people-since.ts's.
import type { DatabaseSync } from "node:sqlite";
import { BATCH, hasNativePeopleSince, hasLegacyPeopleSince, installPeopleSinceIndex } from "../../../src/store/legacy-people-since.ts";

export * from "../../../src/store/legacy-people-since.ts";

type Scope = { last_n: string | null; end_n: string | null; complete: number };

const scope = (db: DatabaseSync, thread: number): Scope | undefined => db.prepare(`SELECT CAST(last_n AS TEXT) AS last_n,
  CAST(end_n AS TEXT) AS end_n,complete FROM legacy_people_time_scopes WHERE thread=?`).get(thread) as Scope | undefined;
export function peopleSinceReady(db: DatabaseSync, thread: number): boolean {
  if (hasNativePeopleSince(db)) return true;
  if (!hasLegacyPeopleSince(db)) return false;
  return scope(db,thread)?.complete === 1;
}
/// Save at most 64 old entries of the requested chat. The triggers keep changed rows current between slices.
export function peopleSinceStep(db: DatabaseSync, thread: number, limit = BATCH): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("people-time batch must be 1–64");
  installPeopleSinceIndex(db);
  if (hasNativePeopleSince(db)) return { done: true, visited: 0 };
  db.exec("BEGIN IMMEDIATE");
  try {
    if (hasNativePeopleSince(db)) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    if (!hasLegacyPeopleSince(db)) { db.exec("COMMIT"); return { done: false, visited: 0 }; }
    if (!scope(db,thread)) {
      // A queued request may outlive a chat deletion. Do not recreate a scope after both the chat and its entries go.
      if (db.prepare("SELECT 1 FROM threads WHERE id=?").get(thread) === undefined &&
          db.prepare("SELECT 1 FROM entries WHERE thread=? LIMIT 1").get(thread) === undefined) {
        db.exec("COMMIT"); return { done: true, visited: 0 };
      }
      db.prepare(`INSERT INTO legacy_people_time_scopes(thread,last_n,end_n,complete)
        VALUES(?1,NULL,(SELECT n FROM entries WHERE thread=?1 ORDER BY n DESC LIMIT 1),0)`).run(thread);
    }
    const s = scope(db,thread)!;
    if (s.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = s.end_n === null ? [] : (s.last_n === null
      ? db.prepare(`SELECT CAST(n AS TEXT) AS n FROM (SELECT n FROM entries WHERE thread=?1 AND n<=CAST(?2 AS INTEGER)
          ORDER BY n LIMIT ?3)`).all(thread,s.end_n,limit)
      : db.prepare(`SELECT CAST(n AS TEXT) AS n FROM (SELECT n FROM entries WHERE thread=?1 AND n>CAST(?2 AS INTEGER)
          AND n<=CAST(?3 AS INTEGER) ORDER BY n LIMIT ?4)`).all(thread,s.last_n,s.end_n,limit)) as { n: string }[];
    const put = db.prepare(`INSERT INTO legacy_people_time_rows(source_rowid,thread,n,at,ts)
      SELECT e.rowid,e.thread,e.n,e.at,e.ts FROM entries e WHERE e.thread=?1 AND e.n=CAST(?2 AS INTEGER)
        AND e.kind='message' AND e.author_kind='person'
        AND NOT EXISTS (SELECT 1 FROM legacy_people_time_rows k WHERE k.source_rowid=e.rowid)
        AND NOT EXISTS (SELECT 1 FROM legacy_people_time_rows k WHERE k.thread=e.thread AND k.n=e.n)`);
    for (const row of rows) put.run(thread,row.n);
    const done = rows.length < limit;
    db.prepare("UPDATE legacy_people_time_scopes SET last_n=CAST(? AS INTEGER),complete=? WHERE thread=?")
      .run(rows.at(-1)?.n ?? s.last_n,done ? 1 : 0,thread);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}