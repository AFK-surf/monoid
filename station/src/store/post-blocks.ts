import type { DatabaseSync } from "node:sqlite";

// A marker covers only one author's messages in a small range of entry numbers. Most consecutive messages from the
// same agent share it, while a lookup can skip every range in which that agent said nothing.
export const POST_BLOCK_SIZE = 64;
export type PostPosition = { thread: number; n: number };

/// A lookup needs an older suffix before it can answer without walking the thread's history.
export class PostBlocksUnavailable extends Error {
  readonly positions: readonly PostPosition[];
  constructor(positions: readonly PostPosition[]) {
    super("post block history not ready");
    this.positions = positions;
  }
}

export const block = (n: string) => `(${n} / ${POST_BLOCK_SIZE} - CASE WHEN ${n} < 0 AND ${n} % ${POST_BLOCK_SIZE} != 0 THEN 1 ELSE 0 END)`;
export const isPost = (row: string) => `${row}.kind = 'message' AND ${row}.author_kind = 'agent'`;

// REPLACE may silently remove two different rows, one for (thread,n) and one for (thread,ts), without DELETE triggers.
// SQLite serializes writers, so this small staging table belongs to the current write. IGNORE may leave it populated;
// the next write clears it, without changing any markers for the ignored write.
const stage = `
  DELETE FROM post_blocks_replaced WHERE thread IS NOT NULL;
  INSERT INTO post_blocks_replaced (thread, author, bucket)
    SELECT e.thread, e.author, ${block("e.n")} FROM entries e
      WHERE e.thread = NEW.thread AND e.n = NEW.n AND ${isPost("e")}
    UNION
    SELECT e.thread, e.author, ${block("e.n")} FROM entries e
      WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND ${isPost("e")};`;
const noPost = (marker: string) => `NOT EXISTS (SELECT 1 FROM entries e WHERE e.thread = ${marker}.thread
  AND e.n >= ${marker}.bucket * ${POST_BLOCK_SIZE} AND e.n <= ${marker}.bucket * ${POST_BLOCK_SIZE} + ${POST_BLOCK_SIZE - 1}
  AND ${isPost("e")} AND e.author = ${marker}.author)`;
const cleanReplaced = `
  DELETE FROM post_blocks WHERE (thread, author, bucket) IN (SELECT thread, author, bucket FROM post_blocks_replaced)
    AND ${noPost("post_blocks")};
  DELETE FROM post_blocks_replaced WHERE thread IS NOT NULL;`;
const cleanOld = `
  DELETE FROM post_blocks WHERE thread = OLD.thread AND author = OLD.author AND bucket = ${block("OLD.n")}
    AND OLD.kind = 'message' AND OLD.author_kind = 'agent' AND ${noPost("post_blocks")};`;
// Do not rely on INSERT OR IGNORE in a trigger: an older writer's conflict policy can override it.
const addNew = `
  INSERT INTO post_blocks (thread, author, bucket)
    SELECT NEW.thread, NEW.author, ${block("NEW.n")}
    WHERE NEW.kind = 'message' AND NEW.author_kind = 'agent'
      AND NOT EXISTS (SELECT 1 FROM post_blocks b WHERE b.thread = NEW.thread AND b.author = NEW.author AND b.bucket = ${block("NEW.n")});`;
const changed = "OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.kind IS NOT NEW.kind OR OLD.author_kind IS NOT NEW.author_kind OR OLD.author IS NOT NEW.author OR OLD.ts IS NOT NEW.ts";

/// Install the markers and their triggers without scanning old messages. An empty store is covered from its first write;
/// an older store records only the requested suffix of each thread in bounded steps.
export function installPostBlocks(db: DatabaseSync): void {
  const installed = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'post_blocks_meta'").get() !== undefined;
  if (installed()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!installed()) db.exec(`
      CREATE TABLE post_blocks(thread INTEGER NOT NULL, author TEXT NOT NULL, bucket INTEGER NOT NULL,
        PRIMARY KEY(thread,author,bucket)) WITHOUT ROWID;
      CREATE TABLE post_blocks_replaced(thread INTEGER NOT NULL, author TEXT NOT NULL, bucket INTEGER NOT NULL,
        PRIMARY KEY(thread,author,bucket)) WITHOUT ROWID;
      CREATE TABLE post_blocks_meta(id INTEGER PRIMARY KEY CHECK (id = 1), fresh INTEGER NOT NULL) WITHOUT ROWID;
      CREATE TABLE post_blocks_coverage(thread INTEGER PRIMARY KEY, cursor INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
      INSERT INTO post_blocks_meta SELECT 1, NOT EXISTS (SELECT 1 FROM entries LIMIT 1);
      CREATE TRIGGER post_blocks_before_insert BEFORE INSERT ON entries BEGIN ${stage} END;
      CREATE TRIGGER post_blocks_after_insert AFTER INSERT ON entries BEGIN ${cleanReplaced} ${addNew} END;
      CREATE TRIGGER post_blocks_before_update BEFORE UPDATE OF thread,n,kind,author_kind,author,ts ON entries
        WHEN ${changed} BEGIN ${stage} END;
      CREATE TRIGGER post_blocks_after_update AFTER UPDATE OF thread,n,kind,author_kind,author,ts ON entries
        WHEN ${changed} BEGIN ${cleanOld} ${cleanReplaced} ${addNew} END;
      CREATE TRIGGER post_blocks_after_delete AFTER DELETE ON entries BEGIN ${cleanOld} END;
    `);
    db.exec("COMMIT");
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch {}
    throw error;
  }
}

type Coverage = { cursor: number | null; complete: number };
export const coverage = (db: DatabaseSync, thread: number): Coverage | undefined =>
  db.prepare("SELECT cursor, complete FROM post_blocks_coverage WHERE thread = ?").get(thread) as Coverage | undefined;
export const fresh = (db: DatabaseSync): boolean =>
  (db.prepare("SELECT fresh FROM post_blocks_meta WHERE id = 1").get() as { fresh: number }).fresh === 1;
export const covers = (row: Coverage | undefined, after: number): boolean =>
  row !== undefined && (row.complete === 1 || (row.cursor !== null && row.cursor <= after + 1));

export function postBlocksReady(db: DatabaseSync, thread: number, after: number): boolean {
  return fresh(db) || covers(coverage(db, thread), after);
}

/// One coverage read can release all of a thread's waiting deliveries after a batch.
export function postBlocksCoverage(db: DatabaseSync, thread: number): { complete: boolean; cursor: number | null } {
  if (fresh(db)) return { complete: true, cursor: null };
  const row = coverage(db, thread);
  return { complete: row?.complete === 1, cursor: row?.cursor ?? null };
}

export type Entry = { n: number; kind: string; author_kind: string; author: string };
