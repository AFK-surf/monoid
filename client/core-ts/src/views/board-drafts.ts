// A person's drafts of 待派发 (the board's tasks not started yet), the same on all their devices: kept by every station
// of the workspace and carried by their own devices, as their presets are (views/presets.ts; the rule both sides keep
// is board-drafts.ts, the station's side station/src/sessions/board-drafts.ts). The device keeps its person's records
// of each workspace (`boardDrafts`, in the workspace's database), each change made here at once (`board.drafts`: the
// list as the board has it now, a draft new, changed, or gone, one `rev` more) and carried: as a station's link opens,
// as it tells `boardDrafts`, as a stream comes back owed one, and as something changes here. It reads the station's
// (GET /board/drafts), keeps the newer of each and brings it only what it lacks or holds older (PUT /board/drafts).
// Never on a timer. Drafts kept on this device before (the prefs' `boardDrafts`) are taken in once as theirs.
//
// A draft's pictures and files are kept by the station it is to run on: the device that has them (its composer, the
// draft's `new:<workspace>:board:<id>`) puts each up there (POST /uploads, then POST /board/files), so that another
// device of theirs shows it (`picture`, GET /board/files) and starting it there sends it (`held`, `stage`: POST
// /board/stage gives the message the file as an upload).
import { Effect } from "effect";
import type { Inner } from "../core.ts";
import type { Call } from "../core/calls.ts";
import { handlers } from "../core/execute.ts";
import type { Owner } from "../core/routing.ts";
import { CoreError } from "../error.ts";
import { t } from "../i18n.ts";
import { type DraftFile, type DraftRecord, type KeptDraft, draftOf, draftsLacking, draftsOf, isGoneDraft, liveDrafts, mergeDrafts } from "../board-drafts.ts";
import { canonical } from "../preset-records.ts";
import type { Topic } from "../protocol.ts";
import { Marks } from "../reactive.ts";
import { StationAddr } from "../station/addr.ts";
import type { Value } from "../store.ts";
import { Priority } from "../sync/scheduler.ts";
import { arr as arrU, get, isObject } from "../util.ts";
import { ofAddress } from "../workspace.ts";
import { fromBeforeRoute, whoIn } from "./presets.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const arr = (v: unknown): J[] => arrU(v) ?? [];

type Of = Extract<Call, { kind: "boardDrafts" }>;

export const TABLE = "boardDrafts";

/// What the device keeps of a workspace: its person's drafts by id (deleted ones too); the ids of its stations owed a
/// carry (one passed by while not reached, one whose read or PUT failed) and of those read at least once (`met`); the
/// files each station said it keeps, by its id; whether the drafts kept on the device before were taken in (`took`).
export type Held = { drafts: Record<string, KeptDraft>; owed: string[]; met: string[]; files: Record<string, string[]>; took: boolean };

const NOTHING = Object.freeze([]) as unknown as string[];
const NONE: Held = Object.freeze({ drafts: Object.freeze({}) as Record<string, KeptDraft>, owed: NOTHING, met: NOTHING, files: Object.freeze({}) as Record<string, string[]>, took: false });
const ids = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

export function heldOf(data: { record(table: string, key: string): unknown }, ws: string): Held {
  const raw = data.record(TABLE, ws);
  if (!isObject(raw)) return NONE;
  const files: Record<string, string[]> = {};
  if (isObject(raw.files)) for (const [k, v] of Object.entries(raw.files)) files[k] = ids(v);
  return { drafts: isObject(raw.drafts) ? (raw.drafts as Record<string, KeptDraft>) : {}, owed: ids(raw.owed), met: ids(raw.met), files, took: raw.took === true };
}

const stationId = (address: string) => address.slice(address.lastIndexOf("/") + 1);

/// A board draft's composer (sfbase's board_file_key): `new:<workspace>:board:<id>`.
export const draftKey = (ws: string, id: string) => `new:${ws}:board:${id}`;
const keyed = (key: string): { ws: string; id: string } | null => {
  const m = /^new:([^:]+):board:(.+)$/.exec(key);
  return m ? { ws: m[1]!, id: m[2]! } : null;
};

function stationsOf(inner: Inner, ws: string): { id: string; address: string }[] {
  return arr(get(inner.data.shared({ topic: "workspace", workspace: ws }), "stations")).flatMap((s: J) => (typeof get(s, "id") === "string" ? [{ id: s.id as string, address: `${ws}/${s.id}` }] : []));
}

const ask = (inner: Inner, address: string, method: string, path: string, body: unknown = null) =>
  inner.stations.requests.call(inner.stations.link(address)?.addr ?? StationAddr.parse(address), method, path, body, { quiet: true });

const reached = (inner: Inner, address: string) => inner.provider.kind === "stillfail" && inner.stations.link(address) !== undefined && inner.stations.reachable(address);

export class BoardDraftViews implements Owner {
  readonly #inner: Inner;
  readonly #marks = new Marks();
  /// The files of drafts going up now, by id: one at a time.
  readonly #going = new Set<string>();
  /// Pictures read of the drafts' stations here, the latest few, by `<draft>\0<file>`.
  readonly #pictures = new Map<string, { type: string; bytes: Uint8Array }>();

  constructor(inner: Inner) {
    this.#inner = inner;
  }

  owns(topic: Topic): boolean {
    return topic.topic === "boardDrafts";
  }

  start(topic: Topic): void {
    this.#takeKept(String(topic.scope));
  }

  compute(topic: Topic): Value | undefined {
    const ws = String(topic.scope);
    this.#marks.read(ws);
    const who = whoIn(this.#inner, ws);
    if (who === null) return { ok: { drafts: [] } };
    const drafts = liveDrafts(heldOf(this.#inner.data, ws).drafts)
      .filter((d) => d.owner === who.sub)
      .map((d) => ({ id: d.id, title: d.title, station: d.station, stationName: d.stationName, ...(d.files.length > 0 ? { files: d.files.map((f) => ({ id: f.id, name: f.name })) } : {}) }));
    return { ok: { drafts } };
  }

  #write(ws: string, held: Held): void {
    this.#inner.data.put(TABLE, ws, held);
    this.#marks.touch(ws);
  }

  #mark(ws: string, key: "owed" | "met", id: string, on: boolean): void {
    const held = heldOf(this.#inner.data, ws);
    if (held[key].includes(id) === on) return;
    this.#write(ws, { ...held, [key]: on ? [...held[key], id] : held[key].filter((x) => x !== id) });
  }

  /// Whether station `address` is owed a carry, or was never read here.
  owedTo(address: string): boolean {
    const held = heldOf(this.#inner.data, ofAddress(address));
    const id = stationId(address);
    return held.owed.includes(id) || !held.met.includes(id);
  }

  /// The drafts kept on this device before (the prefs' `boardDrafts` of `ws`) taken in as its person's, once, and
  /// left out of the prefs.
  #takeKept(ws: string): void {
    const inner = this.#inner;
    const held = heldOf(inner.data, ws);
    if (held.took) return;
    const who = whoIn(inner, ws);
    if (who === null) return;
    const prefs = inner.data.shared({ topic: "prefs" });
    const before = arr(get(get(prefs, "boardDrafts"), ws));
    const now = inner.host.nowMs();
    const given = before.flatMap((d: J, i: number) => {
      try {
        return [draftOf({ ...d, owner: who.sub, rev: 1, at: now - i, updatedAt: now })];
      } catch {
        return [];
      }
    });
    this.#write(ws, { ...held, drafts: mergeDrafts(held.drafts, given), took: true });
    if (before.length > 0 && isObject(prefs) && isObject(prefs.boardDrafts)) {
      const { [ws]: _, ...rest } = prefs.boardDrafts as Record<string, unknown>;
      inner.data.set({ topic: "prefs" }, { ...prefs, boardDrafts: rest }, false);
    }
    if (given.length > 0) this.carryAll(ws);
  }

  /// `given` (a station's, each checked) taken where newer: kept, and what it made gone here let go of.
  #take(ws: string, given: readonly KeptDraft[], sub: string): boolean {
    const held = heldOf(this.#inner.data, ws);
    const drafts = mergeDrafts(held.drafts, given.filter((r) => r.owner === sub));
    if (drafts === held.drafts) return false;
    this.#write(ws, { ...held, drafts });
    // (started or deleted on another device: what this one held of it let go of)
    for (const [id, was] of Object.entries(held.drafts)) {
      const now = drafts[id];
      if (isGoneDraft(was) || (now !== undefined && !isGoneDraft(now))) continue;
      for (const f of was.files) this.#inner.composers.remove(draftKey(ws, id), f.id);
    }
    return true;
  }

  /// The person's drafts carried to station `address`: its own read and the newer of each kept, then brought what it
  /// lacks or holds older; then the files of drafts to run there that this device holds and it does not, put up.
  carry(address: string): Effect.Effect<void, CoreError> {
    const self = this;
    const inner = this.#inner;
    return Effect.gen(function* () {
      if (!reached(inner, address)) return;
      const ws = ofAddress(address);
      const who = whoIn(inner, ws);
      if (who === null) return;
      self.#takeKept(ws);
      const id = stationId(address);
      const said = yield* Effect.result(ask(inner, address, "GET", "/board/drafts"));
      if (said._tag === "Failure") {
        // (one from before keeps none: owed nothing)
        const before = fromBeforeRoute(said.failure);
        if (before) self.#mark(ws, "met", id, true);
        return self.#mark(ws, "owed", id, !before);
      }
      self.#mark(ws, "met", id, true);
      const there = draftsOf(get(said.success, "drafts"));
      self.#files(ws, id, get(said.success, "files"));
      if (self.#take(ws, there, who.sub)) self.carryAll(ws, address);
      const byId: Record<string, KeptDraft> = {};
      for (const r of there) byId[r.id] = r;
      const bring = draftsLacking(heldOf(inner.data, ws).drafts, byId).filter((r) => r.owner === who.sub);
      if (bring.length > 0) {
        const put = yield* Effect.result(ask(inner, address, "PUT", "/board/drafts", { drafts: bring }));
        if (put._tag === "Failure") return self.#mark(ws, "owed", id, true);
        self.#take(ws, draftsOf(get(put.success, "drafts")), who.sub);
        self.#files(ws, id, get(put.success, "files"));
      }
      self.#mark(ws, "owed", id, false);
      yield* self.#putUp(ws, address);
    });
  }

  #files(ws: string, station: string, said: unknown): void {
    const held = heldOf(this.#inner.data, ws);
    const files = ids(said);
    if (canonical(held.files[station] ?? []) === canonical(files)) return;
    this.#write(ws, { ...held, files: { ...held.files, [station]: files } });
  }

  /// The files of the person's drafts to run on `address` that it does not keep and this device holds, put up there.
  #putUp(ws: string, address: string): Effect.Effect<void, CoreError> {
    const self = this;
    const inner = this.#inner;
    return Effect.gen(function* () {
      const station = stationId(address);
      const addr = inner.stations.link(address)?.addr ?? StationAddr.parse(address);
      for (const d of liveDrafts(heldOf(inner.data, ws).drafts)) {
        if (d.station !== address) continue;
        for (const f of d.files) {
          if ((heldOf(inner.data, ws).files[station] ?? []).includes(f.id) || self.#going.has(f.id)) continue;
          const bytes = yield* Effect.promise(() => inner.composers.bytesOf(f.id));
          if (bytes === null) continue;
          self.#going.add(f.id);
          const went = yield* Effect.result(
            Effect.gen(function* () {
              const saved = yield* inner.stations.requests.upload(addr, f.name, bytes, null);
              const path = get(saved, "path");
              if (typeof path !== "string") return;
              const kept = yield* ask(inner, address, "POST", "/board/files", { draft: d.id, file: f.id, path });
              self.#files(ws, station, get(kept, "files"));
            }),
          );
          self.#going.delete(f.id);
          if (went._tag === "Failure") self.#mark(ws, "owed", station, true);
        }
      }
    });
  }

  /// Everything of the person's carried to every station of `ws` reached now (a change made here, or one a station had
  /// newer); one not reached is owed it.
  carryAll(ws: string, besides: string | null = null): void {
    const inner = this.#inner;
    for (const s of stationsOf(inner, ws)) {
      if (s.address === besides) continue;
      if (!reached(inner, s.address)) {
        this.#mark(ws, "owed", s.id, true);
        continue;
      }
      inner.scheduler.enqueue(s.address, `boardDrafts/${s.address}`, Priority.background, Effect.ignore(this.carry(s.address)));
    }
  }

  /// The board's drafts of `ws` as it has them now (newest first): each new one made, each changed one a change more,
  /// each it no longer has a deletion; kept and carried.
  put(ws: string, given: unknown): void {
    const inner = this.#inner;
    const who = whoIn(inner, ws);
    if (who === null) throw CoreError.invalid(t("core-misc.presets.signedOut"));
    if (!Array.isArray(given)) throw CoreError.invalid(t("core-misc.params.invalid", { error: "drafts" }));
    this.#takeKept(ws);
    const held = heldOf(inner.data, ws);
    const now = inner.host.nowMs();
    const made: KeptDraft[] = [];
    const named = new Set<string>();
    given.forEach((g: J, i: number) => {
      const id = typeof get(g, "id") === "string" ? (g.id as string) : "";
      named.add(id);
      const was = held.drafts[id];
      const live = was !== undefined && !isGoneDraft(was) ? was : null;
      const files: DraftFile[] = arr(get(g, "files")).map((f: J) => {
        const fid = String(get(f, "id") ?? "");
        return { id: fid, name: String(get(f, "name") ?? ""), size: live?.files.find((x) => x.id === fid)?.size ?? inner.composers.sizeHeld(fid) };
      });
      let r: DraftRecord;
      try {
        // (a change more than what is kept of it: its first where none is)
        r = draftOf({ id, owner: who.sub, rev: (was?.rev ?? 0) + 1, at: live?.at ?? now - i, updatedAt: now, title: get(g, "title"), station: get(g, "station"), stationName: get(g, "stationName") ?? "", files }) as DraftRecord;
      } catch (e) {
        throw CoreError.invalid(t("core-misc.params.invalid", { error: `drafts: ${(e as Error).message}` }));
      }
      const unchanged = (x: DraftRecord) => canonical({ ...x, rev: 0, updatedAt: 0 });
      if (live !== null && unchanged(live) === unchanged(r)) return;
      made.push(r);
    });
    for (const [id, was] of Object.entries(held.drafts)) {
      if (isGoneDraft(was) || was.owner !== who.sub || named.has(id)) continue;
      made.push({ id, owner: who.sub, rev: was.rev + 1, gone: true, updatedAt: now });
    }
    if (made.length === 0) return;
    this.#write(ws, { ...held, drafts: mergeDrafts(held.drafts, made) });
    this.carryAll(ws);
  }

  /// The files of the board draft `key` (`new:<workspace>:board:<id>`) this device has none of, kept by its station:
  /// for its composer to send as uploads (`stage`).
  held(key: string): { station: string; files: DraftFile[] } | null {
    const at = keyed(key);
    if (at === null) return null;
    const d = heldOf(this.#inner.data, at.ws).drafts[at.id];
    if (d === undefined || isGoneDraft(d)) return null;
    return { station: d.station, files: d.files };
  }

  /// File `file` of board draft `key` as its station keeps it, copied among its uploads for a message: what POST
  /// /uploads answers.
  stage(key: string, station: string, file: { id: string; name: string }): Effect.Effect<J, CoreError> {
    const at = keyed(key);
    if (at === null) return Effect.fail(new CoreError("upload", t("core-misc.composer.upload_missing", { name: file.name })));
    return Effect.flatMap(ask(this.#inner, station, "POST", "/board/stage", { draft: at.id, file: file.id, name: file.name }), (got) =>
      isObject(got) && typeof got.path === "string" ? Effect.succeed(got as J) : Effect.fail(new CoreError("upload", t("core-misc.composer.upload_missing", { name: file.name }))),
    );
  }

  /// A picture of board draft `key` this device holds no bytes of, as its station keeps it: null where none is.
  picture(key: string, file: string): Effect.Effect<{ type: string; bytes: Uint8Array } | null> {
    const at = keyed(key);
    if (at === null) return Effect.succeed(null);
    const d = heldOf(this.#inner.data, at.ws).drafts[at.id];
    if (d === undefined || isGoneDraft(d) || !d.files.some((f) => f.id === file) || !reached(this.#inner, d.station)) return Effect.succeed(null);
    const kept = this.#pictures.get(`${at.id}\0${file}`);
    if (kept !== undefined) return Effect.succeed(kept);
    const addr = this.#inner.stations.link(d.station)?.addr ?? StationAddr.parse(d.station);
    return Effect.map(Effect.orElseSucceed(this.#inner.stations.requests.boardFile(addr, at.id, file, null), () => null), (got) => {
      if (got === null) return null;
      this.#pictures.set(`${at.id}\0${file}`, got);
      for (const k of this.#pictures.keys()) {
        if (this.#pictures.size <= PICTURES_KEPT) break;
        this.#pictures.delete(k);
      }
      return got;
    });
  }
}

/// So many pictures of drafts read of their stations are kept in memory here (the app keeps those it shows).
const PICTURES_KEPT = 24;

export function install(inner: Inner): BoardDraftViews {
  const views = new BoardDraftViews(inner);
  inner.router.owners.push(views);
  handlers.boardDrafts = (core, call) =>
    Effect.try({
      try: () => {
        const c = call as Of;
        core.boardDrafts.put(c.workspace, c.drafts);
        return { ok: true };
      },
      catch: (e) => (e instanceof CoreError ? e : CoreError.invalid(String(e))),
    });
  inner.stations.also.push({
    read: (address) => Effect.ignore(views.carry(address)),
    event: (address, name, data) => {
      if (name === "boardDrafts" && get(data, "workspace") === ofAddress(address)) inner.scheduler.enqueue(address, `boardDrafts/${address}`, Priority.background, Effect.ignore(views.carry(address)));
    },
    // (a stream come back resumed is told again the `boardDrafts` it missed: asked only what it is owed)
    resumed: (address) => Effect.suspend(() => (views.owedTo(address) ? Effect.ignore(views.carry(address)) : Effect.void)),
  });
  return views;
}
