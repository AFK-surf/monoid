// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/notices.ts's.
//
// What the people of a chat hear about while no client of theirs runs: an
// agent's turn ending in one of the station's own chats (done with something said, or blocked), something going wrong
// there (the station says so, ⚠️ first), and a person saying something there. Worked out here, off the main thread,
// from a store change the station saw; the station posts them to still.fail cloud (src/cloud/notify.ts).
import { type Lang, tr as translate } from "../../src/ops/i18n.ts";
import { type EntryRow, type MessageRow, STILLFAIL_SURFACE, type Store, type TurnSummary } from "./store.ts";
import * as store from "./store.ts";
import { apiOf, authorNames, people, titleOf, useNames } from "./views.ts";
import { wall } from "../../src/ops/fibers.ts";
import { STATION_AUTHOR } from "../../src/store/rows.ts";
import { ASKER_BEFORE } from "../../src/store/card-kinds.ts";
import { type Notice } from "../../src/read/notices.ts";

export * from "../../src/read/notices.ts";
export { type Notice };

/// How long a notice's text is kept, in characters (still.fail cloud cuts it shorter).
const TEXT = 400;

/// What a turn's end is worth telling its chat, and in what words: blocked on something new it asks (`fresh`: see
/// store.blockedAsk), or done having said something there (the chat's last message is the agent's, from this turn). A
/// turn blocked on what was already told, or on nothing that waits for anyone, is told as one that ended done. Any other
/// end says nothing; a failed one, the station's ⚠️ does.
export function turnNotice(turn: TurnSummary, last: MessageRow | null, key: string, file: string, fresh: boolean): [string, string] | null {
  const theirs = last !== null && last.authorKind === "agent" && last.author === key && last.createdAt >= (turn.startedAt as number) ? last : null;
  const text = theirs !== null && theirs.text.trim() !== "" ? theirs.text : null;
  if (turn.declared === "block" && fresh) {
    const need = typeof turn.need === "string" && turn.need.trim() !== "" ? turn.need : null;
    return ["block", need ?? text ?? ""];
  }
  if (turn.outcome === "failed") return null;
  if (turn.declared === "final" || turn.declared === "block") return theirs !== null ? ["done", text ?? file] : null;
  return null;
}

/// The station's word in a chat that something went wrong (⚠️ first, as the session posts it): what went wrong.
export function wentWrong(text: string): string | null {
  // Its first paragraph: what it means; what failed said, under it, is for the chat.
  return text.startsWith("⚠️") ? text.slice("⚠️".length).split("\n\n")[0]!.trim() : null;
}

/// The emails of a chat's people: who made it, who said something in it, who started its agents; but `except`.
function emailsOf(s: Store, creator: string | null, said: string[], sessions: string[], except: string | null): string[] {
  const starters = sessions.flatMap((k) => store.getSession(s, k)?.createdBy ?? []);
  const refs = [...(creator === null ? [] : [creator]), ...said, ...starters];
  const not = except?.toLowerCase() ?? null;
  const seen = new Set<string>();
  return people(refs)
    .flatMap((p) => (typeof p.email === "string" ? [p.email.toLowerCase()] : []))
    .filter((e) => e !== not && !seen.has(e) && (seen.add(e), true));
}

/// A notice of a chat: its name and whom to tell, each looked up alone. As lists have the chat, its every message was
/// counted besides (unread, for no one): many pages of a chat of many messages, 3 to 16 s each time on a station short of
/// memory (2026-11-02), every telling after it waiting.
function notice(s: Store, thread: number, seq: number | null, session: string, kind: string, by: string, text: string, except: string | null, only: string | null = null): Notice | null {
  const t = store.getThread(s, thread);
  if (t === null) return null;
  const sessions = store.threadSessions(s, thread).map((m) => m.session);
  // (what a card asks of one person, its assignee, is told to them alone)
  const recipients = only !== null ? [only.toLowerCase()] : emailsOf(s, t.createdBy, store.threadPeople(s, thread, t.surface), sessions, except);
  const muted = store.mutedViewers(s, thread, recipients);
  const to = recipients.filter((email) => !muted.has(email));
  if (to.length === 0) return null;
  // Our own chats use their given title or the untitled label, never the first message (core's chatTitle rule).
  const first = t.surface === STILLFAIL_SURFACE ? null : store.firstText(s, thread);
  return { to, kind, session, thread, seq, title: titleOf(t, first, null), by, text: [...text].slice(0, TEXT).join(""), at: wall.now() };
}

/// Whoever started a chat, by their address (null: no one the workspace knows).
function starterOf(createdBy: string | null): string | null {
  if (createdBy === null) return null;
  const email = people([createdBy]).find((p) => typeof p.email === "string")?.email;
  return typeof email === "string" ? email : null;
}

/// Whom what a chat asks now is asked of (its last message, at `n`, the asking one): its card's assignee; for what an
/// agent needs with no card, the person it was answering (card-kinds.ts ASKER_BEFORE); else whoever started it.
function askedOf(s: Store, thread: number, createdBy: string | null, n: number | null): string | null {
  const card = store.pendingCard(s, thread);
  if (card !== null && card !== undefined) {
    const assignee = card[1]?.assignee;
    return typeof assignee === "string" && assignee.includes("@") ? assignee : starterOf(createdBy);
  }
  const asker = n === null ? undefined : store.one(s, ASKER_BEFORE, thread, n) as { author?: unknown } | undefined;
  if (typeof asker?.author === "string" && asker.author.includes("@")) return asker.author;
  return starterOf(createdBy);
}

/// A session changed: its last turn, if it ended since `since` and is not `ended` (the end already told), told to its
/// chats. Gives the end it saw.
export function turnNotices(s: Store, key: string, since: number, ended: number | null, lang: Lang): { ended: number | null; notices: Notice[] } {
  useNames(s);
  const turn = store.lastTurn(s, key);
  const at = turn?.endedAt;
  if (turn === null || typeof at !== "number" || at < since) return { ended, notices: [] };
  if (at === ended) return { ended, notices: [] };
  // A chat another chat's agent leads (chat_create for me) asks that agent, not its people: they are told nothing.
  if (store.one(s, "SELECT 1 FROM opened_chats WHERE child_station = '' AND child = ? AND led = 1", key) !== undefined) return { ended: at, notices: [] };
  const api = apiOf(s);
  const missing: number[] = [];
  const found: { thread: ReturnType<typeof store.sessionThreads>[number]; last: MessageRow | null }[] = [];
  for (const thread of store.sessionThreads(s, key, STILLFAIL_SURFACE)) {
    if (thread.hiddenAt !== null) continue;
    let last: MessageRow | null;
    try { last = store.lastMessage(s, thread.id); }
    catch (error) {
      if (!(error instanceof store.LastMessageUnavailable)) throw error;
      missing.push(...error.threads);
      continue;
    }
    found.push({ thread, last });
  }
  if (missing.length) throw new store.LastMessageUnavailable([...new Set(missing)]);
  const out: Notice[] = [];
  for (const { thread, last } of found) {
    const fresh = turn.declared === "block" && store.blockedAsk(s, thread.id, key, turn)?.fresh === true;
    const told = turnNotice(turn, last, key, translate(lang, "station.notice.file"), fresh);
    if (told === null) continue;
    const by = authorNames(api, thread.id)("agent", key) ?? "";
    const asked = told[0] === "block" ? askedOf(s, thread.id, thread.createdBy, last?.n ?? null) : null;
    const n = notice(s, thread.id, last?.n ?? null, key, told[0], by, told[1], null, asked);
    if (n !== null) out.push(n);
  }
  return { ended: at, notices: out };
}

/// Entries written in a chat: a person's message (the chat's other people hear it), the station saying something
/// went wrong (everyone does).
export function saidNotices(s: Store, id: number, entries: EntryRow[], since: number, lang: Lang): Notice[] {
  useNames(s);
  const fresh = entries.filter((e) => e.kind === "message" && e.at >= since);
  const person = fresh.filter((e) => e.authorKind === "person").at(-1);
  const wrong = fresh.filter((e) => e.authorKind === STATION_AUTHOR).flatMap((e) => {
    const what = e.text === null ? null : wentWrong(e.text);
    return what === null ? [] : [{ n: e.n, what }];
  }).at(-1);
  if (person === undefined && wrong === undefined) return [];
  const thread = store.getThread(s, id);
  if (thread === null || thread.surface !== STILLFAIL_SURFACE || thread.hiddenAt !== null) return [];
  const session = store.threadSessions(s, id)[0]?.session;
  if (session === undefined) return [];
  const out: Notice[] = [];
  if (person !== undefined) {
    const by = authorNames(apiOf(s), id, translate(lang, "station.author.admin"))("person", person.author) ?? person.author;
    const text = person.text !== null && person.text.trim() !== "" ? person.text : translate(lang, "station.notice.file");
    const n = notice(s, id, person.n, session, "message", by, text, person.author);
    if (n !== null) out.push(n);
  }
  const starter = starterOf(thread.createdBy);
  if (wrong !== undefined && starter !== null) {
    const n = notice(s, id, wrong.n, session, "failed", "", wrong.what, null, starter);
    if (n !== null) out.push(n);
  }
  return out;
}
