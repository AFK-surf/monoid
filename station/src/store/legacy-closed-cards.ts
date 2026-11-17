// An old store can prepare the per-chat closed-card lookup without indexing its whole history during open.
import type { DatabaseSync } from "node:sqlite";

const VERSION = 1;
export const BATCH = 64;
export const CLOSED_SAMPLE_LIMIT = BATCH + 1;
export const exists = (db: DatabaseSync, type: string, name: string) =>
  db.prepare("SELECT 1 FROM sqlite_master WHERE type=? AND name=?").get(type, name) !== undefined;

export const CLOSED_CARDS_PENDING = "closed cards pending:";
// Read at most one more than the cutoff, so the reader can tell whether the bounded result is complete.
export const CLOSED_CHAT_SAMPLE = `SELECT * FROM (SELECT c.thread,CASE WHEN c.at>=?2 THEN c.n END AS n,
  CASE WHEN c.at>=?2 THEN c.viewer END AS viewer,CASE WHEN c.at>=?2 THEN c.at END AS at,
  CASE WHEN c.at>=?2 THEN c.rowid END AS ordering FROM closed_cards c
  WHERE c.thread=?1 ORDER BY c.n LIMIT ${CLOSED_SAMPLE_LIMIT}) ORDER BY at,ordering`;
// Count the whole bounded window, but decode values only for requested chats: unrelated old rows can contain
// 64-bit integers which the Node SQLite driver cannot represent as JavaScript numbers.
export const CLOSED_TIME_SAMPLE = `WITH recent AS MATERIALIZED (
  SELECT thread,n,viewer,at,rowid AS ordering FROM closed_cards INDEXED BY closed_cards_at
  WHERE at>=? ORDER BY at,rowid LIMIT ${CLOSED_SAMPLE_LIMIT}
), selected AS MATERIALIZED (
  SELECT *,thread IN (SELECT value FROM json_each(?2)) AS wanted FROM recent
)
SELECT CASE WHEN wanted THEN thread END AS thread,CASE WHEN wanted THEN n END AS n,
  CASE WHEN wanted THEN viewer END AS viewer,CASE WHEN wanted THEN at END AS at,
  CASE WHEN wanted THEN ordering END AS ordering FROM selected`;

export const hasNativeClosedCards = (db: DatabaseSync) => exists(db, "index", "closed_cards_thread_at");
export function hasLegacyClosedCards(db: DatabaseSync): boolean {
  if (!exists(db, "table", "legacy_closed_meta")) return false;
  const row = db.prepare("SELECT version FROM legacy_closed_meta WHERE id=1").get() as { version: number } | undefined;
  if (!row || row.version !== VERSION) throw new Error("legacy closed-card lookup has an unsupported version");
  return true;
}

// A REPLACE can remove another row by either its (thread,n) key or its rowid without a DELETE trigger. Reconcile only
// those keys against the source after each write. Unlike a BEFORE marker this leaves no debris for ignored writes.
const candidates = (p: string) => `SELECT rowid AS id FROM closed_cards WHERE thread=${p}.thread AND n=${p}.n
  UNION SELECT rowid FROM closed_cards WHERE rowid=${p}.rowid`;
const remove = (p: string) => `DELETE FROM legacy_closed_cards WHERE thread=${p}.thread AND n=${p}.n;
  DELETE FROM legacy_closed_cards WHERE source_rowid=${p}.rowid;`;
const add = (ids: string) => `INSERT INTO legacy_closed_cards(thread,at,source_rowid,n)
  SELECT c.thread,c.at,c.rowid,c.n FROM (${ids}) p CROSS JOIN closed_cards c ON c.rowid=p.id
  WHERE EXISTS (SELECT 1 FROM legacy_closed_scopes s WHERE s.thread=c.thread)
    AND NOT EXISTS (SELECT 1 FROM legacy_closed_cards k WHERE k.thread=c.thread AND k.n=c.n);`;
const changed = `OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.at IS NOT NEW.at OR OLD.rowid IS NOT NEW.rowid`;

const LEGACY_CLOSED_SCHEMA = `
CREATE TABLE legacy_closed_meta (id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL) WITHOUT ROWID;
INSERT INTO legacy_closed_meta VALUES(1,${VERSION});
CREATE TABLE legacy_closed_scopes (thread INTEGER PRIMARY KEY,last_n INTEGER,end_n INTEGER,complete INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE legacy_closed_cards (source_rowid INTEGER PRIMARY KEY,thread INTEGER NOT NULL,n INTEGER NOT NULL,at INTEGER NOT NULL);
CREATE UNIQUE INDEX legacy_closed_by_entry ON legacy_closed_cards(thread,n);
CREATE INDEX legacy_closed_by_time ON legacy_closed_cards(thread,at);
CREATE TRIGGER legacy_closed_insert AFTER INSERT ON closed_cards BEGIN
  ${remove("NEW")}
  ${add(candidates("NEW"))}
END;
CREATE TRIGGER legacy_closed_update AFTER UPDATE ON closed_cards WHEN ${changed} BEGIN
  ${remove("OLD")}
  ${remove("NEW")}
  ${add(`${candidates("OLD")} UNION ${candidates("NEW")}`)}
END;
CREATE TRIGGER legacy_closed_delete AFTER DELETE ON closed_cards BEGIN
  ${remove("OLD")}
  ${add(candidates("OLD"))}
END;`;

const CLOSED_DROP_THREAD = `CREATE TRIGGER legacy_closed_drop_thread AFTER DELETE ON threads
  WHEN NOT EXISTS (SELECT 1 FROM closed_cards WHERE thread=OLD.id LIMIT 1) BEGIN
    DELETE FROM legacy_closed_scopes WHERE thread=OLD.id;
  END;`;

// Stores that already prepared this lookup need the cleanup trigger too. A native index can coexist with metadata
// from a different version; leave that metadata alone if it is not a version this station understands.
function needsClosedCleanup(db: DatabaseSync): boolean {
  if (!exists(db, "table", "legacy_closed_meta") || exists(db, "trigger", "legacy_closed_drop_thread") ||
      !exists(db, "table", "threads") || !exists(db, "table", "legacy_closed_scopes")) return false;
  const row = db.prepare("SELECT version FROM legacy_closed_meta WHERE id=1").get() as { version: number } | undefined;
  return row?.version === VERSION;
}

/// Keep the native index on small or already upgraded stores. Recheck both choices under the writer lock.
export function installClosedCardsIndex(db: DatabaseSync): void {
  if ((hasNativeClosedCards(db) || hasLegacyClosedCards(db)) && !needsClosedCleanup(db)) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!hasNativeClosedCards(db) && !hasLegacyClosedCards(db)) {
      if (db.prepare("SELECT 1 FROM closed_cards LIMIT 1 OFFSET 63").get() === undefined)
        db.exec("CREATE INDEX IF NOT EXISTS closed_cards_thread_at ON closed_cards (thread, at)");
      else db.exec(LEGACY_CLOSED_SCHEMA);
    }
    if (needsClosedCleanup(db)) db.exec(CLOSED_DROP_THREAD);
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

