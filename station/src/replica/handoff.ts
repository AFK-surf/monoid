// One chat of a station that does not answer, gone on with on this station from its copy (replica/AGENTS.md "One chat
// from a copy"): a member asks this station (B) to continue chat `thread` of station `origin` (A) of their workspace
// (POST /copies/handoff). B refuses while A answers: the chat goes on there, or moves with a hand-over (handover.ts). Else
// B asks the stations that could keep A's copy what they hold of it (`replica.held`, its heads alone), and asks first
// the one with the newest copy, then the others (among equals itself first, then in the order they keep it, `ranked`);
// the one asked reads that chat alone from its copy's newest generation (chat.ts, `replica.chat`) and answers. B opens
// a new chat of its own for the member, its first message a handoff prompt made of that reading. Nothing of A's rows
// goes into B's store, A's chat stays as it is, and nothing comes back when A answers again: the two chats go on apart.
import { iso } from "../read/transcript.ts";
import { log } from "../ops/log.ts";
import { type Lang, tr } from "../ops/i18n.ts";
import type { Hub } from "../sessions/hub.ts";
import { newSession, say } from "../sessions/lifecycle.ts";
import { type Candidate, type Used, USED_WITHIN_MS, candidates, choose } from "../sessions/model-choice.ts";
import { sameModel } from "../sessions/config.ts";
import { runtimeKind } from "../agents/runtime.ts";
import { chars } from "../agents/live.ts";
import { STATION } from "./format.ts";
import type { Held } from "./places.ts";
import { type Ask, PeerPlace, ranked } from "./peers.ts";
import { type ChatCopy, type ChatEntry, type ChatReading, newestWhole } from "./chat.ts";

/// A refusal of a handoff, in the asker's words, with the status the route answers it with.
export class HandoffRefused extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/// What a handoff opens on this station: a chat of the member's (`createdBy`, in `ws`), named `title`, its first
/// message `text`; on `runtime` and `model` where asked, else on what the chat ran on its station (`was`) where this
/// station runs it. `key`: the asking client's for this handoff (null: none), so the same ask opens one chat; `lang`:
/// the asker's, for what is refused.
export type HandoffChat = { createdBy: string; ws: string | null; title: string; text: string; runtime: string | null; model: string | null; was: { runtime: string | null; model: string | null }[]; key: string | null; lang: Lang };

/// `attached`: whether this station is on the mesh; off it, a station that does not answer is not told from one that
/// cannot be reached from here, and no other station can be asked.
export type HandoffDeps = {
  here: () => string | null;
  attached: () => boolean;
  roster: (ws: string) => { id: string; name: string }[] | null;
  ask: Ask;
  copies: {
    answering(ws: string, station: string): Promise<boolean>;
    held(ws: string, origin: string): Promise<Held>;
    chat(ws: string, origin: string, thread: number): Promise<ChatReading>;
  };
  open: (o: HandoffChat) => Promise<{ session: string; thread: number }>;
};

/// A member's ask: chat `thread` of station `origin` in workspace `ws`, by `by`, on `runtime` and `model` where named.
/// `key`: one the asking client made for this handoff (null: none); asked again with it, the chat opened is answered.
export type HandoffAsk = { ws: string; origin: string; thread: number; by: string; lang: Lang; runtime: string | null; model: string | null; key: string | null };

/// The chat opened: its session and thread here, the station whose copy it came from (`keptBy`), and when that copy was
/// made (`until`).
export type HandedOff = { session: string; thread: number; title: string; keptBy: string; until: number };

const shortId = (id: string) => id.slice(0, 8);

/// How many handoffs are kept by their clients' keys (`Handoffs`): the newest.
export const HANDOFFS_KEPT = 64;

/// The handoffs asked here by their clients' keys: one asked again with the same key (a retry after a lost answer, a
/// second press) waits for the first, or gets the chat it opened, rather than opening another. The last HANDOFFS_KEPT;
/// one that failed is let go, so it can be asked again. Past a restart the chat's own key finds it (`openHandoffChat`).
export class Handoffs {
  readonly #d: HandoffDeps;
  readonly #kept = new Map<string, Promise<HandedOff>>();
  constructor(d: HandoffDeps) {
    this.#d = d;
  }

  ask(a: HandoffAsk): Promise<HandedOff> {
    if (a.key === null) return handoff(this.#d, a);
    const k = JSON.stringify([a.ws, a.by, a.key]);
    const had = this.#kept.get(k);
    if (had !== undefined) return had;
    const made = handoff(this.#d, a);
    this.#kept.set(k, made);
    while (this.#kept.size > HANDOFFS_KEPT) this.#kept.delete(this.#kept.keys().next().value!);
    made.catch(() => {
      if (this.#kept.get(k) === made) this.#kept.delete(k);
    });
    return made;
  }
}

export async function handoff(d: HandoffDeps, a: HandoffAsk): Promise<HandedOff> {
  const here = d.here();
  if (!STATION.test(a.origin) || !Number.isSafeInteger(a.thread) || a.thread <= 0) {
    throw new HandoffRefused(400, "origin (the station's id) and thread (its chat's id) are needed");
  }
  // (as POST /sessions takes them: a runtime this station knows, and a model only with its runtime)
  if (a.runtime !== null && runtimeKind(a.runtime) === undefined) throw new HandoffRefused(400, tr(a.lang, "station.admin.badRuntime"));
  if (a.model !== null && a.runtime === null) throw new HandoffRefused(400, tr(a.lang, "station.copies.handoff.modelAlone"));
  if (here === null || !d.attached()) throw new HandoffRefused(503, tr(a.lang, "station.copies.handoff.offline"));
  const roster = d.roster(a.ws) ?? [];
  const nameOf = (id: string) => roster.find((s) => s.id === id)?.name || shortId(id);
  if (a.origin === here) throw new HandoffRefused(400, tr(a.lang, "station.copies.handoff.here"));
  // (it answers: its chat goes on there, or comes here by a hand-over, which takes the chat whole)
  if (await d.copies.answering(a.ws, a.origin)) throw new HandoffRefused(409, tr(a.lang, "station.copies.handoff.up", { name: nameOf(a.origin) }));
  const stations = [here, ...ranked(a.ws, a.origin, roster.map((s) => s.id)).filter((s) => s !== here)];
  const place = (station: string) => (station === here ? d.copies : new PeerPlace(station, d.ask));
  // What each holds of the copy (its heads alone), asked of all at once: the newest copy is read first; one that says
  // nothing is asked last.
  const heads = await Promise.all(stations.map((station) => place(station).held(a.ws, a.origin).then((h) => newestWhole(h, a.ws, a.origin)?.head ?? null, () => null)));
  const order = stations
    .map((station, i) => ({ station, i, head: heads[i] ?? null }))
    .sort((x, y) => (y.head?.made ?? -1) - (x.head?.made ?? -1) || (y.head?.to ?? -1) - (x.head?.to ?? -1) || x.i - y.i)
    .map((x) => x.station);
  let kept = false;
  let unreached = false;
  let newer: string | null = null;
  for (const station of order) {
    let chat: ChatReading;
    try {
      chat = await place(station).chat(a.ws, a.origin, a.thread);
    } catch (e) {
      // (not reached, slow, busy, from before `replica.chat`, or its reading failed: only a station that says it keeps
      // no copy is one that keeps none, so the chat may yet be there)
      unreached = true;
      log.warn("copies", "a chat not read from a copy", { ws: a.ws, origin: a.origin, station, error: (e as Error).message });
      continue;
    }
    if (chat === "none") continue;
    if (chat === "newer") {
      newer ??= station;
      continue;
    }
    kept = true;
    if (chat.thread === null) continue;
    // (its name in the roster now, else the one its copy was made under)
    const originName = roster.find((s) => s.id === a.origin)?.name || chat.name || shortId(a.origin);
    // (cut as POST /sessions cuts a chat's title)
    const title = chars(chat.thread.title ?? chat.thread.auto_title ?? `chat ${chat.thread.id}`, 120);
    const text = handoffPrompt(chat, { originName, hereName: nameOf(here), keptBy: nameOf(station) });
    let opened: { session: string; thread: number };
    try {
      opened = await d.open({
        createdBy: a.by,
        // (as POST /sessions makes a person's chat: in the asker's workspace)
        ws: a.ws || null,
        title,
        text,
        runtime: a.runtime,
        model: a.model,
        was: chat.sessions.filter((s) => s.left_at === null).map((s) => ({ runtime: s.runtime, model: s.model })),
        key: a.key,
        lang: a.lang,
      });
    } catch (e) {
      if (e instanceof HandoffRefused) throw e;
      log.warn("copies", "a handoff's chat not opened", { ws: a.ws, origin: a.origin, error: (e as Error).message });
      // (as POST /sessions refuses a chat it cannot make: no account to run it, a runtime not set up here)
      throw new HandoffRefused(409, tr(a.lang, "station.copies.handoff.failed", { error: (e as Error).message }));
    }
    return { ...opened, title, keptBy: station, until: chat.made };
  }
  const name = nameOf(a.origin);
  if (unreached) throw new HandoffRefused(503, tr(a.lang, "station.copies.handoff.unreached", { name }));
  if (newer !== null) throw new HandoffRefused(409, tr(a.lang, "station.copies.handoff.newer", { name, keeper: nameOf(newer) }));
  if (kept) throw new HandoffRefused(404, tr(a.lang, "station.copies.handoff.noChat", { name }));
  throw new HandoffRefused(404, tr(a.lang, "station.copies.handoff.none", { name }));
}

/// The messages of a reading as the prompt says them: each edit put in the message it edits (where that is among them),
/// oldest first; whether each was edited.
export function messagesOf(entries: ChatEntry[]): (ChatEntry & { edited: boolean })[] {
  const out = entries.filter((e) => e.kind === "message").map((e) => ({ ...e, edited: false }));
  const at = new Map(out.map((e, i) => [e.n, i]));
  for (const e of entries) {
    if (e.kind !== "edit" || e.target === null) continue;
    const i = at.get(e.target);
    if (i === undefined) continue;
    // (an edit that adds files carries them, as a message's edit in the chat does)
    out[i] = { ...out[i]!, text: e.text, cut: e.cut, edited: true, files: e.files.length > 0 ? e.files : out[i]!.files };
  }
  return out;
}

/// The first message of the chat a handoff opens (plain text, for its agent): which chat it goes on with and from
/// where, what of it is not here, the sessions it had, and its last messages.
export function handoffPrompt(chat: ChatCopy, o: { originName: string; hereName: string; keptBy: string }): string {
  const t = chat.thread!;
  const title = t.title ?? t.auto_title ?? `chat ${t.id}`;
  const a = o.originName;
  const lines: string[] = [
    `This chat continues the chat "${title}" of station ${a} (chat ${t.id} there). Station ${a} does not answer now, so the chat goes on here, on station ${o.hereName}, from the backup of it that station ${o.keptBy} keeps.`,
    "",
    `- The messages below come from that backup, which goes up to ${iso(chat.made)}. What was said in that chat after that time is not here.`,
    `- Station ${a} may still be running. This chat and that one go on apart from here: nothing done here reaches that chat, and nothing said there comes here.`,
    `- The working directory stayed on station ${a}: its files, its branches and the commits it did not push are not on this station. Get the code again (clone it, or fetch it from its remote) before you change it, and say what is missing.`,
  ];
  if (chat.sessions.length > 0) {
    lines.push("", `The chat's agents on station ${a}:`);
    for (const s of chat.sessions) {
      const on = [s.runtime ?? "an agent", s.model !== null ? `(${s.model})` : null].filter((x) => x !== null).join(" ");
      const where = s.cwd ?? s.workspace;
      lines.push(`- ${on}${where !== null ? `, working in ${where}` : ""}${s.title !== null && s.title !== title ? `, named "${s.title}"` : ""}${s.left_at !== null ? ", which left the chat" : ""}`);
    }
  }
  const messages = messagesOf(chat.entries);
  lines.push("", messages.length === 0 ? "The backup holds no message of the chat." : chat.earlier > 0 ? `The last ${messages.length} messages of the chat (${chat.earlier} earlier entries are left out):` : "The messages of the chat:");
  for (const m of messages) {
    const who = m.author_kind === "agent" ? `agent ${m.author}` : m.author;
    lines.push("", `[${iso(m.at)}] ${who}${m.edited ? " (edited)" : ""}:`, m.text + (m.cut ? " [cut short]" : ""));
    if (m.files.length > 0) lines.push(`(files attached there, not on this station: ${m.files.join(", ")})`);
  }
  lines.push("", "Read these messages. Then say in this chat where the work stands and what you will do next.");
  return lines.join("\n");
}

/// What the chat a handoff opens runs, of what this station runs (`cands`): what was asked; else what the chat ran on
/// its station, its model or its runtime; else what its member uses most here (`used`, model-choice.ts); else the
/// first. Null where nothing here runs what was asked, or nothing at all.
export function runtimeFor(cands: Candidate[], asked: { runtime: string | null; model: string | null }, was: { runtime: string | null; model: string | null }[], used: Used[]): Candidate | null {
  if (cands.length === 0) return null;
  const same = (c: Candidate, model: string | null) => model !== null && c.model !== null && sameModel(c.model, model);
  if (asked.runtime !== null) {
    const of = cands.filter((c) => c.runtime === asked.runtime);
    if (of.length === 0) return null;
    return of.find((c) => same(c, asked.model)) ?? (asked.model !== null ? { runtime: of[0]!.runtime, model: asked.model } : (of.find((c) => c.model === null) ?? of[0]!));
  }
  for (const w of was) {
    const found = cands.find((c) => c.runtime === w.runtime && same(c, w.model));
    if (found) return found;
  }
  for (const w of was) {
    const found = cands.find((c) => c.runtime === w.runtime);
    if (found) return { runtime: found.runtime, model: null };
  }
  const c = choose(cands, used);
  return "pick" in c ? c.pick : (c.ask[0]?.candidate ?? cands[0]!);
}

/// A handoff's chat opened on this station as a person opens one in the app (POST /sessions, then their first
/// message): its session and thread made, then the prompt said in it by the member. With the client's key it is the
/// chat that key made before, if one did, and its prompt is said only into a chat with nothing said yet.
export async function openHandoffChat(hub: Hub, o: HandoffChat): Promise<{ session: string; thread: number }> {
  const lang = o.lang;
  const runtime = o.runtime !== null && runtimeKind(o.runtime) === undefined ? null : o.runtime;
  const pick = runtimeFor(candidates(hub.profilesIn(o.ws), null), { runtime, model: o.model }, o.was, hub.store.modelsUsedBy(o.createdBy, hub.now() - USED_WITHIN_MS));
  if (pick === null) throw new HandoffRefused(409, tr(lang, "station.copies.handoff.noProfile"));
  const clientKey = o.key === null ? null : `handoff:${o.key}`;
  const made = async (model: string | null) => newSession(hub, { runtime: pick.runtime, model, title: o.title, createdBy: o.createdBy, ws: o.ws, clientKey }, lang);
  let key: string;
  let thread: number;
  try {
    const [k, chat] = await made(pick.model);
    [key, thread] = [k, chat.id];
  } catch (e) {
    // (a model no profile here runs: the runtime's own)
    if (pick.model === null) throw e;
    const [k, chat] = await made(null);
    [key, thread] = [k, chat.id];
  }
  if (hub.store.lastEntry(thread) === 0) say(hub, thread, o.createdBy, o.text);
  return { session: key, thread };
}
