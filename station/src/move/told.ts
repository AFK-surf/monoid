// Told steps (move/AGENTS.md): what one station asks of another in a move whose work grows with a chat or a repository
// (a chat's files placed, its room pruned, a hand-over back, a bundle fetched, a clone removed) is never done inside
// the request. A request's answer is waited for 30 s at most (mesh/peer.ts ANSWER_MS) and placing costs about 0.7 ms a
// file (the real run, 2026-11-16: a chat of 70k files took 50 s to place and its move failed, 「…没有应答」), so the
// station asked starts the step and answers at once (`under`), or, where that step ended already, gives its result
// again; the step tells its asker how it goes (`move.told`) at least every TOLD_EVERY_MS while it works, and its end
// until that is answered. The asker waits on its end, however long the step takes: there is no clock on a step's
// length. Told nothing for TOLD_SILENT_MS, or as the other is heard from again after a silence, it asks the same
// step again (a request as any, bounded by ANSWER_MS, and only its failing fails the step): `under`, it waits on; the
// result, it takes it; a station that does not know the step (its process was replaced) starts it again on that same
// ask, so every step is one that can run again. A step is known by a key its asker makes (what it is of, and its
// arguments), the same in every ask of it.
// A station from before told steps answers the request with its result, as it did: the asker takes that as the end.
import { Refused } from "../mesh/bus.ts";
import type { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { RETRY_MOST_MS, RETRY_MS } from "../replica/retire.ts";

type Json = any;

/// How often a step under way tells its asker it still works: well within an answer's 30 s, and few enough requests
/// for a step of an hour (720); on the station's clock, so that a test moves it cheaply.
export const TOLD_EVERY_MS = 5_000;
/// Told nothing for this long, the asker asks the step again: three beats missed.
export const TOLD_SILENT_MS = 3 * TOLD_EVERY_MS;
/// Heard from again after this long without a word of a step, the asker asks it again at once (a link that opened again);
/// a beat comes every TOLD_EVERY_MS, so a station only heard as it beats is not asked again by it.
const HEARD_AGAIN_MS = 2 * TOLD_EVERY_MS;
/// The ended steps kept for an ask of them again (their end's tell lost): the latest, a few hand-overs' worth.
const ENDED_MOST = 256;

/// What a told step's request answers while it works.
export const isUnder = (answer: Json, key: string) => answer?.under === true && answer?.told === key;

type Waiter = {
  to: string; key: string; make: () => Json; progress?: (p: Json) => void;
  resolve: (v: Json) => void; reject: (e: Error) => void;
  /// The silence's deadline, called off as it is armed again; when it was last told.
  silent: () => void; heard: number; asking: boolean; over: boolean;
};

type Step = { state: "running" } | { state: "ended"; result?: Json; error?: string };

export type ToldDeps = {
  fibers: Fibers;
  /// How this station asks another (the move's own, move/station.ts: a station found gone in a turn is asked nothing more).
  ask: (station: string, request: Json) => Promise<Json>;
  /// What keeps the station from updating itself (updates/holds.ts `hold`): held while a step runs here, as the request
  /// that asked it was held while it was answered.
  hold?: () => () => void;
};

export class Told {
  readonly #d: ToldDeps;
  /// The steps this station waits on, by station and key.
  readonly #waiting = new Map<string, Waiter>();
  /// The steps this station runs for others, by station and key, the ended ones the latest ENDED_MOST.
  readonly #steps = new Map<string, Step>();
  /// What each running step tells and stops (its beat, its end's retry).
  readonly #running = new Map<string, Promise<void>>();
  readonly #stops = new Set<() => void>();
  #closed = false;

  constructor(d: ToldDeps) {
    this.#d = d;
  }

  // ── the station that asks ──

  /// Step `key` asked of station `to` (`make` makes its request, a new one each time: one with bytes carries them
  /// anew), waited on to its end: its result, or what it failed with. `progress`: what the step told of how far it is.
  asked(to: string, key: string, make: () => Json, progress?: (p: Json) => void): Promise<Json> {
    if (this.#closed) return Promise.reject(new Error("this station is stopping"));
    const at = `${to}\n${key}`;
    return new Promise<Json>((resolve, reject) => {
      // (waited on before it is asked: its end may be told before the answer that it is under way comes back)
      const w: Waiter = { to, key, make, progress, resolve, reject, silent: () => {}, heard: this.#d.fibers.now(), asking: false, over: false };
      const end = () => {
        w.over = true;
        w.silent();
        if (this.#waiting.get(at) === w) this.#waiting.delete(at);
      };
      w.resolve = ((r) => (v: Json) => (end(), r(v)))(resolve);
      w.reject = ((j) => (e: Error) => (end(), j(e)))(reject);
      this.#waiting.set(at, w);
      this.#askAgain(w);
    });
  }

  /// The step `w` waits on asked (again): under way, its silence's deadline armed; its result taken; its ask failing,
  /// the step failed with that.
  #askAgain(w: Waiter): void {
    if (w.over || w.asking) return;
    w.asking = true;
    w.silent();
    void this.#d.ask(w.to, w.make()).then(
      (answer) => {
        w.asking = false;
        if (w.over) return;
        if (isUnder(answer, w.key)) return this.#arm(w);
        // (its result, given again or at once; a station from before answers the request so)
        w.resolve(answer);
      },
      (e) => {
        w.asking = false;
        if (!w.over) w.reject(e as Error);
      },
    );
  }

  #arm(w: Waiter): void {
    w.silent();
    w.silent = this.#d.fibers.after(TOLD_SILENT_MS, () => this.#askAgain(w)); // timer: a deadline (told nothing that long, the step is asked again)
  }

  /// What a station running a step of this one's told (`move.told`): how far it is, or its end. Answered whatever it
  /// is: one this station no longer waits on (its process was replaced) is told no more.
  heard(peer: string, request: Json): Json {
    const key = typeof request?.told === "string" ? request.told : "";
    const w = this.#waiting.get(`${peer}\n${key}`);
    if (w === undefined || w.over) return { ok: true };
    w.heard = this.#d.fibers.now();
    if (request.ended === true) {
      if (typeof request.error === "string") w.reject(new Refused(request.error));
      else w.resolve(request.result ?? null);
      return { ok: true };
    }
    if (request.progress !== undefined && request.progress !== null) w.progress?.(request.progress);
    if (!w.asking) this.#arm(w);
    return { ok: true };
  }

  /// Step `key` of station `to` no longer waited on: failed here with `error` at once (its hand-over given up). The
  /// station running it ends it as it would; its end, told late, is answered and taken as of nothing waited on.
  letGo(to: string, key: string, error: Error): void {
    this.#waiting.get(`${to}\n${key}`)?.reject(error);
  }

  /// Station `peer` heard from: each step of it this station waited on with no word for a while asked again now (its
  /// link opened again).
  reached(peer: string): void {
    const now = this.#d.fibers.now();
    for (const w of this.#waiting.values()) if (w.to === peer && now - w.heard >= HEARD_AGAIN_MS) (w.heard = now), this.#askAgain(w);
  }

  // ── the station asked ──

  /// Step `key` of station `origin`'s, asked of this one: started (`work`, given how to say how far it is), answered at
  /// once as under way; the same asked again while it runs, under way; ended, its result again (its error refused
  /// again). `measure`: how far it is, asked at each beat (none: what `work` said last).
  run(origin: string, key: string, work: (progress: (p: Json) => void) => Promise<Json>, opts: { measure?: () => Promise<Json> } = {}): Json {
    const at = `${origin}\n${key}`;
    const was = this.#steps.get(at);
    if (was?.state === "running") return { under: true, told: key };
    if (was?.state === "ended") {
      if (was.error !== undefined) throw new Refused(was.error);
      return was.result ?? null;
    }
    if (this.#closed) throw new Refused("this station is stopping: ask again in a moment");
    this.#steps.set(at, { state: "running" });
    const letGo = this.#d.hold?.() ?? (() => {});
    let told: Json = null;
    const tell = (body: Json) => this.#d.ask(origin, { method: "move.told", told: key, ...body });
    // (how far it is told every beat, whatever it is doing; one that does not get there is the asker's silence)
    const beat = this.#d.fibers.every(TOLD_EVERY_MS, async () => { // timer: a heartbeat (a step under way tells it still works)
      if (this.#closed) return;
      if (opts.measure !== undefined) told = await opts.measure().catch(() => told);
      await tell({ progress: told ?? {} }).catch(() => {});
    });
    this.#stops.add(beat);
    const ran = (async () => {
      let end: { result?: Json; error?: string };
      try {
        end = { result: await work((p) => void (told = p)) };
      } catch (e) {
        end = { error: (e as Error)?.message ?? String(e) };
      } finally {
        beat();
        this.#stops.delete(beat);
        letGo();
      }
      this.#steps.set(at, { state: "ended", ...end });
      for (const k of this.#steps.keys()) {
        if (this.#steps.size <= ENDED_MOST) break;
        if (this.#steps.get(k)?.state === "ended") this.#steps.delete(k);
      }
      if (end.error !== undefined) log.info("move", "a step asked of this station failed", { station: origin.slice(0, 12), step: key.split(":")[0], error: end.error });
      await this.#tellEnd(tell, { ended: true, ...end }, 0);
    })();
    this.#running.set(at, ran);
    void ran.finally(() => void (this.#running.get(at) === ran && this.#running.delete(at)));
    return { under: true, told: key };
  }

  /// A step's end told until it is answered (a refusal is an answer: a station from before has no told steps), with the
  /// backoff a hand-over's retries keep.
  async #tellEnd(tell: (body: Json) => Promise<Json>, body: Json, n: number): Promise<void> {
    if (this.#closed) return;
    try {
      await tell(body);
    } catch (e) {
      if (e instanceof Refused || this.#closed) return;
      const again = this.#d.fibers.after(Math.min(RETRY_MS * 2 ** n, RETRY_MOST_MS), () => void this.#tellEnd(tell, body, n + 1)); // timer: a retry after a failure
      this.#stops.add(again);
    }
  }

  /// The steps under way here brought to their end (a test's).
  async settle(): Promise<void> {
    while (this.#running.size > 0) await Promise.all([...this.#running.values()]);
  }

  /// This process stopping: nothing more told or waited on; the steps it ran are its next process's to run again, as
  /// their askers ask them.
  close(): void {
    this.#closed = true;
    for (const stop of this.#stops) stop();
    this.#stops.clear();
    for (const w of [...this.#waiting.values()]) w.reject(new Error("this station is stopping"));
  }
}
