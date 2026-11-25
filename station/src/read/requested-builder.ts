import { setMaxListeners } from "node:events";
import { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { REQUEST_BACKFILL_PAUSE_MS, giveBackfill, releaseStoppedBackfill, takeBackfill } from "../store/backfill.ts";
import { type BackfillOptions, MbProcess } from "./mb-reader.ts";

/// A builder in MoonBit or Pion (read/mb-reader.ts): its program (resolved on each spawn when given as a getter)
/// and arguments. It knows nothing of the backfill permit, which
/// the builder here takes for it around each batch it asks, and gives back when the batch is answered; or (`lazy`) it
/// asks for the permit itself when it is about to write: a line `{"take": true}` answered `{"permit": …}`,
/// `{"give": true}` when it is done with it before its answer. Each is told of what is let go (`cancel`). One that
/// answers `{"fallback": true}` (a store whose schema the station's writer must repair first: the merged view, as an
/// older station dropped an index under it) has `repair` called, and the batch asked again (after a pause where the
/// repair found the database busy: `repair` waits for no lock).
export type MbBuilder = { binary: string | (() => string); args: string[]; lazy?: boolean; repair?: () => void };
/// What stands for a MoonBit builder in the permit: never a thread's.
let nextOwner = 0x40000000;

type Waiter = { resolve: () => void; reject: (error: Error) => void; done: () => void };
const IDLE_MS = 5_000;

/// Requested old state alone; readers share progress, each slice gives other work a turn, and abandoned work stops.
export class RequestedBuilder<K extends number | string> {
  readonly #options: BackfillOptions;
  readonly #timers: Fibers;
  readonly #field: "thread" | "session" | "scope";
  readonly #message: ((item: K, cancel: boolean) => Record<string, unknown>) | undefined;
  readonly #waiting = new Map<K, Set<Waiter>>();
  #worker: MbProcess | null = null;
  readonly #mb: MbBuilder;
  /// The MoonBit builder's own in the permit, and whether it holds it for the batch it was asked.
  #owner = 0;
  #holding = false;
  #current: K | null = null;
  #previousReady = false;
  #previousWaiting = false;
  #closed = false;
  #retry: (() => void) | null = null;
  #idle: (() => void) | null = null;
  #retryMs = 250;

  constructor(options: BackfillOptions, mb: MbBuilder,
    field: "thread" | "session" | "scope", name: string, message?: (item: K, cancel: boolean) => Record<string, unknown>) {
    this.#options = options; this.#mb = mb; this.#field = field; this.#timers = new Fibers(name);
    this.#message = message;
  }

  #priority(): Int32Array | null {
    return this.#options.priority instanceof SharedArrayBuffer ? new Int32Array(this.#options.priority) : null;
  }

  /// A batch asked of the MoonBit builder, once it holds the permit (store/backfill.ts); without it, the batch is not
  /// done, after a pause.
  #askMb(process: MbProcess, message: Record<string, unknown>): void {
    if (this.#mb.lazy) return void process.postMessage(message);
    if (!takeBackfill(this.#priority(), this.#owner)) {
      this.#timers.after(REQUEST_BACKFILL_PAUSE_MS, () => { if (this.#worker === process) this.#answer({ done: false }); });
      return;
    }
    this.#holding = true;
    process.postMessage(message);
  }

  /// The MoonBit builder's answer: the permit given back, and a batch that did not finish everything followed by a
  /// pause before it is answered.
  #answeredMb(process: MbProcess, result: { done: boolean; error?: string; take?: boolean; give?: boolean; fallback?: boolean }): void {
    if (result.fallback === true) {
      if (this.#holding) { this.#holding = false; giveBackfill(this.#priority(), this.#owner); }
      const repair = this.#mb.repair;
      if (repair === undefined) return void this.#answer({ done: false, error: "the store needs a repair this builder cannot make" });
      log.info("readers", "a MoonBit builder left this store's schema to the writer to repair", { args: this.#mb.args.slice(0, 2) });
      try { repair(); }
      catch (error) {
        // (the database busy with another's write: no error, the batch asked again after a pause, as any batch not done)
        const code = (error as { errcode?: number }).errcode;
        if (code === undefined || ![5, 6].includes(code & 255)) return void this.#answer({ done: false, error: (error as Error).message });
        this.#timers.after(REQUEST_BACKFILL_PAUSE_MS, () => { if (this.#worker === process) this.#answer({ done: false }); });
        return;
      }
      return void this.#answer({ done: false });
    }
    if (result.take === true) {
      if (!this.#holding) this.#holding = takeBackfill(this.#priority(), this.#owner);
      return void process.postMessage({ permit: this.#holding });
    }
    if (result.give === true) {
      if (this.#holding) { this.#holding = false; giveBackfill(this.#priority(), this.#owner); }
      return;
    }
    if (this.#holding) { this.#holding = false; giveBackfill(this.#priority(), this.#owner); }
    if (!result.done && !result.error) this.#timers.after(REQUEST_BACKFILL_PAUSE_MS, () => { if (this.#worker === process) this.#answer(result); });
    else this.#answer(result);
  }

  ready(items: readonly K[], signal?: AbortSignal): Promise<void> {
    if (this.#closed) return Promise.reject(new Error("station stopping"));
    if (signal?.aborted) return Promise.reject(new Error("read cancelled"));
    const cancel = new AbortController();
    setMaxListeners(0, cancel.signal);
    const abort = () => cancel.abort();
    signal?.addEventListener("abort", abort, { once: true });
    return Promise.all([...new Set(items)].map((item) => this.#readyItem(item, cancel.signal)))
      .then(() => {})
      .catch((error: unknown) => { cancel.abort(); throw error; })
      .finally(() => signal?.removeEventListener("abort", abort));
  }

  #readyItem(item: K, signal: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
      let waiters = this.#waiting.get(item);
      if (!waiters) { waiters = new Set(); this.#waiting.set(item, waiters); }
      const group = waiters;
      const abort = () => { waiter.done(); reject(new Error("read cancelled")); this.#pump(); };
      const waiter: Waiter = { resolve, reject, done: () => {
        signal.removeEventListener("abort", abort);
        group.delete(waiter);
        if (group.size === 0 && this.#waiting.get(item) === group) this.#waiting.delete(item);
      } };
      group.add(waiter);
      signal.addEventListener("abort", abort, { once: true });
      this.#pump();
    });
  }

  #fail(item: K, error: Error): void {
    const waiters = this.#waiting.get(item);
    this.#waiting.delete(item);
    if (waiters) for (const waiter of [...waiters]) { waiter.done(); waiter.reject(error); }
  }

  #answer(result: { done: boolean; error?: string }): void {
    const item = this.#current;
    this.#current = null;
    if (this.#closed || item === null) return;
    if (result.error) this.#fail(item, new Error(result.error));
    else {
      const waiters = this.#waiting.get(item);
      if (waiters && result.done) for (const waiter of [...waiters]) { waiter.done(); waiter.resolve(); }
      else if (waiters) { this.#waiting.delete(item); this.#waiting.set(item, waiters); }
      this.#retryMs = 250;
    }
    if (!this.#waiting.has(item) && !result.done) this.#worker?.postMessage(this.#message?.(item, true) ?? { [this.#field]: item, cancel: true });
    this.#pump();
  }

  #pump(): void {
    if (this.#closed || this.#current !== null || this.#retry !== null) return;
    if (this.#waiting.size === 0) {
      if (this.#worker !== null && this.#idle === null) {
        const worker = this.#worker;
        this.#idle = this.#timers.after(IDLE_MS, () => {
          this.#idle = null;
          if (this.#worker === worker && this.#current === null && this.#waiting.size === 0) {
            this.#worker = null; void worker.terminate();
          }
        });
      }
      return;
    }
    if (this.#idle !== null) { this.#idle(); this.#idle = null; }
    if (!this.#previousReady) {
      if (this.#previousWaiting) return;
      this.#previousWaiting = true;
      void (this.#options.previousGone ?? Promise.resolve()).then(() => {
        this.#previousReady = true; this.#previousWaiting = false; this.#pump();
      }, (error) => {
        this.#previousWaiting = false;
        for (const item of [...this.#waiting.keys()]) this.#fail(item, error instanceof Error ? error : new Error(String(error)));
      });
      return;
    }
    if (this.#worker === null) {
      let mb: MbProcess;
      try {
        const binary = typeof this.#mb.binary === "function" ? this.#mb.binary() : this.#mb.binary;
        mb = new MbProcess(binary, this.#mb.args);
      } catch (error) {
        const err = error instanceof Error ? error : new Error(String(error));
        log.warn("readers", "an old-state builder could not start", { error: err.message });
        for (const item of [...this.#waiting.keys()]) this.#fail(item, err);
        return;
      }
      const owner = this.#owner = nextOwner++;
      this.#worker = mb;
      mb.on("message", (result: { done: boolean; error?: string }) => { if (this.#worker === mb) this.#answeredMb(mb, result); });
      mb.once("error", (error: Error) => log.warn("readers", "an old-state builder failed", { error: error.message }));
      mb.once("exit", () => {
        releaseStoppedBackfill(this.#options.priority, owner);
        // (only the builder's own: one let go idle can end after the next one took the permit for its batch, which
        // would then never be given back, and no batch of any builder sharing the permit asked again)
        if (this.#worker === mb) this.#holding = false;
        this.#gone(mb);
      });
    }
    const item = this.#waiting.keys().next().value as K | undefined;
    if (item === undefined) return;
    this.#current = item;
    this.#askMb(this.#worker, this.#message?.(item, false) ?? { [this.#field]: item });
  }

  /// Its builder process let go now, not IDLE_MS after its last answer, when it answers nothing and nobody
  /// waits on it (the station short of memory: ops/self-memory.ts); whether it was. One answering is never stopped.
  trimIdle(): boolean {
    const worker = this.#worker;
    if (this.#closed || worker === null || this.#current !== null || this.#waiting.size > 0 || this.#holding) return false;
    if (this.#idle !== null) { this.#idle(); this.#idle = null; }
    this.#worker = null;
    void worker.terminate();
    return true;
  }

  /// The builder process ended: what it held is asked again of another, after a growing wait.
  #gone(worker: MbProcess): void {
    if (this.#worker !== worker) return;
    this.#worker = null; this.#current = null;
    if (this.#idle !== null) { this.#idle(); this.#idle = null; }
    if (this.#closed || this.#waiting.size === 0) return;
    const ms = this.#retryMs;
    this.#retryMs = Math.min(ms * 2, 30_000);
    this.#retry = this.#timers.after(ms, () => { this.#retry = null; this.#pump(); });
  }

  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    this.#retry?.(); this.#retry = null;
    this.#idle?.(); this.#idle = null;
    for (const item of [...this.#waiting.keys()]) this.#fail(item, new Error("station stopping"));
    const worker = this.#worker; this.#worker = null;
    if (worker !== null) await worker.terminate();
    await this.#timers.close();
  }
}
