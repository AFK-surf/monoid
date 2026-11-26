// The state and end time of each job by its id, apart from the wide jobs rows (their command text): Jobs.collect asks
// for up to 500 jobs at once, and reading those rows from cold pages held the station's thread for seconds. Without
// building an index over an old store in one long write: a store of more jobs than BATCH installs the table and its
// writers empty, and the session backfill copies the jobs it had in bounded steps off the station's thread
// (`job-ends`: station/mb/src/legacy `job_ends_step`, pion/station builders_legacy, legacy-said-builder.ts).
import type { DatabaseSync } from "node:sqlite";

export const VERSION = 1;
export const BATCH = 64;
const exists = (db: DatabaseSync, type: string, name: string) =>
  db.prepare("SELECT 1 FROM sqlite_master WHERE type=? AND name=?").get(type, name) !== undefined;

/// A WITHOUT ROWID table keeps each row in its primary key's tree: the lookup reads nothing else.
export const JOBS_ENDS = "SELECT id, state, ended_at FROM job_ends WHERE id IN (SELECT value FROM json_each(?1))";
/// Until the old jobs are copied, the jobs table answers.
export const JOBS_ENDS_BEFORE_BACKFILL = "SELECT id, state, ended_at FROM jobs WHERE id IN (SELECT value FROM json_each(?1))";

// After each write, the ids it may have changed are read again from jobs. REPLACE can remove another job by its token
// without firing DELETE triggers, so the jobs a write may replace are staged before it; an ignored write fires no AFTER
// trigger and leaves its stage behind, which the next write clears (copying a staged id again is harmless). jobs.id may
// be NULL in a rowid table: such rows have no end to read and are left out. The WHERE on the stage's DELETEs keeps
// SQLite from dirtying the empty stage on every ordinary job write.
const STAGED = "(SELECT id FROM job_ends_replaced)";
const reconcile = (ids: string) => `DELETE FROM job_ends WHERE id IN (${ids}) OR id IN ${STAGED};
  INSERT OR REPLACE INTO job_ends(id, state, ended_at)
    SELECT id, state, ended_at FROM jobs WHERE (id IN (${ids}) OR id IN ${STAGED}) AND id IS NOT NULL;
  DELETE FROM job_ends_replaced WHERE id IS NOT NULL;`;

const SCHEMA = `
  CREATE TABLE job_ends_meta(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, complete INTEGER NOT NULL,
    cursor INTEGER, end_id INTEGER) WITHOUT ROWID;
  CREATE TABLE job_ends(id TEXT PRIMARY KEY, state TEXT NOT NULL, ended_at INTEGER) WITHOUT ROWID;
  CREATE TABLE job_ends_replaced(id TEXT PRIMARY KEY) WITHOUT ROWID;
  CREATE TRIGGER job_ends_before_add BEFORE INSERT ON jobs
    WHEN EXISTS (SELECT 1 FROM job_ends_replaced) OR EXISTS (SELECT 1 FROM jobs WHERE id = NEW.id OR token = NEW.token) BEGIN
    DELETE FROM job_ends_replaced WHERE id IS NOT NULL;
    INSERT OR IGNORE INTO job_ends_replaced SELECT id FROM jobs WHERE (id = NEW.id OR token = NEW.token) AND id IS NOT NULL;
  END;
  CREATE TRIGGER job_ends_add AFTER INSERT ON jobs BEGIN ${reconcile("NEW.id")} END;
  CREATE TRIGGER job_ends_before_change BEFORE UPDATE OF id, token ON jobs
    WHEN OLD.id IS NOT NEW.id OR OLD.token IS NOT NEW.token OR EXISTS (SELECT 1 FROM job_ends_replaced) BEGIN
    DELETE FROM job_ends_replaced WHERE id IS NOT NULL;
    INSERT OR IGNORE INTO job_ends_replaced SELECT id FROM jobs
      WHERE (id = NEW.id OR token = NEW.token) AND id IS NOT OLD.id AND id IS NOT NULL;
  END;
  CREATE TRIGGER job_ends_change AFTER UPDATE OF id, state, ended_at, token ON jobs
    WHEN OLD.id IS NOT NEW.id OR OLD.state IS NOT NEW.state OR OLD.ended_at IS NOT NEW.ended_at
      OR EXISTS (SELECT 1 FROM job_ends_replaced) BEGIN ${reconcile("OLD.id, NEW.id")} END;
  CREATE TRIGGER job_ends_drop AFTER DELETE ON jobs WHEN OLD.id IS NOT NULL BEGIN
    DELETE FROM job_ends WHERE id = OLD.id;
  END;`;
const UPSERT = `INSERT INTO job_ends(id, state, ended_at) SELECT id, state, ended_at FROM jobs WHERE id IS NOT NULL`;
const CONFLICT = "ON CONFLICT(id) DO UPDATE SET state = excluded.state, ended_at = excluded.ended_at";

function installed(db: DatabaseSync): boolean {
  if (!exists(db, "table", "job_ends_meta")) return false;
  const row = db.prepare("SELECT version, complete FROM job_ends_meta WHERE id=1").get() as
    { version: number; complete: number } | undefined;
  if (!row || row.version !== VERSION || (row.complete !== 0 && row.complete !== 1))
    throw new Error("the jobs' end lookup has an unsupported version");
  return true;
}

/// A store of at most BATCH jobs (every new one) copies them here; a larger one only notes where its copy ends.
export function installJobEnds(db: DatabaseSync): void {
  if (installed(db)) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!installed(db)) {
      db.exec(SCHEMA);
      if (db.prepare(`SELECT 1 FROM jobs LIMIT 1 OFFSET ${BATCH}`).get() === undefined)
        db.exec(`${UPSERT} ${CONFLICT}; INSERT INTO job_ends_meta VALUES (1, ${VERSION}, 1, NULL, NULL);`);
      else db.exec(`INSERT INTO job_ends_meta VALUES (1, ${VERSION}, 0, NULL, (SELECT MAX(rowid) FROM jobs));`);
    }
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

type Meta = { version: number; complete: number; cursor: string | null; end_id: string | null };
/// The copy's place: the rowid of the last job copied and of the last there was to copy (as the builders read it).
export const jobEndsMeta = (db: DatabaseSync) => db.prepare(`SELECT version, complete, CAST(cursor AS TEXT) cursor,
  CAST(end_id AS TEXT) end_id FROM job_ends_meta WHERE id=1`).get() as Meta | undefined;

/// Whether the lookup is there (the builders copy only into one there is).
export function hasJobEnds(db: DatabaseSync): boolean {
  return exists(db, "table", "job_ends_meta") && exists(db, "table", "job_ends");
}

/// Whether job_ends holds every job (false where it is not installed).
export function jobEndsReady(db: DatabaseSync): boolean {
  return hasJobEnds(db) && jobEndsMeta(db)?.complete === 1;
}

export function jobEndsNeedsWork(db: DatabaseSync): boolean {
  return hasJobEnds(db) && installed(db) && jobEndsMeta(db)!.complete === 0;
}
