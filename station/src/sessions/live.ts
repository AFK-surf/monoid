// Live view of sessions: what a running turn is doing, told at its turning points (the phase, each step starting and
// ending), how fast the model writes, what a session has going in the background and its checklist, and the
// transcript's entries as each is written whole. It runs in the sessions' MoonBit program (station/mb, reader
// `--sessions`, mb/src/reader/live.mbt), as the pseudo-actor `#live` of the hub's program, where a Claude session's
// events are read; this is Node's shell of it (`LiveHub`): it says the program what the station tells it (another
// runtime's events, a session at work, a listener, a deleted session) and answers what the program asks of it: where a
// session's transcripts are, a read of what one gained, a page of its past and where the readers' reading of it stands
// (the readers', read/pool.ts: off the station's thread and off the program's, so a long transcript holds up neither),
// a file watched as it is written (fs.watch: push, not poll), and what is told to each listener, its usage and its
// entries in brief added here where it has them so.
import type { Clock } from "effect";
import { type FSWatcher, mkdtempSync, watch } from "node:fs";
import { access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { BackgroundTask, LiveEvent, PlanItem } from "../agents/runtime.ts";
import { liveClock } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { ChainTail, TranscriptTail, type TailState, type TranscriptRef } from "../read/tail.ts";
import { type TimelineEntry, brief } from "../read/transcript.ts";
import { type SessionUsage, noUsage } from "../read/usage.ts";
import type { RuntimeKind } from "../agents/runtime.ts";
import { ActorsProgram } from "./mb-actor.ts";

export { ChainTail, TranscriptTail } from "../read/tail.ts";

type Json = any;
type Phase = Extract<LiveEvent, { kind: "phase" }>["phase"];

/// A step in flight: what it is, not what it has written so far.
export type LiveStep = { id: string; step: "text" | "thinking" | "tool"; tool?: string; subagent?: boolean; parent?: string; input: string; startedAt: number };

export type LiveMessage =
  | { type: "steps"; steps: LiveStep[]; phase: { phase: Phase; elapsedMs: number } | null }
  | { type: "step"; event: LiveEvent }
  | { type: "timeline"; start: number; entries: TimelineEntry[]; usage: SessionUsage }
  /// How fast the model is writing now (≈ tokens a second, from bytes), at most once a second; 0 once it stops.
  | { type: "rate"; tokensPerSecond: number }
  /// What it has going on past its turns and its checklist, whole each time (told as a stream opens and as either
  /// changes; a client from before reads no such message): each task with how long it has run.
  | { type: "work"; tasks: (BackgroundTask & { elapsedMs: number })[]; plan: PlanItem[] }
  | { type: "clear" };

export type Listener = (message: LiveMessage) => void;

/// How long a session is still followed once its turn is over (`running`; live.mbt `held_after_ms`).
export const HELD_AFTER_MS = 2 * 60_000;

/// Where a session's history is read off the main thread (the readers: sessions/agents.ts): where the reading of its
/// transcripts stands there (read/tail.ts `snapshot`; null: none found), to go on from; and up to `limit` entries just
/// before `before`, in brief or whole, with the index of the first and how many there are (`end`).
export type History = {
  state(key: string): Promise<TailState[] | null>;
  page(key: string, before: number, limit: number, brief: boolean): Promise<{ start: number; entries: TimelineEntry[]; end: number }>;
};

/// Where a session's transcripts are: of the runtime sessions it ran in, the first first, ending with its current one
/// (`current`: whether that one's is among them; when not given, it is).
export type Locate = (key: string) => { runtime: RuntimeKind; paths: TranscriptRef[]; current?: boolean } | null;
export type AsyncLocate = (key: string, signal: AbortSignal) => Promise<ReturnType<Locate>>;

/// A read of one transcript on from where its reading stood (none: from its start), as tail.ts `TranscriptTail.read`
/// gives it, with where it stands after (the readers' `tailRead`).
export type TailRead = (runtime: RuntimeKind, state: TailState | { path: string; runtime: RuntimeKind }) => Promise<{ start: number; entries: TimelineEntry[]; state: TailState }>;

/// A session's checklist as carried over to the next station process (live.mbt `carried_plans`).
export type CarriedPlan = { key: string; at: number; items: (PlanItem & { id?: string })[]; creating: [string, number][] };

/// What the program knows the live view's shell by.
const LIVE_KEY = "#live";

export class LiveHub {
  readonly #locate: Locate;
  readonly #clock: Clock.Clock;
  readonly #given: (() => ActorsProgram | null) | null;
  /// The program of its own, where no hub gives one (a test's).
  #own: ActorsProgram | null = null;
  /// The program the shell is said to (once per program).
  #shelled: ActorsProgram | null = null;
  readonly #subs = new Map<number, { key: string; listener: Listener; brief: boolean }>();
  #nextSub = 0;
  /// The sessions the station follows now, as the program last said (`held`).
  #held: string[] = [];
  /// The sessions whose transcript is watched there, and the usage last told of each.
  readonly #watching = new Set<string>();
  readonly #told = new Map<string, string>();
  /// The file watched of each session (`arm`), its transcript written to now.
  readonly #watchers = new Map<string, { path: string; watcher: FSWatcher | null }>();
  /// The lookups of where a session's transcripts are, given up as it is no longer watched.
  readonly #locating = new Map<string, Set<AbortController>>();
  readonly #following = new Map<string, Set<AbortController>>();
  /// The sessions whose reading began from what the process before carried over while the readers were to be asked.
  readonly #begun = new Set<string>();
  #closed = false;

  /// Where a newly watched session's sources are located off the main thread, when available.
  locateAsync: AsyncLocate | null = null;
  /// What the usage counter recorded of a session's calls (usage/module.ts `usageNow`), and asking it to count what a
  /// session at work wrote since.
  #count: { of: (key: string) => SessionUsage | null; ask: (key: string) => void } | null = null;
  /// Where what the sessions at work say goes (api/events.ts: every stream whose viewer sees them).
  heldTold: ((key: string, message: LiveMessage) => void) | null = null;
  /// Where each watched transcript's length goes as it changes (the store: its session's summary says it).
  lengths: ((key: string, n: number) => void) | null = null;
  /// Where a transcript's past is read (agents.ts: the readers); none (tests): here.
  history: History | null = null;
  /// Where what a watched transcript gains is read (agents.ts: the readers); none: here.
  tailRead: TailRead | null = null;
  /// Until the station process before has handed over: where a reading stands is what it carries over (`takeTails`),
  /// not asked of the readers before then.
  handover: Promise<void> | null = null;

  /// `program`: the hub's, which its actors run in; none: one of its own.
  constructor(locate: Locate, clock?: Clock.Clock, program?: () => ActorsProgram | null) {
    this.#locate = locate;
    this.#clock = clock ?? liveClock;
    this.#given = program ?? null;
  }

  countWith(count: { of: (key: string) => SessionUsage | null; ask: (key: string) => void }) {
    this.#count = count;
  }

  #program(): ActorsProgram | null {
    if (this.#closed) return null;
    let p = this.#given !== null ? this.#given() : this.#own;
    if (p === null && this.#given === null) {
      // (a program of its own, made once: a test's live view, no hub's)
      p = this.#own = ActorsProgram.open(mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "live-")), this.#clock); // sync: once, a test's own
    }
    if (p !== null && this.#shelled !== p) {
      this.#shelled = p;
      p.shell({ key: LIVE_KEY, runtime: "claude", asked: (f, args) => this.#answer(f, args), told: (f, args) => this.#tellOf(f, args), clock: this.#clock, uncounted: true });
    }
    return p;
  }

  /// What was said to the program and is not answered yet: each is answered once all it set going there has been told
  /// (what it says meanwhile says nothing of where the program stands: `idle` waits for these).
  #inflight = 0;

  #call(method: string, args: Json[]): Promise<Json> {
    const p = this.#program();
    if (p === null) return Promise.resolve(null);
    this.#inflight++;
    return p.call(LIVE_KEY, method, args).finally(() => this.#inflight--);
  }

  /// Its usage as the counter has it, kept as told.
  #usageOf(key: string): SessionUsage {
    let usage: SessionUsage | null = null;
    try {
      usage = this.#count?.of(key) ?? null;
    } catch {}
    usage ??= noUsage();
    this.#told.set(key, JSON.stringify(usage));
    return usage;
  }

  /// The counter counted: each watched session whose usage changed is told it, where its transcript ends.
  usageCounted() {
    for (const key of this.#watching) {
      const before = this.#told.get(key);
      if (JSON.stringify(this.#usageOf(key)) !== before) void this.#call("usage", [key]);
    }
  }

  /// A runtime's live event for a session (a Claude session's are read in the program itself).
  event(key: string, event: LiveEvent) {
    void this.#call("event", [key, event]);
  }

  /// The turn is over: what it wrote last is read and told before `clear`, resolved once it is.
  async turnEnded(key: string): Promise<void> {
    await this.#call("turnEnded", [key]);
  }

  /// Whether a session is at work (its `running` as the store has it): from when it starts until HELD_AFTER_MS after it
  /// stops, the station follows it itself and tells what it does (`heldTold`).
  running(key: string, on: boolean) {
    void this.#call("running", [key, on]);
  }

  /// The sessions the station follows now (`running`).
  held(): string[] {
    return [...this.#held];
  }

  /// Followed sessions as they are now, for a stream that opens: where each one's transcript ends (no entry of it) with
  /// its usage, and the steps in flight.
  async nowOf(keys: string[]): Promise<Record<string, LiveMessage[]>> {
    const now = ((await this.#call("now", [keys])) ?? {}) as Record<string, Json[]>;
    for (const [key, messages] of Object.entries(now)) for (const m of messages) if (m.type === "timeline") m.usage = this.#usageOf(key);
    return now as Record<string, LiveMessage[]>;
  }

  /// Follows a session: first the transcript entries from index `from` on (only the `last` of them, when given), in
  /// brief for a listener that has them so, and the usage so far, the steps in flight, then everything new. Gives the
  /// id to unsubscribe with.
  subscribe(key: string, from: number, last: number | null, listener: Listener, brief = false): number {
    const id = ++this.#nextSub;
    this.#subs.set(id, { key, listener, brief });
    void this.#call("subscribe", [key, from, last, id, brief]);
    return id;
  }

  unsubscribe(key: string, id: number) {
    if (!this.#subs.delete(id)) return;
    void this.#call("unsubscribe", [key, id]);
  }

  /// Its transcript changed (its file's watch, `#arm`): what it gained is read once the burst is over.
  soon(key: string) {
    void this.#call("soon", [key]);
  }

  /// The session went on in a new runtime session: a watched history reads on in its transcript.
  moved(key: string) {
    void this.#call("moved", [key]);
  }

  /// A deleted session: nothing of it is watched or kept any more.
  forget(key: string) {
    for (const [id, sub] of this.#subs) if (sub.key === key) this.#subs.delete(id);
    this.#told.delete(key);
    this.#located.delete(key);
    void this.#call("forget", [key]);
  }

  /// Up to `limit` transcript entries just before index `before`, and the index of the first. Null when the session
  /// has no transcript.
  async before(key: string, before: number, limit: number): Promise<[number, TimelineEntry[]] | null> {
    const page = await this.page(key, before, limit);
    return page === null ? null : [page.start, page.entries];
  }

  /// As `before`, with how many entries there are (`end`): read where the history is read (`history`), else here. Null
  /// when the session has no transcript (here; the readers say none as no entries).
  async page(key: string, before: number, limit: number): Promise<{ start: number; entries: TimelineEntry[]; end: number } | null> {
    if (this.history !== null) return this.history.page(key, before, limit, false);
    return this.#pageHere(key, before, limit, false);
  }

  /// What the program carries over to the next station process (parts.ts `carry`): where each checklist was read to,
  /// and where each transcript's reading stood.
  async carried(): Promise<{ plans: CarriedPlan[]; tails: { key: string; states: TailState[] }[] }> {
    const c = await this.#call("carried", []);
    return { plans: c?.plans ?? [], tails: c?.tails ?? [] };
  }

  takePlans(carried: CarriedPlan[]): void {
    void this.#call("takePlans", [carried]);
  }

  takeTails(carried: { key: string; states: TailState[] }[]): void {
    void this.#call("takeTails", [carried]);
  }

  /// Once all it was told is done there and what it asked is answered (a test's, before it looks at what was told).
  async idle(): Promise<void> {
    for (;;) {
      const p = this.#program();
      if (p === null || (!p.busy() && this.#asking === 0 && this.#inflight === 0 && !this.#pending)) return;
      await new Promise<void>((resolve) => setImmediate(resolve));
    }
  }

  close() {
    this.#closed = true;
    for (const w of this.#watchers.values()) w.watcher?.close();
    this.#watchers.clear();
    const own = this.#own;
    this.#own = null;
    if (own !== null) void own.close();
  }

  // ── what the program asks ──────────────────────────────────────────────────────────────────────────────────────

  /// What the program asked and is not answered yet, and whether the live view there has something going: `idle` waits
  /// for both (the program's own `busy` does not count what waits on Node).
  #asking = 0;
  #pending = false;

  async #answer(f: string, args: Json[]): Promise<Json> {
    this.#asking++;
    try {
      return await this.#asked(f, args);
    } finally {
      this.#asking--;
    }
  }

  async #asked(f: string, args: Json[]): Promise<Json> {
    switch (f) {
      case "locate": {
        const key = args[0] as string;
        if (this.locateAsync === null) return this.#keepLocated(key, this.#locate(key) ?? null);
        const pending = new AbortController();
        // (where a session that moved on goes on, looked for as it is read: given up by the next read, `unfollow`)
        const following = args[1] === true;
        const lookups = following ? this.#following : this.#locating;
        const all = lookups.get(key) ?? new Set();
        lookups.set(key, all.add(pending));
        // (only a session's first lookup is waited for by `idle`: one going on is not)
        if (following) this.#asking--;
        try {
          return this.#keepLocated(key, (await this.locateAsync(key, pending.signal)) ?? null);
        } finally {
          if (following) this.#asking++;
          all.delete(pending);
          if (all.size === 0 && lookups.get(key) === all) lookups.delete(key);
        }
      }
      case "tailRead": {
        const [runtime, state] = args as [RuntimeKind, TailState | { path: string; runtime: RuntimeKind }];
        const read = this.tailRead !== null ? await this.tailRead(runtime, state) : await tailReadHere(runtime, state);
        // (each with how it is told in brief, made here as it was read: the program passes it on, `#tellOf`)
        return { ...read, entries: read.entries.map((e) => withBrief(e)) };
      }
      case "page": {
        const [key, before, limit, inBrief] = args as [string, number, number, boolean];
        if (this.history !== null) return this.history.page(key, before, limit, inBrief);
        return (await this.#pageHere(key, before, limit, inBrief, true)) ?? { start: 0, entries: [], end: 0 };
      }
      case "state": {
        const key = args[0] as string;
        await (this.handover ?? Promise.resolve()).catch(() => {});
        // (begun meanwhile from what the process before carried over: not asked)
        if (this.#begun.delete(key) || this.history === null) return null;
        return (await this.history.state(key)) ?? null;
      }
      default:
        throw new Error(`the live view asks nothing called ${f}`);
    }
  }

  #tellOf(f: string, args: Json[]) {
    switch (f) {
      case "told": {
        const [key, to, message, briefed] = args as [string, [number, boolean, boolean][], Json, boolean];
        let briefOf = (m: Json) => m;
        if (message?.type === "timeline") {
          message.usage = this.#usageOf(key);
          const whole = (message.entries as Json[]).map(({ [BRIEF]: _, ...e }) => e);
          const briefs = briefed ? whole : (message.entries as Json[]).map((e) => e[BRIEF] ?? brief(e));
          message.entries = whole;
          briefOf = (m: Json) => ({ ...m, entries: briefs });
        }
        for (const [id, inBrief, held] of to) {
          try {
            if (held) this.heldTold?.(key, briefOf(message));
            else {
              const sub = this.#subs.get(id);
              if (sub !== undefined) sub.listener(inBrief ? briefOf(message) : message);
            }
          } catch {}
        }
        return;
      }
      case "held":
        this.#held = args[0] as string[];
        return;
      case "pending":
        this.#pending = args[0] === true;
        return;
      case "length":
        try {
          this.lengths?.(args[0], args[1]);
        } catch {}
        return;
      case "count":
        this.#count?.ask(args[0]);
        return;
      case "watching":
        if (args[1] === true) this.#watching.add(args[0]);
        else {
          this.#watching.delete(args[0]);
          this.#told.delete(args[0]);
          for (const pending of [...(this.#locating.get(args[0]) ?? []), ...(this.#following.get(args[0]) ?? [])]) pending.abort();
        }
        return;
      case "begun":
        this.#begun.add(args[0]);
        return;
      case "unfollow":
        for (const pending of this.#following.get(args[0]) ?? []) pending.abort();
        return;
      case "arm":
        this.#arm(args[0], args[1]);
        return;
      case "disarm": {
        this.#watchers.get(args[0])?.watcher?.close();
        this.#watchers.delete(args[0]);
        return;
      }
      case "log": {
        const [level, message, fields] = args;
        (level === "warn" ? log.warn : level === "error" ? log.error : log.info)("live", message, fields ?? {});
        return;
      }
    }
  }

  /// Watches the transcript written to now: its file, or its `.zst` while packed (sessions/cold.ts); packed or restored,
  /// it is another file, watched from then on. Each change is said to the program (`soon`).
  #arm(key: string, path: string) {
    const was = this.#watchers.get(key);
    was?.watcher?.close();
    const w = { path, watcher: null as FSWatcher | null };
    this.#watchers.set(key, w);
    // Which of the two is there, asked off the main thread.
    void access(path).then(() => path, () => `${path}.zst`).then((file) => {
      if (this.#watchers.get(key) !== w || this.#closed) return;
      try {
        const watcher = watch(file, { persistent: false }, (event) => {
          if (event === "rename") this.#arm(key, path);
          this.soon(key);
        });
        watcher.on("error", () => {});
        w.watcher = watcher;
      } catch {}
    });
  }

  /// Where the program last found each session's transcripts: what a page read here reads (`#pageHere`).
  readonly #located = new Map<string, ReturnType<Locate>>();
  #keepLocated(key: string, at: ReturnType<Locate>): ReturnType<Locate> {
    if (at === null) this.#located.delete(key);
    else this.#located.set(key, at);
    return at;
  }

  /// A page of a session's transcripts read here, whole (no readers: a test's): for the program, where it found them.
  async #pageHere(key: string, before: number, limit: number, inBrief: boolean, asked = false): Promise<{ start: number; entries: TimelineEntry[]; end: number } | null> {
    const at = (asked ? this.#located.get(key) : undefined) ?? (this.locateAsync !== null ? await this.locateAsync(key, new AbortController().signal) : this.#locate(key));
    if (!at) return null;
    const tail = new ChainTail(at.runtime, at.paths);
    await tail.readSoon();
    const all = tail.entries;
    const end = Math.min(before, all.length);
    const start = Math.max(0, end - limit);
    const entries = all.slice(start, end);
    return { start, entries: inBrief ? entries.map(brief) : entries, end: all.length };
  }
}

/// Where an entry read for the live view carries how it is told in brief (read/transcript.ts `brief`, which says it best
/// of the entry it read itself), where that is not the entry itself.
const BRIEF = "~brief";
const withBrief = (e: TimelineEntry): Json => {
  const b = brief(e);
  return b === e ? e : { ...e, [BRIEF]: b };
};

/// What a transcript gained since `state`, read here (no readers: a test's) off the main thread, as test/reference/ops-sessions.ts
/// `tailRead` reads it.
async function tailReadHere(runtime: RuntimeKind, state: TailState | { path: string; runtime?: RuntimeKind }) {
  const tail = "offset" in state ? TranscriptTail.from(runtime, state) : new TranscriptTail(state.runtime ?? runtime, state.path, null, false);
  const [start, entries] = await tail.readSoon();
  return { start, entries, state: tail.snapshot() };
}
