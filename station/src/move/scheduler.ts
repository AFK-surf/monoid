// The scheduler of a migration (move/AGENTS.md): it only orders the modules' items (module.ts) and never does a
// module's work. An item moves once what it needs is there (it is refused naming what it waits for, or, asked
// `withNeeds`, those move first); it is moved back once nothing on the other station that needs it is still there
// (refused naming it). As an item moves away, each item still here that needs it and cannot have it here any more is
// stopped (a state of its own, kept here across starts: `stopped.json`), and goes on as what it waits for is back, or as
// it moves itself. What changes is told (`changed`), nothing is polled.
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { log } from "../ops/log.ts";
import { type Item, type ItemState, type Module, type Need, type PlanReads, type Progress, named, sameItem } from "./module.ts";

/// An item as a plan shows it: what it is, where it stands, and what would be stopped here if it moved alone.
export type Planned = Item & ItemState & { wouldStop: Need[] };
export type Plan = { ws: string; to: string; modules: { id: string; needs: readonly string[] }[]; items: Planned[] };
/// Which items: one (`module` and `item`), a module's (`module`), or all (`all`); `withNeeds`: what they need first;
/// `follow`: the items of these modules that need only what moved go with it (a chat's jobs).
/// `arriveStopped`: an item whose need is not there goes all the same, arriving there stopped, waiting for it.
export type Selection = { module?: string; item?: string; all?: boolean; withNeeds?: boolean; follow?: string[]; arriveStopped?: boolean };
/// What came of a move or a move back: moved in order; refused (not tried: why); stopped as their need went; the
/// failure it stopped at.
export type Outcome = { done: Need[]; refused: { item: Need; why: string }[]; stopped: { item: Need; waitsFor: Need }[]; resumed: Need[]; failed: { item: Need; error: string } | null };
/// The last move or move back of a workspace's, as the app shows it (GET /move `last`): when it ended, who asked (a
/// person's email; an agent's: its chat's session key), which way and with which station, and what came of it. A turn
/// that could not begin (its plan refused) has `failed` with no item.
export type Last = { at: number; by: string | null; how: "move" | "back"; station: string; stoppedBy?: string | null; done: Need[]; refused: { item: Need; why: string }[]; stopped: { item: Need; waitsFor: Need }[]; resumed: Need[]; failed: { item: Need | null; error: string } | null };
/// An item stopped here, kept: what it waits for, of which workspace.
type Stopped = { item: Need; waitsFor: Need; ws: string };

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
};

const stoppedFile = (data: string) => join(data, "move", "stopped.json");
const lastFile = (data: string) => join(data, "move", "last.json");
/// The turn under way (written as it begins, taken out as it ends): one found as the station starts was cut by a stop.
const turnFile = (data: string) => join(data, "move", "turn.json");

export class Scheduler {
  readonly #d: SchedulerDeps;
  readonly #modules = new Map<string, Module>();
  #stopped: Stopped[];
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
    try {
      this.#stopped = JSON.parse(readFileSync(stoppedFile(d.data), "utf8")) as Stopped[]; // sync: read once, before the station serves
    } catch {
      this.#stopped = [];
    }
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
    for (const s of this.#stopped) {
      const m = this.#modules.get(s.item.module);
      await m?.stop?.({ module: s.item.module, id: s.item.id, label: s.item.id, needs: [s.waitsFor] }, s.waitsFor).catch((e) => log.warn("move", "an item not stopped again", { item: named(s.item), error: (e as Error).message }));
    }
  }

  /// The items stopped here whose need is here (its module lists it here, not moved, or it is usable here) let go:
  /// as the station starts, and as a station an item came from is heard again (a tell of its coming that was lost).
  async settleStopped(): Promise<Need[]> {
    if (this.#settling !== null) return await this.#settling;
    const run = (async () => {
      const going: Need[] = [];
      const plans = new Map<string, Plan | null>();
      for (const s of this.#stopped) {
        const m = this.#modules.get(s.waitsFor.module);
        const bare: Item = { module: s.waitsFor.module, id: s.waitsFor.id, label: s.waitsFor.id, needs: [] };
        // (a module that knows by itself whether it has the item says so; else its plan here does)
        if (m?.isHere !== undefined) {
          if (m.isHere(bare) || m.usableHere?.(bare) === true) going.push(s.item);
          continue;
        }
        if (!plans.has(s.ws)) plans.set(s.ws, await this.plan(s.ws, "").catch(() => null));
        const x = plans.get(s.ws)?.items.find((y) => sameItem(y, s.waitsFor));
        if (x !== undefined && (x.state === "here" || x.state === "failed" || m?.usableHere?.(x) === true)) going.push(s.item);
      }
      if (going.length > 0) {
        await this.#unstop((s) => going.some((g) => sameItem(g, s.item)), true);
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

  /// What waits for what here.
  stopped(): { item: Need; waitsFor: Need }[] {
    return this.#stopped.map((s) => ({ item: s.item, waitsFor: s.waitsFor }));
  }

  /// What a move of `ws` to `to` would be: every module's items, where each stands, what each would stop.
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
    for (let i = 0, cycle = itemCycle(items.filter((x) => x.cannot === undefined)); cycle !== null && i < items.length; i++, cycle = itemCycle(items.filter((x) => x.cannot === undefined))) {
      const why = `these items need each other, so none can go first: ${cycle.map(named).join(" → ")}`;
      for (const x of cycle) {
        const at = items.findIndex((y) => sameItem(y, x));
        if (at >= 0 && items[at]!.cannot === undefined) items[at] = { ...items[at]!, cannot: why };
      }
    }
    const planned: Planned[] = items.map((item) => {
      const st = this.#stateOf(item);
      return { ...item, ...st, wouldStop: [] };
    });
    for (const p of planned) {
      if (this.#modules.get(p.module)!.usableHere?.(p) === true) continue;
      p.wouldStop = planned.filter((x) => x.state !== "there" && x.needs.some((n) => sameItem(n, p))).map((x) => ({ module: x.module, id: x.id }));
    }
    return { ws, to, modules: [...this.#modules.values()].map((m) => ({ id: m.id, needs: m.needs })), items: planned };
  }

  #stateOf(item: Item): ItemState {
    const st = this.#modules.get(item.module)!.state(item);
    const s = this.#stopped.find((x) => sameItem(x.item, item));
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
      if (why) throw new Error(why);
      // (held from its first item to its end: an update would cut it)
      letGo = this.#d.hold?.() ?? null;
      await mkdir(dirname(turnFile(this.#d.data)), { recursive: true });
      await writeFile(turnFile(this.#d.data), JSON.stringify({ ws, how, station, by }));
      return await f();
    }).then(
      async (out) => {
        await this.#keepLast(ws, { at: this.#d.now?.() ?? 0, by, how, station, ...(this.#stopping !== null ? { stoppedBy: this.#stopping.by } : {}), ...out });
        return out;
      },
      async (e) => {
        await this.#keepLast(ws, { at: this.#d.now?.() ?? 0, by, how, station, ...(this.#stopping !== null ? { stoppedBy: this.#stopping.by } : {}), done: [], refused: [], stopped: [], resumed: [], failed: { item: null, error: (e as Error).message } });
        throw e;
      },
    ).finally(async () => {
      await rm(turnFile(this.#d.data), { force: true }).catch(() => {});
      (letGo as (() => void) | null)?.();
      this.#asked--;
      this.#stopping = null;
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
    const all = plan.items;
    const find = (n: Need) => all.find((x) => sameItem(x, n));
    const chosen = select(all, sel);
    if (chosen.length === 0) throw new Error(sel.item !== undefined ? `no item ${sel.module ?? ""} ${sel.item} here to move (station_move plan lists them)` : "nothing to move");
    // (with its needs: what it needs first, and what those need)
    const wanted = new Map<string, Planned>();
    const taking = new Set<string>();
    const take = (p: Planned) => {
      const k = named(p);
      if (wanted.has(k) || taking.has(k)) return;
      taking.add(k);
      if (sel.withNeeds === true || sel.all === true) for (const n of p.needs) { const x = find(n); if (x !== undefined && x.state !== "there") take(x); }
      wanted.set(k, p);
    };
    for (const p of chosen) take(p);
    const thereNow = new Set(all.filter((x) => x.state === "there").map(named));
    // (an item whose move stops others here goes as late as it can, what it stops right after it: the owner's, an
    // account that cannot be shared followed at once by its chats)
    const stopsOthers = (p: Planned) => this.#modules.get(p.module)!.usableHere?.(p) !== true && all.some((x) => !thereNow.has(named(x)) && x.needs.some((n) => sameItem(n, p)) && this.#modules.get(x.module)!.stop !== undefined);
    const going = sel.all === true || sel.withNeeds === true ? lateOrder([...wanted.values()], find, stopsOthers) : order([...wanted.values()], find);
    for (const p of going) {
      if (out.failed !== null || this.#stopping !== null) break;
      if (thereNow.has(named(p))) continue;
      if (p.cannot !== undefined) {
        out.refused.push({ item: p, why: p.cannot });
        continue;
      }
      const waits = p.needs.find((n) => !thereNow.has(named(n)) && find(n) !== undefined);
      if (waits !== undefined && sel.arriveStopped !== true) {
        out.refused.push({ item: p, why: `it needs ${named(waits)} (${find(waits)!.label}) there first: move that first, or ask with withNeeds (or arriveStopped: it waits there for it)` });
        continue;
      }
      const m = this.#modules.get(p.module)!;
      // What here needs it and cannot have it here once it went is stopped first (its account moving away would move
      // it onto another), and goes on where the move fails.
      const stops: Planned[] = m.usableHere?.(p) === true ? [] : all.filter((x) => !thereNow.has(named(x)) && x.needs.some((n) => sameItem(n, p)) && !this.#stopped.some((s) => sameItem(s.item, x)) && this.#modules.get(x.module)!.stop !== undefined);
      for (const x of stops) {
        await this.#modules.get(x.module)!.stop!(x, { module: p.module, id: p.id });
        this.#stopped.push({ item: { module: x.module, id: x.id }, waitsFor: { module: p.module, id: p.id }, ws });
      }
      if (stops.length > 0) await this.#saveStopped();
      try {
        await m.move(p, to, (progress) => this.#d.progress?.(p, progress), waits === undefined ? undefined : { stoppedFor: { module: waits.module, id: waits.id } });
      } catch (e) {
        out.failed = { item: p, error: (e as Error).message };
        await this.#unstop((s) => sameItem(s.waitsFor, p) && stops.some((x) => sameItem(x, s.item)), true);
        break;
      }
      // (what waits for it there goes on)
      await this.#d.tellArrived?.(to, { module: p.module, id: p.id }).catch((e) => log.warn("move", "the other station not told what came", { item: named(p), error: (e as Error).message }));
      thereNow.add(named(p));
      out.done.push({ module: p.module, id: p.id });
      for (const x of stops) out.stopped.push({ item: { module: x.module, id: x.id }, waitsFor: { module: p.module, id: p.id } });
      // (moved where its need is: no longer stopped here)
      await this.#unstop((s) => sameItem(s.item, p), false);
      this.#d.changed?.();
    }
    // (what follows what moved: the items of `follow` that need only what is there now)
    if (out.failed === null && sel.follow !== undefined && out.done.length > 0) {
      const after = await this.plan(ws, to);
      const there = new Set(after.items.filter((x) => x.state === "there").map(named));
      for (const p of order(after.items.filter((x) => sel.follow!.includes(x.module) && x.state !== "there" && x.cannot === undefined && x.needs.length > 0 && x.needs.every((n) => there.has(named(n))) && x.needs.some((n) => out.done.some((d) => sameItem(d, n)))), (n) => after.items.find((x) => sameItem(x, n)))) {
        try {
          await this.#modules.get(p.module)!.move(p, to, (progress) => this.#d.progress?.(p, progress));
          out.done.push({ module: p.module, id: p.id });
          await this.#unstop((s) => sameItem(s.item, p), false);
        } catch (e) {
          out.failed = { item: p, error: (e as Error).message };
          break;
        }
      }
    }
    this.#d.changed?.();
    return out;
  }

  async #back(ws: string, from: string, sel: Selection): Promise<Outcome> {
    const out: Outcome = { done: [], refused: [], stopped: [], resumed: [], failed: null };
    const plan = await this.plan(ws, from);
    const all = plan.items;
    const find = (n: Need) => all.find((x) => sameItem(x, n));
    const chosen = select(all, sel).filter((x) => x.state === "there" || x.state === "failed");
    if (chosen.length === 0) throw new Error(sel.item !== undefined ? `${sel.module ?? ""} ${sel.item} is not there to move back` : "nothing there to move back");
    const backing = new Set(chosen.map(named));
    // (with what needs it, where the whole is asked back)
    if (sel.all === true || sel.withNeeds === true) {
      for (let grew = true; grew; ) {
        grew = false;
        for (const x of all) if (x.state === "there" && !backing.has(named(x)) && x.needs.some((n) => backing.has(named(n)))) (backing.add(named(x)), (grew = true));
      }
    }
    const stillThere = new Set(all.filter((x) => x.state === "there").map(named));
    for (const p of order(all.filter((x) => backing.has(named(x))), find).reverse()) {
      if (out.failed !== null || this.#stopping !== null) break;
      const dependent = all.find((x) => stillThere.has(named(x)) && x.needs.some((n) => sameItem(n, p)));
      if (dependent !== undefined) {
        out.refused.push({ item: p, why: `${named(dependent)} (${dependent.label}) there needs it: move that back first, or ask for all` });
        continue;
      }
      // (what it needs that is still there and cannot be had here: it comes back stopped, waiting for it)
      const waits = p.needs.map(find).find((n): n is Planned => n !== undefined && stillThere.has(named(n)) && this.#modules.get(n.module)!.usableHere?.(n) !== true);
      try {
        await this.#modules.get(p.module)!.back(p, from, waits === undefined ? undefined : { stoppedFor: { module: waits.module, id: waits.id } });
      } catch (e) {
        out.failed = { item: p, error: (e as Error).message };
        break;
      }
      if (waits !== undefined) {
        await this.noteStopped({ module: p.module, id: p.id }, { module: waits.module, id: waits.id }, ws, false);
        out.stopped.push({ item: { module: p.module, id: p.id }, waitsFor: { module: waits.module, id: waits.id } });
      }
      stillThere.delete(named(p));
      out.done.push({ module: p.module, id: p.id });
      // (what waited here for it goes on)
      for (const s of this.#stopped.filter((s) => sameItem(s.waitsFor, p))) out.resumed.push(s.item);
      await this.#unstop((s) => sameItem(s.waitsFor, p), true);
      this.#d.changed?.();
    }
    return out;
  }

  /// An item that arrived here stopped, waiting for `waitsFor` (a hand-over with `stoppedFor`): kept stopped here,
  /// held by its module (`hold`; false: it held itself as it arrived).
  async noteStopped(item: Need, waitsFor: Need, ws: string, hold = true): Promise<void> {
    if (this.#stopped.some((s) => sameItem(s.item, item))) return;
    if (hold) await this.#modules.get(item.module)?.stop?.({ module: item.module, id: item.id, label: item.id, needs: [waitsFor] }, waitsFor);
    this.#stopped.push({ item, waitsFor, ws });
    await this.#saveStopped();
    this.#d.changed?.();
  }

  /// `item` is here now (another station moved it here): what waited here for it goes on.
  async arrived(item: Need): Promise<Need[]> {
    const going = this.#stopped.filter((s) => sameItem(s.waitsFor, item)).map((s) => s.item);
    await this.#unstop((s) => sameItem(s.waitsFor, item), true);
    this.#d.changed?.();
    return going;
  }

  /// The stopped items `which` names let go (`resume`: told to go on here; else they moved).
  async #unstop(which: (s: Stopped) => boolean, resume: boolean): Promise<void> {
    const gone = this.#stopped.filter(which);
    if (gone.length === 0) return;
    this.#stopped = this.#stopped.filter((s) => !which(s));
    await this.#saveStopped();
    if (!resume) return;
    for (const s of gone) {
      const m = this.#modules.get(s.item.module);
      await m?.resume?.({ module: s.item.module, id: s.item.id, label: s.item.id, needs: [s.waitsFor] }).catch((e) => log.warn("move", "an item not let go", { item: named(s.item), error: (e as Error).message }));
    }
  }

  async #saveStopped(): Promise<void> {
    const path = stoppedFile(this.#d.data);
    await mkdir(dirname(path), { recursive: true });
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#stopped));
    await rename(tmp, path);
  }
}

/// A chain of items that need each other round (null: none): modules may need each other, items may not.
function itemCycle(items: Item[]): Item[] | null {
  const by = new Map(items.map((x) => [named(x), x]));
  const state = new Map<string, 1 | 2>();
  const path: Item[] = [];
  const visit = (x: Item): Item[] | null => {
    const k = named(x);
    if (state.get(k) === 2) return null;
    if (state.get(k) === 1) return [...path.slice(path.findIndex((y) => named(y) === k)), x];
    state.set(k, 1);
    path.push(x);
    for (const n of x.needs) {
      const y = by.get(named(n));
      if (y === undefined) continue;
      const c = visit(y);
      if (c !== null) return c;
    }
    path.pop();
    state.set(k, 2);
    return null;
  };
  for (const x of items) {
    const c = visit(x);
    if (c !== null) return c;
  }
  return null;
}

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
  const emitStopper = (s: T) => {
    if (done.has(named(s))) return;
    emit(s);
    for (const d of ordered) if (d.needs.some((n) => sameItem(n, s))) emit(d);
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
  const visit = (x: T, path: Set<string>) => {
    const k = named(x);
    if (seen.has(k) || path.has(k)) return;
    path.add(k);
    for (const n of x.needs) {
      const y = find(n);
      if (y !== undefined && items.includes(y)) visit(y, path);
    }
    seen.add(k);
    out.push(x);
  };
  for (const x of items) visit(x, new Set());
  return out;
}
