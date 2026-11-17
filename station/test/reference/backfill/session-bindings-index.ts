// The steps src/store/session-bindings-index.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/session-bindings-index.ts's.
import type { DatabaseSync } from "node:sqlite";
import { see, checkVersion } from "../../../src/store/session-bindings-index.ts";

export * from "../../../src/store/session-bindings-index.ts";

export const SESSION_BINDINGS_FIRST = `SELECT CAST(rowid AS TEXT) AS position FROM bindings
  WHERE rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export const SESSION_BINDINGS_NEXT = `SELECT CAST(rowid AS TEXT) AS position FROM bindings
  WHERE rowid > CAST(? AS INTEGER) AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export const SESSION_BINDINGS_SELECTED = `SELECT i.session, i.connect FROM json_each(?) k
  CROSS JOIN session_binding_rows i WHERE i.session = k.value ORDER BY i.binding_rowid`;
export function sessionBindingsStep(db: DatabaseSync, limit = 256): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("session binding batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const meta = db.prepare(`SELECT version, CAST(last_rowid AS TEXT) AS last_rowid, CAST(end_rowid AS TEXT) AS end_rowid, complete
      FROM session_binding_meta WHERE id = 1`).get() as { version: number; last_rowid: string | null; end_rowid: string | null; complete: number } | undefined;
    if (meta === undefined) throw new Error("session binding index version marker is missing");
    checkVersion(meta.version);
    if (meta.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = (meta.last_rowid === null
      ? db.prepare(SESSION_BINDINGS_FIRST).all(meta.end_rowid, limit)
      : db.prepare(SESSION_BINDINGS_NEXT).all(meta.last_rowid, meta.end_rowid, limit)) as { position: string }[];
    const put = db.prepare(see("CAST(? AS INTEGER)"));
    for (const row of rows) put.run(row.position);
    const done = rows.length < limit;
    db.prepare("UPDATE session_binding_meta SET last_rowid = CAST(? AS INTEGER), complete = ? WHERE id = 1")
      .run(rows.at(-1)?.position ?? meta.last_rowid, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}