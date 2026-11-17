// The steps src/store/card-post-index.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/card-post-index.ts's.
import type { DatabaseSync } from "node:sqlite";
import { scopeOf, cardPostsReady } from "../../../src/store/card-post-index.ts";

export * from "../../../src/store/card-post-index.ts";

export const CARD_POST_NEXT = "SELECT n FROM card_posts WHERE thread=? AND n>=? ORDER BY n LIMIT 1";
export const CARD_POST_AFTER = "SELECT 1 FROM card_posts WHERE thread=? AND n>? LIMIT 1";
export const CARD_POST_SAMPLE = "SELECT n FROM card_posts WHERE thread=? ORDER BY n LIMIT 65";
// Keep the index's numeric ordering before casting the cursor for JavaScript. LIMIT applies before inspecting kind,
// since the legacy card indexes also contain edits. Missing legacy indexes fall back to bounded primary-key pages.
const positions = (column: "card" | "options" | null, after: boolean): string => {
  const index = column === null ? "" : ` INDEXED BY entries_${column === "card" ? "cards" : "options"}`;
  const predicate = column === null ? "" : ` AND ${column} IS NOT NULL`;
  const range = after ? "n>CAST(?2 AS INTEGER) AND n<=CAST(?3 AS INTEGER)" : "n<=CAST(?2 AS INTEGER)";
  return `SELECT CAST(n AS TEXT) AS n FROM (SELECT n FROM entries${index} WHERE thread=?1 AND ${range}${predicate}
    ORDER BY n LIMIT ${after ? "?4" : "?3"})`;
};
export function cardPostsStep(db: DatabaseSync, thread: number, limit = 128): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 128) throw new RangeError("card post batch must be between 1 and 128");
  if (cardPostsReady(db, thread)) return { done: true, visited: 0 };
  if (!scopeOf(db, thread)) {
    db.exec("BEGIN IMMEDIATE");
    try {
      db.prepare(`INSERT INTO card_post_scopes(thread,last_n,end_n,phase)
        SELECT ?1,NULL,(SELECT n FROM entries WHERE thread=?1 ORDER BY n DESC LIMIT 1),0
        WHERE NOT EXISTS (SELECT 1 FROM card_post_scopes WHERE thread=?1)`).run(thread);
      db.exec("COMMIT");
    } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
  }
  const before = scopeOf(db, thread)!;
  if (before.phase === 2) return { done: true, visited: 0 };
  const indexes = db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='index' AND name IN ('entries_cards','entries_options')").get() as { n: number };
  // If an old index disappeared between batches, restart from the beginning of the primary-key walk: the earlier
  // card-only batches cannot establish that they visited every options-only post.
  if (indexes.n !== 2 && before.phase !== 3) {
    db.exec("BEGIN IMMEDIATE");
    try {
      const now = scopeOf(db, thread);
      if (now && now.last_n === before.last_n && now.end_n === before.end_n && now.phase === before.phase)
        db.prepare("UPDATE card_post_scopes SET last_n=NULL,phase=3 WHERE thread=?").run(thread);
      db.exec("COMMIT");
      return { done: now?.phase === 2, visited: 0 };
    } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
  }
  const column = before.phase === 3 ? null : (before.phase === 0 ? "card" : "options");
  const statement = db.prepare(positions(column, before.last_n !== null));
  const rows = (before.last_n === null ? statement.all(thread, before.end_n, limit)
    : statement.all(thread, before.last_n, before.end_n, limit)) as { n: string }[];
  db.exec("BEGIN IMMEDIATE");
  try {
    const now = scopeOf(db, thread);
    if (!now || now.last_n !== before.last_n || now.end_n !== before.end_n || now.phase !== before.phase) {
      db.exec("COMMIT"); return { done: now?.phase === 2, visited: 0 };
    }
    const add = db.prepare(`INSERT INTO card_posts(thread,n)
      SELECT e.thread,e.n FROM entries e WHERE e.thread=?1 AND e.n=CAST(?2 AS INTEGER)
        AND e.kind='message' AND (e.card IS NOT NULL OR e.options IS NOT NULL)
        AND NOT EXISTS (SELECT 1 FROM card_posts p WHERE p.thread=e.thread AND p.n=e.n)`);
    for (const row of rows) add.run(thread, row.n);
    const endOfPhase = rows.length < limit;
    const phase = endOfPhase ? (column === null ? 2 : before.phase + 1) : before.phase;
    const last = endOfPhase ? null : rows.at(-1)!.n;
    db.prepare("UPDATE card_post_scopes SET last_n=CAST(? AS INTEGER),phase=? WHERE thread=?").run(last, phase, thread);
    db.exec("COMMIT");
    return { done: phase === 2, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}