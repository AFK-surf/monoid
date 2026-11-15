// The scheduler of a migration (move/AGENTS.md): it only orders the modules' items (module.ts) and never does a
// module's work. An item moves once what it needs is there (it is refused naming what it waits for, or, asked
// `withNeeds`, those move first); it is moved back once nothing on the other station that needs it is still there
// (refused naming it). As an item moves away, each item still here that needs it and cannot have it here any more is
// stopped (a state of its own, kept here across starts: `stopped.log`), and goes on as what it waits for is back, or as
// it moves itself. What changes is told (`changed`), nothing is polled.
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { log } from "../ops/log.ts";
import { KeptLog } from "./kept.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { type Item, type ItemState, type Module, type Need, type PlanReads, type Progress, type Waits, named, sameItem, Said, sayOf } from "./module.ts";

/// An item as a plan shows it: what it is, where it stands, and what would be stopped here if it moved alone.
export type Planned = Item & ItemState & { wouldStop: Need[] };
export type Plan = { ws: string; to: string; modules: { id: string; needs: readonly string[] }[]; items: Planned[] };
/// The turn under way's plan as a page reads it (scheduler `held`): each module's items in the plan's order, each one's
/// place among them (by `named`), per module how many there are, cannot go and are there; `now`, an item as it stands.
export type Held = { byModule: ReadonlyMap<string, readonly Planned[]>; at: ReadonlyMap<string, number>; counts: ReadonlyMap<string, { done: number; total: number; cannot: number }>; now: (x: Planned) => Planned };
/// Which items: one (`module` and `item`), a module's (`module`), or all (`all`); `withNeeds`: what they need first;
/// `follow`: the items of these modules that need only what moved go with it (a chat's jobs).
/// `arriveStopped`: an item whose need is not there goes all the same, arriving there stopped, waiting for it.
export type Selection = { module?: string; item?: string; all?: boolean; withNeeds?: boolean; follow?: string[]; arriveStopped?: boolean };
/// What came of a move or a move back: moved in order; refused (not tried: why); stopped as their need went; the
/// failure it stopped at.
/// `failures`: each item whose move failed, with its words: the turn goes on past it, only what needs it not started
/// (refused, naming it); `failed` the first of them.
/// `returned`: what moved only for an item that then did not go, brought back in the same turn.
export type Outcome = { done: Need[]; refused: { item: Need; why: string }[]; stopped: { item: Need; waitsFor: Need }[]; resumed: Need[]; failed: { item: Need; error: string } | null; failures?: { item: Need; error: string }[]; returned?: Need[]; lent?: Need[] };
/// The last move or move back of a workspace's, as the app shows it (GET /move `last`): when it ended, who asked (a
/// person's email; an agent's: its chat's session key), which way and with which station, and what came of it. A turn
/// that could not begin (its plan refused) has `failed` with no item.
export type Last = { at: number; by: string | null; how: "move" | "back"; station: string; stoppedBy?: string | null; done: Need[]; refused: { item: Need; why: string }[]; stopped: { item: Need; waitsFor: Need }[]; resumed: Need[]; failed: { item: Need | null; error: string } | null; failures?: { item: Need; error: string }[]; returned?: Need[]; lent?: Need[] };
/// An item stopped here, kept: what it waits for, of which workspace.
type Stopped = { item: Need; waitsFor: Waits; ws: string };

export type SchedulerDeps = {
  data: string;
  modules: Module[];
  changed?: () => void;
  /// Progress of the item moving now.
  progress?: (item: Need, p: Progress) => void;
  /// Tells station `to` that `item` is there now: what is stopped there waiting for it goes on (`arrived`).
  tellArrived?: (to: string, item: Need) => Promise<void>;
  /// The time, for `last`.
  now?: () => number;
  /// Why a turn with that station of `ws` cannot begin (move/station.ts `refusal`: switched off here or there); null:
  /// it can. Asked before anything is held.
  refusal?: (ws: string, station: string) => Promise<string | null>;
  /// What keeps the station from updating itself while a turn goes on (updates/holds.ts `hold`): its let-go.
  hold?: () => () => void;
  /// What a turn under way as the station stopped says as its outcome, in the viewer's words.
  restarted?: () => string;
  /// What one plan of `ws` reads once for all its modules (module.ts `PlanReads`); none: each module its own.
  reads?: (ws: string) => PlanReads;
  /// Told as a turn with `station` begins (true) and as it ends (false).
  turn?: (on: boolean, station: string) => void;
};

/// What is stopped here, a line a change (kept.ts `KeptLog`); `stopped.json` the file of before, taken in once.
const stoppedFile = (data: string) => join(data, "move", "stopped.log");
const stoppedBefore = (data: string) => join(data, "move", "stopped.json");
const lastFile = (data: string) => join(data, "move", "last.json");
/// The turn under way (written as it begins, taken out as it ends): one found as the station starts was cut by a stop.
const turnFile = (data: string) => join(data, "move", "turn.json");

export class Scheduler {
  readonly #d: SchedulerDeps;
  readonly #modules = new Map<string, Module>();
  readonly #stopped: StoppedSet;
  /// One move or move back at a time.
  #turn: Promise<unknown> = Promise.resolve();
  /// The turns asked and not ended yet (the one under way among them).
  #asked = 0;
  /// Each workspace's last turn (`last.json`).
  #last: Record<string, Last>;

  constructor(d: SchedulerDeps) {
    this.#d = d;
    for (const m of d.modules) {
      if (this.#modules.has(m.id)) throw new Error(`two modules ${m.id}`);
      this.#modules.set(m.id, m);
    }
    for (const m of d.modules) for (const n of m.needs) if (!this.#modules.has(n)) throw new Error(`module ${m.id} needs ${n}, which is not one`);
    this.#stopped = new StoppedSet(new KeptLog<Stopped>(stoppedFile(d.data), {
      path: stoppedBefore(d.data),
      records: (raw) => (Array.isArray(raw) ? (raw as Stopped[]).map((s): [string, Stopped] => [named(s.item), s]) : []),
    }));
    try {
      this.#last = JSON.parse(readFileSync(lastFile(d.data), "utf8")) as Record<string, Last>; // sync: read once, before the station serves
    } catch {
      this.#last = {};
    }
  }

  /// Once the turns asked so far are over (a test's).
  async settle(): Promise<void> {
    await this.#turn;
  }

  /// The turn under way asked to stop by `by` (a person's email, an agent's chat's key): nothing further of it starts, the
  /// item under way gives up where it can (`abandon`). False: none is under way.
  stopTurn(by: string | null): boolean {
    if (!this.busy()) return false;
    if (this.#stopping === null) this.#stopping = { by };
    for (const m of this.#modules.values()) m.abandon?.();
    this.#d.changed?.();
    return true;
  }
  #stopping: { by: string | null } | null = null;

  /// Whether the turn under way was asked to stop.
  stopping(): boolean {
    return this.#stopping !== null;
  }

  /// Whether a move or a move back is under way (or asked behind one).
  /// The item the turn under way is at (stopping what needs it, or moving it): a read of a turn under way says it
  /// moves, until its end is told, not only while an item reads `moving`.
  #current: Need | null = null;
  current(): Need | null {
    return this.#current;
  }

  busy(): boolean {
    return this.#asked > 0;
  }

  /// `ws`'s last move or move back that ended here.
  last(ws: string): Last | null {
    return this.#last[ws] ?? null;
  }

  /// Begun: what was stopped is stopped again (a hold is the process's).
  async start(): Promise<void> {
    // (a turn under way as the station stopped: its outcome says so)
    const cut = await readFile(turnFile(this.#d.data), "utf8").then((t) => JSON.parse(t) as { ws: string; how: Last["how"]; station: string; by: string | null }, () => null);
    if (cut !== null) {
      await this.#keepLast(cut.ws, { at: this.#d.now?.() ?? 0, by: cut.by, how: cut.how, station: cut.station, done: [], refused: [], stopped: [], resumed: [], failed: { item: null, error: this.#d.restarted?.() ?? "the station restarted during the move: what moved stays moved; ask again to go on" } });
      await rm(turnFile(this.#d.data), { force: true });
    }
    // (what waits here for an item that is here after all goes on: a stop between stopping it and the move)
    await this.settleStopped();
    // (one that moved after all, its leaving here not saved yet as a turn ended: kept no more)
    const moved = this.#stopped.values().filter((s) => this.#modules.get(s.item.module)?.state({ module: s.item.module, id: s.item.id, label: s.item.id, needs: [] }).state === "there");
    if (moved.length > 0) await this.#letGo(moved, false);
    for (const s of this.#stopped.values()) {
      const m = this.#modules.get(s.item.module);
      await m?.stop?.({ module: s.item.module, id: s.item.id, label: s.item.id, needs: [s.waitsFor] }, s.waitsFor).catch((e) => log.warn("move", "an item not stopped again", { item: named(s.item), error: (e as Error).message }));
    }
  }

  /// The items stopped here whose need is here (its module lists it here, not moved, or it is usable here) let go:
  /// as the station starts, and as a station an item came from is heard again (a tell of its coming that was lost).
  /// `from`: only what waits for what is at that station (it was heard from): each need looked at once, however many
  /// wait for it.
  async settleStopped(from?: string): Promise<Need[]> {
    if (this.#settling !== null) return await this.#settling;
    const run = (async () => {
      const going: Need[] = [];
      const plans = new Map<string, Items<Planned> | null>();
      for (const { waitsFor, ws } of this.#stopped.needs(from)) {
        // (a need the turn under way is moving is not settled meanwhile: here still as it leaves, what it stopped would
        // go on with it gone; the turn lets go of what waits for it itself, as it ends either way)
        if (this.#current !== null && named(this.#current) === named(waitsFor)) continue;
        const m = this.#modules.get(waitsFor.module);
        const bare: Item = { module: waitsFor.module, id: waitsFor.id, label: waitsFor.id, needs: [] };
        const waiting = () => this.#stopped.waitingFor(waitsFor).filter((s) => s.ws === ws).map((s) => s.item);
        // (a module that knows by itself whether it has the item says so; else its plan here does)
        if (m?.isHere !== undefined) {
          if (m.isHere(bare) || m.usableHere?.(bare) === true) going.push(...waiting());
          continue;
        }
        if (!plans.has(ws)) {
          const plan = await this.plan(ws, "").catch(() => null);
          plans.set(ws, plan === null ? null : new Items(plan.items));
        }
        const x = plans.get(ws)?.find(waitsFor);
        if (x !== undefined && (x.state === "here" || x.state === "failed" || m?.usableHere?.(x) === true)) going.push(...waiting());
      }
      // (what waits for an item a move back under way brings here is that turn's to let go, as the item arrives:
      // its outcome says it went on, `resumed`)
      const ours = going.flatMap((g) => this.#stopped.get(g) ?? []).filter((s) => !this.#bringing.has(named(s.waitsFor)));
      going.length = 0;
      going.push(...ours.map((s) => s.item));
      if (going.length > 0) {
        await this.#letGo(ours, true);
        this.#d.changed?.();
      }
      return going;
    })();
    this.#settling = run;
    try {
      return await run;
    } finally {
      this.#settling = null;
    }
  }
  #settling: Promise<Need[]> | null = null;
  /// What the move back under way brings here (each item's name): what waits for one of them it lets go itself.
  #bringing = new Set<string>();

  /// How many stopped items and needs were looked at so far (a test's: a move's own work, by what is stopped).
  stoppedLooked(): number {
    return this.#stopped.looked;
  }

  /// Whether anything is stopped here (waiting for what is at `at`, where given).
  hasStopped(at?: string): boolean {
    return this.#stopped.needs(at).length > 0;
  }

  /// What waits for what here.
  stopped(): { item: Need; waitsFor: Need }[] {
    return this.#stopped.values().map((s) => ({ item: s.item, waitsFor: s.waitsFor }));
  }

  /// What a move of `ws` to `to` would be: every module's items, where each stands, what each would stop.
  /// The plan as an agent reads it (station_move plan, status): while a turn toward `to` runs, the turn's own plan, each
  /// item where it stands now (no page of the station read again, nothing asked of the other); else planned anew.
  async planShown(ws: string, to: string): Promise<Plan> {
    const h = this.#held;
    if (h !== null && h.ws === ws && h.to === to) return { ...h.plan, items: h.plan.items.map((x) => this.#now(x)) };
    return await this.plan(ws, to);
  }

  /// The turn under way's own plan, for a page read while it runs (routes.ts `moveView`'s `held`): each module's items in
  /// the plan's order, each one's place among them, and per module how many there are, cannot go and are there, kept as
  /// items end; a row's state is asked as it is shown. Null: no turn toward `to` of `ws` runs.
  held(ws: string, to: string): { plan: Plan; view: Held } | null {
    const h = this.#held;
    if (h === null || h.ws !== ws || h.to !== to) return null;
    return { plan: h.plan, view: { byModule: h.byModule, at: h.at, counts: h.counts, now: (x) => this.#now(x) } };
  }

  /// Item `x` of the turn's plan as it stands now: what the plan said of it, but its state, the module's and the
  /// stopped set's now.
  #now(x: Planned): Planned {
    const { state: _s, error: _e, progress: _p, waitsFor: _w, at: _a, waits: _ws, from: _f, lentTo: _l, ...item } = x;
    const { at, ...st } = this.#stateOf(item);
    return { ...item, ...st, ...(at !== undefined && at !== this.#held?.to ? { at } : {}), wouldStop: x.wouldStop };
  }

  #held: (Omit<Held, "now"> & { ws: string; to: string; plan: Plan }) | null = null;

  /// The turn's plan held for the pages read while it runs (one pass over it, as the turn begins).
  #hold(ws: string, to: string, plan: Plan): void {
    const byModule = new Map<string, Planned[]>();
    const at = new Map<string, number>();
    const counts = new Map<string, { done: number; total: number; cannot: number }>();
    for (const x of plan.items) {
      const list = byModule.get(x.module) ?? [];
      at.set(named(x), list.length);
      list.push(x);
      byModule.set(x.module, list);
      const c = counts.get(x.module) ?? { done: 0, total: 0, cannot: 0 };
      c.total++;
      if (x.state === "there") c.done++;
      else if (x.state === "here" && x.cannot !== undefined) c.cannot++;
      counts.set(x.module, c);
    }
    this.#held = { ws, to, plan, byModule, at, counts };
  }

  /// Item `x` there (1) or here again (-1): its module's count of those there, as it ends.
  #ended(x: Need, there: 1 | -1): void {
    const c = this.#held?.counts.get(x.module);
    if (c !== undefined) c.done = Math.max(0, Math.min(c.total, c.done + there));
  }

  async plan(ws: string, to: string): Promise<Plan> {
    const items: Item[] = [];
    const reads = this.#d.reads?.(ws);
    // (the workspace's chats read first, a page at a time, so that a module that plans without waiting has them)
    await reads?.load();
    let first = true;
    for (const m of this.#modules.values()) {
      // (the main thread given back between modules, as between a module's pages)
      if (!first) await new Promise<void>((resolve) => setImmediate(resolve));
      first = false;
      for (const item of await m.plan(ws, to, reads)) {
        for (const n of item.needs) if (!m.needs.includes(n.module)) throw new Error(`module ${m.id}'s item ${item.id} needs ${named(n)}, of a module it does not declare`);
        items.push(item);
      }
    }
    // (a chain of items needing each other round: those cannot move, said naming it; the rest are planned as ever)
    const cycles = itemCycles(items.filter((x) => x.cannot === undefined));
    for (let at = 0; at < items.length; at++) {
      const chain = items[at]!.cannot === undefined ? cycles.get(named(items[at]!)) : undefined;
      if (chain !== undefined) items[at] = { ...items[at]!, cannot: say("cycle", { chain: chain.map(called).join(" → ") }) };
    }
    const planned: Planned[] = items.map((item) => {
      const { at, ...st } = this.#stateOf(item);
      // (where it is, said only where that is neither here nor the station the plan is toward)
      return { ...item, ...st, ...(at !== undefined && at !== to ? { at } : {}), wouldStop: [] };
    });
    const index = new Items(planned);
    for (const p of planned) {
      // (one there already stops nothing by a move: what it stopped as it went is stopped, said by its own row)
      if (p.state === "there" || this.#modules.get(p.module)!.usableHere?.(p) === true) continue;
      p.wouldStop = index.needing(p).filter((x) => x.state !== "there").map((x) => ({ module: x.module, id: x.id }));
    }
    return { ws, to, modules: [...this.#modules.values()].map((m) => ({ id: m.id, needs: m.needs })), items: planned };
  }

  #stateOf(item: Item): ItemState {
    const st = this.#modules.get(item.module)!.state(item);
    const s = this.#stopped.get(item);
    if (s !== undefined && st.state === "here") return { ...st, state: "stopped", waitsFor: s.waitsFor };
    return st;
  }

  /// Moves what `sel` names of `ws` to `to`, in the order their needs make; `by`: who asked (`Last`).
  move(ws: string, to: string, sel: Selection, by: string | null = null): Promise<Outcome> {
    return this.#queue(ws, "move", to, by, () => this.#move(ws, to, sel));
  }

  /// Moves back what `sel` names of `ws` from `from`, in the reverse order.
  back(ws: string, from: string, sel: Selection, by: string | null = null): Promise<Outcome> {
    return this.#queue(ws, "back", from, by, () => this.#back(ws, from, sel));
  }

  /// One turn after the others, its outcome kept as `ws`'s last.
  #queue(ws: string, how: Last["how"], station: string, by: string | null, f: () => Promise<Outcome>): Promise<Outcome> {
    this.#asked++;
    let letGo: (() => void) | null = null;
    const run = this.#turn.then(async () => {
      const why = await this.#d.refusal?.(ws, station);
      if (why) throw new Said(why);
      // (held from its first item to its end: an update would cut it)
      letGo = this.#d.hold?.() ?? null;
      this.#d.turn?.(true, station);
      await mkdir(dirname(turnFile(this.#d.data)), { recursive: true });
      await writeFile(turnFile(this.#d.data), JSON.stringify({ ws, how, station, by }));
      return await f();
    }).then(
      async (out) => {
        await this.#keepLast(ws, { at: this.#d.now?.() ?? 0, by, how, station, ...(this.#stopping !== null ? { stoppedBy: this.#stopping.by } : {}), ...out });
        return out;
      },
      async (e) => {
        await this.#keepLast(ws, { at: this.#d.now?.() ?? 0, by, how, station, ...(this.#stopping !== null ? { stoppedBy: this.#stopping.by } : {}), done: [], refused: [], stopped: [], resumed: [], failed: { item: null, error: sayOf(e, "the turn") } });
        throw e;
      },
    ).finally(async () => {
      await rm(turnFile(this.#d.data), { force: true }).catch(() => {});
      this.#d.turn?.(false, station);
      (letGo as (() => void) | null)?.();
      this.#asked--;
      this.#stopping = null;
      this.#current = null;
      this.#bringing = new Set();
      this.#held = null;
      this.#d.changed?.();
    });
    this.#turn = run.catch(() => {});
    return run;
  }

  /// (kept in memory at once; a write that fails costs only its keeping across a start)
  async #keepLast(ws: string, last: Last): Promise<void> {
    this.#last = { ...this.#last, [ws]: last };
    const path = lastFile(this.#d.data);
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    try {
      await mkdir(dirname(path), { recursive: true });
      await writeFile(tmp, JSON.stringify(this.#last));
      await rename(tmp, path);
    } catch (e) {
      log.warn("move", "the last move not kept", { error: (e as Error).message });
    }
  }

  async #move(ws: string, to: string, sel: Selection): Promise<Outcome> {
    const out: Outcome = { done: [], refused: [], stopped: [], resumed: [], failed: null };
    const plan = await this.plan(ws, to);
    this.#hold(ws, to, plan);
    const all = plan.items;
    const index = new Items(all);
    const find = (n: Need) => index.find(n);
    const chosen = select(all, sel);
    if (chosen.length === 0) throw new Said(sel.item !== undefined ? say("noItem", { item: called({ module: sel.module ?? "", label: sel.item }) }) : say("nothing"));
    // (with its needs: what it needs first, and what those need)
    const wanted = new Map<string, Planned>();
    const taking = new Set<string>();
    /// Needs lent, not moved, for what needs them (a login shared with the other, this station its host): by name, and
    /// the items of the turn they are lent for; lent just before the first of those goes.
    const lending = new Map<string, { x: Planned; for: Need[] }>();
    // (asked for some items with what they need, not for all: a need whose leaving would stop other items here is not
    // taken along for their sake, and the item that needs it is refused saying so: that need moves from its own row,
    // which says what it stops)
    const chosenNames = new Set(chosen.map(named));
    const refusedWhy = new Map<string, string>();
    /// Why need `x` cannot be had there: its own `cannot`, or a need of its own that cannot (said one step further);
    /// `again`: of this turn only (the other did not answer). Null: it can, or is there, or usable there.
    const cannotOf = (x: Planned, seen = new Set<string>()): { why: string; again: boolean } | null => {
      if (x.state === "there" || this.#modules.get(x.module)!.usableThere?.(x) === true) return null;
      if (x.cannot !== undefined) return { why: x.cannot, again: x.again === true };
      if (seen.has(named(x))) return null;
      seen.add(named(x));
      for (const n of x.needs) {
        const y = find(n);
        const c = y === undefined ? null : cannotOf(y, seen);
        if (c !== null) return { why: needCannot(y!, c.why), again: c.again };
      }
      return null;
    };
    const cannotGo = (p: Planned) => {
      for (const n of p.needs) {
        const x = find(n);
        const c = x === undefined ? null : cannotOf(x);
        if (c !== null) return { x: x!, ...c };
      }
      return undefined;
    };
    const wouldStopOthers = (x: Planned) => {
      if (this.#modules.get(x.module)!.usableHere?.(x) === true) return [];
      return index.needing(x).filter((y) => y.state !== "there" && !chosenNames.has(named(y)) && this.#modules.get(y.module)!.stop !== undefined);
    };
    const take = (p: Planned) => {
      const k = named(p);
      if (wanted.has(k) || taking.has(k)) return;
      taking.add(k);
      // (a need that cannot go and is not usable there: what needs it is refused in its words, nothing of it tried;
      // one that cannot ever go leaves the way of arriving stopped there, waiting for it; one not answered this turn none)
      const blocked = p.cannot === undefined ? cannotGo(p) : undefined;
      if (blocked !== undefined && (blocked.again || sel.arriveStopped !== true)) {
        refusedWhy.set(k, needCannot(blocked.x, blocked.why) + (blocked.again ? "" : say("orArrive")));
        return;
      }
      if (sel.withNeeds === true || sel.all === true) {
        for (const n of p.needs) {
          const x = find(n);
          // (a need usable there already, an account the other borrows, is not taken along: in `all` it goes as its own)
          if (x === undefined || x.state === "there" || this.#modules.get(x.module)!.usableThere?.(x) === true) continue;
          // (one that can be made usable there without moving it is lent for it: its host stays here, nothing of it can be
          // stranded on the other; it moves only asked for itself, after what needs it)
          if (this.#modules.get(x.module)!.canLend?.(x) === true) {
            const l = lending.get(named(x)) ?? { x, for: [] };
            l.for.push({ module: p.module, id: p.id });
            lending.set(named(x), l);
            continue;
          }
          // (a need on a round of items needing each other is refused as that round, before this rule speaks)
          const others = sel.all === true || p.cannot !== undefined || x.cannot !== undefined ? [] : wouldStopOthers(x);
          if (others.length > 0) {
            const some = others.slice(0, 3).map(called).join("、");
            const more = others.length > 3 ? say("more", { n: others.length - 3 }) : "";
            refusedWhy.set(k, say("wouldStop", { need: called(x), some: `${some}${more}` }));
            refusedWhy.set(named(x), say("wouldStopIt", { some: `${some}${more}` }));
            continue;
          }
          take(x);
        }
      }
      wanted.set(k, p);
    };
    // (an item refused by what moves nothing is refused before any need of it moves: nothing is moved for it)
    const notReady = new Map<string, string>();
    for (const p of chosen) {
      const why = await this.#modules.get(p.module)!.ready?.(p, to);
      if (typeof why === "string") notReady.set(named(p), why);
    }
    for (const p of chosen) {
      if (notReady.has(named(p))) out.refused.push({ item: { module: p.module, id: p.id }, why: notReady.get(named(p))! });
      else take(p);
    }
    for (const k of refusedWhy.keys()) {
      const x = index.find({ module: k.slice(0, k.indexOf(" ")), id: k.slice(k.indexOf(" ") + 1) });
      if (x !== undefined) out.refused.push({ item: { module: x.module, id: x.id }, why: refusedWhy.get(k)! });
    }
    const thereNow = new Set(all.filter((x) => x.state === "there").map(named));
    // (an item whose move stops others here goes as late as it can, what it stops right after it: the owner's, an
    // account that cannot be shared followed at once by its chats)
    const stopsOthers = (p: Planned) => this.#modules.get(p.module)!.usableHere?.(p) !== true && index.needing(p).some((x) => !thereNow.has(named(x)) && this.#modules.get(x.module)!.stop !== undefined);
    const going = sel.all === true || sel.withNeeds === true ? lateOrder([...wanted.values()], find, stopsOthers) : order([...wanted.values()], find);
    // (what moved here leaves the stopped set at once and is saved so as the turn ends: a start drops one that moved)
    let unsaved = false;
    // (an item that fails stops only what needs it: every other item of the turn goes on)
    const failedHere = new Map<string, string>();
    const fail = (p: Need, error: string) => {
      out.failures = [...(out.failures ?? []), { item: { module: p.module, id: p.id }, error }];
      out.failed ??= { item: { module: p.module, id: p.id }, error };
      failedHere.set(named(p), error);
    };
    const lentNow = new Set<string>();
    /// Items asked for themselves that were lent this turn for what needs them: moved after the rest.
    const hostAfter: Planned[] = [];
    for (const p of going) {
      if (this.#stopping !== null) break;
      if (thereNow.has(named(p)) || refusedWhy.has(named(p))) continue;
      if (p.cannot !== undefined) {
        out.refused.push({ item: p, why: p.cannot });
        continue;
      }
      if (lending.has(named(p))) {
        hostAfter.push(p);
        continue;
      }
      // (what it needs that is lent for it, lent now, before it goes)
      for (const n of p.needs) {
        const l = lending.get(named(n));
        if (l === undefined || lentNow.has(named(n)) || failedHere.has(named(n))) continue;
        try {
          this.#current = l.x;
          await this.#modules.get(l.x.module)!.lend!(l.x, to, l.for);
          lentNow.add(named(n));
          out.lent = [...(out.lent ?? []), { module: l.x.module, id: l.x.id }];
          this.#d.changed?.();
        } catch (e) {
          fail(l.x, sayOf(e, named(l.x)));
        }
      }
      const waits = p.needs.find((n) => !thereNow.has(named(n)) && find(n) !== undefined && this.#modules.get(n.module)!.usableThere?.(find(n)!) !== true);
      const waitsFailed = waits === undefined ? undefined : failedHere.get(named(waits));
      if (waitsFailed !== undefined) {
        out.refused.push({ item: p, why: say("waitsFailed", { need: called(find(waits!)!), why: waitsFailed }) });
        continue;
      }
      if (waits !== undefined && sel.arriveStopped !== true) {
        out.refused.push({ item: p, why: say("needsFirst", { need: called(find(waits)!) }) });
        continue;
      }
      const m = this.#modules.get(p.module)!;
      // What here needs it and cannot have it here once it went is stopped first (its account moving away would move
      // it onto another), and goes on where the move fails.
      const stops: Planned[] = m.usableHere?.(p) === true ? [] : index.needing(p).filter((x) => !thereNow.has(named(x)) && !this.#stopped.has(x) && this.#modules.get(x.module)!.stop !== undefined);
      // (kept stopped before it is held: no read sees it held and not said stopped)
      this.#current = p;
      for (const x of stops) {
        const waitsFor: Waits = { module: p.module, id: p.id, label: p.label, at: to };
        this.#stopped.add({ item: { module: x.module, id: x.id }, waitsFor, ws });
        await this.#modules.get(x.module)!.stop!(x, waitsFor).catch((e) => {
          this.#stopped.remove(x);
          throw e;
        });
      }
      if (stops.length > 0 || unsaved) (await this.#saveStopped(), (unsaved = false));
      try {
        await m.move(p, to, (progress) => this.#d.progress?.(p, progress), waits === undefined ? undefined : { stoppedFor: { module: waits.module, id: waits.id, label: find(waits)?.label } });
      } catch (e) {
        fail(p, sayOf(e, named(p)));
        await this.#letGo(stops.flatMap((x) => this.#stopped.get(x) ?? []).filter((s) => sameItem(s.waitsFor, p)), true);
        unsaved = false;
        continue;
      }
      // (what waits for it there goes on)
      await this.#d.tellArrived?.(to, { module: p.module, id: p.id }).catch((e) => log.warn("move", "the other station not told what came", { item: named(p), error: (e as Error).message }));
      thereNow.add(named(p));
      out.done.push({ module: p.module, id: p.id });
      this.#ended(p, 1);
      for (const x of stops) out.stopped.push({ item: { module: x.module, id: x.id }, waitsFor: { module: p.module, id: p.id } });
      // (moved where its need is: no longer stopped here)
      if (this.#stopped.remove(p) !== undefined) unsaved = true;
      this.#d.changed?.();
    }
    // (lent for what moved and asked for itself too: its host moves now, after what needed it)
    for (const p of hostAfter) {
      if (this.#stopping !== null) break;
      this.#current = p;
      try {
        await this.#modules.get(p.module)!.move(p, to, (progress) => this.#d.progress?.(p, progress));
      } catch (e) {
        fail(p, sayOf(e, named(p)));
        continue;
      }
      thereNow.add(named(p));
      out.done.push({ module: p.module, id: p.id });
      this.#ended(p, 1);
      this.#d.changed?.();
    }
    // (what was lent for items that did not go is taken back: the last of them here, nothing of it stays lent)
    const notGone = (out.failures ?? []).map((f) => f.item).filter((x) => !lending.has(named(x)));
    if (notGone.length > 0) for (const m of this.#modules.values()) await m.left?.(notGone).catch((e) => log.warn("move", "what was lent for items that did not go not taken back", { error: (e as Error).message }));
    // (what the turn left lent, not what it lent and took back: nothing of that left here, nothing to tell)
    if (out.lent !== undefined) {
      out.lent = out.lent.filter((n) => {
        const x = find(n);
        return x !== undefined && this.#modules.get(x.module)!.state(x).lentTo !== undefined;
      });
      if (out.lent.length === 0) delete out.lent;
    }
    // (what moved only for items of this turn that then did not go is brought back, in the same turn, and said so: a
    // login moved for a chat that failed is not left on the other station)
    {
      const doneNow = new Set(out.done.map(named));
      for (const x of [...out.done].reverse()) {
        const p = find(x);
        if (p === undefined || chosenNames.has(named(x))) continue;
        const forWhom = index.needing(p).filter((y) => wanted.has(named(y)));
        if (forWhom.length === 0 || forWhom.some((y) => doneNow.has(named(y)))) continue;
        try {
          await this.#modules.get(p.module)!.back(p, to);
        } catch (e) {
          fail(p, say("notBroughtBack", { for: forWhom.map(called).join("、"), what: called(p), why: sayOf(e, named(p)) }));
          continue;
        }
        out.done = out.done.filter((d) => !sameItem(d, x));
        this.#ended(x, -1);
        doneNow.delete(named(x));
        out.returned = [...(out.returned ?? []), { module: x.module, id: x.id }];
        // (what waited here for it goes on)
        const waited = this.#stopped.waitingFor(p);
        if (waited.length > 0) {
          for (const s of waited) out.resumed.push(s.item);
          await this.#letGo(waited, true);
          out.stopped = out.stopped.filter((s) => !sameItem(s.waitsFor, x));
        }
      }
    }
    // (what follows what moved: the items of `follow` that need only what is there now)
    if (sel.follow !== undefined && out.done.length > 0) {
      const after = await this.plan(ws, to);
      const there = new Set(after.items.filter((x) => x.state === "there").map(named));
      const done = new Set(out.done.map(named));
      const afterIndex = new Items(after.items);
      for (const p of order(after.items.filter((x) => sel.follow!.includes(x.module) && x.state !== "there" && x.cannot === undefined && x.needs.length > 0 && x.needs.every((n) => there.has(named(n))) && x.needs.some((n) => done.has(named(n)))), (n) => afterIndex.find(n))) {
        try {
          await this.#modules.get(p.module)!.move(p, to, (progress) => this.#d.progress?.(p, progress));
          out.done.push({ module: p.module, id: p.id });
          this.#ended(p, 1);
          if (this.#stopped.remove(p) !== undefined) unsaved = true;
        } catch (e) {
          fail(p, sayOf(e, named(p)));
        }
      }
    }
    if (unsaved) await this.#saveStopped();
    this.#d.changed?.();
    return out;
  }

  async #back(ws: string, from: string, sel: Selection): Promise<Outcome> {
    const out: Outcome = { done: [], refused: [], stopped: [], resumed: [], failed: null };
    const plan = await this.plan(ws, from);
    this.#hold(ws, from, plan);
    const all = plan.items;
    const index = new Items(all);
    const find = (n: Need) => index.find(n);
    // (what is there now: one whose move failed is here, no item of a move back)
    const chosen = select(all, sel).filter((x) => x.state === "there");
    if (chosen.length === 0) throw new Said(sel.item !== undefined ? say("notThere", { item: called({ module: sel.module ?? "", label: sel.item }) }) : say("nothingThere"));
    const backing = new Set(chosen.map(named));
    // (what follows what goes back: the items of `follow` there that need it, a chat's jobs, go back first, each arriving
    // stopped until it is here)
    if (sel.follow !== undefined) for (const p of chosen) for (const x of index.needing(p)) if (sel.follow.includes(x.module) && x.state === "there") backing.add(named(x));
    // (with what needs it, where the whole is asked back)
    if (sel.all === true || sel.withNeeds === true) {
      const queue = [...chosen];
      for (let i = 0; i < queue.length; i++) {
        for (const x of index.needing(queue[i]!)) if (x.state === "there" && !backing.has(named(x))) (backing.add(named(x)), queue.push(x));
      }
    }
    this.#bringing = backing;
    const stillThere = new Set(all.filter((x) => x.state === "there").map(named));
    // (an item that fails stops only what needs it: every other item of the turn goes on)
    const failedThere = new Map<string, string>();
    for (const p of order(all.filter((x) => backing.has(named(x))), find).reverse()) {
      if (this.#stopping !== null) break;
      this.#current = p;
      const dependent = index.needing(p).find((x) => stillThere.has(named(x)));
      if (dependent !== undefined) {
        const failed = failedThere.get(named(dependent));
        out.refused.push({ item: p, why: failed !== undefined ? say("backNeedsFailed", { item: called(dependent), why: failed }) : say("backNeeds", { item: called(dependent) }) });
        continue;
      }
      // (what it needs that is still there and cannot be had here: it comes back stopped, waiting for it)
      const waits = p.needs.map(find).find((n): n is Planned => n !== undefined && stillThere.has(named(n)) && this.#modules.get(n.module)!.usableHere?.(n) !== true);
      try {
        await this.#modules.get(p.module)!.back(p, from, waits === undefined ? undefined : { stoppedFor: { module: waits.module, id: waits.id, label: waits.label } });
      } catch (e) {
        const error = sayOf(e, named(p));
        out.failures = [...(out.failures ?? []), { item: { module: p.module, id: p.id }, error }];
        out.failed ??= { item: { module: p.module, id: p.id }, error };
        failedThere.set(named(p), error);
        continue;
      }
      if (waits !== undefined) {
        await this.noteStopped({ module: p.module, id: p.id }, { module: waits.module, id: waits.id, label: waits.label, at: from }, ws, false);
        out.stopped.push({ item: { module: p.module, id: p.id }, waitsFor: { module: waits.module, id: waits.id } });
      }
      stillThere.delete(named(p));
      out.done.push({ module: p.module, id: p.id });
      this.#ended(p, -1);
      // (here again: what was lent for it alone is taken back)
      for (const m of this.#modules.values()) await m.left?.([{ module: p.module, id: p.id }]).catch((e) => log.warn("move", "what was lent for an item back here not taken back", { error: (e as Error).message }));
      // (what waited here for it goes on)
      const waited = this.#stopped.waitingFor(p);
      if (waited.length > 0) {
        for (const s of waited) out.resumed.push(s.item);
        await this.#letGo(waited, true);
      }
      this.#d.changed?.();
    }
    return out;
  }

  /// An item that arrived here stopped, waiting for `waitsFor` (a hand-over with `stoppedFor`): kept stopped here,
  /// held by its module (`hold`; false: it held itself as it arrived).
  /// Kept stopped and held are one fact: one listed already is held again, waiting for what it waits for now (where
  /// that is may have changed: its login moved on since).
  async noteStopped(item: Need, waitsFor: Waits, ws: string, hold = true): Promise<void> {
    if (hold) await this.#modules.get(item.module)?.stop?.({ module: item.module, id: item.id, label: item.id, needs: [waitsFor] }, waitsFor);
    if (this.#stopped.has(item)) this.#stopped.remove(item);
    this.#stopped.add({ item, waitsFor, ws });
    await this.#saveStopped();
    this.#d.changed?.();
  }

  /// Items `gone` went from here (a chat handed to another station): no longer stopped here, nothing let go or resumed
  /// (one that comes back is stopped anew as it arrives, `noteStopped`).
  async forget(gone: Need[]): Promise<void> {
    let changed = false;
    for (const item of gone) if (this.#stopped.remove(item) !== undefined) changed = true;
    if (!changed) return;
    await this.#saveStopped();
    this.#d.changed?.();
  }

  /// `item` is here now (another station moved it here): what waited here for it goes on.
  async arrived(item: Need): Promise<Need[]> {
    const waited = this.#stopped.waitingFor(item);
    const going = waited.map((s) => s.item);
    await this.#letGo(waited, true);
    this.#d.changed?.();
    return going;
  }

  /// The stopped items `gone` let go (`resume`: told to go on here; else they moved).
  async #letGo(gone: readonly Stopped[], resume: boolean): Promise<void> {
    if (gone.length === 0) return;
    for (const s of gone) this.#stopped.remove(s.item);
    await this.#saveStopped();
    if (!resume) return;
    for (const s of gone) {
      const m = this.#modules.get(s.item.module);
      await m?.resume?.({ module: s.item.module, id: s.item.id, label: s.item.id, needs: [s.waitsFor] }).catch((e) => log.warn("move", "an item not let go", { item: named(s.item), error: (e as Error).message }));
    }
  }

  /// What was changed of the stopped items written (each change its own line, written as it was made).
  async #saveStopped(): Promise<void> {
    await this.#stopped.written();
  }
}

const needKey = (s: Stopped) => `${named(s.waitsFor)}\t${s.waitsFor.at ?? ""}\t${s.ws}`;

/// What is stopped here (`stopped.log`, a line an item stopped or let go), by each item's name and by what it waits
/// for: each lookup a map's, each change written alone.
class StoppedSet {
  readonly #by = new Map<string, Stopped>();
  readonly #waiting = new Map<string, Set<string>>();
  /// Each need waited for, by its name, where it is and the workspace of those that wait: how many wait so.
  readonly #needs = new Map<string, { waitsFor: Waits; ws: string; n: number }>();
  readonly #log: KeptLog<Stopped>;
  #writing: Promise<void> = Promise.resolve();
  constructor(log: KeptLog<Stopped>) {
    this.#log = log;
    for (const s of log.values()) this.#keep(s);
  }
  /// Once what was changed so far is written.
  written(): Promise<void> {
    return this.#writing;
  }
  add(s: Stopped): void {
    if (!this.#keep(s)) return;
    this.#write(this.#log.set(named(s.item), s));
  }
  #write(done: Promise<void>): void {
    const was = this.#writing;
    this.#writing = Promise.all([was, done.catch((e) => log.warn("move", "a stopped item's change not written", { error: (e as Error).message }))]).then(() => undefined);
  }
  #keep(s: Stopped): boolean {
    const k = named(s.item);
    if (this.#by.has(k)) return false;
    this.#by.set(k, s);
    const w = named(s.waitsFor);
    const set = this.#waiting.get(w);
    if (set === undefined) this.#waiting.set(w, new Set([k]));
    else set.add(k);
    const nk = needKey(s);
    const need = this.#needs.get(nk);
    if (need === undefined) this.#needs.set(nk, { waitsFor: s.waitsFor, ws: s.ws, n: 1 });
    else need.n++;
    return true;
  }
  has(item: Need): boolean {
    return this.#by.has(named(item));
  }
  get(item: Need): Stopped | undefined {
    return this.#by.get(named(item));
  }
  remove(item: Need): Stopped | undefined {
    const k = named(item);
    const s = this.#by.get(k);
    if (s === undefined) return undefined;
    this.#by.delete(k);
    this.#waiting.get(named(s.waitsFor))?.delete(k);
    const need = this.#needs.get(needKey(s));
    if (need !== undefined && --need.n === 0) this.#needs.delete(needKey(s));
    this.#write(this.#log.delete(k));
    return s;
  }
  /// What the stopped wait for, each need once with the workspace of those that wait for it (`at`: those at that
  /// station alone, and those that say not where): as many as there are needs, however many wait.
  /// How many stopped items and needs were looked at (a test's: what a move's own work costs of what is stopped).
  looked = 0;
  needs(at?: string): { waitsFor: Waits; ws: string }[] {
    this.looked += this.#needs.size;
    return [...this.#needs.values()].filter((x) => at === undefined || x.waitsFor.at === undefined || x.waitsFor.at === at).map(({ waitsFor, ws }) => ({ waitsFor, ws }));
  }
  /// Those that wait for `n`, in the order they stopped.
  waitingFor(n: Need): Stopped[] {
    const keys = this.#waiting.get(named(n)) ?? new Set<string>();
    this.looked += keys.size;
    return [...keys].flatMap((k) => this.#by.get(k) ?? []);
  }
  values(): Stopped[] {
    this.looked += this.#by.size;
    return [...this.#by.values()];
  }
}

/// Items by what names them and by what they need, made once for a plan or a turn: what every lookup of the
/// scheduler's goes through, so that its work grows as the items do, never as their square.
export class Items<T extends Item> {
  readonly #by = new Map<string, T>();
  readonly #needing = new Map<string, T[]>();
  constructor(items: readonly T[]) {
    for (const x of items) if (!this.#by.has(named(x))) this.#by.set(named(x), x);
    for (const x of items) {
      for (const k of new Set(x.needs.map(named))) {
        const list = this.#needing.get(k);
        if (list === undefined) this.#needing.set(k, [x]);
        else list.push(x);
      }
    }
  }
  find(n: Need): T | undefined {
    return this.#by.get(named(n));
  }
  /// Those that need `n`, in their order.
  needing(n: Need): readonly T[] {
    return this.#needing.get(named(n)) ?? [];
  }
}

/// The items on a chain of items that need each other round, each with the chain it is on (the strongly connected
/// parts of their needs, Tarjan's): modules may need each other, items may not. Linear in the items and their needs.
function itemCycles(items: Item[]): Map<string, Item[]> {
  const by = new Map(items.map((x) => [named(x), x]));
  const index = new Map<string, number>();
  const low = new Map<string, number>();
  const on = new Set<string>();
  const stack: Item[] = [];
  const out = new Map<string, Item[]>();
  let next = 0;
  const visit = (x: Item) => {
    const k = named(x);
    index.set(k, next);
    low.set(k, next);
    next++;
    stack.push(x);
    on.add(k);
    for (const n of x.needs) {
      const y = by.get(named(n));
      if (y === undefined) continue;
      const j = named(y);
      if (!index.has(j)) {
        visit(y);
        low.set(k, Math.min(low.get(k)!, low.get(j)!));
      } else if (on.has(j)) low.set(k, Math.min(low.get(k)!, index.get(j)!));
    }
    if (low.get(k) !== index.get(k)) return;
    const part: Item[] = [];
    for (let y = stack.pop()!; ; y = stack.pop()!) {
      on.delete(named(y));
      part.push(y);
      if (named(y) === k) break;
    }
    const self = part.length === 1 && x.needs.some((n) => named(n) === k);
    if (part.length < 2 && !self) return;
    const chain = cycleThrough(x, new Set(part.map(named)), by);
    for (const y of part) out.set(named(y), chain);
  };
  for (const x of items) if (!index.has(named(x))) visit(x);
  return out;
}

/// A chain round from `start` back to it inside `part` (its names), as the chains were named before: `start`, what it
/// needs first in `part`, and so on, `start` again at its end.
function cycleThrough(start: Item, part: Set<string>, by: Map<string, Item>): Item[] {
  const from = new Map<string, Item | null>([[named(start), null]]);
  const queue: Item[] = [start];
  for (let i = 0; i < queue.length; i++) {
    const x = queue[i]!;
    for (const n of x.needs) {
      const y = by.get(named(n));
      if (y === undefined || !part.has(named(y))) continue;
      if (named(y) === named(start)) {
        const path: Item[] = [];
        for (let z: Item | null = x; z !== null; z = from.get(named(z)) ?? null) path.unshift(z);
        return [...path, start];
      }
      if (from.has(named(y))) continue;
      from.set(named(y), x);
      queue.push(y);
    }
  }
  return [start, start];
}

/// Why an item is refused for need `x`, which cannot go (and is not usable there): `x`'s own words of why (`why`).
const needCannot = (x: Item, why: string) => say("needCannot", { need: called(x), why });
/// An item as people call it: what it is (its module's word) and its label, never its id (kept in the outcome's fields).
export const called = (x: { module: string; label: string }) => tr(stationLang(), "station.move.called", { what: tr(stationLang(), `station.move.module.${x.module}`), label: x.module === "chats" ? x.label.replace(/^chat:/, "") : x.label });
/// What the scheduler says, in the station's language (`station.move.sched.*`).
const say = (key: string, args: Record<string, unknown> = {}) => tr(stationLang(), `station.move.sched.${key}`, args);

function select(all: Planned[], sel: Selection): Planned[] {
  if (sel.all === true) return all.filter((x) => sel.module === undefined || x.module === sel.module);
  if (sel.module === undefined) return [];
  return all.filter((x) => x.module === sel.module && (sel.item === undefined || x.id === sel.item));
}

/// `items` in the order of their needs, those that stop others (`stops`) as late as they can: first all that need none
/// of them, then each of them followed at once by what needs it (its other needs before it).
export function lateOrder<T extends Item>(items: T[], find: (n: Need) => T | undefined, stops: (x: T) => boolean): T[] {
  const ordered = order(items, find);
  const inside = new Set(ordered.map(named));
  const of = (n: Need) => {
    const y = find(n);
    return y !== undefined && inside.has(named(y)) ? y : undefined;
  };
  const behind = new Map<string, boolean>();
  const needsStopper = (x: T, path = new Set<string>()): boolean => {
    const k = named(x);
    if (behind.has(k)) return behind.get(k)!;
    if (path.has(k)) return false;
    path.add(k);
    const r = x.needs.some((n) => {
      const y = of(n);
      return y !== undefined && (stops(y) || needsStopper(y, path));
    });
    behind.set(k, r);
    return r;
  };
  const out: T[] = [];
  const done = new Set<string>();
  const busy = new Set<string>();
  const emit = (x: T) => {
    const k = named(x);
    if (done.has(k) || busy.has(k)) return;
    busy.add(k);
    for (const n of x.needs) {
      const y = of(n);
      if (y !== undefined) (stops(y) ? emitStopper(y) : emit(y));
    }
    busy.delete(k);
    if (done.has(k)) return;
    done.add(k);
    out.push(x);
  };
  const needing = new Items(ordered);
  const emitStopper = (s: T) => {
    if (done.has(named(s))) return;
    emit(s);
    for (const d of needing.needing(s)) emit(d);
  };
  for (const x of ordered) if (!stops(x) && !needsStopper(x)) emit(x);
  for (const x of ordered) if (stops(x)) emitStopper(x);
  for (const x of ordered) emit(x);
  return out;
}

/// `items` in the order their needs make (what an item needs before it; a need outside them as if there).
function order<T extends Item>(items: T[], find: (n: Need) => T | undefined): T[] {
  const out: T[] = [];
  const seen = new Set<string>();
  const among = new Set(items);
  const visit = (x: T, path: Set<string>) => {
    const k = named(x);
    if (seen.has(k) || path.has(k)) return;
    path.add(k);
    for (const n of x.needs) {
      const y = find(n);
      if (y !== undefined && among.has(y)) visit(y, path);
    }
    seen.add(k);
    out.push(x);
  };
  for (const x of items) visit(x, new Set());
  return out;
}
