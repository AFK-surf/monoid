// station_move: the migration scheduler's face (move/AGENTS.md; the stillfail-move skill says how to go about it). A
// plan of what a move of this station's chats to another would be (each module's items, what each needs, what cannot
// move and why, what a move would stop); one item moved or moved back, its needs first where asked; everything moved,
// confirmed once on a card by an owner or admin of the workspace in the app (`MoveAsks`); where each stands. One chat
// needs no card: it pauses for seconds and moving it back undoes it.
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Refused } from "../mesh/bus.ts";
import { managesStation } from "../mesh/credential.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import type { CardAt } from "../parts.ts";
import type { Need } from "../move/module.ts";
import type { Outcome, Plan, Scheduler, Selection } from "../move/scheduler.ts";
import type { Tool } from "./mcp.ts";

type Json = any;

/// An item as the scheduler names it in what it says (move/module.ts `named`): said again here, as what the parts share
/// takes only a part's types (test/platform-apart.test.ts).
const named = (n: Need) => `${n.module} ${n.id}`;

export const MOVE_TOOL = {
  name: "station_move",
  description:
    "Move this station's chats, accounts, jobs and connects to another station of its workspace, one item or all, and back. Read skill stillfail-move first: it says each option. " +
    "plan {to}: a summary; module (after, limit) pages, item one. move {to, module, item}: one item (a chat: its session key); withNeeds: its needs first; all: everything, once a card is confirmed in the app. " +
    "back {module, item, to}: back here. status: where each stands. stop: the move under way stops.",
  inputSchema: {
    type: "object",
    properties: {
      action: { type: "string", enum: ["plan", "move", "back", "status", "stop"] },
      to: { type: "string", description: "The other station: name or id (station_list)." },
      module: { type: "string" },
      item: { type: "string" },
      withNeeds: { type: "boolean" },
      arriveStopped: { type: "boolean" },
      all: { type: "boolean" },
      station: { type: "string" },
      wait: { type: "boolean" },
      after: { type: "string" },
      limit: { type: "number" },
    },
    required: ["action"],
    additionalProperties: false,
  },
};

/// An all-moving asked, waiting for its card's choice.
type Ask = { id: string; session: string; ws: string; to: string; toName: string; state: "asked" | "confirmed" | "declined"; thread: number | null; ts: string | null; by: string | null };

export type MoveAsksDeps = {
  data: string;
  scheduler: Scheduler;
  here: () => string | null;
  wsOf: (session: string) => string | null;
  roster: (ws: string) => { id: string; name: string }[] | null;
  cards: { post(session: string, text: string, card: Json): Promise<{ thread: number; ts: string } | null> };
  notify: (session: string, text: string) => void;
  /// Asks another station of the workspace (its station_move, `move.tool`).
  ask?: (station: string, request: Json) => Promise<Json>;
  /// Whether a busy chat's turn is waited for, for the request under way (move/station.ts `wait`).
  setWait?: (wait: boolean) => void;
  /// Why a move or a move back with that station cannot begin (move/station.ts `refusal`: switched off here or there).
  refusal?: (ws: string, station: string) => Promise<string | null>;
  /// What a move to that station would send of chats `ids` and what is free there (move/station.ts `room`).
  room?: (ws: string, station: string, ids: string[]) => Promise<Json>;
  /// The move's told steps (move/told.ts `Told`): a move or a move back asked of another station waits on its end, not
  /// on one answer (mesh/peer.ts ANSWER_MS: a chat of 265 MB in a turn, 2026-11-16, was told "peer request timed out"
  /// though it moved), and one asked here runs as a step.
  told?: {
    asked: (to: string, key: string, make: () => Json) => Promise<Json>;
    run: (origin: string, key: string, work: () => Promise<Json>) => Json;
  };
  /// What a chat's station_move waits for its answer: `what`'s value once settled, or null if it is not within
  /// ANSWER_SOON_MS (it goes on, and the chat is told its answer once it ends). None: waited for to its end.
  soon?: <A>(what: Promise<A>) => Promise<{ value: A } | null>;
};

/// How long a chat's station_move waits on its answer before saying that it is under way and telling the chat its
/// answer once it ends: an agent's tool call has a deadline of its runtime's own (Claude Code's, Codex's), and a plan of
/// thousands of chats toward a far station, or a move toward a busy one, outlasts it (real run, 2026-11-20: a plan toward
/// gt1 and a move toward tokyo-mac-studio-0 answered the agent only "The operation timed out"; the move went on, unseen).
export const ANSWER_SOON_MS = 20_000;

export class MoveAsks {
  readonly #d: MoveAsksDeps;
  #asks: Ask[];
  #running: Promise<unknown> | null = null;
  /// A chat's station_move answers still to be told it (`#soon`).
  readonly #later = new Set<Promise<unknown>>();

  constructor(d: MoveAsksDeps) {
    this.#d = d;
    try {
      this.#asks = JSON.parse(readFileSync(join(d.data, "move", "asks.json"), "utf8")) as Ask[]; // sync: read once, before the station serves
    } catch {
      this.#asks = [];
    }
  }

  async settle(): Promise<void> {
    await this.#running?.catch(() => {});
    await Promise.all([...this.#later]);
  }

  /// `work`'s answer for chat `session` (null: another station asked) if it comes soon (`soon`), else that it is under
  /// way, its answer told to the chat once it ends, whatever it is (a refusal too).
  async #soon(session: string | null, what: string, work: () => Promise<Json>): Promise<Json> {
    const run = work();
    if (session === null || this.#d.soon === undefined) return await run;
    const first = await this.#d.soon(run);
    if (first !== null) return first.value;
    const told = run.then(
      (v) => this.#d.notify(session, `station_move ${what} ended: ${typeof v?.say === "string" ? v.say : JSON.stringify(v)}`),
      (e) => this.#d.notify(session, `station_move ${what} did not go: ${(e as Error).message}`),
    ).finally(() => this.#later.delete(told));
    this.#later.add(told);
    return { underWay: true, say: `station_move ${what} is still under way: its answer is told in this chat once it ends. Do not ask again; end your turn waiting (status shows where each item stands meanwhile).` };
  }

  #station(ws: string, v: unknown): { id: string; name: string } {
    const s = typeof v === "string" ? v.trim() : "";
    if (s === "") throw new Refused("to: name the other station (station_list lists them)");
    const roster = this.#d.roster(ws) ?? [];
    const found = roster.find((r) => r.id === s) ?? roster.find((r) => r.name.toLowerCase() === s.toLowerCase()) ?? roster.find((r) => s.length >= 8 && r.id.startsWith(s));
    if (found === undefined) throw new Refused(`no station ${s} in this chat's workspace: station_list lists them`);
    if (found.id === this.#d.here()) throw new Refused("that is this station: name another");
    return found;
  }

  async tool(session: string, args: Json): Promise<Json> {
    const ws = this.#d.wsOf(session);
    if (ws === null) throw new Refused("this chat is of no workspace here");
    // (another station asked to do it, of its own items: as station_retire asked one)
    if (typeof args.station === "string" && args.station.trim() !== "") {
      const roster = this.#d.roster(ws) ?? [];
      const s = args.station.trim();
      const at = roster.find((r) => r.id === s) ?? roster.find((r) => r.name.toLowerCase() === s.toLowerCase()) ?? roster.find((r) => s.length >= 8 && r.id.startsWith(s));
      if (at === undefined) throw new Refused(`no station ${s} in this chat's workspace: station_list lists them`);
      if (at.id !== this.#d.here()) {
        if (args.all === true) throw new Refused(`moving all of station ${at.name} is confirmed on a card in a chat on that station: ask from one there (chat_create opens one)`);
        if (this.#d.ask === undefined) throw new Refused("other stations cannot be asked from here");
        const { station: _, ...rest } = args;
        // (a move or a move back is a told step there: waited on to its end however long; a station from before told
        // steps answers the request with its outcome, as before)
        const told = this.#d.told;
        if (told !== undefined && (args.action === "move" || args.action === "back")) {
          const key = `tool:${args.action}:${randomBytes(6).toString("hex")}`;
          return await this.#soon(session, `${args.action} on ${at.name}`, () => told.asked(at.id, key, () => ({ method: "move.tool", workspace: ws, args: rest, told: key })));
        }
        const ask = this.#d.ask;
        return await this.#soon(session, `${String(args.action)} on ${at.name}`, () => ask(at.id, { method: "move.tool", workspace: ws, args: rest }));
      }
    }
    return await this.toolIn(ws, session, args);
  }

  /// station_move asked by another station (`move.tool`, `workspace` its chat's): a move or a move back as a told step
  /// where it asks so (`told`, its key), else answered with its outcome as before.
  async answer(peer: string, workspace: string, request: Json): Promise<Json> {
    const args = request?.args ?? {};
    const key = typeof request?.told === "string" && request.told.length <= 300 ? request.told : null;
    if (key === null || this.#d.told === undefined) return await this.toolIn(workspace, null, args);
    return this.#d.told.run(peer, key, () => this.toolIn(workspace, null, args));
  }

  /// The tool's work for workspace `ws` (`session`: the chat asking here; null: asked by another station).
  async toolIn(ws: string, session: string | null, args: Json): Promise<Json> {
    this.#d.setWait?.(args.wait !== false);
    const sel: Selection = { module: typeof args.module === "string" ? args.module : undefined, item: typeof args.item === "string" ? args.item : undefined, withNeeds: args.withNeeds === true, all: args.all === true, arriveStopped: args.arriveStopped === true };
    switch (args.action) {
      case "plan":
      case "status": {
        const to = args.to === undefined && args.action === "status" ? null : this.#station(ws, args.to);
        return await this.#soon(session, `${args.action}${to !== null ? ` toward ${to.name}` : ""}`, () => this.#planned(ws, to, sel, args));
      }
      case "move": {
        const to = this.#station(ws, args.to);
        const why = await this.#d.refusal?.(ws, to.id);
        if (why) throw new Refused(why);
        if (sel.all === true) {
          if (session === null) throw new Refused("moving all of a station is confirmed on a card in a chat on it");
          return await this.#askAll(session, ws, to);
        }
        if (sel.module === undefined || sel.item === undefined) throw new Refused("move: name the module and the item (station_move plan lists them), or all");
        return await this.#soon(session, `move of ${sel.module} ${sel.item} to ${to.name}`, async () => {
          const out = await this.#d.scheduler.move(ws, to.id, { ...sel, follow: sel.module === "chats" ? ["jobs"] : undefined }, session);
          return { outcome: outcomeOf(out), say: outcomeWords(out, "moved to", to.name) };
        });
      }
      case "back": {
        const from = this.#station(ws, args.to);
        if (sel.module === undefined || (sel.item === undefined && sel.all !== true)) throw new Refused("back: name the module and the item (station_move status lists them), and to: the station it is on");
        const why = await this.#d.refusal?.(ws, from.id);
        if (why) throw new Refused(why);
        return await this.#soon(session, `back of ${sel.module} ${sel.item ?? "all"} from ${from.name}`, async () => {
          const out = await this.#d.scheduler.back(ws, from.id, { ...sel, follow: sel.module === "chats" ? ["jobs"] : undefined }, session);
          return { outcome: outcomeOf(out), say: outcomeWords(out, "back here from", from.name) };
        });
      }
      case "stop": {
        if (!this.#d.scheduler.stopTurn(session)) throw new Refused(tr(stationLang(), "station.move.notRunning"));
        return { stopping: true, say: "The move under way stops: nothing further of it starts; a chat not yet gone goes on here, one already gone completes there. Its outcome is told as it ends." };
      }
    }
    throw new Refused("action is one of plan, move, back, status, stop");
  }

  /// station_move plan or status (`args.action`) toward `to` (null: status of every station).
  async #planned(ws: string, to: { id: string; name: string } | null, sel: Selection, args: Json): Promise<Json> {
    const plan = await this.#d.scheduler.planShown(ws, to?.id ?? "");
    const status = args.action === "status";
    // (one item, a module's a page at a time, or the summary: never every item, whatever the station's size)
    if (sel.item !== undefined) {
      const x = plan.items.find((i) => i.id === sel.item && (sel.module === undefined || i.module === sel.module));
      if (x === undefined) throw new Refused(`no item ${sel.item}${sel.module ? ` of ${sel.module}` : ""} in the plan: plan with module lists them`);
      return { item: brief(x) };
    }
    if (sel.module !== undefined) return pageOf(plan, sel.module, typeof args.after === "string" ? args.after : null, typeof args.limit === "number" ? args.limit : PAGE);
    // (the bytes of the chats that would go, as far as they are measured, and the free bytes there)
    const going = plan.items.filter((x) => x.module === "chats" && x.state !== "there").map((x) => x.id);
    const room = (await this.#d.room?.(ws, to?.id ?? "", going).catch(() => null)) ?? null;
    return { summary: { ...summaryOf(plan, this.#d.scheduler.stopped()), ...(room !== null ? { room } : {}) }, say: `${planWords(plan, to?.name ?? "", status)}${room !== null ? ` ${roomWords(room)}` : ""}` };
  }

  async #askAll(session: string, ws: string, to: { id: string; name: string }): Promise<Json> {
    const plan = await this.#d.scheduler.plan(ws, to.id);
    const lang = stationLang();
    const a: Ask = { id: `m_${randomBytes(6).toString("hex")}`, session, ws, to: to.id, toName: to.name, state: "asked", thread: null, ts: null, by: null };
    const confirm = tr(lang, "station.move.card.confirm");
    const card = {
      type: "options",
      options: [
        { label: confirm, detail: tr(lang, "station.move.card.confirmDetail"), action: "close", recommended: true },
        { label: tr(lang, "station.move.card.decline"), detail: tr(lang, "station.move.card.declineDetail"), action: "close" },
      ],
      move: { ask: a.id, to: to.id, toName: to.name },
    };
    const posted = await this.#d.cards.post(session, tr(lang, "station.move.card.title", { to: to.name, n: String(plan.items.filter((x) => x.state !== "there").length) }), card);
    a.thread = posted?.thread ?? null;
    a.ts = posted?.ts ?? null;
    this.#asks = [...this.#asks.filter((x) => !(x.session === session && x.state === "asked")), a].slice(-20);
    await this.#save();
    return { ask: a.id, card: "posted", say: `A card is in this chat: an owner or admin of the workspace confirms it (${confirm}) in the still.fail app; nothing moves until then. You are told what came of it. The plan: ${planWords(plan, to.name, false)}` };
  }

  #askAt(card: Json, at: CardAt): Ask | null {
    const id = card?.move?.ask;
    const a = this.#asks.find((x) => x.id === id);
    return a === undefined || a.thread !== at.thread || a.ts !== at.ts ? null : a;
  }

  may(viewer: { role: string; workspace: string | null; email: string }, card: Json, at: CardAt): string | null {
    const a = this.#askAt(card, at);
    if (a === null) return tr(stationLang(), "station.move.askGone");
    if (!managesStation(viewer) || viewer.workspace !== a.ws) return tr(stationLang(), "station.move.ownersOnly");
    return null;
  }

  chosen(viewer: { email: string }, card: Json, option: string, at: CardAt): void {
    const a = this.#askAt(card, at);
    if (a === null || a.state !== "asked") return;
    a.by = viewer.email;
    if (option.trim() !== tr(stationLang(), "station.move.card.confirm")) {
      a.state = "declined";
      void this.#save();
      this.#d.notify(a.session, `${viewer.email} chose ${option.trim()} on the card: nothing was moved.`);
      return;
    }
    a.state = "confirmed";
    void this.#save();
    this.#running = this.#d.scheduler.move(a.ws, a.to, { all: true, follow: ["jobs"] }, viewer.email).then(
      (out) => this.#d.notify(a.session, `${viewer.email} confirmed moving everything to ${a.toName}. ${outcomeWords(out, "moved to", a.toName)}`),
      (e) => this.#d.notify(a.session, `${viewer.email} confirmed moving everything to ${a.toName}, but it did not begin: ${(e as Error).message}`),
    );
  }

  async #save(): Promise<void> {
    const path = join(this.#d.data, "move", "asks.json");
    await mkdir(dirname(path), { recursive: true });
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#asks));
    await rename(tmp, path);
  }
}

/// The items of a page the tool answers (module, after, limit), and the most a page asks.
export const PAGE = 50;
export const PAGE_MOST = 200;
/// The most examples a group of the summary names, the most groups it lists, and how long a label it says: whatever a
/// station has, the summary's size is bounded by these.
export const EXAMPLES = 3;
export const GROUPS = 20;
const LABEL_MOST = 80;
const short = (s: string) => (s.length > LABEL_MOST ? `${s.slice(0, LABEL_MOST - 1)}…` : s);

/// An item as the tool answers it: a line's worth.
function brief(x: Plan["items"][number]): Json {
  return { module: x.module, item: x.id, label: x.label, state: x.state, ...(x.needs.length > 0 ? { needs: x.needs.map(named) } : {}), ...(x.cannot !== undefined ? { cannot: x.cannot } : {}), ...(x.leaves !== undefined ? { leaves: x.leaves } : {}), ...(x.error ? { error: x.error } : {}), ...(x.waitsFor ? { waitsFor: named(x.waitsFor) } : {}), ...(x.wouldStop.length > 0 ? { wouldStop: x.wouldStop.map(named) } : {}), ...(x.progress ? { progress: x.progress } : {}) };
}

/// A module's items a page at a time, in the plan's order: those after `after` (an item's id), `limit` of them.
function pageOf(plan: Plan, module: string, after: string | null, limit: number): Json {
  const mine = plan.items.filter((x) => x.module === module);
  if (mine.length === 0 && !plan.modules.some((m) => m.id === module)) throw new Refused(`no module ${module}: one of ${plan.modules.map((m) => m.id).join(", ")}`);
  const from = after === null ? 0 : mine.findIndex((x) => x.id === after) + 1;
  const n = Math.max(1, Math.min(PAGE_MOST, Math.floor(limit) || PAGE));
  const page = mine.slice(from, from + n);
  return { module, total: mine.length, items: page.map(brief), more: from + n < mine.length ? page.at(-1)?.id ?? null : null };
}

/// Items grouped by what is said of them (a reason), each group counted, a few named.
function grouped<T>(xs: readonly T[], key: (x: T) => string, example: (x: T) => string): { why: string; count: number; examples: string[] }[] & { more?: number } {
  const groups = new Map<string, { why: string; count: number; examples: string[] }>();
  for (const x of xs) {
    const k = key(x);
    const g = groups.get(k) ?? { why: short(k), count: 0, examples: [] };
    g.count++;
    if (g.examples.length < EXAMPLES) g.examples.push(short(example(x)));
    groups.set(k, g);
  }
  const all = [...groups.values()].sort((a, b) => b.count - a.count);
  const out: { why: string; count: number; examples: string[] }[] & { more?: number } = all.slice(0, GROUPS);
  if (all.length > GROUPS) out.more = all.length - GROUPS;
  return out;
}

/// What the tool answers of a plan by default: each module's counts, what cannot move and why and what moving one item
/// alone would stop (grouped), what is lent there and what is stopped here (grouped by what it waits for). Bounded
/// whatever the station's size: no list of every item (plan with module pages them).
export function summaryOf(plan: Plan, stopped: { item: Need; waitsFor: Need }[]): Json {
  const modules: Record<string, Record<string, number>> = {};
  for (const m of plan.modules) modules[m.id] = { here: 0, there: 0, moving: 0, stopped: 0, failed: 0, cannot: 0 };
  for (const x of plan.items) {
    const c = (modules[x.module] ??= { here: 0, there: 0, moving: 0, stopped: 0, failed: 0, cannot: 0 });
    c[x.state] = (c[x.state] ?? 0) + 1;
    if (x.cannot !== undefined && x.state !== "there") c.cannot!++;
  }
  const left = plan.items.filter((x) => x.state !== "there");
  return {
    items: plan.items.length,
    modules,
    cannot: grouped(left.filter((x) => x.cannot !== undefined), (x) => `${x.module}: ${x.cannot}`, (x) => x.label),
    wouldStop: grouped(left.filter((x) => x.wouldStop.length > 0), (x) => `moving ${named(x)} alone stops ${x.wouldStop.length} here`, (x) => x.wouldStop.slice(0, EXAMPLES).map(named).join(", ")),
    lent: grouped(plan.items.filter((x) => x.lentTo !== undefined), (x) => `${x.module} lent to ${x.lentTo}`, (x) => x.label),
    stopped: grouped(stopped, (s) => `waits for ${named(s.waitsFor)}`, (s) => named(s.item)),
  };
}

/// What the tool says of a plan in words: counts, and what cannot move grouped by why (bounded as `summaryOf`).
export function planWords(plan: Plan, to: string, status: boolean): string {
  const by = (s: string) => plan.items.filter((x) => x.state === s).length;
  const parts = [`${plan.items.length} items${to ? ` for ${to}` : ""}: ${by("here")} here, ${by("there")} there, ${by("moving")} moving, ${by("stopped")} stopped, ${by("failed")} failed.`];
  const left = plan.items.filter((x) => x.state !== "there");
  const cannot = grouped(left.filter((x) => x.cannot !== undefined), (x) => `${x.module}: ${x.cannot}`, (x) => x.label);
  if (!status && cannot.length > 0) parts.push(`Cannot move: ${cannot.map((g) => `${g.count} (e.g. ${g.examples.join(", ")}): ${g.why}`).join("; ")}${cannot.more ? `; and ${cannot.more} other reasons` : ""}.`);
  const stops = left.filter((x) => x.wouldStop.length > 0);
  if (!status && stops.length > 0) parts.push(`${stops.length} items would stop what needs them here if moved alone (e.g. ${stops.slice(0, EXAMPLES).map((x) => `${named(x)} stops ${x.wouldStop.length}`).join(", ")}): move them with what needs them, or all.`);
  if (plan.items.length > 0) parts.push("plan with module (and after, limit) lists a module's items; with item, one.");
  return parts.join(" ");
}

/// A turn's outcome as the tool answers it: each list's first page and how many it has (`counts`): a whole station's
/// back is thousands of items, which no answer carries (mesh/peer.ts MAX_MESSAGE).
export function outcomeOf(out: Outcome): Json {
  const lists = { done: out.done, refused: out.refused.map((r) => ({ item: r.item, why: short(r.why) })), stopped: out.stopped, resumed: out.resumed, failures: (out.failures ?? []).map((f) => ({ item: f.item, error: short(f.error) })), returned: out.returned ?? [], lent: out.lent ?? [] };
  const counts: Record<string, number> = {};
  const cut: Record<string, unknown[]> = {};
  for (const [k, xs] of Object.entries(lists)) {
    counts[k] = xs.length;
    cut[k] = (xs as unknown[]).slice(0, PAGE);
  }
  return { ...cut, failed: out.failed === null ? null : { item: out.failed.item, error: short(out.failed.error) }, counts };
}

/// What a move would send and what is free there, in words.
export function roomWords(r: Json): string {
  const known = r.measuring > 0 ? `${r.known} of ${r.of} chats measured, ${r.measuring} being measured` : `all ${r.of} chats measured`;
  const there = typeof r.freeThere === "string" ? ` ${r.freeThere} free there, ${r.floorThere} of it kept free; what is in place there already is not sent again, so a whole move asks it first what it has of each room.` : "";
  return `Their files: ${r.sends} (${known}).${there}`;
}

/// A list said in words: a few of it, and how many more (a whole station's turn is thousands of items).
const some = <T>(xs: readonly T[], said: (x: T) => string, sep = ", ", most = GROUPS) => `${xs.slice(0, most).map(said).join(sep)}${xs.length > most ? `${sep}and ${xs.length - most} more` : ""}`;

export function outcomeWords(out: Outcome, how: string, station: string): string {
  const parts: string[] = [];
  parts.push(out.done.length === 0 ? `Nothing ${how} ${station}.` : `${how[0]!.toUpperCase()}${how.slice(1)} ${station} (${out.done.length}): ${some(out.done, named)}.`);
  if (out.refused.length > 0) parts.push(`Not moved (${out.refused.length}): ${grouped(out.refused, (r) => r.why, (r) => named(r.item)).map((g) => `${g.count} (e.g. ${g.examples.join(", ")}): ${g.why}`).join("; ")}.`);
  if (out.stopped.length > 0) parts.push(`Stopped here, waiting for what they need (${out.stopped.length}): ${some(out.stopped, (s) => `${named(s.item)} (waits for ${named(s.waitsFor)})`)}.`);
  if (out.resumed.length > 0) parts.push(`Going on here again (${out.resumed.length}): ${some(out.resumed, named)}.`);
  if ((out.returned ?? []).length > 0) parts.push(`Brought back, as what they moved for did not go: ${some(out.returned!, named)}.`);
  const failures = out.failures ?? (out.failed !== null ? [out.failed] : []);
  if (failures.length > 0) parts.push(`Failed (${failures.length}): ${some(failures, (f) => `${named(f.item)}: ${short(f.error)}`, "; ")}. Everything else of the turn went on; what needs a failed item was not started (said above). Ask again for those once the cause is fixed.`);
  return parts.join(" ");
}

export function moveTools(asks: MoveAsks): Tool[] {
  return [{ ...MOVE_TOOL, run: async (session, args) => JSON.stringify(await asks.tool(session, args), null, 2) }];
}
