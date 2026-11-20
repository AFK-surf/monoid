// Background backfill for conversations (§3.2): settles every thread with a `scope = 'thread' AND conv IS NULL`
// session, sharing the single backfill permit with other backfills. Because the condition is data rather than a
// one-time cursor, sessions created during a downgrade or imported from an older station are picked up after upgrade.
import { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { BACKFILL_PAUSE_MS, giveBackfill, takeBackfill } from "../store/backfill.ts";
import { birthThreadsOf, isOwnedWs } from "../store/conversations.ts";
import type { Store } from "../store/store.ts";

let nextOwner = 0x58000000;

/// Settles up to `limit` sessions with `scope = 'thread' AND conv IS NULL` after cursor `after`,
/// using the partial index `sessions_conv_todo`. Lone/orphaned sessions get `conv = key` so the backfill converges.
export function backfillConversationsStep(
  store: Store,
  after: string,
  settledThreads: Set<number>,
  limit = 32,
): { after: string | null; done: boolean } {
  const rows = store.db.prepare(
    "SELECT key, ws FROM sessions INDEXED BY sessions_conv_todo WHERE scope = 'thread' AND conv IS NULL AND key > ? ORDER BY key LIMIT ?",
  ).all(after, limit) as { key: string; ws: string | null }[];
  for (const r of rows) {
    if (!isOwnedWs(r.ws)) continue;
    for (const tid of birthThreadsOf(store.db, r.key)) {
      if (settledThreads.has(tid)) continue;
      settledThreads.add(tid);
      store.settleConversation(tid);
    }
    store.db.prepare("UPDATE sessions SET conv = key WHERE key = ? AND conv IS NULL").run(r.key);
  }
  if (rows.length < limit) return { after: null, done: true };
  return { after: rows[rows.length - 1]!.key, done: false };
}

/// Runs the conversation backfill in bounded batches once `previous` handover finishes, sharing `store.backfillPriority`.
export function buildConversationBackfill(store: Store, previous: Promise<void>): {
  ready: Promise<boolean>;
  close: () => Promise<void>;
} {
  const ready = Promise.withResolvers<boolean>();
  const timers = new Fibers("conversation backfill", store.clock);
  const priority = store.backfillPriority instanceof SharedArrayBuffer ? new Int32Array(store.backfillPriority) : null;
  const owner = nextOwner++;
  const settledThreads = new Set<number>();
  let after = "";
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
      const res = backfillConversationsStep(store, after, settledThreads);
      done = res.done;
      if (res.after !== null) after = res.after;
    } catch (error) {
      log.warn("hub", "conversation backfill batch failed", { error: (error as Error).message });
      done = true;
    } finally {
      giveBackfill(priority, owner);
    }
    if (done) ready.resolve(true);
    else schedule();
  };

  void previous.then(() => {
    if (!closed) step();
  }, (error) => {
    log.warn("hub", "could not start conversation backfill", { error: (error as Error).message });
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
