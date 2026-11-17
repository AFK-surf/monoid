// The steps src/store/session-directory.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/session-directory.ts's.
import type { DatabaseSync } from "node:sqlite";

import { VERSION, EXISTS, DIRTY, CONFLICTS, SESSION_DIR_DIRTY } from "../../../src/store/session-directory.ts";

export * from "../../../src/store/session-directory.ts";

export const SESSION_DIR_FIRST = "SELECT key AS session FROM sessions WHERE key <= ? ORDER BY key LIMIT ?";
export const SESSION_DIR_NEXT = "SELECT key AS session FROM sessions WHERE key > ? AND key <= ? ORDER BY key LIMIT ?";
export function installSessionDirectories(db: DatabaseSync): void {
  if (db.prepare(EXISTS).get() !== undefined) {
    const meta = db.prepare("SELECT version FROM session_dir_meta WHERE id = 1").get() as { version: number } | undefined;
    if (meta?.version !== VERSION) throw new Error(`session directory index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
    return;
  }
  db.exec("BEGIN IMMEDIATE");
  try {
    if (db.prepare(EXISTS).get() === undefined) db.exec(`
      CREATE TABLE session_dir_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL,
        phase INTEGER NOT NULL, cursor TEXT, end_session TEXT) WITHOUT ROWID;
      INSERT INTO session_dir_meta VALUES (1, ${VERSION}, 0, NULL,
        (SELECT key FROM sessions WHERE key IS NOT NULL ORDER BY key DESC LIMIT 1));
      CREATE TABLE session_dir_rows (session TEXT NOT NULL, root TEXT NOT NULL, PRIMARY KEY(session, root)) WITHOUT ROWID;
      CREATE INDEX session_dir_root ON session_dir_rows (root, session);
      CREATE TABLE session_dir_dirty (session TEXT PRIMARY KEY) WITHOUT ROWID;
      CREATE TRIGGER session_dir_before_add BEFORE INSERT ON sessions BEGIN
        ${DIRTY("NEW.key")} ${CONFLICTS}
      END;
      CREATE TRIGGER session_dir_before_change BEFORE UPDATE ON sessions
        WHEN OLD.rowid IS NOT NEW.rowid OR OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token
          OR OLD.workspace IS NOT NEW.workspace OR OLD.cwd IS NOT NEW.cwd BEGIN
        ${DIRTY("OLD.key")} ${DIRTY("NEW.key")} ${CONFLICTS}
      END;
      CREATE TRIGGER session_dir_before_drop BEFORE DELETE ON sessions BEGIN
        ${DIRTY("OLD.key")}
      END;
    `);
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// Each transaction visits at most `limit` historical or journalled sessions.
export function sessionDirectoriesStep(db: DatabaseSync, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("session directory batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const meta = db.prepare("SELECT version, phase, cursor, end_session FROM session_dir_meta WHERE id = 1").get() as
      { version: number; phase: number; cursor: string | null; end_session: string | null } | undefined;
    if (meta?.version !== VERSION) throw new Error(`session directory index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
    const remove = db.prepare("DELETE FROM session_dir_rows WHERE session = ?");
    const insert = db.prepare(`INSERT INTO session_dir_rows (session, root)
      SELECT key, workspace FROM sessions WHERE key = ? AND workspace <> ''
      UNION SELECT key, cwd FROM sessions WHERE key = ? AND cwd IS NOT NULL AND cwd <> ''`);
    const clear = db.prepare("DELETE FROM session_dir_dirty WHERE session = ?");
    let { phase, cursor } = meta;
    let visited = 0;
    while (visited < limit) {
      let rows: { session: string }[];
      if (phase === 0) {
        rows = meta.end_session === null ? [] : (cursor === null
          ? db.prepare(SESSION_DIR_FIRST).all(meta.end_session, limit - visited)
          : db.prepare(SESSION_DIR_NEXT).all(cursor, meta.end_session, limit - visited)) as { session: string }[];
        if (rows.length === 0) { phase = 1; cursor = null; continue; }
      } else {
        rows = db.prepare(SESSION_DIR_DIRTY).all(limit - visited) as { session: string }[];
        if (rows.length === 0) break;
      }
      for (const { session } of rows) {
        remove.run(session);
        insert.run(session, session);
        clear.run(session);
        if (phase === 0) cursor = session;
        visited++;
      }
    }
    db.prepare("UPDATE session_dir_meta SET phase = ?, cursor = ? WHERE id = 1").run(phase, cursor);
    const done = phase === 1 && db.prepare("SELECT 1 FROM session_dir_dirty LIMIT 1").get() === undefined;
    db.exec("COMMIT");
    return { done, visited };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
