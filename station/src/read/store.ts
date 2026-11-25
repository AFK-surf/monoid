// The station's database as the admin API read it (once ported from the Rust station's store.rs), the store's SQL over
// the same file: what the station still reads of it here (an entry's author and a need's question, services.ts and
// sessions/conversations.ts), and what the MoonBit readers refuse with while they prepare (pool.ts). The reads it
// answered before the readers moved to the program are the tests' (test/reference/store.ts).
//
// serde's reading of a stored value is kept where it shows: a list of files or quotes that does not read is none, a
// card or identity that does not parse is none.
import { DatabaseSync } from "node:sqlite";
import { Refused } from "../api/request.ts";
import { hasRuntimeOrderIndex } from "../store/schema.ts";
import { CARD_POSTS_PENDING, cardPostsReady } from "../store/card-post-index.ts";
import { ANSWER_AFTER, CONVERSATION_CARD_LATEST, SYSTEM_CARD_AT, SYSTEM_CARD_KEPT, SYSTEM_CARD_WAITING } from "../store/card-kinds.ts";
import { legacyMergedNeedsRepair, legacyMergedReadReady } from "../store/legacy-edits-build.ts";
import { boundedEditKey as readBoundedEditKey, LAST_MESSAGE_WITH_EDIT } from "../store/legacy-edits-read.ts";
import { hasLegacySaid } from "../store/legacy-said-build.ts";
import { hasLegacyAgent } from "../store/legacy-agent-build.ts";
import { type UsageGroup } from "../store/usage.ts";
import * as rows from "../store/rows.ts";
import { type Membership, type MessageRow, type ThreadRow, cardOf, toMembership, toMessage, toThread } from "../store/rows.ts";

export type Json = any;

// The rows (camelCase) and how they are read from the database are the station's own (store/rows.ts): the readers'
// leave out what is not for the pages (a session's and a job's token).
export { STILLFAIL_SURFACE, ending, optionsCard, saidBefore } from "../store/rows.ts";
export type { AuthorKind, EntryRow, Membership, MessageRow, ThreadRow } from "../store/rows.ts";

// ---- rows ----

/// A session as the pages are given it: without its token.
export type SessionRow = Omit<rows.SessionRow, "token">;

export function toSession(r: Json): SessionRow {
  const { token: _, ...session } = rows.toSession(r);
  return session;
}

// ---- the store ----

export type Store = {
  db: DatabaseSync;
  /// The station's data directory: stillfail.db, archive/, config.json.
  dataDir: string;
  /// People's names by email, as their credentials say them (the admin API's `deps.names`, filled as members ask).
  names: Map<string, string>;
  /// What only the hub knows, as it was when the read was asked: each session's process state (`process_state`;
  /// "cold" for one not listed) and the client keys sessions were made with (`client_key`).
  processes: Map<string, string>;
  clientKeys: Map<string, string>;
  /// An old session whose up-job lookup should be prepared after this read returns.
  prepareUpJobs: string | null;
  /// An old workspace up-job lookup should be prepared after this read returns.
  prepareWorkspaceUpJobs: boolean;
  /// This connection uses the already-published lookup on an older database.
  legacySaid: boolean;
  /// This connection uses the time lookup prepared for an older database.
  legacyAgent: boolean;
};

/// The store over an open database, with the data directory its archive is in.
export function makeStore(db: DatabaseSync, dataDir: string): Store {
  return { db, dataDir, names: new Map(), processes: new Map(), clientKeys: new Map(), prepareUpJobs: null, prepareWorkspaceUpJobs: false,
    legacySaid: hasLegacySaid(db), legacyAgent: hasLegacyAgent(db) };
}

export const one = (s: Store, sql: string, ...args: Json[]): Json | undefined => s.db.prepare(sql).get(...args);
export const all = (s: Store, sql: string, ...args: Json[]): Json[] => s.db.prepare(sql).all(...args);

// ── sessions ──

export function getSession(s: Store, key: string): SessionRow | null {
  const r = one(s, "SELECT * FROM sessions WHERE key = ?", key);
  return r ? toSession(r) : null;
}

/// Before per-message runtime was recorded, every message belonged to the session's first runtime.
export const ORIGINAL_RUNTIME = "SELECT COALESCE(original_runtime, runtime) AS runtime FROM sessions WHERE key = ?";
export const ORIGINAL_RUNTIME_ORDERED = `SELECT COALESCE(s.original_runtime,
  (SELECT r.runtime FROM runtime_sessions r INDEXED BY runtime_sessions_ordered WHERE r.session_key = s.key ORDER BY r.at, r.rowid LIMIT 1),
  s.runtime) AS runtime FROM sessions s WHERE s.key = ?`;
export function originalRuntime(s: Store, key: string): string | null {
  try {
    return one(s, hasRuntimeOrderIndex(s.db) ? ORIGINAL_RUNTIME_ORDERED : ORIGINAL_RUNTIME, key)?.runtime ?? null;
  } catch {
    if (hasRuntimeOrderIndex(s.db)) {
      try {
        return one(s, "SELECT runtime FROM runtime_sessions INDEXED BY runtime_sessions_ordered WHERE session_key = ? ORDER BY at, rowid LIMIT 1", key)?.runtime
          ?? one(s, "SELECT runtime FROM sessions WHERE key = ?", key)?.runtime ?? null;
      } catch {} // a database from before per-transcript runtimes
    }
    return one(s, "SELECT runtime FROM sessions WHERE key = ?", key)?.runtime ?? null;
  }
}

// ── threads ──

export function getThread(s: Store, id: number): ThreadRow | null {
  const r = one(s, "SELECT * FROM threads WHERE id = ?", id);
  return r ? toThread(r) : null;
}

export function threadSessions(s: Store, thread: number): Membership[] {
  return all(s, "SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", thread).map(toMembership);
}

export const LAST_MESSAGE_PENDING = "last message pending: ";
export { LAST_MESSAGE_WITH_EDIT } from "../store/legacy-edits-read.ts";
export const LEGACY_EDITS_PENDING = "legacy edit lookup pending";
export class LegacyEditsUnavailable extends Refused {
  constructor() { super(503, LEGACY_EDITS_PENDING); }
}

// The caller holds the message and edit lookup in one snapshot. Without a prepared lookup, a recent edit (or a
// short chat) proves the latest edit; an old index can prove it when at most one bounded batch matches.
export function boundedEditKey(s: Store, thread: number, n: string): string | null {
  const edit = readBoundedEditKey(s.db, thread, n);
  if (edit === undefined) throw new LegacyEditsUnavailable();
  return edit;
}

export function mergedWithBoundedEdit(s: Store, thread: number, n: string): MessageRow | null {
  const r = one(s, LAST_MESSAGE_WITH_EDIT, thread, n, boundedEditKey(s, thread, n));
  return r ? toMessage(r) : null;
}
export const SAID_PENDING = "sidebar said state pending: ";
export const LEGACY_SAID_PENDING = "legacy said lookup pending";

export const PAGE_LETTER_PENDING = "page letter lookup pending: ";

/// The pending post's number for chat history. Its merged text is not needed to mark a card as pending.
export function pendingCardNumber(s: Store, thread: number): number | null {
  s.db.exec("SAVEPOINT pending_card_number_read");
  try {
    if (!cardPostsReady(s.db, thread)) {
      // An older connection can remove either old index while this thread is still being prepared. In that case
      // prepare the card-post index by bounded primary-key pages instead of probing an index that no longer exists.
      const indexed = one(s, "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'index' AND name IN ('entries_cards', 'entries_options')")?.n === 2;
      if (indexed && threadsWithCards(s, [thread]).length === 0) return null;
      throw new Refused(503, CARD_POSTS_PENDING + JSON.stringify([thread]));
    }
    // A system card waiting comes first: it is settled only where it is decided (store/card-kinds.ts).
    const system = one(s, SYSTEM_CARD_WAITING, thread);
    if (system !== undefined) return system.n;
    const asked = one(s, CONVERSATION_CARD_LATEST, thread);
    if (asked === undefined) return null;
    const post = one(s, "SELECT card, options FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", thread, asked.n);
    if (!post || cardOf(post.card, post.options) === undefined) return null;
    if (one(s, ANSWER_AFTER, thread, asked.n)) return null;
    if (one(s, "SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", thread, asked.n)) return null;
    return asked.n;
  } finally { s.db.exec("RELEASE pending_card_number_read"); }
}

/// Whether the card posted at `n` still waits (store/card-kinds.ts): a system card until it is closed; a
/// conversational one while it is the chat's latest, not closed, and no person's message after it reached its agent.
export function cardWaits(s: Store, thread: number, n: number): boolean {
  if (one(s, "SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", thread, n)) return false;
  if (one(s, SYSTEM_CARD_AT, thread, n)) return one(s, SYSTEM_CARD_KEPT, thread, n) !== undefined;
  if (!cardPostsReady(s.db, thread)) throw new Refused(503, CARD_POSTS_PENDING + JSON.stringify([thread]));
  if (one(s, CONVERSATION_CARD_LATEST, thread)?.n !== n) return false;
  return one(s, ANSWER_AFTER, thread, n) === undefined;
}

/// The latest pending card a need can point to. Its original timestamp and time never depend on edits.
export function statePendingCard(s: Store, threads: number[]): [number, number, string] | null {
  s.db.exec("SAVEPOINT state_pending_card_read");
  try {
    const cards: { thread: number; n: number; ts: string; at: number }[] = [];
    for (const thread of threads) {
      const n = pendingCardNumber(s, thread);
      if (n === null) continue;
      const row = one(s, "SELECT ts, at FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", thread, n);
      if (row) cards.push({ thread, n, ts: row.ts ?? "", at: row.at });
    }
    cards.sort((a, b) => a.at - b.at);
    const last = cards.at(-1);
    return last ? [last.thread, last.n, last.ts] : null;
  } finally { s.db.exec("RELEASE state_pending_card_read"); }
}

/// The visible question a need names, checked together with whether it is still answerable.
export type StateQuestion =
  | { kind: "missing" }
  | { kind: "invalid" }
  | { kind: "proposal" }
  | { kind: "answered" }
  | { kind: "found"; about: [number, number, string] };

export function stateQuestion(s: Store, key: string, threads: number[], ts: string): StateQuestion {
  s.db.exec("SAVEPOINT state_question_read");
  try {
    const hasProposal = one(s, "SELECT 1 AS x FROM pragma_table_info('entries') WHERE name = 'proposal' LIMIT 1") !== undefined;
    const hasSidecar = one(s, "SELECT 1 AS x FROM sqlite_master WHERE type = 'table' AND name = 'entry_proposals' LIMIT 1") !== undefined;
    const sql = hasProposal && hasSidecar
      ? "SELECT e.n, e.card, e.options, COALESCE(e.proposal, ep.proposal) AS proposal FROM entries e LEFT JOIN entry_proposals ep ON ep.thread = e.thread AND ep.n = e.n WHERE e.thread = ? AND e.ts = ? AND e.kind = 'message'"
      : hasProposal
        ? "SELECT n, card, options, proposal FROM entries WHERE thread = ? AND ts = ? AND kind = 'message'"
        : hasSidecar
          ? "SELECT e.n, e.card, e.options, ep.proposal AS proposal FROM entries e LEFT JOIN entry_proposals ep ON ep.thread = e.thread AND ep.n = e.n WHERE e.thread = ? AND e.ts = ? AND e.kind = 'message'"
          : "SELECT n, card, options FROM entries WHERE thread = ? AND ts = ? AND kind = 'message'";
    for (const thread of threads) {
      const entry = one(s, sql, thread, ts);
      if (!entry) continue;
      // A missing native index must be replaced even if the recent tail could answer this one question: confirmation
      // after unrelated concurrent writes also needs a bounded lookup.
      if (legacyMergedNeedsRepair(s.db)) throw new LegacyEditsUnavailable();
      if ((hasProposal || hasSidecar) && entry.proposal != null) return { kind: "proposal" };
      let m: MessageRow | null;
      if (legacyMergedReadReady(s.db)) {
        const row = one(s, "SELECT * FROM merged WHERE thread = ? AND n = ?", thread, entry.n);
        m = row ? toMessage(row) : null;
      } else m = mergedWithBoundedEdit(s, thread, String(entry.n));
      if (!m) continue;
      if (m.authorKind !== "agent" || m.author !== key || m.text.trim() === "") return { kind: "invalid" };
      const carded = entry.card != null || entry.options != null;
      const answered = carded ? !cardWaits(s, thread, m.n) : one(s, ANSWER_AFTER, thread, m.n) !== undefined;
      return answered ? { kind: "answered" } : { kind: "found", about: [m.thread, m.n, m.ts] };
    }
    return { kind: "missing" };
  } finally { s.db.exec("RELEASE state_question_read"); }
}

/// Of `threads`, those that ever had a card or options posted, each by their own indexes.
export function threadsWithCards(s: Store, threads: number[]): number[] {
  return threads.filter((t) =>
    one(s, "SELECT 1 FROM entries INDEXED BY entries_cards WHERE thread = ? AND card IS NOT NULL LIMIT 1", t) !== undefined ||
    one(s, "SELECT 1 FROM entries INDEXED BY entries_options WHERE thread = ? AND options IS NOT NULL LIMIT 1", t) !== undefined);
}
export const TURN_COUNT_PENDING = "turn count pending: ";

// ── usage (store/usage.rs) ──

/// The calls of one day for one thread, person, profile and model, added up (store/usage.ts).
export type { UsageGroup };

export const USAGE_CHATS_PENDING = "usage chat statistics are still being filled";

export const REMOTE_RUNS_PENDING = "remote task statistics are still being filled";
