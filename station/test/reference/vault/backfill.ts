// The vault's background fills in TypeScript before the MoonBit use reader took them over (station/mb src/vaultuses,
// src/vault/use-reader-mb.ts `MbUseReader`), kept to compare it with: every workspace's use index a workspace at a time,
// and the requests whose boxes might need recovery. What the station still runs of them (a database it cannot hand the
// reader, a test's in memory) is src/vault/'s.
import type { DatabaseSync } from "node:sqlite";
import { backfillUsePreparation, usePreparationReady } from "../../../src/vault/use-index.ts";
import { REBOX_BACKFILL_FIRST, REBOX_BACKFILL_NEXT } from "../../../src/vault/rebox-index.ts";

/// In the background, discover one workspace at a time through the requests' primary key and fill one batch. Reads
/// can preempt this work with their own workspace; the saved per-workspace cursor also lets another process resume it.
export function backfillNextWorkspace(db: DatabaseSync): boolean {
  const state = db.prepare("SELECT after_ws, done FROM vault_use_backfill_all WHERE id = 1").get() as { after_ws: string | null; done: number };
  if (state.done) return true;
  const next = (state.after_ws === null
    ? db.prepare("SELECT ws FROM vault_requests ORDER BY ws LIMIT 1").get()
    : db.prepare("SELECT ws FROM vault_requests WHERE ws > ? ORDER BY ws LIMIT 1").get(state.after_ws)) as { ws: string } | undefined;
  if (!next) {
    db.prepare("UPDATE vault_use_backfill_all SET done = 1 WHERE id = 1 AND after_ws IS ?").run(state.after_ws);
    return (db.prepare("SELECT done FROM vault_use_backfill_all WHERE id = 1").get() as { done: number }).done === 1;
  }
  if (usePreparationReady(db, next.ws) || backfillUsePreparation(db, next.ws)) {
    db.prepare("UPDATE vault_use_backfill_all SET after_ws = ? WHERE id = 1 AND after_ws IS ? AND done = 0").run(next.ws, state.after_ws);
  }
  return false;
}

/// Fill at most `limit` old IDs. The cursor and lookup commit together; triggers cover writes on either side of it.
export function backfillReboxIndex(db: DatabaseSync, limit = 32): boolean {
  db.exec("BEGIN IMMEDIATE");
  try {
    const state = db.prepare("SELECT after_ws, after_id, done FROM vault_rebox_backfill WHERE id = 1").get() as
      { after_ws: string | null; after_id: string | null; done: number };
    if (state.done) { db.exec("COMMIT"); return true; }
    const rows = (state.after_ws === null
      ? db.prepare(REBOX_BACKFILL_FIRST).all(limit)
      : db.prepare(REBOX_BACKFILL_NEXT).all(state.after_ws, state.after_id!, limit)) as { ws: string; id: string }[];
    const add = db.prepare(`INSERT INTO vault_rebox_lookup SELECT ws, id FROM vault_requests
      WHERE ws = ? AND id = ? AND status = 'pending' ON CONFLICT(ws, id) DO NOTHING`);
    for (const row of rows) add.run(row.ws, row.id);
    const last = rows.at(-1);
    const done = rows.length < limit;
    db.prepare("UPDATE vault_rebox_backfill SET after_ws = ?, after_id = ?, done = ? WHERE id = 1")
      .run(last?.ws ?? state.after_ws, last?.id ?? state.after_id, done ? 1 : 0);
    db.exec("COMMIT");
    return done;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}
