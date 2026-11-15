// What a move would send of each chat, in bytes, known before it starts (move/AGENTS.md): each session's room and
// transcripts sized by the move's own gathering walk (carry-worker.ts `sizes`, in a thread of its own: the same rules,
// so the same files), kept a line a session (`move/sizes.log`, kept.ts `KeptLog`) against the session as it was then
// (`stamp`: its last activity, archived or not, its last job and where that stands). A plan read tells what it read of
// the chats (`seen`): a session whose stamp differs from its line's, or with none, is measured again by one pass in the
// background, a batch at a time; one whose stamp is its line's is looked at no further (no room walked).
import { join } from "node:path";
import type { Sized, SizedPlaces } from "../replica/carry-worker.ts";
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
  /// Sessions `keys` sized (carry-worker.ts `sizes` in its thread, retire.ts `sizesSoon`).
  measure: (keys: string[]) => Promise<Sized[]>;
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
  /// is measured again (the pass, started if none runs).
  seen(id: string, sessions: { key: string; stamp: string }[]): void {
    this.#keysOf.set(id, sessions.map((s) => s.key));
    for (const s of sessions) {
      if (this.#log.get(s.key)?.stamp === s.stamp) this.#stale.delete(s.key);
      else this.#stale.set(s.key, s.stamp);
    }
    if (this.#stale.size > 0 && this.#pass === null) this.#pass = this.#run().catch((e) => log.warn("move", "the chats' sizing stopped", { error: (e as Error).message }));
  }

  /// The pass under way, ended (none: at once).
  async settled(): Promise<void> {
    while (this.#pass !== null) await this.#pass;
  }

  async #run(): Promise<void> {
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
        for (const [key, stamp] of batch) {
          // (seen again meanwhile with another stamp: measured again in a later batch)
          if (this.#stale.get(key) === stamp) this.#stale.delete(key);
          const s = byKey.get(key);
          if (s === undefined) continue;
          this.measured++;
          // (not kept, a write failing: known till the station stops, measured again after)
          await this.#log.set(key, { bytes: s.bytes, complete: s.complete, stamp, room: s.room, transcripts: s.transcripts }).catch((e) => log.warn("move", "a chat's size not kept", { error: (e as Error).message }));
        }
      }
    } finally {
      this.#pass = null;
    }
  }

  /// A session gone from here (handed over): its line let go.
  async forget(keys: string[]): Promise<void> {
    for (const k of keys) {
      this.#stale.delete(k);
      await this.#log.delete(k);
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
