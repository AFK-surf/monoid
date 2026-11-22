// A person's drafts of 待派发 (the board's tasks not started yet) as their devices carry them between the stations of a
// workspace, the same on all their devices: one rule for the station (station/src/sessions/board-drafts.ts) and the
// core (views/board-drafts.ts), as preset-records.ts is for presets. A device reads each station's, keeps the newer of
// each draft and brings a station what it lacks; the stations never bring them level with each other. A draft counts
// its changes (`rev`, the higher wins) and a deletion is a record of its own (`gone`), so a station that was off does
// not bring a started or deleted draft back. Pure, and run by Hermes too (no `Intl`, no `toSorted`).
import { canonical } from "./preset-records.ts";

/// A picture or file of a draft: its id (the composer's), its name and size; its bytes are kept by the draft's station
/// (`station`) once a device of its person's brought them (GET /board/drafts `files`).
export type DraftFile = { id: string; name: string; size: number };

/// A draft as kept and carried. `owner`: the `sub` of the person it is of; `rev`: how many times it was changed, from
/// 1; `at`: when it was written (the order 待派发 shows them in, the newest first); `station`, `stationName`: where it is
/// to run, and that station's name as it was chosen.
export type DraftRecord = {
  id: string;
  owner: string;
  rev: number;
  at: number;
  updatedAt: number;
  title: string;
  station: string;
  stationName: string;
  files: DraftFile[];
};

/// A draft started or deleted: nothing else of it kept.
export type GoneDraft = { id: string; owner: string; rev: number; gone: true; updatedAt: number };

export type KeptDraft = DraftRecord | GoneDraft;

export const isGoneDraft = (r: KeptDraft): r is GoneDraft => (r as GoneDraft).gone === true;

/// A person keeps so many drafts in a workspace at most (the newest by `at`), as 待派发 kept on a device before; so many
/// deletions (the latest), so long a title, so many files a draft.
export const DRAFTS_MOST = 200;
export const GONE_DRAFTS_MOST = 200;
export const TITLE_MOST = 4000;
export const DRAFT_FILES_MOST = 20;
/// A draft's id and a file's (`new:board-…` as the app makes them), a name, an address: so long at most.
const ID = /^[A-Za-z0-9:_.-]{1,120}$/;
const NAME_MOST = 200;
const WHO_MOST = 320;

/// Why a draft is not taken: what is wrong with it.
export class DraftRefusal extends Error {}

const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const count = (v: unknown, least: number): boolean => typeof v === "number" && Number.isSafeInteger(v) && v >= least;

/// The newer of two records of one draft: the higher `rev`; of the same, the deleted one; then the later `updatedAt`;
/// then the larger as canonical text. A total order: keepers holding the same records choose the same one whatever
/// order they came in.
export function newerDraft<T extends KeptDraft>(a: T, b: T): T {
  if (a.rev !== b.rev) return a.rev > b.rev ? a : b;
  const ga = isGoneDraft(a);
  if (ga !== isGoneDraft(b)) return ga ? a : b;
  if (a.updatedAt !== b.updatedAt) return a.updatedAt > b.updatedAt ? a : b;
  return canonical(a) >= canonical(b) ? a : b;
}

/// A draft as a device or a station says it, checked and made what both sides keep: its title trimmed, its files each
/// named once, its keys in one order. The same record made of what it makes. Throws a DraftRefusal saying what is wrong.
export function draftOf(raw: unknown): KeptDraft {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) throw new DraftRefusal("a draft is an object");
  const o = raw as Record<string, unknown>;
  const id = str(o.id);
  if (id === null || !ID.test(id)) throw new DraftRefusal("id: 1 to 120 letters, digits, :, ., - or _");
  const owner = str(o.owner);
  if (owner === null || owner === "" || owner.length > WHO_MOST) throw new DraftRefusal("owner: the sub of the person it is of");
  if (!count(o.rev, 1)) throw new DraftRefusal("rev: how many times it was changed, from 1");
  if (!count(o.updatedAt, 0)) throw new DraftRefusal("updatedAt: a time in ms");
  const rev = o.rev as number;
  const updatedAt = o.updatedAt as number;
  if (o.gone === true) return { id, owner, rev, gone: true, updatedAt };
  if (!count(o.at, 0)) throw new DraftRefusal("at: when it was written, in ms");
  const given = o.files === undefined || o.files === null ? [] : o.files;
  if (!Array.isArray(given)) throw new DraftRefusal("files: a list of files");
  const files: DraftFile[] = [];
  for (const f of given) {
    const fid = str((f as { id?: unknown } | null)?.id);
    if (fid === null || !ID.test(fid)) throw new DraftRefusal("a file needs an id");
    const name = str((f as { name?: unknown }).name);
    if (name === null || name === "" || name.length > NAME_MOST) throw new DraftRefusal(`file ${fid}: a name, ${NAME_MOST} characters at most`);
    const size = (f as { size?: unknown }).size ?? 0;
    if (!count(size, 0)) throw new DraftRefusal(`file ${fid}: size, in bytes`);
    if (!files.some((x) => x.id === fid)) files.push({ id: fid, name, size: size as number });
  }
  if (files.length > DRAFT_FILES_MOST) throw new DraftRefusal(`a draft has ${DRAFT_FILES_MOST} files at most`);
  const title = (str(o.title) ?? "").trim();
  if (title.length > TITLE_MOST) throw new DraftRefusal("its words are too long");
  if (title === "" && files.length === 0) throw new DraftRefusal("a draft needs words or a file");
  const station = str(o.station);
  if (station === null || station === "" || station.length > NAME_MOST) throw new DraftRefusal("station: the address of the station it is to run on");
  const stationName = str(o.stationName) ?? "";
  if (stationName.length > NAME_MOST) throw new DraftRefusal("stationName is too long");
  return { id, owner, rev, at: o.at as number, updatedAt, title, station, stationName, files };
}

/// What a device or a station said of drafts, each checked; one that does not check left out.
export function draftsOf(raw: unknown): KeptDraft[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((r) => {
    try {
      return [draftOf(r)];
    } catch {
      return [];
    }
  });
}

/// `given` merged into `kept` (by id), the newer of each kept; then past DRAFTS_MOST the oldest drafts by `at` go (as
/// a deletion of their own each, so that they are not brought back), and past GONE_DRAFTS_MOST the deletions longest
/// gone (the same whatever order they came in); `kept` itself where nothing changed.
export function mergeDrafts(kept: Record<string, KeptDraft>, given: readonly KeptDraft[]): Record<string, KeptDraft> {
  let all: Record<string, KeptDraft> | null = null;
  for (const r of given) {
    const was = (all ?? kept)[r.id];
    if (was !== undefined && (newerDraft(was, r) === was || canonical(was) === canonical(r))) continue;
    all ??= { ...kept };
    all[r.id] = r;
  }
  const now = all ?? kept;
  const ids = Object.keys(now);
  const live = ids.filter((id) => !isGoneDraft(now[id]!)) as string[];
  let out: Record<string, KeptDraft> | null = all;
  if (live.length > DRAFTS_MOST) {
    const order = (a: string, b: string) => (now[b] as DraftRecord).at - (now[a] as DraftRecord).at || (a < b ? -1 : a > b ? 1 : 0);
    out ??= { ...now };
    for (const id of [...live].sort(order).slice(DRAFTS_MOST)) {
      const d = now[id] as DraftRecord;
      out[id] = { id, owner: d.owner, rev: d.rev + 1, gone: true, updatedAt: d.updatedAt };
    }
  }
  const held = out ?? now;
  const gone = Object.keys(held).filter((id) => isGoneDraft(held[id]!));
  if (gone.length > GONE_DRAFTS_MOST) {
    const order = (a: string, b: string) => held[b]!.updatedAt - held[a]!.updatedAt || held[b]!.rev - held[a]!.rev || (a < b ? -1 : a > b ? 1 : 0);
    const going = new Set([...gone].sort(order).slice(GONE_DRAFTS_MOST));
    out = Object.fromEntries(Object.entries(held).filter(([id]) => !going.has(id)));
  }
  return out ?? kept;
}

/// Of `drafts`, those a station holding `said` (by id) lacks or holds older: what it is brought, and only that.
export function draftsLacking(drafts: Record<string, KeptDraft>, said: Record<string, KeptDraft>): KeptDraft[] {
  return Object.values(drafts).filter((r) => {
    const there = said[r.id];
    return there === undefined || (newerDraft(there, r) === r && canonical(there) !== canonical(r));
  });
}

/// The drafts not started, the newest first (by `at`, then by id).
export function liveDrafts(drafts: Record<string, KeptDraft>): DraftRecord[] {
  return Object.values(drafts)
    .filter((r): r is DraftRecord => !isGoneDraft(r))
    .sort((a, b) => b.at - a.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}
