// The steps src/store/chat-share-index.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/chat-share-index.ts's.
import type { DatabaseSync } from "node:sqlite";
import { type Json } from "../../../src/store/rows.ts";
import { VERSION, presence, dirty, conflicts, SHARE_DIRTY, refreshChatShareIndex, shareValues } from "../../../src/store/chat-share-index.ts";

export * from "../../../src/store/chat-share-index.ts";

export const SHARE_FIRST = "SELECT session FROM chat_shares WHERE session <= ? ORDER BY session LIMIT ?";
export const SHARE_NEXT = "SELECT session FROM chat_shares WHERE session > ? AND session <= ? ORDER BY session LIMIT ?";
export function installChatShareIndex(db: DatabaseSync): void {
  if (refreshChatShareIndex(db)) {
    const meta = db.prepare("SELECT version FROM chat_share_index_meta WHERE id = 1").get() as { version: number } | undefined;
    if (meta?.version !== VERSION) throw new Error(`chat share index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
    return;
  }
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!refreshChatShareIndex(db)) db.exec(`
      CREATE TABLE chat_share_index_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL,
        phase INTEGER NOT NULL, cursor TEXT, end_session TEXT) WITHOUT ROWID;
      INSERT INTO chat_share_index_meta VALUES (1, ${VERSION}, 0, NULL,
        (SELECT session FROM chat_shares WHERE session IS NOT NULL ORDER BY session DESC LIMIT 1));
      CREATE TABLE chat_share_targets (session TEXT NOT NULL, ordinal INTEGER NOT NULL, workspace TEXT NOT NULL,
        used INTEGER NOT NULL, PRIMARY KEY(session, ordinal)) WITHOUT ROWID;
      CREATE INDEX chat_share_target_time ON chat_share_targets (used, session);
      CREATE INDEX chat_share_target_workspace ON chat_share_targets (workspace, used, session);
      CREATE TABLE chat_share_uncertain (session TEXT PRIMARY KEY) WITHOUT ROWID;
      CREATE TABLE chat_share_dirty (session TEXT PRIMARY KEY) WITHOUT ROWID;
      CREATE TRIGGER chat_share_index_before_add BEFORE INSERT ON chat_shares BEGIN ${dirty("NEW.session")} ${conflicts} END;
      CREATE TRIGGER chat_share_index_before_change BEFORE UPDATE ON chat_shares
        WHEN OLD.rowid IS NOT NEW.rowid OR OLD.session IS NOT NEW.session OR OLD.shared IS NOT NEW.shared OR OLD.at IS NOT NEW.at
        BEGIN ${dirty("OLD.session")} ${dirty("NEW.session")} ${conflicts} END;
      CREATE TRIGGER chat_share_index_before_drop BEFORE DELETE ON chat_shares BEGIN ${dirty("OLD.session")} END;
    `);
    else {
      const meta = db.prepare("SELECT version FROM chat_share_index_meta WHERE id = 1").get() as { version: number } | undefined;
      if (meta?.version !== VERSION) throw new Error(`chat share index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
    }
    db.exec("COMMIT");
    presence.set(db, true);
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// At most `limit` chat keys are processed under one writer transaction. Unusual old values remain on a short list
/// that keeps reads on the original JavaScript rules, including excessively large or noncanonical saved shares.
export function chatShareIndexStep(db: DatabaseSync, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("chat share batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const meta = db.prepare("SELECT version, phase, cursor, end_session FROM chat_share_index_meta WHERE id = 1").get() as
      { version: number; phase: number; cursor: string | null; end_session: string | null } | undefined;
    if (meta?.version !== VERSION) throw new Error(`chat share index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
    const source = db.prepare("SELECT * FROM chat_shares WHERE session = ?");
    const remove = db.prepare("DELETE FROM chat_share_targets WHERE session = ?");
    const removeUncertain = db.prepare("DELETE FROM chat_share_uncertain WHERE session = ?");
    const add = db.prepare("INSERT INTO chat_share_targets (session, ordinal, workspace, used) VALUES (?, ?, ?, ?)");
    const uncertain = db.prepare("INSERT INTO chat_share_uncertain (session) VALUES (?)");
    const clear = db.prepare("DELETE FROM chat_share_dirty WHERE session = ?");
    let { phase, cursor } = meta;
    let visited = 0;
    while (visited < limit) {
      const keys = phase === 0 ? (meta.end_session === null ? [] : (cursor === null
        ? db.prepare(SHARE_FIRST).all(meta.end_session, limit - visited)
        : db.prepare(SHARE_NEXT).all(cursor, meta.end_session, limit - visited)))
        : db.prepare(SHARE_DIRTY).all(limit - visited);
      if (keys.length === 0) { if (phase === 0) { phase = 1; cursor = null; continue; } break; }
      for (const { session } of keys as { session: string }[]) {
        remove.run(session); removeUncertain.run(session);
        const row = source.get(session) as Json | undefined;
        if (row !== undefined) {
          const values = shareValues(row);
          if (values === null) uncertain.run(session);
          else for (let i = 0; i < values.length; i++) {
            const target = values[i]!;
            add.run(session, i, target.workspace, target.used);
          }
        }
        clear.run(session);
        if (phase === 0) cursor = session;
        visited++;
      }
    }
    db.prepare("UPDATE chat_share_index_meta SET phase = ?, cursor = ? WHERE id = 1").run(phase, cursor);
    const done = phase === 1 && db.prepare("SELECT 1 FROM chat_share_dirty LIMIT 1").get() === undefined;
    db.exec("COMMIT");
    return { done, visited };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
