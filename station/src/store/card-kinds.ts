// The two kinds of card a chat waits on (2026-11-16, the status refactor):
// - a system card (a login, a vault's secret, a phone, a rig, a sign-in) is settled only where it is decided: its
//   outcome or its withdrawal closes it (closed_cards). A person's message never does: 「稍等我拿手机」 in a Slack
//   thread must not take the code field of a login away. Several may wait at once in one chat (pending_system_cards).
// - a conversational card (options, a text field) is settled as a person's message reaches its agent: any person's
//   message in a still.fail chat, and in a platform's thread (Slack, Feishu, a group) only one handed to a session
//   (its deliveries), so a colleague's word to someone else there, not mentioning the bot, leaves it waiting. A newer
//   conversational card replaces it; a system card does not, nor does it replace a system card.
// What reads a card (the station's store, its reads in station/mb and the reads they are held to in test/reference)
// goes by these, one text each.

import { STILLFAIL_SURFACE } from "./rows.ts";

/// Whether a card is a system card, by the JSON of an entry's `card` column (`col`, SQL).
/// (never NULL: a field a card has not makes its test NULL, and NOT of NULL holds for no row; a column that is not JSON
/// is no system card, never read as JSON: CASE, as AND is not sure to stop SQLite short)
export const systemCardSql = (col: string): string =>
  `(CASE WHEN ${col} IS NULL OR NOT json_valid(${col}) THEN 0 ELSE COALESCE(json_extract(${col}, '$.type') = 'login'` +
  ` OR json_type(${col}, '$.vault') = 'object' OR json_type(${col}, '$.adb') = 'object'` +
  ` OR json_type(${col}, '$.rig') = 'object' OR json_type(${col}, '$.signin') = 'object', 0) END)`;

const isObject = (v: unknown): boolean => v !== null && typeof v === "object" && !Array.isArray(v);

/// The same of a card read (rows.ts `cardOf`).
export function isSystemCard(card: unknown): boolean {
  if (!isObject(card)) return false;
  const c = card as Record<string, unknown>;
  return c.type === "login" || isObject(c.vault) || isObject(c.adb) || isObject(c.rig) || isObject(c.signin);
}

/// Whether the person's message at `n` (SQL) of thread `thread` (SQL) reached an agent: in a still.fail chat any, in a
/// platform's thread one handed to a session.
export const reachedSql = (thread: string, n: string): string =>
  `((SELECT surface FROM threads WHERE id = ${thread}) = '${STILLFAIL_SURFACE}' OR EXISTS (SELECT 1 FROM deliveries d WHERE d.thread = ${thread} AND d.n = ${n}))`;

/// A person's message of thread ?1 after ?2 that reached an agent: what settles a conversational card posted at ?2.
export const ANSWER_AFTER = `SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.kind = 'message' AND p.author_kind = 'person'
  AND p.n > ?2 AND ${reachedSql("?1", "p.n")} LIMIT 1`;

/// The same between ?2 and ?3, both left out.
export const ANSWER_BETWEEN = `SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.kind = 'message' AND p.author_kind = 'person'
  AND p.n > ?2 AND p.n < ?3 AND ${reachedSql("?1", "p.n")} LIMIT 1`;

/// Whether the message at ?2 of thread ?1 is a person's that reached an agent.
export const ANSWER_AT = `SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.n = ?2 AND p.kind = 'message' AND p.author_kind = 'person'
  AND ${reachedSql("?1", "?2")}`;

/// Thread ?1's latest conversational card posted before ?2 (by the card posts' index; a system card passed over).
export const CONVERSATION_CARD_BEFORE = `SELECT c.n AS n FROM card_posts c JOIN entries e ON e.thread = c.thread AND e.n = c.n
  WHERE c.thread = ?1 AND c.n < ?2 AND NOT ${systemCardSql("e.card")} ORDER BY c.n DESC LIMIT 1`;

/// Thread ?1's latest conversational card.
export const CONVERSATION_CARD_LATEST = `SELECT c.n AS n FROM card_posts c JOIN entries e ON e.thread = c.thread AND e.n = c.n
  WHERE c.thread = ?1 AND NOT ${systemCardSql("e.card")} ORDER BY c.n DESC LIMIT 1`;

/// Thread ?1's latest system card still waiting (none closed: pending_system_cards).
export const SYSTEM_CARD_WAITING = `SELECT s.n AS n FROM pending_system_cards s WHERE s.thread = ?1
  AND NOT EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = s.thread AND c.n = s.n) ORDER BY s.n DESC LIMIT 1`;

/// Thread ?1's system cards still waiting, the latest first: what a chat asks besides the one its row shows, each of its
/// own person (a viewer's marks show the one asked of them first: read/views chatMarks).
export const SYSTEM_CARDS_WAITING = `SELECT s.n AS n FROM pending_system_cards s WHERE s.thread = ?1
  AND NOT EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = s.thread AND c.n = s.n) ORDER BY s.n DESC LIMIT 16`;

/// Whether the post at ?2 of thread ?1 is a system card.
export const SYSTEM_CARD_AT = `SELECT 1 AS x FROM entries e WHERE e.thread = ?1 AND e.n = ?2 AND e.kind = 'message' AND ${systemCardSql("e.card")}`;

/// Whether the system card at ?2 of thread ?1 still waits.
export const SYSTEM_CARD_KEPT = "SELECT 1 AS x FROM pending_system_cards WHERE thread = ?1 AND n = ?2";

/// An agent's latest message in thread ?1 up to ?2 (ms), by the index of agents' messages by time (schema.ts
/// entries_agent_at): what a need with no message in its turn asks with (`askingMessage`), the question asked before
/// and not answered since (a turn that woke for its background work and needs the same, 2026-11-16).
export const ASKED_LATEST = "SELECT n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND at <= ? ORDER BY at DESC LIMIT 1";
/// Same as ASKED_DURING / ASKED_LATEST / carded check, excluding inline & sidecar (`entry_proposals`) project proposals (non-blocking).
export const ASKED_DURING_NO_PROPOSAL = "SELECT max(n) AS n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND proposal IS NULL AND NOT EXISTS (SELECT 1 FROM entry_proposals ep WHERE ep.thread = entries.thread AND ep.n = entries.n) AND at >= ? AND at <= ?";
export const ASKED_LATEST_NO_PROPOSAL = "SELECT n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND proposal IS NULL AND NOT EXISTS (SELECT 1 FROM entry_proposals ep WHERE ep.thread = entries.thread AND ep.n = entries.n) AND at <= ? ORDER BY at DESC LIMIT 1";
export const CARDED_OR_PROPOSAL_AT = "SELECT 1 FROM entries WHERE thread = ? AND n = ? AND (card IS NOT NULL OR options IS NOT NULL OR proposal IS NOT NULL OR EXISTS (SELECT 1 FROM entry_proposals ep WHERE ep.thread = entries.thread AND ep.n = entries.n))";

/// The person whose message came last before ?2 in thread ?1 (the partial index of people's messages): whom an agent's
/// need with no card asks, the person it was answering (a need's `decider`, read/views; the station's notice of it).
/// Their address where it is one (a still.fail chat's), else a platform's id the core takes as no one in particular.
export const ASKER_BEFORE = `SELECT author FROM entries INDEXED BY entries_people_by_n WHERE thread = ?1 AND n < ?2
  AND author_kind = 'person' AND kind = 'message' ORDER BY n DESC LIMIT 1`;

/// Whether session ?1 waits on work it started that is not a watch (a list row's agent's `waitingAsync`, read/views):
/// a background job running (by the running jobs, few), or a chat it leads (chat_create for me) not archived and not
/// ended done or stopped (opened_chats_by_key).
export const WAITS_ON_JOB = "SELECT 1 AS x FROM jobs INDEXED BY jobs_state WHERE state = 'running' AND session_key = ?1 AND watch = 0 LIMIT 1";
export const WAITS_ON_LED = `SELECT 1 AS x FROM opened_chats o LEFT JOIN sessions c ON o.child_station = '' AND c.key = o.child
  WHERE o.parent_station = '' AND o.parent = ?1 AND o.led = 1 AND c.archived_at IS NULL
  AND (o.state IS NULL OR o.state NOT IN ('all_done', 'stopped')) LIMIT 1`;
