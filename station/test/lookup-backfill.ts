// The orchestration tests decide when handover and probes happen. The decision batches themselves are held to the
// real MoonBit program in mb-legacy-ids.test.ts; no child process or real-clock pause runs in this test worker.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { Store } from "../src/store/store.ts";
import { decisionSessionIndexStep, decisionSessionRepairStep } from "./reference/backfill/legacy-decision-session.ts";
import { decisionTimeIndexStep } from "./reference/backfill/legacy-decision-time.ts";

export function lookupWorker(store: Store) {
  let next = 0;
  const steps = {
    "legacy-decision-time": decisionTimeIndexStep,
    "legacy-decision-session": decisionSessionIndexStep,
    "legacy-decision-session-repair": decisionSessionRepairStep,
  };
  class Worker extends EventEmitter {
    readonly threadId = ++next;
    closed = false;
    postMessage(message: unknown) {
      const kind = (message as { kind: keyof typeof steps }).kind;
      assert.ok(Object.hasOwn(steps, kind), `unexpected lookup kind: ${kind}`);
      queueMicrotask(() => {
        if (this.closed) return;
        try { this.emit("message", steps[kind](store.db)); }
        catch (error) { this.emit("error", error); void this.terminate(); }
      });
    }
    unref() {}
    async terminate() {
      if (!this.closed) { this.closed = true; this.emit("exit", 0); }
      return 0;
    }
  }
  return () => new Worker();
}
