// How busy a station is when new chats are assigned automatically (the app's 自动分配, client/core-ts src/choose.ts
// `#pickBest`; a connect's new conversations, station/src/connects/workspace.ts): its agents running and its CPU, so a
// machine with few agents but held full by builds, jobs or tasks is not where the next chat goes. Read by the station
// and the core: nothing else here, so the core takes this file as it is.

/// A station whose CPUs are this busy (0–1), or whose 1-minute load per core is this high, is full: it is chosen only
/// when every station is.
export const CPU_FULL = 0.9;
export const LOAD_PER_CORE_FULL = 1.5;

/// What a station tells of itself: agents running, how busy its CPUs are (0–1; null: not told, an older station), its
/// 1-minute load per core (null: not told).
export type Busy = { agents: number; cpu: number | null; loadPerCore?: number | null };

const finite = (x: number | null | undefined): number | null => (typeof x === "number" && Number.isFinite(x) ? x : null);

/// Whether it is full (`CPU_FULL`, `LOAD_PER_CORE_FULL`).
export function full(b: Busy): boolean {
  const cpu = finite(b.cpu);
  const load = finite(b.loadPerCore);
  return (cpu !== null && cpu >= CPU_FULL) || (load !== null && load >= LOAD_PER_CORE_FULL);
}

/// Its weight, a whole number so that stations alike tie and the callers' own order (least recently chosen, more memory
/// free, in turn) decides between them: an agent running counts one, each quarter of its CPUs busy one more.
export function weight(b: Busy): number {
  const agents = Math.max(0, finite(b.agents) ?? 0);
  const cpu = Math.min(Math.max(finite(b.cpu) ?? 0, 0), 1);
  return agents + Math.round(cpu * 4);
}

/// Less busy first: stations not full before full ones, then by `weight`; 0 for a tie.
export function lessBusy(a: Busy, b: Busy): number {
  const fa = full(a);
  const fb = full(b);
  if (fa !== fb) return fa ? 1 : -1;
  return weight(a) - weight(b);
}
