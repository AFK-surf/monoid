import type { ModelSpeed } from "../../../client/core-ts/src/model-speed.ts";
// The store's rows (the Rust station's store.rs `// ── rows`), camelCase, and how they are read from and written to the database.
// Option is `T | null`; where the Rust leaves a None Value out (EntryRow's agentIdentity, options, card) it is undefined.
// The readers (read/store.ts) read rows with these same conversions, leaving out what is not for the pages (tokens).

import type { SandboxPlace } from "../agents/sandbox.ts";
import { LEGACY_SAID_LATEST } from "./legacy-said-build.ts";

export type Json = any;

/// The page's own threads live on this surface, as the clients have read it since #4101.
export const STILLFAIL_SURFACE = "chat";
/// The connect the page's own threads' sessions are in (sessions/internal.ts INTERNAL_CONNECT).
export const STILLFAIL_CONNECT = "chat";
/// What stations wrote for both before the rename: a database is written over once as it opens (schema.ts
/// `renameOwnChats`), and only what comes from elsewhere (a copy, another station's hand-over) is read in these names.
export const FORMER_OWN_NAMES: readonly string[] = ["ember", "stillfail"];
/// A surface or connect as it is written now: the station's own chats' names of before are its name now
/// (STILLFAIL_SURFACE and STILLFAIL_CONNECT are one name), anything else as it is.
export const ownName = (name: string): string => (FORMER_OWN_NAMES.includes(name) ? STILLFAIL_SURFACE : name);
/// What a chat handed to another station one at a time (replica/handover.ts) says its workspace is here once it went
/// (store `handOff`), out of every device's sight here; and what one coming here says until it is shown (`comingWs`).
export const handedWs = (ws: string) => `handed:${ws}`;
export const comingWs = (ws: string) => `coming:${ws}`;
/// A chat handed from here to another station (store `handOff`): where it went, the workspace it was of here (null:
/// the home one), its thread here and there, when.
export type HandedChat = { session: string; station: string; ws: string | null; thread: number | null; there: number | null; at: number };
/// Archived by a person.
export const MANUAL = "manual";
/// Archived by the station, for idling (or brought back by something said).
export const AUTO = "auto";
/// SQLite's and Rust's i64::MAX, for "no bound".
export const I64_MAX = 9223372036854775807n;


/// Where a Slack connect's threads live: its team, or the connect itself while the team is unknown.
export function slackSurface(connect: string, teamId: string | null): string {
  return teamId ? `slack:${teamId}` : `slack:${connect}`;
}

/// Where a Feishu connect's threads live: the connect's own.
export const feishuSurface = (connect: string): string => `feishu:${connect}`;

/// Where a Comma connect's threads (its Comma Tasks) live: the connect's own.
export const commaSurface = (connect: string): string => `comma:${connect}`;

/// Where a group connect's threads (its IM server's conversations) live: the connect's own (its people's ids are the
/// server's).
export const groupSurface = (connect: string): string => `group:${connect}`;

export type SessionScope = "thread" | "all";

/// Who looks, as far as the station's workspaces go: their workspace, and whether it is the
/// station's home one (absent: it is, as on a station in one workspace).
export type InWorkspace = { workspace: string; home?: boolean };

/// Whether a session whose chat is in `ws` (null: the station's home workspace) is one `viewer` may see and use: a
/// member of one workspace sees nothing of another's chats.
export const sees = (viewer: InWorkspace, ws: string | null): boolean => ws === viewer.workspace || (ws === null && viewer.home !== false);

/// The workspace a task another station sent here runs for, by its job's session key
/// (`remote:<workspace>:<station>:<session>`: jobs/remote.ts, client/core-ts jobs.ts `remoteOwner`); null for any other
/// key. No session here has such a key.
export const remoteWs = (key: string): string | null => /^remote:([^:/]+):[^:/]+:.+$/.exec(key)?.[1] ?? null;

/// Whether `viewer` sees what names a session not here (`sessionWs` undefined): another station's task its
/// workspace's, whichever this station's home is; anything else the home workspace's.
export const seesMissing = (viewer: InWorkspace, key: string): boolean => {
  const ws = remoteWs(key);
  return ws !== null ? ws === viewer.workspace : sees(viewer, null);
};

export type SessionRow = {
  /// The station it was handed here from (replica/handover.ts; absent: it began here, or came back to where it began).
  from?: string;
  /// The conversation anchor session key when grouped (`sessions.conv`; absent when NULL).
  conv?: string;
  key: string; connect: string; scope: SessionScope; title: string | null; createdBy: string | null; runtime: string;
  profile: string; profilePinned: boolean; profiles?: string[] | null; model: string | null; effort: string | null; fast: boolean | null; speed?: ModelSpeed | null; tui?: boolean;
  /// Whether it goes on afresh once its prompt cache is over, as chosen in its chat (null: as its station is set,
  /// `afreshWhenCold`).
  afresh: boolean | null;
  /// The most context it runs with, in tokens: its runtime compacts at it (null: the model's whole window).
  context: number | null;
  /// The most it ran with while what it holds is over `context`, lowered meanwhile, until compacted (0: the model's
  /// whole window; null: none over).
  contextBefore: number | null;
  /// Times its runtime session compacted its context (on its own or by hand), counted afresh with each runtime session
  /// (none: never yet).
  compactions?: number;
  runtimeSessionId: string | null; workspace: string; cwd: string | null;
  /// Which of the station's workspaces its chat is in: null is its home workspace (sessions
  /// from before, and those made outside any workspace's request). Not the `workspace` above, its directory.
  ws: string | null;
  /// Not for the pages (serde skip).
  token: string;
  running: boolean; createdAt: number; lastActiveAt: number; archivedAt: number | null; archivedBy: string | null;
  shownAt: number | null;
};

/// A session as it is first recorded (what NewSession::default leaves out may be left out).
export type NewSession = {
  key: string; connect: string; scope?: SessionScope | null; title?: string | null; createdBy?: string | null; createdBySub?: string | null;
  runtime: string; profile: string; profilePinned?: boolean; profiles?: string[] | null; model?: string | null; effort?: string | null;
  fast?: boolean | null; speed?: ModelSpeed | null; tui?: boolean; context?: number | null; workspace: string; cwd?: string | null; runtimeSessionId?: string | null; token: string;
  createdAt: number; lastActiveAt: number; ws?: string | null;
};

/// External links stored on a thread (e.g. a Comma Task's web page and app deep link).
export type ThreadLinks = { web?: string; app?: string };

/// Status of an inline project-creation proposal attached to an agent message (`entries.proposal`).
export type ProjectProposalStatus = "pending" | "accepted" | "reassigned" | "dismissed";

/// Lightweight project-creation proposal carried on a normal message entry (never `entries.card`).
export type ProjectProposal = {
  id: string;
  name: string;
  note?: string;
  refs?: string[];
  proposer?: string;
  status: ProjectProposalStatus;
  resolvedProject?: string;
  resolvedBy?: string;
  resolvedAt?: number;
};

/// Maximum number of tags on a thread.
export const MAX_THREAD_TAGS = 3;
/// Maximum length of a project name or a single tag (characters).
export const MAX_PROJECT_NAME = 80;
export const MAX_TAG_LENGTH = 48;

const FORBIDDEN_LABEL_CHAR = /[\x00-\x1f\x7f,]/;

/// Normalizes a project name: trims whitespace, preserves "" (explicit cross-project), rejects control chars, commas, and overlong values.
export function normalizeProject(raw: string): string {
  const s = raw.trim();
  if (s.length > MAX_PROJECT_NAME) throw new Error(`project name must be at most ${MAX_PROJECT_NAME} characters`);
  if (FORBIDDEN_LABEL_CHAR.test(s)) throw new Error("project name must not contain control characters or commas");
  return s;
}

/// Normalizes a list of tags: trims, drops empty strings, deduplicates preserving first occurrence, caps at MAX_THREAD_TAGS.
/// When `strict` is true, rejects non-strings, overlong tags, forbidden characters, and more than MAX_THREAD_TAGS unique tags.
export function normalizeTags(raw: readonly unknown[], strict = false): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (typeof item !== "string") {
      if (strict) throw new Error("tags must be strings");
      continue;
    }
    const t = item.trim();
    if (t === "") continue;
    if (t.length > MAX_TAG_LENGTH) {
      if (strict) throw new Error(`tag must be at most ${MAX_TAG_LENGTH} characters: ${t}`);
      continue;
    }
    if (FORBIDDEN_LABEL_CHAR.test(t)) {
      if (strict) throw new Error(`tag must not contain control characters or commas: ${t}`);
      continue;
    }
    if (seen.has(t)) continue;
    if (out.length >= MAX_THREAD_TAGS) {
      if (strict) throw new Error(`at most ${MAX_THREAD_TAGS} tags are allowed`);
      break;
    }
    seen.add(t);
    out.push(t);
  }
  return out;
}

/// Parses a stored `threads.tags` JSON column into a normalized list (undefined when empty/invalid).
export function parseThreadTags(raw: unknown): string[] | undefined {
  const v = typeof raw === "string" ? parsed(raw) : raw;
  if (!Array.isArray(v)) return undefined;
  const tags = normalizeTags(v, false);
  return tags.length > 0 ? tags : undefined;
}

/// Parses an entry's `proposal` JSON column into a validated ProjectProposal (undefined when absent/invalid).
export function proposalOf(v: unknown): ProjectProposal | undefined {
  const p = typeof v === "string" ? parsed(v) : v;
  if (p === null || p === undefined || typeof p !== "object" || Array.isArray(p)) return undefined;
  if (typeof p.id !== "string" || p.id === "" || typeof p.name !== "string" || p.name === "") return undefined;
  if (p.status !== "pending" && p.status !== "accepted" && p.status !== "reassigned" && p.status !== "dismissed") return undefined;
  const out: ProjectProposal = { id: p.id, name: p.name, status: p.status };
  if (typeof p.note === "string" && p.note !== "") out.note = p.note;
  if (Array.isArray(p.refs)) {
    const refs = p.refs.filter((r: unknown): r is string => typeof r === "string" && r.trim() !== "").map((r: string) => r.trim());
    if (refs.length > 0) out.refs = refs;
  }
  if (typeof p.resolvedProject === "string") out.resolvedProject = p.resolvedProject;
  if (typeof p.proposer === "string" && p.proposer !== "") out.proposer = p.proposer;
  if (typeof p.resolvedBy === "string" && p.resolvedBy !== "") out.resolvedBy = p.resolvedBy;
  if (typeof p.resolvedAt === "number" && Number.isFinite(p.resolvedAt)) out.resolvedAt = p.resolvedAt;
  return out;
}

/// Overlays a `proposal_outcomes` row onto an entry's immutable `proposal` payload.
export function mergeProposalOutcome(
  p: ProjectProposal,
  outcome: { status?: unknown; project?: unknown; resolved_by?: unknown; resolved_at?: unknown } | null | undefined,
): ProjectProposal {
  if (!outcome) return p;
  const st = outcome.status;
  if (st !== "accepted" && st !== "reassigned" && st !== "dismissed") return p;
  const out: ProjectProposal = {
    id: p.id,
    name: p.name,
    ...(p.note !== undefined ? { note: p.note } : {}),
    ...(p.refs !== undefined ? { refs: p.refs } : {}),
    ...(p.proposer !== undefined ? { proposer: p.proposer } : {}),
    status: st,
  };
  if (typeof outcome.project === "string") out.resolvedProject = outcome.project;
  if (typeof outcome.resolved_by === "string" && outcome.resolved_by !== "") out.resolvedBy = outcome.resolved_by;
  if (typeof outcome.resolved_at === "number" && Number.isFinite(outcome.resolved_at)) out.resolvedAt = outcome.resolved_at;
  return out;
}

/// A place people talk: a Slack thread, or a chat on the station's page.
export type ThreadRow = {
  id: number; surface: string; channel: string; threadTs: string; title: string | null; autoTitle: string | null;
  createdBy: string | null; createdAt: number; home: string | null; hiddenAt: number | null; hiddenBy: string | null;
  shownAt: number | null; links?: ThreadLinks | null;
  /// Absent when unclassified (NULL); "" when explicitly cross-project/misc; project name otherwise.
  project?: string;
  /// True when a human explicitly set or confirmed the project (agents must not overwrite).
  projectLocked?: boolean;
  /// Up to 3 short tags (omitted when empty).
  tags?: string[];
};

/// The name a chat's agent gave it (Store::autoTitle).
export type AutoTitle = { title: string | null; n: number; changes: number };

/// A thread of a session, with the connect the session posts there through.
export type SessionThread = { thread: ThreadRow; connect: string };

/// A session in a thread, and the connect it posts there through.
/// `leftAt`: when the session left the thread (chat_leave): it is still a member (reads it, posts there), but hears
/// nothing there until someone mentions it again. Absent where it is not read (chat lists).
export type Membership = { thread: number; session: string; connect: string; joinedAt: number; leftAt?: number | null };

/// The station itself as a message's author: its kind and its name, stored and sent to the clients (who have read it so
/// since #4101). An author kind is never a person's name: a person is of kind "person" whatever they are called.
export const STATION_AUTHOR = "station";
export type AuthorKind = "person" | "agent" | typeof STATION_AUTHOR;
export type EntryKind = "message" | "edit";

export type Quote = { author: string; text: string; comment: string; ts?: string; role?: string; file?: string };
/// `width`, `height`: a picture's or a film's size as shown; `duration` (ms) and `frames`: a film's length and how many
/// frames its picture has (sessions/image-size.ts shownFactsSoon), so a page says them before it reads the film.
export type Attachment = { name: string; path: string; size: number; width?: number; height?: number; thumbhash?: string; duration?: number; frames?: number };

/// One entry of a thread's log (as the archive files hold them, one per line).
export type EntryRow = {
  agentIdentity: Json | undefined; thread: number; n: number; kind: EntryKind; target: number | null; ts: string | null;
  authorKind: AuthorKind; author: string; text: string | null; attachments: Attachment[]; quotes: Quote[];
  declared: string | null; client: string | null; profile: string | null; runtime: string | null; options: Json | undefined; card: Json | undefined;
  at: number;
  /// A letter's (isLetter): which way it went and the other chat. Absent on every other entry.
  letter?: Letter;
  /// The station's notice that a session's run changed (sessions/lifecycle.ts `configure`): how it ran before and how it
  /// runs from its next turn on. Absent on every other entry.
  change?: RunChange;
  /// Inline project-creation proposal (entries.proposal): never triggers pending_cards. Absent on every other entry.
  proposal?: ProjectProposal;
};

/// How a session runs, as a notice of its change says it: its runtime, model, effort, speed, account (`profile`, its
/// `account` name; `pinned`: kept to it, else the station's pick) and most context (null: as the runtime has it).
export type RunShown = {
  runtime: string; model: string | null; effort: string | null; fast: boolean | null; speed?: ModelSpeed | null; tui?: boolean; profile: string | null; account: string | null;
  pinned: boolean; context: number | null;
};

/// A session's run before a change and after it (EntryRow `change`).
export type RunChange = { was: RunShown; now: RunShown };

/// What two chats' agents wrote each other (session_send), kept apart from what is said in a chat: `in`, another chat's
/// agent wrote this one (delivered to its agents); `out`, this chat's agent wrote another (`author`, delivered to none
/// here). `title` and `link` name the other chat.
export type Letter = { way: "in" | "out"; title: string; link: string | null };

/// A message as it reads now: its latest edit's words, files and quotes.
export type MessageRow = {
  agentIdentity: Json | null; thread: number; n: number; ts: string; authorKind: AuthorKind; author: string; text: string;
  attachments: Attachment[]; quotes: Quote[]; declared: string | null; client: string | null; createdAt: number;
  editedAt: number | null; letter?: Letter;
  /// Kept in the letters' own log (schema.ts LETTERS), numbered there, not an entry of its thread.
  apart?: true;
};

/// What delivery tells an agent about a card ended by a person's message.
export type DeliveryCardState = {
  ended: Pick<MessageRow, "author" | "ts">; card: Json; current: Pick<MessageRow, "ts"> | null;
};

/// What a person chose on a card with an option that closes it, which sent no message (store.ts closeCard): the card's
/// post (`thread`, `n`, its `ts`; `where`: the thread's channel and thread ts, `question`: its words, each while still
/// there), who chose (`by`), the option's label and when.
export type CardChoice = { thread: number; n: number; ts: string | null; where: [string, string] | null; question: string | null; by: string; option: string; at: number };

/// A card someone answered (`answersSince`).
export type CardAnswer = { question: MessageRow; card: Json; by: string; at: number; answer: MessageRow | null };

/// A message a session has yet to read, with where it was said and how the session hears that thread.
export type PendingMessage = { message: MessageRow; surface: string; channel: string; threadTs: string; connect: string };

/// A message a session was handed, by where it is kept: a thread's entry, or a letter of its own log (`apart`,
/// schema.ts LETTERS), each numbered in its own.
export type Handed = { thread: number; n: number; apart: boolean };

/// What a pending message is, to mark it read or not.
export const handedOf = (m: { message: MessageRow }): Handed => ({ thread: m.message.thread, n: m.message.n, apart: m.message.apart === true });

/// A thread for listings: who takes part, the last thing said, and how much the viewer has not read.
/// Whether a message is a letter (Letter): marked so when it was recorded; one from before letters were marked, by
/// another chat's agent (not of the thread's `keys`) headed as sessions/messages.ts heads them (`来自 …：`, `From …:`),
/// is one coming in. Lists, unread counts and the chat's page leave letters out, so that what agents write to each other
/// does not bury what people say; the page shows them apart (core views.ts).
export function isLetter(m: { authorKind: string; author: string; text: string; letter?: Letter }, keys: ReadonlySet<string>): boolean {
  if (m.letter !== undefined) return true;
  return m.authorKind === "agent" && !keys.has(m.author) && (m.text.startsWith("来自 ") || m.text.startsWith("From "));
}

/// isLetter in SQL, of an entry or merged row (marked when recorded, or on opening for those from before: schema.ts
/// addLetterColumn).
export const LETTER_SQL = "(letter IS NOT NULL)";

/// The Slack and Feishu threads a still.fail chat can copy what people send to when they ask (`cc`
/// "抄送"): every one its agents are in, the one said in last first, at most 20; with a connect that posts there. One
/// `?`: the chat's thread id. When each was said in last is its last entry's time (schema.ts thread_state): as the
/// latest of all its entries, each thread's every entry was read, at each telling of the chat.
export const CC_THREADS_SQL = `SELECT t.*, o.connect FROM thread_sessions m
  JOIN thread_sessions o ON o.session = m.session JOIN threads t ON t.id = o.thread
  WHERE m.thread = ? AND t.surface != '${STILLFAIL_SURFACE}'
  GROUP BY t.id
  ORDER BY (SELECT e.at FROM thread_state st JOIN entries e ON e.thread = st.thread AND e.n = st.last_n WHERE st.thread = t.id) DESC, t.created_at DESC, t.id DESC
  LIMIT 20`;

/// The letter an entry's `letter` column (or an archive file's entry) holds (absent: none, or one not read).
export function letterOf(v: unknown): Letter | undefined {
  const l = typeof v === "string" ? parsed(v) : v;
  if (l === null || l === undefined || typeof l !== "object") return undefined;
  const way = l.way === "in" || l.way === "out" ? l.way : null;
  if (way === null || typeof l.title !== "string") return undefined;
  return { way, title: l.title, link: typeof l.link === "string" ? l.link : null };
}

export type ThreadSummary = {
  thread: ThreadRow; sessions: Membership[]; last: number; lastMessage: MessageRow | null; read: number; unread: number;
  people: string[]; firstText: string | null;
  /// How many letters it has (Letter), in either way.
  letters: number;
  /// Its own log of letters' last (schema.ts LETTERS; 0: none).
  lettersLast: number;
};

/// The message a turn's state is about: its thread, entry (`seq`) and ts.
export type TurnAbout = { thread: number; seq: number; ts: string };

export type TurnSummary = {
  kind: string; outcome: string | null; declared: string | null; ending: string | null; need: string | null;
  about: TurnAbout | null; waitSeconds: number | null; waitFor: string | null;
  /// Whether the wait is its session's watch keeping on (chat_state waiting `watch`); null said before it.
  waitWatch: boolean | null; detail: string | null; startedAt: number; endedAt: number | null;
};

export type TurnRow = { id: string; summary: TurnSummary };

export type SessionStats = { turns: number; workMs: number | null; pending: number; firstText: string | null; lastTurn: TurnSummary | null };
/// Whether a session has something going: its messages not delivered yet, and its latest turn (store.ts `statsOf`).
export type SessionBusy = Pick<SessionStats, "pending" | "lastTurn">;

/// A profile's last check and quota, kept across restarts.
export type ProfileStatus = { check: Json | null; quota: Json | null };

export type ProcessRow = { pgid: number; startedAt: number; runtime: string; label: string };

/// A message being recorded (NewMessage::new's defaults may be left out).
export type NewMessage = {
  thread: number; ts: string; authorKind: AuthorKind; author: string; text: string; attachments?: Attachment[];
  quotes?: Quote[]; declared?: string | null; client?: string | null; profile?: string | null; runtime?: string | null; card?: Json | null;
  options?: Json | null; at?: number | null; letter?: Letter;
  agentIdentity?: Json; change?: RunChange; proposal?: ProjectProposal;
};

export const newMessage = (thread: number, ts: string, authorKind: AuthorKind, author: string, text: string): NewMessage => ({
  thread, ts, authorKind, author, text,
});

/// A background job a session started. `sessionKey` is serde's `session`.
export type JobRow = {
  id: string; sessionKey: string; name: string; command: string; cwd: string; port: number | null;
  /// Not for the pages (serde skip).
  token: string;
  state: string; pgid: number | null; exitCode: number | null; startedAt: number; endedAt: number | null;
  restarts: number; log: string; watch: boolean;
  /// Waiting in the station's queue for room (jobs/admit.ts): running as far as its agent is concerned, not started yet.
  queued?: boolean;
  /// It uses the screen (windows, a simulator): one such job at a time.
  screen?: boolean;
  /// A brief offscreen task in the station's one small-work slot.
  small?: boolean;
  /// It runs in a sandbox, the chat's there (agents/sandbox.ts): a task asked of one of the station's sandboxes.
  sandbox?: SandboxPlace;
};

export type JobNotice = { at: number; text: string };

/// What a person chose in a widget an agent posted. `thread` is (channel, thread ts) when its message is still there.
export type WidgetModel = { path: string; name: string; thread: [string, string] | null; model: string };

/// Whom a turn works for (Store::startTurnFor).
export type TurnFor = { profile: string | null; person: string | null; thread: number | null };

/// What the store says changed, for whoever follows it (the admin API's /events, the hub).
export type StoreChange =
  /// Anything about that session changed; `pending`: how many messages it has yet to take, as it took some.
  | { type: "session"; key: string; pending?: number }
  /// It was deleted; `ws` the workspace its chat was in (null: the home one).
  | { type: "sessionRemoved"; key: string; ws?: string | null }
  /// Entries were appended there (contiguous, in order), or its sessions changed (none); `closed`: the post (its n)
  /// whose card was closed or withdrawn without a message (closed_cards).
  /// `answered`: a person's message handed to a session in a platform's thread that settled the conversational card
  /// waiting there (store/card-kinds.ts; in a still.fail chat it is settled as it is written).
  /// `proposalResolved`: entry whose inline project proposal outcome was recorded in `proposal_outcomes`.
  | { type: "thread"; id: number; entries: EntryRow[]; closed?: number; answered?: { n: number; author: string; ts: string }; proposalResolved?: EntryRow }
  /// Letters were kept in its own log of them (schema.ts LETTERS; contiguous, in order).
  | { type: "letters"; id: number; letters: EntryRow[] }
  /// It went, with every entry it had; `ws` as its session's.
  | { type: "threadRemoved"; id: number; ws?: string | null }
  /// A chat was handed to another station (`station`; null: it came back here): its session, the workspace it is of,
  /// its thread here and there (replica/handover.ts).
  | { type: "moved"; key: string; station: string | null; ws: string | null; thread: number | null; there: number | null }
  /// A viewer's read position moved.
  | { type: "read"; viewer: string; thread: number; n: number }
  /// A viewer hid a chat from their lists, or made it visible again.
  | { type: "hidden"; viewer: string; thread: number; hidden: boolean }
  /// A viewer changed whether a chat sends them notifications.
  | { type: "muted"; viewer: string; thread: number; muted: boolean }
  /// The Slack users a viewer said are them changed.
  | { type: "identities"; viewer: string }
  /// The chats a viewer pinned changed.
  | { type: "pins"; viewer: string; session?: string; at?: number | null }
  /// The decisions a viewer dismissed changed.
  /// `card`: the card dismissed (its thread and entry); `kept`: a chat kept from archiving, or let go again.
  | { type: "dismissed"; viewer: string; card?: { thread: number; n: number }; kept?: { thread: number; kept: boolean } }
  /// The recorded runtime processes changed.
  | { type: "processes" }
  | { type: "decisionChecks" }
  /// A background job started, started again, ended or said something (its session changes as well).
  | { type: "job"; id: string }
  /// A job that was over was taken off its session's record.
  | { type: "jobRemoved"; id: string; session: string }
  /// What was written of a chat beside what is said in it, as written: a device that makes its sidebar itself puts it
  /// in place (api/events.ts `chat-mark`). `archive`: the review's suggestion (the version it looked at; null: none
  /// now) or what it found (`verdict`); `share`: who the chat is shared with now (none: no one); `opened`: a chat an
  /// agent opened from it.
  | { type: "chatMark"; thread: number | null; session: string; archive?: { suggested?: number | null; verdict?: Json }; share?: { to: { workspace: string; name: string }[]; write: boolean }; opened?: Json }
  /// Model calls were recorded (store/usage.ts), of these sessions; `from`, when the earliest of them was made (ms):
  /// what a page holding the usage reads again of it, from that day on.
  | { type: "usage"; sessions: string[]; from?: number; statisticsOnly?: boolean }
  /// A session went on in another runtime session, or in none (its context cleared): where its context stands changed.
  | { type: "conversation"; key: string };

// ── words ──

/// How a turn ended or a post was declared, in the words from before: final, block, waiting.
export function saidBefore(declared: string): string {
  if (declared === "all_done") return "final";
  if (declared === "need_decision" || declared === "need_help") return "block";
  return declared;
}

/// The same in today's words: final is all_done, block and need_decision need_help.
export function ending(declared: string): string {
  if (declared === "final") return "all_done";
  if (declared === "block" || declared === "need_decision") return "need_help";
  return declared;
}

/// Options to pick from as a card.
export const optionsCard = (options: Json): Json => ({ type: "options", options });

/// EntryRow::card: its own card, else its options as an options card (a post from before cards).
export const cardOfEntry = (e: EntryRow): Json | undefined => e.card ?? (e.options === undefined ? undefined : optionsCard(e.options));

/// `serde_json::from_str::<Value>(..).ok()`: undefined when it does not parse.
export function parsed(text: string | null | undefined): Json | undefined {
  if (text === null || text === undefined) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/// A message's card as kept: its `card` column, else its `options` (from before cards) as an options card.
export function cardOf(card: string | null, options: string | null): Json | undefined {
  const own = parsed(card);
  if (own !== undefined) return own;
  const before = parsed(options);
  return before === undefined ? undefined : optionsCard(before);
}

// serde's reading (and writing) of Attachment and Quote: their fields in their order, unknown ones dropped, a wrong one
// fails the list.
const isObj = (v: Json) => v !== null && typeof v === "object" && !Array.isArray(v);
const optional = (v: Json, ok: (v: Json) => boolean) => v === undefined || v === null || ok(v);
const isStr = (v: Json) => typeof v === "string";
const isU64 = (v: Json) => typeof v === "number" && Number.isInteger(v) && v >= 0;
const isU32 = (v: Json) => isU64(v) && v <= 0xffffffff;

export function attachment(a: Json): Attachment {
  if (!isObj(a) || !isStr(a.name) || !isStr(a.path) || !isU64(a.size)) throw new Error("attachment");
  if (!optional(a.width, isU32) || !optional(a.height, isU32) || !optional(a.thumbhash, isStr)) throw new Error("attachment");
  if (!optional(a.duration, isU64) || !optional(a.frames, isU32)) throw new Error("attachment");
  const v: Attachment = { name: a.name, path: a.path, size: a.size };
  if (a.width !== undefined && a.width !== null) v.width = a.width;
  if (a.height !== undefined && a.height !== null) v.height = a.height;
  if (a.thumbhash !== undefined && a.thumbhash !== null) v.thumbhash = a.thumbhash;
  if (a.duration !== undefined && a.duration !== null) v.duration = a.duration;
  if (a.frames !== undefined && a.frames !== null) v.frames = a.frames;
  return v;
}

export function quote(q: Json): Quote {
  if (!isObj(q) || !isStr(q.author) || !isStr(q.text) || !isStr(q.comment)) throw new Error("quote");
  if (!optional(q.ts, isStr) || !optional(q.role, isStr) || !optional(q.file, isStr)) throw new Error("quote");
  const v: Quote = { author: q.author, text: q.text, comment: q.comment };
  if (q.ts !== undefined && q.ts !== null) v.ts = q.ts;
  if (q.role !== undefined && q.role !== null) v.role = q.role;
  if (q.file !== undefined && q.file !== null) v.file = q.file;
  return v;
}

/// from_json_list: a stored list, or none when it does not read.
function fromJsonList<T>(text: string | null, read: (v: Json) => T): T[] {
  const list = parsed(text);
  if (!Array.isArray(list)) return [];
  try {
    return list.map(read);
  } catch {
    return [];
  }
}

/// json_list: none for an empty list, else the list as serde writes it.
export function jsonList<T>(value: T[], write: (v: Json) => T): string | null {
  return value.length === 0 ? null : JSON.stringify(value.map(write));
}

/// AuthorKind::parse.
export function authorKind(s: string): AuthorKind {
  if (s === "agent") return "agent";
  // ("ember" and "stillfail": the kind stations wrote for the station before, in their databases and archives.)
  if (s === STATION_AUTHOR || s === "ember" || s === "stillfail") return STATION_AUTHOR;
  return "person";
}

function parseProfiles(raw: unknown, profile: string, pinned: boolean): string[] | null {
  if (typeof raw === "string" && raw !== "") {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        const list = parsed.filter((x): x is string => typeof x === "string" && x !== "");
        if (list.length > 0) return list;
      }
    } catch {}
  }
  return pinned ? [profile] : null;
}

export function toSession(r: Json): SessionRow {
  const profilePinned = r.profile_pinned === 1;
  return {
    key: r.key, connect: r.connect, scope: r.scope === "all" ? "all" : "thread", title: r.title, createdBy: r.created_by,
    runtime: r.runtime, profile: r.profile, profilePinned, profiles: parseProfiles(r.profiles, r.profile, profilePinned), model: r.model, effort: r.effort,
    ...(r.tui === 1 ? { tui: true } : {}),
    ...(typeof r.speed === "string" ? { speed: r.speed as ModelSpeed } : {}),
    fast: r.fast === null || r.fast === undefined ? null : r.fast !== 0,
    afresh: r.afresh === null || r.afresh === undefined ? null : r.afresh !== 0, context: typeof r.context === "number" ? r.context : null, contextBefore: typeof r.context_before === "number" ? r.context_before : null,
    ...(typeof r.compactions === "number" && r.compactions > 0 ? { compactions: r.compactions } : {}),
    runtimeSessionId: r.runtime_session_id,
    workspace: r.workspace, cwd: r.cwd ?? null, ws: r.ws ?? null, token: r.token, running: r.running === 1, createdAt: r.created_at,
    lastActiveAt: r.last_active_at, archivedAt: r.archived_at, archivedBy: r.archived_by, shownAt: r.shown_at,
    ...(typeof r.came_from === "string" && r.came_from !== "" ? { from: r.came_from } : {}),
    ...(typeof r.conv === "string" && r.conv !== "" ? { conv: r.conv } : {}),
  };
}

/// A chat an agent opened for another (opened_chats): each side by its station ('' for this one) and session key.
export type Opened = {
  childStation: string; child: string; parentStation: string; parent: string; key: string; title: string | null;
  link: string | null; state: string | null; createdAt: number;
  /// What the parent was called when it opened the child (kept by the child's station only; null before it).
  openerTitle: string | null;
  /// Whether its opener leads it (chat_create `for: "me"`): its asks are its opener's to take up, not its person's.
  /// Null on a row from before it (its opener told as a leader is, its asks its person's).
  led: boolean | null;
};

export function toOpened(r: Json): Opened {
  return {
    childStation: r.child_station, child: r.child, parentStation: r.parent_station, parent: r.parent, key: r.key, title: r.title,
    link: r.link, state: r.state, createdAt: r.created_at, openerTitle: r.opener_title ?? null,
    led: r.led === undefined || r.led === null ? null : Number(r.led) === 1,
  };
}

/// How long a chat stays shared with a workspace whose agents neither read it nor write to it:
/// after that a person must share it again.
export const XSHARE_IDLE_MS = 6 * 60 * 60_000;

/// Why a chat once shared with an agent's workspace is not now.
export const LAPSED = "that chat's share with your workspace lapsed, unused for 6 hours: a person of its workspace must share it again (by @-mentioning it in a message to you, or in its chat info)";

/// A chat shared with other workspaces (chat_shares): each workspace with when its agents last read
/// it or wrote to it, or it was shared with them (`used`).
export type ChatShare = { to: { workspace: string; name: string; used: number }[]; write: boolean; by: string; at: number };

/// A chat_shares row as stored: every workspace it names, those whose share lapsed too (one kept from before `used`
/// was used when it was shared).
export function toChatShare(r: Json): ChatShare {
  let to: Json = [];
  try {
    to = JSON.parse(r.shared);
  } catch {}
  const list = Array.isArray(to)
    ? to.filter((t: Json) => typeof t?.workspace === "string").map((t: Json) => ({ workspace: t.workspace as string, name: String(t.name ?? t.workspace), used: typeof t.used === "number" ? t.used : r.at }))
    : [];
  return { to: list, write: r.write === 1, by: r.by, at: r.at };
}

/// Whether a workspace's share is still on at `now`: used within XSHARE_IDLE_MS.
export const shareLive = (t: { used: number }, now: number) => now - t.used < XSHARE_IDLE_MS;

/// A share as it is at `now`: the workspaces it is still on for; null when none.
export function liveShare(share: ChatShare, now: number): ChatShare | null {
  const to = share.to.filter((t) => shareLive(t, now));
  return to.length === 0 ? null : { ...share, to };
}

function parseThreadLinks(raw: unknown): ThreadLinks | null {
  if (typeof raw !== "string" || raw === "") return null;
  try {
    const v = JSON.parse(raw);
    if (v === null || typeof v !== "object" || Array.isArray(v)) return null;
    const out: ThreadLinks = {};
    if (typeof v.web === "string" && v.web !== "") out.web = v.web;
    if (typeof v.app === "string" && v.app !== "") out.app = v.app;
    return out.web !== undefined || out.app !== undefined ? out : null;
  } catch {
    return null;
  }
}

export function toThread(r: Json): ThreadRow {
  const links = parseThreadLinks(r.links);
  const tags = parseThreadTags(r.tags);
  return {
    id: r.id, surface: r.surface, channel: r.channel, threadTs: r.thread_ts, title: r.title, autoTitle: r.auto_title,
    createdBy: r.created_by, createdAt: r.created_at, home: r.home, hiddenAt: r.hidden_at, hiddenBy: r.hidden_by,
    shownAt: r.shown_at, ...(links !== null ? { links } : {}),
    ...(typeof r.project === "string" ? { project: r.project } : {}),
    ...(r.project_locked === 1 ? { projectLocked: true } : {}),
    ...(tags !== undefined ? { tags } : {}),
  };
}

export const toSessionThread = (r: Json): SessionThread => ({ thread: toThread(r), connect: r.connect });

export const toMembership = (r: Json): Membership => ({ thread: r.thread, session: r.session, connect: r.connect, joinedAt: r.joined_at, leftAt: r.left_at ?? null });

/// An entry's columns as they are stored (store.ts `#insertEntry`).
export function entryColumns(e: EntryRow): Json {
  return {
    thread: e.thread, n: e.n, kind: e.kind, target: e.target, ts: e.ts, author_kind: e.authorKind, author: e.author, text: e.text,
    attachments: jsonList<Attachment>(e.attachments, attachment), quotes: jsonList<Quote>(e.quotes, quote), declared: e.declared,
    client: e.client, profile: e.profile, runtime: e.runtime, options: e.options === undefined ? null : JSON.stringify(e.options),
    card: e.card === undefined ? null : JSON.stringify(e.card), at: e.at,
    agent_identity: e.agentIdentity === undefined ? null : JSON.stringify(e.agentIdentity), letter: e.letter === undefined ? null : JSON.stringify(e.letter),
    change: e.change === undefined ? null : JSON.stringify(e.change),
    proposal: e.proposal === undefined ? null : JSON.stringify(e.proposal),
  };
}

/// An entry as a read of it gives it once it is stored: what is told of it as it is written is the same.
export const stored = (e: EntryRow): EntryRow => toEntry(entryColumns(e));

export function toEntry(r: Json): EntryRow {
  return {
    agentIdentity: parsed(r.agent_identity), thread: r.thread, n: r.n, kind: r.kind === "edit" ? "edit" : "message",
    target: r.target, ts: r.ts, authorKind: authorKind(r.author_kind), author: r.author, text: r.text,
    attachments: fromJsonList(r.attachments, attachment), quotes: fromJsonList(r.quotes, quote), declared: r.declared,
    client: r.client, profile: r.profile, runtime: r.runtime ?? null, options: parsed(r.options), card: parsed(r.card), at: r.at,
    ...withLetter(r.letter), ...withChange(r.change), ...withProposal(r.proposal),
  };
}

/// `proposal` when there is one (proposalOf), to spread into a row.
export const withProposal = (v: unknown): { proposal?: ProjectProposal } => {
  const proposal = proposalOf(v);
  return proposal === undefined ? {} : { proposal };
};

/// `letter` when there is one (letterOf), to spread into a row.
export const withLetter = (v: unknown): { letter?: Letter } => {
  const letter = letterOf(v);
  return letter === undefined ? {} : { letter };
};

/// `change` when there is one (a notice's, EntryRow `change`), to spread into a row.
export const withChange = (v: unknown): { change?: RunChange } => {
  const change = typeof v === "string" ? parsed(v) : v;
  return change !== null && typeof change === "object" && change.was !== null && typeof change.was === "object" && change.now !== null && typeof change.now === "object" ? { change } : {};
};

/// A row of the letters' own log (schema.ts LETTERS) as an entry: a message, never edited, numbered in that log.
export function letterEntry(r: Json): EntryRow {
  return {
    agentIdentity: undefined, thread: r.thread, n: r.n, kind: "message", target: null, ts: r.ts, authorKind: authorKind(r.author_kind),
    author: r.author, text: r.text, attachments: fromJsonList(r.attachments, attachment), quotes: [], declared: null, client: null,
    profile: null, runtime: null, options: undefined, card: undefined, at: r.at, ...withLetter(r.letter),
  };
}

/// A row of the letters' own log as a message (to be handed to a session, letterEntry).
export function letterMessage(r: Json): MessageRow {
  return {
    agentIdentity: null, thread: r.thread, n: r.n, ts: r.ts, authorKind: authorKind(r.author_kind), author: r.author, text: r.text,
    attachments: fromJsonList(r.attachments, attachment), quotes: [], declared: null, client: null, createdAt: r.at, editedAt: null,
    ...withLetter(r.letter), apart: true,
  };
}

export function toMessage(r: Json): MessageRow {
  return {
    agentIdentity: parsed(r.agent_identity) ?? null, thread: r.thread, n: r.n, ts: r.ts ?? "",
    authorKind: authorKind(r.author_kind), author: r.author, text: r.text ?? "",
    attachments: fromJsonList(r.attachments, attachment), quotes: fromJsonList(r.quotes, quote), declared: r.declared,
    client: r.client, createdAt: r.created_at, editedAt: r.edited_at, ...withLetter(r.letter),
  };
}

/// to_about: all three, or none.
function toAbout(r: Json): TurnAbout | null {
  return r.about_thread !== null && r.about_n !== null && r.about_ts !== null ? { thread: r.about_thread, seq: r.about_n, ts: r.about_ts } : null;
}

/// TurnSummary from a turns row (or session_stats' `l.*`).
export function toTurnSummary(r: Json): TurnSummary {
  return {
    kind: r.kind, outcome: r.outcome, declared: r.declared === null ? null : saidBefore(r.declared),
    ending: r.declared === null ? null : ending(r.declared), need: r.need, about: toAbout(r), waitSeconds: r.wait_seconds,
    waitFor: r.wait_for, waitWatch: r.wait_watch === null || r.wait_watch === undefined ? null : r.wait_watch === 1, detail: r.detail, startedAt: r.started_at, endedAt: r.ended_at,
  };
}

/// TurnSummary as serde writes it: camelCase, the skipped Nones (ending, need, about, waitSeconds, waitFor, waitWatch) left
/// out.
export function turnSummaryJson(t: TurnSummary): Record<string, Json> {
  const v: Record<string, Json> = { kind: t.kind, outcome: t.outcome, declared: t.declared };
  if (t.ending !== null) v.ending = t.ending;
  if (t.need !== null) v.need = t.need;
  if (t.about !== null) v.about = t.about;
  if (t.waitSeconds !== null) v.waitSeconds = t.waitSeconds;
  if (t.waitFor !== null) v.waitFor = t.waitFor;
  if (t.waitWatch !== null) v.waitWatch = t.waitWatch;
  v.detail = t.detail;
  v.startedAt = t.startedAt;
  v.endedAt = t.endedAt;
  return v;
}

export function toJob(r: Json): JobRow {
  return {
    id: r.id, sessionKey: r.session_key, name: r.name, command: r.command, cwd: r.cwd, port: r.port, token: r.token,
    state: r.state, pgid: r.pgid, exitCode: r.exit_code, startedAt: r.started_at, endedAt: r.ended_at,
    restarts: r.restarts, log: r.log, watch: r.watch !== 0, ...(r.queued === 1 ? { queued: true } : {}), ...(r.screen === 1 ? { screen: true } : {}),
    ...(r.small === 1 ? { small: true } : {}),
    // (`size` held a sandbox's size before sandboxes were station_task's targets; such a job runs nowhere now)
    ...(typeof r.size === "string" && r.size.startsWith("{") ? { sandbox: JSON.parse(r.size) as SandboxPlace } : {}),
  };
}

/// Entries merged into their messages, as the `merged` view does: for a thread read from its archive file.
export function mergeEntries(entries: EntryRow[]): MessageRow[] {
  const messages = new Map<number, MessageRow>();
  for (const e of entries) {
    if (e.kind === "message") {
      messages.set(e.n, {
        agentIdentity: e.agentIdentity ?? null, thread: e.thread, n: e.n, ts: e.ts ?? "", authorKind: e.authorKind,
        author: e.author, text: e.text ?? "", attachments: e.attachments, quotes: e.quotes, declared: e.declared,
        client: e.client, createdAt: e.at, editedAt: null, ...(e.letter !== undefined ? { letter: e.letter } : {}),
      });
    } else {
      const m = e.target === null ? undefined : messages.get(e.target);
      if (m) {
        m.text = e.text ?? "";
        m.attachments = e.attachments;
        m.quotes = e.quotes;
        m.editedAt = e.at;
      }
    }
  }
  return [...messages.values()].sort((a, b) => a.n - b.n);
}

/// The first `n` characters (Rust's `chars().take(n)`: code points, not UTF-16 units).
export function takeChars(text: string, n: number): string {
  let out = "";
  let count = 0;
  for (const c of text) {
    if (count++ >= n) break;
    out += c;
  }
  return out;
}

/// Rust's ordering of String keys (a BTreeMap's): by their UTF-8 bytes.
export const byBytes = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));

/// The jobs running now, the latest first, by the index on their state (schema.ts jobs_up): the main thread's and the
/// readers' (who keeps watch).
// The process watchers need a stable choice when equally large jobs start together. The former query's usual
// jobs_up plan read ties by port and rowid; spell that order out so either query plan gives the same answer.
export const JOBS_RUNNING = "SELECT * FROM jobs WHERE state = 'running' ORDER BY started_at DESC, port, rowid";

/// The jobs running, and the services stopped on their own that hold their port (an exited one with a port), the latest
/// first, by the same index: what a session has up (store.ts `jobsUp`), and the readers' list of them (GET /jobs).
export const JOBS_UP = "SELECT * FROM (SELECT * FROM jobs WHERE state = 'running' UNION ALL SELECT * FROM jobs WHERE state = 'exited' AND port IS NOT NULL) ORDER BY started_at DESC";

/// The latest running service, or one waiting to restart, holding a port. The two state-and-port seeks do not read
/// other services or commands (jobs.ts startId).
/// The sessions in sight on profile ?1 not handed away, at most ?2 (by the index of those in sight).
export const LIVE_ON_PROFILE = "SELECT key FROM sessions INDEXED BY sessions_live WHERE archived_at IS NULL AND profile = ?1 AND key NOT IN (SELECT session FROM handed_over) LIMIT ?2";
/// Each of sessions ?1's last job made (its rowid within the session's index) and where it stands: one statement.
export const LAST_JOBS_OF = "SELECT session_key AS k, rowid AS r, ended_at AS e, state FROM jobs WHERE rowid IN (SELECT MAX(rowid) FROM jobs INDEXED BY jobs_by_session WHERE session_key IN (SELECT value FROM json_each(?1)) GROUP BY session_key)";
export const JOB_AT_PORT = `SELECT id, name, port FROM (
  SELECT id, name, port, started_at FROM jobs INDEXED BY jobs_up WHERE state = 'running' AND port = ?1
  UNION ALL
  SELECT id, name, port, started_at FROM jobs INDEXED BY jobs_up WHERE state = 'exited' AND port = ?1
) ORDER BY started_at DESC LIMIT 1`;

/// A session's jobs, the latest first, by the index on their session (schema.ts jobs_by_session): the main thread's and
/// the readers'.
export const SESSION_JOBS = "SELECT * FROM jobs WHERE session_key = ? ORDER BY started_at DESC";

/// The session that went on with a runtime's session (`?1`, `?2`: its current one, or one it ran in before), the latest
/// active first: by the indexes on them (schema.ts sessions_by_runtime_id, runtime_sessions_by_id), not by asking every
/// session in turn which it ran in.
export const SESSION_OF_RUNTIME = `SELECT key FROM (
    SELECT key, last_active_at FROM sessions s WHERE runtime_session_id = ?2 AND runtime = ?1
      AND NOT EXISTS (SELECT 1 FROM runtime_sessions r WHERE r.session_key = s.key AND r.id = ?2 AND COALESCE(r.runtime, s.original_runtime, s.runtime) != ?1)
    UNION ALL SELECT s.key, s.last_active_at FROM runtime_sessions r JOIN sessions s ON s.key = r.session_key WHERE r.id = ?2 AND COALESCE(r.runtime, s.original_runtime, s.runtime) = ?1
  ) ORDER BY last_active_at DESC LIMIT 1`;

/// What each list of chats asks of the cards answered lately (answersSince, the main thread's and the readers'): the
/// latest card, or post with options, before a person's message (schema.ts addClientColumn's entries_cards and
/// entries_options), and the cards closed since in each requested thread.
export const CARD_BEFORE = "SELECT max(n) AS n FROM entries WHERE thread = ? AND n < ? AND kind = 'message' AND card IS NOT NULL";
export const OPTIONS_BEFORE = "SELECT max(n) AS n FROM entries WHERE thread = ? AND n < ? AND kind = 'message' AND options IS NOT NULL";
/// The same cards for one thread, by thread and time, with insertion order for ties across threads.
export const CLOSED_THREAD_SINCE = "SELECT thread, n, viewer, at, rowid AS ordering FROM closed_cards WHERE thread = ? AND at >= ?";
/// A thread's people's messages since `?2` (the items of a sidebar a change touched), by schema.ts entries_people_since.
export const SAID_SINCE = "SELECT thread, n FROM entries WHERE thread = ? AND author_kind = 'person' AND kind = 'message' AND at >= ?";

/// The last message as merged, including letters kept among old entries. Seek each kind before reading its edit.
/// A partially upgraded old store may lack entries_letters; SQLite still reads it there, using the thread's entries.
export const LAST_MESSAGE = `SELECT * FROM merged WHERE thread = ?1 AND n = (
  SELECT MAX(n) FROM (
    SELECT (SELECT n FROM entries INDEXED BY entries_said WHERE thread = ?1 AND kind = 'message' AND letter IS NULL ORDER BY n DESC LIMIT 1) AS n
    UNION ALL SELECT (SELECT n FROM entries WHERE thread = ?1 AND kind = 'message' AND letter IS NOT NULL ORDER BY n DESC LIMIT 1)
  )
)`;
/// On an old store whose ordinary messages were prepared in bounded batches, use its equivalent lookup.
export const LEGACY_LAST_MESSAGE = `SELECT * FROM merged WHERE thread = ?1 AND n = (
  SELECT MAX(n) FROM (
    SELECT (SELECT n FROM (${LEGACY_SAID_LATEST})) AS n
    UNION ALL SELECT (SELECT n FROM entries WHERE thread = ?1 AND kind = 'message' AND letter IS NOT NULL ORDER BY n DESC LIMIT 1)
  )
)`;

/// A page of messages as merged, latest first. Merge the two ordered message indexes to select a page before reading
/// the messages and their edits; a page does not walk the edits that followed its messages. Like LAST_MESSAGE, old
/// letter metadata on non-messages, or a store missing entries_letters, can make the legacy lookup walk more entries.
export const MESSAGE_KEYS_BEFORE = `
  SELECT n FROM entries INDEXED BY entries_said
    WHERE thread = ?1 AND n < ?2 AND kind = 'message' AND letter IS NULL
  UNION ALL
  SELECT n FROM entries
    WHERE thread = ?1 AND n < ?2 AND kind = 'message' AND letter IS NOT NULL
  ORDER BY n DESC LIMIT ?3`;
export const LEGACY_MESSAGE_KEYS_BEFORE = `
  SELECT n FROM legacy_said WHERE thread = ?1 AND n < ?2
  UNION ALL
  SELECT n FROM entries WHERE thread = ?1 AND n < ?2 AND kind = 'message' AND letter IS NOT NULL
  ORDER BY n DESC LIMIT ?3`;
export const MESSAGES_BEFORE = `SELECT * FROM merged WHERE thread = ?1 AND n IN (${MESSAGE_KEYS_BEFORE}) ORDER BY n DESC`;
export const LEGACY_MESSAGES_BEFORE = `SELECT * FROM merged WHERE thread = ?1 AND n IN (${LEGACY_MESSAGE_KEYS_BEFORE}) ORDER BY n DESC`;

/// The entries belonging to a page of messages, without reading the other entries between them.
export const MESSAGE_PAGE_ENTRIES = `SELECT e.*, COALESCE(e.proposal, ep.proposal) AS proposal FROM json_each(?2) j
  CROSS JOIN entries e ON e.thread=?1 AND e.n=CAST(j.value AS INTEGER)
  LEFT JOIN entry_proposals ep ON ep.thread=e.thread AND ep.n=e.n ORDER BY e.n`;

/// A context falling under half of what the call before sent (at least this much), on the same account and model, was
/// compacted (sessions/pool.ts; what schema.ts USAGE_COMPACTIONS keeps).
export const COMPACTED_FROM = 50_000;

/// Who wrote in a thread, each with when they first did: as the database keeps them (schema.ts LIST_STATE
/// thread_people), each's first message's time.
export const PEOPLE_AT = "SELECT p.author, e.at FROM thread_people p JOIN entries e ON e.thread = p.thread AND e.n = p.first_n WHERE p.thread = ?";
