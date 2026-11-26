// The index for one workspace of the station's, its home one or one it joined. The old comma-stats.db remains the
// Router's compatibility record; its index has no owner recorded and therefore cannot safely be sent after a station
// is enrolled in a different workspace.
import { CommaStats, type Read, type UnreadRetryOptions } from "./stats.ts";
import type { CommaIndexes } from "./surface.ts";

/// `within`: whether the station is in `workspace` now; `version` moves whenever the station's workspaces change.
export function workspaceIndex(data: string, workspace: string, within: () => boolean, version: () => number,
  read: Read, changes: (changed: (fast?: boolean) => void) => () => void, retry?: UnreadRetryOptions): { stats: CommaStats; indexes: CommaIndexes } {
  const guarded: Read = async (from, to) => {
    const at = version();
    const valid = () => within() && version() === at;
    if (!valid()) return { stations: [], unread: [], valid };
    const result = await read(from, to);
    return { ...result, valid: () => valid() && (result.valid?.() ?? true) };
  };
  const stats = CommaStats.inWorkspace(data, workspace, guarded,
    (changed) => changes((fast) => { if (within()) changed(fast); }), retry);
  let started: number | null = null;
  return {
    stats,
    indexes: {
      stats: stats.stats,
      tasks: stats.tasks,
      start: () => {
        const now = version();
        if (started === null) { started = now; stats.start(); }
        else if (started !== now) { started = now; stats.build(); }
        else stats.rebuildIfUnread();
      },
    },
  };
}
