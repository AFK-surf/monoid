// How a person's agents are asked for progress (进度汇报): one choice of theirs, the same on all their devices and in every
// workspace they are in, carried by their own devices as their presets are (views/presets.ts; the rule both sides keep is
// progress-prefs.ts, the station's side station/src/api/routes/progress.ts). The device keeps it in each workspace's
// database (`progressPrefs`), the newest of them the person's; a change (`progress.set`) is kept here at once and brought
// to every station of every workspace of theirs: as a station's link opens, as it tells `progress`, as a stream comes
// back owed it, and as it changes here. Never on a timer. The settings read it in the `settings` view.
import { Effect } from "effect";
import type { Inner } from "../core.ts";
import type { Call } from "../core/calls.ts";
import { handlers } from "../core/execute.ts";
import { CoreError } from "../error.ts";
import { t } from "../i18n.ts";
import { PROGRESS_DEFAULT, type ProgressChoice, type ProgressPrefs, newerProgress, progressOf } from "../progress-prefs.ts";
import { canonical } from "../preset-records.ts";
import { Marks } from "../reactive.ts";
import { StationAddr } from "../station/addr.ts";
import { Priority } from "../sync/scheduler.ts";
import { arr, get, isObject } from "../util.ts";
import { ofAddress } from "../workspace.ts";
import { fromBeforeRoute, whoIn } from "./presets.ts";

type Of = Extract<Call, { kind: "progress" }>;

export const TABLE = "progressPrefs";

/// What the device keeps in a workspace: the choice (null never said); the ids of its stations owed a carry, and of those
/// read at least once (`met`).
export type Held = { sub: string; progress: ProgressPrefs | null; owed: string[]; met: string[] };

const ids = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

const said = (raw: unknown): ProgressPrefs | null => {
  try {
    return raw === null || raw === undefined ? null : progressOf(raw);
  } catch {
    return null;
  }
};

/// What is kept of workspace `ws` for person `sub`: another account's that reached it before is not theirs.
export function heldOf(data: { record(table: string, key: string): unknown }, ws: string, sub: string): Held {
  const raw = data.record(TABLE, ws);
  if (!isObject(raw) || raw.sub !== sub) return { sub, progress: null, owed: [], met: [] };
  return { sub, progress: said(raw.progress), owed: ids(raw.owed), met: ids(raw.met) };
}

const stationId = (address: string) => address.slice(address.lastIndexOf("/") + 1);

function stationsOf(inner: Inner, ws: string): { id: string; address: string }[] {
  return (arr(get(inner.data.shared({ topic: "workspace", workspace: ws }), "stations")) ?? []).flatMap((s) => {
    const id = get(s, "id");
    return typeof id === "string" ? [{ id, address: `${ws}/${id}` }] : [];
  });
}

const ask = (inner: Inner, address: string, method: string, path: string, body: unknown = null) =>
  inner.stations.requests.call(inner.stations.link(address)?.addr ?? StationAddr.parse(address), method, path, body, { quiet: true });

const reached = (inner: Inner, address: string) => inner.provider.kind === "stillfail" && inner.stations.link(address) !== undefined && inner.stations.reachable(address);

export class ProgressViews {
  readonly #inner: Inner;
  readonly #marks = new Marks();
  #seq = 1;

  constructor(inner: Inner) {
    this.#inner = inner;
  }

  /// The choice of the person that workspace `ws` is reached as, with the monotonic publication sequence.
  shown(ws: string): ProgressChoice & { seq: number } {
    this.#marks.read();
    const who = whoIn(this.#inner, ws);
    const choice = (who === null ? null : this.#of(who.sub)) ?? PROGRESS_DEFAULT;
    return { minutes: choice.minutes, strength: choice.strength, seq: this.#seq };
  }

  #workspaces(sub: string): string[] {
    return this.#inner.workspaces.owned().flatMap(([ws, owner]) => (owner === sub ? [ws] : []));
  }

  /// The newest of what is kept for person `sub` in their workspaces.
  #of(sub: string): ProgressPrefs | null {
    let out: ProgressPrefs | null = null;
    for (const ws of this.#workspaces(sub)) {
      const p = heldOf(this.#inner.data, ws, sub).progress;
      if (p !== null) out = out === null ? p : newerProgress(out, p);
    }
    return out;
  }

  #write(ws: string, held: Held): void {
    this.#inner.data.put(TABLE, ws, held);
    this.#marks.touch();
  }

  #mark(ws: string, sub: string, key: "owed" | "met", id: string, on: boolean): void {
    const held = heldOf(this.#inner.data, ws, sub);
    if (held[key].includes(id) === on) return;
    this.#write(ws, { ...held, [key]: on ? [...held[key], id] : held[key].filter((x) => x !== id) });
  }

  /// `given` kept in every workspace of the person's where newer, and brought to their stations (but `besides`, that said it).
  #take(sub: string, given: ProgressPrefs, besides: string | null): void {
    const was = this.#of(sub);
    if (was !== null && canonical(newerProgress(was, given)) === canonical(was)) return;
    this.#seq += 1;
    for (const ws of this.#workspaces(sub)) this.#write(ws, { ...heldOf(this.#inner.data, ws, sub), progress: given });
    for (const ws of this.#workspaces(sub)) {
      for (const s of stationsOf(this.#inner, ws)) {
        if (s.address === besides) continue;
        // (one not reached is owed it: brought as its link opens or its stream comes back)
        if (!reached(this.#inner, s.address)) this.#mark(ws, sub, "owed", s.id, true);
        else this.enqueue(s.address);
      }
    }
  }

  enqueue(address: string): void {
    this.#inner.scheduler.enqueue(address, `progress/${address}`, Priority.background, Effect.ignore(this.carry(address)));
  }

  /// Whether station `address` is owed a carry, or was never read here.
  owedTo(address: string): boolean {
    const ws = ofAddress(address);
    const who = whoIn(this.#inner, ws);
    if (who === null) return false;
    const held = heldOf(this.#inner.data, ws, who.sub);
    return held.owed.includes(stationId(address)) || !held.met.includes(stationId(address));
  }

  /// The choice carried to station `address`: its own read and the newer kept, then brought where it lacks it.
  carry(address: string): Effect.Effect<void, CoreError> {
    const self = this;
    const inner = this.#inner;
    return Effect.gen(function* () {
      if (!reached(inner, address)) return;
      const ws = ofAddress(address);
      const who = whoIn(inner, ws);
      if (who === null) return;
      const id = stationId(address);
      const got = yield* Effect.result(ask(inner, address, "GET", "/progress"));
      if (got._tag === "Failure") {
        // (one from before keeps none, one that has none for this person: owed nothing)
        const none = fromBeforeRoute(got.failure) || got.failure.status === 403;
        if (none) self.#mark(ws, who.sub, "met", id, true);
        return self.#mark(ws, who.sub, "owed", id, !none);
      }
      self.#mark(ws, who.sub, "met", id, true);
      const there = said(get(got.success, "progress"));
      if (there !== null) self.#take(who.sub, there, address);
      const now = self.#of(who.sub);
      if (now !== null && (there === null || canonical(newerProgress(there, now)) !== canonical(there))) {
        const put = yield* Effect.result(ask(inner, address, "PUT", "/progress", { progress: now }));
        // (a read-only member's is not taken: nothing to bring again)
        if (put._tag === "Failure") return self.#mark(ws, who.sub, "owed", id, put.failure.status !== 403);
        const kept = said(get(put.success, "progress"));
        if (kept !== null) self.#take(who.sub, kept, address);
      }
      self.#mark(ws, who.sub, "owed", id, false);
    });
  }

  /// The person's choice changed here: kept and brought to their stations. Returns the current monotonic publication seq.
  set(ws: string, params: Record<string, unknown>): number {
    const who = whoIn(this.#inner, ws);
    if (who === null) throw CoreError.invalid(t("core-misc.presets.signedOut"));
    const was = this.#of(who.sub);
    const { minutes, strength } = was ?? PROGRESS_DEFAULT;
    const at = this.#inner.host.nowMs();
    let now: ProgressPrefs;
    try {
      now = progressOf({ minutes: params.minutes ?? minutes, strength: params.strength ?? strength, rev: Math.max((was?.rev ?? 0) + 1, at), at });
    } catch (e) {
      throw CoreError.invalid(t("core-misc.params.invalid", { error: (e as Error).message }));
    }
    if (now.minutes === minutes && now.strength === strength) return this.#seq;
    this.#take(who.sub, now, null);
    return this.#seq;
  }
}

export function install(inner: Inner): ProgressViews {
  const views = new ProgressViews(inner);
  handlers.progress = (core, call) =>
    Effect.try({
      try: () => {
        const c = call as Of;
        const seq = core.progress.set(c.workspace, c.params);
        return { ok: true, seq };
      },
      catch: (e) => (e instanceof CoreError ? e : CoreError.invalid(String(e))),
    });
  inner.stations.also.push({
    read: (address) => Effect.ignore(views.carry(address)),
    event: (address, name, data) => {
      if (name === "progress" && get(data, "workspace") === ofAddress(address)) views.enqueue(address);
    },
    // (a stream come back resumed is told again the `progress` it missed: asked only what it is owed)
    resumed: (address) => Effect.suspend(() => (views.owedTo(address) ? Effect.ignore(views.carry(address)) : Effect.void)),
  });
  return views;
}
