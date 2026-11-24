// The agents' memory's files and merges in the `--builder memory` program (MoonBit `station/mb/src/memory` by default,
// or Pion `pion/station/packages/memory` via `STILLFAIL_READER_MEMORY=pion` / `STILLFAIL_READER_ENGINE=pion`; shadow
// is strictly forbidden because of filesystem writes), in place of share/memory.ts's own: a workspace's memory read
// and hashed, what changed kept in blobs/, and two versions made apart merged (three-way by lines, or each line once)
// there, none of their bytes on the station's thread; and a skill shared on its own (share/index.ts, a program of its
// own there) read, hashed and written. Started at its first ask, it goes after IDLE_MS with nothing asked of it (or at
// once: `trimIdle`) and is started again by the next: it keeps nothing between asks. There is no TypeScript to fall
// back to: what it replaced is station/test/reference/memory-merge.ts, which station/test/mb-memory-merge.test.ts and
// station/test/reader-contract-memory.test.ts hold it to.
import { sep } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { MbProcess, resolveReaderSelection } from "../read/mb-reader.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";

/// How long a program with nothing asked of it is kept.
export const IDLE_MS = 60_000;

type Json = any;
type Waiting = { resolve: (answer: Json) => void; reject: (error: Error) => void };

/// Detect unpaired UTF-16 surrogates (`\uD800`..`\uDFFF`) in a JSON-serialized string before
/// sending it over stdio so neither MB nor Pion can leave `#waiting` hanging.
function jsonHasLoneSurrogate(json: string): boolean {
  let inStr = false;
  for (let i = 0; i < json.length; i++) {
    const c = json.charCodeAt(i);
    if (!inStr) {
      if (c === 34) inStr = true;
      continue;
    }
    if (c === 34) {
      inStr = false;
    } else if (c === 92) {
      if (i + 1 >= json.length) return false;
      const esc = json.charCodeAt(i + 1);
      if (esc === 117 && i + 5 < json.length) {
        const u = parseInt(json.slice(i + 2, i + 6), 16);
        i += 5;
        if (u >= 0xd800 && u <= 0xdbff) {
          if (i + 6 < json.length && json.charCodeAt(i + 1) === 92 && json.charCodeAt(i + 2) === 117) {
            const lo = parseInt(json.slice(i + 3, i + 7), 16);
            if (lo >= 0xdc00 && lo <= 0xdfff) {
              i += 6;
              continue;
            }
          }
          return true;
        }
        if (u >= 0xdc00 && u <= 0xdfff) return true;
      } else {
        i++;
      }
    }
  }
  return false;
}

/// The program ended while an ask was under way (`close`).
export class MemoryProgramStopped extends Error {}

export class MemoryProgram {
  readonly #binary: string | null;
  readonly #shellDir: string;
  readonly #after: (ms: number, f: () => void) => () => void;
  readonly #readers: (() => ReaderSelectConfig) | undefined;
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
  /// `readers`: live `config.json` `readers` snapshot getter read on each spawn.
  constructor(shellDir: string, options: { binary?: string; after?: (ms: number, f: () => void) => () => void; readers?: () => ReaderSelectConfig } = {}) {
    this.#binary = options.binary ?? null;
    this.#shellDir = shellDir;
    this.#after = options.after ?? wall.after;
    this.#readers = options.readers;
  }

  /// Whether a program runs now.
  get running(): boolean { return this.#process !== null; }

  /// What the program answers `op` with `args` (mb/src/memory answer.mbt); its `error` thrown.
  ask<A = Json>(op: string, args: Record<string, unknown>): Promise<A> {
    if (this.#closed) return Promise.reject(new MemoryProgramStopped("station stopping"));
    const id = ++this.#next;
    let serialized: string;
    try {
      serialized = JSON.stringify({ ...args, id, op }, (_, v) => typeof v === "bigint" ? v.toString() : v);
    } catch (error) {
      return Promise.reject(error as Error);
    }
    if (serialized !== undefined && serialized.includes("\\ud") && jsonHasLoneSurrogate(serialized)) {
      return Promise.reject(new Error("invalid UTF-16 surrogate"));
    }
    return new Promise((resolve, reject) => {
      this.#waiting.set(id, { resolve, reject });
      this.#idle?.();
      this.#idle = null;
      try {
        const child = this.#start();
        child.ref(true);
        child.postLine(serialized);
      } catch (error) {
        this.#waiting.delete(id);
        reject(error as Error);
      }
    });
  }

  #resolveBinary(): string {
    return resolveReaderSelection("memory", {
      binary: this.#binary,
      config: this.#readers,
      logAt: "memory",
    }).primaryBinary;
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
      if (!waiting) {
        if (this.#closed) return;
        log.warn("memory", "the memory's program returned an unmatched response", { id: answer.id ?? null });
        return;
      }
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
