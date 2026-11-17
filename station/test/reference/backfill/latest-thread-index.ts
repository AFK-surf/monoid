// The steps src/store/latest-thread-index.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/latest-thread-index.ts's.
import type { DatabaseSync } from "node:sqlite";
import { LATEST_THREAD_INDEXED, checkLatestThreadIndex, addCandidate } from "../../../src/store/latest-thread-index.ts";

export * from "../../../src/store/latest-thread-index.ts";

export const LATEST_THREAD_SCOPE = "SELECT complete FROM latest_thread_scopes WHERE session=?";
export function latestThreadReady(db: DatabaseSync, session: string): boolean {
  checkLatestThreadIndex(db);
  return (db.prepare(LATEST_THREAD_SCOPE).get(session) as { complete: number } | undefined)?.complete === 1;
}
/// Read readiness and the candidate from one database snapshot.
export function indexedLatestThread(db: DatabaseSync, session: string): Record<string, unknown> | null {
  db.exec("SAVEPOINT latest_thread_read");
  try {
    if (!latestThreadReady(db, session)) throw new Error("latest thread is still being prepared");
    return db.prepare(LATEST_THREAD_INDEXED).get(session) ?? null;
  } finally { db.exec("RELEASE latest_thread_read"); }
}
const addMember = `INSERT INTO latest_thread_members(thread,session)
  SELECT m.thread,m.session FROM thread_sessions m WHERE m.session=?1 AND m.rowid=?2
    AND NOT EXISTS (SELECT 1 FROM latest_thread_members r WHERE r.thread=m.thread AND r.session=m.session)`;
/// Begin and advance an old session's walk in transactions bounded by `limit` source memberships.
export function prepareLatestThreadStep(db: DatabaseSync, session: string, limit = 64,
  options: { existingSession?: boolean } = {}): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 128) throw new RangeError("latest thread batch must be between 1 and 128");
  db.exec("BEGIN IMMEDIATE");
  try {
    checkLatestThreadIndex(db);
    // The worker can be handed a session which was deleted while it waited. Check under this same write transaction,
    // so no later batch can recreate its scope after the deletion has removed it.
    if (options.existingSession && !db.prepare("SELECT 1 FROM sessions WHERE key=?").get(session)) {
      db.exec("COMMIT"); return { done: true, visited: 0 };
    }
    db.prepare(`INSERT INTO latest_thread_scopes(session,scan_end)
      SELECT ?1,(SELECT rowid FROM thread_sessions INDEXED BY thread_sessions_session WHERE session=?1 ORDER BY rowid DESC LIMIT 1)
      WHERE NOT EXISTS (SELECT 1 FROM latest_thread_scopes WHERE session=?1)`).run(session);
    const state = db.prepare("SELECT scan_after,scan_end,complete FROM latest_thread_scopes WHERE session=?");
    state.setReadBigInts(true);
    const scope = state.get(session) as { scan_after: bigint | null; scan_end: bigint | null; complete: bigint };
    if (scope.complete === 1n) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const scan = db.prepare(scope.scan_after === null
      ? "SELECT rowid FROM thread_sessions INDEXED BY thread_sessions_session WHERE session=?1 AND rowid<=?2 ORDER BY rowid LIMIT ?3"
      : "SELECT rowid FROM thread_sessions INDEXED BY thread_sessions_session WHERE session=?1 AND rowid>?2 AND rowid<=?3 ORDER BY rowid LIMIT ?4");
    scan.setReadBigInts(true);
    const rows = (scope.scan_after === null ? scan.all(session, scope.scan_end, limit)
      : scan.all(session, scope.scan_after, scope.scan_end, limit)) as { rowid: bigint }[];
    const put = db.prepare(addCandidate), putMember = db.prepare(addMember);
    for (const row of rows) { putMember.run(session, row.rowid); put.run(session, row.rowid); }
    const done = rows.length < limit;
    db.prepare("UPDATE latest_thread_scopes SET scan_after=?,complete=? WHERE session=?")
      .run(rows.at(-1)?.rowid ?? scope.scan_after, done ? 1 : 0, session);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}