import { Deferred, Effect } from "effect";
import type { Inner, Progress } from "../core.ts";
import type { CoreError } from "../error.ts";
import { Beside } from "../protocol.ts";
import type { SpanContext } from "../trace.ts";
import type { StationAddr } from "./addr.ts";

/// A whole file being read from its station, and those waiting for it: each told how far it has come. `waiting`: how
/// many wait for it still.
type Going = { done: Deferred.Deferred<Beside, CoreError>; heard: Set<Progress>; last: unknown; waiting: number };
const goingOf = new WeakMap<Inner, Map<string, Going>>();

/// `read` once for every asker of the same file at once: one asked again while it is coming (its preview closed and
/// opened again, its image put up anew) waits for the read going, told how far it has come, not brought again beside
/// it. A whole file's read runs to its end whoever waits; each asked anew began another, and on a desktop app six images
/// were coming fifteen times at once, each at a fifteenth of the line, until the app was restarted (a station, 2026-10-28).
export function once(inner: Inner, key: string, progress: Progress, read: (progress: Progress) => Effect.Effect<Beside, CoreError>): Effect.Effect<Beside, CoreError> {
  return Effect.suspend(() => {
    let all = goingOf.get(inner);
    if (all === undefined) goingOf.set(inner, (all = new Map()));
    const going = all;
    let g = going.get(key);
    if (g === undefined) {
      const made: Going = { done: Deferred.makeUnsafe<Beside, CoreError>(), heard: new Set([progress]), last: undefined, waiting: 0 };
      g = made;
      going.set(key, made);
      const tell: Progress = (value) => {
        made.last = value;
        for (const heard of made.heard) heard(value);
      };
      inner.runner.fork(
        Effect.flatMap(Effect.exit(read(tell)), (exit) =>
          Effect.sync(() => {
            if (going.get(key) === made) going.delete(key);
            Deferred.doneUnsafe(made.done, exit);
          }),
        ),
      );
    } else {
      g.heard.add(progress);
      if (g.last !== undefined) progress(g.last);
    }
    const it = g;
    it.waiting++;
    // (what goes beside an answer is the UI's, moved away on the web (its worker's toPage) as it is answered: each that
    // wakes while others wait still takes a copy, the last the bytes read)
    const mine = Effect.map(Deferred.await(it.done), (b) => (it.waiting > 1 ? new Beside(b.value, b.bytes.slice()) : b));
    return Effect.ensuring(mine, Effect.sync(() => {
      it.waiting--;
      it.heard.delete(progress);
    }));
  });
}

/// The legacy whole-file endpoint, also used by a download on a station without range reads.
export function wholeFile(inner: Inner, station: StationAddr, key: string, name: string, thumb: boolean | "preview", progress: Progress, ctx: SpanContext | null): Effect.Effect<Beside, CoreError> {
  return once(inner, JSON.stringify(["whole", station.toString(), key, name, thumb]), progress, (tell) =>
    Effect.map(inner.stations.requests.file(station, key, name, thumb, (loaded, total) => tell({ loaded, total }), ctx),
      ([type, bytes]) => new Beside({ type }, bytes)));
}
