// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/outflow.ts's.
//
// The statistics a Comma connect sends of the workspace (comma/stats.ts), as one station reads them of its own: what
// its agents spent and the chats they worked in (with what each asks of whom now, its link in the app, and whether a
// Comma Router wrote in it), written out field by field here, so that what the station keeps changing never changes
// what another station of another version is answered (`outflow.read`, comma/peer.ts, named so as stations of every
// version answer it). The chats of one workspace of the station's (its home one, unless another station of a workspace
// it joined asks).
import type { Json, Store } from "./store.ts";
import * as store from "./store.ts";
import { SYSTEM_CARD_WAITING } from "../../src/store/card-kinds.ts";
import { cardOf, cardOfEntry, ending, sees, takeChars } from "../../src/store/rows.ts";
import { outflowChatIndexReady, outflowChatScopes } from "./backfill/outflow-index.ts";
import { titleNeedsFirstText, titleOf } from "./views.ts";
import { slackCreator } from "./slack-known.ts";
import { usage } from "./usage.ts";
import type { Lang } from "../../src/ops/i18n.ts";
import { type PageBase, sessionPage } from "../../src/sessions/page.ts";
import { OUTFLOW_CHATS_PENDING } from "../../src/read/outflow.ts";

export * from "../../src/read/outflow.ts";
export { OUTFLOW_CHATS_PENDING };

/// Which workspace's chats are read, as `sees` takes a viewer.
export type Of = { workspace: string; home: boolean };

/// The home workspace: its chats are those of no other workspace.
export const HOME: Of = { workspace: "\u0000home", home: true };

/// Who a person reference is, as far as known: their name and email, and where they were heard (`slack`, `feishu`,
/// `cloud`, `local`). A chat app's person whose name is not known has none here, not their id.
function person(s: Store, ref: string): Json {
  const chat = slackCreator(s, ref);
  if (chat !== null) return { name: ref.endsWith(`:${chat.name}`) ? null : chat.name, email: chat.email, via: chat.via };
  if (ref === "local") return { name: null, email: null, via: "local" };
  return { name: null, email: ref, via: "cloud" };
}

/// v1 `usage`: the model calls from `from` until `to` (ms), added up by day in UTC+`tz` minutes, chat, session, person,
/// account and model, with what they cost at list prices (null for a model without one); `people` the rows' persons.
export function outflowUsage(s: Store, lang: Lang, from: number, to: number, tz: number, of: Of = HOME): Json {
  // The export has no remote-task field, so it need not wait for or read those statistics.
  const read = usage(s, lang, BigInt(from), BigInt(to), BigInt(tz), false, of, false, { remoteRuns: false, metadata: false }) as Json;
  const rows = (read.rows as Json[]).map((r) => ({
    day: r.day, thread: r.thread, session: r.session, person: r.person, account: r.profile, runtime: r.runtime, model: r.model,
    calls: r.calls, input: r.input, cacheRead: r.cacheRead, cacheWrite: r.cacheWrite, output: r.output, cost: r.cost,
  }));
  const people: Record<string, Json> = {};
  for (const r of rows) if (r.person !== null && !(r.person in people)) people[r.person] = person(s, r.person);
  return { from, to, tz, since: read.since ?? null, rows, people };
}

/// How a chat stands, by its agents' latest turn: `working` while one runs, else how it said it ended (`all_done`,
/// `need_human`, `waiting`), `ended` when it said nothing.
function state(turn: Json | null): string | null {
  if (turn === null) return null;
  if (turn.outcome === null || turn.outcome === undefined) return "working";
  if (typeof turn.declared !== "string") return "ended";
  const said = ending(turn.declared);
  return said === "need_help" ? "need_human" : said;
}

const isObj = (v: unknown): v is Record<string, Json> => v !== null && typeof v === "object" && !Array.isArray(v);

/// A message's card as Comma and the Router read it: its kind and conversational choices or hint, never internal ids or
/// credentials.
export function outflowCard(card: Json): Json | null {
  if (!isObj(card)) return null;
  if (card.type === "login") return { type: "login" };
  if (isObj(card.vault)) return { type: "secret" };
  if (isObj(card.adb)) return { type: "device" };
  if (isObj(card.rig)) return { type: "rig" };
  if (isObj(card.signin)) return { type: "signin" };
  if (card.type === "options") {
    const raw = Array.isArray(card.options) ? card.options : [];
    const options = raw
      .filter((o): o is Record<string, Json> => isObj(o) && typeof o.label === "string" && o.label.trim() !== "")
      .slice(0, 6)
      .map((o) => ({
        label: takeChars(o.label.trim(), 100),
        ...(typeof o.detail === "string" && o.detail.trim() !== "" ? { detail: takeChars(o.detail.trim(), 300) } : {}),
        ...(o.recommended === true ? { recommended: true } : {}),
        ...(o.action === "close" ? { action: "close" } : {}),
      }));
    return { type: "options", options };
  }
  if (card.type === "text") {
    const placeholder = typeof card.placeholder === "string" && card.placeholder.trim() !== "" ? takeChars(card.placeholder.trim(), 200) : null;
    return { type: "text", ...(placeholder === null ? {} : { placeholder }) };
  }
  return null;
}

/// The assignee and kind of the card on message `n` of `thread`, as it names them: by its key.
function cardInfoAt(s: Store, thread: unknown, n: unknown): { assignee: string | null; card: string | null } {
  const r = s.db.prepare("SELECT card, options FROM entries WHERE thread = ? AND n = ? AND kind = 'message'").get(thread as number, n as number) as { card: string | null; options: string | null } | undefined;
  if (r === undefined) return { assignee: null, card: null };
  const raw = cardOf(r.card, r.options);
  const assignee = isObj(raw) && typeof raw.assignee === "string" && raw.assignee.trim() !== "" ? raw.assignee.trim().toLowerCase() : null;
  const card = outflowCard(raw)?.type ?? null;
  return { assignee, card };
}

/// Whether a chat's latest message (that is not a letter) is one its creator has not read: past where they read it
/// to in the app, and not theirs. Each by its key (thread_state, the message, their read mark).
function unreadBy(s: Store, thread: number, ref: string, email: string): boolean {
  const said = s.db.prepare(`SELECT e.n, e.author_kind, e.author FROM thread_state t JOIN entries e ON e.thread = t.thread AND e.n = t.said_n
    WHERE t.thread = ?`).get(thread) as { n: number; author_kind: string; author: string } | undefined;
  if (said === undefined) return false;
  if (said.author_kind === "person" && (said.author === ref || said.author.toLowerCase() === email)) return false;
  const read = s.db.prepare("SELECT MAX(n) AS n FROM reads WHERE viewer IN (?1, lower(?1)) AND thread = ?2").get(email, thread) as { n: number | null };
  return said.n > (read.n ?? 0);
}

/// What a chat asks of someone now, by its agents' latest turn; null when nothing (and for an archived chat):
/// - `need`: it ended needing a person (need_human). For whoever decides the card the need is about (its assignee),
///   else whoever started the chat; its words the need, and `card` when a card waits.
/// - `done`: it ended all done and whoever started it has not read its latest message in the app (a still.fail chat:
///   a Slack or Feishu thread is read there, which the station does not know). Its words what was done.
/// - `failed`: it failed without saying how it ended, for whoever started it; its words the failure's first line.
/// `waitsFor`: the emails of who it is for, as far as known.
function attentionOf(s: Store, thread: store.ThreadRow, latest: Json | null, creator: string | null, email: string | null): Json | null {
  if (latest === null || thread.hiddenAt !== null) return null;
  const said = state(latest);
  const mine = email === null ? [] : [email.toLowerCase()];
  const words = (v: unknown) => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);
  if (said === "need_human") {
    const about = latest.about;
    let info = isObj(about) ? cardInfoAt(s, about.thread ?? null, about.seq ?? null) : { assignee: null, card: null };
    if (info.card === null) {
      const sys = s.db.prepare(SYSTEM_CARD_WAITING).get(thread.id) as { n: number } | undefined;
      if (sys !== undefined) {
        const waiting = cardInfoAt(s, thread.id, Number(sys.n));
        info = { assignee: info.assignee ?? waiting.assignee, card: waiting.card };
      }
    }
    return {
      kind: "need",
      waitsFor: info.assignee !== null ? [info.assignee] : mine,
      note: words(latest.need),
      ...(info.card !== null ? { card: info.card } : {}),
    };
  }
  if (said === "all_done") {
    if (email === null || creator === null || thread.surface !== store.STILLFAIL_SURFACE) return null;
    return unreadBy(s, thread.id, creator, email.toLowerCase()) ? { kind: "done", waitsFor: mine, note: words(latest.need) } : null;
  }
  if (latest.outcome === "failed" && latest.declared === null) {
    const detail = words(latest.detail);
    return { kind: "failed", waitsFor: mine, note: detail === null ? null : words(detail.split("\n")[0]) };
  }
  return null;
}

/// Whether a Comma Router ever wrote in still.fail chat `thread`, by one keyed range of who wrote in it (thread_people,
/// kept by the entries' trigger, so of all its history and gone only with its entries). Its writes are the only
/// person messages of a still.fail chat named `slack:<connect>:<requester>` (comma/chats.ts routerSaysOnce); people
/// write there as their email (lifecycle.ts `say`), and the Router writes in no other chat.
export const ROUTER_WROTE = "SELECT author FROM thread_people WHERE thread = ? AND author >= 'slack:' AND author < 'slack;' LIMIT 64";
const ROUTER_CONNECTS_SQL = "SELECT connect FROM comma_router_connects WHERE thread = ? ORDER BY connect LIMIT 64";
const TASK_PARTICIPANTS_SQL = "SELECT connect, email FROM comma_task_participants WHERE thread = ? ORDER BY connect, email LIMIT 128";

const MAX_PARTICIPANTS = 32;
const MAX_ROUTER_CONNECTS = 32;
const MAX_PARTICIPANT_TEXT = 200;
export const PARTICIPANTS_OF = "SELECT author FROM thread_people WHERE thread = ? LIMIT 64";

function legacyRouterConnect(author: string): string | null {
  if (!author.startsWith("slack:")) return null;
  const rest = author.slice(6);
  const colon = rest.indexOf(":");
  return colon > 0 ? rest.slice(0, colon) : null;
}

function routerConnectsOf(s: Store, threadId: number, hasTable: boolean): { router: boolean; routerConnects: string[] } {
  const recorded: string[] = [];
  if (hasTable) {
    for (const row of s.db.prepare(ROUTER_CONNECTS_SQL).all(threadId) as { connect: unknown }[]) {
      if (typeof row.connect !== "string") continue;
      const trimmed = row.connect.trim();
      if (trimmed !== "" && trimmed.length <= MAX_PARTICIPANT_TEXT && !recorded.includes(trimmed)) recorded.push(trimmed);
    }
  }
  const slackRows = s.db.prepare(ROUTER_WROTE).all(threadId) as { author: unknown }[];
  const hasAnySlack = slackRows.length > 0;
  const combined = [...recorded];
  for (const row of slackRows) {
    if (typeof row.author !== "string") continue;
    const cid = legacyRouterConnect(row.author);
    if (cid === null) continue;
    const suffix = `/${cid}`;
    if (!recorded.some((r) => r === cid || r.endsWith(suffix)) && cid.length <= MAX_PARTICIPANT_TEXT && !combined.includes(cid)) {
      combined.push(cid);
    }
  }
  if (combined.length === 0) return { router: hasAnySlack, routerConnects: [] };
  combined.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return { router: true, routerConnects: combined.slice(0, MAX_ROUTER_CONNECTS) };
}

function connectParticipantsOf(s: Store, threadId: number, hasTable: boolean): Record<string, string[]> | null {
  if (!hasTable) return null;
  const grouped = new Map<string, string[]>();
  for (const row of s.db.prepare(TASK_PARTICIPANTS_SQL).all(threadId) as { connect: unknown; email: unknown }[]) {
    if (typeof row.connect !== "string" || typeof row.email !== "string") continue;
    const connect = row.connect.trim();
    const email = row.email.trim().toLowerCase();
    if (connect === "" || connect.length > MAX_PARTICIPANT_TEXT || !/^[^\s@]+@[^\s@]+$/.test(email) || email.length > MAX_PARTICIPANT_TEXT || email.includes(":")) continue;
    let list = grouped.get(connect);
    if (list === undefined) {
      if (grouped.size >= MAX_ROUTER_CONNECTS) continue;
      list = [];
      grouped.set(connect, list);
    }
    if (list.length < MAX_PARTICIPANTS && !list.includes(email)) list.push(email);
  }
  if (grouped.size === 0) return null;
  const out: Record<string, string[]> = {};
  for (const [connect, emails] of grouped) if (emails.length > 0) out[connect] = emails;
  return Object.keys(out).length > 0 ? out : null;
}

/// The human participant emails of `thread`: its creator (if a valid email) plus anyone who spoke in it via
/// `thread_people` (excluding the Comma Router and non-email ids), lowercase, distinct, at most MAX_PARTICIPANTS.
function participantsOf(s: Store, thread: store.ThreadRow, connect: string | null, creatorEmail: string | null, resolve: (ref: string) => Json): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const add = (raw: string) => {
    const email = raw.trim().toLowerCase();
    if (/^[^\s@]+@[^\s@]+$/.test(email) && email.length <= MAX_PARTICIPANT_TEXT && out.length < MAX_PARTICIPANTS && !seen.has(email)) {
      seen.add(email);
      out.push(email);
    }
  };
  if (creatorEmail !== null) add(creatorEmail);
  const isChat = thread.surface === store.STILLFAIL_SURFACE;
  for (const row of s.db.prepare(PARTICIPANTS_OF).all(thread.id) as { author: unknown }[]) {
    if (out.length >= MAX_PARTICIPANTS) break;
    if (typeof row.author !== "string") continue;
    if (isChat) {
      if (row.author.startsWith("slack:") || row.author === "local") continue;
      add(row.author);
    } else if (connect !== null) {
      const e = resolve(`slack:${connect}:${row.author}`)?.email;
      if (typeof e === "string" && e !== "") add(e);
    }
  }
  return out;
}

/// A page of chats: at most `limit`, those after `before` (the `next` of the page before).
export type ChatsPage = { limit: number; before: string | null };

/// A scope's next chats: the compound seek starts at the cursor, including when many chats share a timestamp.
export const OUTFLOW_CHAT_PAGE = `SELECT thread, at FROM outflow_chat_order INDEXED BY outflow_chat_scope_order
  WHERE scope = ?1 AND dirty = 0 AND at >= ?2 AND (at, thread) < (?3, ?4) ORDER BY at DESC, thread DESC LIMIT ?5`;
const OUTFLOW_CHAT_FIRST = `SELECT thread, at FROM outflow_chat_order INDEXED BY outflow_chat_scope_order
  WHERE scope = ?1 AND dirty = 0 AND at >= ?2 ORDER BY at DESC, thread DESC LIMIT ?3`;

/// v1 `chats`: the chats with something new since `since` (ms), the latest active first: each one's thread (what
/// `usage` rows name), where it is (`stillfail`, `slack`, `feishu`), title, how it stands, who started it, when, its
/// latest activity, whether it is archived, and its agents' runtimes and models; what it asks of whom now
/// (`attention`, attentionOf: absent when nothing) and, given where this station's pages are (`pages`), its link in the
/// app (`url`, the page of its latest turn's session); `router: true` when a Comma Router ever wrote in it (routerWrote:
/// absent when not). With `page`, at most its `limit`, `more` when there are more and `next` to ask for them with;
/// without, all of them.
export function outflowChats(s: Store, since: number, of: Of = HOME, page: ChatsPage | null = null, pages: PageBase | null = null): Json {
  // The read and this coverage check share the reader's snapshot. A concurrent write is settled before a retry.
  if (!outflowChatIndexReady(s.db, of)) throw new Error(OUTFLOW_CHATS_PENDING);
  const [at, beforeThread] = (page?.before ?? "").split(".").map(Number);
  const cursor = page?.before != null && Number.isFinite(at) && Number.isFinite(beforeThread);
  const limit = page === null ? -1 : page.limit + 1;
  const candidates = new Map<number, { thread: number; at: number }>();
  for (const scope of outflowChatScopes(of)) {
    const rows = (cursor
      ? s.db.prepare(OUTFLOW_CHAT_PAGE).all(scope, since, at!, beforeThread!, limit)
      : s.db.prepare(OUTFLOW_CHAT_FIRST).all(scope, since, limit)) as { thread: number; at: number }[];
    for (const row of rows) candidates.set(row.thread, row);
  }
  const ordered = [...candidates.values()].sort((a, b) => b.at - a.at || b.thread - a.thread);
  const more = page !== null && ordered.length > page.limit;
  const threads = page === null ? ordered : ordered.slice(0, page.limit);
  const sessions = new Map<string, ReturnType<typeof store.getSession>>();
  // Outflow needs no viewer's unread count, people list, letters or message bodies. A sidebar summary computes those
  // from the chat's messages, including an unread count that grows with its history.
  const listed = threads.flatMap(({ thread: id, at: lastActiveAt }) => {
    const thread = store.getThread(s, id);
    if (thread === null) return [];
    const allMembers = store.threadSessions(s, id);
    let connect: string | null = null;
    for (const m of allMembers) if (typeof m.connect === "string" && (connect === null || m.connect < connect)) connect = m.connect;
    const members = allMembers.filter((m) => {
      if (!sessions.has(m.session)) sessions.set(m.session, store.getSession(s, m.session));
      const session = sessions.get(m.session);
      return session !== null && session !== undefined && sees(of, session.ws ?? null);
    });
    if (members.length === 0) return [];
    return [{ thread, members, lastActiveAt, connect }];
  });
  // Outflow only uses the latest turn. A full session summary also counts pending deliveries, which may be unbounded.
  const turnsBySession = new Map<string, ReturnType<typeof store.lastTurn>>();
  for (const { members } of listed) for (const { session } of members)
    if (!turnsBySession.has(session)) turnsBySession.set(session, store.lastTurn(s, session));
  const peopleCache = new Map<string, Json>();
  const resolvePerson = (ref: string) => (peopleCache.has(ref) ? peopleCache.get(ref) : peopleCache.set(ref, person(s, ref)).get(ref));
  const hasRouterConnects = s.db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'comma_router_connects'").get() !== undefined;
  const hasTaskParticipants = s.db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'comma_task_participants'").get() !== undefined;
  const chats: Json[] = [];
  for (const { thread, members, lastActiveAt, connect } of listed) {
    const turns = members.map((m) => turnsBySession.get(m.session) ?? null).filter((x): x is NonNullable<typeof x> => x !== null);
    const latest = turns.sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0))[0] ?? null;
    const creator = thread.createdBy ?? sessions.get(members[0]!.session)?.createdBy ?? null;
    const who = creator === null ? null : { ref: creator, ...resolvePerson(creator) };
    const creatorEmail = typeof who?.email === "string" && who.email !== "" ? who.email : null;
    const attention = attentionOf(s, thread, latest, creator, creatorEmail);
    const participants = participantsOf(s, thread, connect, creatorEmail, resolvePerson);
    const isChat = thread.surface === store.STILLFAIL_SURFACE;
    const routerInfo = isChat ? routerConnectsOf(s, thread.id, hasRouterConnects) : { router: false, routerConnects: [] };
    const connectParticipants = isChat ? connectParticipantsOf(s, thread.id, hasTaskParticipants) : null;
    const lead = members.find((m) => latest !== null && turnsBySession.get(m.session) === latest)?.session ?? members[0]!.session;
    const url = pages === null ? null : sessionPage(pages, sessions.get(lead)?.ws ?? pages.workspace, lead);
    chats.push({
      thread: thread.id,
      surface: thread.surface === store.STILLFAIL_SURFACE ? "stillfail" : thread.surface,
      title: titleOf(thread, titleNeedsFirstText(thread) ? store.firstText(s, thread.id) : null, null),
      state: state(latest),
      creator: who,
      createdAt: thread.createdAt,
      lastActiveAt,
      archived: thread.hiddenAt !== null,
      agents: members.map((m) => ({ runtime: sessions.get(m.session)!.runtime, model: sessions.get(m.session)!.model })),
      ...(attention === null ? {} : { attention }),
      ...(url === null ? {} : { url }),
      ...(routerInfo.router ? { router: true } : {}),
      ...(routerInfo.routerConnects.length > 0 ? { routerConnects: routerInfo.routerConnects } : {}),
      ...(connectParticipants !== null ? { connectParticipants } : {}),
      ...(participants.length > 0 ? { participants } : {}),
    });
  }
  if (page === null) return { since, chats };
  const last = chats.at(-1);
  return { since, chats, more, next: more && last ? `${last.lastActiveAt}.${last.thread}` : null };
}

function outflowText(text: string | null, quotes: { text: string; comment: string }[]): string | null {
  if (quotes.length === 0) return text;
  const hasText = typeof text === "string" && text.trim() !== "";
  const blocks: string[] = [];
  for (const q of quotes) {
    const comment = q.comment.trim();
    if (hasText && comment === "") continue;
    const parts: string[] = [];
    if (q.text.trim() !== "") {
      parts.push(
        q.text
          .replace(/\r\n?/g, "\n")
          .split("\n")
          .map((line) => (line === "" ? ">" : `> ${line}`))
          .join("\n"),
      );
    }
    if (comment !== "") {
      parts.push(comment);
    }
    if (parts.length > 0) blocks.push(parts.join("\n\n"));
  }
  if (blocks.length === 0) return text;
  if (hasText) blocks.push(text as string);
  return blocks.join("\n\n");
}

/// A chat's messages after its message `after` (its `n`), at most `limit`, oldest first, as the Router reads a Task
/// through a Comma connect (`task.read`): each one's `n`, what it is (`message`, `edit`: a later wording of message
/// `target`), who wrote it (`person`, `agent`, and their reference, a person's name and email as far as known), its words
/// and when; `last`, the chat's latest `n`, and `more` when there are more after these. Null for a chat that is not the
/// workspace's. A newer Router asks for messages alone; without that option old peers still receive entries and edits.
export function outflowMessages(s: Store, thread: number, after: number, limit: number, of: Of = HOME, messagesOnly = false): Json {
  if (store.getThread(s, thread) === null || !store.seesThread(s, of, thread)) return null;
  const entries = messagesOnly
    ? store.messageEntriesAfter(s, thread, BigInt(after), limit + 1)
    : store.entriesAfter(s, thread, BigInt(after), limit + 1);
  const page = entries.slice(0, limit);
  const people = new Map<string, Json>();
  const named = (ref: string) => (people.has(ref) ? people.get(ref) : people.set(ref, person(s, ref)).get(ref));
  return {
    thread,
    messages: page.map((e) => {
      let card = e.kind === "message" ? outflowCard(cardOfEntry(e)) : null;
      if (card !== null) {
        const chosen = s.db.prepare("SELECT option FROM card_choices WHERE thread = ? AND n = ?").get(thread, e.n) as { option?: unknown } | undefined;
        const choice = typeof chosen?.option === "string" && chosen.option.trim() !== "" ? chosen.option : null;
        const closed = choice !== null || s.db.prepare("SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?").get(thread, e.n) !== undefined;
        if (closed) card = { ...card, closed: true, ...(choice !== null ? { choice } : {}) };
      }
      return {
        n: e.n, kind: e.kind, target: e.target, authorKind: e.authorKind, author: e.author, text: outflowText(e.text, e.quotes), at: e.at,
        ...(e.authorKind === "person" && typeof e.author === "string" ? { person: named(e.author) } : {}),
        ...(card !== null ? { card } : {}),
      };
    }),
    last: store.lastEntry(s, thread),
    more: entries.length > page.length,
    ...(messagesOnly ? { messagesOnly: true } : {}),
  };
}
