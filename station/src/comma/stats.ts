// What Comma keeps of the workspace through a Comma connect, as a Comma station sends of its own (Cue's
// systems/station/src/stats and connector/task-index.ts), of this station and of the other stations of its workspace
// (read of them as `outflow.read`, peer.ts):
// - the Stats index (`stats.index`), source `stillfail`: what the agents spent, by day, chat, person, account and
//   model, and the chats they worked in;
// - the Task index (`task.index`): the chats as Comma lists the Tasks its stations host, which the Router reads and
//   writes in through the connect (`task.read`, `task.say`, surface.ts), each with what it asks of whom now
//   (`attention`, `waits_for`, `note`: read/outflow.ts attentionOf) and its link in the app (`url`), for Comma to
//   remind them by, and `router: true` when a Comma Router ever wrote in it (read/outflow.ts routerWrote), for
//   Comma's clients to list those alone.
// Both cover the last BUILD_DAYS, are kept per workspace under <data>/comma-indexes, numbered as their rows change, and each
// connection sends Comma what it does not hold yet, a page at a time.
//
// Built as Comma first connects, a minute after the agents' spending was recorded, as a chat moves or someone reads
// one (a minute after too), and every hour (another station's changes reach it so); one build at a time.
//
// The rows, their database and its pages are the MoonBit program's (station/mb/src/comma, reader `--builder
// comma-stats --db <file>`), none of it on the station's thread: Node reads what the stations give (peer.ts), drives a
// build's turns and keeps what is each connection's (what its Comma holds, whether it is resetting, the rows it takes a
// page): the program keeps nothing of a connection, so it is let go after IDLE_MS with nothing asked of it (or at
// once: `trimIdle`) and started again by the next ask, and no tombstone a connection still needs is pruned by one
// started again. There is no TypeScript to fall back to: what it replaced is station/test/reference/comma-stats.ts,
// which station/test/mb-comma-stats.test.ts holds it to.
import { createHash, randomBytes } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { MbProcess, readerBinary } from "../read/mb-reader.ts";

type Json = any;

/// The days a build takes again: what can still change (a call recorded late, a chat going on).
export const BUILD_DAYS = 31;
const DAY_MS = 24 * 60 * 60_000;
const SETTLE_MS = 60_000;
/// How long a statement on the statistics' database waits for another process's write (a handover's) before SQLite
/// refuses it.
export const BUSY_MS = 5000;
const EVERY_MS = 60 * 60_000;
/// How long the program with nothing asked of it is kept.
export const IDLE_MS = 60_000;
/// The source the rows are of, as Comma's analysis names it.
export const SOURCE = "stillfail";

/// What one station of the workspace gave: its usage rows (`outflowUsage`'s) and chats (`outflowChats`'), and the
/// people its rows name. `station`: another station's id; none for this one.
export type StationRows = { station?: string; usage: Json; chats: Json[] };

/// What a build reads: this station's rows, and those of each other station of the workspace that answered
/// (`unread`, the ids of those that did not: their rows stay as they were).
export type Read = (from: number, to: number) => Promise<{ stations: StationRows[]; unread: string[]; valid?: () => boolean }>;

/// A row as an index keeps it.
export type IndexRow = { key: string; source: string; kind: string; rev: number; removed: boolean; json: string };

/// A chat as the Task index and the Router name it: its thread here, `<thread>@<station>` on another station.
export const chatRef = (thread: number, station?: string) => (station === undefined ? String(thread) : `${thread}@${station}`);

/// The chat a Task index ref names, as chatRef made it; null for anything else.
export function chatOf(ref: string): { thread: number; station: string | null } | null {
  const m = /^([0-9]+)(?:@(.+))?$/.exec(ref);
  const thread = m ? Number(m[1]) : NaN;
  return m && Number.isSafeInteger(thread) && thread > 0 ? { thread, station: m[2] ?? null } : null;
}

/// The day (UTC) a build takes rows from, of `from` (ms).
export const fromDayOf = (from: number) => new Date(Math.floor(from / DAY_MS) * DAY_MS).toISOString().slice(0, 10);

// ── the program ────────────────────────────────────────────────────────────────────────────────────────────────────

/// Another process (a handover's) holds the index's database: the same ask is answered once it lets go.
export class IndexBusy extends Error {}

/// The program ended while an ask was under way (`close`).
export class CommaStatsStopped extends Error {}

type Waiting = { resolve: (answer: Json) => void; reject: (error: Error) => void };

/// One workspace's database as the program answers it, the program started at an ask and let go when idle.
class CommaProgram {
  readonly #path: string;
  readonly #binary: string | null;
  readonly #waitMs: number;
  readonly #after: (ms: number, f: () => void) => () => void;
  #process: MbProcess | null = null;
  #termination: Promise<number> | null = null;
  #next = 0;
  #waiting = new Map<number, Waiting>();
  #idle: (() => void) | null = null;
  #closed = false;
  /// Whether something keeps it from going though nothing is asked (a build under way between its turns).
  held = () => false;
  /// How many processes it started (tests).
  started = 0;

  constructor(path: string, options: { binary?: string; after?: (ms: number, f: () => void) => () => void; busyMs?: number }) {
    this.#path = path;
    this.#binary = options.binary ?? null;
    this.#waitMs = options.busyMs ?? BUSY_MS;
    this.#after = options.after ?? wall.after;
  }

  get running(): boolean { return this.#process !== null; }

  /// What the program answers `op` with `args` (mb/src/comma serve.mbt): its `error` thrown, IndexBusy where another
  /// process held the database, a SyntaxError where a row's JSON was not JSON.
  ask(op: string, args: Record<string, unknown> = {}): Promise<Json> {
    if (this.#closed) return Promise.reject(new CommaStatsStopped("station stopping"));
    return new Promise((resolve, reject) => {
      const id = ++this.#next;
      this.#waiting.set(id, { resolve, reject });
      this.#idle?.();
      this.#idle = null;
      try {
        const child = this.#start();
        child.ref(true);
        child.postMessage({ ...args, id, op });
      } catch (error) {
        this.#waiting.delete(id);
        reject(error as Error);
      }
    });
  }

  #start(): MbProcess {
    if (this.#process !== null) return this.#process;
    const args = ["--builder", "comma-stats", "--db", this.#path, ...(this.#waitMs === BUSY_MS ? [] : ["--wait", String(this.#waitMs)])];
    const child = new MbProcess(this.#binary ?? readerBinary(), args);
    this.started++;
    this.#process = child;
    child.on("message", (answer: Json) => {
      const waiting = typeof answer?.id === "number" ? this.#waiting.get(answer.id) : undefined;
      if (!waiting) return;
      this.#waiting.delete(answer.id);
      if (typeof answer.error !== "string") waiting.resolve(answer);
      else if (answer.busy === true) waiting.reject(new IndexBusy(answer.error));
      else if (answer.syntax === true) waiting.reject(new SyntaxError(answer.error));
      else waiting.reject(new Error(answer.error));
      this.idleLater();
    });
    let failure: Error | null = null;
    child.on("error", (error: Error) => {
      failure = error;
      log.error("comma", "the Comma indexes' program stopped", { error: error.message });
    });
    child.on("exit", (code: number) => {
      if (this.#process !== child) return;
      this.#process = null;
      this.#idle?.();
      this.#idle = null;
      const error = this.#closed ? new CommaStatsStopped("station stopping") : (failure ?? new Error(`the Comma indexes' program stopped (exit ${code})`));
      for (const waiting of this.#waiting.values()) waiting.reject(error);
      this.#waiting.clear();
    });
    return child;
  }

  /// Nothing asked of it: it goes after IDLE_MS unless asked again (and holds the station's process up meanwhile no
  /// longer).
  idleLater(): void {
    if (this.#closed || this.#process === null || this.#waiting.size > 0 || this.held() || this.#idle !== null) return;
    this.#process.ref(false);
    // timer: a deadline (an idle program's process let go)
    this.#idle = this.#after(IDLE_MS, () => {
      this.#idle = null;
      if (this.#waiting.size === 0 && !this.held()) this.#letGo();
    });
  }

  #letGo(): void {
    this.#idle?.();
    this.#idle = null;
    const child = this.#process;
    if (child === null) return;
    this.#process = null;
    this.#termination = child.terminate();
  }

  /// The program let go at once if nothing is asked of it: 1, else 0.
  trimIdle(): number {
    if (this.#closed || this.#process === null || this.#waiting.size > 0 || this.held()) return 0;
    this.#letGo();
    return 1;
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#idle?.();
    this.#idle = null;
    const child = this.#process;
    this.#process = null;
    for (const waiting of this.#waiting.values()) waiting.reject(new CommaStatsStopped("station stopping"));
    this.#waiting.clear();
    if (child !== null) this.#termination = child.terminate();
    if (this.#termination !== null) await this.#termination;
  }
}

// ── the pages a connection sends ───────────────────────────────────────────────────────────────────────────────────

/// What Comma holds of an index.
export type Held = { epoch: string | null; through: number };

/// A `stats.index` or `task.index` page.
export type Page = { epoch: string; reset: boolean; since: number; through: number; rows: Json[] };

/// How an index's rows are carried: `stats.index`'s or `task.index`'s.
export type Wire = "stats" | "task";

/// Comma's bounds on a page: rows, and bytes of its rows as JSON.
export const PAGE_ROWS = 200;
export const PAGE_BYTES = 60 * 1024;

/// An index as a connection follows it: what it is told changed, the page that only asks what Comma holds, and its
/// own reader of the pages after.
export interface PagedIndex {
  readonly ready: Promise<void>;
  listen(changed: () => void): () => void;
  /// The page that only asks what Comma holds: applying it changes nothing.
  probe(): Promise<Page>;
  /// A socket following it, from now until `close`.
  follow(wire: Wire): Promise<IndexFollower>;
}

export interface IndexFollower {
  /// The next page to send after Comma answered `held`; null once it holds all of the index.
  next(held: Held): Promise<Page | null>;
  close(): void;
}

/// An index Comma keeps a copy of: rows numbered by `rev` within an `epoch`, a row gone leaving a tombstone until every
/// connection's Comma holds it. What each connection holds is kept here, not in the program, which may be started
/// again between two pages.
export class RevIndex implements PagedIndex {
  readonly #program: CommaProgram;
  readonly #name: "stats_index" | "task_index";
  readonly #listeners = new Set<() => void>();
  /// What each connection's Comma holds: tombstones go once every one holds them.
  readonly #held = new Map<symbol, number>();
  readonly ready: Promise<void>;
  /// The epoch the program last said.
  epoch: string | null = null;

  constructor(program: CommaProgram, name: "stats_index" | "task_index", ready: Promise<void> = Promise.resolve()) {
    this.#program = program;
    this.#name = name;
    this.ready = ready;
  }

  async probe(): Promise<Page> {
    const got = await this.#program.ask("probe", { index: this.#name });
    this.epoch = got.epoch;
    return { epoch: got.epoch, reset: false, since: got.rev, through: got.rev, rows: [] };
  }

  /// Greatest revision of a tombstone already pruned (tests).
  async pruned(): Promise<number> {
    return (await this.#program.ask("probe", { index: this.#name })).pruned;
  }

  /// The rows past `since`, in revision order (tests).
  async since(since: number, limit: number): Promise<IndexRow[]> {
    return (await this.#program.ask("since", { index: this.#name, since, limit })).rows;
  }

  /// A socket is a distinct reader even when it is replacing a previous socket of the same connect. The prunes'
  /// trigger is installed first (after the old process exits: a schema write lock taken at startup could hold up the
  /// handover itself).
  async follow(wire: Wire): Promise<IndexFollower> {
    await this.#program.ask("guard", { index: this.#name });
    const token = Symbol();
    this.#held.set(token, 0);
    return new IndexSync(this, this.#program, this.#name, token, wire);
  }

  observed(token: symbol, through: number): void { if (this.#held.has(token)) this.#held.set(token, through); }

  /// What connection `token`'s Comma holds now; tombstones every one holds go. The least is taken as this is asked:
  /// the program answers asks in their order, so a connection that follows after it is not pruned past.
  async held(token: symbol, through: number): Promise<void> {
    this.#held.set(token, through);
    await this.#program.ask("held", { index: this.#name, through: Math.min(...this.#held.values()) });
  }

  /// A connection gone: what it held no longer keeps tombstones.
  gone(token: symbol): void { this.#held.delete(token); }

  listen(changed: () => void): () => void {
    this.#listeners.add(changed);
    return () => void this.#listeners.delete(changed);
  }

  /// Tells those listening, after the build that changed it.
  changed(): void {
    for (const l of this.#listeners) l();
  }
}

/// One socket following an index. A reset clears the receiver only on its first page; while it is paging, the socket
/// holds its acknowledged position so another sender cannot prune a tombstone it still needs.
class IndexSync implements IndexFollower {
  readonly #index: RevIndex;
  readonly #program: CommaProgram;
  readonly #name: string;
  readonly #token: symbol;
  readonly #wire: Wire;
  #resetting = false;
  #resetFloor = 0;
  #pageRows = PAGE_ROWS;

  constructor(index: RevIndex, program: CommaProgram, name: string, token: symbol, wire: Wire) {
    this.#index = index;
    this.#program = program;
    this.#name = name;
    this.#token = token;
    this.#wire = wire;
  }

  async next(held: Held): Promise<Page | null> {
    const index = this.#index;
    const epoch = index.epoch ?? (await index.probe()).epoch;
    index.observed(this.#token, held.epoch === epoch ? held.through : 0);
    const got = await this.#program.ask("page", { index: this.#name, epoch: held.epoch, through: held.through,
      rows: this.#pageRows, resetting: this.#resetting, resetFloor: this.#resetFloor, wire: this.#wire });
    const page: Page | null = got.page ?? null;
    if (page !== null) index.epoch = page.epoch;
    // Learn from wire size, not stored JSON size: a large Task body can make a small wire row.
    this.#pageRows = got.byteLimited === true ? Math.min(PAGE_ROWS, Math.max(8, 2 * (got.taken + 1))) : PAGE_ROWS;
    if (page?.reset === true) {
      this.#resetting = true;
      this.#resetFloor = got.floor;
      index.observed(this.#token, 0);
    } else if (page === null) {
      this.#resetting = false;
      await index.held(this.#token, held.through);
    }
    return page;
  }

  close(): void { this.#index.gone(this.#token); }
}

/// Comma's answer to a page, or null when it is not one.
export function heldFrom(result: unknown): Held | null {
  if (typeof result !== "object" || result === null) return null;
  const { epoch, through } = result as Record<string, unknown>;
  if (epoch !== null && epoch !== undefined && typeof epoch !== "string") return null;
  return { epoch: (epoch as string | null | undefined) ?? null, through: typeof through === "number" && through >= 0 ? through : 0 };
}

/// An index of nothing, in memory, for a connect of no workspace the station is in now: it must not receive another's
/// index, and an empty epoch makes Comma remove the rows an older station already sent it (once: then it holds it).
export class EmptyIndex implements PagedIndex {
  readonly ready = Promise.resolve();
  readonly #epoch: string;

  constructor(name: "stats_index" | "task_index") {
    const epoch = randomBytes(16).toString("hex");
    this.#epoch = name === "stats_index" ? `${epoch}.keys1.gc1` : `${epoch}.gc1`;
  }

  listen(): () => void { return () => {}; }
  async probe(): Promise<Page> { return { epoch: this.#epoch, reset: false, since: 0, through: 0, rows: [] }; }
  async follow(): Promise<IndexFollower> {
    const epoch = this.#epoch;
    return {
      // (a copy of another epoch, or one ahead of this index's revision 0, is reset to nothing)
      next: async (held) => (held.epoch !== epoch || held.through > 0 ? { epoch, reset: true, since: 0, through: 0, rows: [] } : null),
      close: () => {},
    };
  }
}

// ── a workspace's indexes ──────────────────────────────────────────────────────────────────────────────────────────

export class CommaStats {
  readonly #program: CommaProgram;
  /// The Stats index and the Task index.
  readonly stats: RevIndex;
  readonly tasks: RevIndex;
  #building: Promise<void> | null = null;
  #again = false;
  #stops: (() => void)[] | null = null;
  #closed = false;
  #stopRetry: (() => void) | null = null;
  #builds = 0;
  readonly #read: Read;
  readonly #changes: (changed: () => void) => () => void;

  /// `changes`: tells when the agents spent or a chat moved, until the function it answers is called. `options.busyMs`:
  /// how long a statement waits for another's write before it is refused (`BUSY_MS`; a test holding the database's
  /// lock gives less). `options.binary`: the program (readerBinary's where none is given); `options.after`: the timer of
  /// IDLE_MS (a test's own; else the wall's).
  constructor(path: string, read: Read, changes: (changed: () => void) => () => void,
    options: { ready?: Promise<void>; busyMs?: number; binary?: string; after?: (ms: number, f: () => void) => () => void } = {}) {
    this.#read = read;
    this.#changes = changes;
    this.#program = new CommaProgram(path, options);
    this.#program.held = () => this.#building !== null;
    this.stats = new RevIndex(this.#program, "stats_index", options.ready);
    this.tasks = new RevIndex(this.#program, "task_index", options.ready);
  }

  /// Whether its program runs now, and how many it started (tests).
  get running(): boolean { return this.#program.running; }
  get started(): number { return this.#program.started; }

  /// A Task's current title, if it is in the index. A removed Task has no title for the Router.
  async taskTitle(ref: string): Promise<Json> {
    const got = await this.#program.ask("title", { ref });
    return got.found === true ? got.title : "";
  }

  /// The program let go at once if nothing is asked of it and no build is under way: 1, else 0.
  trimIdle(): number {
    return this.#closed ? 0 : this.#program.trimIdle();
  }

  /// The directories the indexes are kept in (`inWorkspace`'s), made once off the main thread before them.
  static async makeDirs(data: string): Promise<void> {
    await mkdir(data, { recursive: true });
    await mkdir(join(data, "comma-indexes"), { recursive: true, mode: 0o700 });
  }

  /// A workspace's index is never taken from the old, unscoped index: its owner is not known after a home change.
  static inWorkspace(data: string, workspace: string, read: Read, changes: (changed: () => void) => () => void,
    options: { binary?: string; after?: (ms: number, f: () => void) => () => void } = {}): CommaStats {
    const dir = join(data, "comma-indexes");
    // Preserve JavaScript's whole string, including lone surrogates, rather than folding them to U+FFFD in UTF-8.
    const name = createHash("sha256").update(workspace, "utf16le").digest("hex");
    return new CommaStats(join(dir, `${name}.db`), read, changes, options);
  }

  /// Once Comma is connected first: builds now, a minute after a change, and every hour, until close.
  start(): void {
    if (this.#closed || this.#stops !== null) return;
    let settle: (() => void) | null = null;
    const stopChanges = this.#changes(() => {
      if (settle !== null) return;
      // timer: a debounce (a minute's changes built together)
      settle = wall.after(SETTLE_MS, () => {
        settle = null;
        this.build();
      });
    });
    const tick = () => {
      this.build();
      hourly = wall.after(EVERY_MS, tick); // timer: another station's changes, which tell this one nothing
    };
    let hourly = wall.after(EVERY_MS, tick); // timer: another station's changes, which tell this one nothing
    this.#stops = [stopChanges, () => settle?.(), () => hourly()];
    this.build();
  }

  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    this.#stopRetry?.();
    for (const stop of this.#stops ?? []) stop();
    this.#stops = null;
    await this.#program.close();
  }

  /// A build, after the one under way when there is one.
  build(): void {
    if (this.#closed) return;
    if (this.#building !== null) {
      this.#again = true;
      return;
    }
    const now = wall.now();
    this.#building = this.#read(now - BUILD_DAYS * DAY_MS, now)
      .then(({ stations, unread, valid }) => this.#applyBuild(stations, unread, now - BUILD_DAYS * DAY_MS, valid))
      .catch((e) => { if (!this.#closed) log.info("comma", "the statistics were not read this time", { error: (e as Error).message }); })
      .finally(() => {
        this.#building = null;
        if (this.#again && !this.#closed) {
          this.#again = false;
          this.build();
        } else this.#program.idleLater();
      });
  }

  /// Settles once the build under way (tests).
  async settled(): Promise<void> {
    while (this.#building !== null) await this.#building;
  }

  // The program prepares the age index a batch a turn, then writes the build in one transaction (mb/src/comma
  // build.mbt); each turn yields so a first build on an old database does not take its whole history at once, and a
  // read gone stale meanwhile is not written.
  async #applyBuild(stations: StationRows[], unread: string[], from: number, valid: () => boolean = () => true): Promise<void> {
    const id = ++this.#builds;
    const fromDay = fromDayOf(from);
    let given = false;
    let retryMs = 25;
    while (!this.#closed && valid()) {
      try {
        // (its rows are given again where the first turn found the database held: they may not have been kept)
        const got = given ? await this.#program.ask("turn", { build: id })
          : await this.#program.ask("build", { build: id, stations, unread, fromDay });
        given = true;
        if (got.done === true) {
          if (got.stats > 0) this.stats.changed();
          if (got.tasks > 0) this.tasks.changed();
          return;
        }
        retryMs = 25;
      } catch (error) {
        if (!(error instanceof IndexBusy)) throw error;
        // A previous station can still have the database locked during handover. Retrying the finite work after a
        // backoff keeps that lock from making this build silently disappear.
        await new Promise<void>((resolve) => {
          const finish = () => { this.#stopRetry = null; resolve(); };
          const stop = wall.after(retryMs, finish); // timer: retry a locked index with backoff
          this.#stopRetry = () => { stop(); finish(); };
        });
        retryMs = Math.min(retryMs * 2, 2_000);
      }
    }
    // (a read gone stale: its rows let go)
    if (given && !this.#closed) await this.#program.ask("cancel", { build: id }).catch(() => {});
  }

  /// The stations' rows from the day of `from` on, written where they changed, the age index not used (tests). How
  /// many rows of each index changed.
  async apply(stations: StationRows[], unread: string[], from: number): Promise<{ stats: number; tasks: number }> {
    const got = await this.#program.ask("apply", { stations, unread, fromDay: fromDayOf(from) });
    if (got.stats > 0) this.stats.changed();
    if (got.tasks > 0) this.tasks.changed();
    return { stats: got.stats, tasks: got.tasks };
  }
}
