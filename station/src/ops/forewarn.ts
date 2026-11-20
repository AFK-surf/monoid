// What runs out on the station's machine said before it does: the data directory's disk, the database's log (its WAL,
// held to WAL_CAP by Upkeep's checkpoints: one past twice that is a checkpoint that does not get through), the
// process's descriptors, and a relay saying another endpoint holds this station's key. Looked at with each sample of
// the main thread (main.ts HELD_EVERY_MS), said as each starts and again every SAY_AGAIN_MS while it lasts (a relay's
// conflict once, until it ends); the same numbers in `memory: now`. mb/src/ops_platform/forewarn.mbt is this, line for
// line (station/test/mb-ops-platform.test.ts).
import { readdir, stat, statfs } from "node:fs/promises";
import { join } from "node:path";
import { platform } from "../platform/index.ts";

const MiB = 1_048_576;
/// The data directory's disk is low with less than this free, or less than this share of it.
export const LOW_DISK_BYTES = 2_048 * MiB;
export const LOW_DISK_SHARE = 0.05;
/// The database's log is large past this.
export const LARGE_WAL_BYTES = 256 * MiB;
/// The process holds many descriptors from this many.
export const MANY_FDS = 2_048;
/// What still holds is said again after this.
export const SAY_AGAIN_MS = 10 * 60_000;

/// What is looked at, in bytes (null where the system does not say).
export type Look = { diskFree: number | null; diskTotal: number | null; walBytes: number; openFds: number | null; rss: number | null; relayConflict: boolean };
export type Warning = { at: string; message: string; fields: Record<string, number> };

export const mb = (bytes: number) => Math.round(bytes / MiB);

/// Which of what is looked at holds, each with when it was last said.
export class Forewarn {
  private said = new Map<string, number>();

  /// What to say of `look` at `now` (ms).
  look(look: Look, now: number): Warning[] {
    const out: Warning[] = [];
    const held = (kind: string, on: boolean, again: boolean, warning: () => Warning) => {
      if (!on) {
        this.said.delete(kind);
        return;
      }
      const at = this.said.get(kind);
      if (at !== undefined && (!again || now - at < SAY_AGAIN_MS)) return;
      this.said.set(kind, now);
      out.push(warning());
    };
    const { diskFree: free, diskTotal: total } = look;
    held("disk", free !== null && total !== null && total > 0 && (free < LOW_DISK_BYTES || free < total * LOW_DISK_SHARE), true, () => ({
      at: "station", message: "low disk space on data directory",
      fields: { diskFreeMb: mb(free!), diskTotalMb: mb(total!), freePct: Math.round((free! / total!) * 1000) / 10 },
    }));
    held("wal", look.walBytes > LARGE_WAL_BYTES, true, () => ({ at: "store", message: "database WAL file is large", fields: { walMb: mb(look.walBytes) } }));
    held("fds", look.openFds !== null && look.openFds >= MANY_FDS, true, () => ({
      at: "station", message: "high open file descriptor count",
      fields: { openFds: look.openFds!, ...(look.rss !== null ? { rssMb: mb(look.rss) } : {}) },
    }));
    held("relay", look.relayConflict, false, () => ({ at: "mesh", message: "relay reports another endpoint with this station key", fields: {} }));
    return out;
  }
}

/// This process's open descriptors, where the system lists them (none on Windows): the listing's own one not counted.
async function openFds(): Promise<number | null> {
  const dir = platform.os === "linux" ? "/proc/self/fd" : platform.os === "macos" ? "/dev/fd" : null;
  if (dir === null) return null;
  try {
    return Math.max(0, (await readdir(dir)).length - 1);
  } catch {
    return null;
  }
}

/// What is looked at now, of the data directory `data` (no call waits on the main thread).
export async function lookAt(data: string, relayConflict: boolean): Promise<Look> {
  const [disk, walBytes, fds] = await Promise.all([
    statfs(data).then((s) => ({ free: s.bavail * s.bsize, total: s.blocks * s.bsize }), () => null),
    stat(join(data, "stillfail.db-wal")).then((s) => s.size, () => 0),
    openFds(),
  ]);
  return { diskFree: disk?.free ?? null, diskTotal: disk?.total ?? null, walBytes, openFds: fds, rss: process.memoryUsage.rss(), relayConflict };
}
