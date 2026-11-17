// Requests whose boxes might need recovery. An old database is filled in bounded batches; future changes keep it current.
// Keep (ws, id), rather than SQLite rowids: a VACUUM may change rowids in the original table.
import type { DatabaseSync } from "node:sqlite";
import { installSchema } from "./schema-install.ts";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS vault_rebox_lookup (
  ws TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (ws, id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS vault_rebox_backfill (
  id INTEGER PRIMARY KEY CHECK (id = 1), after_ws TEXT, after_id TEXT, done INTEGER NOT NULL
);
CREATE TRIGGER IF NOT EXISTS vault_rebox_add AFTER INSERT ON vault_requests BEGIN
  DELETE FROM vault_rebox_lookup WHERE ws = NEW.ws AND id = NEW.id AND NEW.status != 'pending';
  INSERT INTO vault_rebox_lookup SELECT NEW.ws, NEW.id WHERE NEW.status = 'pending'
    ON CONFLICT(ws, id) DO NOTHING;
END;
CREATE TRIGGER IF NOT EXISTS vault_rebox_change AFTER UPDATE ON vault_requests
  WHEN (OLD.status = 'pending' OR NEW.status = 'pending')
    AND (OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.status IS NOT NEW.status) BEGIN
  DELETE FROM vault_rebox_lookup WHERE ws = OLD.ws AND id = OLD.id;
  INSERT INTO vault_rebox_lookup SELECT NEW.ws, NEW.id WHERE NEW.status = 'pending'
    ON CONFLICT(ws, id) DO NOTHING;
END;
CREATE TRIGGER IF NOT EXISTS vault_rebox_drop AFTER DELETE ON vault_requests WHEN OLD.status = 'pending' BEGIN
  DELETE FROM vault_rebox_lookup WHERE ws = OLD.ws AND id = OLD.id;
END;
INSERT OR IGNORE INTO vault_rebox_backfill (id, after_ws, after_id, done)
  VALUES (1, NULL, NULL, CASE WHEN EXISTS (SELECT 1 FROM vault_requests LIMIT 1) THEN 0 ELSE 1 END);
`;

// Only pending IDs are traversed after preparation; the temporary sort preserves the old rowid notification order.
export const REBOX_READY = `SELECT r.ws, r.id FROM vault_rebox_lookup p
  CROSS JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id
  WHERE r.status = 'pending' ORDER BY r.rowid`;
export const REBOX_LEGACY = "SELECT ws, id FROM vault_requests WHERE status = 'pending'";
export const REBOX_BACKFILL_FIRST = "SELECT ws, id FROM vault_requests ORDER BY ws, id LIMIT ?";
export const REBOX_BACKFILL_NEXT = "SELECT ws, id FROM vault_requests WHERE (ws, id) > (?, ?) ORDER BY ws, id LIMIT ?";

export function initializeReboxIndex(db: DatabaseSync): void {
  installSchema(db, "vault_rebox_schema", SCHEMA, ["SELECT 1 FROM vault_rebox_backfill WHERE id = 1"]);
}

export function reboxIndexComplete(db: DatabaseSync): boolean {
  return (db.prepare("SELECT done FROM vault_rebox_backfill WHERE id = 1").get() as { done: number }).done === 1;
}
