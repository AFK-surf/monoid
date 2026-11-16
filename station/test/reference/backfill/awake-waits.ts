// The steps src/store/awake-waits.ts built its lookup by before the MoonBit builder took them over, kept to compare the
// program with: the station has no step in TypeScript to fall back to. What it still runs is src/store/awake-
// waits.ts's.
import type { DatabaseSync } from "node:sqlite";

import { deadline, syncAwakeWait } from "../../../src/store/awake-waits.ts";

export * from "../../../src/store/awake-waits.ts";

export const AWAKE_BACKFILL_FIRST = "SELECT session FROM session_recover_waits ORDER BY session LIMIT ?";
export const AWAKE_BACKFILL_NEXT = "SELECT session FROM session_recover_waits WHERE session > ? ORDER BY session LIMIT ?";

/// The old recovery lookup is prepared first; its entries, the cursor and deadline updates commit together.
export function awakeWaitsStep(db: DatabaseSync, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("awake wait batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const state = db.prepare("SELECT cursor, complete FROM session_awake_wait_meta WHERE id = 1").get() as { cursor: string | null; complete: number };
    if (state.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const recovery = db.prepare("SELECT complete FROM session_recover_wait_meta WHERE id = 1").get() as { complete: number };
    if (recovery.complete !== 1) { db.exec("COMMIT"); return { done: false, visited: 0 }; }
    const rows = (state.cursor === null ? db.prepare(AWAKE_BACKFILL_FIRST).all(limit)
      : db.prepare(AWAKE_BACKFILL_NEXT).all(state.cursor, limit)) as { session: string }[];
    const update = db.prepare(syncAwakeWait("?1"));
    for (const { session } of rows) update.run(session);
    const done = rows.length < limit;
    db.prepare("UPDATE session_awake_wait_meta SET cursor = ?, complete = ? WHERE id = 1")
      .run(rows.at(-1)?.session ?? state.cursor, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch {}
    throw error;
  }
}
