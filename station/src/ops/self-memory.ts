// The station's watch over its own memory: this Node process and the MoonBit programs it runs (read/mb-reader.ts
// MbProcess.live: the readers, the serving programs, the builders), which the watch over the agents' processes leaves
// out (jobs/memory.ts: the station and the runners are never units). Sampled every SAMPLE_MS (a sample of this machine).
//
// - Soft: the machine under pressure (high, critical), or the station's whole (Node's resident memory and its programs')
//   past softLimitOf: what answers nothing is let go at once (Readers.trimIdle), at most once a RELIEF_MS. Nothing that
//   answers is stopped.
// - Hard: Node itself past hardRssOf or HEAP_MOST in SUSTAINED samples in a row (a leak, not a transfer's or a pack's
//   moment), STARTUP_MS after it started: its launcher asked to hand over (ops/restart.ts `restarter`), as an update
//   does, once, the next process taking the sessions up. Never an exit: where there is no launcher (a checkout, a
//   test) it is only said, and what is idle let go.
import type { Clock } from "effect";
import type { Pressure } from "../jobs/admit.ts";
import { Fibers } from "./fibers.ts";
import { log } from "./log.ts";

const MiB = 1024 ** 2;
const GiB = 1024 ** 3;
export const SAMPLE_MS = 30_000;
export const RELIEF_MS = 60_000;
export const SUSTAINED = 3;
export const STARTUP_MS = 10 * 60_000;
export const HEAP_MOST = 2.5 * GiB;

const clamp = (n: number, low: number, high: number) => Math.min(high, Math.max(low, n));
/// The station's whole past which what is idle is let go: a fifth of the machine's memory, 2 to 6 GiB.
export const softLimitOf = (totalBytes: number): number => clamp(Math.floor(totalBytes * 0.2), 2 * GiB, 6 * GiB);
/// Node's own resident memory past which, held, it is handed over: 30% of the machine's, 3 to 8 GiB.
export const hardRssOf = (totalBytes: number): number => clamp(Math.floor(totalBytes * 0.3), 3 * GiB, 8 * GiB);

export type NodeMemory = { rss: number; heapUsed: number; external: number; arrayBuffers: number };

export type SelfMemoryOptions = {
  clock?: Clock.Clock;
  totalBytes: number;
  /// When this process started, on the clock.
  startedAt: number;
  /// Node's own (process.memoryUsage).
  memory(): NodeMemory;
  /// The resident bytes of the programs it runs, and how many there are.
  children(): Promise<{ bytes: number; count: number }>;
  pressure(): Promise<Pressure | null>;
  /// Lets go what answers nothing; how many were.
  trimIdle(): number | Promise<number>;
  /// How to ask the launcher to hand over (ops/restart.ts `restarter`); null where there is none.
  handover(): Promise<(() => Promise<void>) | null>;
  sampleMs?: number;
  softBytes?: number;
  hardRssBytes?: number;
  hardHeapBytes?: number;
  sustained?: number;
  startupMs?: number;
  reliefMs?: number;
};

/// What a sample did: how many were let go (null: nothing was asked), and whether the launcher was asked to hand over
/// (`asked`), there was none to ask (`none`), or neither.
export type SelfVerdict = { trimmed: number | null; handover: "asked" | "none" | null };

export class SelfMemoryGovernor {
  readonly #o: SelfMemoryOptions;
  readonly #fibers: Fibers;
  readonly #soft: number;
  readonly #hardRss: number;
  readonly #hardHeap: number;
  #lastRelief: number | null = null;
  /// Samples in a row with Node past its hard limit.
  #over = 0;
  #handedOver = false;
  #stop: (() => void) | null = null;

  constructor(o: SelfMemoryOptions) {
    this.#o = o;
    this.#fibers = new Fibers("memory", o.clock);
    this.#soft = o.softBytes ?? softLimitOf(o.totalBytes);
    this.#hardRss = o.hardRssBytes ?? hardRssOf(o.totalBytes);
    this.#hardHeap = o.hardHeapBytes ?? HEAP_MOST;
  }

  start(): void {
    this.#stop ??= this.#fibers.every(this.#o.sampleMs ?? SAMPLE_MS, () => this.sample()); // timer: a sample of this machine (the station's own memory)
  }

  async sample(): Promise<SelfVerdict> {
    const now = this.#fibers.now();
    const node = this.#o.memory();
    const children = await this.#o.children();
    const pressure = await this.#o.pressure();
    const whole = node.rss + children.bytes;
    const fields = {
      nodeRssMb: Math.round(node.rss / MiB), heapUsedMb: Math.round(node.heapUsed / MiB), externalMb: Math.round(node.external / MiB),
      arrayBuffersMb: Math.round(node.arrayBuffers / MiB), mbChildrenRssMb: Math.round(children.bytes / MiB), mbCount: children.count, pressure,
    };
    const verdict: SelfVerdict = { trimmed: null, handover: null };
    const pressed = pressure === "high" || pressure === "critical";
    if ((pressed || whole > this.#soft) && (this.#lastRelief === null || now - this.#lastRelief >= (this.#o.reliefMs ?? RELIEF_MS))) {
      this.#lastRelief = now;
      verdict.trimmed = await this.#o.trimIdle();
      log.info("memory", "station trimmed idle helpers under memory pressure", { ...fields, softMb: Math.round(this.#soft / MiB), trimmed: verdict.trimmed });
    }
    this.#over = node.rss > this.#hardRss || node.heapUsed > this.#hardHeap ? this.#over + 1 : 0;
    if (this.#handedOver || this.#over < (this.#o.sustained ?? SUSTAINED) || now - this.#o.startedAt < (this.#o.startupMs ?? STARTUP_MS)) return verdict;
    // (counted again from here: where there is no launcher, said once a SUSTAINED samples while it lasts)
    this.#over = 0;
    const limits = { hardRssMb: Math.round(this.#hardRss / MiB), hardHeapMb: Math.round(this.#hardHeap / MiB) };
    const ask = await this.#o.handover().catch(() => null);
    if (ask === null) {
      log.warn("memory", "station process exceeded sustained memory limit; no launcher to hand over to, trimming idle helpers", { ...fields, ...limits });
      verdict.trimmed = await this.#o.trimIdle();
      verdict.handover = "none";
      return verdict;
    }
    this.#handedOver = true;
    log.warn("memory", "station process exceeded sustained memory limit; asking launcher to hand over", { ...fields, ...limits });
    await ask().catch((e) => {
      // (asked again once it is held SUSTAINED samples more)
      this.#handedOver = false;
      log.warn("memory", "asking the launcher to hand over failed", { error: (e as Error).message });
    });
    verdict.handover = "asked";
    return verdict;
  }

  async close(): Promise<void> {
    this.#stop = null;
    await this.#fibers.close();
  }
}
