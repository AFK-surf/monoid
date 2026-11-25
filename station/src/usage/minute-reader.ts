import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type BackfillOptions, MbProcess, engineOfSelection, fallbackModeOf, resolveReaderSelection } from "../read/mb-reader.ts";
import { readerTelemetry } from "../read/reader-telemetry.ts";
import type { InWorkspace } from "../store/rows.ts";

export type MinuteRequest = { id: number; remote: true } | { id: number; chats: InWorkspace | null };
export type MinuteResponse = { id?: number; error?: string; complete?: boolean; foreground?: boolean };

/// How long a checker with nothing asked of it is kept.
const IDLE_MS = 60_000;

/// Check whether the statistics kept apart from the usage itself (the remote tasks' index, the chats' and cards' counts)
/// are complete for a reader, without writing or filling old history, by the MoonBit checker (station/mb, src/usage:
/// `--builder usage-check`; what was spent is counted as it is written, store/usage-15m.ts, and needs none; `binary`: the program, a test's own where it gives one). One with
/// nothing asked of it goes after IDLE_MS (or at once: `trimIdle`) and is started again by the next ask: it keeps
/// nothing between asks (each is answered from the database as it is then), and what this keeps (`complete`) stays.
export class MinuteReader {
  readonly #path: string;
  readonly #mb: string | undefined;
  readonly #readers: BackfillOptions["readers"];
  #worker: MbProcess | null = null;
  #next = 0;
  #closed = false;
  #complete = false;
  #termination: Promise<number> | null = null;
  #waiting = new Map<number, { resolve: () => void; reject: (error: Error) => void; request: MinuteRequest; sent: boolean; at: number }>();
  /// The idle checker's going armed (IDLE_MS), called off by an ask.
  #idle: (() => void) | null = null;
  readonly #after: (ms: number, f: () => void) => () => void;
  /// `options.after`: the timer of IDLE_MS (a test's own; else the wall's).
  constructor(path: string, options: BackfillOptions & { after?: (ms: number, f: () => void) => () => void } = {}, binary?: string) {
    this.#path = path;
    this.#mb = binary;
    this.#readers = options.readers;
    this.#after = options.after ?? wall.after;
  }

  /// Whether a checker runs now.
  get running(): boolean { return this.#worker !== null; }

  /// The checker let go at once if nothing is asked of it: 1, else 0.
  trimIdle(): number {
    if (this.#closed || this.#worker === null || this.#waiting.size > 0) return 0;
    this.#letGo();
    return 1;
  }

  #letGo(): void {
    this.#idle?.();
    this.#idle = null;
    const worker = this.#worker;
    if (worker === null) return;
    this.#worker = null;
    this.#termination = worker.terminate();
  }

  /// Nothing asked of the checker: it goes after IDLE_MS unless asked again.
  #idleLater(): void {
    if (this.#closed || this.#worker === null || this.#waiting.size > 0 || this.#idle !== null) return;
    // timer: a deadline (an idle program's process let go)
    this.#idle = this.#after(IDLE_MS, () => {
      this.#idle = null;
      if (this.#waiting.size === 0) this.#letGo();
    });
  }

  start(): void {
    if (this.#closed || this.#complete || this.#worker !== null) return;
    const sel = resolveReaderSelection("usage-check", { binary: this.#mb, config: this.#readers, logAt: "readers" });
    const worker = new MbProcess(sel.primaryBinary, ["--builder", "usage-check", "--db", this.#path], { engine: engineOfSelection(sel), fallbackMode: fallbackModeOf(sel.selection) });
    this.#worker = worker;
    worker.on("message", (answer: MinuteResponse) => {
      if (answer.complete) {
        this.#complete = true;
        const now = wall.now();
        for (const waiting of this.#waiting.values()) {
          if (waiting.sent) readerTelemetry.recordCall(worker.engine, worker.mode, now - waiting.at, true);
          waiting.resolve();
        }
        this.#waiting.clear();
        if (this.#worker === worker) this.#worker = null;
        this.#termination = worker.terminate();
        return;
      }
      if (answer.id === undefined) return;
      const waiting = this.#waiting.get(answer.id);
      if (!waiting) return;
      this.#waiting.delete(answer.id);
      if (waiting.sent) readerTelemetry.recordCall(worker.engine, worker.mode, wall.now() - waiting.at, !answer.error);
      if (answer.error) waiting.reject(new Error(answer.error));
      else waiting.resolve();
      this.#idleLater();
    });
    let failure: Error | null = null;
    worker.on("error", (error: Error) => {
      failure = error;
      log.error("usage", "the minute summary worker stopped", { engine: worker.engine, mode: worker.mode, error: error.message });
    });
    worker.on("exit", (code: number) => {
      const current = this.#worker === worker;
      if (current) this.#worker = null;
      if (current && !this.#complete && !this.#closed) {
        const now = wall.now();
        for (const waiting of this.#waiting.values()) {
          if (waiting.sent) readerTelemetry.recordCall(worker.engine, worker.mode, now - waiting.at, false);
          waiting.reject(failure ?? new Error(`the minute summary worker stopped (exit ${code})`));
        }
        this.#waiting.clear();
      }
    });
    this.#sendWaiting();
    this.#idleLater();
  }

  #sendWaiting(): void {
    if (this.#worker === null) return;
    if (this.#waiting.size > 0) { this.#idle?.(); this.#idle = null; }
    for (const waiting of this.#waiting.values()) if (!waiting.sent) {
      waiting.at = wall.now();
      this.#worker.postMessage(waiting.request);
      waiting.sent = true;
    }
  }

  /// Remote-task statistics may already be complete even when another statistic is incomplete.
  readyRemote(): Promise<void> {
    if (this.#closed) return Promise.reject(new Error("station stopping"));
    if (this.#complete) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const id = ++this.#next;
      try {
        this.#waiting.set(id, { resolve, reject, request: { id, remote: true }, sent: false, at: 0 });
        this.start();
        this.#sendWaiting();
      } catch (error) {
        this.#waiting.delete(id);
        reject(error);
      }
    });
  }

  /// Check only the asking workspace's chat and card totals.
  readyChats(viewer: InWorkspace | null = null): Promise<void> {
    if (this.#closed) return Promise.reject(new Error("station stopping"));
    // A session can move after an earlier fill finished. The calling reader saw pending work in its own snapshot.
    this.#complete = false;
    return new Promise((resolve, reject) => {
      const id = ++this.#next;
      try {
        this.#waiting.set(id, { resolve, reject, request: { id, chats: viewer }, sent: false, at: 0 });
        this.start();
        this.#sendWaiting();
      } catch (error) {
        this.#waiting.delete(id);
        reject(error);
      }
    });
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#idle?.();
    this.#idle = null;
    for (const waiting of this.#waiting.values()) waiting.reject(new Error("station stopping"));
    this.#waiting.clear();
    if (this.#worker !== null) this.#termination = this.#worker.terminate();
    this.#worker = null;
    if (this.#termination !== null) await this.#termination;
  }
}
