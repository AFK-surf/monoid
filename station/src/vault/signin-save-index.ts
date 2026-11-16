// A save decision names its request, while the corresponding sign-in used to be found by parsing every completed
// sign-in in the session. Maintain that association as sign-ins change; older ones are indexed in bounded steps.
import type { DatabaseSync } from "node:sqlite";

const add = `INSERT INTO signin_save_lookup (ask, session, save)
  SELECT NEW.id, NEW.session, json_extract(NEW.body, '$.save')
  WHERE json_type(NEW.body, '$.save') = 'text' AND NOT EXISTS (SELECT 1 FROM signin_save_lookup WHERE ask = NEW.id);`;
const changed = `DELETE FROM signin_save_lookup WHERE ask = NEW.id AND
  (session IS NOT NEW.session OR save IS NOT json_extract(NEW.body, '$.save')); ${add}`;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS signin_save_lookup (ask TEXT PRIMARY KEY, session TEXT NOT NULL, save TEXT NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS signin_save_by_request ON signin_save_lookup (session, save, ask);
CREATE TABLE IF NOT EXISTS signin_save_progress (session TEXT PRIMARY KEY, status TEXT, row INTEGER, done INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS signin_save_pending (session TEXT NOT NULL, save TEXT NOT NULL, status TEXT NOT NULL,
  PRIMARY KEY (session, save)) WITHOUT ROWID;
CREATE TRIGGER IF NOT EXISTS signin_save_add AFTER INSERT ON signin_asks BEGIN ${changed} END;
CREATE TRIGGER IF NOT EXISTS signin_save_change AFTER UPDATE OF id, session, body ON signin_asks BEGIN
  DELETE FROM signin_save_lookup WHERE ask = OLD.id AND OLD.id IS NOT NEW.id;
  ${changed}
END;
CREATE TRIGGER IF NOT EXISTS signin_save_drop AFTER DELETE ON signin_asks BEGIN
  DELETE FROM signin_save_lookup WHERE ask = OLD.id;
END;`;

/// No older sign-ins are read when the lookup and its triggers are installed.
export function installSigninSaveIndex(db: DatabaseSync): void { db.exec(SCHEMA); }

export const SIGNIN_SAVE = `SELECT a.body FROM signin_save_lookup l INDEXED BY signin_save_by_request
  JOIN signin_asks a ON a.id = l.ask WHERE l.session = ? AND l.save = ? ORDER BY a.status, a.rowid LIMIT 1`;

export function signinForSave(db: DatabaseSync, session: string, save: string): string | null {
  return (db.prepare(SIGNIN_SAVE).get(session, save) as { body: string } | undefined)?.body ?? null;
}

export type PendingSigninSave = { session: string; save: string; status: string };
export function pendingSigninSave(db: DatabaseSync, session?: string): PendingSigninSave | null {
  return (session === undefined
    ? db.prepare("SELECT session, save, status FROM signin_save_pending ORDER BY session, save LIMIT 1").get()
    : db.prepare("SELECT session, save, status FROM signin_save_pending WHERE session = ? ORDER BY save LIMIT 1").get(session)) as PendingSigninSave | undefined ?? null;
}

/// Round-robin the waiting sessions without walking the other sessions' requests.
export function nextPendingSigninSave(db: DatabaseSync, after: string | null): PendingSigninSave | null {
  const next = after === null ? undefined : db.prepare("SELECT session, save, status FROM signin_save_pending WHERE session > ? ORDER BY session, save LIMIT 1").get(after);
  return (next as PendingSigninSave | undefined) ?? pendingSigninSave(db);
}

export function forgetSigninSave(db: DatabaseSync, session: string, save: string, status?: string): void {
  if (status === undefined) db.prepare("DELETE FROM signin_save_pending WHERE session = ? AND save = ?").run(session, save);
  else db.prepare("DELETE FROM signin_save_pending WHERE session = ? AND save = ? AND status = ?").run(session, save, status);
}

export function queueSigninSave(db: DatabaseSync, session: string, save: string, status: string): void {
  db.prepare(`INSERT INTO signin_save_pending (session, save, status) VALUES (?, ?, ?)
    ON CONFLICT (session, save) DO UPDATE SET status = excluded.status WHERE status IS NOT excluded.status`).run(session, save, status);
}

export function signinSaveComplete(db: DatabaseSync, session: string): boolean {
  return (db.prepare("SELECT done FROM signin_save_progress WHERE session = ?").get(session) as { done: number } | undefined)?.done === 1;
}
