// What the station finds for a search: looked for by the MoonBit program (station/mb, src/search; `--builder search`),
// built for every system the station runs on, in the station's data as it is then. A prepared candidate scope avoids
// unrelated chats; their contents are read as asked. The program is started by the first search and let go once none
// has been asked for IDLE_MS (or at once when the station is short of memory: `trimIdle`): kept from the station's
// start, it held 234 MB for hours nobody searched (2026-11-15). It keeps nothing a search needs between searches (each
// reads the database as it is then), so the next is answered by one started again; one that dies is started again too. The machine's files are asked beside it (search/files.ts). A test may give it a
// thread to look instead (`worker`: the search as the station's thread looked before, test/reference/search-worker.ts).
import { Worker } from "node:worker_threads";
import { rmSync } from "node:fs";
import { join, sep } from "node:path";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import { type Asker, type Group, terms } from "./match.ts";
import type { FileSearch } from "./files.ts";
/// What a looker is told, and what it answers.
export type Told = { type: "query"; id: number; query: string; asker: Asker; kinds?: string[]; limit?: number; offset?: number; archived?: boolean; cancel?: SharedArrayBuffer };
export type Answered = { id: number; groups?: Group[]; error?: string } | { scopePending: true } | { sessionListPending: true };
import { SearchScopeBuilder } from "./scope-builder.ts";
import { SessionListBuilder } from "../read/session-list-builder.ts";
import { MbProcess, mbReaderBinary } from "../read/mb-reader.ts";

/// How long a search may take before it is answered with nothing.
const QUERY_MS = 30_000;
/// How long the program is kept with no search asked of it.
const IDLE_MS = 60_000;

/// `building`: always false (said to the clients that showed an index still being built).
export type Found = { groups: Group[]; building: boolean };

type Looker = Worker | MbProcess;

export class Search {
  #data: string;
  /// The program (none: not built here; the worker looks through everything).
  readonly #mb: string | null;
  #program: MbProcess | null = null;
  #worker: Worker | null = null;
  #next = 0;
  #waiting = new Map<number, { resolve: (found: Found) => void; reject: (error: Error) => void; timer: () => void }>();
  #closed = false;
  readonly #scope: SearchScopeBuilder;
  #preparingScope: Promise<void> | null = null;
  readonly #sessionList: SessionListBuilder;
  #preparingSessions: Promise<void> | null = null;
  /// The machine's files (none: not searched here).
  #files: FileSearch | null;
  /// The idle looker's going armed (IDLE_MS), called off by a search.
  #idle: (() => void) | null = null;
  readonly #after: (ms: number, f: () => void) => () => void;

  readonly #workerFile: URL | null;

  /// `after`: the timer of IDLE_MS (a test's own; else the wall's).
  constructor(options: { data: string; files?: FileSearch | null; backfill?: { previousGone?: Promise<void>; priority?: SharedArrayBuffer }; worker?: URL; after?: (ms: number, f: () => void) => () => void }) {
    this.#data = options.data;
    this.#after = options.after ?? wall.after;
    this.#workerFile = options.worker ?? null;
    this.#mb = this.#workerFile !== null ? null : mbReaderBinary();
    this.#files = options.files ?? null;
    this.#scope = new SearchScopeBuilder(join(options.data, "stillfail.db"), options.backfill);
    this.#sessionList = new SessionListBuilder(join(options.data, "stillfail.db"), options.backfill);
  }

  /// The index an earlier station kept removed: there is none now. Nothing is started until a search is asked.
  start(): void {
    for (const f of ["search.db", "search.db-wal", "search.db-shm"]) rmSync(join(this.#data, f), { force: true });
  }

  /// Whether a looker runs now (the program, or the test's thread).
  get running(): boolean { return this.#program !== null || this.#worker !== null; }

  /// The looker let go at once if no search is under way: 1, else 0 (the station short of memory: read/pool.ts
  /// `trimIdle`). The next search starts it again.
  trimIdle(): number {
    if (this.#closed || this.#waiting.size > 0 || !this.running) return 0;
    this.#letGo();
    return 1;
  }

  #letGo(): void {
    this.#idle?.();
    this.#idle = null;
    const program = this.#program, worker = this.#worker;
    this.#program = null;
    this.#worker = null;
    void program?.terminate();
    void worker?.terminate();
  }

  /// No search under way: the looker goes after IDLE_MS unless one is asked meanwhile.
  #idleLater(): void {
    if (this.#closed || this.#waiting.size > 0 || this.#idle !== null || !this.running) return;
    // timer: a deadline (an idle program's process let go)
    this.#idle = this.#after(IDLE_MS, () => {
      this.#idle = null;
      if (this.#waiting.size === 0) this.#letGo();
    });
  }

  #spawnProgram(): MbProcess | null {
    if (this.#closed || this.#mb === null) return null;
    const program = new MbProcess(this.#mb, ["--builder", "search", "--db", join(this.#data, "stillfail.db"), "--data", this.#data, "--sep", sep]);
    this.#program = program;
    this.#listen(program, () => { if (this.#program === program) this.#program = null; });
    return program;
  }

  #spawn(): Worker | null {
    if (this.#closed || this.#workerFile === null) return null;
    const file = this.#workerFile;
    const worker = new Worker(file, { workerData: { data: this.#data }, resourceLimits: { maxOldGenerationSizeMb: 384 } });
    this.#worker = worker;
    this.#listen(worker, () => { if (this.#worker === worker) this.#worker = null; });
    return worker;
  }

  /// A looker's answers: each to the search it is for; its end ends the searches waiting on it.
  #listen(looker: Looker, gone: () => void): void {
    const mine = new Set<number>();
    (looker as Worker).on("message", (answer: Answered) => {
      if ("scopePending" in answer) { if (!this.#closed) this.#prepareScope(); return; }
      if ("sessionListPending" in answer) { if (!this.#closed) this.#prepareSessions(); return; }
      mine.delete(answer.id);
      const waiter = this.#waiting.get(answer.id);
      if (!waiter) return;
      this.#waiting.delete(answer.id);
      waiter.timer();
      if (answer.error !== undefined) waiter.reject(new Error(answer.error));
      else waiter.resolve({ groups: answer.groups ?? [], building: false });
      this.#idleLater();
    });
    (looker as Worker).on("error", (error: Error) => log.error("search", "the search's thread stopped", { error: error.message }));
    (looker as Worker).on("exit", () => {
      gone();
      for (const [id, waiter] of this.#waiting) {
        if (!mine.has(id)) continue;
        waiter.timer();
        waiter.reject(new Error("the search stopped"));
        this.#waiting.delete(id);
      }
      this.#idleLater();
    });
    this.#asked.set(looker, mine);
  }

  readonly #asked = new WeakMap<Looker, Set<number>>();

  /// What `query` finds for `asker`: by kind, at most `limit` of each (those of `kinds` only, when given; the execution
  /// history only when asked for by name), the machine's files beside the rest.
  async query(query: string, asker: Asker, options: { kinds?: string[]; limit?: number; offset?: number; archived?: boolean } = {}): Promise<Found> {
    const files = this.#files;
    const wantsFiles = files !== null && (!options.kinds || options.kinds.length === 0 || options.kinds.includes("file")) && (options.offset ?? 0) === 0;
    const rest = options.kinds?.filter((k) => k !== "file");
    const [looked, found] = await Promise.all([
      options.kinds && options.kinds.length > 0 && rest!.length === 0 ? Promise.resolve({ groups: [], building: false }) : this.#looked(query, asker, options),
      wantsFiles ? files.query(terms(query), asker, Math.max(1, Math.min(options.limit ?? 8, 200))).catch(() => null) : Promise.resolve(null),
    ]);
    return found === null ? looked : { ...looked, groups: [...looked.groups, found] };
  }

  // Preparation is shared and never holds up the current search. A later query retries after a failure or change.
  #prepareScope(): void {
    if (this.#preparingScope !== null) return;
    const pending = this.#scope.prepare();
    this.#preparingScope = pending;
    void pending.catch((error: unknown) => {
      if (!this.#closed) log.warn("search", "the candidate scope could not be prepared", { error: (error as Error).message });
    }).finally(() => { if (this.#preparingScope === pending) this.#preparingScope = null; });
  }

  #prepareSessions(): void {
    if (this.#preparingSessions !== null) return;
    const pending = this.#sessionList.readySearch();
    this.#preparingSessions = pending;
    void pending.catch((error: unknown) => {
      if (!this.#closed) log.warn("search", "the session list could not be prepared", { error: (error as Error).message });
    }).finally(() => { if (this.#preparingSessions === pending) this.#preparingSessions = null; });
  }

  #looked(query: string, asker: Asker, options: { kinds?: string[]; limit?: number; offset?: number; archived?: boolean }): Promise<Found> {
    return this.#ask(this.#mb === null ? this.#worker ?? this.#spawn() : this.#program ?? this.#spawnProgram(), query, asker, options);
  }

  #ask(looker: Looker | null, query: string, asker: Asker, options: { kinds?: string[]; limit?: number; offset?: number; archived?: boolean }): Promise<Found> {
    if (!looker) return Promise.reject(new Error("the search is stopped"));
    this.#idle?.();
    this.#idle = null;
    const id = this.#next++;
    const program = looker instanceof MbProcess;
    const cancel = program ? undefined : new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
    return new Promise<Found>((resolve, reject) => {
      const timer = wall.after(QUERY_MS, () => {
        if (cancel) Atomics.store(new Int32Array(cancel), 0, 1);
        else looker.postMessage({ type: "cancel", id });
        this.#waiting.delete(id);
        reject(new Error("the search took too long"));
        this.#idleLater();
      });
      this.#waiting.set(id, { resolve, reject, timer });
      this.#asked.get(looker)?.add(id);
      looker.postMessage({ type: "query", id, query, asker, ...options, ...(cancel ? { cancel } : {}) } satisfies Told);
    });
  }

  async stop(): Promise<void> {
    this.#closed = true;
    this.#idle?.();
    this.#idle = null;
    await Promise.all([this.#worker?.terminate(), this.#program?.terminate(), this.#scope.close(), this.#sessionList.close()]);
    this.#worker = null;
    this.#program = null;
  }
}
