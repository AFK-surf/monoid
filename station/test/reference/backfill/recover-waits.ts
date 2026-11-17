// The steps src/store/recover-waits.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is src/store/recover-
// waits.ts's.
import type { DatabaseSync } from "node:sqlite";
import { remove, add } from "../../../src/store/recover-waits.ts";

export * from "../../../src/store/recover-waits.ts";

export const RECOVER_BACKFILL_FIRST = "SELECT key FROM sessions ORDER BY key LIMIT ?";
export const RECOVER_BACKFILL_NEXT = "SELECT key FROM sessions WHERE key > ? ORDER BY key LIMIT ?";

/// Fill at most `limit` existing sessions. The cursor and its updates commit together; triggers cover intervening writes.
export function recoverWaitsStep(db: DatabaseSync, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("recovery wait batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const state = db.prepare("SELECT cursor, complete FROM session_recover_wait_meta WHERE id = 1").get() as { cursor: string | null; complete: number };
    if (state.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = (state.cursor === null ? db.prepare(RECOVER_BACKFILL_FIRST).all(limit)
      : db.prepare(RECOVER_BACKFILL_NEXT).all(state.cursor, limit)) as { key: string }[];
    const drop = db.prepare(remove("?1"));
    const put = db.prepare(add("?1"));
    for (const { key } of rows) { drop.run(key); put.run(key); }
    const done = rows.length < limit;
    db.prepare("UPDATE session_recover_wait_meta SET cursor = ?, complete = ? WHERE id = 1")
      .run(rows.at(-1)?.key ?? state.cursor, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch {}
    throw error;
  }
}
