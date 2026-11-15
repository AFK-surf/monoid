// A reader thread: answers reads off the main thread, on a read-only connection of its own (WAL lets readers and the
// one writer go on together), each by the table it is given. What it answers is text, ready to send: no copying the
// value across threads. The station's (worker.ts) answers only what is not the MoonBit program's (read/pool.ts MOVED,
// HISTORY: everything a device asks, and a card's queued pages): a checkpoint. The reads as they were answered here
// before the program took them are the tests' to compare it with (test/reference-worker.ts).
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { parentPort, workerData } from "node:worker_threads";
import type { Lang } from "../ops/i18n.ts";
import type { ReadOp } from "./ops.ts";
import { openStore, usageGroupsBatched, UsageSummaryCache } from "./store.ts";
import { HttpError, setSpoken } from "./views.ts";
import { learn } from "../accounts/catalog.ts";

export type Ask = { id: number; op: string; args: any; lang: Lang; names: [string, string][]; processes: [string, string][]; clientKeys: [string, string][]; catalog?: Record<string, unknown> };
/// `body`: the text as its bytes, as the MoonBit reader gives it (mb-reader.ts `Said`).
export type Answer = { id: number; text?: string; body?: Buffer; status?: number; error?: string; prepareUpJobs?: string; prepareWorkspaceUpJobs?: boolean };
/// Said once, as a reader is ready: how long it took from its first line (its code read in) to its store opened.
export type Ready = { ready: { loadedMs: number; openedMs: number } };

/// How long a checkpoint of a log past its bound waits for the readers and the writer.
const HARD_WAIT_MS = 1000;

/// A read of the station's own, never a device's: answered by its name, outside `ops`.
export type InternalRead = (db: DatabaseSync, args: any) => unknown;

/// Serves the reads of `ops` on this thread, and the station's own: a checkpoint, and those of `internal` (none in the
/// station's: a card's queued pages are the program's, `internalCardEditPage` and `internalCardMessagePage` in
/// read/pool.ts MOVED; the tests' reference worker gives them, to compare the program with).
export function serveReads(ops: Record<string, ReadOp>, internal: Record<string, InternalRead> = {}) {
  const loaded = performance.now();
  const store = openStore(workerData.data as string);
  const usageCache = new UsageSummaryCache();
  parentPort!.postMessage({ ready: { loadedMs: Math.round(loaded), openedMs: Math.round(performance.now() - loaded) } } satisfies Ready);

  /// The connection a checkpoint is made on: one that may write (a read-only one may not), made at the first, and used
  /// for nothing else.
  let writer: DatabaseSync | null = null;

  /// What of the log (the WAL) is not in the database yet, written into it, as far as no reader still reads it (a passive
  /// checkpoint: it waits for no one, and holds up no read or write): the main thread leaves it to the readers (store.ts).
  /// `hard`: the log grew past its bound (a long read held the passive ones back: ops/storage.ts `walCheckpoint`), so
  /// this one waits up to HARD_WAIT_MS for the readers and the writer, and cuts the log's file to nothing once it is all
  /// in (TRUNCATE). The main thread's writes wait on it that long at most, once.
  function checkpoint(hard = false): unknown {
    if (writer === null) {
      writer = new DatabaseSync(join(workerData.data as string, "stillfail.db"), { timeout: 0 });
      writer.exec("PRAGMA synchronous = NORMAL");
    }
    if (!hard) return writer.prepare("PRAGMA wal_checkpoint(PASSIVE)").get();
    writer.exec(`PRAGMA busy_timeout = ${HARD_WAIT_MS}`);
    try {
      return writer.prepare("PRAGMA wal_checkpoint(TRUNCATE)").get();
    } finally {
      writer.exec("PRAGMA busy_timeout = 0");
    }
}

parentPort!.on("message", async (ask: Ask) => {
  let answer: Answer;
  try {
    if (ask.op === "checkpoint") {
      parentPort!.postMessage({ id: ask.id, text: JSON.stringify(checkpoint(ask.args?.hard === true)) } satisfies Answer);
      return;
    }
    setSpoken(ask.lang);
    if (ask.catalog !== undefined) learn(ask.catalog);
    store.names = new Map(ask.names);
    store.processes = new Map(ask.processes);
    store.clientKeys = new Map(ask.clientKeys);
    store.prepareUpJobs = null;
    store.prepareWorkspaceUpJobs = false;
    // Internal queue work is deliberately not in `ops`: the changed-list API must not expose an unscoped card read.
    const own = Object.hasOwn(internal, ask.op) ? internal[ask.op]! : null;
    if (own !== null) {
      store.db.exec("BEGIN");
      let page;
      try { page = own(store.db, ask.args); } finally { store.db.exec("COMMIT"); }
      parentPort!.postMessage({ id: ask.id, text: JSON.stringify(page) } satisfies Answer);
      return;
    }
    const op = ops[ask.op];
    if (!op) throw new HttpError(500, `no read ${ask.op}`);
    // One snapshot for the whole read: its statements see the same database, and what the first of them read in serves
    // the rest. Each statement began on its own before, and as the station writes all the while (each model call, each
    // message), SQLite let go of all this reader held at nearly every one (a connection's pages are dropped whenever the
    // database changed since it last read): each was read again, from the disk while memory was short.
    store.db.exec("BEGIN");
    try {
      // Usage can span many minutes. Read its compact statistics in bounded steps on this same snapshot, resting
      // between them so the cold database does not displace other work's pages all at once.
      const a = ask.args;
      const batched = ask.op === "usage" && a.detailsPreparing !== true
        ? await usageGroupsBatched(store, BigInt(a.from), BigInt(a.to), BigInt(a.tz), a.viewer ?? null, undefined, usageCache,
          a.summaryStrict === true ? a.summaryPrepared === true : undefined) : null;
      answer = { id: ask.id, text: JSON.stringify(op(store, { ...a, ...(batched === null ? {} : { batchedSummary: batched }) })) };
      if (store.prepareUpJobs !== null) answer.prepareUpJobs = store.prepareUpJobs;
      if (store.prepareWorkspaceUpJobs) answer.prepareWorkspaceUpJobs = true;
    } finally {
      store.db.exec("COMMIT");
    }
  } catch (error) {
    answer = { id: ask.id, status: error instanceof HttpError ? error.status : 500, error: (error as Error).message };
  }
  parentPort!.postMessage(answer);
});
}
