// The agents' memory's files and merges in the MoonBit program (station/mb src/memory, reader `--builder memory`), in
// place of share/memory.ts's own: a workspace's memory read and hashed, what changed kept in blobs/, and two versions
// made apart merged (three-way by lines, or each line once) there, none of their bytes on the station's thread; and a
// skill shared on its own (share/index.ts, a program of its own there) read, hashed and written. Started
// at its first ask, it goes after IDLE_MS with nothing asked of it (or at once: `trimIdle`) and is started again by the
// next: it keeps nothing between asks. There is no TypeScript to fall back to: what it replaced is
// station/test/reference/memory-merge.ts, which station/test/mb-memory-merge.test.ts holds it to.
import { sep } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { MbProcess, pionBinary, readerBinary } from "../read/mb-reader.ts";
import { resolveReaderEngine } from "../read/reader-select.ts";

/// How long a program with nothing asked of it is kept.
export const IDLE_MS = 60_000;

const warnedReaderFallbacks = new Set<string>();

type Json = any;
type Waiting = { resolve: (answer: Json) => void; reject: (error: Error) => void };

/// The program ended while an ask was under way (`close`).
export class MemoryProgramStopped extends Error {}

export class MemoryProgram {
  readonly #binary: string | null;
  readonly #shellDir: string;
  readonly #after: (ms: number, f: () => void) => () => void;
  #process: MbProcess | null = null;
  #termination: Promise<number> | null = null;
  #next = 0;
  #waiting = new Map<number, Waiting>();
  #idle: (() => void) | null = null;
  #closed = false;
  /// How many processes it started (tests).
  started = 0;

  /// `shellDir`: where the program's shell keeps its own files (the memory's directory). `binary`: the program
  /// (readerBinary's where none is given). `after`: the timer of IDLE_MS (a test's own; else the wall's).
  constructor(shellDir: string, options: { binary?: string; after?: (ms: number, f: () => void) => () => void } = {}) {
    this.#binary = options.binary ?? null;
    this.#shellDir = shellDir;
    this.#after = options.after ?? wall.after;
  }

  /// Whether a program runs now.
  get running(): boolean { return this.#process !== null; }

  /// What the program answers `op` with `args` (mb/src/memory answer.mbt); its `error` thrown.
  ask<A = Json>(op: string, args: Record<string, unknown>): Promise<A> {
    if (this.#closed) return Promise.reject(new MemoryProgramStopped("station stopping"));
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

  #resolveBinary(): string {
    if (this.#binary !== null) return this.#binary;
    // Probe engine intent first without touching disk (`pionBinary()`) so default `mb` does zero main-thread statSync.
    // `memory` has write-fs side effects (`allowShadow: false`), so shadow is never executed.
    const probe = resolveReaderEngine("memory", { hasPionBinary: true });
    const pionBin = probe.engine === "pion" ? pionBinary() : null;
    const selection = probe.engine === "pion"
      ? resolveReaderEngine("memory", { hasPionBinary: pionBin !== null })
      : probe;
    if (selection.fallback) {
      const dedupKey = `${selection.mode}:${selection.source}:${selection.reason ?? "unknown"}`;
      if (!warnedReaderFallbacks.has(dedupKey)) {
        warnedReaderFallbacks.add(dedupKey);
        log.warn("memory", "reader engine fallback", {
          mode: selection.mode,
          engine: selection.engine,
          requested: selection.requested,
          source: selection.source,
          reason: selection.reason,
          detail: selection.detail,
        });
      }
    }
    if (selection.engine === "pion" && pionBin !== null) return pionBin;
    return readerBinary();
  }

  #start(): MbProcess {
    if (this.#process !== null) return this.#process;
    const child = new MbProcess(this.#resolveBinary(), ["--builder", "memory", "--sep", sep, "--shell-dir", this.#shellDir]);
    this.started++;
    this.#process = child;
    child.on("message", (answer: Json) => {
      if (answer === null || typeof answer !== "object" || Array.isArray(answer)) {
        log.warn("memory", "the memory's program returned a malformed response");
        return;
      }
      const waiting = typeof answer.id === "number" ? this.#waiting.get(answer.id) : undefined;
      if (!waiting) return;
      this.#waiting.delete(answer.id);
      if (typeof answer.error === "string") waiting.reject(new Error(answer.error));
      else if (answer.error !== undefined) waiting.reject(new Error("the memory's program returned a malformed error"));
      else waiting.resolve(answer);
      this.#idleLater();
    });
    let failure: Error | null = null;
    child.on("error", (error: Error) => {
      failure = error;
      log.error("memory", "the memory's program stopped", { error: error.message });
    });
    child.on("exit", (code: number) => {
      if (this.#process !== child) return;
      this.#process = null;
      this.#idle?.();
      this.#idle = null;
      const error = this.#closed ? new MemoryProgramStopped("station stopping") : (failure ?? new Error(`the memory's program stopped (exit ${code})`));
      for (const waiting of this.#waiting.values()) waiting.reject(error);
      this.#waiting.clear();
    });
    return child;
  }

  /// Nothing asked of it: it goes after IDLE_MS unless asked again (and holds the station's process up meanwhile no
  /// longer).
  #idleLater(): void {
    if (this.#closed || this.#process === null || this.#waiting.size > 0 || this.#idle !== null) return;
    this.#process.ref(false);
    // timer: a deadline (an idle program's process let go)
    this.#idle = this.#after(IDLE_MS, () => {
      this.#idle = null;
      if (this.#waiting.size === 0) this.#letGo();
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
    if (this.#closed || this.#process === null || this.#waiting.size > 0) return 0;
    this.#letGo();
    return 1;
  }

  /// Its end: an ask under way is failed (what it wrote stays).
  async close(): Promise<void> {
    this.#closed = true;
    this.#idle?.();
    this.#idle = null;
    const child = this.#process;
    this.#process = null;
    for (const waiting of this.#waiting.values()) waiting.reject(new MemoryProgramStopped("station stopping"));
    this.#waiting.clear();
    if (child !== null) this.#termination = child.terminate();
    if (this.#termination !== null) await this.#termination;
  }
}
