// The chats' statistics' steps in TypeScript before the MoonBit builder took them over (station/mb src/usagefill
// `drain_chat_dirty_step`, run by src/usage/module.ts `drainUsageChats`), kept to compare the program with: the station
// has no step in TypeScript to fall back to. The old chats' fill (`backfillUsageChatStats`) the station runs nowhere:
// incomplete old statistics stay so. What it still runs is src/store/usage-chat-stats.ts's.
import type { DatabaseSync } from "node:sqlite";
import { picked, place } from "../../../src/store/usage-chat-stats.ts";

/// One batch of a moved session's chats (usage_chat_dirty, which a session's change of workspace, key or token marks):
/// each of its memberships given its workspace as it is now. None where no session waits; `done`: none waits after it.
function drainDirty(db: DatabaseSync, limit: number): { done: boolean; processed: number } | null {
  const dirty = db.prepare("SELECT session, thread_after FROM usage_chat_dirty ORDER BY session LIMIT 1").get() as
    { session: string; thread_after: number | null } | undefined;
  if (dirty === undefined) return null;
  const session = db.prepare("SELECT ws FROM sessions WHERE key = ?").get(dirty.session) as { ws: string | null } | undefined;
  const rows = (dirty.thread_after === null
    ? db.prepare("SELECT thread FROM usage_chat_members INDEXED BY usage_chat_members_session WHERE session = ? ORDER BY thread LIMIT ?").all(dirty.session, limit)
    : db.prepare("SELECT thread FROM usage_chat_members INDEXED BY usage_chat_members_session WHERE session = ? AND thread > ? ORDER BY thread LIMIT ?").all(dirty.session, dirty.thread_after, limit)) as { thread: number }[];
  const update = db.prepare("UPDATE usage_chat_members SET ws = ?, present = ? WHERE session = ? AND thread = ? AND (ws IS NOT ? OR present IS NOT ?)");
  const ws = session?.ws ?? null, present = session === undefined ? 0 : 1;
  for (const row of rows) update.run(ws, present, dirty.session, row.thread, ws, present);
  if (rows.length < limit) {
    db.prepare("DELETE FROM usage_chat_dirty_scope WHERE session = ?").run(dirty.session);
    db.prepare("DELETE FROM usage_chat_dirty WHERE session = ?").run(dirty.session);
  } else db.prepare("UPDATE usage_chat_dirty SET thread_after = ? WHERE session = ?").run(rows.at(-1)!.thread, dirty.session);
  return { done: db.prepare("SELECT 1 FROM usage_chat_dirty LIMIT 1").get() === undefined, processed: rows.length };
}

/// One transaction of the chats of sessions that moved (`drainDirty`), and nothing of the old chats' fill
/// (usage_chat_progress): the station runs it as sessions move, so that the page's chats are whole again
/// (usage/module.ts `drainUsageChats`). `done`: no moved session waits.
export function drainUsageChatDirty(db: DatabaseSync, limit = 32): { done: boolean; processed: number } {
  db.exec("BEGIN IMMEDIATE");
  try {
    const moved = drainDirty(db, limit) ?? { done: true, processed: 0 };
    db.exec("COMMIT");
    return moved;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

type Progress = { stage: number; thread_after: number | null; thread_end: number | null; member_after: number | null;
  member_end: number | null; card_thread: number | null; card_n: number | null; card_end_thread: number | null;
  card_end_n: number | null; done: number };

/// Copy at most `limit` old objects. The cursor and their contributions commit together; a concurrent write is already
/// represented by the triggers, so INSERT OR IGNORE never counts it a second time.
export function backfillUsageChatStats(db: DatabaseSync, limit = 32): { done: boolean; processed: number } {
  db.exec("BEGIN IMMEDIATE");
  try {
    const state = db.prepare("SELECT * FROM usage_chat_progress WHERE id = 1").get() as Progress;
    const moved = drainDirty(db, limit);
    if (moved !== null) {
      const done = state.done === 1 && moved.done;
      db.exec("COMMIT");
      return { done, processed: moved.processed };
    }
    if (state.done) { db.exec("COMMIT"); return { done: true, processed: 0 }; }
    let processed = 0;
    if (state.stage === 0) {
      const rows = (state.thread_end === null ? [] : state.thread_after === null
        ? db.prepare("SELECT id, surface, hidden_at FROM threads WHERE id <= ? ORDER BY id LIMIT ?").all(state.thread_end, limit)
        : db.prepare("SELECT id, surface, hidden_at FROM threads WHERE id > ? AND id <= ? ORDER BY id LIMIT ?").all(state.thread_after, state.thread_end, limit)) as
        { id: number; surface: string; hidden_at: number | null }[];
      const insert = db.prepare("INSERT OR IGNORE INTO usage_chat_stats VALUES (?, ?, 1, ?, 0, 0)");
      for (const row of rows) insert.run(row.id, row.surface.split(":")[0] ?? row.surface, row.hidden_at === null ? 0 : 1);
      processed = rows.length;
      db.prepare("UPDATE usage_chat_progress SET thread_after = ?, stage = ? WHERE id = 1")
        .run(rows.at(-1)?.id ?? state.thread_after, rows.length < limit ? 1 : 0);
    } else if (state.stage === 1) {
      const rows = (state.member_end === null ? [] : state.member_after === null
        ? db.prepare("SELECT rowid AS seq, thread, session FROM thread_sessions WHERE rowid <= ? ORDER BY rowid LIMIT ?").all(state.member_end, limit)
        : db.prepare("SELECT rowid AS seq, thread, session FROM thread_sessions WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?").all(state.member_after, state.member_end, limit)) as
        { seq: number; thread: number; session: string }[];
      const addThread = db.prepare(`INSERT OR IGNORE INTO usage_chat_stats
        SELECT ?1, CASE WHEN t.id IS NULL THEN '' ELSE ${place("t")} END, t.id IS NOT NULL,
          t.id IS NOT NULL AND t.hidden_at IS NOT NULL, 0, 0 FROM (SELECT 1) LEFT JOIN threads t ON t.id = ?1`);
      const insert = db.prepare(`INSERT OR IGNORE INTO usage_chat_members VALUES (?1, ?2,
        (SELECT ws FROM sessions WHERE key = ?2), EXISTS (SELECT 1 FROM sessions WHERE key = ?2))`);
      for (const row of rows) { addThread.run(row.thread); insert.run(row.thread, row.session); }
      processed = rows.length;
      db.prepare("UPDATE usage_chat_progress SET member_after = ?, stage = ? WHERE id = 1")
        .run(rows.at(-1)?.seq ?? state.member_after, rows.length < limit ? 2 : 1);
    } else {
      const rows = (state.card_end_thread === null ? [] : state.card_thread === null
        ? db.prepare(`SELECT thread, n FROM card_outcomes WHERE (thread, n) <= (?, ?) ORDER BY thread, n LIMIT ?`)
          .all(state.card_end_thread, state.card_end_n, limit)
        : db.prepare(`SELECT thread, n FROM card_outcomes WHERE (thread, n) > (?, ?) AND (thread, n) <= (?, ?) ORDER BY thread, n LIMIT ?`)
          .all(state.card_thread, state.card_n, state.card_end_thread, state.card_end_n, limit)) as { thread: number; n: number }[];
      const addThread = db.prepare(`INSERT OR IGNORE INTO usage_chat_stats
        SELECT ?1, CASE WHEN t.id IS NULL THEN '' ELSE ${place("t")} END, t.id IS NOT NULL,
          t.id IS NOT NULL AND t.hidden_at IS NOT NULL, 0, 0 FROM (SELECT 1) LEFT JOIN threads t ON t.id = ?1`);
      const insert = db.prepare(`INSERT OR IGNORE INTO usage_chat_cards
        SELECT c.thread, c.n, ${picked("c")} FROM card_outcomes c WHERE c.thread = ? AND c.n = ?`);
      for (const row of rows) { addThread.run(row.thread); insert.run(row.thread, row.n); }
      processed = rows.length;
      const last = rows.at(-1);
      db.prepare("UPDATE usage_chat_progress SET card_thread = ?, card_n = ?, done = ? WHERE id = 1")
        .run(last?.thread ?? state.card_thread, last?.n ?? state.card_n, rows.length < limit ? 1 : 0);
    }
    const done = (db.prepare("SELECT done FROM usage_chat_progress WHERE id = 1").get() as { done: number }).done === 1;
    db.exec("COMMIT");
    return { done, processed };
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}
