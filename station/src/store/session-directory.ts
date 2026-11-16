// Reverse lookup of the directories sessions use. Install only when a shared runtime needs it; the old rows and
// changes from older writers are prepared in bounded batches, without hashing or a long transaction in a trigger.
import type { DatabaseSync } from "node:sqlite";

export const VERSION = 1;
export const EXISTS = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_dir_meta'";
export const DIRTY = (key: string) => `INSERT INTO session_dir_dirty (session)
  SELECT ${key} WHERE ${key} IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM session_dir_dirty d WHERE d.session = ${key});`;
export const CONFLICTS = `INSERT INTO session_dir_dirty (session)
  SELECT s.key FROM sessions s WHERE (s.token = NEW.token OR s.rowid = NEW.rowid) AND s.key IS NOT NEW.key
    AND NOT EXISTS (SELECT 1 FROM session_dir_dirty d WHERE d.session = s.key);`;

export const SESSION_DIR_DIRTY = "SELECT session FROM session_dir_dirty ORDER BY session LIMIT ?";
const DIRTY_LIMIT = 64;
/// A small live set is cheaper to read directly than to derive argument roots. The probe reads at most 33 index entries.
export const SESSION_DIR_LIVE_MANY = "SELECT 1 FROM sessions INDEXED BY sessions_live WHERE archived_at IS NULL LIMIT 1 OFFSET 32";
export const SESSION_DIR_LIVE_FEW = "SELECT key, workspace FROM sessions INDEXED BY sessions_live WHERE archived_at IS NULL ORDER BY last_active_at DESC LIMIT 32";
/// The possible first characters of indexed roots, sought without walking the rest of the index.
export const SESSION_DIR_INITIAL = `SELECT 1 FROM session_dir_rows INDEXED BY session_dir_root
  WHERE root >= ?1 AND root < ?2 LIMIT 1`;
/// Candidates are drawn from roots named by the supplied argument lines, plus the bounded pending journal.
export const SESSION_DIR_ARGUMENTS = `WITH matches AS (
  SELECT s.key, s.workspace, s.last_active_at, s.rowid AS ordering FROM json_each(?1) roots
    CROSS JOIN session_dir_rows d INDEXED BY session_dir_root ON d.root = roots.value
    CROSS JOIN sessions s ON s.key = d.session
    WHERE s.archived_at IS NULL AND s.workspace = d.root AND s.workspace <> '' AND s.workspace <> '/' AND s.workspace <> ?2
  UNION
  SELECT s.key, s.workspace, s.last_active_at, s.rowid AS ordering FROM json_each(?3) dirty
    CROSS JOIN sessions s ON s.key = dirty.value
    WHERE s.archived_at IS NULL AND s.workspace IN (SELECT value FROM json_each(?1))
      AND s.workspace <> '' AND s.workspace <> '/' AND s.workspace <> ?2
)
SELECT key, workspace FROM matches ORDER BY last_active_at DESC, ordering DESC`;
const ARGUMENT_CHARS_LIMIT = 262_144;
const ARGUMENT_INITIALS_LIMIT = 512;
const ARGUMENT_ROOTS_LIMIT = 8192;
const ARGUMENT_ROOT_CHARS_LIMIT = 1_048_576;

/// The old live-session list is newest first (rowid descending on ties); the all-session list uses rowid ascending.
export const sessionDirectoryCandidate = (live: boolean) => `SELECT s.key FROM session_dir_rows d
  CROSS JOIN sessions s ON s.key = d.session
  WHERE d.root = ? AND s.archived_at IS ${live ? "" : "NOT "}NULL AND (s.workspace = d.root OR s.cwd = d.root)
  ORDER BY s.last_active_at DESC, s.rowid ${live ? "DESC" : "ASC"} LIMIT 1`;

export function sessionDirectoryChoice(count: number, live: boolean): string {
  if (!Number.isSafeInteger(count) || count < 1 || count > DIRTY_LIMIT + 1) throw new RangeError("bad directory candidate count");
  return `SELECT s.key FROM sessions s WHERE s.key IN (${Array(count).fill("?").join(", ")})
    AND s.archived_at IS ${live ? "" : "NOT "}NULL AND (s.workspace = ? OR s.cwd = ?)
    ORDER BY s.last_active_at DESC, s.rowid ${live ? "DESC" : "ASC"} LIMIT 1`;
}

export function sessionDirectoriesReady(db: DatabaseSync): boolean {
  return db.prepare(EXISTS).get() !== undefined && db.prepare(`SELECT 1 FROM session_dir_meta
    WHERE id = 1 AND version = ? AND phase = 1 AND NOT EXISTS (SELECT 1 FROM session_dir_dirty LIMIT 1)`).get(VERSION) !== undefined;
}

/// Exactly those strings for which the old `sessionIn` considers `dir` to be at or below the root, longest first.
function rootsOf(dir: string): string[] {
  const roots = new Set<string>();
  if (dir) roots.add(dir);
  for (let i = 0; i < dir.length; i++) if (dir[i] === "/") {
    if (i > 0) roots.add(dir.slice(0, i));
    roots.add(dir.slice(0, i + 1));
  }
  return [...roots].sort((a, b) => b.length - a.length);
}

export type DirectorySession = { key: string | null; live: boolean };

function argumentOwners(rows: { key: string; workspace: string }[], lines: readonly string[], home: string): Map<string, string> {
  // Stable sort keeps the original live-session activity order for roots of equal length.
  const places = rows.filter((r) => r.workspace && r.workspace !== "/" && r.workspace !== home)
    .map((r) => ({ key: r.key, dir: r.workspace.endsWith("/") ? r.workspace : `${r.workspace}/` }))
    .sort((a, b) => b.dir.length - a.dir.length);
  const result = new Map<string, string>();
  for (const line of lines) {
    const place = places.find((p) => line.includes(p.dir));
    if (place !== undefined) result.set(line, place.key);
  }
  return result;
}

/// The live workspace whose normalized directory is named in each argument line, with the old longest-match and
/// activity ordering. Null asks the caller to use the old immediate lookup while the index is unready or input is big.
export function sessionDirectoryArguments(db: DatabaseSync, lines: readonly string[], home: string): Map<string, string> | null {
  if (!lines.some((line) => line.includes("/"))) return new Map();
  if (lines.some((line) => line.includes("\0")) || lines.reduce((n, line) => n + line.length, 0) > ARGUMENT_CHARS_LIMIT) return null;
  db.exec("BEGIN");
  try {
    if (db.prepare(SESSION_DIR_LIVE_MANY).get() === undefined) {
      const rows = db.prepare(SESSION_DIR_LIVE_FEW).all() as { key: string; workspace: string }[];
      const result = argumentOwners(rows, lines, home);
      db.exec("COMMIT");
      return result;
    }
    if (db.prepare(EXISTS).get() === undefined) { db.exec("COMMIT"); return null; }
    const prepared = db.prepare("SELECT 1 FROM session_dir_meta WHERE id = 1 AND version = ? AND phase = 1").get(VERSION);
    if (prepared === undefined) { db.exec("COMMIT"); return null; }
    const dirty = db.prepare(SESSION_DIR_DIRTY).all(DIRTY_LIMIT + 1) as { session: string }[];
    if (dirty.length > DIRTY_LIMIT) { db.exec("COMMIT"); return null; }

    const initials = new Set<string>();
    for (const line of lines) for (const ch of line) {
      initials.add(ch);
      const code = ch.codePointAt(0)!;
      if (initials.size > ARGUMENT_INITIALS_LIMIT || code === 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
        db.exec("COMMIT"); return null;
      }
    }
    const possible = db.prepare(SESSION_DIR_INITIAL), starts = new Set<string>();
    for (const ch of initials) {
      const code = ch.codePointAt(0)!;
      const next = code === 0xd7ff ? 0xe000 : code + 1;
      if (possible.get(ch, String.fromCodePoint(next)) !== undefined) starts.add(ch);
    }
    const changed = db.prepare("SELECT workspace FROM sessions WHERE key = ?");
    for (const { session } of dirty) {
      const row = changed.get(session) as { workspace: string } | undefined;
      if (row?.workspace) starts.add(String.fromCodePoint(row.workspace.codePointAt(0)!));
    }

    const roots = new Set<string>();
    let rootChars = 0;
    for (const line of lines) {
      const at: number[] = [];
      for (let i = 0; i < line.length; ) {
        const ch = String.fromCodePoint(line.codePointAt(i)!);
        if (starts.has(ch)) at.push(i);
        if (ch === "/") for (const start of at) {
          if (start === i) continue;
          for (const root of [line.slice(start, i), line.slice(start, i + 1)]) {
            if (!root || root === "/" || root === home || roots.has(root)) continue;
            roots.add(root);
            rootChars += root.length;
            if (roots.size > ARGUMENT_ROOTS_LIMIT || rootChars > ARGUMENT_ROOT_CHARS_LIMIT) { db.exec("COMMIT"); return null; }
          }
        }
        i += ch.length;
      }
    }
    if (roots.size === 0) { db.exec("COMMIT"); return new Map(); }
    const rows = db.prepare(SESSION_DIR_ARGUMENTS).all(JSON.stringify([...roots]), home, JSON.stringify(dirty.map((d) => d.session))) as
      { key: string; workspace: string }[];
    const result = argumentOwners(rows, lines, home);
    db.exec("COMMIT");
    return result;
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// Null means the old immediate lookup is needed. An answer and the small pending journal use one snapshot.
export function sessionDirectory(db: DatabaseSync, dir: string): DirectorySession | null {
  if (db.prepare(EXISTS).get() === undefined) return null;
  db.exec("BEGIN");
  try {
    const prepared = db.prepare("SELECT 1 FROM session_dir_meta WHERE id = 1 AND version = ? AND phase = 1").get(VERSION);
    if (prepared === undefined) { db.exec("COMMIT"); return null; }
    const dirty = db.prepare(SESSION_DIR_DIRTY).all(DIRTY_LIMIT + 1) as { session: string }[];
    if (dirty.length > DIRTY_LIMIT) { db.exec("COMMIT"); return null; }
    const roots = rootsOf(dir), wanted = new Set(roots), changed = new Map<string, string[]>();
    const read = db.prepare("SELECT workspace, cwd FROM sessions WHERE key = ?");
    for (const { session } of dirty) {
      const row = read.get(session) as { workspace: string; cwd: string | null } | undefined;
      if (row === undefined) continue;
      for (const root of new Set([row.workspace, row.cwd])) if (root && wanted.has(root))
        changed.set(root, [...(changed.get(root) ?? []), session]);
    }
    for (const live of [true, false]) {
      const candidate = db.prepare(sessionDirectoryCandidate(live));
      for (const root of roots) {
        let key = (candidate.get(root) as { key: string } | undefined)?.key;
        const updates = changed.get(root);
        if (updates !== undefined) {
          const choices = [...new Set(key === undefined ? updates : [key, ...updates])];
          key = (db.prepare(sessionDirectoryChoice(choices.length, live)).get(...choices, root, root) as { key: string } | undefined)?.key;
        }
        if (key !== undefined) { db.exec("COMMIT"); return { key, live }; }
      }
    }
    db.exec("COMMIT");
    return { key: null, live: false };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
