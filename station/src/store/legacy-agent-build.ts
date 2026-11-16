// An older store can keep its agent-message time lookup without building an index over every entry under one writer.
import type { DatabaseSync } from "node:sqlite";

export const VERSION = 1;
export const BATCH = 64;
const exists = (db: DatabaseSync, type: string, name: string) =>
  db.prepare("SELECT 1 FROM sqlite_master WHERE type=? AND name=?").get(type,name) !== undefined;

export function hasLegacyAgent(db: DatabaseSync): boolean {
  if (!exists(db,"table","legacy_agent_meta")) return false;
  const m = db.prepare("SELECT version,scanned FROM legacy_agent_meta WHERE id=1").get() as { version: number; scanned: number } | undefined;
  if (!m || m.version !== VERSION || (m.scanned !== 0 && m.scanned !== 1)) throw new Error("legacy agent lookup has an unsupported version");
  return true;
}

// Once prepared, the first arm seeks just the requested time range. Dirty keys are read from their current entries;
// all arms see one SQLite snapshot, including during nested writes by a previous station.
export const LEGACY_ASKED_DURING = `SELECT MAX(n) AS n FROM (
  SELECT e.n FROM legacy_agent_meta m CROSS JOIN entries e
    WHERE m.id=1 AND m.scanned=0 AND e.thread=?1 AND e.kind='message' AND e.author_kind='agent' AND e.at>=?2 AND e.at<=?3
  UNION ALL
  SELECT s.n FROM legacy_agent_meta m CROSS JOIN legacy_agent_build s
    WHERE m.id=1 AND m.scanned=1 AND s.thread=?1 AND s.at>=?2 AND s.at<=?3
      AND NOT EXISTS (SELECT 1 FROM legacy_agent_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  UNION ALL
  SELECT e.n FROM legacy_agent_meta m CROSS JOIN legacy_agent_times t
    CROSS JOIN entries e ON e.thread=t.thread AND e.n=t.n
    WHERE m.id=1 AND m.scanned=1 AND t.thread=?1 AND t.at>=?2 AND t.at<=?3
      AND e.kind='message' AND e.author_kind='agent' AND e.at=t.at
)`;

const conflicts = `SELECT e.thread,e.n FROM (
  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.kind='message' AND e.author_kind='agent'`;
const newKey = "SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.kind='message' AND NEW.author_kind='agent'";
const oldKey = "SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.kind='message' AND OLD.author_kind='agent'";
const newAgent = "NEW.kind='message' AND NEW.author_kind='agent'";
const oldAgent = "OLD.kind='message' AND OLD.author_kind='agent'";
const displacesAgent = `(EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n
    AND e.kind='message' AND e.author_kind='agent')
  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts
    AND e.kind='message' AND e.author_kind='agent'))
  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND e.kind='message' AND e.author_kind='agent'))`;
// Keep the time of the first changed row, which is the time of its staged key if there is one. The scanner never
// stages a dirty key. This lets reconciliation delete by the time-ordered primary key without a second reverse index.
const proposedTime = "SELECT NEW.thread AS thread,NEW.at AS at,NEW.n AS n WHERE NEW.kind='message' AND NEW.author_kind='agent'";
// A BEFORE trigger records the current and proposed times. Even if a nested write replaces one before the outer write
// finishes, each possible current time stays searchable; the actual entry is checked before the result is returned.
const mark = (keys: string, proposed: boolean) => `INSERT INTO legacy_agent_dirty(thread,n,old_at)
  SELECT k.thread,k.n,e.at FROM (${keys}) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
    AND e.kind='message' AND e.author_kind='agent'
  WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  INSERT INTO legacy_agent_times(thread,at,n)
    SELECT t.thread,t.at,t.n FROM (
      SELECT e.thread,e.at,e.n FROM (${keys}) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
        WHERE e.kind='message' AND e.author_kind='agent'
      ${proposed ? `UNION ${proposedTime}` : ""}
    ) t WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_times x WHERE x.thread=t.thread AND x.at=t.at AND x.n=t.n);`;
// An ordinary append has no displaced row. Record its key and proposed time directly, leaving the more expensive
// collision lookup to a separate trigger which runs only if a conflicting agent message actually exists.
const markNew = `INSERT INTO legacy_agent_dirty(thread,n,old_at)
  SELECT NEW.thread,NEW.n,e.at FROM (SELECT 1) x LEFT JOIN entries e ON e.thread=NEW.thread AND e.n=NEW.n
    AND e.kind='message' AND e.author_kind='agent'
  WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_dirty d WHERE d.thread=NEW.thread AND d.n=NEW.n);
  INSERT INTO legacy_agent_times(thread,at,n) SELECT NEW.thread,NEW.at,NEW.n
  WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_times x WHERE x.thread=NEW.thread AND x.at=NEW.at AND x.n=NEW.n);`;
const changed = `OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid
  OR OLD.kind IS NOT NEW.kind OR OLD.author_kind IS NOT NEW.author_kind OR OLD.at IS NOT NEW.at OR OLD.ts IS NOT NEW.ts`;

export function installLegacyAgent(db: DatabaseSync, preferNative = false): boolean {
  if (hasLegacyAgent(db)) return true;
  if (!exists(db,"index","entries_ts")) throw new Error("legacy agent preparation requires entries_ts");
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!hasLegacyAgent(db) && !(preferNative && exists(db,"index","entries_agent_at"))) db.exec(`
      CREATE TABLE legacy_agent_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,scanned INTEGER NOT NULL,
        cursor_thread INTEGER,cursor_n INTEGER,end_thread INTEGER,end_n INTEGER) WITHOUT ROWID;
      INSERT INTO legacy_agent_meta VALUES(1,${VERSION},0,NULL,NULL,
        (SELECT thread FROM entries ORDER BY thread DESC,n DESC LIMIT 1),
        (SELECT n FROM entries ORDER BY thread DESC,n DESC LIMIT 1));
      CREATE TABLE legacy_agent_build(thread INTEGER NOT NULL,at INTEGER NOT NULL,n INTEGER NOT NULL,
        PRIMARY KEY(thread,at,n)) WITHOUT ROWID;
      CREATE TABLE legacy_agent_dirty(thread INTEGER NOT NULL,n INTEGER NOT NULL,old_at INTEGER,
        PRIMARY KEY(thread,n)) WITHOUT ROWID;
      CREATE TABLE legacy_agent_times(thread INTEGER NOT NULL,at INTEGER NOT NULL,n INTEGER NOT NULL,
        PRIMARY KEY(thread,at,n)) WITHOUT ROWID;
      CREATE INDEX legacy_agent_times_by_key ON legacy_agent_times(thread,n,at);
      CREATE TRIGGER legacy_agent_before_insert BEFORE INSERT ON entries WHEN ${newAgent} BEGIN ${markNew} END;
      CREATE TRIGGER legacy_agent_before_insert_conflict BEFORE INSERT ON entries WHEN ${displacesAgent}
        BEGIN ${mark(conflicts,false)} END;
      CREATE TRIGGER legacy_agent_before_update BEFORE UPDATE ON entries WHEN (${changed}) AND
        ((${oldAgent}) OR (${newAgent}) OR ${displacesAgent})
        BEGIN ${mark(`${oldKey} UNION ${newKey} UNION ${conflicts}`,true)} END;
      CREATE TRIGGER legacy_agent_before_delete BEFORE DELETE ON entries WHEN ${oldAgent} BEGIN ${mark(oldKey,false)} END;
    `);
    db.exec("COMMIT");
    return hasLegacyAgent(db);
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

type Meta = { version: number; scanned: number; cursor_thread: string | null; cursor_n: string | null;
  end_thread: string | null; end_n: string | null };
export type Entry = { thread: string; n: string; at: string; kind: string; author_kind: string };
export const meta = (db: DatabaseSync) => db.prepare(`SELECT version,scanned,CAST(cursor_thread AS TEXT) cursor_thread,
  CAST(cursor_n AS TEXT) cursor_n,CAST(end_thread AS TEXT) end_thread,CAST(end_n AS TEXT) end_n
  FROM legacy_agent_meta WHERE id=1`).get() as Meta;
export const limitOf = (limit: number) => {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("agent batch must be 1–64");
};

export function legacyAgentNeedsWork(db: DatabaseSync): boolean {
  if (!hasLegacyAgent(db)) return false;
  return db.prepare(`SELECT 1 FROM legacy_agent_meta WHERE id=1 AND
    (scanned=0 OR EXISTS (SELECT 1 FROM legacy_agent_dirty LIMIT 1))`).get() !== undefined;
}
