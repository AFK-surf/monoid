// Names at the sandbox front door are hashes of session keys and cannot be looked up in sessions. Prepare the reverse
// lookup only for a station that uses sandboxes. Old writers put changed keys in a small journal; hashing and an old
// store's initial preparation happen in bounded batches, never in a trigger on an older connection.
import type { DatabaseSync } from "node:sqlite";
import { keyPart, sandboxName } from "../agents/sandbox-name.ts";
import { type Json, type SessionRow, toSession } from "./rows.ts";

export const VERSION = 1;
export const EXISTS = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sandbox_name_meta'";
export const DIRTY = (key: string) => `INSERT INTO sandbox_name_dirty (session)
  SELECT ${key} WHERE ${key} IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM sandbox_name_dirty d WHERE d.session = ${key});`;
export const CONFLICTS = `INSERT INTO sandbox_name_dirty (session)
  SELECT s.key FROM sessions s WHERE (s.token = NEW.token OR s.rowid = NEW.rowid) AND s.key IS NOT NEW.key
    AND NOT EXISTS (SELECT 1 FROM sandbox_name_dirty d WHERE d.session = s.key);`;

export const hasSandboxIndex = (db: DatabaseSync): boolean => db.prepare(EXISTS).get() !== undefined;

/// The old query orders by activity descending and lets the last session of a colliding name win. The ascending
/// activity and descending rowid reproduce that choice without reading unrelated sessions.
export const SANDBOX_SESSION = `SELECT s.key FROM sandbox_name_rows n
  CROSS JOIN sessions s ON s.key = n.session
  WHERE n.name = ? ORDER BY s.last_active_at ASC, s.rowid DESC LIMIT 1`;
/// The old runner lookup preferred live sessions, then the least recently active among sessions with the same id.
/// Its live and all-session queries use different tie ordering; keep both while checking the unhashed runner part.
const RUNNER_ORDER = `(s.archived_at IS NULL) DESC, s.last_active_at ASC,
  CASE WHEN s.archived_at IS NULL THEN s.rowid END ASC,
  CASE WHEN s.archived_at IS NOT NULL THEN s.rowid END DESC`;
export const RUNNER_SESSION_CANDIDATES = `SELECT s.key FROM sandbox_name_rows n
  CROSS JOIN sessions s ON s.key = n.session WHERE n.name = ?
  ORDER BY ${RUNNER_ORDER}`;
/// Takeup needs every matching session, including archived sessions and colliding runner names. The old all-session
/// query orders equal activity by rowid ascending; keep that order when combining them with running Codex sessions.
export const RUNNER_TAKEUP_NAMES = "SELECT session FROM sandbox_name_rows INDEXED BY sandbox_name_lookup WHERE name = ?";
export const RUNNER_TAKEUP_SESSIONS = `WITH keys AS (
  SELECT value AS key FROM json_each(?1)
  UNION SELECT key FROM sessions INDEXED BY sessions_running WHERE running = 1 AND runtime = 'codex'
)
SELECT s.* FROM keys k CROSS JOIN sessions s ON s.key = k.key
ORDER BY s.last_active_at DESC, s.rowid ASC`;
export const RUNNER_DIRTY_LIMIT = 64;
const RUNNER_TAKEUP_LIMIT = 8192;
export function runnerChoiceFromKeys(count: number): string {
  if (!Number.isSafeInteger(count) || count < 1 || count > RUNNER_DIRTY_LIMIT + 1) throw new RangeError("bad runner candidate count");
  return `SELECT s.key FROM sessions s WHERE s.key IN (${Array(count).fill("?").join(", ")}) ORDER BY ${RUNNER_ORDER} LIMIT 1`;
}
export const SANDBOX_DIRTY_BATCH = "SELECT session FROM sandbox_name_dirty ORDER BY session LIMIT ?";

export function sandboxIndexReady(db: DatabaseSync): boolean {
  return db.prepare(`SELECT 1 FROM sandbox_name_meta WHERE id = 1 AND version = ? AND enabled = 1 AND phase = 2
    AND NOT EXISTS (SELECT 1 FROM sandbox_name_dirty LIMIT 1)`).get(VERSION) !== undefined;
}

export function sandboxIndexEnabled(db: DatabaseSync): boolean {
  if (!hasSandboxIndex(db)) return false;
  const meta = db.prepare("SELECT version, enabled FROM sandbox_name_meta WHERE id = 1").get() as
    { version: number; enabled: number } | undefined;
  if (meta?.version !== VERSION) throw new Error(`sandbox name index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
  return meta.enabled === 1;
}

/// A single read snapshot keeps the readiness check and every name lookup together with older writers.
export function sandboxSessions(db: DatabaseSync, names: readonly string[]): Map<string, string> | null {
  db.exec("BEGIN");
  try {
    if (!sandboxIndexReady(db)) { db.exec("COMMIT"); return null; }
    const lookup = db.prepare(SANDBOX_SESSION);
    const found = new Map<string, string>();
    for (const name of names) {
      const row = lookup.get(name) as { key: string } | undefined;
      if (row !== undefined) found.set(name, row.key);
    }
    db.exec("COMMIT");
    return found;
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// A runner uses the same session-key part as a sandbox. Verify it after the sandbox-name lookup: both names are
/// shortened, so a collision in the sandbox name alone must not attribute a runner to another session.
export function runnerNameSessions(db: DatabaseSync, runners: readonly { id: string; part: string }[]): Map<string, string> | null {
  db.exec("BEGIN");
  try {
    // Once historical preparation is complete, a small pending journal can be overlaid on the indexed names. This
    // keeps one newly created session from making the next memory check reread every unrelated session.
    const prepared = db.prepare("SELECT 1 FROM sandbox_name_meta WHERE id = 1 AND version = ? AND enabled = 1 AND phase = 2").get(VERSION);
    if (prepared === undefined) { db.exec("COMMIT"); return null; }
    const dirty = db.prepare(SANDBOX_DIRTY_BATCH).all(RUNNER_DIRTY_LIMIT + 1) as { session: string }[];
    if (dirty.length > RUNNER_DIRTY_LIMIT) { db.exec("COMMIT"); return null; }
    const lookup = db.prepare(RUNNER_SESSION_CANDIDATES);
    const wanted = new Set(runners.map(({ part }) => part));
    const changed = new Map<string, string[]>();
    for (const { session } of dirty) {
      const part = keyPart(session);
      if (wanted.has(part)) changed.set(part, [...(changed.get(part) ?? []), session]);
    }
    const parts = new Map<string, string | undefined>();
    const found = new Map<string, string>();
    for (const { id, part } of runners) {
      if (!parts.has(part)) {
        const rows = lookup.all(sandboxName(part)) as { key: string }[];
        let key = rows.find((row) => keyPart(row.key) === part)?.key;
        const updates = changed.get(part);
        if (updates !== undefined) {
          const choices = [...new Set(key === undefined ? updates : [key, ...updates])];
          key = (db.prepare(runnerChoiceFromKeys(choices.length)).get(...choices) as { key: string } | undefined)?.key;
        }
        parts.set(part, key);
      }
      const key = parts.get(part);
      if (key !== undefined) found.set(id, key);
    }
    db.exec("COMMIT");
    return found;
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// Take up all sessions for the runner parts, with the current dirty journal and running Codex sessions from one
/// snapshot. Null keeps the original immediate all-session read while the lookup is incomplete or unusually large.
export function runnerTakeUpSessions(db: DatabaseSync, parts: readonly string[]): SessionRow[] | null {
  db.exec("BEGIN");
  try {
    const keys = new Set<string>();
    if (parts.length !== 0) {
      const prepared = db.prepare("SELECT 1 FROM sandbox_name_meta WHERE id = 1 AND version = ? AND enabled = 1 AND phase = 2").get(VERSION);
      if (prepared === undefined) { db.exec("COMMIT"); return null; }
      const dirty = db.prepare(SANDBOX_DIRTY_BATCH).all(RUNNER_DIRTY_LIMIT + 1) as { session: string }[];
      if (dirty.length > RUNNER_DIRTY_LIMIT) { db.exec("COMMIT"); return null; }
      const wanted = new Set(parts);
      const lookup = db.prepare(RUNNER_TAKEUP_NAMES);
      for (const part of wanted) {
        for (const { session } of lookup.all(sandboxName(part)) as { session: string }[]) {
          if (keyPart(session) === part) keys.add(session);
        }
      }
      for (const { session } of dirty) if (wanted.has(keyPart(session))) keys.add(session);
    }
    // SQLite's JSON reader does not preserve a NUL in a string. Do not lose an old key through that encoding.
    if (keys.size > RUNNER_TAKEUP_LIMIT || [...keys].some((key) => key.includes("\0"))) {
      db.exec("COMMIT"); return null;
    }
    const rows = db.prepare(RUNNER_TAKEUP_SESSIONS).all(JSON.stringify([...keys])) as Json[];
    db.exec("COMMIT");
    return rows.map(toSession);
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
