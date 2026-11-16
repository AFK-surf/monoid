// The steps src/store/session-chat-index.ts prepared its lookup by before the MoonBit program (station/mb src/cc) took
// them over, kept to compare the program with: the station has no step in TypeScript to fall back to. What it still
// runs is src/store/session-chat-index.ts's.
import type { DatabaseSync } from "node:sqlite";
import { ccSessionReady, CcIndexPreparation } from "./cc-thread-index.ts";
import { refresh, ensure, checkSessionChatIndex } from "../../../src/store/session-chat-index.ts";

export * from "../../../src/store/session-chat-index.ts";

/// Prepare the existing membership set first, then add its ordered rows in bounded key order. Triggers cover changes during the
/// scan, including rows inserted behind its cursor. Every slice and its cursor are committed together.
export class SessionChatPreparation {
  readonly #cc = new CcIndexPreparation();

  cancel(session: string): void { this.#cc.cancel(session); }

  step(db: DatabaseSync, session: string, limit = 64,
    options: { existingSession?: boolean } = {}): { done: boolean; visited: number } {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 128) throw new RangeError("session chat batch must be between 1 and 128");
    checkSessionChatIndex(db);
    if (options.existingSession && !db.prepare("SELECT 1 FROM sessions WHERE key=?").get(session)) return { done: true, visited: 0 };
    if (!ccSessionReady(db, session)) {
      const progress = this.#cc.step(db, session, limit, options);
      return { done: false, visited: progress.visited };
    }
    db.exec("BEGIN IMMEDIATE");
    try {
      // Another writer may have changed the projection before this transaction took the write lock.
      checkSessionChatIndex(db);
      // A session can disappear while the worker waits for handover or between batches. Never recreate its scope.
      if (options.existingSession && !db.prepare("SELECT 1 FROM sessions WHERE key=?").get(session)) {
        db.exec("COMMIT"); return { done: true, visited: 0 };
      }
      if (!ccSessionReady(db, session)) { db.exec("COMMIT"); return { done: false, visited: 0 }; }
      db.prepare(`INSERT INTO session_chat_scopes(session,scan_end)
        SELECT ?1,(SELECT thread FROM cc_session_rows WHERE session=?1 ORDER BY thread DESC LIMIT 1)
        WHERE NOT EXISTS (SELECT 1 FROM session_chat_scopes WHERE session=?1)`).run(session);
      const scopeQuery = db.prepare("SELECT scan_after,scan_end,complete FROM session_chat_scopes WHERE session=?");
      scopeQuery.setReadBigInts(true);
      const scope = scopeQuery.get(session) as { scan_after: bigint | null; scan_end: bigint | null; complete: bigint };
      if (scope.complete === 1n) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
      const scan = db.prepare(scope.scan_after === null
        ? "SELECT thread FROM cc_session_rows WHERE session=?1 AND thread<=?2 ORDER BY thread LIMIT ?3"
        : "SELECT thread FROM cc_session_rows WHERE session=?1 AND thread>?2 AND thread<=?3 ORDER BY thread LIMIT ?4");
      scan.setReadBigInts(true);
      const rows = (scope.scan_after === null ? scan.all(session, scope.scan_end, limit)
        : scan.all(session, scope.scan_after, scope.scan_end, limit)) as { thread: bigint }[];
      const update = db.prepare(refresh("?1", "?2"));
      const insert = db.prepare(ensure("?1", "?2"));
      for (const row of rows) { update.run(session, row.thread); insert.run(session, row.thread); }
      const done = rows.length < limit;
      db.prepare("UPDATE session_chat_scopes SET scan_after=?,complete=? WHERE session=?")
        .run(rows.at(-1)?.thread ?? scope.scan_after, done ? 1 : 0, session);
      db.exec("COMMIT");
      return { done, visited: rows.length };
    } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
  }
}