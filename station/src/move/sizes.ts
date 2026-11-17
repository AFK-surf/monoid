// What a move would send of each chat, in bytes, known before it starts (move/AGENTS.md): each session's room and
// transcripts sized by the move's own gathering walk (carry.ts `sizesSoon`, the MoonBit program's: the same rules,
// so the same files), kept a line a session (`move/sizes.log`, kept.ts `KeptLog`) against the session as it was then
// (`stamp`: its last activity, archived or not, its last job and where that stands). A plan read tells what it read of
// the chats (`seen`): a session whose stamp differs from its line's, or with none, is measured again by one pass in the
// background, a batch at a time; one whose stamp is its line's is looked at no further (no room walked).
import { join } from "node:path";
import type { Sized, SizedPlaces } from "../replica/carry.ts";
import { log } from "../ops/log.ts";
import { KeptLog } from "./kept.ts";

/// A session's line: its bytes (at least, where `complete` is false), the stamp it was measured against, and where its
/// things are (what the other station is asked to size of its own).
export type SizeLine = { bytes: number; complete: boolean; stamp: string; room: string | null; transcripts: string[] };

/// The sessions one batch of a pass sizes, and the most entries a session's walk takes (past it: at least).
export const SIZES_BATCH = 50;
export const SIZE_MOST = 500_000;

export type SizesDeps = {
  data: string;
  /// Sessions `keys` sized (carry.ts `sizesSoon`, the program's own walk of the gathering).
  measure: (keys: string[]) => Promise<Sized[]>;
  /// Whether session `key` is gone from here (handed over): its line, not read since, let go after a pass at rest.
  gone?: (key: string) => boolean;
};

/// What a set of chats would send, as far as it is known.
export type Sum = { bytes: number; known: number; of: number; measuring: number; atLeast: boolean };

export class Sizes {
  readonly #d: SizesDeps;
  readonly #log: KeptLog<SizeLine>;
  /// The sessions to measure (the stamp each was seen with), and each chat's sessions as the plan named them.
  readonly #stale = new Map<string, string>();
  readonly #keysOf = new Map<string, string[]>();
  #pass: Promise<void> | null = null;
  /// The sessions measured so far (a test's count of the rooms looked at).
  measured = 0;

  constructor(d: SizesDeps) {
    this.#d = d;
    this.#log = new KeptLog<SizeLine>(join(d.data, "move", "sizes.log"));
  }

  /// What a plan read of chat `id`: its sessions, each with its stamp. One whose line is of another stamp, or has none,
  /// is measured again by the pass the plan's end starts (`read`).
  seen(id: string, sessions: { key: string; stamp: string }[]): void {
    this.#keysOf.set(id, sessions.map((s) => s.key));
    for (const s of sessions) {
      if (this.#log.get(s.key)?.stamp === s.stamp) this.#stale.delete(s.key);
      else this.#stale.set(s.key, s.stamp);
    }
  }

  /// A plan read ended: what it found stale measured, at rest (none started while a turn runs here).
  read(): void {
    if (!this.#quiet) this.#start();
  }

  /// While a turn moves chats, no pass starts by a plan read (what is read then is no plan at rest, and the rooms it
  /// would measure are moving): what is stale waits for a plan read at rest, or for a whole move's own ask (`settled`).
  #quiet = false;
  set quiet(on: boolean) {
    this.#quiet = on;
  }

  #start(): void {
    if (this.#stale.size > 0 && this.#pass === null) this.#pass = this.#run().catch((e) => log.warn("move", "the chats' sizing stopped", { error: (e as Error).message }));
  }

  /// What is stale measured now, a turn under way or not (a whole move's own ask, before anything is held), and ended.
  async settled(): Promise<void> {
    this.#start();
    while (this.#pass !== null) await this.#pass;
  }

  async #run(): Promise<void> {
    const t0 = performance.now();
    const before = this.measured;
    try {
      while (this.#stale.size > 0) {
        const batch = [...this.#stale].slice(0, SIZES_BATCH);
        let got: Sized[] = [];
        try {
          got = await this.#d.measure(batch.map(([k]) => k));
        } catch (e) {
          log.warn("move", "chats' sizes not measured", { sessions: batch.length, error: (e as Error).message });
        }
        const byKey = new Map(got.map((s) => [s.key, s]));
        const lines: [string, SizeLine][] = [];
        for (const [key, stamp] of batch) {
          // (seen again meanwhile with another stamp: measured again in a later batch)
          if (this.#stale.get(key) === stamp) this.#stale.delete(key);
          const s = byKey.get(key);
          if (s === undefined) continue;
          this.measured++;
          lines.push([key, { bytes: s.bytes, complete: s.complete, stamp, room: s.room, transcripts: s.transcripts }]);
        }
        // (a batch's lines in one write; not kept, a write failing: known till the station stops, measured again after)
        await this.#log.many(lines).catch((e) => log.warn("move", "chats' sizes not kept", { error: (e as Error).message }));
      }
      // (the lines of sessions gone from here since, not read, let go: a pass at rest's, never one a hand-over writes)
      if (!this.#quiet && this.#d.gone !== undefined) {
        const gone = this.#log.keys().filter((k) => this.#d.gone!(k));
        await this.#log.many(gone.map((k) => [k, undefined])).catch(() => {});
      }
    } finally {
      this.#pass = null;
      log.info("move", "chats' sizes measured", { sessions: this.measured - before, ms: Math.round(performance.now() - t0) });
    }
  }

  /// The sessions of chat `id` as the last plan named them.
  keysOf(id: string): string[] {
    return this.#keysOf.get(id) ?? [id];
  }

  line(key: string): SizeLine | undefined {
    return this.#log.get(key);
  }

  /// Where chat `id`'s sessions' things are, for the other station's sizing of its own.
  placesOf(id: string): SizedPlaces[] {
    return this.keysOf(id).flatMap((key) => {
      const l = this.#log.get(key);
      return l === undefined ? [] : [{ key, room: l.room, transcripts: l.transcripts }];
    });
  }

  /// What chats `ids` would send, as far as it is known: a chat is known once each of its sessions has a line of the
  /// stamp it was last seen with.
  sum(ids: string[]): Sum {
    const out: Sum = { bytes: 0, known: 0, of: ids.length, measuring: 0, atLeast: false };
    for (const id of ids) {
      const keys = this.keysOf(id);
      if (keys.some((k) => this.#stale.has(k) || this.#log.get(k) === undefined)) {
        out.measuring++;
        continue;
      }
      out.known++;
      for (const k of keys) {
        const l = this.#log.get(k)!;
        out.bytes += l.bytes;
        if (!l.complete) out.atLeast = true;
      }
    }
    return out;
  }
}
