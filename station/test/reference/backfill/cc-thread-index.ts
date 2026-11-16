// The steps src/store/cc-thread-index.ts prepared its lookup by before the MoonBit program (station/mb src/cc) took
// them over, kept to compare the program with: the station has no step in TypeScript to fall back to. What it still
// runs is src/store/cc-thread-index.ts's.
import type { DatabaseSync } from "node:sqlite";
import { checkCcIndex, ccSessionReady, CC_SESSION_ROWS } from "../../../src/store/cc-thread-index.ts";

export * from "../../../src/store/cc-thread-index.ts";

export function trackCcSession(db: DatabaseSync, session: string, existingSession = false): void {
  checkCcIndex(db);
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(`INSERT INTO cc_sessions(session,scan_end)
      SELECT ?1,(SELECT rowid FROM thread_sessions INDEXED BY thread_sessions_session
        WHERE session=?1 ORDER BY rowid DESC LIMIT 1)
      WHERE NOT EXISTS (SELECT 1 FROM cc_sessions WHERE session=?1)
        AND (?2=0 OR EXISTS (SELECT 1 FROM sessions WHERE key=?1))`).run(session, existingSession ? 1 : 0);
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
function reconcile(db: DatabaseSync, session: string, thread: bigint): void {
  db.prepare(`DELETE FROM cc_session_rows WHERE session=?1 AND thread=?2 AND NOT EXISTS
    (SELECT 1 FROM thread_sessions WHERE session=?1 AND thread=?2)`).run(session, thread);
  db.prepare(`INSERT INTO cc_session_rows(session,thread,surface,created_at,last_at)
    SELECT m.session,m.thread,t.surface,t.created_at,e.at FROM thread_sessions m
    LEFT JOIN threads t ON t.id=m.thread LEFT JOIN thread_state st ON st.thread=t.id
    LEFT JOIN entries e ON e.thread=st.thread AND e.n=st.last_n
    WHERE m.session=?1 AND m.thread=?2
    ON CONFLICT(session,thread) DO UPDATE SET surface=excluded.surface,
      created_at=excluded.created_at,last_at=excluded.last_at
    WHERE surface IS NOT excluded.surface OR created_at IS NOT excluded.created_at OR last_at IS NOT excluded.last_at`)
    .run(session, thread);
}
export function scanCcSessionStep(db: DatabaseSync, session: string, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 128) throw new RangeError("copy destination batch must be between 1 and 128");
  db.exec("BEGIN IMMEDIATE");
  try {
    checkCcIndex(db);
    const scopeQuery = db.prepare("SELECT scan_after,scan_end,complete FROM cc_sessions WHERE session=?");
    scopeQuery.setReadBigInts(true);
    const scope = scopeQuery.get(session) as { scan_after: bigint | null; scan_end: bigint | null; complete: bigint } | undefined;
    if (!scope) throw new Error("copy destination session is not tracked");
    if (scope.complete === 1n) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rowsQuery = db.prepare(scope.scan_after === null
      ? `SELECT rowid,thread FROM thread_sessions INDEXED BY thread_sessions_session
          WHERE session=?1 AND rowid<=?2 ORDER BY rowid LIMIT ?3`
      : `SELECT rowid,thread FROM thread_sessions INDEXED BY thread_sessions_session
          WHERE session=?1 AND rowid>?2 AND rowid<=?3 ORDER BY rowid LIMIT ?4`);
    rowsQuery.setReadBigInts(true);
    const rows = (scope.scan_after === null ? rowsQuery.all(session, scope.scan_end, limit)
      : rowsQuery.all(session, scope.scan_after, scope.scan_end, limit)) as { rowid: bigint; thread: bigint }[];
    for (const row of rows) reconcile(db, session, row.thread);
    const done = rows.length < limit;
    db.prepare("UPDATE cc_sessions SET scan_after=?,complete=? WHERE session=?")
      .run(rows.at(-1)?.rowid ?? scope.scan_after, done ? 1 : 0, session);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
export function dispatchCcOrderStep(db: DatabaseSync, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 128) throw new RangeError("copy destination batch must be between 1 and 128");
  db.exec("BEGIN IMMEDIATE");
  try {
    checkCcIndex(db);
    const turn = db.prepare("SELECT after_thread,through_thread FROM cc_order_turn WHERE id=1");
    turn.setReadBigInts(true);
    const progress = turn.get() as { after_thread: bigint | null; through_thread: bigint | null };
    let through = progress.through_thread;
    let pending: { thread: bigint; after_session: string | null; through_session: string } | undefined;
    if (through !== null) {
      const next = db.prepare(progress.after_thread === null
        ? "SELECT thread,after_session,through_session FROM cc_order_dispatch WHERE thread<=? ORDER BY thread LIMIT 1"
        : "SELECT thread,after_session,through_session FROM cc_order_dispatch WHERE thread>? AND thread<=? ORDER BY thread LIMIT 1");
      next.setReadBigInts(true);
      pending = (progress.after_thread === null ? next.get(through) : next.get(progress.after_thread, through)) as typeof pending;
    }
    if (!pending) {
      const last = db.prepare("SELECT MAX(thread) AS thread FROM cc_order_dispatch"); last.setReadBigInts(true);
      through = (last.get() as { thread: bigint | null }).thread;
      if (through === null) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
      const first = db.prepare("SELECT thread,after_session,through_session FROM cc_order_dispatch WHERE thread<=? ORDER BY thread LIMIT 1");
      first.setReadBigInts(true); pending = first.get(through) as typeof pending;
    }
    if (!pending) throw new Error("copy destination dispatch disappeared");
    db.prepare("UPDATE cc_order_turn SET after_thread=?,through_thread=? WHERE id=1").run(pending.thread, through);
    const members = db.prepare(pending.after_session === null
      ? "SELECT session FROM cc_session_rows INDEXED BY cc_rows_thread WHERE thread=?1 AND session<=?2 ORDER BY session LIMIT ?3"
      : "SELECT session FROM cc_session_rows INDEXED BY cc_rows_thread WHERE thread=?1 AND session>?2 AND session<=?3 ORDER BY session LIMIT ?4");
    const rows = (pending.after_session === null ? members.all(pending.thread, pending.through_session, limit)
      : members.all(pending.thread, pending.after_session, pending.through_session, limit)) as { session: string }[];
    const mark = db.prepare(`INSERT INTO cc_session_dirty(session,thread) SELECT ?1,?2 WHERE NOT EXISTS
      (SELECT 1 FROM cc_session_dirty WHERE session=?1 AND thread=?2)`);
    for (const row of rows) mark.run(row.session, pending.thread);
    if (rows.length === limit) db.prepare("UPDATE cc_order_dispatch SET after_session=? WHERE thread=?")
      .run(rows.at(-1)!.session, pending.thread);
    else db.prepare("DELETE FROM cc_order_dispatch WHERE thread=?").run(pending.thread);
    const done = db.prepare("SELECT 1 FROM cc_order_dispatch LIMIT 1").get() === undefined;
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
export function settleCcSessionStep(db: DatabaseSync, session: string): { done: boolean; visited: number } {
  db.exec("BEGIN IMMEDIATE");
  try {
    checkCcIndex(db);
    if (!db.prepare("SELECT 1 FROM cc_sessions WHERE session=?").get(session)) throw new Error("copy destination session is not tracked");
    const next = db.prepare("SELECT thread FROM cc_session_dirty WHERE session=? ORDER BY thread LIMIT 1");
    next.setReadBigInts(true);
    const row = next.get(session) as { thread: bigint } | undefined;
    if (!row) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    if (db.prepare("SELECT 1 FROM cc_order_dispatch WHERE thread=?").get(row.thread)) {
      db.exec("COMMIT"); return { done: false, visited: 0 };
    }
    reconcile(db, session, row.thread);
    db.prepare("DELETE FROM cc_session_dirty WHERE session=? AND thread=?").run(session, row.thread);
    const done = db.prepare("SELECT 1 FROM cc_session_dirty WHERE session=? LIMIT 1").get(session) === undefined;
    db.exec("COMMIT"); return { done, visited: 1 };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
export function ccSessionRows(db: DatabaseSync, session: string, limit: number): { thread: number; last_at: number | null; created_at: number }[] {
  if (!Number.isSafeInteger(limit) || limit < 0) throw new RangeError("copy destination limit must be nonnegative");
  db.exec("SAVEPOINT cc_destination_read");
  try {
    if (!ccSessionReady(db, session)) throw new Error("copy destinations are still being prepared");
    return db.prepare(CC_SESSION_ROWS).all(session, limit) as { thread: number; last_at: number | null; created_at: number }[];
  } finally { db.exec("RELEASE cc_destination_read"); }
}
/// Give a requested session one bounded slice of its initial scan, shared-thread distribution, or reconciliation.
/// Alternating the lanes prevents a busy shared thread from indefinitely postponing a short session's initial scan.
export class CcIndexPreparation {
  readonly #turns = new Map<string, number>();

  cancel(session: string): void { this.#turns.delete(session); }

  step(db: DatabaseSync, session: string, limit = 64,
    options: { existingSession?: boolean } = {}): { done: boolean; visited: number } {
    checkCcIndex(db);
    if (options.existingSession && !db.prepare("SELECT 1 FROM sessions WHERE key=?").get(session)) {
      this.#turns.delete(session);
      return { done: true, visited: 0 };
    }
    let scope = db.prepare("SELECT complete FROM cc_sessions WHERE session=?").get(session) as { complete: number } | undefined;
    if (!scope) {
      trackCcSession(db, session, options.existingSession);
      scope = db.prepare("SELECT complete FROM cc_sessions WHERE session=?").get(session) as { complete: number } | undefined;
      if (!scope) { this.#turns.delete(session); return { done: true, visited: 0 }; }
    }
    if (ccSessionReady(db, session)) { this.#turns.delete(session); return { done: true, visited: 0 }; }
    const lanes = [
      { pending: () => scope!.complete === 0, step: () => scanCcSessionStep(db, session, limit).visited },
      { pending: () => db.prepare("SELECT 1 FROM cc_order_dispatch LIMIT 1").get() !== undefined,
        step: () => dispatchCcOrderStep(db, limit).visited },
      { pending: () => db.prepare("SELECT 1 FROM cc_session_dirty WHERE session=? LIMIT 1").get(session) !== undefined,
        step: () => settleCcSessionStep(db, session).visited },
    ];
    const turn = this.#turns.get(session) ?? 0;
    for (let n = 0; n < lanes.length; n++) {
      const at = (turn + n) % lanes.length, lane = lanes[at]!;
      if (!lane.pending()) continue;
      this.#turns.set(session, (at + 1) % lanes.length);
      const visited = lane.step();
      const done = ccSessionReady(db, session);
      if (done) this.#turns.delete(session);
      return { done, visited };
    }
    if (ccSessionReady(db, session)) { this.#turns.delete(session); return { done: true, visited: 0 }; }
    throw new Error("copy destination preparation has no runnable work");
  }
}