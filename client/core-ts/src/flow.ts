// How fast a file comes to this device (views/downloads.ts, fill.ts): the bytes that came over the last FLOW_WINDOW_MS,
// per second, counted as they come off the wire (what was kept already is not counted: it did not come). Nothing samples
// it on a timer: it is read as what comes is told, so a file that stops coming says the speed it last had until it is
// told again (its part answered, given up, or asked anew).

/// How far back what came is counted.
export const FLOW_WINDOW_MS = 4_000;
/// How long it must have been coming before a speed is said (the first piece's burst is not one).
export const FLOW_MIN_MS = 1_000;
/// How often at most a file still coming is told again for its speed alone (its percent unchanged).
export const FLOW_TELL_MS = 1_000;

export class Flow {
  /// When each lot came (ms) and how many bytes, oldest first, none older than the window.
  #at: number[] = [];
  #n: number[] = [];
  /// Since when it has been coming without a gap as long as the window.
  #since = 0;

  /// `bytes` came at `now`. After a gap as long as the window (given way, its station away) it is counted anew.
  came(now: number, bytes: number): void {
    if (!(bytes > 0)) return;
    this.#trim(now);
    if (this.#at.length === 0) this.#since = now;
    this.#at.push(now);
    this.#n.push(bytes);
  }

  /// Bytes per second over the window up to `now`; 0 while it has come for less than FLOW_MIN_MS, or nothing came within
  /// the window.
  perSecond(now: number): number {
    this.#trim(now);
    if (this.#at.length === 0) return 0;
    const span = Math.min(FLOW_WINDOW_MS, now - this.#since);
    if (span < FLOW_MIN_MS) return 0;
    let sum = 0;
    for (const n of this.#n) sum += n;
    return Math.round((sum * 1000) / span);
  }

  #trim(now: number): void {
    let drop = 0;
    while (drop < this.#at.length && this.#at[drop]! <= now - FLOW_WINDOW_MS) drop++;
    if (drop === 0) return;
    this.#at.splice(0, drop);
    this.#n.splice(0, drop);
  }
}
