// Persistent state for periodic station upkeep (`<data>/upkeep-state.json`), shared between Upkeep and Hub
// (and byte-compatible with the MoonBit station). Survives frequent restarts so idle rebuildable scanning
// advances across restarts and daily-once tasks do not re-run on every restart.
import { readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

export const UPKEEP_STATE_FILE = "upkeep-state.json";
export const IDLE_MEASURED_MAX = 4096;

export type UpkeepState = {
  idleMeasured: Record<string, number>;
  lastRepoBranchesAt: number | null;
  lastOrphanRoomsAt: number | null;
  lastFullRelieveAt: number | null;
  lastArchiveUpkeepAt: number | null;
};

export type UpkeepStatePatch = Partial<UpkeepState>;

export function emptyUpkeepState(): UpkeepState {
  return {
    idleMeasured: {},
    lastRepoBranchesAt: null,
    lastOrphanRoomsAt: null,
    lastFullRelieveAt: null,
    lastArchiveUpkeepAt: null,
  };
}

function finiteNumberOrNull(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

function normalizeIdleMeasured(raw: unknown): Record<string, number> {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return {};
  const entries: [string, number][] = [];
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v === "number" && Number.isFinite(v)) entries.push([k, v]);
  }
  const trimmed = entries.length > IDLE_MEASURED_MAX ? entries.slice(entries.length - IDLE_MEASURED_MAX) : entries;
  const out: Record<string, number> = {};
  for (const [k, v] of trimmed) out[k] = v;
  return out;
}

export function parseUpkeepState(text: string): UpkeepState {
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return emptyUpkeepState();
    const obj = parsed as Record<string, unknown>;
    return {
      idleMeasured: normalizeIdleMeasured(obj.idleMeasured),
      lastRepoBranchesAt: finiteNumberOrNull(obj.lastRepoBranchesAt),
      lastOrphanRoomsAt: finiteNumberOrNull(obj.lastOrphanRoomsAt),
      lastFullRelieveAt: finiteNumberOrNull(obj.lastFullRelieveAt),
      lastArchiveUpkeepAt: finiteNumberOrNull(obj.lastArchiveUpkeepAt),
    };
  } catch {
    return emptyUpkeepState();
  }
}

export async function readUpkeepState(dataDir: string): Promise<UpkeepState> {
  const path = join(dataDir, UPKEEP_STATE_FILE);
  try {
    return parseUpkeepState(await readFile(path, "utf8"));
  } catch {
    return emptyUpkeepState();
  }
}

function sameIdleMeasured(a: Record<string, number>, b: Record<string, number>): boolean {
  const ak = Object.keys(a);
  const bk = Object.keys(b);
  if (ak.length !== bk.length) return false;
  for (let i = 0; i < ak.length; i++) {
    const k = ak[i]!;
    if (bk[i] !== k || a[k] !== b[k]) return false;
  }
  return true;
}

function sameUpkeepState(a: UpkeepState, b: UpkeepState): boolean {
  return (
    a.lastRepoBranchesAt === b.lastRepoBranchesAt &&
    a.lastOrphanRoomsAt === b.lastOrphanRoomsAt &&
    a.lastFullRelieveAt === b.lastFullRelieveAt &&
    a.lastArchiveUpkeepAt === b.lastArchiveUpkeepAt &&
    sameIdleMeasured(a.idleMeasured, b.idleMeasured)
  );
}

const queues = new Map<string, Promise<unknown>>();

function serialize<T>(key: string, f: () => Promise<T>): Promise<T> {
  const prev = queues.get(key) ?? Promise.resolve();
  const next = prev.catch(() => undefined).then(f);
  queues.set(key, next);
  void next.finally(() => {
    if (queues.get(key) === next) queues.delete(key);
  });
  return next;
}

/// Merges `patch` into `<data>/upkeep-state.json` atomically (temp file + rename), writing only when the state
/// actually changed. Returns whether a write occurred.
export function patchUpkeepState(dataDir: string, patch: UpkeepStatePatch): Promise<boolean> {
  const path = join(dataDir, UPKEEP_STATE_FILE);
  return serialize(path, async () => {
    const current = await readUpkeepState(dataDir);
    const next: UpkeepState = {
      idleMeasured: patch.idleMeasured !== undefined ? normalizeIdleMeasured(patch.idleMeasured) : current.idleMeasured,
      lastRepoBranchesAt: patch.lastRepoBranchesAt !== undefined ? finiteNumberOrNull(patch.lastRepoBranchesAt) : current.lastRepoBranchesAt,
      lastOrphanRoomsAt: patch.lastOrphanRoomsAt !== undefined ? finiteNumberOrNull(patch.lastOrphanRoomsAt) : current.lastOrphanRoomsAt,
      lastFullRelieveAt: patch.lastFullRelieveAt !== undefined ? finiteNumberOrNull(patch.lastFullRelieveAt) : current.lastFullRelieveAt,
      lastArchiveUpkeepAt: patch.lastArchiveUpkeepAt !== undefined ? finiteNumberOrNull(patch.lastArchiveUpkeepAt) : current.lastArchiveUpkeepAt,
    };
    if (sameUpkeepState(current, next)) return false;
    const tmp = `${path}.tmp`;
    try {
      await writeFile(tmp, JSON.stringify(next), { mode: 0o600 });
      await rename(tmp, path);
      return true;
    } catch {
      await rm(tmp, { force: true }).catch(() => undefined);
      return false;
    }
  });
}
