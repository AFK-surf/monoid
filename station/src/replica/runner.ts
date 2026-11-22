// Where the export's work runs: a process of its own as the station runs (the MoonBit program, station/mb's
// src/replica), so none of its reads, hashing, compressing or writing is on the main thread; the TypeScript it is held
// to line by line in the test's thread in tests (test/reference/replica-work.ts `InlineRunner`).
import { sep } from "node:path";
import { wall } from "../ops/fibers.ts";
import { MbProcess, readerBinary } from "../read/mb-reader.ts";
import type { Passed, Places, Told } from "./export.ts";

/// A pass, and whether the station has no chat of its own (a copy is taken back only into such a one).
export type WorkPassed = Passed & { empty: boolean };

export type Asked =
  | { type: "places"; places: Places }
  | { type: "pass"; told: Told }
  | { type: "newGenerations"; after: number }
  | { type: "sources"; hashes: string[] }
  | { type: "close" };

export interface Runner {
  places(places: Places): Promise<void>;
  pass(told: Told): Promise<WorkPassed>;
  newGenerations(after: number): Promise<void>;
  sources(hashes: string[]): Promise<Record<string, string>>;
  close(): Promise<void>;
}

export type RunnerOptions = { db: string; replica: string; dataDir: string; origin: string; chunkBytes?: number };

/// What the work runs in: the MoonBit program's process, or a test's own, asked and answering a message each,
/// `{id, answer}` or `{id, error}`.
type Thread = {
  on(event: "message", f: (m: { id: number; answer?: unknown; error?: string }) => void): unknown;
  on(event: "error", f: (e: Error) => void): unknown;
  on(event: "exit", f: (code: number) => void): unknown;
  postMessage(m: unknown): void;
};

/// The work in the MoonBit program (`--builder replica-export`).
export function exportThread(o: RunnerOptions): Thread {
  const args = ["--builder", "replica-export", "--db", o.db, "--replica", o.replica, "--data-dir", o.dataDir, "--origin", o.origin, "--sep", sep];
  if (o.chunkBytes !== undefined) args.push("--chunk-bytes", String(o.chunkBytes));
  return new MbProcess(readerBinary(), args);
}

/// The work in a process of its own, started again (told the workspaces again) at the next thing asked once
/// it ended: what asked meanwhile failed, and its caller tries again with a backoff (copies.ts `#pass`). Each ask says
/// the time (`now`): the program's clock is the station's.
export class ProgramRunner implements Runner {
  readonly #o: RunnerOptions;
  readonly #start: (o: RunnerOptions) => Thread;
  #worker: Thread | null = null;
  readonly #waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  #next = 0;
  #places: Places | null = null;
  #closed = false;

  constructor(o: RunnerOptions, start: (o: RunnerOptions) => Thread = exportThread) {
    this.#o = o;
    this.#start = start;
  }

  #begin(): Thread {
    const worker = this.#start(this.#o);
    worker.on("message", (m: { id: number; answer?: unknown; error?: string }) => {
      const w = this.#waiting.get(m.id);
      this.#waiting.delete(m.id);
      if (m.error !== undefined) w?.reject(new Error(m.error));
      else w?.resolve(m.answer);
    });
    const fail = (e: Error) => {
      if (this.#worker !== worker) return;
      this.#worker = null;
      for (const w of this.#waiting.values()) w.reject(e);
      this.#waiting.clear();
    };
    worker.on("error", (e) => fail(new Error(`the copies' thread failed: ${e.message}`)));
    worker.on("exit", (code) => fail(new Error(`the copies' thread ended (${code})`)));
    this.#worker = worker;
    if (this.#places !== null) worker.postMessage({ type: "places", places: this.#places, id: ++this.#next, now: wall.now() });
    return worker;
  }

  #ask<T>(m: Asked): Promise<T> {
    if (this.#closed) return Promise.reject(new Error("the copies' thread is closed"));
    const worker = this.#worker ?? this.#begin();
    const id = ++this.#next;
    return new Promise<T>((resolve, reject) => {
      this.#waiting.set(id, { resolve, reject });
      worker.postMessage({ ...m, id, now: wall.now() });
    });
  }

  places(places: Places) {
    this.#places = places;
    return this.#ask<void>({ type: "places", places });
  }
  pass(told: Told) {
    return this.#ask<WorkPassed>({ type: "pass", told });
  }
  newGenerations(after: number) {
    return this.#ask<void>({ type: "newGenerations", after });
  }
  sources(hashes: string[]) {
    return this.#ask<Record<string, string>>({ type: "sources", hashes });
  }
  async close() {
    if (this.#worker === null) {
      this.#closed = true;
      return;
    }
    await this.#ask<void>({ type: "close" }).catch(() => {});
    this.#closed = true;
  }
}
