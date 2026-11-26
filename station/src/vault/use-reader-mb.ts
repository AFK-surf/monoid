// The vault's use reader by the MoonBit program (station/mb, src/vaultuses), in the place of the thread of before
// (test/workers/use-index-worker.ts): the same queue and pacing, here on the station's thread, each read, preparation step and background batch asked of the
// program (`--builder vault-uses`), which knows nothing of the backfill permit: it is taken here around each write.
import { EventEmitter } from "node:events";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { MbProcess, type ResolvedReaderSelection, breakerOfSelection, engineOfSelection, fallbackModeOf } from "../read/mb-reader.ts";
import { readerTelemetry } from "../read/reader-telemetry.ts";
import { BACKFILL_PAUSE_MS, REQUEST_BACKFILL_PAUSE_MS, giveBackfill, takeBackfill } from "../store/backfill.ts";
import type { PendingPrepare, UseAnswer, UseRead } from "./use-index.ts";

/// What stands for this reader in the permit (a worker's thread id there): never a thread's.
let nextOwner = 0x70000000;

type Reply = { answered?: UseAnswer; unready?: true; complete?: boolean; bodies?: string[]; done?: boolean; busy?: true; error?: string };

export class MbUseReader extends EventEmitter {
  readonly threadId = nextOwner++;
  readonly #process: MbProcess;
  readonly #priority: Int32Array | null;
  readonly #replies: { resolve: (reply: Reply) => void; at: number }[] = [];
  readonly #waiting: (UseRead | PendingPrepare)[] = [];
  #backgroundComplete = false;
  #reboxComplete = false;
  #reboxTurn = true;
  #scheduled = false;
  #foregroundWaiting = false;
  #stepping = false;
  #exited = false;
  #terminated = false;

  /// `known`: what of the background an earlier one of these found done (`settled`), not asked again: one let go
  /// while idle (use-index.ts `trimIdle`) is followed by another, which goes on where the database says (its progress
  /// is kept there), or not at all where it was done or given up.
  constructor(binary: string | ResolvedReaderSelection, path: string, priority: SharedArrayBuffer | undefined, known: { uses?: boolean; rebox?: boolean } = {}) {
    super();
    this.#backgroundComplete = known.uses === true;
    this.#reboxComplete = known.rebox === true;
    this.#priority = priority instanceof SharedArrayBuffer ? new Int32Array(priority) : null;
    const bin = typeof binary === "string" ? binary : binary.primaryBinary;
    const opts = typeof binary === "string" ? undefined : { engine: engineOfSelection(binary), fallbackMode: fallbackModeOf(binary.selection), breaker: breakerOfSelection(binary) };
    this.#process = new MbProcess(bin, ["--builder", "vault-uses", "--db", path], opts);
    this.#process.on("message", (reply: Reply) => {
      const entry = this.#replies.shift();
      if (entry === undefined) return;
      readerTelemetry.recordCall(this.#process.engine, this.#process.mode, wall.now() - entry.at, reply.error === undefined);
      entry.resolve(reply);
    });
    this.#process.on("error", (error) => this.emit("error", error));
    this.#process.on("exit", (code) => {
      this.#exited = true;
      const now = wall.now();
      for (const entry of this.#replies.splice(0)) {
        if (!this.#terminated) readerTelemetry.recordCall(this.#process.engine, this.#process.mode, now - entry.at, false);
        entry.resolve({ error: `the vault use program stopped (exit ${code})` });
      }
      this.emit("exit", code);
    });
    this.#schedule();
  }

  #ask(op: string, q?: UseRead | PendingPrepare): Promise<Reply> {
    if (this.#exited) return Promise.resolve({ error: "the vault use program stopped" });
    const at = wall.now();
    return new Promise((resolve) => { this.#replies.push({ resolve, at }); this.#process.postMessage({ op, ...(q ? { q } : {}) }); });
  }

  /// A ready answer is a read: no permit, no pause.
  async #answerIfReady(q: UseRead | PendingPrepare): Promise<"answered" | "unready" | "busy"> {
    const reply = await this.#ask("ready", q);
    if (reply.busy) return "busy";
    if (reply.error !== undefined) { this.emit("message", { id: q.id, error: reply.error } satisfies UseAnswer); return "answered"; }
    if (reply.answered === undefined) return "unready";
    this.emit("message", reply.answered);
    return "answered";
  }

  #more(): boolean { return this.#waiting.length > 0 || !this.#backgroundComplete || !this.#reboxComplete; }

  /// What of the background is done (or given up), for the one that follows this (`known`).
  get settled(): { uses: boolean; rebox: boolean } { return { uses: this.#backgroundComplete, rebox: this.#reboxComplete }; }

  /// Nothing asked of it, nothing of the background left, and no step under way (so no permit held): it may be let go.
  /// Told as `idle` once a step leaves it so.
  idle(): boolean {
    return !this.#exited && !this.#scheduled && !this.#stepping && this.#replies.length === 0 && !this.#more();
  }
  #pause(): number { return this.#waiting.length > 1 ? REQUEST_BACKFILL_PAUSE_MS : BACKFILL_PAUSE_MS; }

  #schedule(delay = 0) {
    if (this.#scheduled || this.#exited) return;
    this.#scheduled = true;
    const run = () => {
      this.#stepping = true;
      void this.#step().catch((error) => log.error("vault", "the use reader stopped", { error: (error as Error).message }))
        .finally(() => { this.#stepping = false; if (this.idle()) this.emit("idle"); });
    };
    if (delay > 0) wall.after(delay, run);
    else setImmediate(run);
  }

  async #step(): Promise<void> {
    this.#scheduled = false;
    if (this.#exited) return;
    const q = this.#waiting.shift();
    if (q) {
      const answer = await this.#answerIfReady(q);
      if (answer === "answered") {
        if (this.#more()) this.#schedule(this.#waiting.length ? REQUEST_BACKFILL_PAUSE_MS : BACKFILL_PAUSE_MS);
        return;
      }
      if (answer === "busy") {
        this.#waiting.push(q);
        this.#schedule(this.#pause());
        return;
      }
    }
    if (!takeBackfill(this.#priority, this.threadId)) {
      if (q) this.#waiting.push(q);
      if (!this.#foregroundWaiting && this.#priority !== null && Atomics.load(this.#priority, 0) !== 0) {
        this.#foregroundWaiting = true;
        this.emit("message", { foreground: true, request: q?.id });
      }
      this.#schedule(this.#pause());
      return;
    }
    this.#foregroundWaiting = false;
    try {
      if (q) {
        const reply = await this.#ask("prepare", q);
        if (reply.busy) { this.#waiting.push(q); this.#schedule(this.#pause()); return; }
        if (reply.error !== undefined) this.emit("message", { id: q.id, error: reply.error } satisfies UseAnswer);
        else if (!reply.complete) this.#waiting.push(q); // (other workspaces get a turn between this one's batches)
        else if ("kind" in q) this.emit("message", { id: q.id, ready: true } satisfies UseAnswer);
        else this.emit("message", { id: q.id, bodies: reply.bodies ?? [] } satisfies UseAnswer);
      } else if (!this.#reboxComplete && (this.#backgroundComplete || this.#reboxTurn)) {
        const reply = await this.#ask("rebox");
        if (reply.busy) { this.#schedule(this.#pause()); return; }
        if (reply.error !== undefined) {
          log.error("vault", "the recovery index backfill stopped", { error: reply.error });
          this.#reboxComplete = true;
        } else { this.#reboxComplete = reply.done === true; this.#reboxTurn = false; }
      } else if (!this.#backgroundComplete) {
        const reply = await this.#ask("uses");
        if (reply.busy) { this.#schedule(this.#pause()); return; }
        if (reply.error !== undefined) {
          // (a broken old request must not keep another workspace's prepared page from being read)
          log.error("vault", "the use history backfill stopped", { error: reply.error });
          this.#backgroundComplete = true;
        } else { this.#backgroundComplete = reply.done === true; this.#reboxTurn = true; }
      }
    } finally { giveBackfill(this.#priority, this.threadId); }
    if (this.#more()) this.#schedule(this.#waiting.length ? REQUEST_BACKFILL_PAUSE_MS : BACKFILL_PAUSE_MS);
  }

  postMessage(q: UseRead | PendingPrepare) {
    this.#foregroundWaiting = false;
    // (a ready read is served without disturbing the background's pacing)
    void this.#answerIfReady(q).then((answer) => {
      if (answer === "answered") return;
      this.#waiting.push(q);
      this.#schedule();
    });
  }

  unref() {}

  terminate(): Promise<number> {
    this.#terminated = true;
    return this.#process.terminate();
  }
}
