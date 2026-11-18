import type { DatabaseSync } from "node:sqlite";
import { STILLFAIL_SURFACE } from "./rows.ts";

// A projection only for sessions whose copy destinations have been requested. A thread change is distributed in
// batches; a dirty session cannot be read until every relevant distribution and its own reconciliation have ended.
export const CC_INDEX_VERSION = 1;
const VERSION = CC_INDEX_VERSION;
export const CC_SESSIONS_PENDING = "copy destination sessions pending:";
const orderChange = (thread: string) => `
  INSERT INTO cc_order_dispatch(thread, after_session, through_session)
    SELECT ${thread}, NULL, (SELECT session FROM cc_session_rows INDEXED BY cc_rows_thread
      WHERE thread=${thread} ORDER BY session DESC LIMIT 1) WHERE ${thread} IS NOT NULL
      AND EXISTS (SELECT 1 FROM cc_session_rows INDEXED BY cc_rows_thread WHERE thread=${thread} LIMIT 1)
      AND NOT EXISTS (SELECT 1 FROM cc_order_dispatch WHERE thread=${thread});`;
const memberChange = (thread: string, session: string) => `
  INSERT INTO cc_session_dirty(session, thread)
    SELECT ${session}, ${thread} WHERE ${session} IS NOT NULL AND ${thread} IS NOT NULL
      AND EXISTS (SELECT 1 FROM cc_sessions WHERE session=${session})
      AND NOT EXISTS (SELECT 1 FROM cc_session_dirty WHERE session=${session} AND thread=${thread});`;
const displacedMemberThread = "(SELECT thread FROM thread_sessions WHERE rowid=NEW.rowid)";
const displacedMemberSession = "(SELECT session FROM thread_sessions WHERE rowid=NEW.rowid)";
const displacedEntry = "(SELECT thread FROM entries WHERE rowid=NEW.rowid)";
const displacedThread = `(SELECT id FROM threads WHERE surface=NEW.surface AND channel=NEW.channel
  AND thread_ts=NEW.thread_ts)`;

/// The order of a session's threads that are no chat of the station's own (renamed with them: schema.ts `renameOwnChats`).
export const CC_SESSION_ORDER = `CREATE INDEX cc_session_order ON cc_session_rows(session,last_at DESC,created_at DESC,thread DESC)
        WHERE surface != '${STILLFAIL_SURFACE}';`;

export function installCcIndex(db: DatabaseSync): void {
  const installed = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cc_index_meta'").get() !== undefined;
  if (installed()) { checkCcIndex(db); return; }
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!installed()) db.exec(`
      CREATE TABLE cc_index_meta (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL) WITHOUT ROWID;
      INSERT INTO cc_index_meta VALUES(1, ${VERSION});
      CREATE TABLE cc_sessions (session TEXT PRIMARY KEY, scan_after INTEGER, scan_end INTEGER,
        complete INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
      -- Keep memberships whose thread is missing or currently internal too: a later thread write may expose them.
      CREATE TABLE cc_session_rows (session TEXT NOT NULL, thread INTEGER NOT NULL, surface TEXT,
        created_at INTEGER, last_at INTEGER, PRIMARY KEY(session,thread)) WITHOUT ROWID;
      ${CC_SESSION_ORDER}
      CREATE INDEX cc_rows_thread ON cc_session_rows(thread,session);
      CREATE TABLE cc_session_dirty (session TEXT NOT NULL, thread INTEGER NOT NULL,
        PRIMARY KEY(session,thread)) WITHOUT ROWID;
      CREATE TABLE cc_order_dispatch (thread INTEGER PRIMARY KEY, after_session TEXT, through_session TEXT NOT NULL);
      CREATE TABLE cc_order_turn (id INTEGER PRIMARY KEY CHECK(id=1), after_thread INTEGER, through_thread INTEGER);
      INSERT INTO cc_order_turn VALUES(1,NULL,NULL);

      -- An old writer can replace a different membership by rowid without a DELETE trigger.
      CREATE TRIGGER cc_member_before_add BEFORE INSERT ON thread_sessions BEGIN
        ${memberChange("NEW.thread", "NEW.session")}
        ${memberChange(displacedMemberThread, displacedMemberSession)}
      END;
      CREATE TRIGGER cc_member_add AFTER INSERT ON thread_sessions BEGIN ${memberChange("NEW.thread", "NEW.session")} END;
      CREATE TRIGGER cc_member_before_change BEFORE UPDATE ON thread_sessions
        WHEN OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.rowid IS NOT NEW.rowid BEGIN
          ${memberChange("OLD.thread", "OLD.session")}
          ${memberChange("NEW.thread", "NEW.session")}
          ${memberChange(displacedMemberThread, displacedMemberSession)}
      END;
      CREATE TRIGGER cc_member_change AFTER UPDATE ON thread_sessions
        WHEN OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.rowid IS NOT NEW.rowid BEGIN
          ${memberChange("NEW.thread", "NEW.session")}
      END;
      -- A departed membership no longer needs a row or a future reconciliation, even if its session is never read again.
      CREATE TRIGGER cc_member_drop AFTER DELETE ON thread_sessions BEGIN
        DELETE FROM cc_session_rows WHERE session=OLD.session AND thread=OLD.thread;
        DELETE FROM cc_session_dirty WHERE session=OLD.session AND thread=OLD.thread;
      END;

      -- A row added behind a running distributor's cursor stays dirty until that distribution has ended.
      CREATE TRIGGER cc_row_add AFTER INSERT ON cc_session_rows
        WHEN EXISTS (SELECT 1 FROM cc_order_dispatch WHERE thread=NEW.thread) BEGIN
          ${memberChange("NEW.thread", "NEW.session")}
      END;

      CREATE TRIGGER cc_thread_before_add BEFORE INSERT ON threads BEGIN
        ${orderChange("NEW.id")} ${orderChange(displacedThread)}
      END;
      CREATE TRIGGER cc_thread_add AFTER INSERT ON threads BEGIN ${orderChange("NEW.id")} END;
      CREATE TRIGGER cc_thread_before_change BEFORE UPDATE ON threads
        WHEN OLD.id IS NOT NEW.id OR OLD.surface IS NOT NEW.surface OR OLD.created_at IS NOT NEW.created_at
          OR OLD.channel IS NOT NEW.channel OR OLD.thread_ts IS NOT NEW.thread_ts BEGIN
        ${orderChange("OLD.id")} ${orderChange("NEW.id")} ${orderChange(displacedThread)}
      END;
      CREATE TRIGGER cc_thread_change AFTER UPDATE ON threads
        WHEN OLD.id IS NOT NEW.id OR OLD.surface IS NOT NEW.surface OR OLD.created_at IS NOT NEW.created_at
          OR OLD.channel IS NOT NEW.channel OR OLD.thread_ts IS NOT NEW.thread_ts BEGIN
        ${orderChange("OLD.id")} ${orderChange("NEW.id")}
      END;
      CREATE TRIGGER cc_thread_drop AFTER DELETE ON threads BEGIN ${orderChange("OLD.id")} END;

      -- Track the source of the original query's timestamp, including manual changes and REPLACE by rowid.
      CREATE TRIGGER cc_state_add AFTER INSERT ON thread_state BEGIN ${orderChange("NEW.thread")} END;
      CREATE TRIGGER cc_state_change AFTER UPDATE OF thread,last_n ON thread_state
        WHEN OLD.thread IS NOT NEW.thread OR OLD.last_n IS NOT NEW.last_n BEGIN
          ${orderChange("OLD.thread")} ${orderChange("NEW.thread")}
      END;
      CREATE TRIGGER cc_state_drop AFTER DELETE ON thread_state BEGIN ${orderChange("OLD.thread")} END;
      CREATE TRIGGER cc_entry_before_add BEFORE INSERT ON entries BEGIN ${orderChange(displacedEntry)} END;
      CREATE TRIGGER cc_entry_add AFTER INSERT ON entries BEGIN ${orderChange("NEW.thread")} END;
      CREATE TRIGGER cc_entry_before_change BEFORE UPDATE OF rowid,_rowid_,oid,thread,n,ts,at ON entries BEGIN
        ${orderChange("OLD.thread")} ${orderChange("NEW.thread")} ${orderChange(displacedEntry)}
      END;
      CREATE TRIGGER cc_entry_change AFTER UPDATE OF rowid,_rowid_,oid,thread,n,ts,at ON entries BEGIN
        ${orderChange("OLD.thread")} ${orderChange("NEW.thread")}
      END;
      CREATE TRIGGER cc_entry_drop AFTER DELETE ON entries BEGIN ${orderChange("OLD.thread")} END;
    `);
    else checkCcIndex(db);
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function checkCcIndex(db: DatabaseSync): void {
  const row = db.prepare("SELECT version FROM cc_index_meta WHERE id=1").get() as { version: number } | undefined;
  if (row?.version !== VERSION) throw new Error(`copy destination index version ${row?.version ?? "missing"} is incompatible with ${VERSION}`);
}

// The caller must hold the snapshot through the subsequent read. Cap both sides of the intersection; if both are
// large, wait for dispatch rather than performing a history-sized read or returning stale destinations.
export function ccSessionReady(db: DatabaseSync, session: string): boolean {
  checkCcIndex(db);
  const scope = db.prepare("SELECT complete FROM cc_sessions WHERE session=?").get(session) as { complete: number } | undefined;
  if (scope?.complete !== 1 || db.prepare("SELECT 1 FROM cc_session_dirty WHERE session=? LIMIT 1").get(session)) return false;
  const dispatch = db.prepare(`SELECT COUNT(*) AS n, MAX(EXISTS
    (SELECT 1 FROM cc_session_rows r WHERE r.session=?1 AND r.thread=d.thread)) AS affects
    FROM (SELECT thread FROM cc_order_dispatch ORDER BY thread LIMIT 65) d`).get(session) as { n: number; affects: number | null };
  if (dispatch.affects === 1) return false;
  if (dispatch.n <= 64) return true;
  const rows = db.prepare(`SELECT COUNT(*) AS n, MAX(EXISTS
    (SELECT 1 FROM cc_order_dispatch d WHERE d.thread=r.thread)) AS affects
    FROM (SELECT thread FROM cc_session_rows WHERE session=?1 ORDER BY thread LIMIT 65) r`).get(session) as { n: number; affects: number | null };
  return rows.n <= 64 && rows.affects !== 1;
}

export const CC_SESSION_ROWS = `SELECT thread,last_at,created_at FROM cc_session_rows INDEXED BY cc_session_order
  WHERE session=?1 AND surface != '${STILLFAIL_SURFACE}' ORDER BY last_at DESC,created_at DESC,thread DESC LIMIT ?2`;

// Read the key as text to keep 64-bit values intact, but order by the integer column, not the text alias.
export const CC_SESSION_KEYS = `SELECT CAST(thread AS TEXT) AS thread FROM cc_session_rows INDEXED BY cc_session_order
  WHERE session=?1 AND surface != '${STILLFAIL_SURFACE}' ORDER BY last_at DESC,created_at DESC,cc_session_rows.thread DESC LIMIT 20`;

// The union contains at most twenty rows per source session. A destination in the global top twenty must be in the
// top twenty of every session it shares with the source; otherwise that session alone has twenty distinct earlier
// destinations. SQLite compares the original values for the final ordering, including NULL and non-integer values.
export const CC_INDEXED_THREADS = `SELECT t.*,o.connect FROM json_each(?1) c
  CROSS JOIN threads t ON t.id=CAST(json_extract(c.value,'$[0]') AS INTEGER)
  CROSS JOIN thread_sessions o ON o.thread=t.id AND o.session=json_extract(c.value,'$[1]')
  WHERE t.surface != '${STILLFAIL_SURFACE}'
  ORDER BY (SELECT e.at FROM thread_state st JOIN entries e ON e.thread=st.thread AND e.n=st.last_n
    WHERE st.thread=t.id) DESC, t.created_at DESC, t.id DESC LIMIT 20`;

export class CcSessionsUnavailable extends Error {
  readonly sessions: string[];
  constructor(sessions: string[]) { super("copy destinations are still being prepared"); this.sessions = sessions; }
}

/// The caller gets readiness, candidate selection and the final rows from one snapshot.
export function indexedCcThreads(db: DatabaseSync, thread: number): Record<string, unknown>[] {
  db.exec("SAVEPOINT cc_threads_read");
  try {
    const sessions = db.prepare("SELECT session FROM thread_sessions WHERE thread=? ORDER BY session")
      .all(thread) as { session: string }[];
    const missing = sessions.filter(({ session }) => !ccSessionReady(db, session)).map(({ session }) => session);
    if (missing.length) throw new CcSessionsUnavailable(missing);
    const keys = db.prepare(CC_SESSION_KEYS), candidates = new Map<string, string>();
    for (const { session } of sessions) {
      for (const row of keys.all(session) as { thread: string }[])
        if (!candidates.has(row.thread)) candidates.set(row.thread, session);
    }
    if (candidates.size === 0) return [];
    return db.prepare(CC_INDEXED_THREADS).all(JSON.stringify([...candidates])) as Record<string, unknown>[];
  } finally { db.exec("RELEASE cc_threads_read"); }
}
