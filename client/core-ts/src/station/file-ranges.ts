// A save, a player and a cache fill can read different, overlapping parts of the same station file.
// Reserve the entire interval before yielding. Each reader then takes its slices in order, including bytes
// that arrived before it joined. Only the last reader to leave a range interrupts its request.
import { Deferred, Effect, Exit, Fiber } from "effect";
import { CoreError } from "../error.ts";
import { t } from "../i18n.ts";
import type { Runner } from "../runtime.ts";
import { concat } from "./wire.ts";

type Head = { type: string; total: number; mtime?: number | null };
type Fetch<H> = (at: number, length: number, take: (part: Uint8Array) => void, said: (head: H) => void) => Effect.Effect<H, CoreError>;
type Range<H> = {
  at: number;
  end: number;
  users: number;
  noHedge: boolean;
  head?: H;
  loaded: number;
  pieces: { at: number; bytes: Uint8Array }[];
  listeners: Set<() => void>;
  done: Deferred.Deferred<H, CoreError>;
  fiber?: Fiber.Fiber<void, never>;
};
type Slice<H> = { range: Range<H>; at: number; end: number };

const same = (a: Head, b: Head) => a.total === b.total && a.mtime === b.mtime;

export class FileRanges<H extends Head> {
  readonly #files = new Map<string, Set<Range<H>>>();
  readonly #runner: Runner;

  constructor(runner: Runner) {
    this.#runner = runner;
  }

  #start(range: Range<H>, fetch: Fetch<H>): void {
    if (range.fiber) return;
    const notify = () => { for (const next of range.listeners) next(); };
    const transfer = fetch(range.at, range.end - range.at, (bytes) => {
      range.pieces.push({ at: range.at + range.loaded, bytes });
      range.loaded += bytes.length;
      notify();
    }, (head) => {
      range.head = head;
      notify();
    });
    range.fiber = this.#runner.fork(Effect.flatMap(Effect.exit(transfer), (result) =>
      Effect.sync(() => { Deferred.doneUnsafe(range.done, result); })));
  }

  #reserve(key: string, at: number, end: number, noHedge: boolean): Slice<H>[] {
    const active = this.#files.get(key) ?? new Set<Range<H>>();
    this.#files.set(key, active);
    const slices: Slice<H>[] = [];
    do {
      let cover: Range<H> | undefined;
      let next = end;
      for (const range of active) {
        if (!noHedge && range.noHedge) continue;
        if (range.at <= at && at < range.end) { cover = range; break; }
        if (range.at > at) next = Math.min(next, range.at);
      }
      if (!cover) {
        cover = { at, end: next, loaded: 0, users: 0, noHedge, pieces: [], listeners: new Set(), done: Deferred.makeUnsafe() };
        active.add(cover);
      }
      cover.users++;
      const until = Math.min(end, cover.end);
      slices.push({ range: cover, at, end: until });
      at = until;
    } while (at < end);
    return slices;
  }

  #release(key: string, slices: Slice<H>[]): Effect.Effect<void> {
    const active = this.#files.get(key)!;
    const last = slices.map((s) => s.range).filter((range) => --range.users === 0);
    for (const range of last) active.delete(range);
    if (!active.size) this.#files.delete(key);
    return Effect.forEach(last, (range) => range.fiber ? Fiber.interrupt(range.fiber) : Effect.void, { discard: true });
  }

  read(key: string, at: number, length: number, fetch: Fetch<H>, heard?: (loaded: number) => void, sink?: (bytes: Uint8Array) => void, said?: (head: H) => void, noHedge = false): Effect.Effect<H & { bytes: Uint8Array }, CoreError> {
    return Effect.suspend(() => {
      const chunks: Uint8Array[] = [];
      let head: H | undefined;
      let loaded = 0;
      let detach = () => {};
      const receiveHead = (next: H) => {
        if (head) return same(head, next);
        head = next;
        said?.(next);
        return true;
      };
      return Effect.acquireUseRelease(
        Effect.sync(() => this.#reserve(key, at, at + length, noHedge)),
        (slices) => Effect.gen({ self: this }, function* () {
          for (const { range, at: from, end } of slices) {
            this.#start(range, fetch);
            let index = 0;
            const ready = Deferred.makeUnsafe<H>();
            const drain = () => {
              if (range.head && !receiveHead(range.head)) return;
              while (index < range.pieces.length) {
                const piece = range.pieces[index++];
                const left = Math.max(0, from - piece.at);
                const right = Math.min(piece.bytes.length, end - piece.at);
                if (right <= left) continue;
                const bytes = piece.bytes.subarray(left, right);
                // A web reader transfers its buffer out of the core. Other readers still need it.
                if (sink) sink(bytes.slice());
                else chunks.push(bytes);
                loaded += bytes.length;
                heard?.(loaded);
              }
              if (end < range.end && range.head && range.at + range.loaded >= end) Deferred.doneUnsafe(ready, Exit.succeed(range.head));
            };
            range.listeners.add(drain);
            detach = () => range.listeners.delete(drain);
            drain();
            const complete = Deferred.await(range.done);
            const result = yield* (end < range.end ? Effect.raceFirst(complete, Deferred.await(ready)) : complete);
            drain();
            detach();
            if (!receiveHead(result)) return yield* Effect.fail(new CoreError("changed", t("station.core.fileUnreadable")));
            if (loaded < end - at || end >= result.total) break;
          }
          return { ...head!, bytes: concat(chunks) };
        }),
        // Leave the sink attached until interruption has flushed the last short batch into the reader's cache.
        (slices) => Effect.ensuring(this.#release(key, slices), Effect.sync(() => detach())),
      );
    });
  }
}
