// A migration between two stations of a workspace is a set of independent modules and a scheduler that only orders
// them (the owner, 2026-11-14: 「每个模块独立迁移，有依赖的模块显式给出依赖，要求先迁依赖项，模块内部带进度迁移，可回滚」;
// move/AGENTS.md). This is the one seam every module is: what it would move (its items, each naming what it needs), each
// moved and moved back on its own, where each stands.

import { log } from "../ops/log.ts";
import { Said, stationLang, tr } from "../ops/i18n.ts";
import { Refused } from "../mesh/bus.ts";

/// An item a module's needs name, by its module and its id there (an id the workspace knows it by, the same on every
/// station: a chat's session key, a share's id, a connect as `<id>@<origin>`).
export type Need = { module: string; id: string };
/// What a stopped item waits for: the need, what people call it and the station it is on (none: not known, a record
/// from before).
export type Waits = Need & { label?: string; at?: string };

/// What a module would move: its id, what people call it, what it needs moved first (only of the modules its module
/// declares), why it cannot move (in words that say what to do; none: it can), how big it is (bytes, where known).
/// `again`: its `cannot` is of this turn only (the other station did not answer what it has): asked again it may go,
/// and nothing goes ahead of it to wait for it.
export type Item = { module: string; id: string; label: string; needs: Need[]; cannot?: string; again?: true; size?: number };
/// Why an item cannot go where the other station did not answer what it has of it, as a plan asked (a station enrolled a
/// moment ago, not reached): a plan is never made on a guess of what is there, so it is not tried; asked again it is.
/// What a move says to people, in the station's language, already: passed on as it is, never worded again.
// (one class with ops/i18n.ts's, which the rest of the station says its words by)
export { Said };
/// A request with bytes that met the other station's connection gone, the first time in a turn (move/station.ts
/// `#ask`): nothing of it was taken, and its body is read, so its caller sends it once more from its start, on the
/// connection dialed anew (replica/sending.ts `sendBatch`). Its words, where a caller does not, say so.
export class AskAgain extends Said {}
/// The other station found gone in a turn (`#ask`): this step, and every later one toward it, fails with these words.
export class Gone extends Said {}

/// What an item's failure says to people (move/AGENTS.md: every word a move says is the catalog's): the station's own
/// words (`Said`) and the other station's answer (a refusal, said there in its words) as they are; anything else (an
/// error as it came: a file's, a request's, a process's) logged whole and said in the catalog's: the other station not
/// answering, or that it could not be done, with what to do.
export function sayOf(e: unknown, what: string): string {
  const message = (e as Error)?.message ?? String(e);
  if (e instanceof Said || e instanceof Refused) return message;
  log.warn("move", "an item failed: the error, said to people in the station's words", { item: what, error: message });
  return tr(stationLang(), UNANSWERED.test(message) ? "station.move.why.unanswered" : "station.move.why.failedHere");
}
/// What the transport says of a station that did not answer (mesh/peer.ts: no answer, its connection gone, no answer in
/// time; a test's transport: unreachable).
export const UNANSWERED = /answered nothing|got no answer|timed out|station unreachable|connection (was )?(gone|lost|closed|reset)|stream (was )?(reset|closed|stopped)/i;

/// A plan's question of the other station not answered (`method`, of `to`): said once in the log as it fails, the error
/// as it came, so what a start or a dead station did is read there (a plan says only that it was not answered).
export const notAnswered = (method: string, to: string, e: unknown): unknown => {
  log.warn("move", "a plan's question of the other station was not answered", { method, station: to.slice(0, 12), error: (e as Error)?.message ?? String(e) });
  return e ?? new Error("no answer");
};
/// (what it failed with is in the log, said as the plan asked, `notAnswered`: not in a sentence for people)
export const unanswered = (_e: unknown) => tr(stationLang(), "station.move.sched.unanswered");

/// Where an item stands: here, moving, there, failed (why kept; it is here and works), or stopped: still here, but
/// what it needs moved away and cannot be had here (`waitsFor`), so it is held as one moving is, not left to fail
/// (the owner, 2026-11-14: 「依赖项被迁走就停掉啊」).
export type State = "here" | "moving" | "there" | "failed" | "stopped";
export type Progress = { done: number; total: number; unit: string };
/// `at`: the station it is on, where its module knows (a chat handed to another, `handed_over`); `waitsFor`, of one
/// stopped: what it waits for, with the station that is on where known.
/// `waits`, of one moving: what its move waits for now, not stuck though its progress stands ("turn": the chat's turn
/// under way to end, before it is held; "station": the station it comes from, `from`, to go on with it: shown here, or
/// dropped and it stays there, once that station is heard from).
/// `lentTo`, of one here: the station it is usable on too, lent for what moved there (a login shared with it, this
/// station its host).
export type ItemState = { state: State; error?: string; progress?: Progress; waitsFor?: Waits; at?: string; waits?: "turn" | "station"; from?: string; lentTo?: string };
/// How an item arrives: stopped, waiting for `stoppedFor` (the station it arrives at keeps it stopped).
export type Arrive = { stoppedFor?: Waits };

/// What one plan reads once for all the modules that need it (move/station.ts makes it for each plan): the
/// workspace's chats here a page at a time, each page read once whichever module asks first, and the canonical clones
/// the linked worktrees in a directory hang on, as the repository cache's clones say them.
export type PlanReads = {
  /// The workspace's chats here, a page at a time (store.ts `SessionPage`), the main thread given back between pages.
  pages(): AsyncIterable<import("../store/store.ts").SessionPage>;
  /// Every page read (`pages` gone through), so that what plans without waiting finds them (`loaded`): the scheduler's,
  /// before the modules plan.
  load(): Promise<void>;
  /// The pages read so far.
  loaded(): readonly import("../store/store.ts").SessionPage[];
  /// The canonical clones the linked worktrees in `dir`, or right under it, hang on, as the clones say them (repos.ts
  /// `worktreesOfClones`, read once a plan): nothing of a chat's room is read.
  worktrees(dir: string): Promise<{ repo: string; url: string }[]>;
};

export interface Module {
  readonly id: string;
  /// The modules its items may need (declared and checked: an item's `needs` names only these).
  readonly needs: readonly string[];
  /// What it would move of `ws` here to `to` (bounded: a page of each of what there are many of).
  /// `reads`: what this plan reads once for its modules.
  plan(ws: string, to: string, reads?: PlanReads): Promise<Item[]>;
  /// The item moved to `to`, its progress told as it goes; safe to start again after a stop. `stoppedFor`: what it
  /// needs is not usable there yet: it arrives stopped, waiting for that (the scheduler says so, never the module).
  move(item: Item, to: string, progress: (p: Progress) => void, opts?: Arrive): Promise<void>;
  /// The item here again as it was, from `from`; safe to start again. `stoppedFor`: as `move`'s, here.
  back(item: Item, from: string, opts?: Arrive): Promise<void>;
  state(item: Item): ItemState;
  /// Whether the item, moved away, can still be had here (an account this station borrows from where it went).
  /// Absent: it cannot.
  usableHere?(item: Item): boolean;
  /// What needs it can go there though it is not there: e.g. an account the other station borrows. Absent: it cannot.
  usableThere?(item: Item): boolean;
  /// Whether the item, needed there, can be made usable there without moving it (a login lent: shared with the other,
  /// this station staying its host). Absent: it cannot.
  canLend?(item: Item): boolean;
  /// The item made usable at `to` for `forWhom` (the items of the turn that need it there), not moved; answered once it
  /// is (refused in words where it cannot be): `usableThere` says so from then.
  lend?(item: Item, to: string, forWhom: Need[]): Promise<void>;
  /// Item `item`, lent to `to` before, needed there by `forWhom` too (going there now in a later turn): kept as lent
  /// for them as well. None: lent for what it was lent for alone.
  lentFor?(item: Item, to: string, forWhom: Need[]): Promise<void>;
  /// Items `items` are here, or never went (came back, failed, a chat that arrived here): what was lent for them alone is
  /// taken back, once the other says nothing there runs on it. Asked with none at a turn's end: what was kept lent only
  /// for what the other runs on it is looked at again.
  left?(items: Need[]): Promise<void>;
  /// Whether the item is on this station now, from what the module keeps (none: its state says `here` or `failed`):
  /// what lets go, as the station starts, what was stopped waiting for it (scheduler `settleStopped`).
  isHere?(item: Item): boolean;
  /// The turn was asked to stop (scheduler `stopTurn`): the item under way gives up where it is not yet past its point
  /// of no return (undone as a failure there is), else completes. None: what is under way completes.
  abandon?(): void;
  /// Why the item cannot go to `to` now by what moves nothing (it is in a turn and is not to be waited for, it is not
  /// to go there as it is): asked before any of its needs moves for it (null: it may go). None: nothing to ask.
  ready?(item: Item, to: string): Promise<string | null>;
  /// The item held here as its need moved away (`waitsFor`), and let go once it is back or the item moved; durable as
  /// the scheduler keeps it (scheduler.ts `stopped`). A module with nothing to hold has none.
  stop?(item: Item, waitsFor: Waits): Promise<void>;
  resume?(item: Item): Promise<void>;
}

export const sameItem = (a: Need, b: Need) => a.module === b.module && a.id === b.id;
export const named = (n: Need) => `${n.module} ${n.id}`;
