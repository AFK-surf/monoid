// The scheduler of a migration (move/AGENTS.md): it only orders the modules' items (module.ts) and never does a
// module's work. An item moves once what it needs is there (it is refused naming what it waits for, or, asked
// `withNeeds`, those move first); it is moved back once nothing on the other station that needs it is still there
// (refused naming it). As an item moves away, each item still here that needs it and cannot have it here any more is
// stopped (a state of its own, kept here across starts: `stopped.json`), and goes on as what it waits for is back, or as
// it moves itself. What changes is told (`changed`), nothing is polled.
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { log } from "../ops/log.ts";
import { type Item, type ItemState, type Module, type Need, type Progress, named, sameItem } from "./module.ts";

/// An item as a plan shows it: what it is, where it stands, and what would be stopped here if it moved alone.
export type Planned = Item & ItemState & { wouldStop: Need[] };
export type Plan = { ws: string; to: string; modules: { id: string; needs: readonly string[] }[]; items: Planned[] };
/// Which items: one (`module` and `item`), a module's (`module`), or all (`all`); `withNeeds`: what they need first;
/// `follow`: the items of these modules that need only what moved go with it (a chat's jobs).
export type Selection = { module?: string; item?: string; all?: boolean; withNeeds?: boolean; follow?: string[] };
/// What came of a move or a move back: moved in order; refused (not tried: why); stopped as their need went; the
/// failure it stopped at.
export type Outcome = { done: Need[]; refused: { item: Need; why: string }[]; stopped: { item: Need; waitsFor: Need }[]; resumed: Need[]; failed: { item: Need; error: string } | null };
/// An item stopped here, kept: what it waits for, of which workspace.
type Stopped = { item: Need; waitsFor: Need; ws: string };

export type SchedulerDeps = {
  data: string;
  modules: Module[];
  changed?: () => void;
  /// Progress of the item moving now.
  progress?: (item: Need, p: Progress) => void;
};

const stoppedFile = (data: string) => join(data, "move", "stopped.json");

export class Scheduler {
  readonly #d: SchedulerDeps;
  readonly #modules = new Map<string, Module>();
  #stopped: Stopped[];
  /// One move or move back at a time.
  #turn: Promise<unknown> = Promise.resolve();

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
  }

  /// Begun: what was stopped is stopped again (a hold is the process's).
  async start(): Promise<void> {
    for (const s of this.#stopped) {
      const m = this.#modules.get(s.item.module);
      await m?.stop?.({ module: s.item.module, id: s.item.id, label: s.item.id, needs: [s.waitsFor] }, s.waitsFor).catch((e) => log.warn("move", "an item not stopped again", { item: named(s.item), error: (e as Error).message }));
    }
  }

  /// What waits for what here.
  stopped(): { item: Need; waitsFor: Need }[] {
    return this.#stopped.map((s) => ({ item: s.item, waitsFor: s.waitsFor }));
  }

  /// What a move of `ws` to `to` would be: every module's items, where each stands, what each would stop.
  async plan(ws: string, to: string): Promise<Plan> {
    const items: Item[] = [];
    for (const m of this.#modules.values()) {
      for (const item of await m.plan(ws, to)) {
        for (const n of item.needs) if (!m.needs.includes(n.module)) throw new Error(`module ${m.id}'s item ${item.id} needs ${named(n)}, of a module it does not declare`);
        items.push(item);
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

  /// Moves what `sel` names of `ws` to `to`, in the order their needs make.
  move(ws: string, to: string, sel: Selection): Promise<Outcome> {
    const run = this.#turn.then(() => this.#move(ws, to, sel));
    this.#turn = run.catch(() => {});
    return run;
  }

  /// Moves back what `sel` names of `ws` from `from`, in the reverse order.
  back(ws: string, from: string, sel: Selection): Promise<Outcome> {
    const run = this.#turn.then(() => this.#back(ws, from, sel));
    this.#turn = run.catch(() => {});
    return run;
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
    const take = (p: Planned) => {
      const k = named(p);
      if (wanted.has(k)) return;
      if (sel.withNeeds === true || sel.all === true) for (const n of p.needs) { const x = find(n); if (x !== undefined && x.state !== "there") take(x); }
      wanted.set(k, p);
    };
    for (const p of chosen) take(p);
    const thereNow = new Set(all.filter((x) => x.state === "there").map(named));
    for (const p of order([...wanted.values()], find)) {
      if (out.failed !== null) break;
      if (thereNow.has(named(p))) continue;
      if (p.cannot !== undefined) {
        out.refused.push({ item: p, why: p.cannot });
        continue;
      }
      const waits = p.needs.find((n) => !thereNow.has(named(n)) && find(n) !== undefined);
      if (waits !== undefined) {
        out.refused.push({ item: p, why: `it needs ${named(waits)} (${find(waits)!.label}) there first: move that first, or ask with withNeeds` });
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
        await m.move(p, to, (progress) => this.#d.progress?.(p, progress));
      } catch (e) {
        out.failed = { item: p, error: (e as Error).message };
        await this.#unstop((s) => sameItem(s.waitsFor, p) && stops.some((x) => sameItem(x, s.item)), true);
        break;
      }
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
      if (out.failed !== null) break;
      const dependent = all.find((x) => stillThere.has(named(x)) && x.needs.some((n) => sameItem(n, p)));
      if (dependent !== undefined) {
        out.refused.push({ item: p, why: `${named(dependent)} (${dependent.label}) there needs it: move that back first, or ask for all` });
        continue;
      }
      try {
        await this.#modules.get(p.module)!.back(p, from);
      } catch (e) {
        out.failed = { item: p, error: (e as Error).message };
        break;
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

function select(all: Planned[], sel: Selection): Planned[] {
  if (sel.all === true) return all.filter((x) => sel.module === undefined || x.module === sel.module);
  if (sel.module === undefined) return [];
  return all.filter((x) => x.module === sel.module && (sel.item === undefined || x.id === sel.item));
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
