// What the launcher did to recover while no station could say it (a Node or the front killed as hung, a crash, a
// handover given up): station/native/launcher/src/lifecycle.rs `record` keeps each as a JSON line in
// <data>/run/launcher-events.jsonl, and the station that comes up next says each in its log (so the log upload carries
// it, src/ops/log-export.ts), once: it takes the file for itself first (a rename), so another process does not say them
// again. MoonBit's station does the same (station/mb/src/station_main/launcher_events.mbt).
import { readFile, rename, unlink } from "node:fs/promises";
import { join } from "node:path";
import { log } from "./log.ts";

export type LauncherEventLevel = "error" | "warn";
export type LauncherEventEmit = (level: LauncherEventLevel, message: string, fields: Record<string, unknown>) => void;

/// The fields said of an event: the launcher's numbers and words of its own (no path, nothing a person wrote).
const FIELDS = ["kind", "at", "pid", "version", "how", "uptimeMs", "taken", "failures", "heartbeatTimeoutMs", "misses", "probeMs", "retries", "reason", "exitTimeoutMs", "healthAgeMs", "rssBytes", "openFds", "heldMaxMs", "front", "presenceOnline", "relayConflict"];
const ERRORS = new Set(["node_hung_killed", "node_crashed", "front_hung_killed"]);

/// One line of the file: its level, kind and fields; null for one that is not an event.
export function launcherEventOf(line: string): { level: LauncherEventLevel; kind: string; fields: Record<string, unknown> } | null {
  let event: unknown;
  try {
    event = JSON.parse(line);
  } catch {
    return null;
  }
  if (event === null || typeof event !== "object" || Array.isArray(event)) return null;
  const e = event as Record<string, unknown>;
  if (typeof e.kind !== "string" || e.kind === "") return null;
  const fields: Record<string, unknown> = {};
  for (const name of FIELDS) if (e[name] !== undefined) fields[name] = e[name];
  const level = e.level === "error" || e.level === "warn" ? e.level : ERRORS.has(e.kind) ? "error" : "warn";
  return { level, kind: e.kind, fields };
}

const said: LauncherEventEmit = (level, message, fields) => (level === "error" ? log.error("launcher", message, fields) : log.warn("launcher", message, fields));

/// Says each event the launcher kept (`emit`, the log by default) and removes them: how many.
export async function reportLauncherEvents(data: string, emit: LauncherEventEmit = said): Promise<number> {
  const run = join(data, "run");
  const claimed = join(run, `launcher-events.${process.pid}.jsonl`);
  try {
    await rename(join(run, "launcher-events.jsonl"), claimed);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw e;
  }
  try {
    let n = 0;
    for (const line of (await readFile(claimed, "utf8")).split("\n")) {
      const event = line.trim() === "" ? null : launcherEventOf(line);
      if (event === null) continue;
      emit(event.level, event.kind, event.fields);
      n++;
    }
    return n;
  } finally {
    await unlink(claimed).catch((e: NodeJS.ErrnoException) => {
      if (e.code !== "ENOENT") throw e;
    });
  }
}
