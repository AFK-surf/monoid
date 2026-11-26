// Copies the jobs an old store had into job_ends (station/src/store/job-ends.ts) in bounded steps once the station
// before has let go of the database, sharing the single backfill permit with the other backfills.
import { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { BACKFILL_PAUSE_MS, giveBackfill, takeBackfill } from "../store/backfill.ts";
import { jobEndsNeedsWork, jobEndsStep } from "../store/job-ends.ts";
import type { Store } from "../store/store.ts";

let nextOwner = 0x59000000;

const busy = (error: unknown) => /SQLITE_BUSY|database is locked/i.test(
  `${(error as { code?: string; errstr?: string })?.code ?? ""} ${(error as Error)?.message ?? ""} ${(error as { errstr?: string })?.errstr ?? ""}`);

/// One step on the station's own connection, waiting for no lock: one held elsewhere is SQLITE_BUSY, asked again later.
function stepNow(store: Store): boolean {
  const timeout = Number((store.db.prepare("PRAGMA busy_timeout").get() as { timeout: number }).timeout);
  store.db.exec("PRAGMA busy_timeout = 0");
  try { return jobEndsStep(store.db); } finally { store.db.exec(`PRAGMA busy_timeout = ${timeout}`); }
}

export function buildJobEndsBackfill(store: Store, previous: Promise<void>): {
  ready: Promise<boolean>;
  close: () => Promise<void>;
} {
  const ready = Promise.withResolvers<boolean>();
  const timers = new Fibers("job ends backfill", store.clock);
  const priority = store.backfillPriority instanceof SharedArrayBuffer ? new Int32Array(store.backfillPriority) : null;
  const owner = nextOwner++;
  let closed = false;
  let cancel: (() => void) | null = null;

  const schedule = () => {
    if (closed || cancel !== null) return;
    cancel = timers.after(BACKFILL_PAUSE_MS, () => {
      cancel = null;
      step();
    });
  };

  const step = () => {
    if (closed) return;
    if (!takeBackfill(priority, owner)) {
      schedule();
      return;
    }
    let done = false;
    try {
      done = stepNow(store);
    } catch (error) {
      if (!busy(error)) {
        log.warn("jobs", "job ends backfill batch failed", { error: (error as Error).message });
        ready.resolve(false);
        return;
      }
    } finally {
      giveBackfill(priority, owner);
    }
    if (done) ready.resolve(true);
    else schedule();
  };

  void previous.then(() => {
    if (closed) return;
    try {
      if (!jobEndsNeedsWork(store.db)) {
        ready.resolve(true);
        return;
      }
    } catch (error) {
      log.warn("jobs", "could not start job ends backfill", { error: (error as Error).message });
      ready.resolve(false);
      return;
    }
    step();
  }, (error) => {
    log.warn("jobs", "could not start job ends backfill", { error: (error as Error).message });
    ready.resolve(false);
  });

  return {
    ready: ready.promise,
    close: async () => {
      if (closed) return;
      closed = true;
      cancel?.();
      cancel = null;
      ready.resolve(false);
      await timers.close();
    },
  };
}
