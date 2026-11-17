// The steps src/store/workspace-activity.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/workspace-activity.ts's.
import type { DatabaseSync } from "node:sqlite";
import { byBytes } from "../../../src/store/rows.ts";
import { active, add, FIRST_RUNNING, FIRST_MESSAGE, FIRST_LETTER } from "../../../src/store/workspace-activity.ts";

export * from "../../../src/store/workspace-activity.ts";

const NEXT_RUNNING = "SELECT key AS session FROM sessions INDEXED BY sessions_running WHERE running = 1 AND key > ? ORDER BY key LIMIT 1";
const NEXT_MESSAGE = "SELECT session FROM deliveries INDEXED BY deliveries_pending WHERE delivered_at IS NULL AND session > ? ORDER BY session LIMIT 1";
const NEXT_LETTER = "SELECT session FROM letter_deliveries INDEXED BY letter_deliveries_pending WHERE delivered_at IS NULL AND session > ? ORDER BY session LIMIT 1";

/// Bring across at most `limit` distinct active session keys; all checks and progress commit atomically with the new
/// writers. A key added before the cursor is handled by its trigger, even if an older station wrote it.
export function workspaceActivityStep(db: DatabaseSync, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("workspace activity batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const meta = db.prepare("SELECT cursor, complete FROM workspace_activity_meta WHERE id = 1").get() as { cursor: string | null; complete: number };
    if (meta.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const first = [FIRST_RUNNING, FIRST_MESSAGE, FIRST_LETTER].map((sql) => db.prepare(sql));
    const next = [NEXT_RUNNING, NEXT_MESSAGE, NEXT_LETTER].map((sql) => db.prepare(sql));
    const put = db.prepare(add("?"));
    let cursor = meta.cursor;
    let visited = 0;
    let done = false;
    while (visited < limit) {
      const keys = (cursor === null ? first.map((s) => s.get()) : next.map((s) => s.get(cursor!)))
        .flatMap((row) => row === undefined ? [] : [row.session as string]).sort(byBytes);
      const key = keys[0];
      if (key === undefined) { done = true; break; }
      put.run(key);
      cursor = key;
      visited++;
    }
    db.prepare("UPDATE workspace_activity_meta SET cursor = ?, complete = ? WHERE id = 1").run(cursor, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited };
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch {}
    throw error;
  }
}
