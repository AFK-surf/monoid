// How a person's agents are asked for progress (进度汇报): the one rule of the station (station/src/api/routes/progress.ts)
// and the core (views/progress.ts), as preset-records.ts is for presets. A person has one, the same on all their devices,
// in every workspace of theirs and on every station of those, carried by their own devices; it goes for every chat they
// started. Pure.
import { RecordRefusal, canonical } from "./preset-records.ts";

/// `minutes`: how long an agent that waits on its own work may post nothing before it is told so. `strength`: told to
/// post an update (`require`), or to post one where there is something to say (`remind`).
export type ProgressChoice = { minutes: number; strength: "require" | "remind" };

/// A choice as kept: `at` when it was changed, `rev` that too but always past the one it changed: the
/// last change wins, though a device made it before it heard of others.
export type ProgressPrefs = ProgressChoice & { rev: number; at: number };

export const PROGRESS_DEFAULT: ProgressChoice = Object.freeze({ minutes: 10, strength: "require" });

/// What the settings offer.
export const PROGRESS_MINUTES = [5, 10, 20, 30, 60];
/// The shortest an interval may be: what is silent for less is told nothing, whoever started it.
export const MINUTES_LEAST = 5;
const MINUTES_MOST = 24 * 60;

const count = (v: unknown, least: number): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= least;

/// A choice as a device or a station says it, checked: throws a RecordRefusal saying what is wrong.
export function progressOf(raw: unknown): ProgressPrefs {
  const v = raw as Partial<ProgressPrefs> | null | undefined;
  if (v === null || typeof v !== "object") throw new RecordRefusal("progress: {minutes, strength, rev, at}");
  if (!count(v.minutes, MINUTES_LEAST) || v.minutes > MINUTES_MOST) throw new RecordRefusal(`progress: minutes is ${MINUTES_LEAST} to ${MINUTES_MOST}`);
  if (v.strength !== "require" && v.strength !== "remind") throw new RecordRefusal("progress: strength is require or remind");
  if (!count(v.rev, 1) || !count(v.at, 0)) throw new RecordRefusal("progress: rev and at are whole numbers");
  return { minutes: v.minutes, strength: v.strength, rev: v.rev, at: v.at };
}

/// The newer of two: the higher `rev`, then the later `at`, then one order for all.
export function newerProgress(a: ProgressPrefs, b: ProgressPrefs): ProgressPrefs {
  if (a.rev !== b.rev) return a.rev > b.rev ? a : b;
  if (a.at !== b.at) return a.at > b.at ? a : b;
  return canonical(a) >= canonical(b) ? a : b;
}
