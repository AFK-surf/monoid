// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/views.ts's.
//
// What the pages read: the sidebar (GET /chats) and thread entries (GET /threads/:id/entries), ported from
// the Rust station's admin/views.rs with the same JSON, field for field and in serde_json's order (preserve_order).
//
// What the Rust station keeps outside the database is taken as a station with none of it has it:
// - the hub: no session has a runtime process (`process_state` "cold"), no client keys (`client_key` none);
// - Slack connections: none connected, so no workspace or channel names (`known_channel`) and no Slack people
//   (`known_person`): a Slack user goes by their id, with no email;
// - the cloud's names (`deps.names`): those of the members who asked since the station started (`Store.names`);
// - the config's connects are read from config.json in the data directory for the names
//   agents go by; none when it has none.
// Words are in the language the request asks in (`stillfail-lang`, else Accept-Language, else Chinese).
import type { Viewer } from "../../src/mesh/credential.ts";
import { sees, seesMissing } from "../../src/store/rows.ts";
import * as store from "./store.ts";
import { Refused as HttpError } from "../../src/api/request.ts";
import * as titles from "../../../client/core-ts/src/titles.ts";
import { trim } from "../../../client/core-ts/src/whitespace.ts";
import * as chatRow from "../../../client/core-ts/src/chat-row.ts";
import { knownChannel, knownPerson, slackCreator, teamName } from "./slack-known.ts";
import { log } from "../../src/ops/log.ts";
import { ANSWER_AFTER, ASKER_BEFORE, CONVERSATION_CARD_LATEST, SYSTEM_CARDS_WAITING, WAITS_ON_JOB, WAITS_ON_LED } from "../../src/store/card-kinds.ts";
import { type AuthorKind, type Json, type MessageRow, type Store, type ThreadRow, type ThreadSummary, STILLFAIL_SURFACE, takeChars } from "./store.ts";
import { STILLFAIL_CONNECT } from "../../src/store/rows.ts";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { tr, untitled, type Api, configOf, given, titleOf, type Names, authorNames, pictureView, declaredView, entryViews } from "../../src/read/views.ts";

export * from "../../src/read/views.ts";
export { HttpError, tr, untitled, type Api, given, titleOf, type Names, authorNames, pictureView, declaredView, entryViews };

/// config.json as last read for a store, again when the file changed (by its size, time and inode).
const configs = new WeakMap<Store, { stamp: string; raw: Json }>();
/// The views' `Api` as a reader thread made it: config.json and the names books read from the data directory when they
/// changed (the station's own holds both in memory: src/read/views.ts `apiOf`).
export function apiOf(s: Store): Api {
  const path = join(s.dataDir, "config.json");
  let stamp = "none";
  try {
    const st = statSync(path);
    stamp = `${st.size}:${st.mtimeMs}:${st.ino}`;
  } catch {}
  let had = configs.get(s);
  if (had === undefined || had.stamp !== stamp) {
    let raw: Json = {};
    try {
      raw = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      // No config: no connects.
    }
    had = { stamp, raw };
    configs.set(s, had);
  }
  return { store: s, ...configOf(had.raw), person: (connect, user) => knownPerson(s, connect, user) };
}

export { makeStore, openStore } from "./store.ts";

/// How much of a chat's last message the sidebar gets.
const LAST_CHARS = 200;
/// How far back a row says which cards the viewer answered in it: a day and a half.
const ANSWERED_WITHIN = 36 * 3600 * 1000;
/// The cloud's names of the store being answered for, for `people` and `authorNames` used on their own.
export const useNames = (s: Store) => ((cloudNames = s.names), (currentStore = s));
/// The store being answered for, for Slack's names (slack-known.ts).
let currentStore: Store | null = null;

// ---- titles ----

function turnSummary(t: store.TurnSummary): Json {
  return t;
}

/// The connect a Slack thread came in through: the first of its sessions' that is not the station's own.
export function slackConnectOf(t: Pick<ThreadSummary, "sessions">): string | null {
  return t.sessions.map((m) => m.connect).find((c) => c !== STILLFAIL_CONNECT) ?? null;
}

/// The shared title rule uses the first message only for an unnamed external chat.
export function titleNeedsFirstText(thread: ThreadRow): boolean {
  return titles.givenTitle(thread) === null && !titles.isOwnChat(thread);
}

/// What a thread is called (title_of over a summary).
export function chatTitle(t: ThreadSummary, channelName: string | null): string {
  return titleOf(t.thread, t.firstText, channelName);
}

// ---- people ----

/// What a thread is called for a client: as `titleOf`, but "" where the rule would say a word (a chat with no name, an
/// unnamed direct message): the client says it in its own language.
export function shownTitleOf(thread: ThreadRow, firstText: string | null, channelName: string | null): string {
  return titles.chatTitle(thread, firstText, channelName, { untitled: "", directMessage: "" });
}

/// A creator reference in words: who, and their email where known.
/// The names of the store being answered for (creator and people have no store of their own).
let cloudNames = new Map<string, string>();

export function creator(reference: string | null): Json | null {
  if (reference === null) return null;
  // (the local page named by the client: core-ts present.ts `person`)
  if (reference === "local") return { id: "local", name: null, email: null, via: "local" };
  if (reference.startsWith("slack:") && currentStore !== null) {
    const slack = slackCreator(currentStore, reference);
    if (slack !== null) return slack;
  }
  return { id: reference, name: cloudNames.get(reference) ?? reference, email: reference, via: "cloud" };
}

/// Several people, once each: one person may write through Slack and the station's chat under the same email.
export function people(refs: string[]): Json[] {
  const seen = new Set<string>();
  return refs
    .map((r) => creator(r))
    .filter((p): p is Json => p !== null)
    .filter((p) => {
      const key = typeof p.email === "string" ? p.email : typeof p.id === "string" ? p.id : "";
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

/// Whether a person is the viewer: by id, by email, or as a Slack user the viewer said is them.
function isMine(api: Api, viewer: Viewer): (person: Json | null) => boolean {
  const id = viewer.email;
  const email = viewer.email.toLowerCase();
  const slack = new Set(store.slackIdentities(api.store, id));
  return (p) => {
    if (p === null || p === undefined) return false;
    const pid: string = typeof p.id === "string" ? p.id : "";
    return (
      pid === id ||
      (typeof p.email === "string" && p.email.toLowerCase() === email) ||
      (p.via === "slack" && slack.has(pid.slice(pid.lastIndexOf(":") + 1)))
    );
  };
}

/// Where a Slack thread is, for the connect icon's tip: the Slack workspace, the channel, and where its thread lives
/// (a Feishu or Comma connect's own). No connection is up to name the workspace, nor knows the channel.
function origin(t: Pick<ThreadSummary, "thread" | "sessions">): Json {
  const connect = slackConnectOf(t);
  const s = currentStore!;
  return { teamName: connect === null ? null : teamName(s, connect), channel: t.thread.channel, channelName: knownChannel(s, connect, t.thread.channel), threadTs: t.thread.threadTs, surface: t.thread.surface };
}

// ---- messages ----

/// A merged message as lists show it (a thread's latest), with its author's name.
export function messageView(m: MessageRow, names: Names, s: Store): Json {
  const v: Json = {
    agentIdentity: m.agentIdentity, seq: m.n, thread: m.thread, ts: m.ts, authorKind: m.authorKind, author: m.author, authorName: names(m.authorKind, m.author),
    text: m.text, attachments: m.attachments, quotes: m.quotes, declared: m.declared, createdAt: m.createdAt, editedAt: m.editedAt,
  };
  pictureView(v, names, m.authorKind, m.author);
  if (m.authorKind === "agent") {
    const session = m.agentIdentity == null || typeof m.agentIdentity.runtime !== "string" ? store.getSession(s, m.author) : null;
    const runtime = m.agentIdentity?.runtime ?? store.originalRuntime(s, m.author) ?? session?.runtime;
    if (typeof runtime === "string") v.authorRuntime = runtime;
    const model = m.agentIdentity != null ? m.agentIdentity.model : runtime === session?.runtime ? session?.model : null;
    if (typeof model === "string") v.authorModel = model;
  }
  declaredView(v, m.declared);
  return v;
}

/// serde_json's Map::remove with preserve_order: the last entry takes the removed one's place (swap_remove).
function swapRemove(v: Json, key: string): Json {
  const entries = Object.entries(v);
  const at = entries.findIndex(([k]) => k === key);
  if (at < 0) return v;
  const last = entries.pop()!;
  if (at < entries.length) entries[at] = last;
  return Object.fromEntries(entries);
}

/// A card the viewer answered, for its chat's row (`answered`).
function answeredView(a: store.CardAnswer): Json {
  const v: Json = { seq: a.question.n, text: a.question.text, askedAt: a.question.createdAt, answeredAt: a.at, card: a.card };
  if (a.answer !== null) {
    v.reply = a.answer.text;
    v.quoted = a.answer.quotes.some((q) => q.ts === a.question.ts);
  } else {
    v.closed = true;
  }
  return v;
}

/// A chat's card still pending, for its row: `seq`, the `card`, the post itself (`message`) and the two messages
/// before it (`before`), `dismissed` when the viewer will not take it up.
/// `kept`: the card's entry as kept (null: none waits), or undefined to work it out (`pendingCard`).
function cardView(api: Api, thread: number, dismissed: Set<string>, names: Names, kept?: number | null): Json | null {
  if (kept === null) return null;
  const pending = kept === undefined ? store.pendingCard(api.store, thread) : store.cardAt(api.store, thread, kept);
  if (pending === null) return null;
  const [m, card] = pending;
  const message = messageView(m, names, api.store);
  if (field(card, "type") === "options") message.options = field(card, "options");
  message.card = card;
  const before = store.messagesBefore(api.store, thread, m.n, 2).map((b) => messageView(b, names, api.store));
  const v: Json = { seq: m.n, card, message, before };
  if (dismissed.has(`${thread}:${m.n}`)) v.dismissed = true;
  return v;
}

/// What thread `thread` asks and waits on: its system cards still waiting, the latest first, then its latest
/// conversational card while it waits, by their numbers (station/mb cards.mbt `asks_waiting`).
function asksWaiting(s: Store, thread: number): number[] {
  const out = store.all(s, SYSTEM_CARDS_WAITING, thread).map((r: Json) => Number(r.n));
  const latest = store.one(s, CONVERSATION_CARD_LATEST, thread) as Json;
  if (latest === undefined || latest === null) return out;
  const n = Number(latest.n);
  if (store.one(s, ANSWER_AFTER, thread, n) !== undefined || store.one(s, "SELECT 1 AS x FROM closed_cards WHERE thread = ? AND n = ?", thread, n) !== undefined) return out;
  return [...out, n];
}

/// The card a viewer's marks show of a thread (`shown`, the one its row shows): where it is not asked of them by name
/// and another waiting there is, that one (station/mb chatmarks.mbt `mine_first`).
function mineFirst(api: Api, thread: number, dismissed: Set<string>, names: Names, email: string, shown: Json | null): Json | null {
  if (shown === null || email === "") return shown;
  const mine = (card: Json) => typeof field(card, "assignee") === "string" && (field(card, "assignee") as string).toLowerCase() === email.toLowerCase();
  if (mine(field(shown, "card"))) return shown;
  for (const n of asksWaiting(api.store, thread)) {
    if (n === Number(field(shown, "seq"))) continue;
    const at = store.cardAt(api.store, thread, n);
    if (at !== null && mine(at[1])) return cardView(api, thread, dismissed, names, n);
  }
  return shown;
}

/// serde_json's `value[key]`: null for a key it lacks or a value that is no object.
function field(v: Json, key: string): Json {
  return v !== null && typeof v === "object" && !Array.isArray(v) && key in v ? v[key] : null;
}

/// What one of a chat's agents needs a person for without a card (its last turn ended need_help), while no one has
/// written since: `seq`, `message`, the two messages before it and `dismissed`, as `card_view` gives a card.
function needView(api: Api, thread: number, agents: Json[], dismissed: Set<string>, names: Names): Json | null {
  const turn = agents
    .map((a) => field(a, "lastTurn"))
    .find((t) => {
      const ending = field(t, "ending");
      return typeof ending === "string" ? ending === "need_help" || ending === "need_decision" : field(t, "declared") === "block";
    });
  if (turn === undefined) return null;
  const about = field(turn, "about");
  const seq = about !== null && typeof about === "object" && !Array.isArray(about) && field(about, "thread") === thread && Number.isInteger(field(about, "seq")) ? field(about, "seq") : null;
  const started = field(turn, "startedAt");
  const ended = field(turn, "endedAt");
  const during: [number, number | bigint] = [Number.isInteger(started) ? started : 0, Number.isInteger(ended) ? ended : store.I64_MAX];
  const asked = store.askingMessage(api.store, thread, seq, during);
  if (asked === null) return null;
  const [m, earlier] = asked;
  const before = earlier.map((b) => messageView(b, names, api.store));
  const v: Json = { seq: m.n, message: messageView(m, names, api.store), before };
  // (whom it asks: the person it was answering, by their address)
  const asker = store.one(api.store, ASKER_BEFORE, thread, m.n) as Json;
  if (typeof field(asker, "author") === "string" && (field(asker, "author") as string).includes("@")) v.decider = (field(asker, "author") as string).toLowerCase();
  if (dismissed.has(`${thread}:${m.n}`)) v.dismissed = true;
  return v;
}

// ---- the sidebar ----

/// What a change of some sessions and threads can touch of a sidebar (`chats`), and what reading it takes: `rows`, the
/// ids of the items it can change (an item's id is its first agent's key: the sessions changed, and the agents of the
/// threads changed or theirs); `sessions` and `threads`, what those items are made of (their chats' agents, and the
/// threads those take part in, the Slack ones they came from among them).
export type Scope = {
  rows: Set<string>; sessions: Set<string>; threads: number[];
  // Only a job-name scope keeps these, for the duration of its reader's snapshot.
  jobNameMembers?: Map<number, store.Membership[]>;
  jobNameThreads?: ReturnType<typeof store.threadsForChatNames>;
};

/// How many of the archive's items a page of it has (`archivedPage`).
export const ARCHIVE_PAGE = 50;

/// GET /chats?archived=1&before=…: a page of the archive, the latest archived first, before `before` (when, and the
/// session key or chat id; none: from the latest), and where the next one goes on from (none at its end). Its items, by
/// the indexes of those archived, and their rows made of them alone (`scopeOf`). The whole archive was made at once: its
/// many chats on a station in 60 s, every other read of devices waiting behind it (2026-11-03).
export function archivedPage(station: Store, viewer: Viewer, before: [number, string] | null, limit = ARCHIVE_PAGE): Json {
  const items = store.archivedPage(station, before ?? [Number.MAX_SAFE_INTEGER, "\uffff"], limit);
  const sessions = items.filter((i) => i.kind === "s").map((i) => i.id);
  const threads = items.filter((i) => i.kind === "t").map((i) => Number(i.id));
  const rows = items.length === 0 ? [] : chats(station, viewer, true, scopeOf(station, sessions, threads));
  const last = items.at(-1);
  return { rows, next: items.length < limit || last === undefined ? null : `${last.at}:${last.id}` };
}

export function scopeOf(s: Store, sessions: string[], threads: number[]): Scope {
  const members = (ids: Iterable<number>) => {
    const out = new Set<string>();
    for (const id of ids) for (const m of store.threadSessions(s, id)) out.add(m.session);
    return out;
  };
  const touched = new Set([...threads, ...store.threadsOfSessions(s, sessions)]);
  const rows = new Set([...sessions, ...members(touched)]);
  const theirs = store.threadsOfSessions(s, [...rows]);
  const agents = new Set([...rows, ...members(theirs)]);
  return { rows, sessions: agents, threads: [...new Set([...touched, ...theirs, ...store.threadsOfSessions(s, [...agents])])] };
}

/// Only what can name a job's chat: its sessions' own chats, and external origins when one of those chats or a
/// standalone session actually needs a name from them. A shared chat can take its name from any of its members.
export function scopeOfJobNames(s: Store, keys: string[]): Scope {
  const rows = new Set(keys), agents = new Set(keys), origins = new Set<string>(), hasChat = new Set<string>();
  const jobNameMembers = new Map<number, store.Membership[]>();
  const target = new Map(keys.map((key) => [key, store.getSession(s, key)]));
  const owner = keys.length === 1 ? keys[0] : null;
  const chats = store.threadsOfSessionsOnSurface(s, keys, true);
  const checked = new Map<string, boolean>();
  let probe: ((session: string) => boolean) | null = null;
  for (const id of chats) {
    const thread = store.getThread(s, id);
    if (thread === null) continue;
    const own = owner !== null && thread.home === owner && thread.hiddenAt === null && given(thread) !== null &&
      target.get(owner)?.archivedAt === null;
    const members = (own ? store.jobNameFirstMembers(s, owner, id) : null) ?? store.threadSessions(s, id);
    jobNameMembers.set(id, members);
    for (const member of members) {
      rows.add(member.session);
      agents.add(member.session);
      const session = target.get(member.session);
      if (session && (thread.hiddenAt !== null) === (session.archivedAt !== null)) hasChat.add(member.session);
    }
    if (given(thread) === null) for (const member of members) {
      let found = checked.get(member.session);
      if (found === undefined) {
        probe ??= store.namingOriginProbe(s);
        found = probe(member.session);
        checked.set(member.session, found);
      }
      if (found) { origins.add(member.session); break; }
    }
  }
  for (const [key, session] of target) {
    if (session && (session.title === null || trim(session.title) === "") && !hasChat.has(key)) origins.add(key);
  }
  const external = new Set(store.latestNamingOrigins(s, [...origins]));
  // An origin can include a missing member; its other members still make it visible to the shared reader.
  for (const id of external) {
    const members = store.threadSessions(s, id);
    jobNameMembers.set(id, members);
    for (const member of members) agents.add(member.session);
  }
  return { rows, sessions: agents, threads: [...chats, ...external], jobNameMembers };
}

/// The sidebar items of `viewer` a change of `sessions` and `threads` can touch (`scopeOf`), as the whole sidebar has
/// them, and the ids of those that can be touched (one not among the items now is gone from the sidebar).
export function chatRows(station: Store, viewer: Viewer, sessions: string[], threads: number[]): Json {
  const scope = scopeOf(apiOf(station).store, sessions, threads);
  return { rows: chats(station, viewer, false, scope), scope: [...scope.rows] };
}

/// GET /chats?shared=1: the chat list as the station makes it for everyone (`sharedChats`), the rows the viewer sees; of
/// some sessions and threads (`scopeOf`) with the ids those can touch, as `chatRows`.
export function sharedChatRows(station: Store, viewer: Viewer, sessions: string[] | null, threads: number[] | null): Json {
  const seen = (rows: Json[]) => rows.filter((row) => sees(viewer, row.ws));
  if (sessions === null || threads === null) return seen(sharedChats(station, false));
  const of = sharedOf(station, sessions, threads);
  return { rows: seen(of.rows), scope: of.scope };
}

/// The chat list whole (`scope` null), or the rows a change of some sessions and threads can touch (`scopeOf`) and the
/// ids of those, for everyone.
export function sharedOf(station: Store, sessions: string[] | null, threads: number[] | null): { rows: Json[]; scope: string[] | null } {
  if (sessions === null || threads === null) return { rows: sharedChats(station, false), scope: null };
  const scope = scopeOf(apiOf(station).store, sessions, threads);
  return { rows: sharedChats(station, false, scope), scope: [...scope.rows] };
}

/// GET /chats?marks=1: what a device that makes the viewer's sidebar itself (client/core-ts/src/station/rows-made.ts)
/// cannot make of it from the sessions' and threads' summaries it holds, as written beside them: the cards and needs
/// waiting (`card`, `need` by thread, as `chats` gives them), the cards the viewer answered lately (`answered`), the
/// review's marks (`suggested`, `verdicts`, `reviews`), what the viewer pinned and kept (`pins`, `kept`), the chats
/// opened from each and its opener (`opened`, `openers`), who each is shared with (`shares`), client keys, the Slack
/// teams' names by connect (`teams`) and the Slack users the viewer is (`selves`). Of the shown sessions' chats, or of
/// those `threads` and `sessions` alone.
export function chatMarks(station: Store, viewer: Viewer, scope: { sessions: string[]; threads: number[] } | null = null, ownOnly = false): Json {
  // What a slow one spent where: 5.7 s for one new chat's on a station (2026-11-03), unsaid where.
  const started = performance.now();
  const stages: Record<string, number> = {};
  let last = started;
  const stage = (name: string) => {
    const now = performance.now();
    stages[name] = Math.round(now - last);
    last = now;
  };
  useNames(station);
  const api = apiOf(station);
  const s = api.store;
  const seesThread = (id: number): boolean => {
    const members = store.threadSessions(s, id);
    if (members.length === 0) return sees(viewer, null);
    return members.some((m) => {
      const x = store.getSession(s, m.session);
      return x !== null && sees(viewer, x.ws);
    });
  };
  const seesPin = (rawKey: string, anchor: string): boolean => {
    const row = store.getSession(s, anchor) ?? (rawKey !== anchor ? store.getSession(s, rawKey) : null);
    return row !== null ? sees(viewer, row.ws) : seesMissing(viewer, anchor);
  };
  const shown = (scope === null ? store.shownSessions(s) : scope.sessions.flatMap((k) => store.getSession(s, k) ?? []).filter((x) => x.archivedAt === null)).filter((x) => sees(viewer, x.ws));
  const keys = shown.map((x) => x.key);
  const threadIds = [...new Set([...(scope?.threads ?? []).filter(seesThread), ...store.threadsOfSessions(s, keys)])];
  // The chats themselves and who is in them, by their keys alone: their summaries (latest message, unread, people) are
  // the device's already, and read with them, this read took up to 73 s on a station short of memory (2026-11-03).
  const own = threadIds.flatMap((id) => {
    const thread = store.getThread(s, id);
    return thread !== null && thread.surface === STILLFAIL_SURFACE && thread.hiddenAt === null ? [{ thread, sessions: ownOnly ? [] : store.threadSessions(s, id) }] : [];
  });
  stage("found");
  const ids = own.map((t) => t.thread.id);
  const dismissed = store.dismissed(s, viewer.email, ids);
  const kept = [...store.keptChats(s, viewer.email, ids)];
  const pinMap = new Map<string, number>();
  const pinScope = scope === null ? null : (() => {
    const out = new Set(keys);
    if (keys.length > 0) {
      for (const r of s.db.prepare("SELECT key FROM sessions INDEXED BY sessions_conv_grouped WHERE conv IS NOT NULL AND conv != key AND conv IN (SELECT value FROM json_each(?))").all(JSON.stringify(keys)) as { key: string }[]) {
        out.add(r.key);
      }
    }
    return [...out];
  })();
  for (const [k, at] of store.pins(s, viewer.email, pinScope)) {
    const row = store.getSession(s, k);
    const anchor = typeof row?.conv === "string" && row.conv !== "" ? row.conv : k;
    if (!seesPin(k, anchor)) continue;
    const prev = pinMap.get(anchor);
    if (prev === undefined || at < prev) pinMap.set(anchor, at);
  }
  const pins = Object.fromEntries(pinMap);
  const selves = store.slackIdentities(s, viewer.email);
  // What is the viewer's own of the chat list (client/core-ts/src/chat-row.ts): the cards they let go, where they read.
  const reads = Object.fromEntries(store.readsOf(s, viewer.email, ids));
  const hidden = [...store.hiddenChats(s, viewer.email, ids)];
  const muted = [...store.mutedChats(s, viewer.email, ids)];
  if (ownOnly) {
    return { kept, hidden, muted, pins, selves, dismissed: [...dismissed], reads };
  }
  const listed = new Set(keys);
  const listedOne = (key: string) => {
    if (scope === null) return listed.has(key);
    const x = store.getSession(s, key);
    return x !== null && x.archivedAt === null && sees(viewer, x.ws);
  };
  const lastTurns = new Map<string, Json>();
  const lastTurnOf = (key: string) => {
    if (!lastTurns.has(key)) lastTurns.set(key, store.lastTurn(s, key));
    return lastTurns.get(key) ?? null;
  };
  const mine = isMine(api, viewer);
  const card: Json = {};
  const need: Json = {};
  const suggested: number[] = [];
  const verdicts: Json = {};
  // The review's marks of these chats, by its two small tables: a chat's last entry read only where one has any.
  const reviewed = ids.length === 0 ? new Set<number>() : new Set<number>(store.reviewedThreads(s, ids));
  // The cards they wait on as kept; a chat with a card from before they were kept, worked out as it was.
  const cards = store.pendingCards(s, ids);
  // Prepare legacy cards together: otherwise each old chat would cause the entire marks read to be retried.
  store.requireCardPosts(s, cards === null ? store.threadsWithCards(s, ids) : [...cards.before]);
  const keptCard = (id: number): number | null | undefined => (cards === null || cards.before.has(id) ? undefined : (cards.at.get(id) ?? null));
  for (const t of own) {
    const id = t.thread.id;
    // Who wrote in it, read only where something waits there to be shown with its authors.
    let known: Names | null = null;
    const namesOf = () => (known ??= authorNames(api, id));
    const names = Object.assign((kind: AuthorKind, author: string) => namesOf()(kind, author), { picture: (kind: AuthorKind, author: string) => namesOf().picture?.(kind, author) ?? null });
    const c = mineFirst(api, id, dismissed, names, viewer.email ?? "", cardView(api, id, dismissed, names, keptCard(id)));
    if (c !== null) card[id] = c;
    else {
      // its agents in lists, as its row has them (`chats`)
      const agents = t.sessions.filter((m) => listedOne(m.session)).map((m) => ({ lastTurn: lastTurnOf(m.session) }));
      const n = needView(api, id, agents, dismissed, names);
      if (n !== null) need[id] = n;
    }
    if (!reviewed.has(id)) continue;
    if (store.archiveSuggested(s, id)) suggested.push(id);
    if (api.reviews) {
      const v = store.archiveVerdict(s, id);
      if (v !== null) verdicts[id] = v;
    }
  }
  stage("waiting");
  const answered: Json = {};
  // Of the chats that ever had a card alone: each of the others' people's messages of the last day and a half was looked
  // at with half a dozen lookups for a card it answered, 3.2 s for one busy chat on a station short of memory (2026-11-03).
  const carded = store.threadsWithCards(s, ids);
  for (const a of store.answersSince(s, store.nowMs() - ANSWERED_WITHIN, carded)) {
    if (!mine(creator(a.by))) continue;
    (answered[a.question.thread] ??= []).push(answeredView(a));
  }
  stage("answered");
  const named = (o: { station: string | null; session: string; title: string | null; led?: true; active?: true }) => ({ ...(o.station !== null ? { station: o.station } : {}), session: o.session, ...(o.title !== null ? { title: o.title } : {}), ...(o.led === true ? { led: true } : {}), ...(o.active === true ? { active: true } : {}) });
  const openers = Object.fromEntries([...store.openers(s, keys)].map(([k, o]) => [k, named(o)]));
  const opened = Object.fromEntries([...store.openedChats(s, keys)].map(([k, list]) => [k, list.map(named)]));
  const shares = Object.fromEntries([...store.chatShares(s, keys)].map(([k, v]) => [k, { to: v.to.map((t) => t.workspace), write: v.write }]));
  const clientKeys = Object.fromEntries(keys.flatMap((k) => (s.clientKeys.has(k) ? [[k, s.clientKeys.get(k)!]] : [])));
  const teams = Object.fromEntries(api.connects.flatMap((c) => {
    const name = teamName(s, c.id);
    return name === null ? [] : [[c.id, name]];
  }));
  stage("rest");
  const ms = Math.round(performance.now() - started);
  if (ms >= 1_000) log.warn("readers", "a chat marks read's stages", { ms, chats: own.length, scoped: scope !== null, ...(scope !== null ? { sessions: scope.sessions.length, threads: scope.threads.length } : {}), ...stages });
  return { card, need, answered, suggested, verdicts, reviews: api.reviews, kept, hidden, muted, pins, openers, opened, shares, clientKeys, teams, selves, dismissed: [...dismissed], reads };
}

/// The viewer's sidebar: one kind of item, an agent (a shown session) merged with its internal chat. An agent in an
/// internal chat is that chat's item; one with none yet is an item without a chat. A Slack thread is no item: it lends
/// its agent's item a title (while the chat has no words of its own), the connect and the origin. `archived`: the
/// archive's items instead, each with `archived: {at, by, alone}`. Each says when the viewer pinned it (`pinned`).
///
/// `scope` (`scopeOf`): only the items whose ids it names (what a change of some sessions and threads can touch), read
/// from what they are made of alone, each as the whole list has it.
/// `titlesOnly`: the items' ids, titles and agents alone (what names a job's chat, read/jobs.ts `openJobs`): none of their
/// latest messages, cards, needs, answers or the review's marks read for them.
export function chats(station: Store, viewer: Viewer, archived: boolean, scope: Scope | null = null, titlesOnly = false): Json[] {
  // Only the chats of the viewer's workspace.
  const rows = sharedChats(station, archived, scope, titlesOnly).filter((row) => sees(viewer, row.ws));
  // (each row with what names it, `named`, and a last message that only quotes marked so: the words are the client's,
  // core-ts chat-row.ts `worded`)
  if (titlesOnly) {
    // Jobs only use each row's id, title and agents. The viewer's marks do not change any of those.
    const own: chatRow.Own = { mine: () => false, reads: new Map(), dismissed: new Set(), kept: new Set(), pins: new Map() };
    return rows.map((row) => chatRow.rowFor(row, own));
  }
  const api = apiOf(station);
  const s = api.store;
  const threads = rows.flatMap((row) => (typeof row.thread === "number" ? [row.thread as number] : []));
  const keys = rows.flatMap((row) => (typeof row.id === "string" ? [row.id as string] : []));
  const own: chatRow.Own = {
    mine: isMine(api, viewer),
    reads: store.readsOf(s, viewer.email, threads),
    dismissed: store.dismissed(s, viewer.email, scope?.threads ?? null),
    kept: store.keptChats(s, viewer.email, scope?.threads ?? null),
    hidden: store.hiddenChats(s, viewer.email, threads),
    muted: store.mutedChats(s, viewer.email, threads),
    // When the viewer pinned each to the top of their list.
    pins: (() => {
      const m = new Map<string, number>();
      const pinScope = scope === null ? null : [...new Set([
        ...keys,
        ...rows.flatMap((row) => (Array.isArray(row.agents) ? row.agents.flatMap((a: any) => (typeof a?.key === "string" ? [a.key as string] : [])) : [])),
      ])];
      for (const [k, at] of store.pins(s, viewer.email, pinScope)) {
        const row = store.getSession(s, k);
        const anchor = typeof row?.conv === "string" && row.conv !== "" ? row.conv : k;
        const prev = m.get(anchor);
        if (prev === undefined || at < prev) m.set(anchor, at);
      }
      return m;
    })(),
  };
  return rows.map((row) => chatRow.rowFor(row, own));
}

/// The chat list as the station makes it once for everyone who sees it (`chats` without a viewer): each row with its
/// workspace (`ws`), what names it (`named`: the chat or Slack thread a name is taken from, by the one rule titles.ts
/// has), who it is mine for (`mineOf`), its latest message and the latest before that its author did not write (`said`:
/// unread for a viewer read short of either not theirs), its card or need as no one let it go, and the cards answered in
/// it lately with who answered (`answeredBy`). A viewer's row is it with what is theirs (client/core-ts/src/chat-row.ts):
/// made so by a device that makes its sidebar itself, and by `chats` for one from before.
export function sharedChats(station: Store, archived: boolean, scope: Scope | null = null, titlesOnly = false): Json[] {
  useNames(station);
  const api = apiOf(station);
  const s = api.store;
  type ListedThread = { thread: ThreadRow; sessions: ThreadSummary["sessions"]; lastAt: number; summary: ThreadSummary | null };
  // For some items alone, the sessions they are made of alone: each change read every session the station ever had.
  const sessions = (
    scope === null
      // The sidebar's by the index of those not archived, not every session the station ever had.
      ? (archived ? store.listSessions(s) : store.shownSessions(s))
      : [...scope.sessions].flatMap((key) => store.getSession(s, key) ?? []).sort((a, b) => b.lastActiveAt - a.lastActiveAt)
  );
  const convOf = (x: store.SessionRow) => (typeof x.conv === "string" && x.conv !== "" ? x.conv : x.key);
  const groupedAnchors = new Set<string>();
  for (const x of sessions) {
    const a = convOf(x);
    if (a !== x.key) groupedAnchors.add(a);
  }
  const shown = new Map(sessions.filter((x) => (x.archivedAt !== null) === archived).map((x) => [x.key, x]));
  if (scope !== null) {
    for (const x of sessions) {
      if (scope.rows.has(x.key)) scope.rows.add(convOf(x));
    }
  }
  const order = sessions.filter((x) => (x.archivedAt !== null) === archived && (scope === null || scope.rows.has(x.key) || scope.rows.has(convOf(x)))).map((x) => x.key);
  // In the archive, a chat of its own shows its agents whatever they are doing elsewhere.
  const all = new Map(sessions.map((x) => [x.key, x]));
  // (a chat's own session, its thread's `home`: one put away with it, archived or hidden, whichever of the two says so;
  // two stations merged once left them apart, a chat archived shown again untitled as its session alone, 2026-11-17)
  const putAway = (t: ListedThread) => t.thread.hiddenAt !== null || (t.thread.home !== null && (all.get(t.thread.home)?.archivedAt ?? null) !== null);
  const listed = (t: ListedThread) => putAway(t) === archived;
  const inChat = (t: ListedThread): string[] => {
    const alone = archived && t.thread.home === null;
    const home = archived ? t.thread.home : null;
    return t.sessions.filter((m) => (alone ? all.has(m.session) : shown.has(m.session)) || (m.session === home && all.has(m.session))).map((m) => m.session);
  };
  const archivedOf = (x: store.SessionRow) => ({ at: x.archivedAt ?? 0, by: x.archivedBy ?? store.MANUAL, alone: false });
  const watches = titlesOnly ? new Map<string, Json>() : store.watching(s, scope === null ? null : [...scope.sessions]);
  const agent = (key: string): Json => {
    const x = all.get(key)!;
    const stat = stats.get(key);
    const v: Json = {
      key, runtime: x.runtime, model: x.model, effort: x.effort, process: s.processes.get(x.key) ?? "cold",
      pending: stat?.pending ?? 0, lastTurn: stat?.lastTurn ? turnSummary(stat.lastTurn) : null,
    };
    if (v.process === "coldFailed" || v.process === "warmFailed") {
      v.startFailed = true;
      v.process = v.process === "warmFailed" ? "warm" : "cold";
    }
    const watch = watches.get(key);
    if (watch !== undefined) v.watch = watch;
    // (it waits on work it started that is not a watch: client/core-ts chat-stage.ts keeps such a chat at work)
    if (!titlesOnly && (store.one(s, WAITS_ON_JOB, key) !== undefined || store.one(s, WAITS_ON_LED, key) !== undefined)) v.waitingAsync = true;
    return v;
  };
  // The sidebar's own threads alone; the archive's, all of them.
  const of = scope !== null ? scope.threads : archived ? null : store.threadsOfShown(s);
  const jobNameThreads = () => scope?.jobNameMembers === undefined ? store.threadsForChatNames(s, of)
    : (scope.jobNameThreads ??= store.threadsForChatNames(s, of, scope.jobNameMembers));
  const selected: ListedThread[] = titlesOnly
    ? jobNameThreads().map((t) => ({ ...t, summary: null }))
    : store.listThreads(s, "", null, of, "none").map((t) => ({ thread: t.thread, sessions: t.sessions, lastAt: t.lastMessage?.createdAt ?? 0, summary: t }));
  const threads = selected.filter((t) => t.sessions.some((m) => all.has(m.session)));
  const titleTexts = new Map<number, string | null>();
  const nameText = (t: ListedThread): string | null => {
    if (t.summary !== null) return t.summary.firstText;
    if (!titleNeedsFirstText(t.thread)) return null;
    if (!titleTexts.has(t.thread.id)) titleTexts.set(t.thread.id, store.firstText(s, t.thread.id));
    return titleTexts.get(t.thread.id) ?? null;
  };
  const stats: ReturnType<typeof store.sessionActivity> = titlesOnly ? new Map() : store.sessionActivity(s, of === null ? null : [...new Set([...(scope?.sessions ?? shown.keys()), ...threads.flatMap((t) => t.sessions.map((m) => m.session))])]);
  // Per agent: the Slack thread it came from (the latest one it is in), whether it has an internal chat, and who wrote
  // in its Slack threads (a row is mine for them).
  const origins = new Map<string, ListedThread>();
  const chatted = new Set<string>();
  const chattedConvs = new Set<string>();
  const spoke = new Map<string, Json[]>();
  for (const t of threads) {
    if (t.thread.surface === STILLFAIL_SURFACE && listed(t) && t.thread.home !== null) chattedConvs.add(t.thread.home);
    const writers = t.thread.surface !== STILLFAIL_SURFACE && t.summary !== null ? people(t.summary.people) : [];
    for (const m of t.sessions) {
      if (t.thread.surface === STILLFAIL_SURFACE) {
        if (listed(t) || t.thread.home === m.session) chatted.add(m.session);
      } else {
        if (!origins.has(m.session)) origins.set(m.session, t);
        if (writers.length > 0) spoke.set(m.session, [...(spoke.get(m.session) ?? []), ...writers]);
      }
    }
  }
  const rows: Json[] = [];
  // No one's let-go cards: a viewer's are theirs (chat-row.ts).
  const dismissed = new Set<string>();
  // The cards answered lately, by chat, with who answered.
  const answered = new Map<number, Json[]>();
  const itemThreads = threads.filter((t) => t.thread.surface === STILLFAIL_SURFACE && listed(t) && inChat(t).length > 0);
  const carded = !archived && !titlesOnly ? store.threadsWithCards(s, itemThreads.map((t) => t.thread.id)) : [];
  const cardedSet = new Set(carded);
  // Each card view below can need its old posts. Ask once for the list, rather than retrying it once per chat.
  store.requireCardPosts(s, carded);
  const saidByThread = new Map<number, ReturnType<typeof store.saidOf>>();
  const needSaid: number[] = [];
  for (const t of titlesOnly ? [] : itemThreads) {
    try { saidByThread.set(t.thread.id, store.saidOf(s, t.thread.id)); }
    catch (error) {
      if (!(error instanceof store.SaidUnavailable)) throw error;
      needSaid.push(...error.threads);
    }
  }
  if (needSaid.length) throw new store.SaidUnavailable([...new Set(needSaid)]);
  if (!archived && !titlesOnly) {
    // Only these items can show an answer, and a chat without cards cannot have one. Looking at every person's recent
    // messages first made even a change to one cardless chat read that chat's whole recent conversation.
    for (const a of store.answersSince(s, store.nowMs() - ANSWERED_WITHIN, carded)) {
      const list = answered.get(a.question.thread) ?? [];
      list.push({ ...answeredView(a), by: creator(a.by) });
      answered.set(a.question.thread, list);
    }
  }
  for (const t of itemThreads) {
    const from = t.sessions.map((m) => origins.get(m.session)).find((o) => o !== undefined) ?? null;
    const agents = inChat(t).map(agent);
    const origin_ = from === null ? null : origin(from);
    const creator_ = creator(t.thread.createdBy);
    const people_ = t.summary === null ? [] : people(t.summary.people);
    const names = titlesOnly ? null : authorNames(api, t.thread.id);
    const lastMessage = t.summary?.lastMessage ?? null;
    const lastView = names === null || lastMessage === null ? null : messageView(lastMessage, names, api.store);
    const starters = agents.map((a) => creator(all.get(a.key)?.createdBy ?? null));
    const key = t.thread.home !== null && all.has(t.thread.home) && groupedAnchors.has(t.thread.home) ? t.thread.home : agents[0].key;
    // with no name of its own, the Slack thread its agent came from names it
    const named = from !== null && origin_ !== null && given(t.thread) === null
      ? { thread: from.thread, firstText: nameText(from), channelName: origin_.channelName }
      : { thread: t.thread, firstText: nameText(t), channelName: null };
    let last: Json = null;
    if (lastView !== null) {
      const text0 = trim(typeof lastView.text === "string" ? lastView.text : "");
      // Something to show when there are no words: a message that only quotes says so (in the viewer's words).
      const quotedOnly = text0 === "" && Array.isArray(lastView.quotes) && lastView.quotes.length > 0;
      last = {
        seq: lastView.seq, authorKind: lastView.authorKind, author: lastView.author, authorName: lastView.authorName,
        text: typeof lastView.text === "string" ? takeChars(text0, LAST_CHARS) : null, createdAt: lastView.createdAt,
      };
      if (quotedOnly) last.quotedOnly = true;
      if (lastView.authorPicture !== undefined) last.authorPicture = lastView.authorPicture;
      if (lastView.agentIdentity != null) last.agentIdentity = lastView.agentIdentity;
      if (lastView.authorModel !== undefined) last.authorModel = lastView.authorModel;
      if (lastView.authorRuntime !== undefined) last.authorRuntime = lastView.authorRuntime;
    }
    const said = saidByThread.get(t.thread.id) ?? null;
    const row: Json = {
      // An item is its agent's, from its first moment to its last: the session key is its id, chat or no chat.
      id: key, session: key, thread: t.thread.id,
      title: "",
      agents,
      last,
      unread: false,
      mine: false,
      lastActiveAt: Math.max(t.thread.createdAt, t.lastAt),
      connect: from === null ? null : slackConnectOf(from),
      origin: origin_,
      // Who is in it, for the row's pictures: who started it, and everyone who wrote in it.
      creator: creator_,
      people: people_,
    };
    row.ws = (all.get(key) ?? all.get(agents[0].key))?.ws ?? null;
    row.named = named;
    row.mineOf = [creator_, ...people_, ...starters, ...agents.flatMap((a) => spoke.get(a.key) ?? [])].filter((p) => p !== null);
    row.said = said;
    row.archiveReminderDismissed = false;
    // The decision looked at it (after its agent said all done) and found nothing left to do; with the review on, only
    // such a chat is shown as one to archive (`archiveReviewed`), not every one whose agents are done.
    row.archiveRecommended = !archived && !titlesOnly && store.archiveSuggested(s, t.thread.id);
    if (api.reviews && !titlesOnly) {
      row.archiveReviewed = true;
      // What the review made of it as it stands: the option picked (and whether that recommends it), or its failure.
      const verdict = archived ? null : store.archiveVerdict(s, t.thread.id);
      if (verdict !== null) row.archiveCheck = verdict;
    }
    // The client key it was made with, while the hub remembers it.
    const clientKey = s.clientKeys.get(String(key));
    if (clientKey !== undefined) row.clientKey = clientKey;
    // The card it waits on, if any, and whether the viewer dismissed it; an options card is its `decision` too.
    const card = archived || names === null || !cardedSet.has(t.thread.id) ? null : cardView(api, t.thread.id, dismissed, names);
    if (card !== null) {
      if (field(card.card, "type") === "options") {
        const decision = swapRemove(card, "card");
        decision.options = field(card.card, "options");
        row.decision = decision;
      }
      row.card = card;
    } else if (!archived && names !== null) {
      // With no card waiting: what an agent needs a person for all the same, the message that asks.
      const need = needView(api, t.thread.id, agents, dismissed, names);
      if (need !== null) row.need = need;
    }
    const list = answered.get(t.thread.id);
    if (list !== undefined) {
      answered.delete(t.thread.id);
      row.answeredBy = list;
    }
    if (archived) {
      const home = t.thread.home === null ? undefined : all.get(t.thread.home);
      row.archived = home !== undefined && home.archivedAt !== null ? archivedOf(home)
        : { at: t.thread.hiddenAt ?? 0, by: t.thread.hiddenBy ?? store.MANUAL, alone: home === undefined };
    }
    rows.push(row);
  }
  const convOrder: string[] = [];
  const convMembers = new Map<string, string[]>();
  for (const key of order) {
    const x = shown.get(key)!;
    const anchor = convOf(x);
    if (chatted.has(key) || chattedConvs.has(anchor)) continue;
    let ms = convMembers.get(anchor);
    if (ms === undefined) { convOrder.push(anchor); convMembers.set(anchor, (ms = [])); }
    if (!ms.includes(key)) ms.push(key);
  }
  for (const anchor of convOrder) {
    const rawMs = convMembers.get(anchor)!;
    const ms = [...rawMs].sort((a, b) => {
      const ca = all.get(a)?.createdAt ?? 0;
      const cb = all.get(b)?.createdAt ?? 0;
      if (ca !== cb) return ca - cb;
      return a < b ? -1 : a > b ? 1 : 0;
    });
    const x = shown.get(anchor) ?? all.get(anchor) ?? shown.get(ms[0]!)!;
    const from = origins.get(anchor) ?? ms.map((k) => origins.get(k)).find((o) => o !== undefined) ?? null;
    const origin_ = from === null ? null : origin(from);
    const own = x.title === null ? "" : trim(x.title);
    const named = own !== "" ? { thread: { surface: STILLFAIL_SURFACE, title: own } } : from !== null && origin_ !== null ? { thread: from.thread, firstText: nameText(from), channelName: origin_.channelName } : { thread: { surface: STILLFAIL_SURFACE } };
    const starter = creator(x.createdBy);
    let lastActiveAt = x.lastActiveAt;
    const mineOf: Json[] = [];
    for (const mk of ms) {
      const mx = shown.get(mk)!;
      if (mx.lastActiveAt > lastActiveAt) lastActiveAt = mx.lastActiveAt;
      const st = creator(mx.createdBy);
      if (st !== null) mineOf.push(st);
      mineOf.push(...(spoke.get(mk) ?? []));
    }
    const peopleArr = ms.length === 1 ? (starter === null ? [] : [starter]) : from !== null && from.summary !== null && from.summary.people.length > 0 ? people(from.summary.people) : starter === null ? [] : [starter];
    const row: Json = {
      id: anchor, session: anchor, thread: null,
      title: "",
      agents: ms.map(agent),
      last: null,
      unread: false,
      mine: false,
      lastActiveAt,
      connect: x.connect === STILLFAIL_CONNECT ? null : x.connect,
      origin: origin_,
      people: peopleArr,
      creator: starter,
    };
    row.ws = x.ws;
    row.named = named;
    row.mineOf = mineOf.filter((p) => p !== null);
    if (archived) row.archived = archivedOf(x);
    rows.push(row);
  }
  // A job uses only the name and agents; its chat's links and shares are not part of that answer.
  if (titlesOnly) return scope === null ? rows : rows.filter((row) => scope.rows.has(String(row.id)));
  // Of the items read alone (a change's), theirs alone.
  const rowKeys = (row: Json): string[] => {
    const out: string[] = [];
    if (typeof row.id === "string") out.push(row.id);
    if (Array.isArray(row.agents)) for (const a of row.agents) if (typeof a?.key === "string" && !out.includes(a.key)) out.push(a.key);
    return out;
  };
  const ids = scope === null ? null : rows.flatMap((row) => (typeof row.id === "string" && scope.rows.has(row.id) ? rowKeys(row) : []));
  // When a viewer pinned it is theirs (chat-row.ts).
  for (const row of rows) row.pinned = null;
  // The chat an agent opened it from (chat_create), for its way back there: that chat's station (left out: this one),
  // session and what it was called; only for those opened so. Nothing else of the list goes by it (its order, its
  // archiving): each chat stands on its own.
  const openers = store.openers(s, ids);
  // and the chats it opened, the first first, for its own list of them
  const opened = store.openedChats(s, ids);
  const named = (o: { station: string | null; session: string; title: string | null; led?: true; active?: true }) => ({ ...(o.station !== null ? { station: o.station } : {}), session: o.session, ...(o.title !== null ? { title: o.title } : {}), ...(o.led === true ? { led: true } : {}), ...(o.active === true ? { active: true } : {}) });
  for (const row of rows) {
    if (typeof row.id !== "string") continue;
    const mkeys = rowKeys(row);
    for (const mk of mkeys) {
      const o = openers.get(mk);
      if (o) { row.opener = named(o); break; }
    }
    const children: Json[] = [];
    for (const mk of mkeys) {
      for (const c of opened.get(mk) ?? []) {
        const nc = named(c);
        if (!children.some((x) => JSON.stringify(x) === JSON.stringify(nc))) children.push(nc);
      }
    }
    if (children.length > 0) row.opened = children;
  }
  // Which other workspaces each is shared with, only those that are.
  const shares = store.chatShares(s, ids);
  for (const row of rows) {
    if (typeof row.id !== "string") continue;
    for (const mk of rowKeys(row)) {
      const shared = shares.get(mk);
      if (shared) { row.xshare = { to: shared.to.map((t) => t.workspace), write: shared.write }; break; }
    }
  }
  return scope === null ? rows : rows.filter((row) => scope.rows.has(String(row.id)));
}

// ---- thread entries ----

/// `asked.param`'s value as a number: Rust's `str::parse::<f64>`, which takes no spaces, no hex, nothing empty.
const RUST_F64 = /^[+-]?(?:inf|infinity|nan|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)$/i;
function parseF64(text: string): number | null {
  if (!RUST_F64.test(text)) return null;
  const body = text.replace(/^[+-]/, "").toLowerCase();
  const sign = text.startsWith("-") ? -1 : 1;
  if (body === "inf" || body === "infinity") return sign * Infinity;
  if (body === "nan") return NaN;
  return sign * Number(body);
}

/// Rust's `f64 as i64`: truncated, saturating, NaN 0.
function asI64(n: number): bigint {
  if (Number.isNaN(n)) return 0n;
  if (n >= 9223372036854775807) return store.I64_MAX;
  if (n <= -9223372036854775808) return -store.I64_MAX - 1n;
  return BigInt(Math.trunc(n));
}

/// GET /threads/:id/entries: `after` (an n) gives what came since (at most `limit` if given); `before` pages back; `from` and
/// `to` a gap (both included); none of them the latest page. `params`: the query's pairs, the first of a name counts
/// (admin/mod.rs `query_pairs`, `Asked::param`), or a plain map of them.
export function entries(station: Store, _viewer: Viewer, thread: number, params: Record<string, string> | [string, string][]): Json {
  useNames(station);
  const pairs = Array.isArray(params) ? params : Object.entries(params);
  const param = (name: string) => pairs.find(([k]) => k === name)?.[1];
  const api = apiOf(station);
  if (store.getThread(api.store, thread) === null) throw new HttpError(404, `unknown thread ${thread}`);
  const number = (name: string): bigint | null => {
    const v = param(name);
    if (v === undefined) return null;
    const n = parseF64(v);
    if (n !== null && Number.isFinite(n) && Math.trunc(n) === n && n >= 0) return asI64(n);
    throw new HttpError(400, `${name} must be an integer`);
  };
  const [after, before, from, to] = [number("after"), number("before"), number("from"), number("to")];
  const asked = param("limit");
  const parsedLimit = asked === undefined ? null : parseF64(asked);
  const wanted = parsedLimit === null || parsedLimit === 0 ? 50 : parsedLimit;
  // f64::clamp keeps NaN, which `as usize` makes 0.
  const limit = Number.isNaN(wanted) ? 0 : Math.trunc(Math.min(Math.max(wanted, 1), 500));
  if ((from !== null) !== (to !== null)) throw new HttpError(400, "Provide from and to together");
  const s = api.store;
  const last = store.lastEntry(s, thread);
  const found =
    after !== null ? store.entriesAfter(s, thread, after, asked === undefined ? undefined : limit) : from !== null && to !== null ? store.entriesBetween(s, thread, from, to) : store.entriesBefore(s, thread, before, limit);
  return { last, entries: entryViews(api, thread, found) };
}

/// GET /threads/:id/letters: the chat's own log of letters (store/schema.ts LETTERS), numbered from 1 in it, read as
/// its entries are (`after`, `before` with `limit`, `from` and `to`, none of them the latest page). Letters from before
/// it are among its entries, marked so.
export function letters(station: Store, _viewer: Viewer, thread: number, params: Record<string, string> | [string, string][]): Json {
  useNames(station);
  const pairs = Array.isArray(params) ? params : Object.entries(params);
  const param = (name: string) => pairs.find(([k]) => k === name)?.[1];
  const api = apiOf(station);
  if (store.getThread(api.store, thread) === null) throw new HttpError(404, `unknown thread ${thread}`);
  const number = (name: string): bigint | null => {
    const v = param(name);
    if (v === undefined) return null;
    const n = parseF64(v);
    if (n !== null && Number.isFinite(n) && Math.trunc(n) === n && n >= 0) return asI64(n);
    throw new HttpError(400, `${name} must be an integer`);
  };
  const [after, before, from, to] = [number("after"), number("before"), number("from"), number("to")];
  const asked = param("limit");
  const parsedLimit = asked === undefined ? null : parseF64(asked);
  const wanted = parsedLimit === null || parsedLimit === 0 ? 50 : parsedLimit;
  const limit = Number.isNaN(wanted) ? 0 : Math.trunc(Math.min(Math.max(wanted, 1), 500));
  if ((from !== null) !== (to !== null)) throw new HttpError(400, "Provide from and to together");
  const s = api.store;
  const last = store.lastLetter(s, thread);
  const found =
    after !== null
      ? store.lettersBetween(s, thread, BigInt.asIntN(64, after + 1n), store.I64_MAX, asked === undefined ? undefined : limit)
      : from !== null && to !== null
        ? store.lettersBetween(s, thread, from, to)
        : store.lettersBefore(s, thread, before, limit);
  return { last, letters: entryViews(api, thread, found) };
}
