// Minimal SQLite writer for the move drill's offline database helpers (e2e/move-{live,seed,stale}.ts).
// Opens an existing station database (`stillfail.db`) using Node's built-in `node:sqlite`, matching the schema and
// write semantics of `Store` without importing station runtime code.
import { DatabaseSync } from "node:sqlite";

const STILLFAIL_SURFACE = "chat";
const FORMER_OWN_NAMES: readonly string[] = ["ember", "stillfail"];
const ownName = (name: string): string => (FORMER_OWN_NAMES.includes(name) ? STILLFAIL_SURFACE : name);

const flag = (v: boolean): number => (v ? 1 : 0);
const optFlag = (v: boolean | null | undefined): number | null => (v === undefined || v === null ? null : flag(v));

const THREAD_INSERT_IF_ABSENT = `INSERT OR IGNORE INTO threads (surface, channel, thread_ts, title, created_by, created_at, home)
  SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7 WHERE NOT EXISTS
    (SELECT 1 FROM threads WHERE surface = ?1 AND channel = ?2 AND thread_ts = ?3)`;

const MEMBER_JOIN_IF_NEEDED = `INSERT INTO thread_sessions (thread, session, connect, joined_at)
  SELECT ?1, ?2, ?3, ?4 WHERE NOT EXISTS
    (SELECT 1 FROM thread_sessions WHERE thread = ?1 AND session = ?2 AND left_at IS NULL)
  ON CONFLICT (thread, session) DO UPDATE SET left_at = NULL WHERE thread_sessions.left_at IS NOT NULL`;

export type MoveSession = {
  key: string;
  connect: string;
  scope?: string;
  title?: string | null;
  createdBy?: string | null;
  runtime: string;
  profile: string;
  profilePinned?: boolean;
  profiles?: string[] | null;
  model?: string | null;
  effort?: string | null;
  workspace: string;
  cwd?: string | null;
  runtimeSessionId?: string | null;
  token: string;
  createdAt: number;
  lastActiveAt: number;
  fast?: boolean | null;
  ws?: string | null;
  context?: number | null;
  speed?: string | null;
  tui?: boolean;
};

export type MoveMessage = {
  thread: number;
  ts: string | null;
  authorKind: "person" | "agent" | "station";
  author: string;
  text: string | null;
  at?: number;
};

export type MoveDb = {
  db: DatabaseSync;
  insertSession(s: MoveSession): void;
  openThread(surface: string, channel: string, threadTs: string, title: string | null, createdBy: string | null): { id: number };
  joinThread(thread: number, session: string, connect: string): boolean;
  insertMessage(m: MoveMessage): [number, boolean];
  close(): void;
};

export function openMoveDb(path: string): MoveDb {
  const db = new DatabaseSync(path, { timeout: 5000 });
  db.exec("PRAGMA busy_timeout = 5000;");

  const insertSessionStmt = db.prepare(
    `INSERT INTO sessions (key, connect, scope, title, created_by, runtime, profile, profile_pinned, profiles, model, effort, workspace, cwd, runtime_session_id, token, created_at, last_active_at, told_notes, fast, ws, context, speed, tui)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  const maxToldNotesStmt = db.prepare("SELECT MAX(told_notes) AS n FROM sessions");
  const openThreadStmt = db.prepare(THREAD_INSERT_IF_ABSENT);
  const threadAtStmt = db.prepare("SELECT id FROM threads WHERE surface = ? AND channel = ? AND thread_ts = ?");
  const joinThreadStmt = db.prepare(MEMBER_JOIN_IF_NEEDED);
  const messageAtTsStmt = db.prepare("SELECT n FROM entries WHERE thread = ? AND ts = ? AND kind = 'message' LIMIT 1");
  const maxEntryNStmt = db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?");
  const lastKnownNStmt = db.prepare(
    "SELECT MAX(n) AS n FROM (SELECT MAX(n) AS n FROM reads WHERE thread = ?1 UNION ALL SELECT MAX(n) AS n FROM deliveries WHERE thread = ?1)",
  );
  const insertEntryStmt = db.prepare(
    `INSERT INTO entries (thread, n, kind, target, ts, author_kind, author, text, attachments, quotes, declared, client, profile, runtime, options, card, at, agent_identity, letter, change)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );

  return {
    db,

    insertSession(s: MoveSession): void {
      const connect = ownName(s.connect);
      const list = s.profiles !== undefined
        ? (s.profiles && s.profiles.length > 0 ? s.profiles : null)
        : (s.profilePinned ? [s.profile] : null);
      const pinned = list !== null ? list.length === 1 : (s.profilePinned ?? false);
      const toldNotesRow = maxToldNotesStmt.get() as { n: number | null } | undefined;
      const toldNotes = toldNotesRow?.n ?? 0;
      insertSessionStmt.run(
        s.key,
        connect,
        s.scope ?? "thread",
        s.title ?? null,
        s.createdBy ?? null,
        s.runtime,
        s.profile,
        flag(pinned),
        list !== null ? JSON.stringify(list) : null,
        s.model ?? null,
        s.effort ?? null,
        s.workspace,
        s.cwd ?? null,
        s.runtimeSessionId ?? null,
        s.token,
        s.createdAt,
        s.lastActiveAt,
        toldNotes,
        optFlag(s.fast),
        s.ws ?? null,
        s.context ?? null,
        s.speed ?? null,
        flag(s.tui === true),
      );
    },

    openThread(surface: string, channel: string, threadTs: string, title: string | null, createdBy: string | null): { id: number } {
      const norm = ownName(surface);
      openThreadStmt.run(norm, channel, threadTs, title, createdBy, Date.now(), null);
      const row = threadAtStmt.get(norm, channel, threadTs) as { id: number } | undefined;
      if (row === undefined) throw new Error(`thread ${norm} ${channel}/${threadTs} not made`);
      return { id: Number(row.id) };
    },

    joinThread(thread: number, session: string, connect: string): boolean {
      const res = joinThreadStmt.run(thread, session, ownName(connect), Date.now());
      return Number(res.changes) > 0;
    },

    insertMessage(m: MoveMessage): [number, boolean] {
      if (m.ts !== null) {
        const existing = messageAtTsStmt.get(m.thread, m.ts) as { n: number } | undefined;
        if (existing !== undefined) return [Number(existing.n), false];
      }
      db.exec("BEGIN IMMEDIATE");
      try {
        const maxRow = maxEntryNStmt.get(m.thread) as { n: number | null } | undefined;
        let base = maxRow?.n ?? null;
        if (base === null) {
          const knownRow = lastKnownNStmt.get(m.thread) as { n: number | null } | undefined;
          base = knownRow?.n ?? 0;
        }
        const n = Number(base) + 1;
        insertEntryStmt.run(
          m.thread,
          n,
          "message",
          null,
          m.ts,
          m.authorKind,
          m.author,
          m.text,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          m.at ?? Date.now(),
          null,
          null,
          null,
        );
        db.exec("COMMIT");
        return [n, true];
      } catch (err) {
        db.exec("ROLLBACK");
        throw err;
      }
    },

    close(): void {
      db.close();
    },
  };
}
