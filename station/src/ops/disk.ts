// The disk of the station's data running low, in two steps (agents.ts `relieving`). Every DISK_EVERY_MS it is looked at;
// under the soft mark (`diskSoft`: DISK_SOFT_BYTES, or a tenth of the disk where that is more) every DISK_SOFT_EVERY_MS,
// and what is made again when asked for goes first: thumbnails, half-done downloads, old copies of the config,
// readings of transcripts gone (ops/storage.ts `Upkeep.renewables`), then the mirrors of other stations' tasks not in use
// (jobs/remote.ts `relieve`). Under the low mark (`diskLow`: DISK_LOW_BYTES, or a tenth of the disk where that is less),
// a full reclamation pass runs (throttled to once per RELIEVE_FULL_EVERY_MS = 30 min) across all four steps without
// stopping early between steps: idle unarchived rebuildables (1h threshold, sessions/lifecycle.ts `relieveIdleRebuildable`),
// archived workspaces before their time (`relieveArchived`), orphaned UUID transcripts under `<data>` older than 7 days
// (ops/storage.ts `relieveOrphanTranscripts`), and unreferenced shared clones in `<data>/repos` (`relieveRepos`). Only the mirrors went at first: a station, which runs no one's tasks, had
// none, and its 89G disk was down to 2.3G free with 10G of archived workspaces waiting out their week (2026-10-25). And
// only under 20 GiB at all, every five minutes, while remote/sessions grew to 63 GiB in five days (2026-11-15).

import { statfs } from "node:fs/promises";

/// The low mark's most: under it (or a tenth of the disk, where that is less) what can go goes.
export const DISK_LOW_BYTES = 20 * 1024 ** 3;
/// The soft mark's least: under it (or a tenth of the disk, where that is more) the station starts making room.
export const DISK_SOFT_BYTES = 30 * 1024 ** 3;
/// How often the station looks at its free space.
export const DISK_EVERY_MS = 5 * 60_000;
/// How often while under the soft mark.
export const DISK_SOFT_EVERY_MS = 30_000;

/// The bytes free for the station on the disk holding `path`.
export async function diskFree(path: string): Promise<number> {
  const st = await statfs(path);
  return st.bavail * st.bsize;
}

/// The low mark of a disk of `total` bytes: a disk of less than 200 GiB is low under a tenth of it, not under 20 GiB,
/// which on a small disk would be low (archived workspaces emptied early) all the time.
export const diskLow = (total: number): number => Math.min(DISK_LOW_BYTES, total / 10);

/// The soft mark of a disk of `total` bytes.
export const diskSoft = (total: number): number => Math.max(DISK_SOFT_BYTES, total / 10);

/// Where a disk with `free` of `total` bytes free stands: well, under the soft mark, or low.
export function diskTier(free: number, total: number): "ok" | "soft" | "low" {
  if (free < diskLow(total)) return "low";
  return free < diskSoft(total) ? "soft" : "ok";
}

/// How long until the disk is looked at again, as it stands.
export const diskEvery = (tier: "ok" | "soft" | "low"): number => (tier === "ok" ? DISK_EVERY_MS : DISK_SOFT_EVERY_MS);
