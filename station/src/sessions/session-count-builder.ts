import { MbBackfill, resolveReaderSelection } from "../read/mb-reader.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { releaseStoppedBackfill } from "../store/backfill.ts";
import { sessionCountsReady } from "../store/session-counts.ts";
import type { Store } from "../store/store.ts";

/// Wait for the previous station before reading old rows; a stopped builder resumes at its committed cursor. By the
/// MoonBit builder (station/mb, src/counts; `binary`: the program, a test's own where it gives one).
export function buildSessionCounts(
  store: Store,
  previous: Promise<void>,
  binary?: string,
  readers?: () => ReaderSelectConfig,
): { ready: Promise<boolean>; close: () => Promise<void> } {
  const { promise: ready, resolve } = Promise.withResolvers<boolean>();
  const path = store.db.location();
  const retries = new Fibers("session counts", store.clock);
  let worker: MbBackfill | null = null;
  let cancel: (() => void) | null = null;
  let closed = false, complete = false, retryMs = 250;
  const finish = () => { if (!complete && !closed) { complete = true; resolve(true); } };
  const retry = () => {
    if (closed || complete || cancel !== null) return;
    const ms = retryMs;
    retryMs = Math.min(retryMs * 2, 30_000);
    cancel = retries.after(ms, () => { cancel = null; start(); });
  };
  const start = () => {
    if (closed || complete || worker !== null) return;
    if (path === null) {
      log.warn("hub", "the session count backfill requires a file-backed store");
      resolve(false);
      return;
    }
    let current: MbBackfill;
    try {
      const bin = resolveReaderSelection("session-counts", { binary, config: readers, logAt: "readers" });
      current = new MbBackfill(bin, ["--builder", "session-counts", "--db", path], store.backfillPriority, 20);
    }
    catch (error) {
      log.warn("hub", "the session count worker could not start", { error: (error as Error).message });
      retry();
      return;
    }
    const owner = current.threadId;
    worker = current;
    current.unref();
    current.on("message", (result: { done: boolean; error?: string }) => {
      if (closed || worker !== current) return;
      if (result.error) {
        log.warn("hub", "a session count batch stopped", { error: result.error });
        void current.terminate();
      } else if (result.done) {
        finish();
        void current.terminate();
      } else {
        retryMs = 250;
        current.postMessage({});
      }
    });
    current.once("error", (error) => log.warn("hub", "the session count worker failed", { error: error.message }));
    current.once("exit", () => {
      releaseStoppedBackfill(store.backfillPriority, owner);
      if (worker === current) worker = null;
      retry();
    });
    current.postMessage({});
  };
  if (sessionCountsReady(store.db)) finish();
  else void previous.then(start).catch((error) => log.warn("hub", "could not start the session count worker", { error: (error as Error).message }));
  return {
    ready,
    close: async () => {
      if (closed) return;
      closed = true;
      resolve(false);
      cancel?.();
      await retries.close();
      if (worker !== null) await worker.terminate();
    },
  };
}
