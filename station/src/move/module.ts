// A migration between two stations of a workspace is a set of independent modules and a scheduler that only orders
// them (the owner, 2026-11-14: 「每个模块独立迁移，有依赖的模块显式给出依赖，要求先迁依赖项，模块内部带进度迁移，可回滚」;
// move/AGENTS.md). This is the one seam every module is: what it would move (its items, each naming what it needs), each
// moved and moved back on its own, where each stands.

/// An item a module's needs name, by its module and its id there (an id the workspace knows it by, the same on every
/// station: a chat's session key, a share's id, a connect as `<id>@<origin>`).
export type Need = { module: string; id: string };

/// What a module would move: its id, what people call it, what it needs moved first (only of the modules its module
/// declares), why it cannot move (in words that say what to do; none: it can), how big it is (bytes, where known).
export type Item = { module: string; id: string; label: string; needs: Need[]; cannot?: string; size?: number };

/// Where an item stands: here, moving, there, failed (why kept; it is here and works), or stopped: still here, but
/// what it needs moved away and cannot be had here (`waitsFor`), so it is held as one moving is, not left to fail
/// (the owner, 2026-11-14: 「依赖项被迁走就停掉啊」).
export type State = "here" | "moving" | "there" | "failed" | "stopped";
export type Progress = { done: number; total: number; unit: string };
export type ItemState = { state: State; error?: string; progress?: Progress; waitsFor?: Need };
/// How an item arrives: stopped, waiting for `stoppedFor` (the station it arrives at keeps it stopped).
export type Arrive = { stoppedFor?: Need };

export interface Module {
  readonly id: string;
  /// The modules its items may need (declared and checked: an item's `needs` names only these).
  readonly needs: readonly string[];
  /// What it would move of `ws` here to `to` (bounded: a page of each of what there are many of).
  plan(ws: string, to: string): Promise<Item[]>;
  /// The item moved to `to`, its progress told as it goes; safe to start again after a stop. `stoppedFor`: what it
  /// needs is not usable there yet: it arrives stopped, waiting for that (the scheduler says so, never the module).
  move(item: Item, to: string, progress: (p: Progress) => void, opts?: Arrive): Promise<void>;
  /// The item here again as it was, from `from`; safe to start again. `stoppedFor`: as `move`'s, here.
  back(item: Item, from: string, opts?: Arrive): Promise<void>;
  state(item: Item): ItemState;
  /// Whether the item, moved away, can still be had here (an account this station borrows from where it went).
  /// Absent: it cannot.
  usableHere?(item: Item): boolean;
  /// The item held here as its need moved away (`waitsFor`), and let go once it is back or the item moved; durable as
  /// the scheduler keeps it (scheduler.ts `stopped`). A module with nothing to hold has none.
  stop?(item: Item, waitsFor: Need): Promise<void>;
  resume?(item: Item): Promise<void>;
}

export const sameItem = (a: Need, b: Need) => a.module === b.module && a.id === b.id;
export const named = (n: Need) => `${n.module} ${n.id}`;
