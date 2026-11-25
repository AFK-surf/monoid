// The pace this station's backups leave it at (replica/AGENTS.md): every byte sent to a keeper station or an S3/R2
// target shares one rate, `config.json` `backup.uploadMbps`, so a first copy of many GB never fills the machine's
// uplink and starves its chats, screens and everything else on that line. Bytes go in slices of SLICE, each when the
// rate allows, never a part sent whole at line rate after a wait.
import type { Bytes } from "../mesh/bus.ts";

/// What is sent at once: small enough that the link is never held for long.
export const SLICE = 64 * 1024;
/// How far ahead an idle pace lets bytes go at once, in time at its rate.
export const BURST_MS = 250;

export type PaceDeps = {
  /// Milliseconds, on the station's clock.
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  /// Bytes a second now (0 or less: unpaced).
  rate: () => number;
};

export class Pace {
  readonly #d: PaceDeps;
  /// When the bytes taken so far have gone at the rate.
  #free = Number.NEGATIVE_INFINITY;

  constructor(d: PaceDeps) {
    this.#d = d;
  }

  /// Whether bytes are paced now.
  get on(): boolean {
    return this.#d.rate() > 0;
  }

  /// Waits until `n` more bytes may go. Callers are served in the order they ask, each its share of one rate.
  async take(n: number): Promise<void> {
    const rate = this.#d.rate();
    if (!(rate > 0) || n <= 0) return;
    const now = this.#d.now();
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
