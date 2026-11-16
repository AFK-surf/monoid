// The steps src/store/post-blocks.ts built its lookup by before the MoonBit builder took them over, kept to compare the
// program with: the station has no step in TypeScript to fall back to. What it still runs is src/store/post-
// blocks.ts's.
import type { DatabaseSync } from "node:sqlite";
import { POST_BLOCK_SIZE, block, isPost, coverage, fresh, covers, type Entry } from "../../../src/store/post-blocks.ts";

export * from "../../../src/store/post-blocks.ts";

/// Index one requested suffix, newest first. The potentially cold history is read outside the write transaction. Once
/// the write lock is held, only the selected posts are rechecked by primary key; intervening writes have their own
/// triggers, so neither a concurrent change nor an interrupted batch can make coverage claim a missing marker.
export function postBlocksStep(db: DatabaseSync, thread: number, after: number, limit = POST_BLOCK_SIZE, mayWrite?: () => boolean): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > POST_BLOCK_SIZE) throw new RangeError("post block batch must be between 1 and 64");
  if (fresh(db)) return { done: true, visited: 0 };
  const before = coverage(db, thread);
  if (covers(before, after)) return { done: true, visited: 0 };
  const rows = (before?.cursor === null || before?.cursor === undefined
    ? db.prepare("SELECT n, kind, author_kind, author FROM entries WHERE thread = ? AND n >= ? ORDER BY n DESC LIMIT ?").all(thread, after, limit)
    : db.prepare("SELECT n, kind, author_kind, author FROM entries WHERE thread = ? AND n < ? AND n >= ? ORDER BY n DESC LIMIT ?").all(thread, before.cursor, after, limit)) as Entry[];
  const older = rows.length < limit && db.prepare("SELECT 1 FROM entries WHERE thread = ? AND n < ? LIMIT 1").get(thread, after) !== undefined;
  // A foreground writer may have arrived while those pages were read. Do not try to take SQLite's writer then.
  if (mayWrite && !mayWrite()) return { done: false, visited: rows.length };
  db.exec("BEGIN IMMEDIATE");
  try {
    const current = coverage(db, thread);
    if ((current?.cursor ?? null) !== (before?.cursor ?? null) || (current?.complete ?? 0) !== (before?.complete ?? 0)) {
      const done = covers(current, after);
      db.exec("COMMIT");
      return { done, visited: 0 };
    }
    const add = db.prepare(`INSERT INTO post_blocks (thread, author, bucket)
      SELECT e.thread, e.author, ${block("e.n")} FROM entries e
      WHERE e.thread = ? AND e.n = ? AND e.author = ? AND ${isPost("e")}
        AND NOT EXISTS (SELECT 1 FROM post_blocks b WHERE b.thread = e.thread AND b.author = e.author AND b.bucket = ${block("e.n")})`);
    for (const row of rows) if (row.kind === "message" && row.author_kind === "agent") add.run(thread, row.n, row.author);
    const cursor = rows.length < limit ? after : rows.at(-1)!.n;
    const complete = rows.length < limit && !older ? 1 : 0;
    db.prepare(`INSERT INTO post_blocks_coverage(thread, cursor, complete) VALUES (?, ?, ?)
      ON CONFLICT(thread) DO UPDATE SET cursor = excluded.cursor, complete = excluded.complete`).run(thread, cursor, complete);
    db.exec("COMMIT");
    return { done: complete === 1 || cursor <= after + 1, visited: rows.length };
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch {}
    throw error;
  }
}
