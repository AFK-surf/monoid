// Transcripts put away, put away again and written back by the MoonBit program (station/mb src/packed, reader
// `--builder packed`), for sessions/archive.ts: a transcript cut into its segments, compressed, read back and compared
// with what it was by the shell (client/shell `zstd.segments`, `zstd.check`), none of its bytes on the station's thread
// or in its heap (a 150 MB transcript was held there 16 MiB at a time, with its copy and its compressed copy). So is a
// session's workspace: packed into its tar, read back, unpacked and a file read out of it by the shell (`tar.pack`,
// `tar.unpack`, `tar.file`), where the station walked it twice and streamed every block through its heap. The
// station keeps the locks and the renames: the program only makes the temporary it is given and says whether it reads
// back as it must. Started at its first ask, it goes after IDLE_MS with nothing asked of it and is started again by the
// next: it keeps nothing between asks. There is no TypeScript to fall back to: what it replaced is
// station/test/reference/packed.ts, station/test/reference/workspace-archive.ts and the archive's own segmenting of
// before, which station/test/mb-packed.test.ts holds it to.
import { tmpdir } from "node:os";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { MbProcess, type ResolvedReaderSelection, breakerOfSelection, engineOfSelection, fallbackModeOf, resolveReaderSelection } from "../read/mb-reader.ts";
import { readerTelemetry } from "../read/reader-telemetry.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";

/// How long a program with nothing asked of it is kept.
export const IDLE_MS = 60_000;

/// Resolve the binary for `--builder packed` (`mb` by default; `pion` via `STILLFAIL_READER_PACKED` /
/// `config.json` `readers.packed` / `STILLFAIL_READER_ENGINE`; `shadow` is forbidden by
/// `READER_MODES.packed.allowShadow === false`).
function resolvePackedSelection(explicit?: string | null, readers?: () => ReaderSelectConfig): ResolvedReaderSelection {
  return resolveReaderSelection("packed", { binary: explicit, config: readers, logAt: "archive" });
}

type Json = any;
type Waiting = { resolve: (answer: Json) => void; reject: (error: Error) => void; at: number };

/// The program ended while an ask was under way (`close`).
export class PackedProgramStopped extends Error {}

/// A one-shot packed operation (such as `workspace.pack`) was aborted via `AbortSignal`.
export class PackAborted extends Error {}

/// Runs a single `--builder packed` ask in its own process, killed immediately on reply or abort so slow
/// `workspace.pack` runs never block interactive restores/reads on the shared `packedProgram()`.
export function runPackedOnce<A = Json>(
  op: string,
  args: Record<string, unknown>,
  options?: { binary?: string; shellDir?: string; background?: boolean; signal?: AbortSignal; readers?: () => ReaderSelectConfig },
): Promise<A> {
  const signal = options?.signal;
  if (signal?.aborted) return Promise.reject(new PackAborted("workspace packing aborted"));
  return new Promise((resolve, reject) => {
    const startedAt = wall.now();
    const sel = resolvePackedSelection(options?.binary, options?.readers);
    const p = new MbProcess(
      sel.primaryBinary,
      ["--builder", "packed", "--shell-dir", options?.shellDir ?? tmpdir()],
      { background: options?.background, engine: engineOfSelection(sel), mode: "packed-once", fallbackMode: fallbackModeOf(sel.selection, "packed-once"), breaker: breakerOfSelection(sel) },
    );
    let settled = false;
    let aborted = false;
    let exited = false;
    const done = (f: () => void, ok?: boolean) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener("abort", stop);
      if (ok !== undefined) readerTelemetry.recordCall(p.engine, p.mode, wall.now() - startedAt, ok);
      f();
    };
    const finishChild = () => {
      p.ref(false);
      p.kill();
    };
    const stop = () => {
      if (settled || aborted) return;
      aborted = true;
      finishChild();
      // Wait for the child process to exit before rejecting so file handles (e.g. `.writing` on Windows) are released.
      if (exited) done(() => reject(new PackAborted("workspace packing aborted")));
    };
    signal?.addEventListener("abort", stop, { once: true });
    p.on("message", (answer: Json) => {
      if (answer === null || typeof answer !== "object" || Array.isArray(answer)) return;
      if (answer.id !== 1 || aborted) return;
      const ok = typeof answer.error !== "string";
      done(() => {
        finishChild();
        if (!ok) reject(new Error(answer.error));
        else resolve(answer as A);
      }, ok);
    });
    let failure: Error | null = null;
    p.on("error", (error: Error) => {
      failure = error;
      if (aborted) return;
      done(() => {
        finishChild();
        reject(error);
      }, false);
    });
    p.on("exit", (code: number) => {
      exited = true;
      if (aborted) {
        done(() => reject(new PackAborted("workspace packing aborted")));
        return;
      }
      done(() => reject(failure ?? new Error(`the archive's program stopped (exit ${code})`)), false);
    });
    try {
      p.postMessage({ ...args, id: 1, op });
    } catch (error) {
      done(() => {
        finishChild();
        reject(error as Error);
      }, false);
    }
  });
}

export class PackedProgram {
  readonly #binary: string | null;
  readonly #shellDir: string;
  readonly #after: (ms: number, f: () => void) => () => void;
  #readers: (() => ReaderSelectConfig) | undefined;
  #process: MbProcess | null = null;
  #termination: Promise<number> | null = null;
  #next = 0;
  #waiting = new Map<number, Waiting>();
  #idle: (() => void) | null = null;
  #closed = false;
  /// How many processes it started (tests).
  started = 0;

  /// `shellDir`: where the program's shell would keep its own files (it asks for none: the system's temporary
  /// directory by default). `binary`: the program (readerBinary's where none is given). `after`: the timer of IDLE_MS
  /// (a test's own; else the wall's). `readers`: live `config.json` `readers` snapshot getter read on each spawn.
  constructor(options: { binary?: string; shellDir?: string; after?: (ms: number, f: () => void) => () => void; readers?: () => ReaderSelectConfig } = {}) {
    this.#binary = options.binary ?? null;
    this.#shellDir = options.shellDir ?? tmpdir();
    this.#after = options.after ?? wall.after;
    this.#readers = options.readers;
  }

  /// Whether a program runs now.
  get running(): boolean { return this.#process !== null; }

  /// What the program answers `op` with `args` (mb/src/packed answer.mbt); its `error` thrown.
  ask<A = Json>(op: string, args: Record<string, unknown>): Promise<A> {
    if (this.#closed) return Promise.reject(new PackedProgramStopped("station stopping"));
    return new Promise((resolve, reject) => {
      const id = ++this.#next;
      this.#waiting.set(id, { resolve, reject, at: wall.now() });
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
    const sel = resolvePackedSelection(this.#binary, this.#readers);
    const child = new MbProcess(sel.primaryBinary, ["--builder", "packed", "--shell-dir", this.#shellDir], { engine: engineOfSelection(sel), fallbackMode: fallbackModeOf(sel.selection), breaker: breakerOfSelection(sel) });
    this.started++;
    this.#process = child;
    child.on("message", (answer: Json) => {
      if (answer === null || typeof answer !== "object" || Array.isArray(answer)) return;
      const waiting = typeof answer.id === "number" ? this.#waiting.get(answer.id) : undefined;
      if (!waiting) return;
      this.#waiting.delete(answer.id);
      const ok = typeof answer.error !== "string";
      readerTelemetry.recordCall(child.engine, child.mode, wall.now() - waiting.at, ok);
      if (!ok) waiting.reject(new Error(answer.error));
      else waiting.resolve(answer);
      this.#idleLater();
    });
    let failure: Error | null = null;
    child.on("error", (error: Error) => {
      failure = error;
      log.error("archive", "the archive's program stopped", { engine: child.engine, mode: child.mode, error: error.message });
    });
    child.on("exit", (code: number) => {
      if (this.#process !== child) return;
      this.#process = null;
      this.#idle?.();
      this.#idle = null;
      const error = this.#closed ? new PackedProgramStopped("station stopping") : (failure ?? new Error(`the archive's program stopped (exit ${code})`));
      const now = wall.now();
      for (const waiting of this.#waiting.values()) {
        if (!this.#closed) readerTelemetry.recordCall(child.engine, child.mode, now - waiting.at, false);
        waiting.reject(error);
      }
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
    // (waited for by the process as it ends: not left behind it)
    child.ref(true);
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
    for (const waiting of this.#waiting.values()) waiting.reject(new PackedProgramStopped("station stopping"));
    this.#waiting.clear();
    if (child !== null) this.#termination = child.terminate();
    if (this.#termination !== null) await this.#termination;
  }
}

let shared: PackedProgram | null = null;

/// The one program the archive asks, made at its first ask. A process that comes to its end by itself (a command, a
/// test's file) lets it go first, rather than leave it to find its stdin closed after: each time its loop runs out, not
/// only the first (a test's file ran out between two tests, its program started again after and left running at its
/// end; an idle program's process is let go of the loop).
export function packedProgram(): PackedProgram {
  if (shared === null) {
    const program = new PackedProgram();
    shared = program;
    process.on("beforeExit", () => void program.trimIdle());
  }
  return shared;
}

/// The one program the archive asks, if it was made (what the station's memory lets go, and its end, reach).
export function peekPackedProgram(): PackedProgram | null {
  return shared;
}
