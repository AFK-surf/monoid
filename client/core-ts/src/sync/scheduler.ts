// The sync scheduler (rule 6): every request the core makes of still.fail cloud and the stations is a
// task here, run by the lane it belongs to (still.fail cloud's, or a station's) a few at a time, the most urgent first.
// What exists to be synced is the sync's to say, whatever the UI shows; the UI only makes some of it more urgent
// (`prioritize`: a chat opened, a page shown). A task asked for again while it waits or runs is the same task: its
// priority is raised, and whoever asked waits on its one run.
import { Deferred, Effect, type Fiber } from "effect";
import type { CoreError } from "../error.ts";
import type { Runner, Scoped } from "../runtime.ts";

/// How urgent a task is: higher goes first.
export const Priority = {
  /// What was opened and let go, brought whole all the same (fill.ts): after everything else.
  idle: -10,
  /// Kept current in the background.
  background: 0,
  /// What a UI shows only once opened (an execution history's step whole, `history.detail`): never pushed, and after
  /// what a UI shows in brief.
  detail: 5,
  /// Behind something a UI shows.
  shown: 10,
  /// The chat a UI has open.
  focused: 20,
  /// A person waits on it (a call answers once it is done).
  asked: 30,
} as const;

type Waiting = {
  key: string;
  /// What it was asked at (the most of every time it was), before what a UI makes urgent (`prioritize`) raises it.
  basePriority: number;
  seq: number;
  work: Effect.Effect<void, CoreError>;
  done: Deferred.Deferred<void, CoreError>;
  fiber?: Fiber.Fiber<void, never>;
};

/// Past a lane's width, how many more may run of what a UI has open or a person waits on (Priority.focused and up): on
/// a slow link a read can take a minute (every thread, the sidebar), and two of them would hold up the chat opened.
export const URGENT_ROOM = 2;

/// One lane: its tasks, run by how urgent each is now (`#pump`): what a UI has open or a person waits on in `width` and
/// URGENT_ROOM more, what a UI shows in `width`, what is kept current in the background one at a time and only while
/// nothing more urgent is asked or under way, what is idle alone once nothing else is.
class Lane {
  readonly waiting: Waiting[] = [];
  readonly running = new Map<string, Waiting>();
  readonly width: number;
  /// Requests made in a person's sight that are no task of the lane (`foregroundBegin`): under way now.
  foreground = 0;
  /// Told once something more urgent than the background is asked or under way (`preempted`).
  preempt: Deferred.Deferred<void> | null = null;
  constructor(width: number) {
    this.width = width;
  }
}

export class Scheduler {
  readonly #runner: Runner;
  readonly #scoped: Scoped;
  readonly #lanes = new Map<string, Lane>();
  #seq = 0;
  /// The priority things matching any of the key prefixes get while a UI makes them urgent (`prioritize`), by who asked.
  readonly #boosts = new Map<string, [readonly string[], number]>();
  /// Told when a lane has nothing left to run, a task of it just over.
  onIdle: (lane: string) => void = () => {};

  constructor(runner: Runner, scoped: Scoped) {
    this.#runner = runner;
    this.#scoped = scoped;
  }

  #lane(name: string): Lane {
    let lane = this.#lanes.get(name);
    if (!lane) {
      lane = new Lane(name === "cloud" ? 4 : 2);
      this.#lanes.set(name, lane);
    }
    return lane;
  }

  #boosted(key: string, priority: number): number {
    let p = priority;
    for (const [prefixes, boost] of this.#boosts.values()) {
      if (boost <= p) continue;
      for (const prefix of prefixes) {
        if (key.startsWith(prefix)) {
          p = boost;
          break;
        }
      }
    }
    return p;
  }

  /// How urgent a task is now: what it was asked at, raised by what a UI makes urgent.
  #effective(w: Waiting): number {
    return this.#boosted(w.key, w.basePriority);
  }

  /// Whether anything of a lane more urgent than `than` waits or runs.
  #above(lane: Lane, than: number): boolean {
    for (const w of lane.running.values()) if (this.#effective(w) > than) return true;
    for (const w of lane.waiting) if (this.#effective(w) > than) return true;
    return false;
  }

  /// Whether a lane has a request in a person's sight under way, or a task more urgent than the background.
  #urgent(lane: Lane): boolean {
    return lane.foreground > 0 || this.#above(lane, Priority.background);
  }

  /// What is idle in a lane (`preempted`) gives way: something more urgent is asked or under way.
  #preemptIdle(lane: Lane): void {
    const preempt = lane.preempt;
    if (preempt === null) return;
    lane.preempt = null;
    Deferred.doneUnsafe(preempt, Effect.void);
  }

  /// Asks for a task: in `lane`, by `key` (one task per key), at `priority`. Returns its completion: what its run
  /// ends with (a task asked for while it runs is run again after, for what changed meanwhile).
  ask(lane: string, key: string, priority: number, work: Effect.Effect<void, CoreError>): Effect.Effect<void, CoreError> {
    return Deferred.await(this.enqueue(lane, key, priority, work));
  }

  /// As `ask`, without waiting: the completion to wait on, if one wants to.
  enqueue(lane: string, key: string, priority: number, work: Effect.Effect<void, CoreError>): Deferred.Deferred<void, CoreError> {
    const l = this.#lane(lane);
    const waiting = l.waiting.find((w) => w.key === key);
    if (waiting) {
      // (raised to the urgent, it may go on now in the room kept for them)
      if (priority > waiting.basePriority) {
        waiting.basePriority = priority;
        this.#pump(l, lane);
      }
      return waiting.done;
    }
    const task: Waiting = { key, basePriority: priority, seq: ++this.#seq, work, done: Deferred.makeUnsafe<void, CoreError>() };
    l.waiting.push(task);
    this.#pump(l, lane);
    return task.done;
  }

  /// Whether the task of `key` waits or runs in `lane`.
  queued(lane: string, key: string): boolean {
    const l = this.#lanes.get(lane);
    return l !== undefined && (l.running.has(key) || l.waiting.some((w) => w.key === key));
  }

  /// Whether a lane has anything to run, or running.
  busy(lane: string): boolean {
    const l = this.#lanes.get(lane);
    return l !== undefined && (l.running.size > 0 || l.waiting.length > 0);
  }

  /// A request in a person's sight (not quiet) that is no task of the lane begins: until the returned function is
  /// called (once; again does nothing), the background of `lane` waits and what is idle there gives way.
  foregroundBegin(lane: string): () => void {
    const l = this.#lane(lane);
    l.foreground++;
    this.#preemptIdle(l);
    let ended = false;
    return () => {
      if (ended) return;
      ended = true;
      l.foreground--;
      this.#pump(l, lane);
      if (l.foreground === 0 && l.running.size === 0 && l.waiting.length === 0) this.onIdle(lane);
    };
  }

  /// Done at once while `lane` has a request in a person's sight under way or a task more urgent than the background,
  /// else once it has: what is idle (fill.ts) races it to give way.
  preempted(lane: string): Effect.Effect<void> {
    return Effect.suspend(() => {
      const l = this.#lane(lane);
      if (this.#urgent(l)) return Effect.void;
      return Deferred.await((l.preempt ??= Deferred.makeUnsafe<void>()));
    });
  }

  #pump(lane: Lane, name: string): void {
    // (something urgent asked or under way: what is idle gives way to it)
    if (this.#urgent(lane)) this.#preemptIdle(lane);
    for (;;) {
      // The most urgent, then the oldest; one already running for its key waits for that run.
      let best = -1;
      let bestP = 0;
      for (let i = 0; i < lane.waiting.length; i++) {
        const w = lane.waiting[i];
        if (lane.running.has(w.key)) continue;
        const p = this.#effective(w);
        if (best < 0 || p > bestP || (p === bestP && w.seq < lane.waiting[best].seq)) {
          best = i;
          bestP = p;
        }
      }
      if (best < 0) return;
      const busy = lane.running.size;
      if (bestP >= Priority.focused) {
        // What a UI has open or a person waits on: the lane's width and the room kept for them.
        if (busy >= lane.width + URGENT_ROOM) return;
      } else if (bestP > Priority.background) {
        // What a UI shows: the lane's width.
        if (busy >= lane.width) return;
      } else if (bestP > Priority.idle) {
        // The background: one at a time, and only while nothing more urgent is asked or under way, so that what is
        // asked next never waits behind more than the one already gone.
        if (busy >= lane.width || lane.foreground > 0 || this.#above(lane, Priority.background)) return;
        for (const w of lane.running.values()) if (this.#effective(w) <= Priority.background) return;
      } else {
        // What is idle: alone, once nothing else is.
        if (busy > 0 || lane.foreground > 0 || this.#above(lane, Priority.idle)) return;
      }
      const [task] = lane.waiting.splice(best, 1);
      lane.running.set(task.key, task);
      task.fiber = this.#runner.fork(
        task.work.pipe(
          Effect.exit,
          Effect.flatMap((exit) =>
            Effect.sync(() => {
              if (lane.running.get(task.key) === task) lane.running.delete(task.key);
              Deferred.doneUnsafe(task.done, exit);
              this.#pump(lane, name);
              if (lane.running.size === 0 && lane.waiting.length === 0) this.onIdle(name);
            }),
          ),
          Effect.onInterrupt(() =>
            Effect.sync(() => {
              if (lane.running.get(task.key) === task) lane.running.delete(task.key);
              Deferred.doneUnsafe(task.done, Effect.interrupt);
              this.#pump(lane, name);
              if (lane.running.size === 0 && lane.waiting.length === 0) this.onIdle(name);
            }),
          ),
        ),
        this.#scoped,
      );
    }
  }

  /// Makes what matches `prefix` (or any of several) at least `priority` while `who` says so (a UI's focus); `null`
  /// (or none) lets it go, and what it raised that has not begun goes back to what it was asked at.
  prioritize(who: string, prefix: string | readonly string[] | null, priority: number = Priority.focused): void {
    const prefixes = prefix === null ? null : typeof prefix === "string" ? [prefix] : prefix.length === 0 ? null : [...prefix];
    if (prefixes === null) this.#boosts.delete(who);
    else this.#boosts.set(who, [prefixes, priority]);
    // (raised to the urgent, it may go on now in the room kept for them; let go, it waits its turn again)
    for (const [name, lane] of this.#lanes) this.#pump(lane, name);
  }

  /// Cancels the queued or running task of `key` in `lane`, freeing its slot at once.
  cancel(lane: string, key: string): void {
    const l = this.#lanes.get(lane);
    if (!l) return;
    let changed = false;
    for (let i = l.waiting.length - 1; i >= 0; i--) {
      if (l.waiting[i]!.key !== key) continue;
      const [task] = l.waiting.splice(i, 1);
      Deferred.doneUnsafe(task!.done, Effect.interrupt);
      changed = true;
    }
    const running = l.running.get(key);
    if (running) {
      l.running.delete(key);
      Deferred.doneUnsafe(running.done, Effect.interrupt);
      if (running.fiber) this.#runner.interrupt(running.fiber);
      changed = true;
    }
    if (!changed) return;
    this.#pump(l, lane);
    if (l.foreground === 0 && l.running.size === 0 && l.waiting.length === 0) this.onIdle(lane);
  }

  /// Drops what waits in a lane (a station no longer reached, a signed-out account): those waiting on it are told.
  drop(lane: string, why: CoreError): void {
    const l = this.#lanes.get(lane);
    if (!l) return;
    for (const w of l.waiting.splice(0)) Deferred.doneUnsafe(w.done, Effect.fail(why));
  }

  /// What waits and runs, for tests: `lane key@priority`, as urgent as each is now.
  pending(): string[] {
    const out: string[] = [];
    for (const [name, lane] of this.#lanes) {
      for (const w of lane.running.values()) out.push(`${name} ${w.key}@${this.#effective(w)} running`);
      for (const w of lane.waiting) out.push(`${name} ${w.key}@${this.#effective(w)}`);
    }
    return out;
  }
}
