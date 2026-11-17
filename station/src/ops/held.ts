// Whether another station process runs this data directory, for a process started with no launcher (`main.js run` from
// a checkout, a script): the launcher's lock (native/launcher run.rs, run/station.lock) is not taken then, and the
// loopback port falls back to a free one where 4760 is taken (main.ts Loopback), so nothing else stops a second whole
// station beside the first, both on its key (2026-11-16). The launcher's pid (run/station.json) and the process holding
// the sessions (run/hub.json) say who runs it; one of them still there is the station running.
import { readFileSync } from "node:fs";
import { join } from "node:path";

/// `run`'s exit when another station runs the data directory: the launcher's (native/launcher main.rs `HELD`), which
/// the desktop app reads.
export const HELD = 3;

/// Whether `pid` is there and this user's (signal 0 only asks; another user's is no station of this data directory).
function there(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/// The pid of another process running the station of `data`, or null.
export function heldBy(data: string, self = process.pid, alive: (pid: number) => boolean = there): number | null {
  for (const name of ["station.json", "hub.json"]) {
    let pid: unknown = null;
    try {
      pid = JSON.parse(readFileSync(join(data, "run", name), "utf8")).pid; // sync: before it serves (before anything is made)
    } catch {}
    if (typeof pid === "number" && Number.isSafeInteger(pid) && pid > 0 && pid !== self && alive(pid)) return pid;
  }
  return null;
}
