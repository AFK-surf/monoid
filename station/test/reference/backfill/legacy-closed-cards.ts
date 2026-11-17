// The steps src/store/legacy-closed-cards.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/legacy-closed-cards.ts's.
import type { DatabaseSync } from "node:sqlite";
import { BATCH, exists, hasNativeClosedCards, hasLegacyClosedCards, installClosedCardsIndex } from "../../../src/store/legacy-closed-cards.ts";

export * from "../../../src/store/legacy-closed-cards.ts";

type Scope = { last_n: string | null; end_n: string | null; complete: number };

export const CLOSED_CARDS_INDEXED = `SELECT thread,n,viewer,at,rowid AS ordering
  FROM closed_cards INDEXED BY closed_cards_thread_at WHERE thread=? AND at>=?`;
export const LEGACY_CLOSED_CARDS = `SELECT c.thread,c.n,c.viewer,c.at,c.rowid AS ordering
  FROM legacy_closed_cards k INDEXED BY legacy_closed_by_time CROSS JOIN closed_cards c ON c.rowid=k.source_rowid
  WHERE k.thread=? AND k.at>=? AND c.thread=k.thread AND c.n=k.n AND c.at=k.at`;
export const hasClosedCardsTimeIndex = (db: DatabaseSync) => exists(db, "index", "closed_cards_at");
const scope = (db: DatabaseSync, thread: number): Scope | undefined => db.prepare(`SELECT CAST(last_n AS TEXT) AS last_n,
  CAST(end_n AS TEXT) AS end_n,complete FROM legacy_closed_scopes WHERE thread=?`).get(thread) as Scope | undefined;
/// An empty chat needs no saved state; the reader's snapshot also sees any concurrent close consistently.
export function closedCardsReady(db: DatabaseSync, thread: number): boolean {
  if (hasNativeClosedCards(db)) return true;
  if (hasLegacyClosedCards(db)) {
    const found = scope(db, thread);
    if (found) return found.complete === 1;
  }
  return db.prepare("SELECT 1 FROM closed_cards WHERE thread=? LIMIT 1").get(thread) === undefined;
}
/// Save at most 64 old rows for the requested chat. Triggers cover writes from older connections between slices.
export function closedCardsStep(db: DatabaseSync, thread: number, limit = BATCH): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("closed-card batch must be 1–64");
  installClosedCardsIndex(db);
  if (hasNativeClosedCards(db)) return { done: true, visited: 0 };
  db.exec("BEGIN IMMEDIATE");
  try {
    // An older connection may change the schema between the installation and this writer lock.
    if (hasNativeClosedCards(db)) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    if (!hasLegacyClosedCards(db)) { db.exec("COMMIT"); return { done: false, visited: 0 }; }
    if (!scope(db, thread)) {
      // A queued request may finish after the chat is deleted; do not recreate its empty scope.
      if (exists(db, "table", "threads") && db.prepare("SELECT 1 FROM threads WHERE id=?").get(thread) === undefined &&
          db.prepare("SELECT 1 FROM closed_cards WHERE thread=? LIMIT 1").get(thread) === undefined) {
        db.exec("COMMIT"); return { done: true, visited: 0 };
      }
      db.prepare(`INSERT INTO legacy_closed_scopes(thread,last_n,end_n,complete)
        VALUES(?1,NULL,(SELECT n FROM closed_cards WHERE thread=?1 ORDER BY n DESC LIMIT 1),0)`).run(thread);
    }
    const s = scope(db, thread)!;
    if (s.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = s.end_n === null ? [] : (s.last_n === null
      ? db.prepare(`SELECT CAST(n AS TEXT) AS n FROM (SELECT n FROM closed_cards WHERE thread=?1 AND n<=CAST(?2 AS INTEGER)
          ORDER BY n LIMIT ?3)`).all(thread, s.end_n, limit)
      : db.prepare(`SELECT CAST(n AS TEXT) AS n FROM (SELECT n FROM closed_cards WHERE thread=?1 AND n>CAST(?2 AS INTEGER)
          AND n<=CAST(?3 AS INTEGER) ORDER BY n LIMIT ?4)`).all(thread, s.last_n, s.end_n, limit)) as { n: string }[];
    const put = db.prepare(`INSERT INTO legacy_closed_cards(thread,at,source_rowid,n)
      SELECT c.thread,c.at,c.rowid,c.n FROM closed_cards c WHERE c.thread=?1 AND c.n=CAST(?2 AS INTEGER)
        AND NOT EXISTS (SELECT 1 FROM legacy_closed_cards k WHERE k.thread=c.thread AND k.n=c.n)`);
    for (const row of rows) put.run(thread, row.n);
    const done = rows.length < limit;
    db.prepare("UPDATE legacy_closed_scopes SET last_n=CAST(? AS INTEGER),complete=? WHERE thread=?")
      .run(rows.at(-1)?.n ?? s.last_n, done ? 1 : 0, thread);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}