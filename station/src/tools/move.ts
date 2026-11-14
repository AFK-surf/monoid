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
    "Move this station's chats, accounts, jobs and connects to another station of the chat's workspace, one item or all, and back. Read the stillfail-move skill first: it says each action and option. " +
    "plan {to}: every item, what it needs, what cannot move and why. move {to, module, item}: one item (a chat: its session key); withNeeds moves its needs first; all moves everything once a card is confirmed in the app. " +
    "back {module, item, to}: moves it back here. status: where each stands. stop: the move under way stops.",
  inputSchema: {
    type: "object",
    properties: {
      action: { enum: ["plan", "move", "back", "status", "stop"] },
      to: { type: "string", description: "The other station, by name or id (station_list)." },
      module: { type: "string" },
      item: { type: "string" },
      withNeeds: { type: "boolean" },
      arriveStopped: { type: "boolean" },
      all: { type: "boolean" },
      station: { type: "string" },
      wait: { type: "boolean" },
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
};

export class MoveAsks {
  readonly #d: MoveAsksDeps;
  #asks: Ask[];
  #running: Promise<unknown> | null = null;

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
        return await this.#d.ask(at.id, { method: "move.tool", workspace: ws, args: rest });
      }
    }
    return await this.toolIn(ws, session, args);
  }

  /// The tool's work for workspace `ws` (`session`: the chat asking here; null: asked by another station).
  async toolIn(ws: string, session: string | null, args: Json): Promise<Json> {
    this.#d.setWait?.(args.wait !== false);
    const sel: Selection = { module: typeof args.module === "string" ? args.module : undefined, item: typeof args.item === "string" ? args.item : undefined, withNeeds: args.withNeeds === true, all: args.all === true, arriveStopped: args.arriveStopped === true };
    switch (args.action) {
      case "plan":
      case "status": {
        const to = args.to === undefined && args.action === "status" ? null : this.#station(ws, args.to);
        const plan = await this.#d.scheduler.planShown(ws, to?.id ?? "");
        return { plan: brief(plan), stopped: this.#d.scheduler.stopped(), say: planWords(plan, to?.name ?? "", args.action === "status") };
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
        const out = await this.#d.scheduler.move(ws, to.id, { ...sel, follow: sel.module === "chats" ? ["jobs"] : undefined }, session);
        return { outcome: out, say: outcomeWords(out, "moved to", to.name) };
      }
      case "back": {
        const from = this.#station(ws, args.to);
        if (sel.module === undefined || (sel.item === undefined && sel.all !== true)) throw new Refused("back: name the module and the item (station_move status lists them), and to: the station it is on");
        const why = await this.#d.refusal?.(ws, from.id);
        if (why) throw new Refused(why);
        const out = await this.#d.scheduler.back(ws, from.id, { ...sel, follow: sel.module === "chats" ? ["jobs"] : undefined }, session);
        return { outcome: out, say: outcomeWords(out, "back here from", from.name) };
      }
      case "stop": {
        if (!this.#d.scheduler.stopTurn(session)) throw new Refused(tr(stationLang(), "station.move.notRunning"));
        return { stopping: true, say: "The move under way stops: nothing further of it starts; a chat not yet gone goes on here, one already gone completes there. Its outcome is told as it ends." };
      }
    }
    throw new Refused("action is one of plan, move, back, status, stop");
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

/// A plan as the tool answers it: each item in a line's worth.
function brief(plan: Plan): Json[] {
  return plan.items.map((x) => ({ module: x.module, item: x.id, label: x.label, state: x.state, ...(x.needs.length > 0 ? { needs: x.needs.map(named) } : {}), ...(x.cannot !== undefined ? { cannot: x.cannot } : {}), ...(x.error ? { error: x.error } : {}), ...(x.waitsFor ? { waitsFor: named(x.waitsFor) } : {}), ...(x.wouldStop.length > 0 ? { wouldStop: x.wouldStop.map(named) } : {}), ...(x.progress ? { progress: x.progress } : {}) }));
}

export function planWords(plan: Plan, to: string, status: boolean): string {
  const by = (s: string) => plan.items.filter((x) => x.state === s).length;
  const cannot = plan.items.filter((x) => x.cannot !== undefined && x.state !== "there");
  const parts = [`${plan.items.length} items${to ? ` for ${to}` : ""}: ${by("here")} here, ${by("there")} there, ${by("moving")} moving, ${by("stopped")} stopped, ${by("failed")} failed.`];
  if (!status && cannot.length > 0) parts.push(`Cannot move: ${cannot.map((x) => `${x.module} ${x.label}: ${x.cannot}`).join("; ")}.`);
  const stops = plan.items.filter((x) => x.wouldStop.length > 0 && x.state !== "there");
  if (!status && stops.length > 0) parts.push(`Moving these alone would stop what needs them here: ${stops.map((x) => `${named(x)} stops ${x.wouldStop.map(named).join(", ")}`).join("; ")}.`);
  return parts.join(" ");
}

export function outcomeWords(out: Outcome, how: string, station: string): string {
  const parts: string[] = [];
  parts.push(out.done.length === 0 ? `Nothing ${how} ${station}.` : `${how[0]!.toUpperCase()}${how.slice(1)} ${station}: ${out.done.map(named).join(", ")}.`);
  if (out.refused.length > 0) parts.push(`Not moved: ${out.refused.map((r) => `${named(r.item)}: ${r.why}`).join("; ")}.`);
  if (out.stopped.length > 0) parts.push(`Stopped here, waiting for what they need: ${out.stopped.map((s) => `${named(s.item)} (waits for ${named(s.waitsFor)})`).join(", ")}.`);
  if (out.resumed.length > 0) parts.push(`Going on here again: ${out.resumed.map(named).join(", ")}.`);
  if ((out.returned ?? []).length > 0) parts.push(`Brought back, as what they moved for did not go: ${out.returned!.map(named).join(", ")}.`);
  const failures = out.failures ?? (out.failed !== null ? [out.failed] : []);
  if (failures.length > 0) parts.push(`Failed: ${failures.map((f) => `${named(f.item)}: ${f.error}`).join("; ")}. Everything else of the turn went on; what needs a failed item was not started (said above). Ask again for those once the cause is fixed.`);
  return parts.join(" ");
}

export function moveTools(asks: MoveAsks): Tool[] {
  return [{ ...MOVE_TOOL, run: async (session, args) => JSON.stringify(await asks.tool(session, args), null, 2) }];
}
