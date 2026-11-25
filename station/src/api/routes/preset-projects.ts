// A person's default project preference per preset in a workspace, carried across devices and stations by their own
// devices (mirroring api/routes/stars.ts). GET /preset-projects returns the viewer's map; PUT /preset-projects
// `{ presetProjects }` merges per presetId via `mergePresetProjects` and returns the merged map. Changes emit a
// private SSE event `presetProjects` `{ workspace }` to that person's devices alone.
import { type Answer, type Request, error, json } from "../request.ts";
import type { Route } from "../admin.ts";
import { log } from "../../ops/log.ts";
import { readProjectsInfoStrict } from "../../projects/info.ts";
import {
  type PresetProjects,
  RecordRefusal,
  canonical,
  mergePresetProjects,
  presetProjectsOf,
} from "../../../../client/core-ts/src/preset-records.ts";

export type ProjectRenameEvent = { seq: number; from: string; to: string; renamedAt: number; wallAt?: number; originSeq?: number };

export type PresetProjectWatermark = { at: number; wallAt?: number; originSeq: number; seq: number };
export type PresetProjectsMeta = Record<string, PresetProjectWatermark>;

export function parsePresetProjectsMeta(raw: string | null | undefined): PresetProjectsMeta {
  const out: PresetProjectsMeta = Object.create(null);
  if (typeof raw !== "string" || raw.trim() === "") return out;
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return out;
    for (const pid of Object.keys(parsed)) {
      if (!Object.hasOwn(parsed, pid)) continue;
      const v = (parsed as Record<string, unknown>)[pid];
      if (v !== null && typeof v === "object" && !Array.isArray(v)) {
        const rec = v as Record<string, unknown>;
        if (
          typeof rec.at === "number" && Number.isFinite(rec.at) &&
          typeof rec.originSeq === "number" && Number.isFinite(rec.originSeq) &&
          typeof rec.seq === "number" && Number.isFinite(rec.seq)
        ) {
          out[pid] = {
            at: rec.at,
            ...(typeof rec.wallAt === "number" && Number.isFinite(rec.wallAt) ? { wallAt: rec.wallAt } : {}),
            originSeq: rec.originSeq,
            seq: rec.seq,
          };
        }
      }
    }
  } catch {}
  return out;
}

export function eventAfterWatermark(
  ev: { renamedAt: number; originSeq?: number; seq: number },
  wm: PresetProjectWatermark,
): boolean {
  const evOrigin = ev.originSeq ?? ev.seq;
  return (
    ev.renamedAt > wm.at ||
    (ev.renamedAt === wm.at && (evOrigin > wm.originSeq || (evOrigin === wm.originSeq && ev.seq > wm.seq)))
  );
}

/// Where they are kept (the store's `preset_projects` and `project_rename_events`).
export type PresetProjectsKept = {
  presetProjects(ws: string, sub: string): string | null;
  presetProjectsWithMeta?(ws: string, sub: string): { json: string; meta: string | null } | null;
  putPresetProjects(ws: string, sub: string, json: string, meta?: string | null): void;
  listProjectRenameEvents?(ws: string): readonly ProjectRenameEvent[];
  hasLocalProject?(ws: string, name: string, home?: string | null): boolean;
};

/// Single-pass linear scan over `events` (`renamed_at ASC, origin_seq ASC, seq ASC`) migrating `PresetProjects` entries.
/// Uses server-only per-preset watermarks `meta` so already-migrated entries never replay earlier renames (e.g. `B->C` then `A->B`),
/// advances logical `ren` past skipped same-ms logical-clock events for active rebuilt projects (keeping `at` and `rev` immutable)
/// so cross-station carries to peers without local threads stay on the rebuilt project, and NEVER bumps `rev`.
export function migratePresetProjectsByRenames(
  map: PresetProjects,
  events: readonly ProjectRenameEvent[],
  meta?: PresetProjectsMeta,
  opts?: { isActiveProject?: (name: string) => boolean },
): { map: PresetProjects; meta: PresetProjectsMeta; changed: boolean } {
  const nextMeta: PresetProjectsMeta = Object.create(null);
  if (events.length === 0) {
    if (meta !== undefined) {
      for (const pid of Object.keys(map)) {
        if (Object.hasOwn(map, pid) && Object.hasOwn(meta, pid)) nextMeta[pid] = meta[pid]!;
      }
    }
    return { map, meta: nextMeta, changed: false };
  }
  const out: PresetProjects = Object.create(null);
  let changed = false;
  for (const pid of Object.keys(map)) {
    if (!Object.hasOwn(map, pid)) continue;
    const entry = map[pid]!;
    if (typeof entry.project !== "string" || entry.project === "") {
      out[pid] = entry;
      continue;
    }
    const baseAt = entry.at;
    const initialRen = entry.ren;
    let cur = entry.project;
    let wm: PresetProjectWatermark | undefined = meta !== undefined && Object.hasOwn(meta, pid) ? meta[pid] : undefined;
    let skippedMaxWm: PresetProjectWatermark | undefined;
    let curRen: number | undefined = entry.ren;
    let moved = false;
    let bumpedRen = false;
    for (const ev of events) {
      if (cur !== ev.from) continue;
      const evWall = ev.wallAt ?? ev.renamedAt;
      const evWm: PresetProjectWatermark = { at: ev.renamedAt, wallAt: evWall, originSeq: ev.originSeq ?? ev.seq, seq: ev.seq };
      const afterWm =
        (wm !== undefined ? eventAfterWatermark(ev, wm) : true) &&
        (moved || initialRen === undefined || ev.renamedAt > initialRen);
      const eligible =
        afterWm &&
        (moved ||
          baseAt < evWall ||
          (baseAt === evWall &&
            baseAt < ev.renamedAt &&
            (initialRen !== undefined || opts?.isActiveProject?.(cur) !== true)));
      if (eligible) {
        cur = ev.to;
        wm = evWm;
        curRen = ev.renamedAt;
        moved = true;
        if (cur === "") break;
      } else if (ev.renamedAt > baseAt && (curRen === undefined || ev.renamedAt > curRen)) {
        // Skipped event in the same wall-ms narrow window (`ev.renamedAt > baseAt`):
        // advance logical `ren` (keeping `entry.at` & `entry.rev` immutable!) so peers without local threads
        // won't replay the skipped event, while `entry.at` stays the user's true choice wall-clock.
        curRen = ev.renamedAt;
        bumpedRen = true;
        if (skippedMaxWm === undefined || eventAfterWatermark(ev, skippedMaxWm)) {
          skippedMaxWm = evWm;
        }
      }
    }
    const finalWm =
      wm === undefined
        ? skippedMaxWm
        : skippedMaxWm === undefined
          ? wm
          : eventAfterWatermark({ renamedAt: skippedMaxWm.at, originSeq: skippedMaxWm.originSeq, seq: skippedMaxWm.seq }, wm)
            ? skippedMaxWm
            : wm;
    if (finalWm !== undefined) nextMeta[pid] = finalWm;
    if (moved || bumpedRen) {
      out[pid] = curRen !== undefined ? { project: cur, rev: entry.rev, at: entry.at, ren: curRen } : { project: cur, rev: entry.rev, at: entry.at };
      changed = true;
    } else {
      out[pid] = entry;
    }
  }
  return { map: changed ? out : map, meta: nextMeta, changed };
}

export type PresetProjectsDeps = {
  kept: PresetProjectsKept;
  told?: (ws: string, sub: string) => void;
  agentHome?: () => string | null;
  homeWorkspace?: () => string | null;
};

/// A PUT /preset-projects body is at most 256 KiB (matching stars.ts).
const BODY_MOST = 256 * 1024;

export function routes({ kept, told, agentHome, homeWorkspace }: PresetProjectsDeps): Route[] {
  // Always read directly from the single-PK `preset_projects(workspace, sub)` table so background rewrites
  // (e.g. `renameOrMergeProject`) are immediately visible and never overwritten by a stale in-memory cache.
  const readWithMeta = (ws: string, sub: string): { map: PresetProjects; meta: PresetProjectsMeta; metaRaw: string | null } => {
    const row = kept.presetProjectsWithMeta
      ? kept.presetProjectsWithMeta(ws, sub)
      : (() => {
          const text = kept.presetProjects(ws, sub);
          return text === null ? null : { json: text, meta: null };
        })();
    if (row === null) return { map: Object.create(null), meta: Object.create(null), metaRaw: null };
    try {
      return { map: presetProjectsOf(JSON.parse(row.json)), meta: parsePresetProjectsMeta(row.meta), metaRaw: row.meta };
    } catch (e) {
      log.warn("preset-projects", "a person's preset projects kept here do not read; taken as none", { error: (e as Error).message });
      return { map: Object.create(null), meta: Object.create(null), metaRaw: null };
    }
  };
  return [
    {
      method: "GET",
      pattern: /^\/preset-projects$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, "preset projects are a person's own");
        return json(200, JSON.stringify({ presetProjects: readWithMeta(r.viewer.workspace, r.viewer.sub).map }));
      },
    },
    {
      method: "PUT",
      pattern: /^\/preset-projects$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, "preset projects are a person's own");
        if (r.body.length > BODY_MOST) return error(413, "request too large");
        let given: PresetProjects;
        try {
          given = presetProjectsOf((JSON.parse(r.body.toString("utf8") || "{}") as { presetProjects?: unknown } | null)?.presetProjects);
        } catch (e) {
          return error(400, e instanceof RecordRefusal ? e.message : "invalid JSON");
        }
        const ws = r.viewer.workspace;
        const sub = r.viewer.sub;
        const home = homeWorkspace?.() ?? null;
        // Only read PROJECTS.jsonl when an entry actually falls in the narrow same-wall-ms logical-clock window
        // (`evWall <= entry.at < ev.renamedAt`) and is not already backed by a local thread.
        let infoProjects: Record<string, unknown> = Object.create(null);
        const ah = agentHome?.() ?? null;
        if (ah !== null && ah !== "") {
          const preRenames = kept.listProjectRenameEvents?.(ws) ?? [];
          if (preRenames.length > 0) {
            const preMerged = mergePresetProjects(readWithMeta(ws, sub).map, given);
            let needInfo = false;
            for (const pid of Object.keys(preMerged)) {
              if (!Object.hasOwn(preMerged, pid)) continue;
              const entry = preMerged[pid]!;
              if (typeof entry.project !== "string" || entry.project === "") continue;
              for (const ev of preRenames) {
                const evWall = ev.wallAt ?? ev.renamedAt;
                if (
                  ev.from === entry.project &&
                  entry.at === evWall &&
                  entry.at < ev.renamedAt &&
                  entry.ren === undefined
                ) {
                  if (kept.hasLocalProject?.(ws, entry.project, home) !== true) {
                    needInfo = true;
                    break;
                  }
                }
              }
              if (needInfo) break;
            }
            if (needInfo) {
              try {
                const infoDoc = await readProjectsInfoStrict(ah, ws || null, home);
                infoProjects = infoDoc.projects;
              } catch (e) {
                const ans = error(503, `projects metadata temporarily unavailable: ${(e as Error).message}`);
                ans.noCache = true;
                return ans;
              }
            }
          }
        }
        // Re-read latest DB state AFTER any async I/O so read -> merge -> migrate -> put runs in ONE synchronous tick!
        const { map: was, meta: wasMeta, metaRaw: wasMetaRaw } = readWithMeta(ws, sub);
        const merged = mergePresetProjects(was, given);
        const mergedMeta: PresetProjectsMeta = Object.create(null);
        for (const pid of Object.keys(merged)) {
          if (!Object.hasOwn(merged, pid)) continue;
          const m = merged[pid]!;
          const w = Object.hasOwn(was, pid) ? was[pid] : undefined;
          if (w !== undefined && Object.hasOwn(wasMeta, pid)) {
            const wm = wasMeta[pid]!;
            const keptWas = w.project === m.project && w.rev === m.rev && w.at === m.at && (w.ren ?? 0) === (m.ren ?? 0);
            // Inherit watermark when client explicitly edited to a higher rev at wall-clock >= watermark wallAt
            // (entry.at is immutable, so no separate chosenAt is needed).
            const explicitNewerChoice = m.rev > w.rev && m.at >= (wm.wallAt ?? wm.at);
            if (keptWas || explicitNewerChoice) {
              mergedMeta[pid] = wm;
            }
          }
        }
        const renames = kept.listProjectRenameEvents?.(ws) ?? [];
        const { map: now, meta: nextMeta } = migratePresetProjectsByRenames(merged, renames, mergedMeta, {
          isActiveProject: (name) => kept.hasLocalProject?.(ws, name, home) === true || Object.hasOwn(infoProjects, name),
        });
        const nextMetaRaw = Object.keys(nextMeta).length > 0 ? JSON.stringify(nextMeta) : null;
        const dataChanged = canonical(now) !== canonical(was);
        if (dataChanged || nextMetaRaw !== wasMetaRaw) {
          kept.putPresetProjects(ws, sub, JSON.stringify(now), nextMetaRaw);
          if (dataChanged) told?.(ws, sub);
        }
        return json(200, JSON.stringify({ presetProjects: now }));
      },
    },
  ];
}
