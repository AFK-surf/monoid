// The pace this station's backups leave it at (replica/AGENTS.md): every byte sent to a keeper station or an S3/R2
// target shares one rate, `config.json` `backup.uploadMbps`, so a first copy of many GB never fills the machine's
// uplink and starves its chats, screens and everything else on that line. Bytes go in slices of SLICE, each when the
// rate allows, never a part sent whole at line rate after a wait. That rate is a ceiling: below it a backup gives way
// to everything else on the line by the delay it makes (`Pace.rate`), so a slow uplink is not filled even when its
// speed is under the ceiling.
import type { Bytes, Rtt } from "../mesh/bus.ts";

/// What is sent at once: small enough that the link is never held for long.
export const SLICE = 64 * 1024;
/// How far ahead an idle pace lets bytes go at once, in time at its rate.
export const BURST_MS = 250;

/// The delay a backup lets the line queue (ms over a connection's least round trip): past it, it gives way. A low
/// target, as LEDBAT's (RFC 6817) for background transfers: what queues at this machine's uplink delays every chat,
/// screen and read on it (a station on a slow Wi-Fi: 0.5 to 2 s round trips while it backed up, 2026-11-25, #8704).
export const TARGET_MS = 60;
/// How often the rate is worked out again from the round trips.
export const ADJUST_MS = 250;
/// How long a connection's least round trip counts as its base: a line that changed comes to a new base within it.
export const BASE_MS = 10 * 60_000;
/// The least a backup goes at while it gives way (bytes a second), so it still gets on.
export const FLOOR = 32 * 1024;
/// What is kept of the rate at each adjustment past the target.
export const DOWN = 0.75;
/// What of the ceiling is gained at each adjustment with no delay (less as the delay nears the target).
export const UP = 0.02;

export type PaceDeps = {
  /// Milliseconds, on the station's clock.
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  /// Bytes a second at most now (0 or less: unpaced).
  rate: () => number;
  /// The round trip of each connection to another station now (mesh/peer.ts `rtts`); none: the ceiling alone.
  rtts?: () => Rtt[];
};

/// A connection's least round trip over the last BASE_MS, in two halves so an old least goes.
type Base = { half: number; least: number; before: number };

export class Pace {
  readonly #d: PaceDeps;
  /// When the bytes taken so far have gone at the rate.
  #free = Number.NEGATIVE_INFINITY;
  /// The rate it goes at now under the ceiling (null: not worked out yet), and when it was.
  #rate: number | null = null;
  #adjusted = Number.NEGATIVE_INFINITY;
  readonly #bases = new Map<string, Base>();

  constructor(d: PaceDeps) {
    this.#d = d;
  }

  /// Whether bytes are paced now.
  get on(): boolean {
    return this.#d.rate() > 0;
  }

  /// How long each connection's round trip is over its base now, the most of them (null: none told).
  delay(now: number): number | null {
    let most: number | null = null;
    const half = Math.floor(now / (BASE_MS / 2));
    for (const { key, ms } of this.#d.rtts?.() ?? []) {
      if (!(ms > 0) || !Number.isFinite(ms)) continue;
      let b = this.#bases.get(key);
      if (b === undefined) this.#bases.set(key, (b = { half, least: ms, before: ms }));
      else if (b.half !== half) {
        b.before = b.half === half - 1 ? b.least : ms;
        b.half = half;
        b.least = ms;
      } else b.least = Math.min(b.least, ms);
      const over = ms - Math.min(b.least, b.before);
      most = most === null ? over : Math.max(most, over);
    }
    // (a connection gone a while: its base with it; one that comes again soon keeps it, not learnt anew on a full line)
    for (const [key, b] of this.#bases) if (b.half < half - 1) this.#bases.delete(key);
    return most;
  }

  /// Bytes a second it goes at now, under `ceiling`: down by DOWN each ADJUST_MS the delay is past TARGET_MS, up by a
  /// share of the ceiling below it; the ceiling itself when no round trip is told (no other station connected).
  rate(ceiling: number, now: number): number {
    if (now - this.#adjusted < ADJUST_MS && this.#rate !== null) return Math.min(this.#rate, ceiling);
    this.#adjusted = now;
    const delay = this.delay(now);
    const floor = Math.min(FLOOR, ceiling);
    if (delay === null) return (this.#rate = ceiling);
    let rate = this.#rate ?? Math.max(floor, ceiling / 4);
    if (delay > TARGET_MS) rate *= DOWN;
    else rate += ceiling * UP * (1 - delay / TARGET_MS);
    return (this.#rate = Math.min(ceiling, Math.max(floor, rate)));
  }

  /// Waits until `n` more bytes may go. Callers are served in the order they ask, each its share of one rate.
  async take(n: number): Promise<void> {
    const ceiling = this.#d.rate();
    if (!(ceiling > 0) || n <= 0) return;
    const now = this.#d.now();
    const rate = this.rate(ceiling, now);
    this.#free = Math.max(this.#free, now - BURST_MS) + (n * 1000) / rate;
    const wait = this.#free - now;
    if (wait > 0) await this.#d.sleep(wait);
  }

  /// `bytes`, each slice let through when the rate allows.
  paced(bytes: Bytes): Bytes {
    const pace = this;
    return {
      async *[Symbol.asyncIterator]() {
        for await (const piece of bytes) {
          for (let at = 0; at < piece.length; at += SLICE) {
            const slice = piece.subarray(at, Math.min(piece.length, at + SLICE));
            await pace.take(slice.length);
            yield slice;
          }
        }
      },
    };
  }
}

/// Bytes a second of `mbps` megabits a second.
export const bytesPerSecond = (mbps: number): number => (mbps > 0 ? (mbps * 1_000_000) / 8 : 0);
