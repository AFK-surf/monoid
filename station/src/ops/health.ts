// How the running station's process is, as it says it itself, for `stillfail status` (cli.ts) on this machine:
// <data>/run/health.json, written by the process serving every HELD_EVERY_MS from its main thread's loop (main.ts) and
// as what it says changes. Written there, it is fresh only while that loop runs: a process whose thread is held writes
// nothing, and what it wrote last grows old (HEALTH_FRESH_MS), which is how a hung station is told from one that serves.
// What presence.json says (the cloud's socket) is not enough: a station whose link to its front is gone, or whose main
// thread is held, stays "online" there.
import { rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

/// The endpoint as this process has it: bound by itself (`direct`), the front's and linked to it (`ok`), or the front's
/// and linking to it again (`reconnecting`: the front ended, or the link went; devices cannot reach the station).
export type FrontLink = "ok" | "reconnecting" | "direct";

export type Health = {
  /// The process that wrote it (Node's; station.json names the launcher's).
  pid: number;
  /// When, ms since the epoch (the machine's clock: read by another process).
  updatedAt: number;
  /// The longest its main thread was held in the window before (ms).
  heldMaxMs: number;
  front: FrontLink;
  /// Whether it hears the cloud on its presence socket.
  presenceOnline: boolean;
  /// Whether a relay holds its endpoint inactive for another of its id (mesh/native.ts `relayConflict`): another
  /// station on its key. None from a release from before it said it.
  relayConflict?: boolean;
  /// Its open file descriptors (handles on Windows), and its resident memory in bytes, where the system says them: a
  /// leak or a drift seen from outside. None from a release from before it said them, or where it could not read them.
  openFds?: number;
  rssBytes?: number;
};

/// What written longer ago than this is taken for the word of a process that no longer runs its loop: some six windows
/// (main.ts HELD_EVERY_MS), well short of the launcher's limit (native/launcher `heartbeat`, 90 s), after which it is
/// killed and started again.
export const HEALTH_FRESH_MS = 60_000;

export const healthPath = (data: string) => join(data, "run", "health.json");

/// Written whole: to a file of this process's own beside it, then renamed into place (a reader never sees half of it).
export async function writeHealth(data: string, health: Health): Promise<void> {
  const path = healthPath(data);
  const own = `${path}.${health.pid}`;
  await writeFile(own, JSON.stringify(health) + "\n", { mode: 0o600 });
  await rename(own, path);
}

/// What it says, where it reads as such.
export function healthOf(text: unknown): Health | null {
  const h = text as Partial<Health> | null;
  if (h === null || typeof h !== "object") return null;
  if (!Number.isInteger(h.pid) || typeof h.updatedAt !== "number" || !["ok", "reconnecting", "direct"].includes(h.front as string)) return null;
  return { pid: h.pid!, updatedAt: h.updatedAt, heldMaxMs: typeof h.heldMaxMs === "number" ? h.heldMaxMs : 0, front: h.front!, presenceOnline: h.presenceOnline === true, ...(h.relayConflict === true ? { relayConflict: true } : {}), ...(Number.isInteger(h.openFds) && h.openFds! >= 0 ? { openFds: h.openFds } : {}), ...(typeof h.rssBytes === "number" && Number.isFinite(h.rssBytes) && h.rssBytes >= 0 ? { rssBytes: h.rssBytes } : {}) };
}

/// How the station works, for `stillfail status`: from whether it runs (station.json's launcher there), what its process
/// said last of itself (`health`: none from a release from before it said it, or not yet), whether that process is
/// still there (one that ended said it last: a handover's, a crash's; what the one after says is not known yet), and
/// the presence socket's word (presence.json).
export type Working =
  | { is: "stopped" }
  /// Its process there, but its main thread said nothing for `silentMs`.
  | { is: "unresponsive"; silentMs: number }
  | { is: "front" }
  /// Another station (another machine with a copy of its data, or a second process here, a front left from before)
  /// connects with its key: the cloud takes each one's presence socket in turn (presence.ts `Replaced`), or a relay
  /// holds its endpoint inactive for the other's (health.json's `relayConflict`), so devices reach the other one.
  | { is: "conflict" }
  | { is: "offline" }
  | { is: "normal" };

export function workingOf(i: { running: boolean; health: Health | null; healthAlive: boolean; online: boolean; conflict?: boolean; now: number }): Working {
  if (!i.running) return { is: "stopped" };
  const h = i.health;
  if (h !== null && i.healthAlive) {
    const silentMs = i.now - h.updatedAt;
    if (silentMs > HEALTH_FRESH_MS) return { is: "unresponsive", silentMs };
    if (h.front === "reconnecting") return { is: "front" };
    if (h.relayConflict === true) return { is: "conflict" };
  }
  // (the cloud's word: its presence socket replaced again and again, cloud/presence.ts `Replaced`)
  if (i.conflict === true) return { is: "conflict" };
  if (!i.online) return { is: "offline" };
  return { is: "normal" };
}
