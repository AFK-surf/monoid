// How a thread made the usage statistics' workspace moves and totals before the MoonBit program (`--builder
// usage-scope`) took them: one bounded batch at a time, what the program is compared with (test/mb-usage-scope.test.ts).
import { DatabaseSync } from "node:sqlite";
import { parentPort, threadId, workerData } from "node:worker_threads";
import { wall } from "../../src/ops/fibers.ts";
import { giveBackfill, takeBackfill } from "../../src/store/backfill.ts";
import { compactTotalsStep, hasCompactUsage, moveCompactStep } from "../../src/store/usage-compact.ts";
import { hasUsageSummaryBlocks, usageSummaryBlocksPending, usageSummaryBlocksStep, type UsageSummaryKey, type UsageSummaryRange } from "../../src/store/usage-summary-blocks.ts";

const db = new DatabaseSync(workerData.path as string);
const priority = new Int32Array(workerData.priority as SharedArrayBuffer);
db.exec("PRAGMA busy_timeout = 250; PRAGMA synchronous = NORMAL");

parentPort!.on("message", async (message: { wake?: boolean; scope?: string; range?: UsageSummaryRange }) => {
  if (!message.wake) return;
  const scope = message.scope;
  const range = message.range;
  let result: { done: boolean; session?: string; sessions?: string[]; from?: number; after?: UsageSummaryKey; converted?: boolean; error?: string } = { done: true };
  try {
    if (range !== undefined && (!hasCompactUsage(db) || !hasUsageSummaryBlocks(db))) throw new Error("usage summary statistics are not installed");
    if (hasCompactUsage(db)) {
      const all = scope === undefined || scope === "G";
      const moving = all ? db.prepare("SELECT 1 FROM usage_compact_moving LIMIT 1").get()
        : db.prepare("SELECT 1 FROM usage_compact_moving_scope WHERE scope = ? LIMIT 1").get(scope);
      const pending = scope === undefined ? undefined : all
        ? db.prepare("SELECT 1 FROM usage_compact INDEXED BY usage_compact_pending_session WHERE pending = 1 LIMIT 1").get()
        : db.prepare("SELECT 1 FROM usage_compact INDEXED BY usage_compact_pending_scope WHERE pending = 1 AND scope = ? LIMIT 1").get(scope);
      const blocksInstalled = hasUsageSummaryBlocks(db);
      const blocksPending = blocksInstalled && usageSummaryBlocksPending(db, all ? undefined : scope, range);
      if (moving !== undefined || pending !== undefined || blocksPending) {
        if (!takeBackfill(priority, threadId)) result = { done: false };
        else {
          try {
            if (moving !== undefined) {
              result = moveCompactStep(db, 256, all ? undefined : scope);
              if (range !== undefined && result.done) result.done = false;
            }
            else if (range !== undefined && blocksPending) {
              const blocks = usageSummaryBlocksStep(db, 32, all ? undefined : scope, range);
              result = { done: blocks.done, ...(blocks.after ? { after: blocks.after } : {}), ...(blocks.converted ? { converted: true } : {}) };
            } else if (range !== undefined) result = { done: true };
            else if (pending !== undefined) result = compactTotalsStep(db, 256, all ? undefined : scope);
            else {
              const blocks = usageSummaryBlocksStep(db, 32, all ? undefined : scope);
              result = { done: blocks.done };
            }
            if (result.done && range === undefined && blocksInstalled && usageSummaryBlocksPending(db, all ? undefined : scope)) {
              result.done = false;
            }
          } catch (error) {
            const code = (error as { errcode?: number }).errcode;
            if (code === undefined || ![5, 6].includes(code & 255)) throw error;
            result = { done: false };
          } finally { giveBackfill(priority, threadId); }
        }
      }
    }
  } catch (error) {
    result = { done: false, error: (error as Error).message };
  }
  // Leave a gap for foreground work and other requested scopes between batches.
  if (!result.done && !result.error) await wall.sleep(20);
  parentPort!.postMessage(result);
});
